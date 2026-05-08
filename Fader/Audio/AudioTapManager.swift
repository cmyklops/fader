import Foundation
import CoreAudio
import AppKit

/// Per-app volume state that persists across launches.
struct AppVolumePreferences {
    private static let prefix = "fader.volume."
    private static let mutePrefix = "fader.mute."

    static func save(bundleID: String, sliderValue: Float, defaults: UserDefaults = .standard) {
        defaults.set(sliderValue, forKey: prefix + bundleID)
    }

    static func hasSavedVolume(bundleID: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: prefix + bundleID) != nil
    }

    static func load(bundleID: String, defaults: UserDefaults = .standard) -> Float {
        guard hasSavedVolume(bundleID: bundleID, defaults: defaults) else { return 1.0 }
        return min(max(defaults.float(forKey: prefix + bundleID), 0.0), 1.0)
    }

    static func saveMute(bundleID: String, isMuted: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isMuted, forKey: mutePrefix + bundleID)
    }

    static func loadMute(bundleID: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: mutePrefix + bundleID)
    }
}

/// Represents a single app entry in the mixer, binding the UI model
/// to the underlying AppAudioTap.
@Observable
final class MixerEntry: Identifiable {
    var process: AudioProcess
    private var tap: AppAudioTap

    /// Linear slider position [0, 1] — drive this from the UI.
    var sliderValue: Float {
        didSet {
            tap.amplitude = VolumeConverter.sliderToAmplitude(sliderValue)
            if let bundleID = process.bundleID {
                AppVolumePreferences.save(bundleID: bundleID, sliderValue: sliderValue)
            }
        }
    }

    var isMuted: Bool {
        didSet {
            tap.isMuted = isMuted
            if let bundleID = process.bundleID {
                AppVolumePreferences.saveMute(bundleID: bundleID, isMuted: isMuted)
            }
        }
    }

    /// Whether the app is currently producing audio output.
    var isPlayingAudio: Bool = true

    var id: pid_t { process.pid }

    var displayLabel: String {
        VolumeConverter.displayString(forSlider: sliderValue)
    }

    var tapStatus: TapStatus {
        tap.status
    }

    init(process: AudioProcess, tap: AppAudioTap) {
        self.process = process
        self.tap = tap
        let initial: Float
        let savedMute: Bool
        if let bundleID = process.bundleID {
            initial = AppVolumePreferences.load(bundleID: bundleID)
            savedMute = AppVolumePreferences.loadMute(bundleID: bundleID)
        } else {
            initial = 1.0
            savedMute = false
        }
        self.sliderValue = initial
        self.isMuted = savedMute
        applyCurrentState(to: tap)
    }

    func update(process: AudioProcess) {
        self.process = process
    }

    func replaceTap(_ tap: AppAudioTap, process: AudioProcess) {
        self.process = process
        self.tap = tap
        applyCurrentState(to: tap)
    }

    private func applyCurrentState(to tap: AppAudioTap) {
        tap.amplitude = VolumeConverter.sliderToAmplitude(sliderValue)
        tap.isMuted = isMuted
    }
}

/// Top-level audio engine. Creates and tears down AppAudioTap instances
/// as audio-producing processes appear and disappear.
@Observable
@MainActor
final class AudioTapManager {

    /// Ordered list of active mixer entries, sorted by app name.
    private(set) var entries: [MixerEntry] = []

    /// Human-readable error for display in UI.
    private(set) var lastError: String?
    private(set) var recentErrors: [String] = []

    private let processMonitor = AudioProcessMonitor()
    private var activeTaps: [pid_t: AppAudioTap] = [:]
    private var defaultOutputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var isShuttingDown = false

    init(startImmediately: Bool = true) {
        guard startImmediately else { return }
        startObservingProcesses()
        startObservingDefaultOutputDevice()
        startObservingWorkspacePowerState()
    }

    deinit {
        MainActor.assumeIsolated {
            shutdown()
        }
    }

    // MARK: - Public

    func refresh() {
        processMonitor.refresh()
        syncProcesses()
    }

    func restartTap(pid: pid_t) {
        guard let process = processMonitor.processes[pid] ?? entries.first(where: { $0.id == pid })?.process else {
            return
        }
        restartTap(pid: pid, process: process)
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true

        removeDefaultOutputDeviceListener()
        for token in workspaceObserverTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObserverTokens.removeAll()

        for tap in activeTaps.values {
            record(stopErrors: tap.stop())
        }
        activeTaps.removeAll()
        processMonitor.shutdown()
    }

    func diagnosticsReport() -> DiagnosticsReport {
        let bundle = Bundle.main
        let defaultOutputUID = try? AppAudioTap.defaultOutputDevice().1
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        let snapshots = entries.map { entry in
            let outputUID: String?
            let status: String
            switch entry.tapStatus {
            case .stopped:
                outputUID = nil
                status = "stopped"
            case .running(let configuration):
                outputUID = configuration.outputDeviceUID
                status = "running"
            case .failed(let message):
                outputUID = nil
                status = "failed: \(message)"
            }

            return DiagnosticsReport.TapSnapshot(
                id: entry.id,
                name: entry.process.name,
                pid: entry.process.pid,
                bundleID: entry.process.bundleID,
                objectIDSignature: entry.process.objectIDSignature,
                outputDeviceUID: outputUID,
                isPlayingAudio: entry.isPlayingAudio,
                isMuted: entry.isMuted,
                sliderValue: entry.sliderValue,
                status: status
            )
        }

        return DiagnosticsReport(
            generatedAt: Date(),
            appVersion: version,
            appBuild: build,
            macOSVersion: macOSVersion,
            defaultOutputDeviceUID: defaultOutputUID,
            permissions: DiagnosticsReport.permissions(bundle: bundle),
            taps: snapshots,
            recentErrors: recentErrors
        )
    }

    func exportDiagnostics(to url: URL) throws {
        let report = diagnosticsReport()
        if url.pathExtension.lowercased() == "txt" {
            try report.textSummary.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try report.jsonData.write(to: url, options: [.atomic])
        }
    }

    // MARK: - Private

    private func startObservingProcesses() {
        syncProcesses()
        observeProcessMonitor()
    }

    private func startObservingDefaultOutputDevice() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.restartAllTaps()
            }
        }
        defaultOutputDeviceListenerBlock = block
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status != kAudioHardwareNoError {
            record(TapError(.listenerRegistration, status: status, detail: "Default output device changes will require manual refresh."))
        }
    }

    private func removeDefaultOutputDeviceListener() {
        guard let block = defaultOutputDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status != kAudioHardwareNoError {
            record(TapError(.listenerRegistration, status: status, detail: "Failed to remove default output listener."))
        }
        defaultOutputDeviceListenerBlock = nil
    }

    private func startObservingWorkspacePowerState() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stopTapsForSleep()
                }
            }
        )
        workspaceObserverTokens.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                    self?.restartAllTaps()
                }
            }
        )
    }

    private func restartAllTaps() {
        let pids = Set(activeTaps.keys).union(entries.map(\.id))
        for pid in pids {
            restartTap(pid: pid)
        }
    }

    private func stopTapsForSleep() {
        for tap in activeTaps.values {
            record(stopErrors: tap.stop())
        }
        activeTaps.removeAll()
        for entry in entries {
            entry.isPlayingAudio = false
        }
    }

    private func observeProcessMonitor() {
        guard !isShuttingDown else { return }
        withObservationTracking {
            _ = processMonitor.processes
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown else { return }
                self.syncProcesses()
                self.observeProcessMonitor()
            }
        }
    }

    private func removeEntry(for pid: pid_t) {
        guard activeTaps[pid] != nil || entries.contains(where: { $0.id == pid }) else { return }
        if let tap = activeTaps[pid] {
            record(stopErrors: tap.stop())
        }
        activeTaps.removeValue(forKey: pid)
        entries.removeAll { $0.id == pid }
    }

    private func syncProcesses() {
        guard !isShuttingDown else { return }
        let currentProcesses = processMonitor.processes

        let livePIDs = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
        for pid in Array(activeTaps.keys) where !livePIDs.contains(pid) {
            removeEntry(for: pid)
        }

        for entry in entries {
            if let process = currentProcesses[entry.id] {
                entry.update(process: process)
                entry.isPlayingAudio = process.isRunning
                if activeTaps[entry.id]?.configuration?.objectIDSignature != process.objectIDSignature {
                    restartTap(pid: entry.id, process: process)
                }
            } else {
                entry.isPlayingAudio = false
            }
        }

        let addedIDs = Set(currentProcesses.keys).subtracting(Set(entries.map(\.id)))
        for id in addedIDs {
            guard let process = currentProcesses[id] else { continue }
            addEntry(for: process)
        }

        entries.sort { $0.process.name.localizedCompare($1.process.name) == .orderedAscending }
    }

    private func addEntry(for process: AudioProcess) {
        let tap = makeTap(for: process, entry: nil)
        do {
            try tap.start()
            activeTaps[process.pid] = tap
            let entry = MixerEntry(process: process, tap: tap)
            entry.isPlayingAudio = process.isRunning
            entries.append(entry)
        } catch {
            record(error)
        }
    }

    private func restartTap(pid: pid_t, process: AudioProcess) {
        let entry = entries.first { $0.id == pid }
        let replacement = makeTap(for: process, entry: entry)

        if let oldTap = activeTaps[pid] {
            record(stopErrors: oldTap.stop())
        }
        activeTaps.removeValue(forKey: pid)

        do {
            try replacement.start()
            activeTaps[pid] = replacement
            if let entry {
                entry.replaceTap(replacement, process: process)
                entry.isPlayingAudio = process.isRunning
            } else {
                let newEntry = MixerEntry(process: process, tap: replacement)
                newEntry.isPlayingAudio = process.isRunning
                entries.append(newEntry)
            }
        } catch {
            record(error)
        }
    }

    private func makeTap(for process: AudioProcess, entry: MixerEntry?) -> AppAudioTap {
        let sliderValue: Float
        let isMuted: Bool
        if let entry {
            sliderValue = entry.sliderValue
            isMuted = entry.isMuted
        } else if let bundleID = process.bundleID {
            sliderValue = AppVolumePreferences.load(bundleID: bundleID)
            isMuted = AppVolumePreferences.loadMute(bundleID: bundleID)
        } else {
            sliderValue = 1.0
            isMuted = false
        }

        return AppAudioTap(
            process: process,
            initialAmplitude: VolumeConverter.sliderToAmplitude(sliderValue),
            isMuted: isMuted
        )
    }

    private func record(_ error: Error) {
        let message = error.localizedDescription
        lastError = message
        recentErrors.append(message)
        if recentErrors.count > 20 {
            recentErrors.removeFirst(recentErrors.count - 20)
        }
    }

    private func record(stopErrors errors: [TapError]) {
        for error in errors {
            record(error)
        }
    }
}

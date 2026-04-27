import Foundation
import CoreAudio
import AppKit

/// Per-app volume state that persists across launches.
struct AppVolumePreferences {
    private static let prefix = "fader.volume."
    private static let mutePrefix = "fader.mute."

    static func save(bundleID: String, sliderValue: Float) {
        UserDefaults.standard.set(sliderValue, forKey: prefix + bundleID)
    }

    static func load(bundleID: String) -> Float {
        let stored = UserDefaults.standard.float(forKey: prefix + bundleID)
        return stored > 0 ? stored : 1.0
    }

    static func saveMute(bundleID: String, isMuted: Bool) {
        UserDefaults.standard.set(isMuted, forKey: mutePrefix + bundleID)
    }

    static func loadMute(bundleID: String) -> Bool {
        UserDefaults.standard.bool(forKey: mutePrefix + bundleID)
    }
}

/// Represents a single app entry in the mixer, binding the UI model
/// to the underlying AppAudioTap.
@Observable
final class MixerEntry: Identifiable {
    let process: AudioProcess
    private let tap: AppAudioTap

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
    /// Apps remain in the mixer list when paused (e.g. Tidal paused) so users
    /// can pre-set volumes; this flag drives the visual "active" indicator.
    var isPlayingAudio: Bool = true

    var id: pid_t { process.pid }

    var displayLabel: String {
        VolumeConverter.displayString(forSlider: sliderValue)
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
        tap.isMuted = savedMute
        let targetAmplitude = VolumeConverter.sliderToAmplitude(initial)
        if savedMute || targetAmplitude >= 0.99 {
            tap.amplitude = targetAmplitude
        } else {
            // Fade from unity to saved level to avoid audible jump on startup
            tap.fadeToAmplitude(targetAmplitude)
        }
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

    private let processMonitor = AudioProcessMonitor()
    private var activeTaps: [pid_t: AppAudioTap] = [:]
    private var defaultOutputDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        startObservingProcesses()
        startObservingDefaultOutputDevice()
    }

    deinit {
        if let block = defaultOutputDeviceListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )
        }
    }

    // MARK: - Public

    /// Manually refreshes the list of audio-producing processes.
    func refresh() {
        processMonitor.refresh()
    }

    // MARK: - Private

    private func startObservingProcesses() {
        // Trigger initial sync then observe changes.
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
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func restartAllTaps() {
        for (pid, tap) in activeTaps {
            tap.stop()
            do {
                try tap.start()
            } catch {
                lastError = error.localizedDescription
                print("[AudioTapManager] Failed to restart tap for pid=\(pid) after output device change: \(error)")
            }
        }
    }

    private func observeProcessMonitor() {
        withObservationTracking {
            _ = processMonitor.processes
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncProcesses()
                self?.observeProcessMonitor()
            }
        }
    }

    private func removeEntry(for pid: pid_t) {
        guard activeTaps[pid] != nil || entries.contains(where: { $0.id == pid }) else { return }
        activeTaps[pid]?.stop()
        activeTaps.removeValue(forKey: pid)
        entries.removeAll { $0.id == pid }
    }

    private func syncProcesses() {
        let currentProcesses = processMonitor.processes

        // Use NSWorkspace (not CoreAudio) to determine if an app has actually quit.
        // CoreAudio removes processes from its list when they go silent/paused,
        // so we must not use it as the removal signal.
        let livePIDs = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
        for pid in Array(activeTaps.keys) where !livePIDs.contains(pid) {
            removeEntry(for: pid)
        }

        // Update playing/paused indicator. An entry stays in the list even when
        // isPlayingAudio is false (app paused); it's only removed when the app quits.
        for entry in entries {
            entry.isPlayingAudio = currentProcesses[entry.id]?.isRunning ?? false
        }

        // Add taps for newly-discovered audio-producing processes.
        let addedIDs = Set(currentProcesses.keys).subtracting(activeTaps.keys)
        for id in addedIDs {
            guard let process = currentProcesses[id] else { continue }
            let tap = AppAudioTap(process: process)
            do {
                try tap.start()
                activeTaps[id] = tap
                let entry = MixerEntry(process: process, tap: tap)
                entry.isPlayingAudio = process.isRunning
                entries.append(entry)
            } catch {
                lastError = error.localizedDescription
                print("[AudioTapManager] Failed to tap \(process.name): \(error)")
            }
        }

        // Keep list sorted by app name for stable UI ordering.
        entries.sort { $0.process.name.localizedCompare($1.process.name) == .orderedAscending }
    }
}

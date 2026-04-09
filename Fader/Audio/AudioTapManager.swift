import Foundation
import CoreAudio

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

    /// Manually refreshes the list of audio-producing processes.
    func refresh() {
        processMonitor.refresh()
    }
    private var activeTaps: [pid_t: AppAudioTap] = [:]

    init() {
        // Respond to process list changes from the monitor.
        // We use a periodic check via withObservationTracking since
        // AudioProcessMonitor is @Observable.
        startObservingProcesses()
    }

    // MARK: - Private

    private func startObservingProcesses() {
        // Trigger initial sync then observe changes.
        syncProcesses()
        observeProcessMonitor()
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

    private func syncProcesses() {
        let currentProcesses = processMonitor.processes

        // Remove taps for processes that are gone.
        let removedIDs = Set(activeTaps.keys).subtracting(currentProcesses.keys)
        for id in removedIDs {
            activeTaps[id]?.stop()
            activeTaps.removeValue(forKey: id)
            entries.removeAll { $0.id == id }
        }

        // Add taps for new processes.
        let addedIDs = Set(currentProcesses.keys).subtracting(activeTaps.keys)
        for id in addedIDs {
            guard let process = currentProcesses[id] else { continue }
            let tap = AppAudioTap(process: process)
            do {
                try tap.start()
                activeTaps[id] = tap
                entries.append(MixerEntry(process: process, tap: tap))
            } catch {
                lastError = error.localizedDescription
                print("[AudioTapManager] Failed to tap \(process.name): \(error)")
            }
        }

        // Keep list sorted by app name for stable UI ordering.
        entries.sort { $0.process.name.localizedCompare($1.process.name) == .orderedAscending }
    }
}

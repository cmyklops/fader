import Foundation
import CoreAudio
import AppKit

/// A model representing a single audio-producing process discovered on the system.
@Observable
final class AudioProcess: Identifiable {
    /// The CoreAudio object ID for this process.
    let objectID: AudioObjectID

    /// The Unix process ID.
    let pid: pid_t

    /// The application bundle identifier, if available.
    let bundleID: String?

    /// The human-readable application name.
    let name: String

    /// The application icon, if available.
    let icon: NSImage?

    init(objectID: AudioObjectID, pid: pid_t, bundleID: String?, name: String, icon: NSImage?) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
    }

    var id: AudioObjectID { objectID }
}

/// Monitors the system for audio-producing processes and publishes the
/// current list as an `@Observable` property.
@Observable
@MainActor
final class AudioProcessMonitor {

    /// Currently active audio-producing processes, keyed by AudioObjectID.
    private(set) var processes: [AudioObjectID: AudioProcess] = [:]

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public

    /// Fetches the current process list immediately (one-shot refresh).
    func refresh() {
        processes = fetchProcesses()
    }

    // MARK: - Private

    private func startMonitoring() {
        processes = fetchProcesses()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.processes = self?.fetchProcesses() ?? [:]
            }
        }
        listenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )

        if status != kAudioHardwareNoError {
            print("[AudioProcessMonitor] Failed to add property listener: \(status)")
        }
    }

    private func stopMonitoring() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        listenerBlock = nil
    }

    private func fetchProcesses() -> [AudioObjectID: AudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &dataSize
        )
        guard status == kAudioHardwareNoError, dataSize > 0 else { return [:] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &dataSize,
            &objectIDs
        )
        guard status == kAudioHardwareNoError else { return [:] }

        var result: [AudioObjectID: AudioProcess] = [:]
        for objectID in objectIDs {
            if let process = makeAudioProcess(objectID: objectID) {
                result[objectID] = process
            }
        }
        return result
    }

    private func makeAudioProcess(objectID: AudioObjectID) -> AudioProcess? {
        // Fetch PID
        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var pidSize = UInt32(MemoryLayout<pid_t>.size)
        let pidStatus = AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &pid)
        guard pidStatus == kAudioHardwareNoError, pid > 0 else { return nil }

        // Resolve running application info
        let runningApp = NSRunningApplication(processIdentifier: pid)
        let name = runningApp?.localizedName ?? runningApp?.bundleIdentifier ?? "PID \(pid)"
        let bundleID = runningApp?.bundleIdentifier
        let icon = runningApp?.icon

        // Skip system audio daemon and our own process
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard pid != selfPID else { return nil }
        guard bundleID != "com.apple.audio.coreaudiod" else { return nil }

        return AudioProcess(
            objectID: objectID,
            pid: pid,
            bundleID: bundleID,
            name: name,
            icon: icon
        )
    }
}

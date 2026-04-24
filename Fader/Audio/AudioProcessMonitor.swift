import Foundation
import CoreAudio
import AppKit

/// A model representing a single audio-producing application discovered on the system.
/// May encompass multiple CoreAudio process objects (parent + child/helper processes).
@Observable
final class AudioProcess: Identifiable {
    /// The primary CoreAudio object ID (the Dock-visible app itself).
    let objectID: AudioObjectID

    /// ALL CoreAudio object IDs for this app's process tree (parent + children).
    let allObjectIDs: [AudioObjectID]

    /// The Unix process ID of the parent app.
    let pid: pid_t

    /// The application bundle identifier, if available.
    let bundleID: String?

    /// The human-readable application name.
    let name: String

    /// The application icon, if available.
    let icon: NSImage?

    /// Whether any of this app's audio processes are currently active (non-zero isRunning).
    /// False when the app is paused/silent but still registered with CoreAudio.
    var isRunning: Bool

    init(objectID: AudioObjectID, allObjectIDs: [AudioObjectID], pid: pid_t, bundleID: String?, name: String, icon: NSImage?, isRunning: Bool) {
        self.objectID = objectID
        self.allObjectIDs = allObjectIDs
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
        self.isRunning = isRunning
    }

    var id: pid_t { pid }
}

/// Monitors the system for audio-producing processes and publishes the
/// current list as an `@Observable` property.
@Observable
@MainActor
final class AudioProcessMonitor {

    /// Currently active audio-producing processes, keyed by app PID.
    private(set) var processes: [pid_t: AudioProcess] = [:]

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var isRunningListenerBlock: AudioObjectPropertyListenerBlock?
    private var isRunningListenerObjectIDs: Set<AudioObjectID> = []

    init() {
        startMonitoring()
    }

    // MARK: - Public

    /// Fetches the current process list immediately (one-shot refresh).
    func refresh() {
        processes = fetchProcesses()
    }

    // MARK: - Private

    private func startMonitoring() {
        // Block for kAudioHardwarePropertyProcessObjectList changes (new process registered
        // or unregistered). Does an immediate fetch plus a deferred second fetch 500ms later
        // because some helpers (Firefox renderer, Electron) aren't marked isRunning yet
        // at the moment the notification fires.
        let processListBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.processes = self?.fetchProcesses() ?? [:]
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.processes = self?.fetchProcesses() ?? [:]
            }
        }
        listenerBlock = processListBlock

        // Separate block for per-process kAudioProcessPropertyIsRunning changes (play/pause).
        // No delay needed — the state is already set when this fires.
        let isRunningBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.processes = self?.fetchProcesses() ?? [:]
            }
        }
        isRunningListenerBlock = isRunningBlock

        processes = fetchProcesses()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            processListBlock
        )

        if status != kAudioHardwareNoError {
            print("[AudioProcessMonitor] Failed to add property listener: \(status)")
        }
    }

    private func stopMonitoring() {
        if let block = listenerBlock {
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
        if let block = isRunningListenerBlock {
            var isRunAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunning,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            for objID in isRunningListenerObjectIDs {
                AudioObjectRemovePropertyListenerBlock(objID, &isRunAddr, DispatchQueue.main, block)
            }
            isRunningListenerBlock = nil
        }
        isRunningListenerObjectIDs.removeAll()
    }

    private func updateIsRunningListeners(allObjectIDs: [AudioObjectID]) {
        let newSet = Set(allObjectIDs)
        let toRemove = isRunningListenerObjectIDs.subtracting(newSet)
        let toAdd = newSet.subtracting(isRunningListenerObjectIDs)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard let block = isRunningListenerBlock else { return }

        for objID in toRemove {
            AudioObjectRemovePropertyListenerBlock(objID, &address, DispatchQueue.main, block)
        }
        for objID in toAdd {
            AudioObjectAddPropertyListenerBlock(objID, &address, DispatchQueue.main, block)
        }
        isRunningListenerObjectIDs = newSet
    }

    private func fetchProcesses() -> [pid_t: AudioProcess] {
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

        // Listen for isRunningOutput changes on all process objects.
        updateIsRunningListeners(allObjectIDs: objectIDs)

        let selfPID = ProcessInfo.processInfo.processIdentifier

        // Build the Dock-app lookup first so Step 1 can use it per-object.
        let dockApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPID
        }
        let dockAppByPID = Dictionary(uniqueKeysWithValues: dockApps.map { ($0.processIdentifier, $0) })

        // Step 1: Map every audio objectID → its PID.
        // Include ALL registered processes (playing or paused) so apps like Tidal show up
        // in the mixer even when not actively producing audio. Track isRunning separately
        // per objectID so we can report the playing/paused indicator to the UI.
        var objToPID: [(AudioObjectID, pid_t)] = []
        var isRunningByObjID: [AudioObjectID: Bool] = [:]
        for objectID in objectIDs {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            let st = AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &pid)
            guard st == kAudioHardwareNoError, pid > 0, pid != selfPID else { continue }

            var isRunAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunning,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunning: UInt32 = 0
            var isRunSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(objectID, &isRunAddr, 0, nil, &isRunSize, &isRunning)
            isRunningByObjID[objectID] = isRunning != 0

            objToPID.append((objectID, pid))
        }

        // Step 2: For each PID, find the owning Dock app by walking PPID.
        // Cache PID → parent app PID + NSRunningApplication.
        var appForPID: [pid_t: NSRunningApplication] = [:]

        func findParentApp(for pid: pid_t) -> NSRunningApplication? {
            if let cached = appForPID[pid] { return cached }
            // If this PID is itself a Dock app, return it.
            if let app = dockAppByPID[pid] {
                appForPID[pid] = app
                return app
            }
            // Walk up the PPID chain (max 10 levels to avoid infinite loops).
            var current = pid
            for _ in 0..<10 {
                var info = proc_bsdinfo()
                let size = proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                guard size > 0 else { break }
                let ppid = pid_t(info.pbi_ppid)
                if ppid <= 1 { break }
                if let app = dockAppByPID[ppid] {
                    appForPID[pid] = app
                    return app
                }
                current = ppid
            }
            // Fallback: check if the process executable is inside an app bundle.
            // This catches sandboxed helper processes (e.g. Firefox Web Content, GPU process)
            // whose PPID chain doesn't trace back through the Dock app's PID.
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN)) > 0 {
                let execPath = String(cString: pathBuffer)
                for app in dockApps {
                    if let bundlePath = app.bundleURL?.path,
                       execPath.hasPrefix(bundlePath + "/") {
                        appForPID[pid] = app
                        return app
                    }
                }
            }
            return nil
        }

        // Step 3: Group objectIDs by parent app PID.
        var groupedObjectIDs: [pid_t: [AudioObjectID]] = [:]
        var primaryObjectID: [pid_t: AudioObjectID] = [:]
        for (objectID, pid) in objToPID {
            guard let parentApp = findParentApp(for: pid) else { continue }
            let appPID = parentApp.processIdentifier
            groupedObjectIDs[appPID, default: []].append(objectID)
            // The objectID whose PID matches the app PID is the "primary" one.
            if pid == appPID {
                primaryObjectID[appPID] = objectID
            }
        }

        // Step 4: Build AudioProcess for each group.
        var result: [pid_t: AudioProcess] = [:]
        for (appPID, objectIDs) in groupedObjectIDs {
            guard let app = dockAppByPID[appPID] else { continue }
            guard let name = app.localizedName, !name.isEmpty else { continue }
            let primary = primaryObjectID[appPID] ?? objectIDs[0]
            // App is considered running if ANY of its audio objects are active.
            let running = objectIDs.contains { isRunningByObjID[$0] == true }
            result[appPID] = AudioProcess(
                objectID: primary,
                allObjectIDs: objectIDs,
                pid: appPID,
                bundleID: app.bundleIdentifier,
                name: name,
                icon: app.icon,
                isRunning: running
            )
        }
        return result
    }
}

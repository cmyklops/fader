import Foundation
import CoreAudio
import AudioToolbox
import CoreGraphics
import AppKit
import os

private let logger = Logger(subsystem: "com.mattwesdock.Fader", category: "TapDiagnostics")

/// One-shot diagnostics to help debug why the process tap IOProc may not fire.
enum TapDiagnostics {

    static func runAll() {
        logger.warning("===== TAP DIAGNOSTICS START =====")

        checkMacOSVersion()
        checkDefaultOutputDevice()
        checkScreenCapturePermission()
        listAudioProcesses()
        runMinimalTapTest()

        logger.warning("===== TAP DIAGNOSTICS END =====")
    }

    // MARK: - 1. macOS Version

    private static func checkMacOSVersion() {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        logger.info("macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }

    // MARK: - 2. Default Output Device

    private static func checkDefaultOutputDevice() {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        logger.info("Default output device: id=\(deviceID), status=\(st)")

        if deviceID != kAudioObjectUnknown {
            // Get UID
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uidRef)
            let uid = uidRef?.takeRetainedValue() as String? ?? "<nil>"
            logger.info("  UID: \(uid)")

            // Get stream config (output scope)
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize)
            let ablPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(streamSize))
            defer { ablPtr.deallocate() }
            let cfgSt = AudioObjectGetPropertyData(deviceID, &streamAddr, 0, nil, &streamSize, ablPtr)
            if cfgSt == kAudioHardwareNoError {
                let bufs = UnsafeMutableAudioBufferListPointer(ablPtr)
                logger.info("  Output buffers: \(bufs.count)")
                for (i, buf) in bufs.enumerated() {
                    logger.info("    [\(i)] channels=\(buf.mNumberChannels), bytes=\(buf.mDataByteSize)")
                }
            }

            // Check device is running
            var isRunning: UInt32 = 0
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunning,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(deviceID, &runAddr, 0, nil, &runSize, &isRunning)
            logger.info("  isRunning: \(isRunning)")
        }
    }

    // MARK: - 3. Screen Capture Permission (heuristic)

    private static func checkScreenCapturePermission() {
        // CGWindowListCopyWindowInfo returns an empty/nil list if we lack Screen Recording permission.
        // This is the standard heuristic used by many apps.
        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let hasNames = windowList.contains { ($0[kCGWindowOwnerName as String] as? String) != nil }
            logger.info("Screen capture check: \(windowList.count) windows, hasOwnerNames=\(hasNames)")
            if !hasNames && windowList.isEmpty {
                logger.error("⚠️ Screen Recording permission likely DENIED — process taps may silently fail")
            } else {
                logger.info("Screen Recording permission appears GRANTED (or not needed)")
            }
        } else {
            logger.error("⚠️ CGWindowListCopyWindowInfo returned nil — Screen Recording permission likely DENIED")
        }
    }

    // MARK: - 4. Audio Process List

    private static func listAudioProcesses() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize)
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &objectIDs)

        logger.info("Audio processes: \(count) total")
        for objID in objectIDs {
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &pidSize, &pid)

            // Check if process is running output audio
            var isRunningOut: UInt32 = 0
            var runOutAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var runOutSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(objID, &runOutAddr, 0, nil, &runOutSize, &isRunningOut)

            let name: String
            if let app = NSRunningApplication(processIdentifier: pid) {
                name = app.localizedName ?? app.bundleIdentifier ?? "pid=\(pid)"
            } else {
                name = "pid=\(pid)"
            }
            let outputTag = isRunningOut != 0 ? " 🔊AUDIO_OUTPUT" : ""
            logger.info("  objID=\(objID)  pid=\(pid)  \(name)\(outputTag)")
        }
    }

    // MARK: - Helper: read nominal sample rate

    private static func readNominalSampleRate(deviceID: AudioObjectID) -> Float64 {
        var rate: Float64 = 0
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &rateSize, &rate)
        return rate
    }

    private static func readIsRunning(deviceID: AudioObjectID) -> UInt32 {
        var isRunning: UInt32 = 0
        var runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var runSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &runAddr, 0, nil, &runSize, &isRunning)
        return isRunning
    }

    // Context object for passing state through C render callback's refcon.
    private final class DiagContext: @unchecked Sendable {
        let au: AudioUnit
        var callCount: UInt64 = 0
        init(au: AudioUnit) { self.au = au }
    }

    // MARK: - 5. Minimal Tap Test (3 approaches)

    /// Runs three tap tests: IOProc (nil queue), IOProc (custom queue), AUHAL.
    /// Also checks aggregate isRunning and sample rates.
    private static func runMinimalTapTest() {
        logger.info("--- Minimal Tap Test ---")

        // Find a process that is ACTIVELY producing audio output
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize)
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { logger.error("No audio processes found"); return }

        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &objectIDs)

        let selfPID = ProcessInfo.processInfo.processIdentifier
        var activeOutputObjID: AudioObjectID?
        var fallbackObjID: AudioObjectID?

        for objID in objectIDs {
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &pidSize, &pid)
            guard pid != selfPID, pid > 0 else { continue }

            if fallbackObjID == nil { fallbackObjID = objID }

            // Prefer a process that is actively outputting audio
            var isRunningOut: UInt32 = 0
            var runOutAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var runOutSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(objID, &runOutAddr, 0, nil, &runOutSize, &isRunningOut)
            if isRunningOut != 0 {
                activeOutputObjID = objID
                let name: String
                if let app = NSRunningApplication(processIdentifier: pid) {
                    name = app.localizedName ?? "pid=\(pid)"
                } else { name = "pid=\(pid)" }
                logger.info("Found active audio output process: objID=\(objID) \(name)")
                break
            }
        }

        let testObjID: AudioObjectID
        if let active = activeOutputObjID {
            testObjID = active
            logger.info("Testing with ACTIVE output process objID=\(testObjID)")
        } else if let fb = fallbackObjID {
            testObjID = fb
            logger.warning("⚠️ No process is actively outputting audio! Using fallback objID=\(testObjID)")
        } else {
            logger.error("No suitable process for test")
            return
        }

        // Get default output UID (try BOTH properties)
        var defOutID = AudioObjectID(kAudioObjectUnknown)
        var defOutSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var defOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defOutAddr, 0, nil, &defOutSize, &defOutID)

        var sysOutID = AudioObjectID(kAudioObjectUnknown)
        var sysOutSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var sysOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &sysOutAddr, 0, nil, &sysOutSize, &sysOutID)
        logger.info("DefaultOutputDevice=\(defOutID), DefaultSystemOutputDevice=\(sysOutID), same=\(defOutID == sysOutID)")

        let outputDeviceID = defOutID
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(outputDeviceID, &uidAddr, 0, nil, &uidSize, &uidRef)
        guard let outputUID = uidRef?.takeRetainedValue() as String? else {
            logger.error("Cannot get output UID for test")
            return
        }

        let outputRate = readNominalSampleRate(deviceID: outputDeviceID)
        logger.info("Output device rate=\(outputRate)")

        // --- Test A: IOProc with nil queue (simplest, like AudioCap) ---
        logger.warning("=== TEST A: IOProc with nil queue ===")
        runIOProcTest(label: "A", testObjID: testObjID, outputUID: outputUID, outputRate: outputRate, queue: nil)

        // --- Test B: IOProc with custom queue ---
        logger.warning("=== TEST B: IOProc with custom queue ===")
        let customQueue = DispatchQueue(label: "com.mattwesdock.Fader.diag.B", qos: .userInteractive)
        runIOProcTest(label: "B", testObjID: testObjID, outputUID: outputUID, outputRate: outputRate, queue: customQueue)

        // --- Test C: AUHAL approach ---
        logger.warning("=== TEST C: AUHAL render callback ===")
        runAUHALTest(label: "C", testObjID: testObjID, outputUID: outputUID, outputRate: outputRate)
    }

    // MARK: - Test A/B: IOProc

    private static func runIOProcTest(label: String, testObjID: AudioObjectID, outputUID: String, outputRate: Float64, queue: DispatchQueue?) {
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [testObjID])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted
        tapDesc.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapSt = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        logger.info("[\(label)] CreateProcessTap: status=\(tapSt), tapID=\(tapID)")
        guard tapSt == kAudioHardwareNoError else { return }

        // Read tap format
        var tapFmt = AudioStreamBasicDescription()
        var tapFmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapFmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtSt = AudioObjectGetPropertyData(tapID, &tapFmtAddr, 0, nil, &tapFmtSize, &tapFmt)
        logger.info("[\(label)] Tap format: status=\(fmtSt) rate=\(tapFmt.mSampleRate) ch=\(tapFmt.mChannelsPerFrame) bits=\(tapFmt.mBitsPerChannel) fmtID=\(tapFmt.mFormatID)")

        let tapUID = tapDesc.uuid.uuidString
        let aggUID = UUID().uuidString
        let aggProps: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Fader-Diag-\(label)",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID
                ]
            ]
        ]

        var aggID = AudioObjectID(kAudioObjectUnknown)
        let aggSt = AudioHardwareCreateAggregateDevice(aggProps as CFDictionary, &aggID)
        logger.info("[\(label)] CreateAggregateDevice: status=\(aggSt), aggID=\(aggID)")
        guard aggSt == kAudioHardwareNoError else {
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        // Check aggregate sample rate
        let aggRate = readNominalSampleRate(deviceID: aggID)
        logger.info("[\(label)] Aggregate nominal rate=\(aggRate), output rate=\(outputRate), match=\(aggRate == outputRate)")

        // If rates differ, try setting it
        if aggRate != outputRate && outputRate > 0 {
            var setRate = outputRate
            var rateAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let setRateSt = AudioObjectSetPropertyData(aggID, &rateAddr, 0, nil,
                UInt32(MemoryLayout<Float64>.size), &setRate)
            logger.info("[\(label)] Set aggregate rate to \(outputRate): status=\(setRateSt)")
        }

        // Check aggregate isRunning BEFORE start
        let runBefore = readIsRunning(deviceID: aggID)
        logger.info("[\(label)] Aggregate isRunning BEFORE start: \(runBefore)")

        // Create IOProc
        nonisolated(unsafe) var callCount: UInt64 = 0
        var procID: AudioDeviceIOProcID?
        let procSt = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, inInput, _, outOutput, _ in
            callCount += 1
            // Pass through input to output
            let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            let outABL = UnsafeMutableAudioBufferListPointer(outOutput)
            for i in 0..<min(inABL.count, outABL.count) {
                guard let src = inABL[i].mData, let dst = outABL[i].mData else { continue }
                memcpy(dst, src, Int(min(inABL[i].mDataByteSize, outABL[i].mDataByteSize)))
            }
        }
        logger.info("[\(label)] CreateIOProcIDWithBlock: status=\(procSt)")
        guard procSt == kAudioHardwareNoError, let validProcID = procID else {
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        let startSt = AudioDeviceStart(aggID, validProcID)
        logger.info("[\(label)] AudioDeviceStart: status=\(startSt)")

        // Check aggregate isRunning AFTER start
        let runAfter = readIsRunning(deviceID: aggID)
        logger.info("[\(label)] Aggregate isRunning AFTER start: \(runAfter)")

        // Also check output device isRunning
        // (We stored defOutID in the caller but we need to re-read here)
        var defOutID2 = AudioObjectID(kAudioObjectUnknown)
        var defOutSize2 = UInt32(MemoryLayout<AudioObjectID>.size)
        var defOutAddr2 = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defOutAddr2, 0, nil, &defOutSize2, &defOutID2)
        let outRunAfter = readIsRunning(deviceID: defOutID2)
        logger.info("[\(label)] Output device isRunning AFTER start: \(outRunAfter)")

        let cleanupAggID = aggID
        let cleanupTapID = tapID
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            logger.warning("[\(label)] Result: IOProc called \(callCount) times in 2s")
            let aggRunFinal = readIsRunning(deviceID: cleanupAggID)
            logger.info("[\(label)] Aggregate isRunning at check time: \(aggRunFinal)")

            AudioDeviceStop(cleanupAggID, validProcID)
            AudioDeviceDestroyIOProcID(cleanupAggID, validProcID)
            AudioHardwareDestroyAggregateDevice(cleanupAggID)
            AudioHardwareDestroyProcessTap(cleanupTapID)
            logger.info("[\(label)] Cleanup done")
        }
    }

    // MARK: - Test C: AUHAL

    private static func runAUHALTest(label: String, testObjID: AudioObjectID, outputUID: String, outputRate: Float64) {
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [testObjID])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted
        tapDesc.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapSt = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard tapSt == kAudioHardwareNoError else {
            logger.error("[\(label)] CreateProcessTap failed: \(tapSt)")
            return
        }

        let tapUID = tapDesc.uuid.uuidString
        let aggUID = UUID().uuidString
        let aggProps: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Fader-Diag-\(label)",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID
                ]
            ]
        ]

        var aggID = AudioObjectID(kAudioObjectUnknown)
        let aggSt = AudioHardwareCreateAggregateDevice(aggProps as CFDictionary, &aggID)
        guard aggSt == kAudioHardwareNoError else {
            logger.error("[\(label)] CreateAggregateDevice failed: \(aggSt)")
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            logger.error("[\(label)] No HAL output component")
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        var au: AudioUnit?
        var st = AudioComponentInstanceNew(component, &au)
        guard st == noErr, let au else {
            logger.error("[\(label)] AudioComponentInstanceNew failed: \(st)")
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            return
        }

        var devID = aggID
        st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size))

        var enableIO: UInt32 = 1
        st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &enableIO, UInt32(MemoryLayout<UInt32>.size))

        // Read the hardware format from input element 1 and set it on output element 0
        var inputFmt = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        st = AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 1, &inputFmt, &fmtSize)
        logger.info("[\(label)] AUHAL input1 format: rate=\(inputFmt.mSampleRate) ch=\(inputFmt.mChannelsPerFrame)")

        var outputFmt = AudioStreamBasicDescription()
        st = AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 0, &outputFmt, &fmtSize)
        logger.info("[\(label)] AUHAL output0 format: rate=\(outputFmt.mSampleRate) ch=\(outputFmt.mChannelsPerFrame)")

        let ctx = DiagContext(au: au)
        var callbackStruct = AURenderCallbackStruct(
            inputProc: { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
                let ctx = Unmanaged<DiagContext>.fromOpaque(inRefCon).takeUnretainedValue()
                guard let ioData else { return noErr }
                let status = AudioUnitRender(ctx.au, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData)
                if status == noErr { ctx.callCount += 1 }
                return status
            },
            inputProcRefCon: Unmanaged.passUnretained(ctx).toOpaque()
        )
        st = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        st = AudioUnitInitialize(au)
        logger.info("[\(label)] AudioUnitInitialize: status=\(st)")

        st = AudioOutputUnitStart(au)
        logger.info("[\(label)] AudioOutputUnitStart: status=\(st)")

        let runAfter = readIsRunning(deviceID: aggID)
        logger.info("[\(label)] Aggregate isRunning AFTER AUHAL start: \(runAfter)")

        let cleanupAggID = aggID
        let cleanupTapID = tapID
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            logger.warning("[\(label)] Result: RenderCB called \(ctx.callCount) times in 2s")
            let aggRunFinal = readIsRunning(deviceID: cleanupAggID)
            logger.info("[\(label)] Aggregate isRunning at check time: \(aggRunFinal)")

            AudioOutputUnitStop(ctx.au)
            AudioUnitUninitialize(ctx.au)
            AudioComponentInstanceDispose(ctx.au)
            AudioHardwareDestroyAggregateDevice(cleanupAggID)
            AudioHardwareDestroyProcessTap(cleanupTapID)
            logger.info("[\(label)] Cleanup done")
        }
    }
}

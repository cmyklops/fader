import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import os.lock
import os

private let logger = Logger(subsystem: "com.mattwesdock.Fader", category: "AppAudioTap")

/// Manages an audio tap for a single application process.
/// Intercepts the process's audio output, scales samples by a volume
/// factor, and routes the result to the current default output device.
final class AppAudioTap {

    // MARK: - Properties

    let process: AudioProcess

    /// Linear amplitude scalar [0, 1] derived from the dB-linear slider.
    /// Written from the main thread, read from the real-time audio thread.
    /// Uses an atomic store/load pattern via a lock-protected backing value.
    var amplitude: Float {
        get {
            os_unfair_lock_lock(&_lock)
            defer { os_unfair_lock_unlock(&_lock) }
            return _amplitude
        }
        set {
            os_unfair_lock_lock(&_lock)
            _amplitude = newValue
            _fadeTarget = newValue
            _fadeStep = 0
            os_unfair_lock_unlock(&_lock)
        }
    }

    var isMuted: Bool {
        get {
            os_unfair_lock_lock(&_lock)
            defer { os_unfair_lock_unlock(&_lock) }
            return _isMuted
        }
        set {
            os_unfair_lock_lock(&_lock)
            _isMuted = newValue
            os_unfair_lock_unlock(&_lock)
        }
    }

    // MARK: - Private

    private var _lock = os_unfair_lock()
    private var _amplitude: Float = 1.0
    private var _fadeTarget: Float = 1.0
    private var _fadeStep: Float = 0.0
    private var _isMuted: Bool = false
    private var _ioProcCallCount: UInt64 = 0

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    // MARK: - Init / Deinit

    init(process: AudioProcess, initialAmplitude: Float = 1.0) {
        self.process = process
        self._amplitude = initialAmplitude
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Creates the process tap, wraps it in a private aggregate device,
    /// attaches an IOProc, and starts the device.
    func start() throws {
        // 1. Create a CATapDescription targeting this process.
        //    muteBehavior .muted means the process's audio is intercepted —
        //    it no longer goes directly to the hardware. We read it, scale it,
        //    and re-route it ourselves.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: process.allObjectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.isPrivate = true
        tapDescription.isExclusive = false
        tapDescription.isMixdown = true
        tapDescription.isMono = false

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &createdTapID)
        logger.info("CreateProcessTap for \(self.process.name) (objIDs=\(self.process.allObjectIDs)): status=\(tapStatus), tapID=\(createdTapID)")
        guard tapStatus == kAudioHardwareNoError, createdTapID != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        tapID = createdTapID

        // 2. Get the default output device UID so we can include it in the aggregate.
        var defaultOutputID = AudioObjectID(kAudioObjectUnknown)
        var defaultOutputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var defaultOutputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddr,
            0, nil,
            &defaultOutputSize,
            &defaultOutputID
        )

        // Get the output device UID string.
        var outputUIDAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputUIDRef: Unmanaged<CFString>?
        var outputUIDSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(
            defaultOutputID,
            &outputUIDAddr,
            0, nil,
            &outputUIDSize,
            &outputUIDRef
        )
        guard let outputUID = outputUIDRef?.takeRetainedValue() as String? else {
            logger.error("Failed to get output device UID")
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw TapError.tapCreationFailed(kAudioHardwareUnspecifiedError)
        }

        logger.info("Output device: id=\(defaultOutputID), uid=\(outputUID)")

        // 3. Wrap the tap in a private aggregate device with the real output device,
        //    so the IOProc can read tapped audio and write it to hardware.
        let tapUID = tapDescription.uuid.uuidString
        let aggUID = UUID().uuidString
        let aggProps: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Fader-\(self.process.pid)",
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

        logger.info("Creating aggregate device with tapUID=\(tapUID), outputUID=\(outputUID)")
        var createdAggID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggProps as CFDictionary, &createdAggID)
        logger.info("CreateAggregateDevice: status=\(aggStatus), aggID=\(createdAggID)")
        guard aggStatus == kAudioHardwareNoError, createdAggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw TapError.aggregateDeviceCreationFailed(aggStatus)
        }
        aggregateDeviceID = createdAggID

        // 4. Attach an IOProc and start the aggregate device.
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) {
            [weak self] (inNow, inInputData, inInputTime, outOutputData, inOutputTime) in
            self?.ioProc(inputData: inInputData, outputData: outOutputData)
        }
        logger.info("CreateIOProcIDWithBlock: status=\(procStatus)")

        guard procStatus == kAudioHardwareNoError, let validProcID = procID else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            aggregateDeviceID = kAudioObjectUnknown
            tapID = kAudioObjectUnknown
            throw TapError.ioProcCreationFailed(procStatus)
        }
        ioProcID = validProcID

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        logger.info("AudioDeviceStart: status=\(startStatus)")
        if startStatus != kAudioHardwareNoError {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID!)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            ioProcID = nil
            aggregateDeviceID = kAudioObjectUnknown
            tapID = kAudioObjectUnknown
            throw TapError.startFailed(startStatus)
        }
    }

    /// Smoothly ramp amplitude to `target` over `duration` seconds via the IOProc.
    func fadeToAmplitude(_ target: Float, duration: TimeInterval = 0.5) {
        os_unfair_lock_lock(&_lock)
        let current = _amplitude
        // ~86 IOProc callbacks/sec (44100 / 512)
        let totalSteps = max(Float(duration) * 86.0, 1.0)
        if abs(current - target) < 0.001 {
            _amplitude = target
            _fadeTarget = target
            _fadeStep = 0
        } else {
            _fadeTarget = target
            _fadeStep = (target - current) / totalSteps
        }
        os_unfair_lock_unlock(&_lock)
    }

    /// Stops the tap and releases all CoreAudio resources.
    func stop() {
        if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - Audio Thread (real-time, no allocations, no ObjC)

    private func ioProc(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        os_unfair_lock_lock(&_lock)
        // Apply fade stepping toward target amplitude.
        if _fadeStep != 0 {
            _amplitude += _fadeStep
            if (_fadeStep > 0 && _amplitude >= _fadeTarget) || (_fadeStep < 0 && _amplitude <= _fadeTarget) {
                _amplitude = _fadeTarget
                _fadeStep = 0
            }
        }
        let scale: Float = _isMuted ? 0.0 : _amplitude
        _ioProcCallCount += 1
        let callCount = _ioProcCallCount
        os_unfair_lock_unlock(&_lock)

        if callCount == 1 || callCount % 1000 == 0 {
            let inCount = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData)).count
            let outCount = UnsafeMutableAudioBufferListPointer(outputData).count
            logger.info("IOProc #\(callCount): scale=\(scale), inBufs=\(inCount), outBufs=\(outCount)")
        }

        let inputABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputABL = UnsafeMutableAudioBufferListPointer(outputData)

        let bufferCount = min(inputABL.count, outputABL.count)
        for i in 0..<bufferCount {
            let srcBuf = inputABL[i]
            let dstBuf = outputABL[i]
            guard let srcData = srcBuf.mData, let dstData = dstBuf.mData else { continue }
            let byteCount = Int(min(srcBuf.mDataByteSize, dstBuf.mDataByteSize))
            let frameCount = byteCount / MemoryLayout<Float32>.size

            if scale == 1.0 {
                memcpy(dstData, srcData, byteCount)
            } else if scale == 0.0 {
                memset(dstData, 0, Int(dstBuf.mDataByteSize))
            } else {
                let src = srcData.assumingMemoryBound(to: Float32.self)
                let dst = dstData.assumingMemoryBound(to: Float32.self)
                vDSP_vsmul(src, 1, [scale], dst, 1, vDSP_Length(frameCount))
            }
        }
    }

    // MARK: - Errors

    enum TapError: Error, LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let code):
                return "Failed to create process tap (OSStatus \(code))."
            case .aggregateDeviceCreationFailed(let code):
                return "Failed to create aggregate device (OSStatus \(code))."
            case .ioProcCreationFailed(let code):
                return "Failed to create IOProc (OSStatus \(code))."
            case .startFailed(let code):
                return "Failed to start audio device (OSStatus \(code))."
            }
        }
    }
}

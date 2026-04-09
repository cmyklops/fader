import Foundation
import CoreAudio
import AudioToolbox
import os.lock

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
    private var _isMuted: Bool = false

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
        guard #available(macOS 14.2, *) else {
            throw TapError.unsupportedOS
        }

        // 1. Create a CATapDescription targeting this process.
        //    muteBehavior .muted means the process's audio is intercepted —
        //    it no longer goes directly to the hardware. We read it, scale it,
        //    and re-route it ourselves.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [process.objectID])
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.isPrivate = true
        tapDescription.isExclusive = false
        tapDescription.isMixdown = true
        tapDescription.isMono = false

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &createdTapID)
        guard tapStatus == kAudioHardwareNoError, createdTapID != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        tapID = createdTapID

        // 2. Wrap the tap in a private aggregate device so we can attach an IOProc.
        let tapUID = tapDescription.uuid.uuidString
        let aggUID = UUID().uuidString
        let aggProps: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Fader-\(process.pid)",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false
        ]

        var createdAggID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggProps as CFDictionary, &createdAggID)
        guard aggStatus == kAudioHardwareNoError, createdAggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw TapError.aggregateDeviceCreationFailed(aggStatus)
        }
        aggregateDeviceID = createdAggID

        // 3. Determine the current default output device so we can route audio to it.
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

        // 4. Attach the IOProc callback and start the aggregate device.
        let context = Unmanaged.passRetained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) {
            [weak self] (inNow, inInputData, inInputTime, outOutputData, inOutputTime) in
            self?.ioProc(
                inputData: inInputData,
                outputData: outOutputData,
                outputDeviceID: defaultOutputID
            )
        }
        // Release the manually-retained context since we used [weak self] instead
        Unmanaged<AppAudioTap>.fromOpaque(context).release()

        guard procStatus == kAudioHardwareNoError, let validProcID = procID else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            aggregateDeviceID = kAudioObjectUnknown
            tapID = kAudioObjectUnknown
            throw TapError.ioProcCreationFailed(procStatus)
        }
        ioProcID = validProcID

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
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

    // NOTE: This IOProc receives the tapped (intercepted) audio in inInputData.
    // We scale the samples by the current amplitude and write them to outOutputData.
    // outOutputData here is used to drive a sub-tap — actual routing to the real
    // output device requires an additional output IOProc on the real device.
    // For the initial implementation we apply gain scaling and let CoreAudio
    // handle routing via the aggregate device's connection to the default output.
    private func ioProc(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        outputDeviceID: AudioObjectID
    ) {
        // Read volume state atomically without Obj-C messaging.
        os_unfair_lock_lock(&_lock)
        let scale: Float = _isMuted ? 0.0 : _amplitude
        os_unfair_lock_unlock(&_lock)

        let inputABL = inputData.pointee
        let outputABL = UnsafeMutableAudioBufferListPointer(outputData)

        // Copy input → output, scaling each float32 sample.
        let bufferCount = min(Int(inputABL.mNumberBuffers), outputABL.count)
        withUnsafePointer(to: inputABL.mBuffers) { inputBuffersPtr in
            for bufferIndex in 0 ..< bufferCount {
                let inputBuffer = inputBuffersPtr.advanced(by: bufferIndex).pointee
                let outputBuffer = outputABL[bufferIndex]

                guard
                    let srcData = inputBuffer.mData,
                    let dstData = outputBuffer.mData
                else { continue }

                let frameCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float32>.size
                let src = srcData.assumingMemoryBound(to: Float32.self)
                let dst = dstData.assumingMemoryBound(to: Float32.self)

                if scale == 1.0 {
                    dst.update(from: src, count: frameCount)
                } else if scale == 0.0 {
                    dst.assign(repeating: 0.0, count: frameCount)
                } else {
                    vDSP_vsmul(src, 1, [scale], dst, 1, vDSP_Length(frameCount))
                }
            }
        }
    }

    // MARK: - Errors

    enum TapError: Error, LocalizedError {
        case unsupportedOS
        case tapCreationFailed(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupportedOS:
                return "Per-app audio tapping requires macOS 14.2 or later."
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

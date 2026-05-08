import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import os

private let logger = Logger(subsystem: "com.mattwesdock.Fader", category: "AppAudioTap")

/// Manages an audio tap for a single application process.
final class AppAudioTap {

    // MARK: - Properties

    let process: AudioProcess
    private let parameters: RealtimeTapParameters

    var amplitude: Float {
        get { parameters.amplitude }
        set { parameters.amplitude = newValue }
    }

    var isMuted: Bool {
        get { parameters.isMuted }
        set { parameters.isMuted = newValue }
    }

    private(set) var status: TapStatus = .stopped
    private(set) var configuration: TapConfiguration?

    // MARK: - Private

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat = AudioStreamBasicDescription()

    private var renderGain: Float
    private var renderTargetGain: Float
    private var renderRampRemaining = 0
    private var renderRampStep: Float = 0.0
    private var renderRampSamples = 256

    // MARK: - Init / Deinit

    init(process: AudioProcess, initialAmplitude: Float = 1.0, isMuted: Bool = false) {
        self.process = process
        self.parameters = RealtimeTapParameters(amplitude: initialAmplitude, isMuted: isMuted)
        let initialScale = isMuted ? 0.0 : initialAmplitude
        self.renderGain = initialScale
        self.renderTargetGain = initialScale
    }

    deinit {
        _ = stop()
    }

    // MARK: - Lifecycle

    func start() throws {
        _ = stop()

        let (defaultOutputID, outputUID) = try Self.defaultOutputDevice()
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: process.allObjectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.isPrivate = true
        tapDescription.isExclusive = false
        tapDescription.isMixdown = true
        tapDescription.isMono = false

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &createdTapID)
        guard tapStatus == kAudioHardwareNoError, createdTapID != kAudioObjectUnknown else {
            throw TapError(.tapCreation, status: tapStatus)
        }
        tapID = createdTapID

        do {
            tapFormat = try readTapFormat()
            try validateTapFormat(tapFormat)
        } catch {
            _ = stop()
            throw error
        }

        let sampleRate = tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : 44_100
        renderRampSamples = max(Int(sampleRate * 0.008), 64)

        let tapUID = tapDescription.uuid.uuidString
        let aggUID = UUID().uuidString
        let aggProps: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Fader-\(process.pid)",
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

        var createdAggID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggProps as CFDictionary, &createdAggID)
        guard aggStatus == kAudioHardwareNoError, createdAggID != kAudioObjectUnknown else {
            _ = stop()
            throw TapError(.aggregateDeviceCreation, status: aggStatus)
        }
        aggregateDeviceID = createdAggID

        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) {
            [unowned self] _, inputData, _, outputData, _ in
            self.ioProc(inputData: inputData, outputData: outputData)
        }
        guard procStatus == kAudioHardwareNoError, let validProcID = procID else {
            _ = stop()
            throw TapError(.ioProcCreation, status: procStatus)
        }
        ioProcID = validProcID

        let startStatus = AudioDeviceStart(aggregateDeviceID, validProcID)
        guard startStatus == kAudioHardwareNoError else {
            _ = stop()
            throw TapError(.deviceStart, status: startStatus)
        }

        let config = TapConfiguration(
            processPID: process.pid,
            objectIDSignature: process.objectIDSignature,
            outputDeviceUID: outputUID
        )
        configuration = config
        status = .running(config)
        logger.info("Started tap for \(self.process.name) outputDevice=\(defaultOutputID) uid=\(outputUID)")
    }

    @discardableResult
    func stop() -> [TapError] {
        var errors: [TapError] = []

        if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            let stopStatus = AudioDeviceStop(aggregateDeviceID, procID)
            if stopStatus != kAudioHardwareNoError {
                errors.append(TapError(.deviceStop, status: stopStatus))
            }
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            if destroyStatus != kAudioHardwareNoError {
                errors.append(TapError(.ioProcDestroy, status: destroyStatus))
            }
            ioProcID = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            let destroyStatus = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if destroyStatus != kAudioHardwareNoError {
                errors.append(TapError(.aggregateDeviceDestroy, status: destroyStatus))
            }
            aggregateDeviceID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            let destroyStatus = AudioHardwareDestroyProcessTap(tapID)
            if destroyStatus != kAudioHardwareNoError {
                errors.append(TapError(.tapDestroy, status: destroyStatus))
            }
            tapID = kAudioObjectUnknown
        }

        configuration = nil
        status = errors.isEmpty ? .stopped : .failed(errors.map(\.localizedDescription).joined(separator: "\n"))
        return errors
    }

    // MARK: - CoreAudio Helpers

    static func defaultOutputDevice() throws -> (AudioObjectID, String) {
        var defaultOutputID = AudioObjectID(kAudioObjectUnknown)
        var defaultOutputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var defaultOutputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outputStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddr,
            0, nil,
            &defaultOutputSize,
            &defaultOutputID
        )
        guard outputStatus == kAudioHardwareNoError, defaultOutputID != kAudioObjectUnknown else {
            throw TapError(.defaultOutputDevice, status: outputStatus)
        }

        var outputUIDAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputUIDRef: Unmanaged<CFString>?
        var outputUIDSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = AudioObjectGetPropertyData(
            defaultOutputID,
            &outputUIDAddr,
            0, nil,
            &outputUIDSize,
            &outputUIDRef
        )
        guard uidStatus == kAudioHardwareNoError,
              let outputUID = outputUIDRef?.takeRetainedValue() as String? else {
            throw TapError(.outputDeviceUID, status: uidStatus)
        }

        return (defaultOutputID, outputUID)
    }

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == kAudioHardwareNoError else {
            throw TapError(.tapFormat, status: status)
        }
        return format
    }

    private func validateTapFormat(_ format: AudioStreamBasicDescription) throws {
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard format.mFormatID == kAudioFormatLinearPCM,
              isFloat,
              format.mBitsPerChannel == 32 else {
            let detail = "Expected 32-bit float PCM, got formatID \(format.mFormatID), flags \(format.mFormatFlags), bits \(format.mBitsPerChannel)."
            throw TapError(.unsupportedFormat, status: kAudioHardwareUnsupportedOperationError, detail: detail)
        }
    }

    // MARK: - Audio Thread

    private func ioProc(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let target = parameters.targetScale
        if target != renderTargetGain {
            renderTargetGain = target
            renderRampRemaining = renderRampSamples
            renderRampStep = (target - renderGain) / Float(renderRampRemaining)
        }

        let inputABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputABL = UnsafeMutableAudioBufferListPointer(outputData)
        let bufferCount = min(inputABL.count, outputABL.count)
        var consumedRampSamples = 0

        for i in 0..<bufferCount {
            let srcBuf = inputABL[i]
            let dstBuf = outputABL[i]
            guard let dstData = dstBuf.mData else { continue }
            guard let srcData = srcBuf.mData else {
                memset(dstData, 0, Int(dstBuf.mDataByteSize))
                continue
            }

            let byteCount = Int(min(srcBuf.mDataByteSize, dstBuf.mDataByteSize))
            let sampleCount = byteCount / MemoryLayout<Float32>.size

            if byteCount == 0 || byteCount % MemoryLayout<Float32>.size != 0 {
                memset(dstData, 0, Int(dstBuf.mDataByteSize))
                continue
            }

            let src = srcData.assumingMemoryBound(to: Float32.self)
            let dst = dstData.assumingMemoryBound(to: Float32.self)

            if renderRampRemaining > 0 {
                applyRamp(src: src, dst: dst, sampleCount: sampleCount)
                consumedRampSamples = max(consumedRampSamples, min(sampleCount, renderRampRemaining))
            } else if renderGain == 1.0 {
                memcpy(dstData, srcData, byteCount)
            } else if renderGain == 0.0 {
                memset(dstData, 0, byteCount)
            } else {
                var scale = renderGain
                withUnsafePointer(to: &scale) { scalePointer in
                    vDSP_vsmul(src, 1, scalePointer, dst, 1, vDSP_Length(sampleCount))
                }
            }

            if dstBuf.mDataByteSize > byteCount {
                memset(dstData.advanced(by: byteCount), 0, Int(dstBuf.mDataByteSize) - byteCount)
            }
        }

        if renderRampRemaining > 0 {
            renderRampRemaining -= consumedRampSamples
            if renderRampRemaining <= 0 {
                renderGain = renderTargetGain
                renderRampStep = 0
                renderRampRemaining = 0
            } else {
                renderGain += renderRampStep * Float(consumedRampSamples)
            }
        }

        if outputABL.count > bufferCount {
            for i in bufferCount..<outputABL.count {
                if let dstData = outputABL[i].mData {
                    memset(dstData, 0, Int(outputABL[i].mDataByteSize))
                }
            }
        }
    }

    private func applyRamp(
        src: UnsafePointer<Float32>,
        dst: UnsafeMutablePointer<Float32>,
        sampleCount: Int
    ) {
        var gain = renderGain
        let rampedSamples = min(sampleCount, renderRampRemaining)

        for index in 0..<rampedSamples {
            dst[index] = src[index] * gain
            gain += renderRampStep
        }

        if rampedSamples < sampleCount {
            let stableGain = renderTargetGain
            if stableGain == 1.0 {
                memcpy(dst.advanced(by: rampedSamples), src.advanced(by: rampedSamples), (sampleCount - rampedSamples) * MemoryLayout<Float32>.size)
            } else if stableGain == 0.0 {
                memset(dst.advanced(by: rampedSamples), 0, (sampleCount - rampedSamples) * MemoryLayout<Float32>.size)
            } else {
                var scale = stableGain
                withUnsafePointer(to: &scale) { scalePointer in
                    vDSP_vsmul(
                        src.advanced(by: rampedSamples),
                        1,
                        scalePointer,
                        dst.advanced(by: rampedSamples),
                        1,
                        vDSP_Length(sampleCount - rampedSamples)
                    )
                }
            }
        }
    }
}

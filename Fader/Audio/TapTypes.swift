import Foundation
import CoreAudio
import Atomics

struct TapConfiguration: Equatable, Codable {
    let processPID: pid_t
    let objectIDSignature: String
    let outputDeviceUID: String
}

enum TapStatus: Equatable, Codable {
    case stopped
    case running(TapConfiguration)
    case failed(String)
}

struct TapError: Error, LocalizedError, Equatable, Codable {
    enum Operation: String, Codable {
        case defaultOutputDevice
        case outputDeviceUID
        case tapCreation
        case tapFormat
        case aggregateDeviceCreation
        case ioProcCreation
        case deviceStart
        case deviceStop
        case ioProcDestroy
        case aggregateDeviceDestroy
        case tapDestroy
        case listenerRegistration
        case unsupportedFormat
    }

    let operation: Operation
    let status: OSStatus
    let detail: String

    init(_ operation: Operation, status: OSStatus, detail: String = "") {
        self.operation = operation
        self.status = status
        self.detail = detail
    }

    var errorDescription: String? {
        let message: String
        switch operation {
        case .defaultOutputDevice:
            message = "Fader could not find the default output device."
        case .outputDeviceUID:
            message = "Fader could not read the output device identifier."
        case .tapCreation:
            message = "Fader could not create a process audio tap."
        case .tapFormat:
            message = "Fader could not read the tapped audio format."
        case .aggregateDeviceCreation:
            message = "Fader could not create an aggregate audio device."
        case .ioProcCreation:
            message = "Fader could not attach the audio processing callback."
        case .deviceStart:
            message = "Fader could not start audio processing."
        case .deviceStop:
            message = "Fader could not stop audio processing cleanly."
        case .ioProcDestroy:
            message = "Fader could not release the audio processing callback cleanly."
        case .aggregateDeviceDestroy:
            message = "Fader could not release the aggregate audio device cleanly."
        case .tapDestroy:
            message = "Fader could not release the process audio tap cleanly."
        case .listenerRegistration:
            message = "Fader could not observe an audio system change."
        case .unsupportedFormat:
            message = "Fader received an unsupported audio format."
        }

        if detail.isEmpty {
            return "\(message) OSStatus \(status)."
        }
        return "\(message) \(detail) OSStatus \(status)."
    }
}

final class RealtimeTapParameters {
    private let amplitudeBits: ManagedAtomic<UInt32>
    private let muted: ManagedAtomic<Bool>

    init(amplitude: Float = 1.0, isMuted: Bool = false) {
        amplitudeBits = ManagedAtomic(Self.clamp(amplitude).bitPattern)
        muted = ManagedAtomic(isMuted)
    }

    var amplitude: Float {
        get {
            Float(bitPattern: amplitudeBits.load(ordering: .relaxed))
        }
        set {
            amplitudeBits.store(Self.clamp(newValue).bitPattern, ordering: .relaxed)
        }
    }

    var isMuted: Bool {
        get {
            muted.load(ordering: .relaxed)
        }
        set {
            muted.store(newValue, ordering: .relaxed)
        }
    }

    var targetScale: Float {
        isMuted ? 0.0 : amplitude
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, 0.0), 1.0)
    }
}

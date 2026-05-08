import Foundation
import CoreGraphics

struct DiagnosticsReport: Codable, Equatable {
    struct Permissions: Codable, Equatable {
        let screenRecording: String
        let systemAudioCaptureUsageDescriptionPresent: Bool
        let microphoneUsageDescriptionPresent: Bool
    }

    struct TapSnapshot: Codable, Equatable, Identifiable {
        let id: pid_t
        let name: String
        let pid: pid_t
        let bundleID: String?
        let objectIDSignature: String
        let outputDeviceUID: String?
        let isPlayingAudio: Bool
        let isMuted: Bool
        let sliderValue: Float
        let status: String
    }

    let generatedAt: Date
    let appVersion: String
    let appBuild: String
    let macOSVersion: String
    let defaultOutputDeviceUID: String?
    let permissions: Permissions
    let taps: [TapSnapshot]
    let recentErrors: [String]

    static func permissions(bundle: Bundle = .main) -> Permissions {
        Permissions(
            screenRecording: CGPreflightScreenCaptureAccess() ? "granted" : "not granted or not needed",
            systemAudioCaptureUsageDescriptionPresent: bundle.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") != nil,
            microphoneUsageDescriptionPresent: bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
        )
    }

    var jsonData: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }
    }

    var textSummary: String {
        var lines: [String] = [
            "Fader Diagnostics",
            "Generated: \(generatedAt)",
            "App: \(appVersion) (\(appBuild))",
            "macOS: \(macOSVersion)",
            "Default Output Device UID: \(defaultOutputDeviceUID ?? "unknown")",
            "Screen Recording: \(permissions.screenRecording)",
            "NSAudioCaptureUsageDescription: \(permissions.systemAudioCaptureUsageDescriptionPresent ? "present" : "missing")",
            "NSMicrophoneUsageDescription: \(permissions.microphoneUsageDescriptionPresent ? "present" : "missing")",
            "",
            "Active Taps:"
        ]

        if taps.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: taps.map {
                "- \($0.name) pid=\($0.pid) bundle=\($0.bundleID ?? "unknown") playing=\($0.isPlayingAudio) muted=\($0.isMuted) slider=\($0.sliderValue) objects=\($0.objectIDSignature) output=\($0.outputDeviceUID ?? "unknown") status=\($0.status)"
            })
        }

        lines.append("")
        lines.append("Recent Errors:")
        if recentErrors.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: recentErrors.map { "- \($0)" })
        }

        return lines.joined(separator: "\n")
    }
}

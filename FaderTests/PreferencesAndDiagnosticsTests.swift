import XCTest
import CoreAudio
@testable import Fader

final class PreferencesAndDiagnosticsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.mattwesdock.FaderTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testMissingVolumeDefaultsToUnity() {
        XCTAssertFalse(AppVolumePreferences.hasSavedVolume(bundleID: "app.test", defaults: defaults))
        XCTAssertEqual(AppVolumePreferences.load(bundleID: "app.test", defaults: defaults), 1.0)
    }

    func testZeroVolumePersists() {
        AppVolumePreferences.save(bundleID: "app.test", sliderValue: 0.0, defaults: defaults)
        XCTAssertTrue(AppVolumePreferences.hasSavedVolume(bundleID: "app.test", defaults: defaults))
        XCTAssertEqual(AppVolumePreferences.load(bundleID: "app.test", defaults: defaults), 0.0)
    }

    func testMutePersists() {
        AppVolumePreferences.saveMute(bundleID: "app.test", isMuted: true, defaults: defaults)
        XCTAssertTrue(AppVolumePreferences.loadMute(bundleID: "app.test", defaults: defaults))
    }

    func testObjectIDSignatureIsStableAndSorted() {
        let ids: [AudioObjectID] = [42, 7, 19]
        XCTAssertEqual(AudioProcess.objectIDSignature(for: ids), "7,19,42")
    }

    func testDiagnosticsReportContainsCoreSections() throws {
        let report = DiagnosticsReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "1.0",
            appBuild: "1",
            macOSVersion: "14.2.0",
            defaultOutputDeviceUID: "OutputUID",
            permissions: .init(
                screenRecording: "granted",
                systemAudioCaptureUsageDescriptionPresent: true,
                microphoneUsageDescriptionPresent: true
            ),
            taps: [
                .init(
                    id: 123,
                    name: "Player",
                    pid: 123,
                    bundleID: "app.player",
                    objectIDSignature: "1,2",
                    outputDeviceUID: "OutputUID",
                    isPlayingAudio: true,
                    isMuted: false,
                    sliderValue: 0.5,
                    status: "running"
                )
            ],
            recentErrors: ["Example error"]
        )

        let summary = report.textSummary
        XCTAssertTrue(summary.contains("Fader Diagnostics"))
        XCTAssertTrue(summary.contains("Player"))
        XCTAssertTrue(summary.contains("Example error"))
        XCTAssertFalse(try report.jsonData.isEmpty)
    }
}

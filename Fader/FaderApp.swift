import SwiftUI
import AppKit

@MainActor
final class FaderAppDelegate: NSObject, NSApplicationDelegate {
    static weak var tapManager: AudioTapManager?

    func applicationWillTerminate(_ notification: Notification) {
        Self.tapManager?.shutdown()
    }
}

@main
struct FaderApp: App {
    @NSApplicationDelegateAdaptor(FaderAppDelegate.self) private var appDelegate
    @State private var tapManager: AudioTapManager

    init() {
        let manager = AudioTapManager(startImmediately: !ProcessInfo.processInfo.isRunningUnitTests)
        _tapManager = State(initialValue: manager)
        FaderAppDelegate.tapManager = manager
    }

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environment(tapManager)
                .onAppear {
                    FaderAppDelegate.tapManager = tapManager
                }
        } label: {
            Label("Fader", systemImage: "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)
    }
}

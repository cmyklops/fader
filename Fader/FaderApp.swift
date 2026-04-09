import SwiftUI

@main
struct FaderApp: App {
    @State private var tapManager = AudioTapManager()

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environment(tapManager)
        } label: {
            Label("Fader", systemImage: "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)
    }
}

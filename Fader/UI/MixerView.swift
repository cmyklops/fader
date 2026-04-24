import SwiftUI
import ServiceManagement

// MARK: - Vertical Slider (NSSlider wrapper)

struct VerticalSlider: NSViewRepresentable {
    @Binding var value: Float

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: 1,
                              target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isVertical = true
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        if abs(slider.floatValue - value) > 0.001 {
            slider.floatValue = value
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    final class Coordinator: NSObject {
        var value: Binding<Float>
        init(value: Binding<Float>) { self.value = value }
        @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.floatValue
        }
    }
}

struct MixerView: View {
    @Environment(AudioTapManager.self) private var tapManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("fader.verticalSliders") private var verticalSliders = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: verticalSliders ? max(CGFloat(tapManager.entries.count) * 56 + 24, 140) : 320)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.2), value: verticalSliders)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.secondary)
            Text("Fader")
                .font(.headline)
            Spacer()
            Button {
                tapManager.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh app list")
            Button {
                verticalSliders.toggle()
            } label: {
                Image(systemName: verticalSliders ? "slider.horizontal.3" : "slider.vertical.3")
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(verticalSliders ? "Switch to horizontal" : "Switch to vertical")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Fader")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if tapManager.entries.isEmpty {
            emptyState
        } else if verticalSliders {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(tapManager.entries) { entry in
                        AppVolumeColumn(entry: entry)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 240)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tapManager.entries) { entry in
                        AppVolumeRow(entry: entry)
                        if entry.id != tapManager.entries.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
        }

        if let error = tapManager.lastError {
            errorBanner(error)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No audio apps detected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Play audio in any app to see it here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .foregroundStyle(.secondary)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        print("[Fader] Launch at login failed: \(error)")
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Per-App Column (Vertical)

struct AppVolumeColumn: View {
    @Bindable var entry: MixerEntry

    var body: some View {
        VStack(spacing: 6) {
            muteButton

            VerticalSlider(value: $entry.sliderValue)
                .frame(width: 28, height: 140)
                .disabled(entry.isMuted)

            Text(entry.displayLabel)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            appIcon
        }
        .frame(width: 48)
        .opacity(entry.isMuted ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: entry.isMuted)
        .animation(.easeInOut(duration: 0.2), value: entry.isPlayingAudio)
    }

    private var appIcon: some View {
        Group {
            if let icon = entry.process.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(entry.isPlayingAudio ? 1.0 : 0.55)
        .saturation(entry.isPlayingAudio ? 1.0 : 0.4)
        .help(entry.isPlayingAudio ? entry.process.name : "\(entry.process.name) (paused)")
    }

    private var muteButton: some View {
        Button {
            entry.isMuted.toggle()
        } label: {
            Image(systemName: entry.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13))
                .foregroundStyle(entry.isMuted ? .red : .secondary)
                .frame(width: 22, height: 22)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(entry.isMuted ? "Unmute" : "Mute")
    }
}

// MARK: - Per-App Row (Horizontal)

struct AppVolumeRow: View {
    @Bindable var entry: MixerEntry

    var body: some View {
        HStack(spacing: 10) {
            appIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.process.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(entry.displayLabel)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 80, alignment: .leading)

            Slider(value: $entry.sliderValue, in: 0...1)
                .frame(minWidth: 80)
                .disabled(entry.isMuted)

            muteButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .opacity(entry.isMuted ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: entry.isMuted)
        .animation(.easeInOut(duration: 0.2), value: entry.isPlayingAudio)
    }

    private var appIcon: some View {
        Group {
            if let icon = entry.process.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(entry.isPlayingAudio ? 1.0 : 0.55)
        .saturation(entry.isPlayingAudio ? 1.0 : 0.4)
    }

    private var muteButton: some View {
        Button {
            entry.isMuted.toggle()
        } label: {
            Image(systemName: entry.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13))
                .foregroundStyle(entry.isMuted ? .red : .secondary)
                .frame(width: 22, height: 22)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(entry.isMuted ? "Unmute" : "Mute")
    }
}

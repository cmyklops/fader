import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

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
        @MainActor @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.floatValue
        }
    }
}

struct MixerView: View {
    @Environment(AudioTapManager.self) private var tapManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showingDiagnostics = false
    @AppStorage("fader.verticalSliders") private var verticalSliders = false

    var body: some View {
        VStack(spacing: 12) {
            header
            content
            footer
        }
        .padding(12)
        .frame(width: verticalSliders ? max(CGFloat(tapManager.entries.count) * 64 + 28, 260) : 380)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.2), value: verticalSliders)
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsView()
                .environment(tapManager)
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.24), lineWidth: 1)
                    )
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text("Fader")
                    .font(.system(size: 17, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(tapManager.entries.isEmpty ? Color.secondary : Color.green)
                        .frame(width: 6, height: 6)
                    Text(headerStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer(minLength: 10)

            HStack(spacing: 4) {
                GlassIconButton(systemName: "arrow.clockwise", helpTitle: "Refresh app list") {
                    tapManager.refresh()
                }
                GlassIconButton(systemName: "stethoscope", helpTitle: "Diagnostics") {
                    showingDiagnostics = true
                }
                GlassIconButton(
                    systemName: verticalSliders ? "rectangle.split.1x2" : "rectangle.split.2x1",
                    helpTitle: verticalSliders ? "Switch to horizontal" : "Switch to vertical",
                    isActive: verticalSliders
                ) {
                    verticalSliders.toggle()
                }
                GlassIconButton(systemName: "power", helpTitle: "Quit Fader", tint: .red) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(4)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 10) {
            if tapManager.entries.isEmpty {
                emptyState
            } else if verticalSliders {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(tapManager.entries) { entry in
                            AppVolumeColumn(entry: entry)
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 250)
                .scrollIndicators(.hidden)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(tapManager.entries) { entry in
                            AppVolumeRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 420)
                .scrollIndicators(.automatic)
            }

            if let error = tapManager.lastError {
                errorBanner(error)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 54, height: 54)
                Image(systemName: "speaker.slash")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text("No audio apps detected")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Start playback in an app to add it here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var headerStatus: String {
        let count = tapManager.entries.count
        guard count > 0 else { return "Idle" }
        let active = tapManager.entries.filter(\.isPlayingAudio).count
        return "\(active)/\(count) active"
    }

    private var footer: some View {
        HStack(spacing: 10) {
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
            Spacer()
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.thinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1)
        )
    }
}

// MARK: - Shared Chrome

struct FaderPanelBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.20), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 14)
    }
}

struct GlassIconButton: View {
    let systemName: String
    let helpTitle: String
    var isActive = false
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint ?? (isActive ? .primary : .secondary))
                .frame(width: 28, height: 28)
                .background(buttonBackground)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(helpTitle)
    }

    private var buttonBackground: some View {
        Circle()
            .fill(isActive ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.clear))
            .overlay(
                Circle()
                    .strokeBorder(isActive ? .white.opacity(0.22) : .clear, lineWidth: 1)
            )
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @Environment(AudioTapManager.self) private var tapManager
    @Environment(\.dismiss) private var dismiss
    @State private var exportMessage: String?

    private var report: DiagnosticsReport {
        tapManager.diagnosticsReport()
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.regularMaterial)
                    Image(systemName: "stethoscope")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Diagnostics")
                        .font(.system(size: 17, weight: .semibold))
                    Text(report.generatedAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                GlassIconButton(systemName: "square.and.arrow.down", helpTitle: "Export diagnostics") {
                    exportDiagnostics()
                }
                GlassIconButton(systemName: "xmark", helpTitle: "Close") {
                    dismiss()
                }
            }
            .padding(.horizontal, 2)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    diagnosticsSection("System") {
                        row("App", "\(report.appVersion) (\(report.appBuild))")
                        row("macOS", report.macOSVersion)
                        row("Output", report.defaultOutputDeviceUID ?? "unknown")
                    }

                    diagnosticsSection("Permissions") {
                        row("Screen Recording", report.permissions.screenRecording)
                        row("System Audio Key", report.permissions.systemAudioCaptureUsageDescriptionPresent ? "present" : "missing")
                        row("Microphone Key", report.permissions.microphoneUsageDescriptionPresent ? "present" : "missing")
                    }

                    diagnosticsSection("Taps") {
                        if report.taps.isEmpty {
                            Text("No active taps")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(report.taps) { tap in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tap.name)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("pid \(tap.pid) / \(tap.status)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("objects \(tap.objectIDSignature)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    diagnosticsSection("Recent Errors") {
                        if report.recentErrors.isEmpty {
                            Text("None")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(report.recentErrors, id: \.self) { error in
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let exportMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(exportMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule(style: .continuous))
                    }
                }
                .padding(2)
            }
            .scrollIndicators(.automatic)
        }
        .padding(12)
        .frame(width: 440, height: 480)
        .background(.ultraThinMaterial)
    }

    private func diagnosticsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Fader-Diagnostics.json"
        panel.allowedContentTypes = [.json, .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try tapManager.exportDiagnostics(to: url)
            exportMessage = "Exported \(url.lastPathComponent)"
        } catch {
            exportMessage = error.localizedDescription
        }
    }
}

// MARK: - Per-App Column (Vertical)

struct AppVolumeColumn: View {
    @Bindable var entry: MixerEntry

    var body: some View {
        VStack(spacing: 10) {
            AppIconView(process: entry.process, isPlayingAudio: entry.isPlayingAudio, size: 34)

            VerticalSlider(value: $entry.sliderValue)
                .frame(width: 28, height: 138)
                .disabled(entry.isMuted)

            Text(entry.displayLabel)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(entry.isMuted ? .tertiary : .secondary)
                .frame(height: 14)

            muteButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(width: 58)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(entry.isPlayingAudio ? 0.18 : 0.08), lineWidth: 1)
        )
        .opacity(entry.isMuted ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: entry.isMuted)
        .animation(.easeInOut(duration: 0.2), value: entry.isPlayingAudio)
    }

    private var muteButton: some View {
        Button {
            entry.isMuted.toggle()
        } label: {
            Image(systemName: entry.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(entry.isMuted ? .red : .secondary)
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: Circle())
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
            AppIconView(process: entry.process, isPlayingAudio: entry.isPlayingAudio, size: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.process.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    StatusDot(isPlayingAudio: entry.isPlayingAudio, isMuted: entry.isMuted)
                    Text(rowStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 76, maxWidth: 112, alignment: .leading)

            Slider(value: $entry.sliderValue, in: 0...1)
                .frame(minWidth: 68)
                .disabled(entry.isMuted)

            Text(entry.displayLabel)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(entry.isMuted ? .tertiary : .secondary)
                .frame(width: 42)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule(style: .continuous))

            muteButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(entry.isPlayingAudio ? 0.16 : 0.08), lineWidth: 1)
        )
        .opacity(entry.isMuted ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: entry.isMuted)
        .animation(.easeInOut(duration: 0.2), value: entry.isPlayingAudio)
    }

    private var rowStatus: String {
        if entry.isMuted { return "Muted" }
        return entry.isPlayingAudio ? "Live" : "Paused"
    }

    private var muteButton: some View {
        Button {
            entry.isMuted.toggle()
        } label: {
            Image(systemName: entry.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(entry.isMuted ? .red : .secondary)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(entry.isMuted ? "Unmute" : "Mute")
    }
}

struct AppIconView: View {
    let process: AudioProcess
    let isPlayingAudio: Bool
    var size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon = process.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                        .padding(size * 0.18)
                        .background(.regularMaterial)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            )
            .opacity(isPlayingAudio ? 1.0 : 0.58)
            .saturation(isPlayingAudio ? 1.0 : 0.45)

            Circle()
                .fill(isPlayingAudio ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(.black.opacity(0.22), lineWidth: 1))
                .offset(x: 1, y: 1)
        }
        .help(isPlayingAudio ? process.name : "\(process.name) (paused)")
    }
}

struct StatusDot: View {
    let isPlayingAudio: Bool
    let isMuted: Bool

    var body: some View {
        Circle()
            .fill(isMuted ? Color.red : (isPlayingAudio ? Color.green : Color.secondary))
            .frame(width: 6, height: 6)
    }
}

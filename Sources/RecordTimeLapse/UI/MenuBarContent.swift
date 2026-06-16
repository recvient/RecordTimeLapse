import SwiftUI
import AppKit

/// The menu-bar icon. A dedicated View so SwiftUI's Observation tracking reliably re-renders
/// it whenever the recording state (and thus the symbol) changes.
struct MenuBarLabel: View {
    private let model = RecordingCoordinator.shared.model
    // The menu bar template-izes systemImage/foregroundStyle to monochrome. A non-template
    // NSImage tinted via a palette config keeps its color — that's how we get a red REC dot.
    var body: some View {
        Image(nsImage: icon)
    }
    private var icon: NSImage {
        let base = NSImage(systemSymbolName: model.menuBarSymbol, accessibilityDescription: "status")
            ?? NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)!
        let color: NSColor? = switch model.state {
            case .recording: .systemRed       // unmistakable "REC" dot
            case .paused:    .systemOrange
            default:         nil               // idle/finalizing: follow the menu bar appearance
        }
        guard let color,
              let tinted = base.withSymbolConfiguration(.init(paletteColors: [color])) else {
            base.isTemplate = true
            return base
        }
        tinted.isTemplate = false
        return tinted
    }
}

/// The popover shown from the menu-bar item: status, live stats, and controls.
struct MenuBarContent: View {
    private let coordinator = RecordingCoordinator.shared
    private var model: RecorderModel { coordinator.model }
    private let settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !model.permissionGranted {
                permissionBanner
            }

            if let warning = model.diskWarning {
                Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }

            if model.isRecording {
                statsView
            }
            // Shown in every state: while recording this is where stall/encoder
            // warnings surface; when idle it shows "Saved …" / errors.
            if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            controls
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            Image(systemName: model.menuBarSymbol)
                .foregroundStyle(model.isRecording && !model.isPaused ? .red : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Record TimeLapse").font(.headline)
                Text(model.statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var permissionBanner: some View {
        Button {
            Task {
                _ = await PermissionService.requestIfNeeded()
                PermissionService.openSystemSettings()
                coordinator.refreshPermission()
            }
        } label: {
            Label("Allow Screen Recording…", systemImage: "lock.shield")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.orange)
    }

    private var statsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            statRow("Frames", "\(model.frameCount)")
            statRow("Recording time", Self.formatDuration(model.activeSeconds))
            statRow("Video length", Self.formatDuration(model.projectedVideoLength(outputFPS: settings.outputFPS)))
            statRow("Size on disk", Self.formatBytes(model.estimatedBytes))
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            switch model.state {
            case .idle:
                Button {
                    Task { await coordinator.start() }
                } label: {
                    Label("Start Recording", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

            case .finalizing:
                HStack { ProgressView().controlSize(.small); Text("Finalizing…").font(.caption) }
                    .frame(maxWidth: .infinity)

            case .recording, .paused:
                HStack(spacing: 6) {
                    Button {
                        coordinator.togglePauseByUser()
                    } label: {
                        Label(model.isPaused ? "Resume" : "Pause",
                              systemImage: model.isPaused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        Task { await coordinator.stop() }
                    } label: {
                        Label("Stop & Save", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            if model.lastOutputURL != nil {
                menuButton("Reveal Last Video", "film") { coordinator.revealLastOutput() }
            }
            menuButton("Open Output Folder", "folder") { coordinator.openOutputFolder() }
            menuButton("Settings…", "gearshape") { openSettings() }
            Divider().padding(.vertical, 2)
            menuButton("Quit", "power") {
                Task { await coordinator.stop(); NSApp.terminate(nil) }
            }
        }
    }

    private func menuButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Formatting

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

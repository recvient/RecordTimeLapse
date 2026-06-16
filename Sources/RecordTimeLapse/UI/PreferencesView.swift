import SwiftUI
import AppKit

struct PreferencesView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var displays: [DisplayInfo] = []

    private let intervalPresets: [Double] = [0.5, 1, 2, 5, 10, 30, 60]
    private let fpsPresets: [Int] = [15, 24, 30, 60]

    var body: some View {
        TabView {
            captureTab.tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            outputTab.tabItem { Label("Output", systemImage: "film") }
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460)
        .task { displays = await DisplayProvider.availableDisplays() }
    }

    // MARK: - Capture

    private var captureTab: some View {
        Form {
            Picker("Capture every", selection: $settings.captureInterval) {
                ForEach(intervalPresets, id: \.self) { v in
                    Text(v < 1 ? "\(v, specifier: "%.1f") sec" : "\(Int(v)) sec").tag(v)
                }
            }
            .onChange(of: settings.captureInterval) { _, _ in
                RecordingCoordinator.shared.captureSettingsChanged()
            }

            Picker("Display", selection: $settings.targetDisplayID) {
                Text("Main display").tag(CGDirectDisplayID(0))
                ForEach(displays) { d in Text(d.label).tag(d.id) }
            }

            Picker("Resolution", selection: $settings.resolutionCap) {
                ForEach(ResolutionCap.allCases) { Text($0.label).tag($0) }
            }

            Toggle("Show mouse cursor", isOn: $settings.showsCursor)
                .onChange(of: settings.showsCursor) { _, _ in
                    RecordingCoordinator.shared.captureSettingsChanged()
                }

            Section {
                Text(projectionText)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Output

    private var outputTab: some View {
        Form {
            Picker("Output frame rate", selection: $settings.outputFPS) {
                ForEach(fpsPresets, id: \.self) { Text("\($0) fps").tag($0) }
            }

            Picker("Codec", selection: $settings.codec) {
                ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
            }

            Stepper("Checkpoint every: \(settings.segmentMinutes) min",
                    value: $settings.segmentMinutes, in: 1...30)

            Section {
                Text("The recording is sealed into a complete file every \(settings.segmentMinutes) min of real time, "
                   + "then everything is joined into one video on Stop. If the Mac crashes, "
                   + "all sealed checkpoints are recovered automatically on next launch.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Save to") {
                HStack {
                    Text(settings.outputFolder.path)
                        .font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Toggle("Pause when the screen sleeps or locks", isOn: $settings.pauseOnSleep)
            Toggle("Keep Mac awake while recording", isOn: $settings.preventIdleSleep)
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .onChange(of: settings.launchAtLogin) { _, on in LoginItem.set(on) }

            Section {
                Text("“Keep Mac awake” records continuously through idle periods (heavier on battery). "
                   + "Leave it off to let the Mac sleep — recording pauses and resumes automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Helpers

    private var projectionText: String {
        let interval = max(0.1, settings.captureInterval)
        let fps = max(1, settings.outputFPS)
        let videoSecPer12h = (12 * 3600 / interval) / Double(fps)
        let minutes = videoSecPer12h / 60
        return String(format: "At 1 frame every %@ played back at %d fps, 12 hours becomes ≈ %.1f min of video — "
                      + "if the screen keeps changing. Static periods are skipped automatically "
                      + "(shorter video, zero battery cost).",
                      interval < 1 ? String(format: "%.1f s", interval) : "\(Int(interval)) s",
                      fps, minutes)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputFolder = url
        }
    }
}

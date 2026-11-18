import AppKit
import SwiftUI
import VexaCore

/// The "Record" pane: records the microphone and the Mac's sound and transcribes them with
/// Whisper. A fallback for when Vexa's bots or the browser extension don't work.
struct RecordView: View {
    @Environment(AppModel.self) private var app
    @Environment(RecorderStore.self) private var recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
                .padding(20)
            Divider()
            transcript
        }
        .navigationTitle("Record")
        .toolbar {
            Button("Open folder", systemImage: "folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: app.outputDirectory))
            }
        }
        .task {
            recorder.refreshDevices()
            // Keep the Whisper light current while the pane is open (it may be started elsewhere).
            while !Task.isCancelled {
                await recorder.checkWhisper(app)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        @Bindable var rec = recorder
        let idle = recorder.phase == .idle
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Record from this Mac").font(.title2.weight(.semibold))
                Text("Doesn't need Vexa — only Whisper. Use headphones, or your microphone will also pick up the other people.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            whisperRow
            if let problem = recorder.problem { ProblemBanner(problem: problem) }

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Toggle("Microphone", isOn: $rec.useMicrophone)
                        TextField("Name", text: $rec.microphoneLabel)
                            .textFieldStyle(.roundedBorder).frame(width: 130)
                            .disabled(!recorder.useMicrophone)
                        Picker("Microphone", selection: $rec.inputDeviceUID) {
                            Text("System default").tag("")
                            ForEach(recorder.inputDevices) { Text($0.name).tag($0.id) }
                            if !recorder.inputDeviceUID.isEmpty,
                               !recorder.inputDevices.contains(where: { $0.id == recorder.inputDeviceUID }) {
                                Text("Not connected").tag(recorder.inputDeviceUID)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        .disabled(!recorder.useMicrophone)
                    }
                    GridRow {
                        Toggle("System audio", isOn: $rec.useSystemAudio)
                        TextField("Name", text: $rec.systemAudioLabel)
                            .textFieldStyle(.roundedBorder).frame(width: 130)
                            .disabled(!recorder.useSystemAudio)
                        Text("What your Mac plays: the other people in the call.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 20) {
                Picker("Language", selection: $rec.languageCode) {
                    ForEach(LocalTranscript.languages, id: \.name) { Text($0.name).tag($0.code ?? "") }
                }
                .frame(maxWidth: 260)
                .help("Detecting the language automatically can turn silence into made-up text in another language.")
                Toggle("Keep the audio", isOn: $rec.keepAudio)
                    .help("Also saves a WAV file per source next to the transcript (about 115 MB per hour each).")
            }
            .disabled(!idle)

            HStack(alignment: .center, spacing: 16) {
                startStopButton
                status
                Spacer(minLength: 0)
                fileButtons
            }

            if let warning = recorder.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .disabled(recorder.phase == .starting)
    }

    private var whisperRow: some View {
        HStack(spacing: 10) {
            let w = recorder.whisper
            StatusLight(label: "Whisper", state: w.isUp ? .up : (w == .down || w == .loading ? .down : .unknown),
                        detail: whisperDetail)
            Spacer()
            if recorder.whisper == .down {
                Button("Start Whisper") { Task { await recorder.startWhisper(app) } }
                    .disabled(app.runner.isRunning || !app.projectLooksValid)
            }
            Button("Check again", systemImage: "arrow.clockwise") { Task { await recorder.checkWhisper(app) } }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .controlSize(.small)
    }

    private var whisperDetail: String {
        switch recorder.whisper {
        case .up(let model): return model?.replacingOccurrences(of: "mlx-community/", with: "") ?? "running"
        case .loading: return "loading the model…"
        case .down: return "not running"
        case .checking: return "checking…"
        case .unknown: return ""
        }
    }

    private var startStopButton: some View {
        let recording = recorder.phase == .recording
        return Button {
            Task { recording ? await recorder.stop() : await recorder.start(app) }
        } label: {
            Label(recording ? "Stop" : "Start recording", systemImage: recording ? "stop.circle.fill" : "record.circle")
                .font(.title3.weight(.semibold))
                .frame(minWidth: 170)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(recording ? .red : .accentColor)
        .keyboardShortcut(recording ? "." : "r", modifiers: .command)
        .disabled(recorder.phase == .starting || recorder.phase == .stopping
                  || (recorder.phase == .idle && recorder.selectedLanes.isEmpty))
    }

    @ViewBuilder private var status: some View {
        switch recorder.phase {
        case .idle:
            EmptyView()
        case .starting:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Starting…").foregroundStyle(.secondary) }
        case .stopping:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(recorder.pendingChunks > 0 ? "Finishing: \(recorder.pendingChunks) left for Whisper…" : "Finishing…")
                    .foregroundStyle(.secondary)
                if recorder.pendingChunks > 0 {
                    Button("Stop waiting") { recorder.skipWaiting() }
                        .controlSize(.small)
                        .help("Audio Whisper hasn't done yet is saved next to the transcript instead.")
                }
            }
        case .recording:
            HStack(spacing: 16) {
                if let start = recorder.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(Self.elapsed(context.date.timeIntervalSince(start)))
                            .font(.title3.monospacedDigit())
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recorder.activeLanes) { lane in
                        HStack(spacing: 6) {
                            Text(recorder.label(for: lane)).font(.caption).frame(width: 56, alignment: .leading).lineLimit(1)
                            LevelMeter(level: recorder.levels[lane] ?? 0).frame(width: 110, height: 6)
                        }
                    }
                    if recorder.pendingChunks > 1 {
                        Text("\(recorder.pendingChunks) pieces waiting for Whisper").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var fileButtons: some View {
        if let url = recorder.fileURL {
            HStack {
                Button("Open transcript", systemImage: "doc.text") { NSWorkspace.shared.open(url) }
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(url.lastPathComponent)
        }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
            : String(format: "%02d:%02d", t / 60, t % 60)
    }

    // MARK: Live transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            List(recorder.lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(line.speaker).font(.callout.weight(.semibold))
                            .foregroundStyle(line.lane == .microphone ? Color.accentColor : Color.purple)
                        Text(line.start.formatted(date: .omitted, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(line.text).textSelection(.enabled)
                }
                .padding(.vertical, 2)
                .id(line.id)
            }
            .overlay {
                if recorder.lines.isEmpty {
                    ContentUnavailableView(
                        recorder.phase == .recording ? "Listening…" : "No transcript yet",
                        systemImage: "waveform",
                        description: Text(recorder.phase == .recording
                            ? "Text appears here a few seconds after someone stops talking."
                            : "Press Start recording. The transcript is saved as Markdown in your transcripts folder as it goes."))
                }
            }
            .onChange(of: recorder.lines.count) {
                guard let last = recorder.lines.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(minHeight: 160)
    }
}

/// Why recording couldn't start, with the button that fixes it.
private struct ProblemBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(RecorderStore.self) private var recorder
    let problem: RecorderStore.Problem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message).fixedSize(horizontal: false, vertical: true)
                if case .screenRecordingDenied(let detail) = problem {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                switch problem {
                case .whisperDown:
                    Button("Start Whisper") { Task { await recorder.startWhisper(app) } }
                        .disabled(app.runner.isRunning || !app.projectLooksValid)
                case .microphoneDenied:
                    Button("Open Microphone Settings") { RecorderPermissions.openMicrophoneSettings() }
                case .screenRecordingDenied:
                    Button("Open Screen & System Audio Recording Settings") { RecorderPermissions.openScreenRecordingSettings() }
                default:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark") { recorder.problem = nil }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var message: String {
        switch problem {
        case .noLanes:
            return "Turn on the microphone, system audio, or both."
        case .whisperDown:
            return "Whisper isn't running. Start it, then press Start recording again."
        case .microphoneDenied:
            return "Vexa Local isn't allowed to use the microphone. Allow it in System Settings › Privacy & Security › Microphone, or turn the microphone off here."
        case .screenRecordingDenied:
            return "To record system audio, allow Vexa Local in System Settings › Privacy & Security › Screen & System Audio Recording. Then quit and reopen Vexa Local. Or turn system audio off here."
        case .other(let text):
            return text
        }
    }
}

/// A horizontal level bar, 0…1.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.9 ? Color.red : (level > 0.7 ? Color.orange : Color.green))
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
            }
        }
        .animation(.linear(duration: 0.1), value: level)
    }
}

/// Covers the window while quitting waits for the recording to finish.
struct RecorderQuitOverlay: View {
    @Environment(RecorderStore.self) private var recorder

    var body: some View {
        if recorder.isQuitting {
            ZStack {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finishing the recording before quitting…").font(.headline)
                    }
                    Text(recorder.pendingChunks > 0
                         ? "\(recorder.pendingChunks) piece\(recorder.pendingChunks == 1 ? "" : "s") of audio still with Whisper. This can take up to a minute."
                         : "Saving the transcript…")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Quit Now") { recorder.skipWaiting() }
                            .help("Stop waiting for Whisper. Audio it hasn't transcribed is saved next to the transcript.")
                    }
                }
                .padding(20)
                .frame(width: 460)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 12)
            }
        }
    }
}

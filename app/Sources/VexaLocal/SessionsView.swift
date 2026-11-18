import AppKit
import SwiftUI
import VexaCore

struct SessionsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.sessions.isEmpty {
                ContentUnavailableView("No meetings yet", systemImage: "doc.text",
                                       description: Text("Send a bot to a Teams meeting, or record a Google Meet or Zoom meeting with the browser extension. Transcripts appear here."))
            } else {
                List(app.sessions) { SessionRow(session: $0) }
            }
        }
        .navigationTitle("Transcripts")
        .toolbar {
            Button("Open folder", systemImage: "folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: app.outputDirectory))
            }
        }
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var app
    let session: Session

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: session.platform.symbolName)
                .font(.title2).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.platform.displayName).font(.headline)
                    Text(session.meetingId).font(.body.monospaced()).foregroundStyle(.secondary)
                    StatusBadge(status: session.status)
                }
                Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(session.segmentCount) segments · \(session.source.label)")
                    .font(.caption).foregroundStyle(.secondary)
                if let why = session.failureReason, session.status == "failed" {
                    Label(why, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text(URL(fileURLWithPath: session.filePath).lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let err = session.lastError {
                    Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Spacer()
            HStack {
                Button("Open", systemImage: "doc.text") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: session.filePath))
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.filePath)])
                }
                if session.finished || session.source == .browserExtension {
                    Button("Remove from list", systemImage: "xmark") { app.removeSession(session) }
                } else {
                    Button("Leave meeting", systemImage: "stop.fill") { Task { await app.stopBot(session) } }
                        .tint(.red)
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case "awaiting_admission": return "waiting in lobby"
        case "needs_help": return "needs help"
        default: return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    private var color: Color {
        switch status {
        case "active": return .green
        case "completed": return .blue
        case "failed": return .red
        case "awaiting_admission", "needs_help": return .orange
        default: return .secondary
        }
    }
}

extension MeetingPlatform {
    /// SF Symbol shown next to a meeting of this platform.
    var symbolName: String {
        switch self {
        case .googleMeet: return "video.fill"
        case .teams: return "person.3.fill"
        case .zoom: return "video.circle.fill"
        }
    }
}

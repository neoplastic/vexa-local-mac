import AppKit
import Foundation

/// Copies the running app into /Applications and reopens it from there.
enum AppMover {
    static let destination = URL(fileURLWithPath: "/Applications/Vexa Local.app")

    struct MoveError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Copies `source` to `destination` with ditto (keeps the code signature), replacing an
    /// older copy. The copy goes to a temporary name first, so a failed copy never leaves a
    /// half-copied app behind.
    static func copy(from source: URL, to destination: URL = destination) async throws {
        let fm = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let folder = destination.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".\(destination.lastPathComponent).moving-\(UUID().uuidString)")
        let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let result = await Command.run(["ditto", source.path, temp.path], environment: env, timeout: 120)
        guard result.ok else {
            try? fm.removeItem(at: temp)
            throw MoveError(message: "Could not copy the app to \(folder.path): \(result.message). "
                            + "Drag it there in Finder instead.")
        }
        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temp, to: destination)
        } catch {
            try? fm.removeItem(at: temp)
            throw MoveError(message: "Could not replace \(destination.path): \(error.localizedDescription)")
        }
    }

    /// Opens the copy in /Applications, then quits this one without stopping Vexa.
    @MainActor
    static func relaunch(_ app: AppModel, from destination: URL = destination,
                         onError: @escaping @MainActor (String) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, error in
            Task { @MainActor in
                if let error {
                    onError("The app was copied, but couldn't be opened: \(error.localizedDescription). Open it from Applications.")
                    return
                }
                app.quit.relaunching = true
                NSApp.terminate(nil)
            }
        }
    }
}

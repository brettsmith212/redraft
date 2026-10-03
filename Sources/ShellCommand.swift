import AppKit

/// The `redraft` shell command ships inside the app
/// (Contents/Resources/redraft). Installing it links that copy onto the
/// PATH, so it always matches the app you have.
enum ShellCommand {
    static let name = "redraft"

    static var bundled: URL? { Bundle.main.url(forResource: name, withExtension: nil) }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Where to put the link, most preferred first. ~/.local/bin needs no
    /// admin rights; the others are used if they're writable.
    private static var folders: [URL] {
        [home.appendingPathComponent(".local/bin"), URL(fileURLWithPath: "/usr/local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin")]
    }

    /// The installed link, if any.
    static var installed: URL? {
        folders.map { $0.appendingPathComponent(name) }.first { link in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
                || FileManager.default.fileExists(atPath: link.path)
        }
    }

    /// Where the installed link points, if it's a link.
    static var installedTarget: String? {
        installed.flatMap { try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path) }
    }

    @discardableResult
    static func install() throws -> URL {
        guard let bundled else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        let folder = folders.first { fm.isWritableFile(atPath: $0.path) } ?? folders[0]
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent(name)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path) {
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
        return link
    }

    static func uninstall() {
        guard let link = installed else { return }
        try? FileManager.default.removeItem(at: link)
    }

    /// Whether the folder holding the command is on the user's shell PATH.
    /// GUI apps don't inherit it, so ask a login shell once.
    static func folderIsOnPath(_ folder: URL) -> Bool {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return true }
        process.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return path.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            .contains { URL(fileURLWithPath: String($0)).standardized.path == folder.standardized.path }
    }

    /// On launch: re-point a link left behind by a moved or deleted copy of
    /// the app. Installing is always the user's choice (menu or Settings).
    static func setUpOnLaunch() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            if let target = installedTarget, target.contains("Redraft.app") {
                // Our link: follow the app if it moved, and prefer the copy in /Applications.
                let here = Bundle.main.bundlePath
                let preferHere = here.hasPrefix("/Applications/") && !target.hasPrefix(here)
                if !fm.fileExists(atPath: target) || preferHere { _ = try? install() }
            }
        }
    }

    /// Installs and reports the result in an alert.
    @MainActor
    static func installWithAlert() {
        let alert = NSAlert()
        do {
            let link = try install()
            let folder = link.deletingLastPathComponent()
            alert.messageText = "Shell command installed"
            var info = "Run `redraft file.md` in a terminal to open a file in Redraft.\n\nInstalled at \(link.path.replacingOccurrences(of: home.path, with: "~"))."
            if !folderIsOnPath(folder) {
                info += "\n\nThat folder isn't on your shell's PATH yet. Add this to your shell profile:\nexport PATH=\"\(folder.path.replacingOccurrences(of: home.path, with: "$HOME")):$PATH\""
            }
            alert.informativeText = info
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install the shell command"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}

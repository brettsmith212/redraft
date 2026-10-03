import AppKit
import Markdown
import UniformTypeIdentifiers

/// Export Clean Copy: the essay as a reader gets it. Current wording of every
/// alternative, ghosted text left out, no overflow or Redraft notes. The
/// working file is untouched and stays open.
extension EditorSession {
    enum ExportFormat: Int, CaseIterable {
        case markdown, html

        var title: String { self == .markdown ? "Markdown (.md)" : "HTML (.html, styled like Preview)" }
        var type: UTType { self == .markdown ? .markdownText : .html }
        var fileExtension: String { self == .markdown ? "md" : "html" }
    }

    /// The finished text: ghosts removed, and the gaps they leave tidied.
    func exportMarkdown() -> String {
        var text = cleanText()
        // Removing ghosted passages can leave runs of blank lines or trailing spaces.
        text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=\S)  +(?=\S)"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    func exportCleanCopy() {
        guard let window = textView?.window else { return }
        let documentURL = (window.windowController?.document as? NSDocument)?.fileURL
        let baseName = documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"

        let panel = NSSavePanel()
        panel.title = "Export Clean Copy"
        panel.message = "The essay as Preview shows it: current alternatives, no ghosted text or overflow."
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let folder = documentURL?.deletingLastPathComponent() { panel.directoryURL = folder }

        let remembered = ExportFormat(rawValue: UserDefaults.standard.integer(forKey: "exportFormat")) ?? .markdown
        panel.allowedContentTypes = [remembered.type]
        panel.nameFieldStringValue = "\(baseName) (final).\(remembered.fileExtension)"

        // A Format menu, like other Mac apps' export dialogs.
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        ExportFormat.allCases.forEach { picker.addItem(withTitle: $0.title) }
        picker.selectItem(at: remembered.rawValue)
        let handler = FormatChange(panel: panel, picker: picker)
        picker.target = handler
        picker.action = #selector(FormatChange.changed)
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, picker])
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        panel.accessoryView = row

        let markdown = exportMarkdown()
        panel.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(handler) {}
            guard response == .OK, let url = panel.url else { return }
            let format = ExportFormat(rawValue: picker.indexOfSelectedItem) ?? .markdown
            UserDefaults.standard.set(format.rawValue, forKey: "exportFormat")
            let contents = format == .markdown
                ? markdown
                : MarkdownPreview.page(HTMLFormatter.format(markdown), title: url.deletingPathExtension().lastPathComponent)
            do {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self?.errorMessage = "Couldn't export: \(error.localizedDescription)"
            }
        }
    }
}

/// Keeps the file name's extension in step with the chosen format.
private final class FormatChange: NSObject {
    let panel: NSSavePanel
    let picker: NSPopUpButton

    init(panel: NSSavePanel, picker: NSPopUpButton) {
        self.panel = panel
        self.picker = picker
    }

    @MainActor @objc func changed() {
        guard let format = EditorSession.ExportFormat(rawValue: picker.indexOfSelectedItem) else { return }
        panel.allowedContentTypes = [format.type]
        let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(name).\(format.fileExtension)"
    }
}

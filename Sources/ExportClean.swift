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
        CleanCopy.markdown(from: storage)
    }

    /// The finished text without Markdown symbols, for posting where they'd
    /// show as typed.
    func plainText() -> String {
        PlainText.from(markdown: exportMarkdown())
    }

    /// Copies the finished text formatted: HTML for the web editors writers
    /// paste into (Substack, Ghost, WordPress, Medium, Google Docs), RTF for
    /// Pages, Notes and Mail, and plain text for everywhere else. Headings,
    /// emphasis, lists and links come along; Markdown symbols don't.
    func copyRichText(to pasteboard: NSPasteboard = .general) {
        let markdown = exportMarkdown()
        let html = "<meta charset=\"utf-8\">" + HTMLFormatter.format(markdown)
        let item = NSPasteboardItem()
        item.setString(html, forType: .html)
        if let rtf = Self.rtf(fromHTML: html) { item.setData(rtf, forType: .rtf) }
        item.setString(PlainText.from(markdown: markdown), forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// RTF for apps that prefer it, in a plain, readable font rather than
    /// the HTML importer's Times.
    private static func rtf(fromHTML html: String) -> Data? {
        let styled = "<style>body { font: 14px -apple-system, \"Helvetica Neue\", sans-serif; } code, pre { font-family: Menlo, monospace; }</style>" + html
        guard let text = try? NSAttributedString(
            data: Data(styled.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }
        return try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    func exportCleanCopy() {
        guard let window = textView?.window else { return }
        guard placeholderCount > 0 else { return showExportPanel(in: window) }
        // TKs left in would go out with the essay.
        let alert = NSAlert()
        alert.messageText = placeholderCount == 1 ? "This draft still has a TK" : "This draft still has \(placeholderCount) TKs"
        alert.informativeText = "TK marks something still to fill in. Export anyway, or go fill it in first?"
        alert.addButton(withTitle: "Go to First TK")
        alert.addButton(withTitle: "Export Anyway")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                self.showExportPanel(in: window)
            } else {
                self.textView?.setSelectedRange(NSRange(location: 0, length: 0))
                self.goToNextPlaceholder()
            }
        }
    }

    private func showExportPanel(in window: NSWindow) {
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

/// Markdown as plain text, for places that show it as typed (a post on X):
/// headings and emphasis lose their symbols, a link becomes its text and
/// address, a list keeps its bullets or numbers.
enum PlainText {
    static func from(markdown: String) -> String {
        blocks(Document(parsing: markdown).children)
    }

    private static func blocks(_ children: MarkupChildren, separator: String = "\n\n") -> String {
        children.map(block).filter { !$0.isEmpty }.joined(separator: separator)
    }

    private static func block(_ markup: Markup) -> String {
        switch markup {
        case let list as UnorderedList:
            return list.listItems.map { "- " + blocks($0.children, separator: "\n") }.joined(separator: "\n")
        case let list as OrderedList:
            return list.listItems.enumerated()
                .map { "\(Int(list.startIndex) + $0.offset). " + blocks($0.element.children, separator: "\n") }
                .joined(separator: "\n")
        case let code as CodeBlock:
            return code.code.trimmingCharacters(in: .newlines)
        case let html as HTMLBlock:
            return withoutTags(html.rawHTML).trimmingCharacters(in: .whitespacesAndNewlines)
        case is ThematicBreak:
            return ""
        case let container as InlineContainer:
            return inline(container)
        default:
            return blocks(markup.children)
        }
    }

    private static func inline(_ markup: Markup) -> String {
        switch markup {
        case let text as Text:
            return text.string
        case is SoftBreak, is LineBreak:
            return "\n"
        case let code as InlineCode:
            return code.code
        case is InlineHTML:
            return ""
        case let link as Link:
            let label = link.children.map(inline).joined()
            guard let address = link.destination, !address.isEmpty, address != label else { return label }
            return label.isEmpty ? address : "\(label) (\(address))"
        default:
            return markup.children.map(inline).joined()
        }
    }

    private static func withoutTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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

import AppKit
import Markdown
import SwiftUI
import WebKit

/// Hosts the main `EditorTextView` on the document's own text storage.
struct EditorView: NSViewRepresentable {
    @ObservedObject var session: EditorSession

    func makeNSView(context: Context) -> NSScrollView {
        let layoutManager = NSLayoutManager()
        session.doc.storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let tv = EditorTextView(frame: .zero, textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.isAutomaticTextReplacementEnabled = true
        tv.smartInsertDeleteEnabled = true
        tv.selectedTextAttributes = [.backgroundColor: Theme.selection]
        tv.textContainerInset = NSSize(width: 40, height: Theme.topInset)
        tv.setUpCaret()

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = tv
        tv.trackReadingPosition()

        session.attach(tv)
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            // Back where you left off in this file, or at the end of a new one.
            session.restorePosition()
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? EditorTextView)?.featuresOn = session.featuresOn
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        if let tv = scroll.documentView as? NSTextView, let lm = tv.layoutManager {
            tv.textStorage?.removeLayoutManager(lm)
        }
    }
}

/// The overflow drawer's plain text view.
struct OverflowEditor: NSViewRepresentable {
    let session: EditorSession

    func makeNSView(context: Context) -> NSScrollView {
        let layoutManager = NSLayoutManager()
        session.doc.overflow.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let tv = PlainTextView(frame: .zero, textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.usesFontPanel = false
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.insertionPointColor = Theme.accent
        tv.selectedTextAttributes = [.backgroundColor: Theme.selection]
        tv.textContainerInset = NSSize(width: 12, height: 6)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = tv
        session.attachOverflow(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        if let tv = scroll.documentView as? NSTextView, let lm = tv.layoutManager {
            tv.textStorage?.removeLayoutManager(lm)
        }
    }
}

final class PlainTextView: NSTextView {
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

/// Read-only rendering of the Markdown (without ghosted text), set like a page.
struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    var zoom: CGFloat = 1

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = Theme.paper
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        web.pageZoom = zoom
        let body = HTMLFormatter.format(markdown)
        web.loadHTMLString(Self.page(body), baseURL: nil)
    }

    static func page(_ body: String, title: String? = nil) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">\(title.map { "<title>\($0.replacingOccurrences(of: "<", with: "&lt;"))</title>" } ?? "")<style>
        :root { color-scheme: light dark; --ink:#2B2A26; --soft:#8A857B; --accent:#A8743A; --rule:rgba(43,42,38,.12); --code:rgba(43,42,38,.05); }
        @media (prefers-color-scheme: dark) { :root { --ink:#E0DCD3; --soft:#8F8A80; --accent:#D3A468; --rule:rgba(224,220,211,.12); --code:rgba(224,220,211,.06); } }
        html { background: transparent; }
        body { font: 18px/1.62 ui-serif, "New York", Georgia, serif; color: var(--ink); max-width: 660px;
               margin: 0 auto; padding: 72px 40px 120px; -webkit-font-smoothing: antialiased; }
        h1, h2, h3, h4 { line-height: 1.2; font-weight: 600; margin: 1.4em 0 .5em; }
        h1 { font-size: 30px; } h2 { font-size: 24px; } h3 { font-size: 20px; } h4 { font-size: 18px; }
        h1:first-child, h2:first-child { margin-top: 0; }
        p { margin: 0 0 .85em; }
        a { color: var(--accent); text-decoration: none; border-bottom: 1px solid color-mix(in srgb, var(--accent) 35%, transparent); }
        blockquote { margin: 1em 0; padding-left: 18px; border-left: 2px solid var(--rule); color: var(--soft); font-style: italic; }
        code { font: 15px ui-monospace, Menlo, monospace; background: var(--code); padding: 1px 4px; border-radius: 4px; }
        pre { background: var(--code); padding: 14px 16px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
        ul, ol { padding-left: 1.3em; } li { margin: .25em 0; }
        li::marker { color: var(--accent); }
        img { max-width: 100%; }
        table { border-collapse: collapse; } td, th { border-bottom: 1px solid var(--rule); padding: 6px 10px; text-align: left; }
        </style></head><body>\(body)</body></html>
        """
    }
}

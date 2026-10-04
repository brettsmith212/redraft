import AppKit

/// Live Markdown styling for the editor. The source stays plain Markdown;
/// this only paints it: headings get size, emphasis gets weight, and syntax
/// markers fade back so the words carry the page.
enum MarkdownStyler {
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are compile-time constants.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static let heading = regex(#"^(#{1,6})[ \t]+"#)
    private static let quote = regex(#"^>[ \t]?"#)
    static let list = regex(#"^[ \t]*([-*+]|\d+[.)])[ \t]+"#)
    private static let rule = regex(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)
    /// A line of dashes, where smart dashes would change the Markdown: a
    /// `---` rule or front matter fence, or a table's divider row (`|---|:--|`).
    private static let dashLine = regex(#"^[ \t]*(?:--|-{3,}[ \t]*|[-:\t ]*\|[-|:\t ]*)$"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*_\w])"#)
    private static let code = regex(#"`([^`\n]+)`"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    /// TK, the journalist's mark for something to fill in later (TKTK too).
    private static let placeholder = regex(#"\bTK(?:TK)*\b"#)

    /// Styles every paragraph that intersects `range`. `range` should already
    /// be paragraph-aligned. `codeBlocks` saves finding them again when the
    /// caller already has them for this text.
    static func apply(to ts: NSMutableAttributedString, in range: NSRange, groups: [String: VariantGroup], showAlternates: Bool,
                      codeBlocks known: [CodeBlock]? = nil) {
        guard range.length > 0, NSMaxRange(range) <= ts.length else { return }
        let ns = ts.string as NSString
        let blocks = known ?? codeBlocks(in: ns)

        for key in [NSAttributedString.Key.kern, .backgroundColor, .strikethroughStyle, .strikethroughColor, .markdownMarker, .placeholder] {
            ts.removeAttribute(key, range: range)
        }

        ns.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, line, enclosing, _ in
            styleParagraph(ts, ns: ns, line: line, enclosing: enclosing, inBlock: codeRole(at: line.location, in: blocks))
        }

        ts.enumerateAttribute(.ghost, in: range) { value, r, _ in
            guard (value as? Bool) == true else { return }
            ts.addAttribute(.foregroundColor, value: Theme.ghost, range: r)
            // A ghosted TK won't be read, so it isn't flagged.
            ts.enumerateAttribute(.placeholder, in: r) { tk, tkRange, _ in
                if tk != nil { ts.removeAttribute(.backgroundColor, range: tkRange) }
            }
        }
        ts.enumerateAttribute(.labMark, in: range) { value, r, _ in
            if value != nil { ts.addAttribute(.backgroundColor, value: Theme.mark, range: r) }
        }
        ts.enumerateAttribute(.proposedCut, in: range) { value, r, _ in
            guard value != nil else { return }
            ts.addAttributes([
                .foregroundColor: Theme.cutInk,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: Theme.cutStrike,
            ], range: r)
        }

        guard showAlternates else { return }
        let full = NSRange(location: 0, length: ts.length)
        ts.enumerateAttribute(.variantGroup, in: range) { value, r, _ in
            guard let id = value as? String, let group = groups[id], !group.options.isEmpty else { return }
            var run = NSRange()
            _ = ts.attribute(.variantGroup, at: r.location, longestEffectiveRange: &run, in: full)
            let last = NSMaxRange(run) - 1
            guard last >= range.location, last < NSMaxRange(range) else { return }
            // Make room after the last character for the little row of dots.
            ts.addAttribute(.kern, value: EditorTextView.dotsWidth(group.options.count), range: NSRange(location: last, length: 1))
        }
    }

    /// Like `apply`, but changes only the attributes that differ. Rewriting
    /// attributes that are already right still counts as an edit, and right
    /// after typing that makes TextKit lay out the whole rest of the document
    /// again; typing plain prose usually changes nothing at all.
    static func restyle(_ ts: NSTextStorage, in range: NSRange, groups: [String: VariantGroup], showAlternates: Bool,
                        codeBlocks blocks: [CodeBlock]) {
        guard range.length > 0, NSMaxRange(range) <= ts.length else { return }
        let copy = NSMutableAttributedString(attributedString: ts.attributedSubstring(from: range))
        // The code blocks, as seen from inside the copy.
        func local(_ r: NSRange) -> NSRange {
            NSLocationInRange(r.location, range) ? NSRange(location: r.location - range.location, length: r.length) : NSRange(location: NSNotFound, length: 0)
        }
        let localBlocks = blocks.compactMap { block -> CodeBlock? in
            let whole = NSIntersectionRange(block.whole, range)
            guard whole.length > 0 else { return nil }
            return CodeBlock(open: local(block.open), close: block.close.map(local),
                             whole: NSRange(location: whole.location - range.location, length: whole.length))
        }
        apply(to: copy, in: NSRange(location: 0, length: copy.length), groups: groups, showAlternates: showAlternates, codeBlocks: localBlocks)
        copy.enumerateAttributes(in: NSRange(location: 0, length: copy.length)) { attrs, r, _ in
            let target = NSRange(location: r.location + range.location, length: r.length)
            var current = NSRange()
            let existing = ts.attributes(at: target.location, longestEffectiveRange: &current, in: target)
            if NSEqualRanges(current, target), (existing as NSDictionary).isEqual(to: attrs) { return }
            ts.setAttributes(attrs, range: target)
        }
    }

    private static func styleParagraph(_ ts: NSMutableAttributedString, ns: NSString, line: NSRange, enclosing: NSRange, inBlock: CodeRole?) {
        ts.addAttributes(Theme.baseAttributes, range: enclosing)
        switch inBlock {
        case .fence:
            ts.addAttributes([.font: Theme.mono, .foregroundColor: Theme.marker], range: line)
            return
        case .code:
            // Code reads as written: no headings, emphasis or links inside it.
            ts.addAttribute(.font, value: Theme.mono, range: enclosing)
            return
        case nil:
            break
        }
        // Blank lines are as tall as a line of body text.
        guard line.length > 0 else { return }
        let text = ns.substring(with: line)
        let local = NSRange(location: 0, length: (text as NSString).length)
        func abs(_ r: NSRange) -> NSRange { NSRange(location: r.location + line.location, length: r.length) }

        if let m = heading.firstMatch(in: text, range: local) {
            let level = m.range(at: 1).length
            ts.addAttributes([.font: Theme.heading(level), .paragraphStyle: Theme.headingParagraph], range: enclosing)
            marker(ts, abs(m.range))
        } else if let m = quote.firstMatch(in: text, range: local) {
            ts.addAttributes([
                .paragraphStyle: Theme.quoteParagraph,
                .foregroundColor: Theme.inkSecondary,
                .font: NSFontManager.shared.convert(Theme.body, toHaveTrait: .italicFontMask),
            ], range: enclosing)
            marker(ts, abs(m.range))
        } else if rule.firstMatch(in: text, range: local) != nil {
            ts.addAttribute(.foregroundColor, value: Theme.marker, range: line)
            return
        } else if let m = list.firstMatch(in: text, range: local) {
            ts.addAttribute(.foregroundColor, value: Theme.accent, range: abs(m.range(at: 1)))
            // Wrapped lines start under the item's text, not its bullet.
            let bullet = (text as NSString).substring(with: m.range) as NSString
            let indent = bullet.size(withAttributes: [.font: Theme.body, .paragraphStyle: Theme.paragraph]).width
            ts.addAttribute(.paragraphStyle, value: Theme.listParagraph(indent: indent), range: enclosing)
        }

        let codeSpans = code.matches(in: text, range: local).map(\.range)
        for span in codeSpans {
            ts.addAttributes([.font: Theme.mono, .backgroundColor: Theme.codeBackground], range: abs(span))
            marker(ts, abs(NSRange(location: span.location, length: 1)))
            marker(ts, abs(NSRange(location: NSMaxRange(span) - 1, length: 1)))
        }
        for m in placeholder.matches(in: text, range: local) where !codeSpans.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            ts.addAttributes([.placeholder: true, .backgroundColor: Theme.placeholder], range: abs(m.range))
        }
        for m in bold.matches(in: text, range: local) {
            addTrait(.boldFontMask, ts, abs(m.range))
            dimMarkers(ts, abs(m.range), markerLength: m.range(at: 1).length)
        }
        for m in italic.matches(in: text, range: local) {
            addTrait(.italicFontMask, ts, abs(m.range))
            dimMarkers(ts, abs(m.range), markerLength: 1)
        }
        for m in link.matches(in: text, range: local) {
            let label = m.range(at: 1)
            ts.addAttribute(.foregroundColor, value: Theme.accent, range: abs(label))
            marker(ts, abs(NSRange(location: m.range.location, length: 1)))
            marker(ts, abs(NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label))))
        }
    }

    // MARK: Code blocks

    /// A fenced code block, by the paragraph ranges of its fence lines. An
    /// unclosed block (one being typed) runs to the end of the text.
    struct CodeBlock {
        let open: NSRange
        let close: NSRange?
        let whole: NSRange
    }

    private enum CodeRole { case fence, code }

    /// The fenced code blocks in the text, in order. A block closes on a fence
    /// of the same character, at least as long, with nothing after it.
    static func codeBlocks(in ns: NSString) -> [CodeBlock] {
        // Most writing has none, so skip the scan.
        guard ns.range(of: "```").location != NSNotFound || ns.range(of: "~~~").location != NSNotFound else { return [] }
        var blocks: [CodeBlock] = []
        var open: (range: NSRange, marker: unichar, length: Int)?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, line, enclosing, _ in
            guard let fence = fenceLine(in: ns, line: line) else { return }
            if let o = open {
                guard fence.marker == o.marker, fence.length >= o.length, fence.bare else { return }
                blocks.append(CodeBlock(open: o.range, close: enclosing, whole: NSUnionRange(o.range, enclosing)))
                open = nil
            } else {
                open = (enclosing, fence.marker, fence.length)
            }
        }
        if let o = open {
            blocks.append(CodeBlock(open: o.range, close: nil, whole: NSRange(location: o.range.location, length: ns.length - o.range.location)))
        }
        return blocks
    }

    /// A fence line's character (` or ~), how many, and whether nothing follows them.
    private static func fenceLine(in ns: NSString, line: NSRange) -> (marker: unichar, length: Int, bare: Bool)? {
        func isBlank(_ c: unichar) -> Bool { c == 32 || c == 9 }
        let end = NSMaxRange(line)
        var i = line.location
        while i < end, isBlank(ns.character(at: i)) { i += 1 }
        guard i < end, ns.character(at: i) == 96 || ns.character(at: i) == 126 else { return nil }
        let marker = ns.character(at: i)
        var j = i
        while j < end, ns.character(at: j) == marker { j += 1 }
        guard j - i >= 3 else { return nil }
        var k = j
        while k < end, isBlank(ns.character(at: k)) { k += 1 }
        return (marker, j - i, k == end)
    }

    private static func codeRole(at location: Int, in blocks: [CodeBlock]) -> CodeRole? {
        guard let block = blocks.first(where: { NSLocationInRange(location, $0.whole) }) else { return nil }
        return location == block.open.location || location == block.close?.location ? .fence : .code
    }

    /// Whether smart quotes and dashes would change the Markdown here: in code,
    /// or on a line of dashes (a `---` rule or front matter fence, a table's
    /// divider row).
    static func wantsPlainPunctuation(at location: Int, in ns: NSString) -> Bool {
        guard location <= ns.length else { return false }
        let line = contentLine(at: location, in: ns)
        if dashLine.firstMatch(in: ns.substring(with: line), range: NSRange(location: 0, length: line.length)) != nil { return true }
        return isInCode(at: location, in: ns)
    }

    /// Whether a spot is in code: a code block, or an inline code span open on its line.
    static func isInCode(at location: Int, in ns: NSString) -> Bool {
        guard location <= ns.length else { return false }
        let line = contentLine(at: location, in: ns)
        let before = ns.substring(with: NSRange(location: line.location, length: max(0, location - line.location)))
        if before.reduce(0, { $1 == "`" ? $0 + 1 : $0 }) % 2 == 1 { return true }
        return codeBlocks(in: ns).contains { NSLocationInRange(location, $0.whole) }
    }

    /// The line holding a spot, without its line break.
    static func contentLine(at location: Int, in ns: NSString) -> NSRange {
        var line = ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0))
        while line.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(line) - 1)) { line.length -= 1 }
        return line
    }

    // MARK: Helpers

    private static func addTrait(_ trait: NSFontTraitMask, _ ts: NSMutableAttributedString, _ range: NSRange) {
        ts.enumerateAttribute(.font, in: range) { value, r, _ in
            guard let font = value as? NSFont else { return }
            ts.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: r)
        }
    }

    private static func dimMarkers(_ ts: NSMutableAttributedString, _ range: NSRange, markerLength: Int) {
        guard range.length > markerLength * 2 else { return }
        marker(ts, NSRange(location: range.location, length: markerLength))
        marker(ts, NSRange(location: NSMaxRange(range) - markerLength, length: markerLength))
    }

    /// Syntax characters: faded, and tagged so the editor can hide them
    /// outside the paragraph being edited.
    private static func marker(_ ts: NSMutableAttributedString, _ range: NSRange) {
        guard range.length > 0 else { return }
        ts.addAttributes([.foregroundColor: Theme.marker, .markdownMarker: true], range: range)
    }
}

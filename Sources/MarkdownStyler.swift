import AppKit

/// Live Markdown styling for the editor. The source stays plain Markdown;
/// this only paints it: headings get size, emphasis gets weight, and syntax
/// markers fade back so the words carry the page.
enum MarkdownStyler {
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are compile-time constants.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let heading = regex(#"^(#{1,6})[ \t]+"#)
    private static let quote = regex(#"^>[ \t]?"#)
    private static let list = regex(#"^[ \t]*([-*+]|\d+[.)])[ \t]+"#)
    private static let rule = regex(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let fence = regex(#"^[ \t]*(```|~~~)"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*_\w])"#)
    private static let code = regex(#"`([^`\n]+)`"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#)

    /// Styles every paragraph that intersects `range`. `range` should already
    /// be paragraph-aligned.
    static func apply(to ts: NSTextStorage, in range: NSRange, groups: [String: VariantGroup], showAlternates: Bool) {
        guard range.length > 0, NSMaxRange(range) <= ts.length else { return }
        let ns = ts.string as NSString

        for key in [NSAttributedString.Key.kern, .backgroundColor, .strikethroughStyle, .strikethroughColor, .markdownMarker] {
            ts.removeAttribute(key, range: range)
        }

        ns.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, line, enclosing, _ in
            styleParagraph(ts, ns: ns, line: line, enclosing: enclosing)
        }

        ts.enumerateAttribute(.ghost, in: range) { value, r, _ in
            if (value as? Bool) == true { ts.addAttribute(.foregroundColor, value: Theme.ghost, range: r) }
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

    private static func styleParagraph(_ ts: NSTextStorage, ns: NSString, line: NSRange, enclosing: NSRange) {
        ts.addAttributes(Theme.baseAttributes, range: enclosing)
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
        } else if fence.firstMatch(in: text, range: local) != nil {
            ts.addAttributes([.font: Theme.mono, .foregroundColor: Theme.marker], range: line)
            return
        } else if let m = list.firstMatch(in: text, range: local) {
            ts.addAttribute(.foregroundColor, value: Theme.accent, range: abs(m.range(at: 1)))
        }

        for m in code.matches(in: text, range: local) {
            ts.addAttributes([.font: Theme.mono, .backgroundColor: Theme.codeBackground], range: abs(m.range))
            marker(ts, abs(NSRange(location: m.range.location, length: 1)))
            marker(ts, abs(NSRange(location: NSMaxRange(m.range) - 1, length: 1)))
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

    private static func addTrait(_ trait: NSFontTraitMask, _ ts: NSTextStorage, _ range: NSRange) {
        ts.enumerateAttribute(.font, in: range) { value, r, _ in
            guard let font = value as? NSFont else { return }
            ts.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: r)
        }
    }

    private static func dimMarkers(_ ts: NSTextStorage, _ range: NSRange, markerLength: Int) {
        guard range.length > markerLength * 2 else { return }
        marker(ts, NSRange(location: range.location, length: markerLength))
        marker(ts, NSRange(location: NSMaxRange(range) - markerLength, length: markerLength))
    }

    /// Syntax characters: faded, and tagged so the editor can hide them
    /// outside the paragraph being edited.
    private static func marker(_ ts: NSTextStorage, _ range: NSRange) {
        guard range.length > 0 else { return }
        ts.addAttributes([.foregroundColor: Theme.marker, .markdownMarker: true], range: range)
    }
}

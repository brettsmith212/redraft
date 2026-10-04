import Foundation

/// Markdown editing commands, worked out on the text alone. Each returns a
/// `Change` for the editor to make as one undoable edit, or nil to leave the
/// key to its usual behavior.
enum MarkdownEditing {
    /// Replace `range` with `pieces`, then select `selection`. A piece keeps a
    /// stretch of the original text (with its ghosts and alternatives) or adds
    /// new text.
    struct Change: Equatable {
        var range: NSRange
        var pieces: [Piece]
        var selection: NSRange
    }

    enum Piece: Equatable {
        case kept(NSRange)
        case added(String)
    }

    /// The text a change leaves behind.
    static func apply(_ change: Change, to ns: NSString) -> String {
        let replacement = change.pieces.map { piece in
            switch piece {
            case .kept(let r): ns.substring(with: r)
            case .added(let s): s
            }
        }.joined()
        return ns.replacingCharacters(in: change.range, with: replacement)
    }

    // MARK: Lines

    private struct Line {
        /// Without its line break.
        let range: NSRange
        let blank: Bool
        let heading: Int?
        /// The indent of a list item's marker; nil for other lines.
        let listIndent: Int?
        let indent: Int
        let inCode: Bool
    }

    private static func lines(of ns: NSString) -> [Line] {
        let blocks = MarkdownStyler.codeBlocks(in: ns)
        var result: [Line] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, r, _, _ in
            let text = ns.substring(with: r)
            let local = NSRange(location: 0, length: r.length)
            let inCode = blocks.contains { NSLocationInRange(r.location, $0.whole) }
            let indent = Self.indent(of: text)
            let heading = inCode ? nil : MarkdownStyler.heading.firstMatch(in: text, range: local).map { $0.range(at: 1).length }
            let isItem = !inCode && MarkdownStyler.list.firstMatch(in: text, range: local) != nil
            result.append(Line(range: r, blank: text.trimmingCharacters(in: .whitespaces).isEmpty, heading: heading,
                               listIndent: isItem ? indent : nil, indent: indent, inCode: inCode))
        }
        return result
    }

    /// Leading whitespace in columns, a tab counting four.
    private static func indent(of text: String) -> Int {
        var columns = 0
        for c in text {
            if c == " " { columns += 1 } else if c == "\t" { columns += 4 } else { break }
        }
        return columns
    }

    private static func lineIndex(at location: Int, in lines: [Line]) -> Int? {
        lines.lastIndex { $0.range.location <= location }
    }

    // MARK: Moving paragraphs and sections

    /// Moves what the selection is in past its neighbor, up or down: on a
    /// heading, the section (the heading and everything under it, past the
    /// next section of the same level); on a list item, the item with its
    /// sub-items (within its list); otherwise the paragraph or code block. A
    /// selection across several paragraphs moves them together.
    static func move(_ selection: NSRange, up: Bool, in ns: NSString) -> Change? {
        let lines = lines(of: ns)
        guard let first = lineIndex(at: selection.location, in: lines),
              let last = lineIndex(at: max(selection.location, NSMaxRange(selection) - 1), in: lines),
              !lines[first].blank else { return nil }

        let unit: ClosedRange<Int>
        let neighbor: ClosedRange<Int>?
        if first == last || itemContaining(first, lines).map({ $0.contains(last) }) == true || section(at: first, lines)?.contains(last) == true {
            if let section = section(at: first, lines) {
                unit = section
                neighbor = up ? sectionBefore(section, lines) : sectionAfter(section, lines)
            } else if let item = itemContaining(first, lines) {
                unit = item
                neighbor = up ? itemBefore(item, lines) : itemAfter(item, lines)
            } else if let block = block(at: first, lines) {
                unit = block
                neighbor = up ? blockBefore(block, lines) : blockAfter(block, lines)
            } else {
                return nil
            }
        } else {
            guard let start = block(at: first, lines)?.lowerBound,
                  let end = (lines[last].blank ? blockBefore(last...last, lines) : block(at: last, lines))?.upperBound,
                  start <= end else { return nil }
            unit = start...end
            neighbor = up ? blockBefore(unit, lines) : blockAfter(unit, lines)
        }
        guard let neighbor else { return nil }

        func span(_ r: ClosedRange<Int>) -> NSRange {
            NSUnionRange(lines[r.lowerBound].range, lines[r.upperBound].range)
        }
        let moving = span(unit), other = span(neighbor)
        let (top, bottom) = up ? (other, moving) : (moving, other)
        let gap = NSRange(location: NSMaxRange(top), length: bottom.location - NSMaxRange(top))
        // The moving part lands where the other one started (going up), or
        // after the other one and the gap (going down).
        let landing = up ? top.location : top.location + bottom.length + gap.length
        return Change(range: NSUnionRange(top, bottom),
                      pieces: [.kept(bottom), .kept(gap), .kept(top)],
                      selection: NSRange(location: selection.location - moving.location + landing, length: selection.length))
    }

    /// The paragraph or code block holding a line, as line indices.
    private static func block(at i: Int, _ lines: [Line]) -> ClosedRange<Int>? {
        let line = lines[i]
        guard !line.blank || line.inCode else { return nil }
        if line.heading != nil { return i...i }
        func belongs(_ j: Int) -> Bool {
            line.inCode ? lines[j].inCode : (!lines[j].blank && lines[j].heading == nil && !lines[j].inCode)
        }
        var start = i, end = i
        while start > 0, belongs(start - 1) { start -= 1 }
        while end < lines.count - 1, belongs(end + 1) { end += 1 }
        return start...end
    }

    private static func previousText(before i: Int, _ lines: [Line]) -> Int? {
        var j = i - 1
        while j >= 0, lines[j].blank, !lines[j].inCode { j -= 1 }
        return j >= 0 ? j : nil
    }

    private static func nextText(after i: Int, _ lines: [Line]) -> Int? {
        var j = i + 1
        while j < lines.count, lines[j].blank, !lines[j].inCode { j += 1 }
        return j < lines.count ? j : nil
    }

    private static func blockBefore(_ unit: ClosedRange<Int>, _ lines: [Line]) -> ClosedRange<Int>? {
        previousText(before: unit.lowerBound, lines).flatMap { block(at: $0, lines) }
    }

    private static func blockAfter(_ unit: ClosedRange<Int>, _ lines: [Line]) -> ClosedRange<Int>? {
        nextText(after: unit.upperBound, lines).flatMap { block(at: $0, lines) }
    }

    /// A heading and everything under it, up to the next heading of the same
    /// or a higher level (blank lines at its end left out).
    private static func section(at i: Int, _ lines: [Line]) -> ClosedRange<Int>? {
        guard let level = lines[i].heading else { return nil }
        var end = i
        var j = i + 1
        while j < lines.count, (lines[j].heading ?? 7) > level {
            if !lines[j].blank || lines[j].inCode { end = j }
            j += 1
        }
        return i...end
    }

    private static func sectionBefore(_ section: ClosedRange<Int>, _ lines: [Line]) -> ClosedRange<Int>? {
        guard let level = lines[section.lowerBound].heading else { return nil }
        var j = section.lowerBound - 1
        while j >= 0, (lines[j].heading ?? 7) > level { j -= 1 }
        // Only past a sibling, never out from under a parent heading.
        guard j >= 0, lines[j].heading == level else { return nil }
        return self.section(at: j, lines)
    }

    private static func sectionAfter(_ section: ClosedRange<Int>, _ lines: [Line]) -> ClosedRange<Int>? {
        guard let level = lines[section.lowerBound].heading else { return nil }
        var j = section.upperBound + 1
        while j < lines.count, (lines[j].heading ?? 7) > level { j += 1 }
        guard j < lines.count, lines[j].heading == level else { return nil }
        return self.section(at: j, lines)
    }

    /// The list item a line belongs to (it, or the item it continues), with
    /// its sub-items and continuation lines.
    private static func itemContaining(_ i: Int, _ lines: [Line]) -> ClosedRange<Int>? {
        if lines[i].listIndent != nil { return item(at: i, lines) }
        var j = i
        while j > 0 {
            j -= 1
            let line = lines[j]
            if line.blank || line.heading != nil || line.inCode { return nil }
            if line.listIndent != nil { return item(at: j, lines).flatMap { $0.contains(i) ? $0 : nil } }
        }
        return nil
    }

    private static func item(at i: Int, _ lines: [Line]) -> ClosedRange<Int>? {
        guard let indent = lines[i].listIndent else { return nil }
        var end = i
        while end + 1 < lines.count {
            let next = lines[end + 1]
            if next.blank || next.heading != nil || next.inCode { break }
            if let nextIndent = next.listIndent, nextIndent <= indent { break }
            end += 1
        }
        return i...end
    }

    /// The item before, at the same depth in the same list.
    private static func itemBefore(_ unit: ClosedRange<Int>, _ lines: [Line]) -> ClosedRange<Int>? {
        guard let indent = lines[unit.lowerBound].listIndent else { return nil }
        var j = unit.lowerBound - 1
        while j >= 0 {
            let line = lines[j]
            if line.heading != nil || line.inCode { return nil }
            if let other = line.listIndent, other <= indent {
                // A sibling, right above (blank lines aside): not a parent, or another list.
                guard other == indent, let sibling = item(at: j, lines),
                      nextText(after: sibling.upperBound, lines) == unit.lowerBound else { return nil }
                return sibling
            }
            j -= 1
        }
        return nil
    }

    /// The item after, at the same depth in the same list.
    private static func itemAfter(_ unit: ClosedRange<Int>, _ lines: [Line]) -> ClosedRange<Int>? {
        guard let indent = lines[unit.lowerBound].listIndent,
              let j = nextText(after: unit.upperBound, lines), lines[j].listIndent == indent else { return nil }
        return item(at: j, lines)
    }

    // MARK: Emphasis and links

    /// Turns bold (`**`) or italic (`*`) on for the selection, or off when
    /// it's already there. With no selection it works on the word at the
    /// caret; between words, it adds an empty pair to type into.
    static func toggleEmphasis(bold: Bool, selection: NSRange, in ns: NSString) -> Change? {
        guard !MarkdownStyler.isInCode(at: selection.location, in: ns) else { return nil }
        let n = bold ? 2 : 1
        let marker = String(repeating: "*", count: n)
        let caret = selection.length == 0 ? selection.location : nil
        let r = caret.flatMap { word(at: $0, in: ns) } ?? trimmed(selection, in: ns)
        guard r.length > 0 else {
            return Change(range: NSRange(location: selection.location, length: 0), pieces: [.added(marker + marker)],
                          selection: NSRange(location: selection.location + n, length: 0))
        }
        // Italic is an odd run of stars (* or ***), bold a run of two or more.
        func has(_ stars: Int) -> Bool { bold ? stars >= 2 : stars % 2 == 1 }
        func keep(_ location: Int, _ length: Int) -> NSRange {
            caret.map { NSRange(location: $0 - n, length: 0) } ?? NSRange(location: location, length: length)
        }
        // Off, with the stars just outside the text…
        if has(min(stars(before: r.location, in: ns), stars(from: NSMaxRange(r), in: ns))) {
            return Change(range: NSRange(location: r.location - n, length: r.length + 2 * n), pieces: [.kept(r)],
                          selection: keep(r.location - n, r.length))
        }
        // …or selected along with it.
        let inside = min(stars(from: r.location, in: ns), stars(before: NSMaxRange(r), in: ns))
        if r.length > 2 * inside, has(inside) {
            let inner = NSRange(location: r.location + n, length: r.length - 2 * n)
            return Change(range: r, pieces: [.kept(inner)], selection: NSRange(location: r.location, length: inner.length))
        }
        return Change(range: r, pieces: [.added(marker), .kept(r), .added(marker)],
                      selection: caret.map { NSRange(location: $0 + n, length: 0) } ?? NSRange(location: r.location + n, length: r.length))
    }

    /// Makes the selection a link to `address` (or to an address still to be
    /// typed). The caret lands where there's something left to type.
    static func link(selection: NSRange, address: String?, in ns: NSString) -> Change? {
        guard !MarkdownStyler.isInCode(at: selection.location, in: ns) else { return nil }
        let r = trimmed(selection, in: ns)
        let tail = "](" + (address ?? "") + ")"
        let caret = r.length == 0 ? r.location + 1  // the link's text
            : address == nil ? r.location + 1 + r.length + 2  // its address
            : r.location + 1 + r.length + (tail as NSString).length  // after it
        return Change(range: r, pieces: [.added("["), .kept(r), .added(tail)], selection: NSRange(location: caret, length: 0))
    }

    /// Pasting a web address over selected words links them instead of
    /// replacing them.
    static func pasteLink(_ pasted: String, selection: NSRange, in ns: NSString) -> Change? {
        guard selection.length > 0, let address = webAddress(pasted) else { return nil }
        let selected = ns.substring(with: selection)
        guard !selected.contains("\n"), webAddress(selected) == nil else { return nil }
        return link(selection: selection, address: address, in: ns)
    }

    /// The text as a link address, when that's all it is (http, https or mailto).
    static func webAddress(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: t), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? t : nil
        case "mailto": return t
        default: return nil
        }
    }

    private static func stars(before location: Int, in ns: NSString) -> Int {
        var i = location
        while i > 0, ns.character(at: i - 1) == 42 { i -= 1 }
        return location - i
    }

    private static func stars(from location: Int, in ns: NSString) -> Int {
        var i = location
        while i < ns.length, ns.character(at: i) == 42 { i += 1 }
        return i - location
    }

    private static func trimmed(_ r: NSRange, in ns: NSString) -> NSRange {
        var r = r
        func blank(_ i: Int) -> Bool { [32, 9, 10, 13].contains(ns.character(at: i)) }
        while r.length > 0, blank(r.location) { r.location += 1; r.length -= 1 }
        while r.length > 0, blank(NSMaxRange(r) - 1) { r.length -= 1 }
        return r
    }

    /// The word around a caret, if it's in or next to one.
    private static func word(at caret: Int, in ns: NSString) -> NSRange? {
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let scalar = Unicode.Scalar(ns.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "\u{2019}"
        }
        var start = caret, end = caret
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: Lists

    /// A list item's start: indent, bullet or number with its delimiter, the
    /// space after, and a task's checkbox.
    private static let listItem = try! NSRegularExpression(pattern: #"^([ \t]*)(?:([-*+])|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#)

    /// Return in a list item starts the next one: the same bullet, the next
    /// number, a fresh checkbox for a task. On an empty item it steps out a
    /// level when nested, or ends the list.
    static func newline(at caret: Int, in ns: NSString) -> Change? {
        guard caret <= ns.length, !MarkdownStyler.isInCode(at: caret, in: ns) else { return nil }
        let line = MarkdownStyler.contentLine(at: caret, in: ns)
        let text = ns.substring(with: line) as NSString
        guard let m = listItem.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)),
              caret >= line.location + m.range.length else { return nil }
        let indent = text.substring(with: m.range(at: 1))
        if text.substring(from: m.range.length).trimmingCharacters(in: .whitespaces).isEmpty {
            guard indent.isEmpty else {
                let removed = outdentWidth(indent)
                return Change(range: NSRange(location: line.location, length: removed), pieces: [],
                              selection: NSRange(location: caret - removed, length: 0))
            }
            return Change(range: line, pieces: [], selection: NSRange(location: line.location, length: 0))
        }
        let marker: String
        if m.range(at: 2).location != NSNotFound {
            marker = text.substring(with: m.range(at: 2))
        } else {
            marker = "\((Int(text.substring(with: m.range(at: 3))) ?? 0) + 1)" + text.substring(with: m.range(at: 4))
        }
        let task = m.range(at: 6).location != NSNotFound ? "[ ] " : ""
        let insertion = "\n" + indent + marker + text.substring(with: m.range(at: 5)) + task
        return Change(range: NSRange(location: caret, length: 0), pieces: [.added(insertion)],
                      selection: NSRange(location: caret + (insertion as NSString).length, length: 0))
    }

    /// Tab nests the list items the selection touches one level deeper, and
    /// Shift-Tab brings them back out. Anywhere else, Tab is left alone.
    static func indentList(_ selection: NSRange, outdent: Bool, in ns: NSString) -> Change? {
        guard !MarkdownStyler.isInCode(at: selection.location, in: ns) else { return nil }
        let covered = ns.paragraphRange(for: selection)
        var lines: [NSRange] = []
        ns.enumerateSubstrings(in: covered, options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in lines.append(enclosing) }
        let items = lines.filter { listItem.firstMatch(in: ns.substring(with: $0), range: NSRange(location: 0, length: $0.length)) != nil }
        let blank = lines.filter { ns.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !items.isEmpty, items.count + blank.count == lines.count else { return nil }

        var pieces: [Piece] = []
        var caretShift = 0
        for line in lines {
            guard items.contains(line) else { pieces.append(.kept(line)); continue }
            let hasCaret = selection.location >= line.location && selection.location <= NSMaxRange(line)
            if outdent {
                let removed = outdentWidth(ns.substring(with: line))
                pieces.append(.kept(NSRange(location: line.location + removed, length: line.length - removed)))
                if hasCaret { caretShift = -min(removed, selection.location - line.location) }
            } else {
                pieces.append(contentsOf: [.added("\t"), .kept(line)])
                if hasCaret { caretShift = 1 }
            }
        }
        let change = Change(range: covered, pieces: pieces, selection: selection)
        let newLength = (apply(change, to: ns) as NSString).length - (ns.length - covered.length)
        guard newLength != covered.length else { return nil }  // nothing to bring out
        let newSelection = selection.length == 0
            ? NSRange(location: selection.location + caretShift, length: 0)
            : NSRange(location: covered.location, length: newLength - (ns.character(at: NSMaxRange(covered) - 1) == 10 ? 1 : 0))
        return Change(range: covered, pieces: pieces, selection: newSelection)
    }

    /// How much one level out removes from a line's start: a tab, or up to four spaces.
    private static func outdentWidth(_ text: String) -> Int {
        if text.hasPrefix("\t") { return 1 }
        return text.prefix(4).prefix { $0 == " " }.count
    }
}

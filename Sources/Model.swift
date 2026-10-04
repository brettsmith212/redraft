import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

enum OptionSource: String, Codable {
    case human, ai
}

struct VariantOption: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var source: OptionSource
}

/// A spot in the text that has more than one way of being written.
/// Option 0 is always the original wording.
struct VariantGroup: Codable, Identifiable, Equatable {
    var id: String
    var options: [VariantOption]
    var selected: Int = 0
}

extension NSAttributedString.Key {
    /// String id of the `VariantGroup` this text belongs to. Saved.
    static let variantGroup = NSAttributedString.Key("mw.variantGroup")
    /// `true` when the text is ghosted (dimmed, kept, ignored). Saved.
    static let ghost = NSAttributedString.Key("mw.ghost")
    /// Id of a Lab trim proposal. Transient.
    static let proposedCut = NSAttributedString.Key("mw.proposedCut")
    /// Markdown syntax characters (`#`, `**`, backticks…). Display-only; hidden
    /// outside the paragraph being edited.
    static let markdownMarker = NSAttributedString.Key("mw.markdownMarker")
    /// Id of a Lab review finding. Transient.
    static let labMark = NSAttributedString.Key("mw.labMark")
    /// A TK placeholder, still to be filled in. Display-only.
    static let placeholder = NSAttributedString.Key("mw.placeholder")
}

/// Reads and writes the on-disk format: plain Markdown, with ghosted text and
/// alternate spots wrapped in inline `<span>` tags (so any Markdown viewer
/// still shows the current wording), and the alternates themselves plus the
/// overflow drawer kept in a trailing HTML comment.
enum MarkdownCodec {
    struct Metadata: Codable {
        var version = 1
        var groups: [VariantGroup]
        var overflow: String
        /// The length the writer is aiming for, in words. Left out when unset.
        var target: Int?
    }

    static let metaOpen = "<!-- redraft"
    static let metaClose = "-->"
    static let ghostOpen = "<span data-mw-ghost>"
    static let altOpenPrefix = "<span data-mw-alt=\""
    static let spanClose = "</span>"

    // MARK: Encoding

    static func encode(storage: NSAttributedString, groups: [String: VariantGroup], overflow: String, target: Int? = nil) -> String {
        var out = ""
        var openGhost = false
        var openGroup: String?
        var used = Set<String>()
        let ns = storage.string as NSString
        // Text since the last tag, escaped as a whole (styling splits it into runs).
        var text = ""
        func flushText() {
            out += escaped(text, inSpan: openGhost || openGroup != nil)
            text = ""
        }

        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            let ghost = (attrs[.ghost] as? Bool) == true
            let group = attrs[.variantGroup] as? String
            if ghost != openGhost || group != openGroup { flushText() }
            if ghost != openGhost {
                if openGroup != nil { out += spanClose; openGroup = nil }
                if openGhost { out += spanClose }
                if ghost { out += ghostOpen }
                openGhost = ghost
            }
            if group != openGroup {
                if openGroup != nil { out += spanClose }
                if let group { out += altOpenPrefix + group + "\">" }
                openGroup = group
            }
            if let group { used.insert(group) }
            text += ns.substring(with: range)
        }
        flushText()
        if openGroup != nil { out += spanClose }
        if openGhost { out += spanClose }

        let keptGroups = groups.values
            .filter { used.contains($0.id) && !$0.options.isEmpty }
            .sorted { $0.id < $1.id }
        if keptGroups.isEmpty && overflow.isEmpty && target == nil { return out }

        let meta = Metadata(groups: keptGroups, overflow: overflow, target: target)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(meta) else { return out }
        // "--" can't appear inside an HTML comment; escape it inside JSON strings.
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "--", with: "-\\u002d")
        return out + "\n\n" + metaOpen + "\n" + json + "\n" + metaClose + "\n"
    }

    // MARK: Decoding

    static func decode(_ text: String) -> (NSAttributedString, [String: VariantGroup], String, Int?) {
        var body = text
        var groups: [String: VariantGroup] = [:]
        var overflow = ""
        var target: Int?

        if let open = text.range(of: metaOpen, options: .backwards),
           let close = text.range(of: metaClose, range: open.upperBound..<text.endIndex),
           text[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let json = text[open.upperBound..<close.lowerBound]
            if let meta = try? JSONDecoder().decode(Metadata.self, from: Data(json.utf8)) {
                groups = Dictionary(meta.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                overflow = meta.overflow
                target = meta.target
                body = String(text[..<open.lowerBound])
                if body.hasSuffix("\n\n") { body.removeLast(2) }
            }
        }

        let result = NSMutableAttributedString()
        var stack: [(ghost: Bool, group: String?)] = []
        var buffer = ""
        var ghost = false
        var group: String?

        func flush() {
            guard !buffer.isEmpty else { return }
            var attrs: [NSAttributedString.Key: Any] = [:]
            if ghost { attrs[.ghost] = true }
            if let group { attrs[.variantGroup] = group }
            result.append(NSAttributedString(string: unescaped(buffer, inSpan: ghost || group != nil), attributes: attrs))
            buffer = ""
        }

        var i = body.startIndex
        while i < body.endIndex {
            let rest = body[i...]
            if rest.hasPrefix(ghostOpen) {
                flush(); stack.append((ghost, group)); ghost = true
                i = body.index(i, offsetBy: ghostOpen.count); continue
            }
            if rest.hasPrefix(altOpenPrefix),
               let end = rest.range(of: "\">") {
                let id = String(rest[rest.index(rest.startIndex, offsetBy: altOpenPrefix.count)..<end.lowerBound])
                if !id.isEmpty, !id.contains("<"), !id.contains("\n") {
                    flush(); stack.append((ghost, group)); group = id
                    i = end.upperBound; continue
                }
            }
            if rest.hasPrefix(spanClose), let previous = stack.popLast() {
                flush(); ghost = previous.ghost; group = previous.group
                i = body.index(i, offsetBy: spanClose.count); continue
            }
            buffer.append(body[i])
            i = body.index(after: i)
        }
        flush()

        // Re-derive which option is showing from the text actually in the file.
        let ns = result.string as NSString
        result.enumerateAttribute(.variantGroup, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let id = value as? String, var g = groups[id] else { return }
            let current = ns.substring(with: range)
            if let index = g.options.firstIndex(where: { $0.text == current }) {
                g.selected = index
            } else if g.options.indices.contains(g.selected) {
                g.options[g.selected].text = current
            }
            groups[id] = g
        }
        return (result, groups, overflow, target)
    }

    // MARK: Escaping

    // Writing that looks like Redraft's own tags would read back as tags:
    // `<span data-mw-…` anywhere, and `</span>` inside a ghost or alternative
    // (where it would end the span early). Such text is written as `&lt;…`.
    // Text that already looks like that escape gets one more `amp;`, so
    // reading undoes exactly what writing did. Other text is left alone.
    private static let tagText = try! NSRegularExpression(pattern: "<(span data-mw-|/span>)")
    private static let openTagText = try! NSRegularExpression(pattern: "<(span data-mw-)")
    private static let escapedTagText = try! NSRegularExpression(pattern: "&((?:amp;)*lt;(?:span data-mw-|/span>))")
    private static let escapedOpenTagText = try! NSRegularExpression(pattern: "&((?:amp;)*lt;span data-mw-)")
    private static let tagEscape = try! NSRegularExpression(pattern: "&lt;(span data-mw-|/span>)")
    private static let openTagEscape = try! NSRegularExpression(pattern: "&lt;(span data-mw-)")
    private static let doubledEscape = try! NSRegularExpression(pattern: "&amp;((?:amp;)*lt;(?:span data-mw-|/span>))")
    private static let doubledOpenEscape = try! NSRegularExpression(pattern: "&amp;((?:amp;)*lt;span data-mw-)")

    private static func escaped(_ text: String, inSpan: Bool) -> String {
        guard text.contains("span") else { return text }
        let alreadyEscaped = inSpan ? escapedTagText : escapedOpenTagText
        let tags = inSpan ? tagText : openTagText
        return replace(tags, "&lt;$1", in: replace(alreadyEscaped, "&amp;$1", in: text))
    }

    private static func unescaped(_ text: String, inSpan: Bool) -> String {
        guard text.contains("span") else { return text }
        let escapes = inSpan ? tagEscape : openTagEscape
        let doubled = inSpan ? doubledEscape : doubledOpenEscape
        return replace(doubled, "&$1", in: replace(escapes, "<$1", in: text))
    }

    private static func replace(_ regex: NSRegularExpression, _ template: String, in text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }
}

/// How long writing takes to read, at 238 words a minute: the average for
/// silent reading of non-fiction (Brysbaert, 2019).
enum ReadingTime {
    static let wordsPerMinute = 238.0

    static func label(words: Int) -> String {
        guard words > 0 else { return "Nothing to read yet" }
        if Double(words) < wordsPerMinute { return "Under a minute to read" }
        return "About \(Int((Double(words) / wordsPerMinute).rounded(.up))) min read"
    }
}

/// Picks "a" or "an" for the word that follows.
enum Article {
    static func wantsAn(_ text: String) -> Bool {
        let word = text
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
            .lowercased()
        guard let first = word.first else { return false }
        for prefix in ["hour", "honest", "honor", "honour", "heir"] where word.hasPrefix(prefix) { return true }
        for prefix in ["uni", "use", "usu", "uti", "ure", "eu", "one", "once", "ewe", "ubiq", "uran", "uro"]
            where word.hasPrefix(prefix) { return false }
        if first.isNumber { return word.hasPrefix("8") || word.hasPrefix("11") || word.hasPrefix("18") }
        return "aeiou".contains(first)
    }
}

/// Small deterministic RNG so hand-drawn marks look the same on every redraw.
struct SeededRandom {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    init(string: String) {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        self.init(hash)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }

    mutating func range(_ r: ClosedRange<CGFloat>) -> CGFloat { r.lowerBound + (r.upperBound - r.lowerBound) * unit() }
}

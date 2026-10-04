import Foundation

/// The essay as a reader gets it: the text with ghosted passages taken out.
/// Where a ghost comes out, the spacing either side of it is tidied, so no
/// doubled space, trailing space or extra blank line is left behind.
/// Everything else stays exactly as written, two-space line breaks and code
/// included.
enum CleanCopy {
    static func markdown(from text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var out = ""
        var afterGhost = false
        text.enumerateAttribute(.ghost, in: NSRange(location: 0, length: text.length)) { value, r, _ in
            if (value as? Bool) == true {
                afterGhost = true
            } else {
                let kept = ns.substring(with: r)
                out = afterGhost ? join(out, kept) : out + kept
                afterGhost = false
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Joins the text either side of a removed ghost. Within a line the
    /// whitespace between them becomes one space. Across lines it becomes the
    /// line breaks of the side with more, keeping how the line before ends
    /// (it may be a two-space line break) and the indent of the line after.
    private static func join(_ left: String, _ right: String) -> String {
        func isBlank(_ c: Character) -> Bool { c == " " || c == "\t" || c.isNewline }
        let leftCore = left[..<(left.lastIndex { !isBlank($0) }.map(left.index(after:)) ?? left.startIndex)]
        let leftSpace = left[leftCore.endIndex...]
        let rightStart = right.firstIndex { !isBlank($0) } ?? right.endIndex
        let rightSpace = right[..<rightStart]
        let rightCore = right[rightStart...]

        let leftBreaks = leftSpace.filter(\.isNewline).count
        let rightBreaks = rightSpace.filter(\.isNewline).count
        guard leftBreaks + rightBreaks > 0 else {
            return String(leftCore) + (leftSpace.isEmpty && rightSpace.isEmpty ? "" : " ") + rightCore
        }
        let lineEnd = leftBreaks > 0 ? leftSpace[..<leftSpace.firstIndex(where: \.isNewline)!] : ""
        let indentFrom = rightBreaks > 0 ? rightSpace : leftSpace
        let indent = indentFrom[indentFrom.index(after: indentFrom.lastIndex(where: \.isNewline)!)...]
        return String(leftCore) + lineEnd + String(repeating: "\n", count: max(leftBreaks, rightBreaks)) + indent + rightCore
    }
}

import AppKit

/// Key mappings from Settings, written like a vimrc:
///
///     inoremap jk <Esc>
///     nnoremap ; :
///
/// All mappings are non-recursive (the right-hand side isn't re-mapped).
struct VimMappings {
    enum Mode { case normal, insert, visual }

    var normal: [[String]: [String]] = [:]
    var insert: [[String]: [String]] = [:]
    var visual: [[String]: [String]] = [:]
    var errors: [String] = []

    private static let commands: [String: [Mode]] = {
        var table: [String: [Mode]] = [:]
        for name in ["map", "noremap", "no", "nor"] { table[name] = [.normal, .visual] }
        for name in ["nmap", "nnoremap", "nn", "nno", "nnor"] { table[name] = [.normal] }
        for name in ["imap", "inoremap", "ino", "inor", "inomap"] { table[name] = [.insert] }
        for name in ["vmap", "vnoremap", "vn", "vno", "xmap", "xnoremap", "xn", "xno"] { table[name] = [.visual] }
        return table
    }()

    static func parse(_ text: String) -> VimMappings {
        var result = VimMappings()
        for (number, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("\"") { continue }
            let parts = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count == 3, let modes = commands[parts[0].lowercased()] else {
                result.errors.append("Line \(number + 1): expected something like “inoremap jk <Esc>”.")
                continue
            }
            let lhs = tokens(parts[1])
            let rhs = tokens(parts[2].trimmingCharacters(in: .whitespaces))
            guard !lhs.isEmpty, !rhs.isEmpty else {
                result.errors.append("Line \(number + 1): missing keys.")
                continue
            }
            for mode in modes {
                switch mode {
                case .normal: result.normal[lhs] = rhs
                case .insert: result.insert[lhs] = rhs
                case .visual: result.visual[lhs] = rhs
                }
            }
        }
        return result
    }

    /// Splits key notation like `jk<Esc>` into tokens: "j", "k", "<Esc>".
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", let close = s[i...].firstIndex(of: ">"), close > s.index(after: i),
               let name = canonical(String(s[s.index(after: i)..<close])) {
                out.append(name)
                i = s.index(after: close)
                continue
            }
            out.append(String(s[i]))
            i = s.index(after: i)
        }
        return out
    }

    private static func canonical(_ raw: String) -> String? {
        let name = raw.lowercased()
        switch name {
        case "esc": return "<Esc>"
        case "cr", "enter", "return": return "<CR>"
        case "bs", "backspace": return "<BS>"
        case "tab": return "<Tab>"
        case "space": return " "
        case "lt": return "<"
        case "bar": return "|"
        case "bslash": return "\\"
        case "del", "delete": return "<Del>"
        case "up": return "<Up>"
        case "down": return "<Down>"
        case "left": return "<Left>"
        case "right": return "<Right>"
        case "home": return "<Home>"
        case "end": return "<End>"
        case "nop": return "<Nop>"
        default:
            if name.hasPrefix("c-"), name.count == 3 { return "<C-\(name.last!)>" }
            return nil
        }
    }
}

/// Vim-style modal editing on top of the editor's NSTextView. Insert mode is
/// plain NSTextView typing (so input methods, smart quotes and spelling all
/// keep working); normal and visual mode commands are interpreted here.
@MainActor
final class VimEngine {
    enum Mode: String {
        case normal = "NORMAL", insert = "INSERT", visual = "VISUAL", visualLine = "V-LINE"
    }

    static let defaultMappings = """
    " One mapping per line, vimrc style. For example:
    " inoremap jk <Esc>

    """

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "vimEnabled") }
    static var mappingsText: String { UserDefaults.standard.string(forKey: "vimMappings") ?? defaultMappings }

    weak var textView: EditorTextView?
    var onStateChange: (() -> Void)?

    private(set) var mode: Mode = .normal {
        didSet { if oldValue != mode { stateChanged() } }
    }
    private(set) var pendingKeys = ""

    private var wasEnabled = false
    private var mappings = VimMappings()
    private var mappingsSource: String?

    private var keys: [String] = []
    private var mapBuffer: [String] = []
    private var mapTimer: Timer?
    private var insertPending: [String] = []
    private var insertTimer: Timer?
    private var executingMapped = false

    private var register = (text: "", linewise: false)
    private var pasteboardCount = -1

    private var recording: [String]?
    private var lastChange: [String] = []
    private var replaying = false

    private var lastFind: (kind: String, char: String)?
    private var goalX: CGFloat?
    private var anchor = 0
    private var cursor = 0
    private var busy = 0

    init(textView: EditorTextView) {
        self.textView = textView
        wasEnabled = Self.enabled
    }

    var isActive: Bool { Self.enabled }
    var showsBlockCaret: Bool { Self.enabled && mode == .normal }

    /// Status text for the window ("NORMAL", "VISUAL d2"…), or nil when Vim is off.
    var statusText: String? {
        guard Self.enabled else { return nil }
        return pendingKeys.isEmpty ? mode.rawValue : "\(mode.rawValue)  \(pendingKeys)"
    }

    func settingsChanged() {
        let enabled = Self.enabled
        if enabled != wasEnabled {
            wasEnabled = enabled
            keys = []
            mapBuffer = []
            insertPending = []
            if enabled {
                mode = .normal
                if let tv = textView { setCaret(clampNormal(tv.selectedRange().location)) }
            } else {
                mode = .insert
            }
            stateChanged()
        }
    }

    private func stateChanged() {
        textView?.scheduleCaretUpdate()
        onStateChange?()
    }

    private func refreshMappings() {
        let text = Self.mappingsText
        if text != mappingsSource {
            mappingsSource = text
            mappings = VimMappings.parse(text)
        }
    }

    // MARK: Keys

    /// Returns true when Vim consumed the key.
    func handle(_ event: NSEvent) -> Bool {
        guard Self.enabled else { return false }
        refreshMappings()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false }
        guard let token = Self.token(for: event) else {
            // Unrecognized keys (dead keys, function keys) type in insert mode only.
            return mode != .insert
        }
        if mode == .insert { return handleInsert(token) }
        feedMapped(token)
        return true
    }

    static func token(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: return "<Esc>"
        case 36, 76: return "<CR>"
        case 51: return "<BS>"
        case 117: return "<Del>"
        case 48: return "<Tab>"
        case 123: return "<Left>"
        case 124: return "<Right>"
        case 125: return "<Down>"
        case 126: return "<Up>"
        case 115: return "<Home>"
        case 119: return "<End>"
        default: break
        }
        if flags.contains(.control) {
            guard let c = event.charactersIgnoringModifiers?.lowercased(), c.count == 1 else { return nil }
            return c == "[" ? "<Esc>" : "<C-\(c)>"
        }
        guard let chars = event.characters, chars.count == 1,
              let scalar = chars.unicodeScalars.first, !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        return chars
    }

    // MARK: Insert mode

    private func handleInsert(_ token: String) -> Bool {
        if !replaying && !executingMapped {
            let candidate = insertPending + [token]
            if let rhs = mappings.insert[candidate] {
                // The earlier keys of the mapping were typed as text; take them back.
                retractTyped(insertPending.count)
                if let count = recording?.count { recording?.removeLast(min(count, insertPending.count)) }
                insertPending = []
                insertTimer?.invalidate()
                runMapped(rhs)
                return true
            }
            let isPrefix = token.count == 1 && mappings.insert.keys.contains {
                $0.count > candidate.count && Array($0.prefix(candidate.count)) == candidate
            }
            if isPrefix {
                insertPending = candidate
                insertTimer?.invalidate()
                insertTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.insertPending = [] }
                }
                recording?.append(token)
                return false
            }
            if !insertPending.isEmpty {
                insertPending = []
                return handleInsert(token)
            }
        }
        return insertKey(token)
    }

    private func retractTyped(_ count: Int) {
        guard count > 0, let tv = textView else { return }
        let selection = tv.selectedRange()
        guard selection.length == 0, selection.location >= count else { return }
        replace(NSRange(location: selection.location - count, length: count), with: "")
    }

    /// Typing in insert mode. Real keystrokes go to NSTextView (returns false);
    /// replayed or mapped keys are applied here.
    private func insertKey(_ token: String) -> Bool {
        if token == "<Esc>" {
            exitInsert()
            return true
        }
        if token == "<Nop>" { return true }
        recording?.append(token)
        guard replaying || executingMapped, let tv = textView else { return false }
        switch token {
        case "<CR>": tv.insertNewline(nil)
        case "<BS>": tv.deleteBackward(nil)
        case "<Del>": tv.deleteForward(nil)
        case "<Tab>": tv.insertTab(nil)
        case "<Left>": tv.moveLeft(nil)
        case "<Right>": tv.moveRight(nil)
        case "<Up>": tv.moveUp(nil)
        case "<Down>": tv.moveDown(nil)
        default:
            if !token.hasPrefix("<") || token == "<" {
                tv.insertText(token, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        return true
    }

    private func enterInsert(at location: Int) {
        setCaret(location)
        textView?.breakUndoCoalescing()
        mode = .insert
    }

    private func exitInsert() {
        guard let tv = textView else { return }
        insertPending = []
        if tv.hasMarkedText() { tv.unmarkText() }
        tv.breakUndoCoalescing()
        mode = .normal
        var loc = tv.selectedRange().location
        if loc > lineRange(loc).location { loc -= 1 }
        setCaret(clampNormal(loc))
        if let recorded = recording, !replaying {
            lastChange = recorded + ["<Esc>"]
        }
        recording = nil
    }

    // MARK: Mappings in normal / visual mode

    private func feedMapped(_ token: String) {
        let table = mode == .normal ? mappings.normal : mappings.visual
        if table.isEmpty || awaitingCharacter || executingMapped {
            process(token)
            return
        }
        mapBuffer.append(token)
        mapTimer?.invalidate()
        let buffer = mapBuffer
        let longer = table.keys.contains { $0.count > buffer.count && Array($0.prefix(buffer.count)) == buffer }
        if longer {
            updatePending()
            mapTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.resolveMapBuffer() }
            }
            return
        }
        resolveMapBuffer()
    }

    private func resolveMapBuffer() {
        let table = mode == .normal ? mappings.normal : mappings.visual
        let buffer = mapBuffer
        mapBuffer = []
        if let rhs = table[buffer] {
            runMapped(rhs)
        } else {
            for token in buffer { process(token) }
        }
    }

    private func runMapped(_ tokens: [String]) {
        let wasExecuting = executingMapped
        executingMapped = true
        defer { executingMapped = wasExecuting }
        for token in tokens where token != "<Nop>" {
            if mode == .insert { _ = insertKey(token) } else { process(token) }
        }
    }

    private var awaitingCharacter: Bool {
        guard let last = keys.last else { return false }
        if ["f", "F", "t", "T", "r", "]", "["].contains(last) { return true }
        if last == "i" || last == "a" {
            return mode == .visual || mode == .visualLine || keys.dropLast().contains { ["d", "c", "y"].contains($0) }
        }
        return false
    }

    private func updatePending() {
        pendingKeys = (keys + mapBuffer).map { $0 == " " ? "␣" : $0 }.joined()
        onStateChange?()
    }

    // MARK: Command parsing

    private enum Motion: Equatable {
        case left, right, down, up, displayDown, displayUp, nextLineStart, previousLineStart
        case wordForward(big: Bool), wordBackward(big: Bool), wordEnd(big: Bool)
        case lineStart, firstNonBlank, lineEnd, fileStart, fileEnd
        case screenLineStart, screenFirstNonBlank, screenLineEnd
        case paragraphForward, paragraphBackward, sentenceForward, sentenceBackward
        case find(kind: String, char: String), repeatFind(reverse: Bool)
    }

    private struct TextObject {
        let around: Bool
        let kind: String
    }

    private enum Target {
        case motion(Motion), lines, object(TextObject)
    }

    private enum Command {
        case move(Motion, count: Int?)
        case operate(String, Target, count: Int)
        case action(String, count: Int, arg: String?)
        case visualOperation(String, arg: String?)
        case visualObject(TextObject)
    }

    private enum Parse {
        case incomplete, invalid, command(Command)
    }

    private enum MotionParse {
        case found(Motion), incomplete, invalid
    }

    private var isVisual: Bool { mode == .visual || mode == .visualLine }

    private func process(_ token: String) {
        if token == "<Esc>" {
            if keys.isEmpty && isVisual { exitVisual() }
            keys = []
            updatePending()
            return
        }
        keys.append(token)
        switch parse(keys) {
        case .incomplete:
            updatePending()
        case .invalid:
            keys = []
            updatePending()
        case .command(let command):
            let typed = keys
            keys = []
            updatePending()
            busy += 1
            execute(command, keys: typed)
            busy -= 1
        }
    }

    private func parse(_ k: [String]) -> Parse {
        var i = 0
        func readCount() -> Int? {
            var digits = ""
            while i < k.count, k[i].count == 1, let c = k[i].first, c.isASCII, c.isNumber, !(digits.isEmpty && c == "0") {
                digits.append(c)
                i += 1
            }
            return Int(digits)
        }
        let count1 = readCount()
        guard i < k.count else { return .incomplete }
        let key = k[i]

        if let motion = parseMotion(k, &i) {
            switch motion {
            case .found(let m): return i == k.count ? .command(.move(m, count: count1)) : .invalid
            case .incomplete: return .incomplete
            case .invalid: return .invalid
            }
        }

        if isVisual {
            if key == "i" || key == "a" {
                guard i + 1 < k.count else { return .incomplete }
                return .command(.visualObject(TextObject(around: key == "a", kind: k[i + 1])))
            }
            if key == "r" {
                guard i + 1 < k.count else { return .incomplete }
                return .command(.visualOperation("r", arg: k[i + 1]))
            }
            let ops: Set<String> = ["d", "x", "<Del>", "X", "D", "c", "s", "C", "S", "y", "Y", "~", "u", "U", "J", "p", "P", "o", "O", "v", "V"]
            return ops.contains(key) ? .command(.visualOperation(key, arg: nil)) : .invalid
        }

        if key == "d" || key == "c" || key == "y" {
            i += 1
            let count2 = readCount()
            guard i < k.count else { return .incomplete }
            let total = (count1 ?? 1) * (count2 ?? 1)
            if k[i] == key { return i + 1 == k.count ? .command(.operate(key, .lines, count: total)) : .invalid }
            if k[i] == "i" || k[i] == "a" {
                guard i + 1 < k.count else { return .incomplete }
                let object = TextObject(around: k[i] == "a", kind: k[i + 1])
                return i + 2 == k.count ? .command(.operate(key, .object(object), count: total)) : .invalid
            }
            switch parseMotion(k, &i) {
            case .found(let m)?: return i == k.count ? .command(.operate(key, .motion(m), count: total)) : .invalid
            case .incomplete?: return .incomplete
            default: return .invalid
            }
        }

        let count = count1 ?? 1
        // ]a / [a: next / previous alternative of the word under the cursor.
        if key == "]" || key == "[" {
            guard i + 1 < k.count else { return .incomplete }
            guard k[i + 1] == "a", i + 2 == k.count else { return .invalid }
            return .command(.action(key == "]" ? "]a" : "[a", count: count, arg: nil))
        }
        if key == "r" {
            guard i + 1 < k.count else { return .incomplete }
            return i + 2 == k.count ? .command(.action("r", count: count, arg: k[i + 1])) : .invalid
        }
        let actions: Set<String> = [
            "x", "<Del>", "X", "s", "S", "D", "C", "Y", "p", "P", "u", "<C-r>", "J", "~",
            "i", "a", "I", "A", "o", "O", "v", "V", ".", "n", "N", "/", "?", "*",
            "<C-d>", "<C-u>", "<C-f>", "<C-b>",
        ]
        return actions.contains(key) && i + 1 == k.count ? .command(.action(key, count: count, arg: nil)) : .invalid
    }

    private func parseMotion(_ k: [String], _ i: inout Int) -> MotionParse? {
        let key = k[i]
        func one(_ m: Motion) -> MotionParse { i += 1; return .found(m) }
        switch key {
        case "h", "<Left>", "<BS>": return one(.left)
        case "l", "<Right>", " ": return one(.right)
        case "j", "<Down>", "<C-n>": return one(.down)
        case "k", "<Up>", "<C-p>": return one(.up)
        case "<CR>", "+": return one(.nextLineStart)
        case "-": return one(.previousLineStart)
        case "w": return one(.wordForward(big: false))
        case "W": return one(.wordForward(big: true))
        case "b": return one(.wordBackward(big: false))
        case "B": return one(.wordBackward(big: true))
        case "e": return one(.wordEnd(big: false))
        case "E": return one(.wordEnd(big: true))
        case "0", "<Home>": return one(Self.screenLines ? .screenLineStart : .lineStart)
        case "^", "_": return one(Self.screenLines ? .screenFirstNonBlank : .firstNonBlank)
        case "$", "<End>": return one(Self.screenLines ? .screenLineEnd : .lineEnd)
        case "G": return one(.fileEnd)
        case "}": return one(.paragraphForward)
        case "{": return one(.paragraphBackward)
        case ")": return one(.sentenceForward)
        case "(": return one(.sentenceBackward)
        case ";": return one(.repeatFind(reverse: false))
        case ",": return one(.repeatFind(reverse: true))
        case "f", "F", "t", "T":
            guard i + 1 < k.count else { return .incomplete }
            let char = k[i + 1]
            guard char.count == 1 else { return .invalid }
            i += 2
            return .found(.find(kind: key, char: char))
        case "g":
            guard i + 1 < k.count else { return .incomplete }
            switch k[i + 1] {
            case "g": i += 2; return .found(.fileStart)
            case "j": i += 2; return .found(.displayDown)
            case "k": i += 2; return .found(.displayUp)
            case "_": i += 2; return .found(.lineEnd)
            case "0": i += 2; return .found(.screenLineStart)
            case "^": i += 2; return .found(.screenFirstNonBlank)
            case "$": i += 2; return .found(.screenLineEnd)
            default: return .invalid
            }
        default:
            return nil
        }
    }

    // MARK: Execution

    private func execute(_ command: Command, keys typed: [String]) {
        guard let tv = textView else { return }
        switch command {
        case .move(let motion, let count):
            let from = isVisual ? cursor : tv.selectedRange().location
            guard let destination = target(of: motion, from: from, count: count, forOperator: mode == .visualLine && !Self.screenLines) else { return }
            let vertical = [.down, .up, .displayDown, .displayUp].contains(motion)
            if isVisual {
                cursor = destination.index
                applyVisual()
                if !vertical { goalX = nil }
            } else {
                setCaret(clampNormal(destination.index), keepGoal: vertical)
            }

        case .operate(let op, let what, let count):
            let from = tv.selectedRange().location
            guard let (range, linewise) = resolve(what, op: op, from: from, count: count) else { return }
            if op != "y" { noteChange(typed, entersInsert: op == "c") }
            apply(op, to: range, linewise: linewise, from: from)

        case .action(let name, let count, let arg):
            perform(name, count: count, arg: arg, keys: typed)

        case .visualOperation(let name, let arg):
            visualOperation(name, arg: arg)

        case .visualObject(let object):
            guard let range = textObject(object, at: cursor, count: 1), range.length > 0 else { return }
            if mode == .visualLine { mode = .visual }
            anchor = range.location
            cursor = NSMaxRange(range) - 1
            applyVisual()
        }
    }

    private func noteChange(_ typed: [String], entersInsert: Bool) {
        guard !replaying else { return }
        if entersInsert { recording = typed } else { lastChange = typed }
    }

    private func resolve(_ what: Target, op: String, from: Int, count: Int) -> (NSRange, Bool)? {
        switch what {
        case .lines:
            if Self.screenLines, let screen = screenLines(from: from, count: count, op: op) { return screen }
            let lastLine = lineNumber(from) + count - 1
            let start = lineRange(from).location
            let end = NSMaxRange(lineRange(lineStart(ofLine: min(lastLine, lineCount - 1))))
            return (NSRange(location: start, length: end - start), true)
        case .object(let object):
            guard let range = textObject(object, at: from, count: count) else { return nil }
            let linewise = object.kind == "p"
            return (range, linewise)
        case .motion(var motion):
            // "cw" changes to the end of the word, like "ce".
            if op == "c", case .wordForward(let big) = motion, from < length, classOf(from, big: big) > 0 {
                motion = .wordEnd(big: big)
                if classOf(min(from + 1, length - 1), big: big) != classOf(from, big: big) || from + 1 >= length {
                    return (NSRange(location: from, length: 1), false)
                }
            }
            guard let t = target(of: motion, from: from, count: count, forOperator: true) else { return nil }
            if t.linewise {
                let a = min(from, t.index), b = max(from, t.index)
                let start = lineRange(a).location
                let end = NSMaxRange(lineRange(b))
                return (NSRange(location: start, length: end - start), true)
            }
            var a = min(from, t.index)
            var b = max(from, t.index) + (t.inclusive ? 1 : 0)
            if case .wordForward = motion {
                // "dw" on a line's last word stops at the end of the line.
                let content = contentRange(from)
                if b > NSMaxRange(content), from < NSMaxRange(content) { b = NSMaxRange(content) }
            }
            a = max(0, a)
            b = min(length, b)
            return b > a ? (NSRange(location: a, length: b - a), false) : nil
        }
    }

    /// dd / cc / yy on the lines you see. A span that covers whole
    /// paragraphs stays linewise; part of a wrapped paragraph is plain text,
    /// and the paragraph break is left alone so paragraphs don't merge.
    private func screenLines(from: Int, count: Int, op: String) -> (NSRange, Bool)? {
        guard let first = screenLineChars(from), first.length > 0 else { return nil }
        var last = first
        for _ in 1..<max(1, count) {
            guard NSMaxRange(last) < length, let next = screenLineChars(NSMaxRange(last)), next.length > 0 else { break }
            last = next
        }
        var range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let paragraphStart = lineRange(range.location).location == range.location
        let endsParagraph = NSMaxRange(range) == length || char(NSMaxRange(range) - 1) == 10
        if paragraphStart && endsParagraph { return nil }  // whole paragraphs: the usual linewise path

        if op == "c" {
            // Change only the words, keeping the space or break that follows.
            while range.length > 0, [10, 13, 32, 9].contains(char(NSMaxRange(range) - 1)) { range.length -= 1 }
        } else if endsParagraph {
            // The paragraph's last visible line: keep its break, and take the
            // space that joined it to the line above.
            if char(NSMaxRange(range) - 1) == 10 { range.length -= 1 }
            while range.location > 0, [32, 9].contains(char(range.location - 1)) {
                range.location -= 1
                range.length += 1
            }
        }
        return (range, false)
    }

    private func apply(_ op: String, to range: NSRange, linewise: Bool, from: Int) {
        let text = substring(range)
        switch op {
        case "y":
            setRegister(text, linewise: linewise)
            setCaret(clampNormal(linewise ? from : range.location))
        case "d":
            setRegister(text, linewise: linewise)
            var deletion = range
            // Deleting a final line that has no line break: take the preceding break instead.
            if linewise, !text.hasSuffix("\n"), range.location > 0, char(range.location - 1) == 10 {
                deletion = NSRange(location: range.location - 1, length: range.length + 1)
            }
            replace(deletion, with: "")
            setCaret(linewise ? firstNonBlank(min(deletion.location, length)) : clampNormal(deletion.location))
        case "c":
            setRegister(text, linewise: linewise)
            if linewise {
                var content = range
                if text.hasSuffix("\n") { content.length -= 1 }
                // Keep the line's indentation.
                var indentEnd = content.location
                while indentEnd < NSMaxRange(content), char(indentEnd) == 32 || char(indentEnd) == 9 { indentEnd += 1 }
                replace(NSRange(location: indentEnd, length: NSMaxRange(content) - indentEnd), with: "")
                enterInsert(at: indentEnd)
            } else {
                replace(range, with: "")
                enterInsert(at: range.location)
            }
        default:
            break
        }
    }

    private func perform(_ name: String, count: Int, arg: String?, keys typed: [String]) {
        guard let tv = textView else { return }
        let loc = tv.selectedRange().location
        let content = contentRange(loc)
        switch name {
        case "x", "<Del>":
            let end = min(loc + count, NSMaxRange(content))
            guard end > loc else { return }
            noteChange(typed, entersInsert: false)
            apply("d", to: NSRange(location: loc, length: end - loc), linewise: false, from: loc)
        case "X":
            let start = max(content.location, loc - count)
            guard start < loc else { return }
            noteChange(typed, entersInsert: false)
            apply("d", to: NSRange(location: start, length: loc - start), linewise: false, from: loc)
        case "s":
            noteChange(typed, entersInsert: true)
            let end = min(loc + count, NSMaxRange(content))
            if end > loc { setRegister(substring(NSRange(location: loc, length: end - loc)), linewise: false) }
            replace(NSRange(location: loc, length: max(0, end - loc)), with: "")
            enterInsert(at: loc)
        case "S":
            execute(.operate("c", .lines, count: count), keys: typed)
        case "C":
            execute(.operate("c", .motion(Self.screenLines ? .screenLineEnd : .lineEnd), count: count), keys: typed)
        case "D":
            execute(.operate("d", .motion(Self.screenLines ? .screenLineEnd : .lineEnd), count: count), keys: typed)
        case "Y":
            execute(.operate("y", .lines, count: count), keys: typed)
        case "p", "P":
            noteChange(typed, entersInsert: false)
            paste(after: name == "p", count: count)
        case "u", "<C-r>":
            tv.breakUndoCoalescing()
            for _ in 0..<count {
                if name == "u" { tv.undoManager?.undo() } else { tv.undoManager?.redo() }
            }
            setCaret(clampNormal(tv.selectedRange().location))
        case "r":
            guard let arg, arg.count == 1, loc + count <= NSMaxRange(content) else { return }
            noteChange(typed, entersInsert: false)
            replace(NSRange(location: loc, length: count), with: String(repeating: arg, count: count))
            setCaret(loc + count - 1)
        case "J":
            noteChange(typed, entersInsert: false)
            joinLines(from: loc, count: max(2, count))
        case "~":
            let end = min(loc + count, NSMaxRange(content))
            guard end > loc else { return }
            noteChange(typed, entersInsert: false)
            let range = NSRange(location: loc, length: end - loc)
            replace(range, with: toggledCase(substring(range)))
            setCaret(clampNormal(end))
        case "i":
            noteChange(typed, entersInsert: true)
            enterInsert(at: loc)
        case "a":
            noteChange(typed, entersInsert: true)
            enterInsert(at: content.length == 0 ? loc : min(loc + 1, NSMaxRange(content)))
        case "I":
            noteChange(typed, entersInsert: true)
            enterInsert(at: Self.screenLines ? screenFirstNonBlank(loc) : firstNonBlank(loc))
        case "A":
            noteChange(typed, entersInsert: true)
            // On a wrapped line, append right after the last visible word.
            enterInsert(at: Self.screenLines ? NSMaxRange(screenContent(loc, trimSpaces: true)) : NSMaxRange(content))
        case "o":
            noteChange(typed, entersInsert: true)
            let at = NSMaxRange(content)
            replace(NSRange(location: at, length: 0), with: "\n")
            enterInsert(at: at + 1)
        case "O":
            noteChange(typed, entersInsert: true)
            replace(NSRange(location: content.location, length: 0), with: "\n")
            enterInsert(at: content.location)
        case "v", "V":
            anchor = loc
            cursor = loc
            mode = name == "v" ? .visual : .visualLine
            applyVisual()
        case ".":
            guard !lastChange.isEmpty else { return }
            let change = lastChange
            replaying = true
            for _ in 0..<count { for token in change { if mode == .insert { _ = insertKey(token) } else { process(token) } } }
            if mode == .insert { exitInsert() }
            replaying = false
        case "]a", "[a":
            tv.session?.cycleAtCaret(name == "]a" ? count : -count)
            setCaret(clampNormal(tv.selectedRange().location))
        case "n", "N":
            find(name == "n" ? .nextMatch : .previousMatch)
        case "*":
            let word = textObject(TextObject(around: false, kind: "w"), at: loc, count: 1).map(substring) ?? ""
            guard !word.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let pb = NSPasteboard(name: .find)
            pb.clearContents()
            pb.setString(word, forType: .string)
            find(.nextMatch)
        case "/", "?":
            tv.performTextFinderAction(Self.finderItem(.showFindInterface))
        case "<C-d>", "<C-u>", "<C-f>", "<C-b>":
            let visibleLines = max(1, Int((tv.visibleRect.height / (Theme.body.boundingRectForFont.height * Theme.paragraph.lineHeightMultiple)).rounded()))
            let lines = name == "<C-d>" || name == "<C-u>" ? max(1, visibleLines / 2) : max(1, visibleLines - 2)
            let target = displayLineTarget(from: loc, by: name == "<C-d>" || name == "<C-f>" ? lines : -lines)
            setCaret(clampNormal(target))
        default:
            break
        }
    }

    private static func finderItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = action.rawValue
        return item
    }

    private func find(_ action: NSTextFinder.Action) {
        guard let tv = textView else { return }
        tv.performTextFinderAction(Self.finderItem(action))
        let selection = tv.selectedRange()
        if selection.length > 0 { setCaret(selection.location) }
    }

    // MARK: Visual mode

    private func visualRange() -> NSRange {
        let a = min(anchor, cursor), b = max(anchor, cursor)
        if mode == .visualLine {
            // With wrapped-line motions on, V works on the lines you see.
            if Self.screenLines, let first = screenLineChars(a), let last = screenLineChars(b) {
                return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            }
            let start = lineRange(a).location
            let end = NSMaxRange(lineRange(b))
            return NSRange(location: start, length: end - start)
        }
        let end = min(b + 1, length)
        return NSRange(location: a, length: max(0, end - a))
    }

    private func applyVisual() {
        guard let tv = textView else { return }
        busy += 1
        tv.setSelectedRange(visualRange())
        tv.scrollRangeToVisible(NSRange(location: min(cursor, length), length: 0))
        busy -= 1
        stateChanged()
    }

    private func exitVisual(at location: Int? = nil) {
        let loc = location ?? cursor
        mode = .normal
        setCaret(clampNormal(min(loc, length)))
    }

    private func visualOperation(_ name: String, arg: String?) {
        let range = visualRange()
        // A screen-line V selection is linewise only when it reaches the end
        // of its paragraph; otherwise it's a plain span of text.
        let screenVisualLine = mode == .visualLine && Self.screenLines
        let linewise = screenVisualLine
            ? range.length > 0 && char(NSMaxRange(range) - 1) == 10
            : mode == .visualLine || ["X", "D", "Y", "S", "C"].contains(name)
        let lineRangeAll: NSRange = screenVisualLine ? range : {
            let start = lineRange(range.location).location
            let end = NSMaxRange(lineRange(max(range.location, NSMaxRange(range) - 1)))
            return NSRange(location: start, length: end - start)
        }()
        let target = linewise ? lineRangeAll : range
        switch name {
        case "d", "x", "<Del>", "X", "D":
            mode = .normal
            apply("d", to: target, linewise: linewise, from: target.location)
        case "c", "s", "C", "S":
            mode = .normal
            apply("c", to: target, linewise: linewise, from: target.location)
        case "y", "Y":
            mode = .normal
            apply("y", to: target, linewise: linewise, from: target.location)
            setCaret(clampNormal(target.location))
        case "~", "u", "U":
            let text = substring(range)
            let changed = name == "~" ? toggledCase(text) : name == "u" ? text.lowercased() : text.uppercased()
            replace(range, with: changed)
            exitVisual(at: range.location)
        case "r":
            guard let arg, arg.count == 1 else { return }
            let text = substring(range)
            replace(range, with: String(text.map { $0 == "\n" ? "\n" : Character(arg) }))
            exitVisual(at: range.location)
        case "J":
            let lines = max(2, lineNumber(max(range.location, NSMaxRange(range) - 1)) - lineNumber(range.location) + 1)
            mode = .normal
            joinLines(from: range.location, count: lines)
        case "p", "P":
            let (text, isLinewise) = currentRegister()
            mode = .normal
            setRegister(substring(target), linewise: linewise)
            replace(target, with: isLinewise && !linewise ? "\n" + text : text)
            setCaret(clampNormal(target.location))
        case "o", "O":
            swap(&anchor, &cursor)
            applyVisual()
        case "v":
            if mode == .visual { exitVisual() } else { mode = .visual; applyVisual() }
        case "V":
            if mode == .visualLine { exitVisual() } else { mode = .visualLine; applyVisual() }
        default:
            break
        }
    }

    // MARK: Selection sync

    /// Called when the selection changes outside Vim (mouse, Find, the panels).
    func selectionDidChange() {
        guard Self.enabled, busy == 0, mode != .insert else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let tv = self.textView, self.busy == 0, self.mode != .insert else { return }
            let selection = tv.selectedRange()
            if selection.length > 0 {
                if !self.isVisual { self.mode = .visual }
                self.anchor = selection.location
                self.cursor = NSMaxRange(selection) - 1
                self.stateChanged()
            } else {
                if self.isVisual { self.mode = .normal }
                let clamped = self.clampNormal(selection.location)
                if clamped != selection.location { self.setCaret(clamped) }
                self.goalX = nil
            }
        }
    }

    // MARK: Editing helpers

    private func setCaret(_ location: Int, keepGoal: Bool = false) {
        guard let tv = textView else { return }
        busy += 1
        let loc = max(0, min(location, length))
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        tv.scrollRangeToVisible(NSRange(location: loc, length: 0))
        busy -= 1
        if !keepGoal { goalX = nil }
        tv.scheduleCaretUpdate()
    }

    private func replace(_ range: NSRange, with text: String) {
        guard let tv = textView, let ts = tv.textStorage, NSMaxRange(range) <= ts.length else { return }
        busy += 1
        defer { busy -= 1 }
        if tv.shouldChangeText(in: range, replacementString: text) {
            ts.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: Theme.baseAttributes))
            tv.didChangeText()
        }
    }

    private func setRegister(_ text: String, linewise: Bool) {
        register = (text, linewise)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pasteboardCount = pb.changeCount
    }

    private func currentRegister() -> (String, Bool) {
        let pb = NSPasteboard.general
        if pb.changeCount != pasteboardCount, let text = pb.string(forType: .string) {
            register = (text, text.hasSuffix("\n"))
            pasteboardCount = pb.changeCount
        }
        return register
    }

    private func paste(after: Bool, count: Int) {
        guard let tv = textView else { return }
        let (text, linewise) = currentRegister()
        guard !text.isEmpty else { return }
        let loc = tv.selectedRange().location
        let repeated = String(repeating: text, count: max(1, count))
        if linewise {
            var block = repeated.hasSuffix("\n") ? repeated : repeated + "\n"
            var at: Int
            if after {
                at = NSMaxRange(lineRange(loc))
                if at == length, length > 0, char(length - 1) != 10 {
                    block = "\n" + String(block.dropLast())
                }
            } else {
                at = lineRange(loc).location
            }
            replace(NSRange(location: at, length: 0), with: block)
            setCaret(firstNonBlank(at + (block.hasPrefix("\n") ? 1 : 0)))
        } else {
            let content = contentRange(loc)
            let at = after && content.length > 0 ? min(loc + 1, NSMaxRange(content)) : loc
            replace(NSRange(location: at, length: 0), with: repeated)
            setCaret(clampNormal(at + (repeated as NSString).length - 1))
        }
    }

    private func joinLines(from loc: Int, count: Int) {
        var position = loc
        for _ in 0..<(count - 1) {
            let content = contentRange(position)
            let newline = NSMaxRange(content)
            guard newline < length else { break }
            var end = newline + 1
            while end < length, char(end) == 32 || char(end) == 9 { end += 1 }
            let nextIsEmpty = end >= length || char(end) == 10
            let needsSpace = content.length > 0 && !nextIsEmpty && char(newline - 1) != 32
            replace(NSRange(location: newline, length: end - newline), with: needsSpace ? " " : "")
            position = newline
        }
        setCaret(clampNormal(position))
    }

    private func toggledCase(_ text: String) -> String {
        String(text.map { c in
            let s = String(c)
            return s == s.uppercased() ? Character(s.lowercased()) : Character(s.uppercased())
        })
    }

    // MARK: Text geometry

    private var string: NSString { (textView?.string ?? "") as NSString }
    private var length: Int { string.length }
    private func char(_ i: Int) -> unichar { string.character(at: i) }
    private func substring(_ r: NSRange) -> String { string.substring(with: r) }

    private func lineRange(_ i: Int) -> NSRange {
        string.lineRange(for: NSRange(location: max(0, min(i, length)), length: 0))
    }

    private func contentRange(_ i: Int) -> NSRange {
        var r = lineRange(i)
        while r.length > 0, char(NSMaxRange(r) - 1) == 10 || char(NSMaxRange(r) - 1) == 13 { r.length -= 1 }
        return r
    }

    private func clampNormal(_ i: Int) -> Int {
        let r = contentRange(i)
        if r.length == 0 { return r.location }
        return min(max(i, r.location), NSMaxRange(r) - 1)
    }

    private func firstNonBlank(_ i: Int) -> Int {
        let r = contentRange(i)
        var j = r.location
        while j < NSMaxRange(r), char(j) == 32 || char(j) == 9 { j += 1 }
        return r.length == 0 ? r.location : min(j, NSMaxRange(r) - 1)
    }

    private var lineCount: Int {
        var count = 1
        for i in 0..<length where char(i) == 10 { count += 1 }
        if length > 0, char(length - 1) == 10 { count -= 1 }
        return max(1, count)
    }

    private func lineNumber(_ i: Int) -> Int {
        var count = 0
        for j in 0..<min(i, length) where char(j) == 10 { count += 1 }
        return count
    }

    private func lineStart(ofLine n: Int) -> Int {
        var line = 0
        var j = 0
        while line < n, j < length {
            if char(j) == 10 { line += 1 }
            j += 1
        }
        return j
    }

    /// 0 = whitespace, 1 = word characters (or any non-blank for WORDs), 2 = punctuation, -1 = line break.
    private func classOf(_ i: Int, big: Bool) -> Int {
        let c = char(i)
        if c == 10 { return -1 }
        if c == 32 || c == 9 || c == 13 { return 0 }
        if big { return 1 }
        if c == 95 { return 1 }
        if let s = Unicode.Scalar(c), CharacterSet.alphanumerics.contains(s) { return 1 }
        if (0xD800...0xDFFF).contains(c) { return 1 }
        return 2
    }

    private struct Destination {
        var index: Int
        var linewise = false
        var inclusive = false
    }

    private func target(of motion: Motion, from: Int, count: Int?, forOperator: Bool) -> Destination? {
        let n = count ?? 1
        let len = length
        switch motion {
        case .left:
            return Destination(index: max(contentRange(from).location, from - n))
        case .right:
            let content = contentRange(from)
            let limit = forOperator ? NSMaxRange(content) : max(content.location, NSMaxRange(content) - 1)
            return Destination(index: min(from + n, limit))
        case .down, .up:
            if forOperator || !Self.screenLines {
                let line = lineNumber(from)
                let targetLine = motion == .down ? min(line + n, lineCount - 1) : max(line - n, 0)
                if targetLine == line && forOperator && n > 0 && mode != .visualLine { return nil }
                let column = from - lineRange(from).location
                let start = lineStart(ofLine: targetLine)
                let content = contentRange(start)
                return Destination(index: min(start + column, max(content.location, NSMaxRange(content) - 1)), linewise: true)
            }
            return Destination(index: displayLineTarget(from: from, by: motion == .down ? n : -n))
        case .displayDown, .displayUp:
            return Destination(index: displayLineTarget(from: from, by: motion == .displayDown ? n : -n))
        case .nextLineStart, .previousLineStart:
            let line = lineNumber(from)
            let targetLine = motion == .nextLineStart ? min(line + n, lineCount - 1) : max(line - n, 0)
            return Destination(index: firstNonBlank(lineStart(ofLine: targetLine)), linewise: true)
        case .wordForward(let big):
            var i = from
            for _ in 0..<n { i = wordForward(i, big: big) }
            return Destination(index: min(i, len))
        case .wordBackward(let big):
            var i = from
            for _ in 0..<n { i = wordBackward(i, big: big) }
            return Destination(index: i)
        case .wordEnd(let big):
            var i = from
            for _ in 0..<n { i = wordEnd(i, big: big) }
            return Destination(index: i, inclusive: true)
        case .lineStart:
            return Destination(index: lineRange(from).location)
        case .screenLineStart:
            return Destination(index: screenContent(from, trimSpaces: false).location)
        case .screenFirstNonBlank:
            return Destination(index: screenFirstNonBlank(from))
        case .screenLineEnd:
            var at = from
            if n > 1 {
                at = displayLineTarget(from: from, by: n - 1)
                goalX = nil
            }
            let content = screenContent(at, trimSpaces: true)
            let end = forOperator ? NSMaxRange(content) : max(content.location, NSMaxRange(content) - 1)
            return Destination(index: end, inclusive: false)
        case .firstNonBlank:
            return Destination(index: firstNonBlank(from))
        case .lineEnd:
            let line = min(lineNumber(from) + n - 1, lineCount - 1)
            let content = contentRange(lineStart(ofLine: line))
            let end = forOperator ? NSMaxRange(content) : max(content.location, NSMaxRange(content) - 1)
            return Destination(index: end, inclusive: false)
        case .fileStart, .fileEnd:
            let line = count.map { max(0, min($0 - 1, lineCount - 1)) } ?? (motion == .fileStart ? 0 : lineCount - 1)
            return Destination(index: firstNonBlank(lineStart(ofLine: line)), linewise: true)
        case .paragraphForward, .paragraphBackward:
            var i = from
            for _ in 0..<n { i = paragraphBoundary(from: i, forward: motion == .paragraphForward) }
            return Destination(index: i)
        case .sentenceForward, .sentenceBackward:
            var i = from
            for _ in 0..<n { i = sentenceBoundary(from: i, forward: motion == .sentenceForward) }
            return Destination(index: i)
        case .find(let kind, let char):
            lastFind = (kind, char)
            return findOnLine(kind: kind, char: char, from: from, count: n, forOperator: forOperator)
        case .repeatFind(let reverse):
            guard let last = lastFind else { return nil }
            var kind = last.kind
            if reverse {
                kind = ["f": "F", "F": "f", "t": "T", "T": "t"][kind] ?? kind
            }
            return findOnLine(kind: kind, char: last.char, from: from, count: n, forOperator: forOperator, repeating: true)
        }
    }

    private func findOnLine(kind: String, char target: String, from: Int, count: Int, forOperator: Bool, repeating: Bool = false) -> Destination? {
        let content = contentRange(from)
        guard let unit = target.utf16.first else { return nil }
        let forward = kind == "f" || kind == "t"
        let till = kind == "t" || kind == "T"
        var i = from
        var found = 0
        // Repeating a "till" search skips the character it's already against.
        if repeating && till { i += forward ? 1 : -1 }
        while found < count {
            i += forward ? 1 : -1
            guard i >= content.location, i < NSMaxRange(content) else { return nil }
            if char(i) == unit { found += 1 }
        }
        let index = till ? i + (forward ? -1 : 1) : i
        return Destination(index: index, inclusive: forward)
    }

    private func wordForward(_ start: Int, big: Bool) -> Int {
        let n = length
        var i = start
        guard i < n else { return n }
        let c0 = classOf(i, big: big)
        if c0 > 0 { while i < n, classOf(i, big: big) == c0 { i += 1 } }
        while i < n {
            let c = classOf(i, big: big)
            if c == -1 {
                i += 1
                if i < n, char(i) == 10 { return i }
                continue
            }
            if c == 0 { i += 1; continue }
            break
        }
        return i
    }

    private func wordEnd(_ start: Int, big: Bool) -> Int {
        let n = length
        var i = start + 1
        guard i < n else { return max(0, n - 1) }
        while i < n, classOf(i, big: big) <= 0 { i += 1 }
        guard i < n else { return n - 1 }
        let c = classOf(i, big: big)
        while i + 1 < n, classOf(i + 1, big: big) == c { i += 1 }
        return i
    }

    private func wordBackward(_ start: Int, big: Bool) -> Int {
        var i = start - 1
        guard i >= 0 else { return 0 }
        while i > 0, classOf(i, big: big) <= 0 {
            if char(i) == 10, char(i - 1) == 10 { return i }
            i -= 1
        }
        let c = classOf(i, big: big)
        if c <= 0 { return i }
        while i > 0, classOf(i - 1, big: big) == c { i -= 1 }
        return i
    }

    /// Whether line motions (0 ^ $ I A D C, and j/k) follow wrapped lines on
    /// screen rather than whole paragraphs. On by default: in prose a
    /// paragraph is one long line.
    static var screenLines: Bool {
        UserDefaults.standard.object(forKey: "vimScreenLines") as? Bool ?? true
    }

    /// The characters on the screen line containing `loc`.
    private func screenLineChars(_ loc: Int) -> NSRange? {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, length > 0 else { return nil }
        if loc >= length, char(length - 1) == 10 { return NSRange(location: length, length: 0) }
        lm.ensureLayout(for: tc)
        let glyph = lm.glyphIndexForCharacter(at: min(loc, length - 1))
        var lineGlyphs = NSRange()
        _ = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        return lm.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
    }

    /// A screen line without its line break, and optionally without the
    /// trailing space where it wraps.
    private func screenContent(_ loc: Int, trimSpaces: Bool) -> NSRange {
        guard var r = screenLineChars(loc) else { return contentRange(loc) }
        while r.length > 0, char(NSMaxRange(r) - 1) == 10 || char(NSMaxRange(r) - 1) == 13 { r.length -= 1 }
        if trimSpaces {
            while r.length > 0, char(NSMaxRange(r) - 1) == 32 || char(NSMaxRange(r) - 1) == 9 { r.length -= 1 }
        }
        return r
    }

    private func screenFirstNonBlank(_ loc: Int) -> Int {
        let r = screenContent(loc, trimSpaces: false)
        var j = r.location
        while j < NSMaxRange(r), char(j) == 32 || char(j) == 9 { j += 1 }
        return r.length == 0 ? r.location : min(j, NSMaxRange(r) - 1)
    }

    private func isBlankLine(_ i: Int) -> Bool {
        contentRange(i).length == 0
    }

    private func paragraphBoundary(from start: Int, forward: Bool) -> Int {
        var line = lineNumber(start)
        let last = lineCount - 1
        if forward {
            while line < last, isBlankLine(lineStart(ofLine: line)) { line += 1 }
            while line < last {
                line += 1
                if isBlankLine(lineStart(ofLine: line)) { return lineStart(ofLine: line) }
            }
            return max(0, length - (length > 0 && char(length - 1) == 10 ? 1 : 0))
        } else {
            while line > 0, isBlankLine(lineStart(ofLine: line)) { line -= 1 }
            while line > 0 {
                line -= 1
                if isBlankLine(lineStart(ofLine: line)) { return lineStart(ofLine: line) }
            }
            return 0
        }
    }

    private static let sentenceStart = try! NSRegularExpression(pattern: #"(?:[.!?]['"’”)\]]*[ \t]+|\n[ \t]*\n[ \t]*)(?=\S)"#)

    private func sentenceStarts() -> [Int] {
        let text = string as String
        var starts = [0]
        for m in Self.sentenceStart.matches(in: text, range: NSRange(location: 0, length: length)) {
            starts.append(NSMaxRange(m.range))
        }
        return starts
    }

    private func sentenceBoundary(from start: Int, forward: Bool) -> Int {
        let starts = sentenceStarts()
        if forward { return starts.first { $0 > start } ?? max(0, length - 1) }
        return starts.last { $0 < start } ?? 0
    }

    private func textObject(_ object: TextObject, at loc: Int, count: Int) -> NSRange? {
        let len = length
        guard len > 0 else { return nil }
        let i = min(loc, len - 1)
        switch object.kind {
        case "w", "W":
            let big = object.kind == "W"
            let c = classOf(i, big: big)
            guard c >= 0 else { return NSRange(location: i, length: 0) }
            var a = i, b = i + 1
            while a > 0, classOf(a - 1, big: big) == c { a -= 1 }
            while b < len, classOf(b, big: big) == c { b += 1 }
            if object.around {
                var e = b
                while e < len, char(e) == 32 || char(e) == 9 { e += 1 }
                if e > b { b = e } else { while a > 0, char(a - 1) == 32 || char(a - 1) == 9 { a -= 1 } }
            }
            return NSRange(location: a, length: b - a)
        case "s":
            let starts = sentenceStarts()
            let a = starts.last { $0 <= i } ?? 0
            let next = starts.first { $0 > i } ?? len
            var b = next
            let paragraph = contentRange(i)
            b = min(b, NSMaxRange(paragraph))
            if !object.around { while b > a, char(b - 1) == 32 || char(b - 1) == 9 { b -= 1 } }
            return NSRange(location: a, length: b - a)
        case "p":
            var first = lineNumber(i), last = first
            let blank = isBlankLine(i)
            while first > 0, isBlankLine(lineStart(ofLine: first - 1)) == blank { first -= 1 }
            while last < lineCount - 1, isBlankLine(lineStart(ofLine: last + 1)) == blank { last += 1 }
            if object.around {
                while last < lineCount - 1, isBlankLine(lineStart(ofLine: last + 1)) != blank { last += 1 }
            }
            let start = lineStart(ofLine: first)
            let end = NSMaxRange(lineRange(lineStart(ofLine: last)))
            return NSRange(location: start, length: end - start)
        case "\"", "'", "`":
            guard let quote = object.kind.utf16.first else { return nil }
            let content = contentRange(i)
            var positions: [Int] = []
            for j in content.location..<NSMaxRange(content) where char(j) == quote { positions.append(j) }
            var pair: (Int, Int)?
            for k in stride(from: 0, to: positions.count - 1, by: 2) {
                let (a, b) = (positions[k], positions[k + 1])
                if a <= i && i <= b { pair = (a, b); break }
                if a > i { pair = (a, b); break }
            }
            guard let (a, b) = pair else { return nil }
            return object.around ? NSRange(location: a, length: b - a + 1) : NSRange(location: a + 1, length: b - a - 1)
        case "(", ")", "b", "[", "]", "{", "}", "B", "<", ">":
            let pairs: [String: (unichar, unichar)] = [
                "(": (40, 41), ")": (40, 41), "b": (40, 41), "[": (91, 93), "]": (91, 93),
                "{": (123, 125), "}": (123, 125), "B": (123, 125), "<": (60, 62), ">": (60, 62),
            ]
            guard let (open, close) = pairs[object.kind] else { return nil }
            var depth = 0
            var a = i
            while a >= 0 {
                if char(a) == close && a != i { depth += 1 }
                if char(a) == open { if depth == 0 { break }; depth -= 1 }
                a -= 1
            }
            guard a >= 0 else { return nil }
            depth = 0
            var b = a + 1
            while b < len {
                if char(b) == open { depth += 1 }
                if char(b) == close { if depth == 0 { break }; depth -= 1 }
                b += 1
            }
            guard b < len else { return nil }
            return object.around ? NSRange(location: a, length: b - a + 1) : NSRange(location: a + 1, length: b - a - 1)
        default:
            return nil
        }
    }

    /// Moves by lines as they appear on screen, keeping the horizontal position.
    private func displayLineTarget(from loc: Int, by delta: Int) -> Int {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, length > 0 else { return loc }
        lm.ensureLayout(for: tc)
        let glyph = lm.glyphIndexForCharacter(at: min(loc, length - 1))
        var lineGlyphs = NSRange()
        var fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let x = goalX ?? (fragment.minX + lm.location(forGlyphAt: glyph).x)
        goalX = x
        for _ in 0..<abs(delta) {
            if delta > 0 {
                let next = NSMaxRange(lineGlyphs)
                guard next < lm.numberOfGlyphs else { break }
                fragment = lm.lineFragmentRect(forGlyphAt: next, effectiveRange: &lineGlyphs)
            } else {
                guard lineGlyphs.location > 0 else { break }
                fragment = lm.lineFragmentRect(forGlyphAt: lineGlyphs.location - 1, effectiveRange: &lineGlyphs)
            }
        }
        var fraction: CGFloat = 0
        let hit = lm.glyphIndex(for: NSPoint(x: x, y: fragment.midY), in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let chars = lm.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
        let index = lm.characterIndexForGlyph(at: hit)
        return max(chars.location, min(index, NSMaxRange(chars) - 1))
    }
}

#if DEBUG
extension VimEngine {
    /// Types key notation (e.g. `dw`, `A five<Esc>`) by sending synthetic key
    /// events through the text view's real keyDown path, one key per event
    /// like a fast typist, then calls `done`.
    func debugType(_ notation: String, done: @escaping @MainActor () -> Void) {
        let tokens = VimMappings.tokens(notation)
        func send(_ index: Int) {
            guard index < tokens.count else { done(); return }
            debugSend(tokens[index])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { MainActor.assumeIsolated { send(index + 1) } }
        }
        send(0)
    }

    private func debugSend(_ token: String) {
        guard let tv = textView else { return }
        let trace = ProcessInfo.processInfo.environment["REDRAFT_VIM_TRACE"]
        let specials: [String: (UInt16, String)] = [
            "<Esc>": (53, "\u{1b}"), "<CR>": (36, "\r"), "<BS>": (51, "\u{7f}"), "<Tab>": (48, "\t"),
            "<Left>": (123, "\u{F702}"), "<Right>": (124, "\u{F703}"), "<Down>": (125, "\u{F701}"), "<Up>": (126, "\u{F700}"),
        ]
        do {
            var flags: NSEvent.ModifierFlags = []
            var keyCode: UInt16 = 0
            var chars = token
            if let special = specials[token] {
                keyCode = special.0
                chars = special.1
            } else if token.hasPrefix("<C-"), token.count == 5 {
                flags = .control
                chars = String(token.dropFirst(3).prefix(1))
            }
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: tv.window?.windowNumber ?? 0, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
            ) else { return }
            tv.keyDown(with: event)
            if let trace {
                let line = "\(token.debugDescription) -> \(mode.rawValue) sel=\(tv.selectedRange()) len=\(tv.string.utf16.count)\n"
                if let h = FileHandle(forWritingAtPath: trace) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? line.write(toFile: trace, atomically: true, encoding: .utf8) }
            }
        }
    }
}
#endif

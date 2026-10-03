import AppKit
import SwiftUI

/// Redraft's own shortcuts, in one place. Two styles:
/// - Control (⌃⇧ + letter): for Caps-Lock-as-Control setups. Plain ⌃ keys are
///   left alone for Vim (⌃r, ⌃d…) and macOS text editing (⌃a, ⌃e, ⌃k…).
/// - Command: conventional Mac shortcuts.
/// Standard Mac commands (⌘S, ⌘Z, ⌘C, ⌘,) never change.
enum AppShortcut: CaseIterable {
    case toggleTools, alternatives, aiAlternatives, nextAlternative, previousAlternative
    case ghost, stash, overflowPanel, labPanel, preview, zen, copyClean, allTabs, shortcutsCard

    enum Style: String, CaseIterable, Identifiable {
        case command, control  // the default first
        var id: String { rawValue }
        var title: String { self == .control ? "Control (⌃⇧)" : "Command (⌘)" }
    }

    static var style: Style {
        Style(rawValue: UserDefaults.standard.string(forKey: "shortcutStyle") ?? "") ?? .command
    }

    var title: String {
        switch self {
        case .toggleTools: "Toggle writing tools"
        case .alternatives: "Alternatives"
        case .aiAlternatives: "AI alternatives"
        case .nextAlternative: "Next alternative"
        case .previousAlternative: "Previous alternative"
        case .ghost: "Ghost or revive"
        case .stash: "Stash in overflow"
        case .overflowPanel: "Overflow"
        case .labPanel: "Lab"
        case .preview: "Preview Markdown"
        case .zen: "Zen mode"
        case .copyClean: "Copy clean text"
        case .allTabs: "Show all tabs"
        case .shortcutsCard: "Keyboard shortcuts"
        }
    }

    /// The key and modifiers for the given style.
    func binding(_ style: Style = AppShortcut.style) -> (key: KeyEquivalent, modifiers: EventModifiers) {
        // Like ⌘, for Settings, ⌘/ (the shortcuts card) and ⇧⌘\ (Show All
        // Tabs) are the same in either style.
        if self == .shortcutsCard { return ("/", [.command]) }
        if self == .allTabs { return ("\\", [.command, .shift]) }
        switch style {
        case .control:
            let letter: Character = switch self {
            case .toggleTools: "e"
            case .alternatives: "a"
            case .aiAlternatives: "i"
            case .nextAlternative: "j"
            case .previousAlternative: "k"
            case .ghost: "g"
            case .stash: "s"
            case .overflowPanel: "o"
            case .labPanel: "l"
            case .preview: "p"
            case .zen: "z"
            case .copyClean: "c"
            case .allTabs: "\\"  // unused: always ⇧⌘\ (see binding)
            case .shortcutsCard: "/"  // unused: always ⌘/ (see binding)
            }
            return (KeyEquivalent(letter), [.control, .shift])
        case .command:
            switch self {
            case .toggleTools: return ("e", [.command, .shift])
            case .alternatives: return ("a", [.command, .option])
            case .aiAlternatives: return ("i", [.command, .option])
            case .nextAlternative: return (.downArrow, [.command, .option])
            case .previousAlternative: return (.upArrow, [.command, .option])
            case .ghost: return ("g", [.command, .option])
            case .stash: return ("s", [.command, .option])
            case .overflowPanel: return ("o", [.command, .option])
            case .labPanel: return ("l", [.command, .option])
            case .preview: return ("p", [.command, .option])
            case .zen: return ("z", [.command, .control])
            case .copyClean: return ("c", [.command, .shift])
            case .allTabs: return ("\\", [.command, .shift])
            case .shortcutsCard: return ("/", [.command])
            }
        }
    }

    var keyboardShortcut: KeyboardShortcut {
        let b = binding()
        return KeyboardShortcut(b.key, modifiers: b.modifiers)
    }

    /// Display text, e.g. "⌃⇧A" or "⌥⌘↓".
    var label: String {
        let b = binding()
        var text = ""
        if b.modifiers.contains(.control) { text += "⌃" }
        if b.modifiers.contains(.option) { text += "⌥" }
        if b.modifiers.contains(.shift) { text += "⇧" }
        if b.modifiers.contains(.command) { text += "⌘" }
        switch b.key {
        case .downArrow: text += "↓"
        case .upArrow: text += "↑"
        default: text += String(b.key.character).uppercased()
        }
        return text
    }

    /// The Control-style shortcut for a key event, if any. The editor checks
    /// this before Vim sees the key, so ⌃⇧ shortcuts work in every mode.
    static func controlStyleMatch(for event: NSEvent) -> AppShortcut? {
        guard style == .control else { return nil }
        let flags = event.modifierFlags.intersection([.control, .shift, .option, .command])
        guard flags == [.control, .shift], let key = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
        return allCases.first { $0 != .shortcutsCard && $0 != .allTabs && $0.binding(.control).key.character == key }
    }
}

extension View {
    func keyboardShortcut(_ shortcut: AppShortcut) -> some View {
        keyboardShortcut(shortcut.keyboardShortcut)
    }
}

extension EditorSession {
    func perform(_ shortcut: AppShortcut) {
        switch shortcut {
        case .toggleTools: featuresOn.toggle()
        case .alternatives: alternativesShortcut()
        case .aiAlternatives: aiAlternatives(for: nil)
        case .nextAlternative: cycleAtCaret(1)
        case .previousAlternative: cycleAtCaret(-1)
        case .ghost: toggleGhost(range: nil)
        case .stash: stash(range: nil)
        case .overflowPanel:
            featuresOn = true
            rightPanel = rightPanel == .overflow ? nil : .overflow
        case .labPanel:
            featuresOn = true
            rightPanel = rightPanel == .lab ? nil : .lab
        case .preview: previewing.toggle()
        case .zen: toggleZen()
        case .copyClean: copyCleanText()
        case .allTabs: showingTabs.toggle()
        case .shortcutsCard: showShortcuts.toggle()
        }
    }
}

import AppKit

/// Markdown editing commands: the change is worked out by `MarkdownEditing`
/// and made here, as one undoable edit.
extension EditorSession {
    /// Makes a change, keeping the ghosts and alternatives in the text it
    /// keeps. Returns false when there's nothing to do.
    @discardableResult
    func apply(_ change: MarkdownEditing.Change?, named name: String) -> Bool {
        guard let change, let tv = textView else { return false }
        let replacement = NSMutableAttributedString()
        for piece in change.pieces {
            switch piece {
            case .kept(let r): replacement.append(storage.attributedSubstring(from: r))
            case .added(let text): replacement.append(NSAttributedString(string: text, attributes: Theme.baseAttributes))
            }
        }
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: change.range, replacementString: replacement.string) else { return false }
        storage.replaceCharacters(in: change.range, with: replacement)
        tv.didChangeText()
        tv.breakUndoCoalescing()
        undoManager?.setActionName(name)
        tv.setSelectedRange(change.selection)
        tv.scrollRangeToVisible(change.selection)
        return true
    }

    /// Moves the paragraph, section or list item at the selection past its
    /// neighbor.
    func moveBlock(up: Bool) {
        guard let tv = textView else { return }
        let change = MarkdownEditing.move(tv.selectedRange(), up: up, in: string)
        if !apply(change, named: up ? "Move Up" : "Move Down") { NSSound.beep() }
    }

    func toggleEmphasis(bold: Bool) {
        guard let tv = textView else { return }
        if !apply(MarkdownEditing.toggleEmphasis(bold: bold, selection: tv.selectedRange(), in: string), named: bold ? "Bold" : "Italic") {
            NSSound.beep()
        }
    }

    /// Links the selection, to the address on the clipboard if there is one.
    func insertLink(from pasteboard: NSPasteboard = .general) {
        guard let tv = textView else { return }
        let address = pasteboard.string(forType: .string).flatMap(MarkdownEditing.webAddress)
        if !apply(MarkdownEditing.link(selection: tv.selectedRange(), address: address, in: string), named: "Link") {
            NSSound.beep()
        }
    }

    /// Pasting a web address over selected words links them. Returns false
    /// to paste as usual.
    func pasteLink(from pasteboard: NSPasteboard) -> Bool {
        guard let tv = textView, let pasted = pasteboard.string(forType: .string) else { return false }
        return apply(MarkdownEditing.pasteLink(pasted, selection: tv.selectedRange(), in: string), named: "Link")
    }

    /// Return in a list item. Returns false for an ordinary new line.
    func continueList() -> Bool {
        guard let tv = textView, tv.selectedRange().length == 0 else { return false }
        return apply(MarkdownEditing.newline(at: tv.selectedRange().location, in: string), named: "Typing")
    }

    /// Tab or Shift-Tab on list items. Returns false to type a tab as usual.
    func indentList(outdent: Bool) -> Bool {
        guard let tv = textView else { return false }
        return apply(MarkdownEditing.indentList(tv.selectedRange(), outdent: outdent, in: string), named: outdent ? "Outdent" : "Indent")
    }
}

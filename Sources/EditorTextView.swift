import AppKit
import SwiftUI

/// The writing surface. Standard NSTextView editing, plus the marks the
/// writing tools need: an editor's-pen underline beneath text that has
/// alternates, a row of dots showing which one is in place, and arrow-key
/// cycling while the pointer rests on it.
final class EditorTextView: NSTextView {
    weak var session: EditorSession?
    private(set) lazy var vim = VimEngine(textView: self)

    var featuresOn = false {
        didSet {
            if !featuresOn { hoveredGroup = nil }
            needsDisplay = true
        }
    }

    private(set) var hoveredGroup: String? {
        didSet { if oldValue != hoveredGroup { needsDisplay = true } }
    }

    private var hitRects: [(id: String, rect: NSRect, isDots: Bool)] = []
    private var tracking: NSTrackingArea?
    private var lastMouse: NSPoint?

    static let dotSize: CGFloat = 3.6
    static let dotGap: CGFloat = 3.0
    static let maxDots = 7

    static func dotsWidth(_ count: Int) -> CGFloat {
        3 + CGFloat(min(count, maxDots)) * (dotSize + dotGap) - 1
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        // A width change (a panel opening or closing, a window resize)
        // re-wraps every line; keep the same text at the top of the page.
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        if widthChanged { beginKeepingReadingPosition() }
        super.setFrameSize(newSize)
        let inset = NSSize(width: max(40, floor((newSize.width - Theme.column) / 2)), height: insetHeight)
        if abs(textContainerInset.width - inset.width) > 0.5 || abs(textContainerInset.height - inset.height) > 0.5 {
            textContainerInset = inset
        }
        if widthChanged { restoreReadingPosition() }
        scheduleCaretUpdate()
    }

    // MARK: Typewriter scrolling

    /// Zen's typewriter scrolling: the line being written stays in the
    /// middle of the screen.
    var typewriter = false {
        didSet {
            guard oldValue != typewriter else { return }
            setFrameSize(frame.size)
        }
    }

    /// Room above the first line, and below the last. Typewriter scrolling
    /// needs about half a screen, so even those lines can reach the middle.
    private var insetHeight: CGFloat {
        guard typewriter, let clip = enclosingScrollView?.contentView else { return Theme.topInset }
        return max(Theme.topInset, floor(clip.bounds.height / 2 - 24))
    }

    private func keepInMiddle(_ caret: NSRect) {
        guard let scroll = enclosingScrollView else { return }
        // The screen may have changed size (going full screen) since the inset was set.
        if abs(textContainerInset.height - insetHeight) > 0.5 { setFrameSize(frame.size) }
        let clip = scroll.contentView
        let y = min(max(0, (caret.midY - clip.bounds.height / 2).rounded()), max(0, frame.height - clip.bounds.height))
        guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Reading position

    /// The line at the top of the page (as a character) and how far into it
    /// the page is scrolled. Updated as you scroll or type; held still while
    /// the width is changing.
    private var readingAnchor: (index: Int, offset: CGFloat)?
    private var keepingPosition = false
    /// True while Redraft itself scrolls back, so that scroll doesn't move the anchor.
    private var restoringPosition = false
    private var keepingEnd: DispatchWorkItem?
    private let scrollObserver = ObserverBag()

    func trackReadingPosition() {
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver.add(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteReadingPosition() }
        })
    }

    private func noteReadingPosition() {
        guard !keepingPosition, !restoringPosition, let lm = layoutManager, let tc = textContainer, !string.isEmpty else { return }
        // Mid-resize (the scroll view already has its new width but the page
        // doesn't yet), scrolling is the layout settling, not you.
        if let clip = enclosingScrollView?.contentView, abs(clip.bounds.width - frame.width) > 1 { return }
        let top = visibleRect.minY
        let point = NSPoint(x: 1, y: max(0, top - textContainerOrigin.y))
        let glyph = lm.glyphIndex(for: point, in: tc)
        var lineGlyphs = NSRange()
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let lineChars = lm.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
        let offset = top - (line.minY + textContainerOrigin.y)
        // Re-wrapping moves line starts around; while the anchor's character
        // is still on the top line, keep it exactly so it can't creep.
        if let anchor = readingAnchor, NSLocationInRange(anchor.index, lineChars) {
            readingAnchor = (anchor.index, offset)
        } else {
            readingAnchor = (lm.characterIndexForGlyph(at: glyph), offset)
        }
    }

    private func beginKeepingReadingPosition() {
        if !keepingPosition { noteReadingPosition() }
        keepingPosition = true
        // Panels animate their width for a moment; settle once it stops.
        keepingEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.restoreReadingPosition()
            self?.keepingPosition = false
        }
        keepingEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func restoreReadingPosition() {
        guard let anchor = readingAnchor, let lm = layoutManager, let tc = textContainer,
              let clip = enclosingScrollView?.contentView, !string.isEmpty else { return }
        lm.ensureLayout(for: tc)
        let index = min(anchor.index, (string as NSString).length - 1)
        let line = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: index), effectiveRange: nil)
        let maxY = max(0, frame.height - clip.bounds.height)
        let y = min(max(0, line.minY + textContainerOrigin.y + anchor.offset), maxY)
        restoringPosition = true
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
        restoringPosition = false
    }

    // MARK: Caret

    /// The editor draws its own caret: a slim bar sized to the letters (the
    /// paragraphs' generous line spacing would otherwise make it tower over
    /// the text), with a soft blink that holds steady while you type.
    private let caret = CaretView()
    private var caretUpdateScheduled = false

    func setUpCaret() {
        insertionPointColor = .clear
        caret.color = Theme.accent
        addSubview(caret)
        caret.isHidden = true
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(self, selector: #selector(windowFocusChanged), name: name, object: nil)
        }
    }

    @objc private func windowFocusChanged(_ note: Notification) {
        if (note.object as? NSWindow) === window { scheduleCaretUpdate() }
    }

    /// Coalesces caret updates to once per run-loop turn, after layout settles.
    func scheduleCaretUpdate() {
        guard !caretUpdateScheduled else { return }
        caretUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.caretUpdateScheduled = false
            self?.updateCaret()
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let hadSelection = selectedRange().length > 0
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // With the paragraphs' tall line spacing, the highlight reaches above
        // the area AppKit repaints when it changes, leaving a sliver behind on
        // this transparent view. Repaint the visible page whenever a highlight
        // appears, changes or goes away.
        if hadSelection || selectedRange().length > 0 {
            setNeedsDisplay(visibleRect)
        }
        if !stillSelecting { vim.selectionDidChange() }
        scheduleCaretUpdate()
    }

    // MARK: Tabs

    /// The + in Show All Tabs (and the tab bar) asks for a new tab this way.
    override func newWindowForTab(_ sender: Any?) {
        WindowTabs.newTab()
    }

    // MARK: Pinch for all tabs

    /// A two-finger pinch-in on the page shows all tabs, like Safari.
    private var pinch: CGFloat = 0

    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            pinch = 0
        case .changed:
            pinch += event.magnification
        case .ended, .cancelled:
            if pinch < -0.25 { session?.showingTabs = true }
            pinch = 0
        default:
            break
        }
    }

    override func didChangeText() {
        super.didChangeText()
        scheduleCaretUpdate()
        noteReadingPosition()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        scheduleCaretUpdate()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        scheduleCaretUpdate()
        return ok
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        caret.color = Theme.accent
    }

    private func updateCaret() {
        updateSelectionBar()
        let selection = selectedRange()
        if typewriter, selection.length == 0, !isDraggingSelection, window?.firstResponder === self,
           let frame = caretFrame(at: selection.location) {
            keepInMiddle(frame)
        }
        let active = window?.isKeyWindow == true && window?.firstResponder === self && selection.length == 0
        guard active, let frame = caretFrame(at: selection.location) else {
            caret.isHidden = true
            return
        }
        if vim.showsBlockCaret {
            caret.frame = blockFrame(from: frame, at: selection.location)
            caret.isBlock = true
        } else {
            caret.frame = frame
            caret.isBlock = false
        }
        caret.isHidden = false
        caret.restartBlink()
    }

    /// Normal mode's block caret covers the character under it.
    private func blockFrame(from bar: NSRect, at loc: Int) -> NSRect {
        guard let ts = textStorage else { return bar }
        let ns = ts.string as NSString
        var width: CGFloat = 9
        if loc < ts.length, ns.character(at: loc) != 10 {
            let font = (ts.attribute(.font, at: loc, effectiveRange: nil) as? NSFont) ?? Theme.body
            let composed = ns.rangeOfComposedCharacterSequence(at: loc)
            width = max(4, ceil((ns.substring(with: composed) as NSString).size(withAttributes: [.font: font]).width))
        }
        return NSRect(x: bar.minX + 1, y: bar.minY, width: width, height: bar.height)
    }

    private func caretFrame(at loc: Int) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return nil }
        let ns = ts.string as NSString
        let length = ts.length
        // Layout up to the caret is all it needs; the whole page, after every
        // keystroke, is slow in a long document.
        if loc < length {
            lm.ensureLayout(forCharacterRange: NSRange(location: loc, length: 1))
        } else {
            lm.ensureLayout(for: tc)
        }

        // The caret takes the size of the text it sits in: the character
        // before it, unless that's a line break.
        var font = (typingAttributes[.font] as? NSFont) ?? Theme.body
        if loc > 0, loc <= length, ns.character(at: loc - 1) != 10,
           let f = ts.attribute(.font, at: loc - 1, effectiveRange: nil) as? NSFont {
            font = f
        } else if loc < length, let f = ts.attribute(.font, at: loc, effectiveRange: nil) as? NSFont {
            font = f
        }

        var x: CGFloat
        var baseline: CGFloat
        // The line the caret sits on, so it never reaches into the row above.
        var lineBounds: NSRect?
        if loc < length {
            let glyph = lm.glyphIndexForCharacter(at: loc)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let point = lm.location(forGlyphAt: glyph)
            x = fragment.minX + point.x
            baseline = fragment.minY + point.y
            let used = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            lineBounds = NSRect(x: fragment.minX, y: fragment.minY, width: fragment.width, height: used.height)
            // An empty line reports an odd baseline for its line break; place
            // the caret exactly as on a line of text of the same height.
            if ns.character(at: loc) == 10, loc == 0 || ns.character(at: loc - 1) == 10 {
                let paragraph = (ts.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle) ?? Theme.paragraph
                baseline = fragment.maxY - paragraph.paragraphSpacing - ceil(-font.descender)
                lineBounds = nil
            }
        } else if length > 0, ns.character(at: length - 1) != 10 {
            let glyph = lm.glyphIndexForCharacter(at: length - 1)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let point = lm.location(forGlyphAt: glyph)
            let advance = (ns.substring(with: NSRange(location: length - 1, length: 1)) as NSString).size(withAttributes: [.font: font]).width
            x = fragment.minX + point.x + advance
            baseline = fragment.minY + point.y
        } else {
            // A fresh line at the very end (or an empty document).
            let fragment = lm.extraLineFragmentRect
            let paragraph = (typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? Theme.paragraph
            x = fragment.minX
            if fragment.height > 0 {
                baseline = fragment.maxY - paragraph.paragraphSpacing - ceil(-font.descender)
            } else {
                baseline = ceil(font.ascender * max(1, paragraph.lineHeightMultiple))
            }
        }
        let origin = textContainerOrigin
        var top = baseline + origin.y - ceil(font.ascender) - 1
        var bottom = top + ceil(font.ascender - font.descender) + 2
        // Blank lines between paragraphs are shorter than a line of text; keep
        // the caret within the line instead of letting it bleed upward.
        if let line = lineBounds, line.height > 4 {
            top = max(top, line.minY + origin.y)
            bottom = min(bottom, line.minY + origin.y + line.height)
        }
        return NSRect(x: round(x + origin.x) - 1, y: round(top), width: 2, height: max(6, round(bottom - top)))
    }

    // MARK: Selection bar

    private let selectionBarModel = SelectionBarModel()
    private var isDraggingSelection = false

    private lazy var selectionBar: NSHostingView<SelectionBarView> = {
        let bar = NSHostingView(rootView: SelectionBarView(model: selectionBarModel) { [weak self] action in
            self?.performSelectionAction(action)
        })
        bar.isHidden = true
        addSubview(bar)
        return bar
    }()

    /// A small bar above a selection with the things you can do to it.
    private func updateSelectionBar() {
        let selection = selectedRange()
        guard featuresOn, selection.length > 0, !isDraggingSelection,
              window?.isKeyWindow == true, let session, session.tourStep == nil, !session.previewing,
              let lm = layoutManager, let tc = textContainer, NSMaxRange(selection) <= (textStorage?.length ?? 0) else {
            if selectionBar.superview != nil { selectionBar.isHidden = true }
            return
        }
        let origin = textContainerOrigin
        let glyphs = lm.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
        var firstLine = NSRange()
        _ = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &firstLine)
        let top = lm.boundingRect(forGlyphRange: NSIntersectionRange(firstLine, glyphs), in: tc).offsetBy(dx: origin.x, dy: origin.y)
        selectionBarModel.inGhost = session.ghostToRevive(for: selection) != nil
        let size = selectionBar.fittingSize
        let visible = visibleRect
        var x = top.midX - size.width / 2
        x = min(max(visible.minX + 8, x), visible.maxX - size.width - 8)
        var y = top.minY - size.height - 6
        if y < visible.minY + 4 {
            let last = lm.boundingRect(forGlyphRange: NSRange(location: NSMaxRange(glyphs) - 1, length: 1), in: tc)
            y = last.maxY + origin.y + 6
        }
        selectionBar.frame = NSRect(x: round(x), y: round(y), width: size.width, height: size.height)
        selectionBar.isHidden = false
    }

    private func performSelectionAction(_ action: SelectionBarView.Action) {
        guard let session else { return }
        let selection = selectedRange()
        selectionBar.isHidden = true
        switch action {
        case .alternatives: session.openAlternatives(for: selection)
        case .ai: session.aiAlternatives(for: selection)
        case .ghost:
            session.toggleGhost(range: selection)
            setSelectedRange(NSRange(location: NSMaxRange(selection), length: 0))
        case .stash: session.stash(range: selection)
        }
        // From Vim's Visual modes, an action ends the selection like d or y
        // would, which returns Vim to Normal mode.
        if (vim.mode == .visual || vim.mode == .visualLine), selectedRange().length > 0 {
            setSelectedRange(NSRange(location: min(selection.location, (string as NSString).length), length: 0))
        }
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Clicking the dots after an alternate opens its panel.
        if featuresOn, event.clickCount == 1, let hit = hitRects.first(where: { $0.isDots && $0.rect.contains(p) }) {
            session?.activate(hit.id)
            return
        }
        isDraggingSelection = true
        selectionBar.isHidden = true
        super.mouseDown(with: event)  // tracks the drag until mouse-up
        isDraggingSelection = false
        scheduleCaretUpdate()
    }

    // MARK: Pasting

    override func paste(_ sender: Any?) {
        // A web address pasted over selected words links them.
        if let session, session.pasteLink(from: .general) { return }
        pasteAsPlainText(sender)
    }

    // MARK: Lists

    override func insertNewline(_ sender: Any?) {
        if let session, session.continueList() { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if let session, session.indentList(outdent: false) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if let session, session.indentList(outdent: true) { return }
        super.insertBacktab(sender)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if let cursor = PointerOverride.cursor { cursor.set(); return }
        super.cursorUpdate(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if let cursor = PointerOverride.cursor {
            cursor.set()
            return
        }
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        lastMouse = p
        updateHover(at: p)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        lastMouse = nil
        hoveredGroup = nil
    }

    #if DEBUG
    /// Caret frame and its line fragment, for checking geometry from scripts.
    /// The first character at the top of the visible page, for scroll tests.
    func debugTopCharacter() -> Int {
        guard let lm = layoutManager, let tc = textContainer else { return -1 }
        let point = NSPoint(x: 10, y: visibleRect.minY - textContainerOrigin.y + 2)
        return lm.characterIndexForGlyph(at: lm.glyphIndex(for: point, in: tc))
    }

    func debugCaretGeometry(at loc: Int) -> String {
        guard let frame = caretFrame(at: loc), let lm = layoutManager, let ts = textStorage, loc < ts.length else { return "n/a" }
        let glyph = lm.glyphIndexForCharacter(at: loc)
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: 0, dy: textContainerOrigin.y)
        return String(format: "caret y %.1f-%.1f (h %.1f) | line y %.1f-%.1f", frame.minY, frame.maxY, frame.height, fragment.minY, fragment.maxY)
    }

    func debugHover(_ id: String?) {
        hoveredGroup = id
    }
    #endif

    private func updateHover(at p: NSPoint) {
        guard featuresOn else {
            hoveredGroup = nil
            toolTip = nil
            return
        }
        let hit = hitRects.first { $0.rect.contains(p) }
        hoveredGroup = hit?.id
        if let hit {
            if hit.isDots { NSCursor.pointingHand.set() }
            toolTip = hit.isDots
                ? "Click to see every version"
                : (vim.isActive
                    ? "This has other versions. Press ← → to try them (or ]a [a at the cursor), or click the dots."
                    : "This has other versions. Press ← → to try them, or click the dots.")
        } else if let index = characterIndex(at: p), session?.ghostRun(at: index) != nil,
                  textStorage.map({ index < $0.length && $0.attribute(.ghost, at: index, effectiveRange: nil) != nil }) == true {
            toolTip = "Ghosted: kept in the file, out of your way. Select it or right-click to revive."
        } else {
            toolTip = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        // While the shortcuts card is open, Esc closes it and the page ignores typing.
        if let session, session.showShortcuts {
            if event.keyCode == 53 { session.showShortcuts = false }
            return
        }
        let isHorizontal = event.keyCode == 123 || event.keyCode == 124
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Hover + ← → tries alternatives (→ next, ← previous), in any mode.
        // Hover only arms when the pointer moves onto the word and disarms on
        // any other key, so after typing the arrows move again until you
        // reach for the mouse.
        if featuresOn, isHorizontal, mods.isEmpty, let id = hoveredGroup {
            session?.cycle(groupID: id, by: event.keyCode == 124 ? 1 : -1)
            return
        }
        // Typing means the hand has left the mouse; don't let a resting pointer steal arrows.
        if !isHorizontal { hoveredGroup = nil }
        // App shortcuts (⌃⇧ + letter) come before Vim, so they work in every mode.
        if let shortcut = AppShortcut.controlStyleMatch(for: event), let session {
            session.perform(shortcut)
            return
        }
        if vim.handle(event) { return }
        super.keyDown(with: event)
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let session else { return menu }
        let items = session.contextItems(clickIndex: characterIndex(at: convert(event.locationInWindow, from: nil)))
        guard !items.isEmpty else { return menu }
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        menu.insertItem(.separator(), at: items.count)
        return menu
    }

    func characterIndex(at p: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        let pt = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: pt, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.insetBy(dx: -2, dy: -2).contains(pt) else { return nil }
        return lm.characterIndexForGlyph(at: glyph)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        hitRects.removeAll(keepingCapacity: true)
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return }
        if ts.length == 0 {
            drawPlaceholder()
            return
        }
        guard featuresOn, let session else { return }
        let origin = textContainerOrigin
        let ns = ts.string as NSString
        let full = NSRange(location: 0, length: ts.length)
        // Only the alternatives on screen. Finding where every one in a long
        // document sits would lay out the whole page again after each keystroke.
        let onScreen = lm.characterRange(
            forGlyphRange: lm.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc),
            actualGlyphRange: nil)
        var spots: [(id: String, range: NSRange)] = []
        ts.enumerateAttribute(.variantGroup, in: onScreen) { value, r, _ in
            guard let id = value as? String else { return }
            // The whole spot, though it may start above the screen or end below it.
            var range = NSRange()
            _ = ts.attribute(.variantGroup, at: r.location, longestEffectiveRange: &range, in: full)
            if spots.last?.range != range { spots.append((id, range)) }
        }

        for (id, range) in spots {
            guard range.length > 0, let group = session.doc.groups[id], !group.options.isEmpty else { continue }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            // Zen's focus dims alternatives outside the paragraph being written.
            let dimmed = session.focusRange.map { NSIntersectionRange($0, range).length == 0 } ?? false
            let context = NSGraphicsContext.current?.cgContext
            if dimmed { context?.saveGState(); context?.setAlpha(0.35) }
            defer { if dimmed { context?.restoreGState() } }
            let hovered = id == hoveredGroup
            let lastChar = NSMaxRange(range) - 1
            let lastGlyph = NSMaxRange(glyphs) - 1
            let font = (ts.attribute(.font, at: lastChar, effectiveRange: nil) as? NSFont) ?? Theme.body
            let lastWidth = (ns.substring(with: NSRange(location: lastChar, length: 1)) as NSString).size(withAttributes: [.font: font]).width
            var endX: CGFloat = 0
            var baseline: CGFloat = 0
            var line = 0

            lm.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, glyphs)
                guard part.length > 0 else { return }
                let bounds = lm.boundingRect(forGlyphRange: part, in: tc)
                let base = lineRect.minY + lm.location(forGlyphAt: part.location).y + origin.y
                var x0 = bounds.minX + origin.x
                var x1 = bounds.maxX + origin.x
                if NSMaxRange(part) == NSMaxRange(glyphs) {
                    x1 = lineRect.minX + lm.location(forGlyphAt: lastGlyph).x + lastWidth + origin.x
                    endX = x1
                    baseline = base
                }
                x0 = min(x0, x1)

                if hovered {
                    Theme.accent.withAlphaComponent(0.09).setFill()
                    let wash = NSRect(x: x0 - 3, y: base - font.ascender - 2, width: x1 - x0 + 6, height: font.ascender - font.descender + 4)
                    NSBezierPath(roundedRect: wash, xRadius: 4, yRadius: 4).fill()
                }
                Theme.accent.withAlphaComponent(hovered ? 0.95 : 0.55).setStroke()
                let pen = Self.penStroke(from: x0, to: x1, y: base + 3.6, seed: "\(id)#\(line)")
                pen.stroke()
                self.hitRects.append((id, NSRect(x: x0 - 2, y: lineRect.minY + origin.y, width: x1 - x0 + 4, height: lineRect.height), false))
                line += 1
            }

            // The dots: one per option. The one in place is filled; it turns
            // the accent color once you've moved off the original.
            let count = min(group.options.count, Self.maxDots)
            let centerY = baseline - font.xHeight * 0.5
            var x = endX + 3
            for i in 0..<count {
                let isCurrent = i == group.selected
                let color: NSColor = isCurrent
                    ? (group.selected == 0 ? Theme.inkSecondary : Theme.accent)
                    : Theme.accent.withAlphaComponent(hovered ? 0.4 : 0.26)
                color.setFill()
                let d = isCurrent ? Self.dotSize + 0.6 : Self.dotSize
                NSBezierPath(ovalIn: NSRect(x: x + (Self.dotSize - d) / 2, y: centerY - d / 2, width: d, height: d)).fill()
                x += Self.dotSize + Self.dotGap
            }
            self.hitRects.append((id, NSRect(x: endX, y: centerY - 9, width: x - endX + 2, height: 18), true))
        }

    }

    private func drawPlaceholder() {
        var attrs = Theme.baseAttributes
        attrs[.foregroundColor] = Theme.ghost
        let rect = NSRect(origin: textContainerOrigin, size: NSSize(width: max(0, bounds.width - textContainerOrigin.x * 2), height: 60))
        ("Start writing." as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs)
    }

    /// An editor's-pen line: mostly straight, gently wavering, slightly
    /// uneven in weight, never perfect. Seeded so it doesn't shimmer on redraw.
    static func penStroke(from x0: CGFloat, to x1: CGFloat, y: CGFloat, seed: String) -> NSBezierPath {
        var rng = SeededRandom(string: seed)
        let length = max(x1 - x0, 1)
        let start = x0 - rng.range(0.3...1.6)
        let end = x1 + rng.range(-0.4...1.4)
        let tilt = rng.range(-0.7...0.7)
        let amplitude = rng.range(0.35...0.75)
        let wavelength = rng.range(18...30)
        let phase = rng.range(0...(2 * .pi))
        let steps = max(3, Int(length / 6))

        var points: [NSPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = start + (end - start) * t
            let wave = amplitude * sin((x - start) / wavelength * 2 * .pi + phase)
            let jitter = rng.range(-0.22...0.22)
            points.append(NSPoint(x: x, y: y + tilt * (t - 0.5) + wave + jitter))
        }

        // Catmull-Rom through the points, as cubic Béziers.
        let path = NSBezierPath()
        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        path.lineWidth = rng.range(1.0...1.3)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }
}

/// The editor's caret: a rounded bar with a gentle fade blink.
final class CaretView: NSView {
    var color: NSColor = .controlAccentColor {
        didSet { applyColor() }
    }

    /// A translucent block (Vim normal mode) instead of a bar.
    var isBlock = false {
        didSet { if oldValue != isBlock { applyColor() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 1
        applyColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isBlock ? color.withAlphaComponent(0.4) : color).cgColor
        }
        layer?.cornerRadius = isBlock ? 2 : 1
    }

    /// Solid now, then blinks after a short pause, so the caret stays put while typing.
    func restartBlink() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "blink")
        layer.opacity = 1
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 1, 0, 0, 1]
        blink.keyTimes = [0, 0.42, 0.5, 0.92, 1]
        blink.duration = 1.1
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + 0.55
        blink.fillMode = .backwards
        layer.add(blink, forKey: "blink")
    }
}


// MARK: - Selection bar

final class SelectionBarModel: ObservableObject {
    @Published var inGhost = false
}

struct SelectionBarView: View {
    enum Action { case alternatives, ai, ghost, stash }

    @ObservedObject var model: SelectionBarModel
    let perform: (Action) -> Void

    var body: some View {
        HStack(spacing: 0) {
            item("text.badge.plus", "Alternatives", .alternatives)
            item("sparkle", "AI", .ai)
            item(model.inGhost ? "eye" : "eye.slash", model.inGhost ? "Revive" : "Ghost", .ghost)
            item("tray.and.arrow.down", "Stash", .stash)
        }
        .padding(3)
        .background(Capsule().fill(Color.panel))
        .overlay(Capsule().strokeBorder(Color.hairline))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .fixedSize()
    }

    private func item(_ icon: String, _ title: String, _ action: Action) -> some View {
        SelectionBarItem(icon: icon, title: title) { perform(action) }
    }
}

private struct SelectionBarItem: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .medium))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(hovering ? Color.accent : Color.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(hovering ? Color.accent.opacity(0.1) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointingHandOnHover()
    }
}

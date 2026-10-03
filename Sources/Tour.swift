import AppKit
import SwiftUI

// MARK: - Anchors

/// Places in the window the tour can point at.
enum TourAnchor: Hashable {
    case wordCount, toolsToggle, alternativesButton, overflowButton, labButton, previewButton
}

struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [TourAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourAnchor: Anchor<CGRect>], nextValue: () -> [TourAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func tourAnchor(_ anchor: TourAnchor) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [anchor: $0] }
    }
}

// MARK: - Steps

struct TourStep {
    let anchor: TourAnchor?
    let title: String
    let body: String
    /// Writing tools must be visible for this step's target to exist.
    var needsTools = false

    static var all: [TourStep] { [
        TourStep(
            anchor: nil,
            title: "Welcome to Redraft",
            body: "A quiet page for writing. Everything else stays out of the way until you ask for it."
        ),
        TourStep(
            anchor: .toolsToggle,
            title: "Your tools live here",
            body: "The writing tools sit in this corner. Click › to tuck them away for plain writing, and the pencil to bring them back. (\(AppShortcut.toggleTools.label), or click the word count)",
            needsTools: true
        ),
        TourStep(
            anchor: nil,
            title: "Try other words",
            body: "Select a word, sentence or paragraph. A small bar appears: choose Alternatives to write other versions, or AI for suggestions. You can also right-click.\n\nUnderlined text has alternatives. Hover it and press ← → to try each one in place, or click its dots to see them all.",
            needsTools: true
        ),
        TourStep(
            anchor: .alternativesButton,
            title: "Every version, side by side",
            body: "This panel lists the versions of the spot you're on. Type one and press Return, or type ?? and AI adds a few more. Click a version to use it. Press Delete to remove one.",
            needsTools: true
        ),
        TourStep(
            anchor: nil,
            title: "Ghost, don't delete",
            body: "Not sure a sentence belongs? Select it and choose Ghost. It fades back so you can read without it, but it stays in the file. Right-click it (or use the bar) to revive it.",
            needsTools: true
        ),
        TourStep(
            anchor: .overflowButton,
            title: "Overflow",
            body: "A drawer for writing you're not ready to use or lose. Select text and choose Stash to send it here.",
            needsTools: true
        ),
        TourStep(
            anchor: .labButton,
            title: "The Lab",
            body: "AI editing that points things out but never rewrites: tangled sentences, off-tone words, and trims you can accept or keep one by one. Connect AI in Settings (⌘,).",
            needsTools: true
        ),
        TourStep(
            anchor: .previewButton,
            title: "Preview",
            body: "See your Markdown rendered, without ghosted text. When you're done, File → Export Clean Copy saves the finished piece (it's also in the file name's menu at the top edge).",
            needsTools: true
        ),
        TourStep(
            anchor: nil,
            title: "That's it",
            body: "Find this tour, shortcuts and feedback anytime in the Help menu, or press \(AppShortcut.shortcutsCard.label) for every shortcut. Vim mode and AI live in Settings (⌘,)."
        ),
    ] }
}

// MARK: - Overlay

/// Dims the window, spotlights one control, and explains it.
struct TourOverlay: View {
    @ObservedObject var session: EditorSession
    let anchors: [TourAnchor: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            if let index = session.tourStep, TourStep.all.indices.contains(index) {
                let step = TourStep.all[index]
                let target = step.anchor.flatMap { anchors[$0] }.map { proxy[$0].insetBy(dx: -8, dy: -6) }
                ZStack(alignment: .topLeading) {
                    Spotlight(hole: target)
                        .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .arrowCursorOnHover()
                    if let target {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accent, lineWidth: 2)
                            .frame(width: target.width, height: target.height)
                            .offset(x: target.minX, y: target.minY)
                            .allowsHitTesting(false)
                    }
                    TourCard(session: session, step: step, index: index)
                        .frame(width: 320)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(cardOffset(target: target, in: proxy.size))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.tourStep)
    }

    private func cardOffset(target: CGRect?, in size: CGSize) -> CGSize {
        let width: CGFloat = 320, height: CGFloat = 220, margin: CGFloat = 16
        guard let target else {
            return CGSize(width: (size.width - width) / 2, height: max(margin, size.height * 0.32 - height / 2))
        }
        var x = target.midX - width / 2
        x = min(max(margin, x), size.width - width - margin)
        // Prefer above targets in the lower half, below targets in the upper half.
        let y = target.midY > size.height / 2 ? target.minY - height - 12 : target.maxY + 14
        return CGSize(width: x, height: min(max(margin, y), size.height - height - margin))
    }
}

private struct Spotlight: Shape {
    let hole: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let hole { path.addRoundedRect(in: hole, cornerSize: CGSize(width: 10, height: 10)) }
        return path
    }
}

private struct TourCard: View {
    @ObservedObject var session: EditorSession
    let step: TourStep
    let index: Int

    private var isLast: Bool { index == TourStep.all.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title)
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(Color.ink)
            Text(step.body)
                .font(.system(size: 13))
                .foregroundStyle(Color.ink.opacity(0.85))
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                ForEach(TourStep.all.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? Color.accent : Color.inkSecondary.opacity(0.3))
                        .frame(width: 5, height: 5)
                }
                Spacer()
                if !isLast {
                    Button("Skip") { session.endTour() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.inkSecondary)
                        .pointingHandOnHover()
                }
                if index > 0 {
                    Button("Back") { session.advanceTour(by: -1) }
                        .pointingHandOnHover()
                }
                Button(isLast ? "Done" : "Next") {
                    if isLast { session.endTour() } else { session.advanceTour(by: 1) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
                .pointingHandOnHover()
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.top, 4)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.paper))
        .arrowCursorOnHover()
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.hairline))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onExitCommand { session.endTour() }
    }
}

// MARK: - Shortcuts

/// Every shortcut on one card.
/// The shortcuts card: an in-window panel over a dimmed page. Closes with
/// the ✕, a click outside, Esc, or ⌘/ again.
struct ShortcutsSheet: View {
    let close: () -> Void
    @State private var hoveringClose = false

    private var groups: [(String, [(String, String)])] { [
        ("Writing tools", [
            ("Show or hide tools", "\(AppShortcut.toggleTools.label)  or the button at the end of the tools"),
            ("Preview Markdown", AppShortcut.preview.label),
            ("Copy clean text", AppShortcut.copyClean.label),
            ("Export clean copy", "⌥⇧⌘E"),
            ("Zoom in / out / actual size", "⌘+  ⌘−  ⌘0"),
            ("New tab / close tab", "⌘T  ⌘W"),
            ("Show all tabs", "\(AppShortcut.allTabs.label)  or pinch in"),
            ("Settings", "⌘,"),
            ("This card", "⌘/"),
        ]),
        ("Alternatives", [
            ("Alternatives for a selection, or open the panel", "\(AppShortcut.alternatives.label)  or select / right-click"),
            ("AI alternatives", AppShortcut.aiAlternatives.label),
            ("Try the next / previous one", "hover + → ←  or  \(AppShortcut.nextAlternative.label) \(AppShortcut.previousAlternative.label)"),
            ("See them all", "click the dots"),
            ("In the panel", "Return adds · ?? asks AI · Delete removes"),
        ]),
        ("Ghost and overflow", [
            ("Ghost or revive", "\(AppShortcut.ghost.label)  or select / right-click"),
            ("Stash in overflow", "\(AppShortcut.stash.label)  or select / right-click"),
        ]),
        ("Panels", [
            ("Overflow / Lab", "\(AppShortcut.overflowPanel.label) / \(AppShortcut.labPanel.label)"),
            ("Zen mode (full screen)", AppShortcut.zen.label),
        ]),
        ("Vim (when on)", [
            ("Leave insert mode", "Esc  or your mapping (e.g. jk)"),
            ("Move", "h j k l  w b e  0 $  gg G  { }  ( )  f t ; ,"),
            ("Edit", "d c y + motion · dd cc yy · x p u ⌃r ."),
            ("Select", "v  V  then d c y ~"),
            ("Try alternatives at the cursor", "]a  [a"),
        ]),
    ] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Shortcuts")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.ink)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(hoveringClose ? Color.ink : Color.inkSecondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.ink.opacity(hoveringClose ? 0.1 : 0.05)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hoveringClose = $0 }
                .pointingHandOnHover()
                .help("Close (Esc)")
            }
            .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.0.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(1.1)
                                .foregroundStyle(Color.inkSecondary)
                            ForEach(group.1, id: \.0) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.0).font(.system(size: 13))
                                    Spacer(minLength: 16)
                                    Text(row.1)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Color.accent)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 540)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.paper))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
    }
}

// MARK: - Practice document

enum PracticeDocument {
    /// Opens a fresh practice file with examples of every feature.
    static func open() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folder = support.appendingPathComponent("Redraft", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Practice.md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    private static let text = """
    # A <span data-mw-alt="P1">practice</span> page

    This page is for playing. Nothing here matters, so try everything.

    Underlined words have other versions, like <span data-mw-alt="P2">alternatives</span> here and the word in the title. Hover one and press the up and down arrow keys, or click the little dots after it to open the panel. You'll hear a lower tone when you land back on the original.

    Select any sentence on this page and a small bar appears above it. <span data-mw-ghost>This sentence is ghosted: still in the file, out of your way. Select it and choose Revive to bring it back.</span> Try ghosting this one instead.

    Open the Overflow drawer from the toolbar at the bottom right. There's already a note waiting in it. Select this paragraph and choose Stash to send it there too.

    When AI is connected in Settings, select a word and choose AI, or open the Lab and try a trim. Nothing gets rewritten without you.

    <!-- redraft
    {"groups":[{"id":"P1","options":[{"id":"0B1C2E1A-1111-4111-8111-111111111111","source":"human","text":"practice"},{"id":"0B1C2E1A-2222-4111-8111-111111111111","source":"human","text":"playground"},{"id":"0B1C2E1A-3333-4111-8111-111111111111","source":"ai","text":"sandbox"}],"selected":0},{"id":"P2","options":[{"id":"0C1C2E1A-1111-4111-8111-111111111111","source":"human","text":"alternatives"},{"id":"0C1C2E1A-2222-4111-8111-111111111111","source":"human","text":"other versions"},{"id":"0C1C2E1A-3333-4111-8111-111111111111","source":"ai","text":"options"}],"selected":0}],"overflow":"A note from the overflow drawer: keep the good lines you aren't using yet.","version":1}
    -->

    """
}

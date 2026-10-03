import SwiftUI

/// Edit a Lab tool's prompt (and, for your own tools, its name, icon and
/// type), or start a new one from a blank page or a starter.
struct LabToolEditor: View {
    let onRun: (LabTool) -> Void

    @State private var draft: LabTool
    private let isNew: Bool
    @ObservedObject private var store = LabToolStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showIcons = false
    @State private var showContract = false
    @State private var confirmDelete = false
    @FocusState private var promptFocused: Bool

    init(tool: LabTool, onRun: @escaping (LabTool) -> Void) {
        self.onRun = onRun
        _draft = State(initialValue: tool)
        isNew = !LabToolStore.shared.tools.contains { $0.id == tool.id }
    }

    private var isPreset: Bool { draft.isPreset }
    private var defaultPrompt: String? { store.defaultPrompt(for: draft.id) }
    private var promptIsEmpty: Bool { draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    kindPicker
                    promptSection
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 20)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        .background(Color.panel)
        .onAppear { if !isNew || !draft.name.isEmpty { promptFocused = true } }
        .confirmationDialog("Delete “\(draft.name)”?", isPresented: $confirmDelete) {
            Button("Delete Tool", role: .destructive) {
                store.delete(draft.id)
                dismiss()
            }
        } message: {
            Text("Its prompt will be gone for good.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Button { if !isPreset { showIcons.toggle() } } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accent.opacity(0.14))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accent.opacity(0.25))
                    Image(systemName: draft.icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.accent)
                }
                .frame(width: 56, height: 56)
                .overlay(alignment: .bottomTrailing) {
                    if !isPreset {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.accent, Color.panel)
                            .offset(x: 4, y: 4)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isPreset)
            .help(isPreset ? "" : "Choose an icon")
            .popover(isPresented: $showIcons, arrowEdge: .bottom) { iconGrid }
            .pointingHandOnHover()

            VStack(alignment: .leading, spacing: 6) {
                if isPreset {
                    Text(draft.name)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.ink)
                } else {
                    TextField("Name your tool", text: $draft.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.ink)
                }
                HStack(spacing: 6) {
                    Badge(text: isPreset ? "Built in" : isNew ? "New tool" : "Your tool", tint: Color.inkSecondary)
                    if isPreset, let defaultPrompt, draft.prompt != defaultPrompt {
                        Badge(text: "Edited", tint: Color.accent)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var iconGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 6), spacing: 6) {
            ForEach(LabTool.icons, id: \.self) { name in
                Button {
                    draft.icon = name
                    showIcons = false
                } label: {
                    Image(systemName: name)
                        .font(.system(size: 15))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(name == draft.icon ? Color.accent : Color.ink)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(name == draft.icon ? Color.accent.opacity(0.16) : Color.ink.opacity(0.04))
                        )
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }
        }
        .padding(14)
    }

    // MARK: Type

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "What it does")
            HStack(spacing: 10) {
                ForEach(LabTool.Kind.allCases) { kind in
                    KindCard(kind: kind, selected: draft.kind == kind, locked: isPreset) {
                        withAnimation(.easeOut(duration: 0.15)) { draft.kind = kind }
                    }
                }
            }
        }
    }

    // MARK: Prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "Prompt")
                Spacer()
                if isPreset, let defaultPrompt, draft.prompt != defaultPrompt {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { draft.prompt = defaultPrompt }
                    } label: {
                        Label("Restore default", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.accent)
                    .pointingHandOnHover()
                }
            }

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft.prompt)
                        .font(.system(size: 14.5, design: .serif))
                        .lineSpacing(5)
                        .foregroundStyle(Color.ink)
                        .scrollContentBackground(.hidden)
                        .focused($promptFocused)
                        .padding(.horizontal, 13)
                        .padding(.top, 12)
                    if promptIsEmpty {
                        Text("Describe what the editor should look for, and how much to flag. For example: “You are a careful editor. Find claims that need a source or an example to be convincing. Flag at most 6.”")
                            .font(.system(size: 14.5, design: .serif))
                            .lineSpacing(5)
                            .foregroundStyle(Color.inkSecondary.opacity(0.7))
                            .padding(.horizontal, 18)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 210)

                HStack(spacing: 10) {
                    Text("\(EditorSession.words(in: draft.prompt)) words")
                        .monospacedDigit()
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { showContract.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("What Redraft adds")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(showContract ? 180 : 0))
                        }
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.inkSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.ink.opacity(0.025))
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.paper))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(promptFocused ? Color.accent.opacity(0.55) : Color.hairline, lineWidth: promptFocused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: promptFocused)

            if showContract {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Added after your prompt so results can be found and marked in your text:")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.inkSecondary)
                    Text(draft.kind.contract)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color.ink.opacity(0.75))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ink.opacity(0.04)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isNew && promptIsEmpty {
                starters
            }
        }
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or start from one of these")
                .font(.system(size: 11))
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 4)
            FlowRow(spacing: 6) {
                ForEach(LabStarter.all) { starter in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if draft.name.isEmpty { draft.name = starter.name }
                            draft.icon = starter.icon
                            draft.kind = starter.kind
                            draft.prompt = starter.prompt
                        }
                        promptFocused = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: starter.icon).font(.system(size: 10.5))
                            Text(starter.name).font(.system(size: 12))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color.ink)
                        .background(Capsule().fill(Color.paper))
                        .overlay(Capsule().strokeBorder(Color.hairline))
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if !isPreset && !isNew {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color(nsColor: Theme.cutStrike).opacity(1))
                .pointingHandOnHover()
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .pointingHandOnHover()
            Button("Save & Run") {
                store.save(draft)
                dismiss()
                onRun(store.tools.first { $0.id == draft.id } ?? draft)
            }
            .disabled(promptIsEmpty)
            .pointingHandOnHover()
            Button("Save") {
                store.save(draft)
                dismiss()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(Color.accent)
            .disabled(promptIsEmpty)
            .help("Save (⌘↩)")
            .pointingHandOnHover()
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }
}

// MARK: Pieces

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Color.inkSecondary)
    }
}

private struct Badge: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

private struct KindCard: View {
    let kind: LabTool.Kind
    let selected: Bool
    let locked: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind == .flag ? "highlighter" : "scissors")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Color.accent : Color.inkSecondary)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Text(kind.explanation)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accent.opacity(0.10) : hovering && !locked ? Color.ink.opacity(0.04) : Color.paper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accent.opacity(0.55) : Color.hairline, lineWidth: selected ? 1.5 : 1)
            )
            .opacity(locked && !selected ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .onHover { hovering = $0 }
        .help(locked ? "Built-in tools keep their type" : "")
        .pointingHandOnHover()
    }
}

/// Lays children out left to right, wrapping onto new lines.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return (points, maxWidth, y + rowHeight)
    }
}

/// Ready-made prompts for new tools.
private struct LabStarter: Identifiable {
    let name: String
    let icon: String
    let kind: LabTool.Kind
    let prompt: String
    var id: String { name }

    static let all: [LabStarter] = [
        LabStarter(name: "Passive voice", icon: "arrow.uturn.left", kind: .flag, prompt: """
        You are a careful line editor. Find sentences in the passive voice where an active version would be clearer or stronger. Leave passive sentences alone when the actor is unknown or unimportant.

        Flag at most 8. In each note, name who should be doing the action.
        """),
        LabStarter(name: "Clichés", icon: "quote.bubble", kind: .flag, prompt: """
        You are a careful line editor. Find clichés, stock phrases and tired metaphors that a sharp reader would skim past.

        Flag at most 8, using the shortest span that captures each one. In each note, say what the phrase is trying to say plainly.
        """),
        LabStarter(name: "Unsupported claims", icon: "checkmark.seal", kind: .flag, prompt: """
        You are a skeptical editor. Find claims that need an example, a number or a source to be convincing, and sweeping generalizations a reader might push back on.

        Flag at most 6. In each note, say what kind of support would help.
        """),
        LabStarter(name: "Weak openings", icon: "text.magnifyingglass", kind: .flag, prompt: """
        You are a careful editor. Look at how the piece and each section begin. Find openings that clear their throat, restate the title or delay the point.

        Flag at most 5, quoting the weak opening sentence. In each note, say where the real start is.
        """),
        LabStarter(name: "Repeated words", icon: "list.bullet.indent", kind: .flag, prompt: """
        You are a careful line editor. Find words and phrases repeated close together in a way a reader would notice, ignoring small words like "the" and "and".

        Flag at most 10, quoting the second occurrence. In each note, name the repeated word.
        """),
        LabStarter(name: "Cut hedges", icon: "scissors", kind: .cut, prompt: """
        You are an editor who tightens writing only by deleting. Remove hedges and softeners that weaken the writing without adding accuracy: words like "really", "very", "just", "basically", "actually", "quite", "I think" and "sort of".

        Keep a hedge when it carries real uncertainty.
        """),
    ]
}

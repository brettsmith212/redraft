import SwiftUI

/// Left-hand panel: every way you've written the current spot. Click one to
/// put it in place, arrow through them, type `??` to have AI add more, and
/// press Delete to blow one up.
struct AlternativesPanel: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var doc: WriterDocument
    @State private var draft = ""
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var bursts: [Burst] = []
    @FocusState private var addFocused: Bool
    @FocusState private var listFocused: Bool

    init(session: EditorSession) {
        self.session = session
        self.doc = session.doc
    }

    private var group: VariantGroup? { session.activeGroupID.flatMap { doc.groups[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Alternatives") { session.showAlternatives = false }
            if let group {
                content(group)
            } else {
                hint
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "alternatives")
        .overlay { ForEach(bursts) { ExplosionView(burst: $0) } }
        .background(Color.panel)
    }

    /// Shown before any spot is chosen: what this panel is for and how to start.
    private var hint: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Color.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("Write it another way")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.ink)
                Text("Keep several versions of a word, sentence or paragraph, and try each one in place.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.inkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Select some text, then")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.inkSecondary)
                hintRow("cursorarrow.click", Text("choose ") + Text("Alternatives").bold() + Text(" in the bar above it"))
                hintRow("contextualmenu.and.cursorarrow", Text("or right-click it"))
                HStack(spacing: 10) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.inkSecondary)
                        .frame(width: 16)
                    Text("or press").font(.system(size: 12.5)).foregroundStyle(Color.ink)
                    Keycap(AppShortcut.alternatives.label)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.paper.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.hairline))
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    private func hintRow(_ icon: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.inkSecondary)
                .frame(width: 16)
            text
                .font(.system(size: 12.5))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func content(_ group: VariantGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(group.options.enumerated()), id: \.element.id) { index, option in
                        OptionRow(
                            option: option,
                            isOriginal: index == 0,
                            isSelected: index == group.selected,
                            canDelete: group.options.count > 1
                        ) {
                            session.select(groupID: group.id, index: index)
                            listFocused = true
                        } onDelete: {
                            explode(option, in: group)
                        }
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: RowFrameKey.self, value: [option.id: geo.frame(in: .named("alternatives"))])
                        })
                        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .scale(scale: 0.6).combined(with: .opacity)))
                    }
                    if session.aiLoadingGroup == group.id {
                        DancingDots().padding(.leading, 30).padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 10)
                .animation(.spring(response: 0.32, dampingFraction: 0.8), value: group.options)
            }
            .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { session.cycle(groupID: group.id, by: -1); return .handled }
            .onKeyPress(.downArrow) { session.cycle(groupID: group.id, by: 1); return .handled }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard group.options.count > 1, group.options.indices.contains(group.selected) else { return .ignored }
                explode(group.options[group.selected], in: group)
                return .handled
            }

            addField(group)
            footer(group)
        }
    }

    private func addField(_ group: VariantGroup) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 4)
            TextField("Another version…  or ?? for AI", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .serif))
                .lineLimit(1...6)
                .focused($addFocused)
                .onSubmit { submit(group) }
                .onChange(of: draft) { _, value in
                    if value.trimmingCharacters(in: .whitespacesAndNewlines) == "??" {
                        draft = ""
                        session.aiAlternatives(groupID: group.id)
                    }
                }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .onChange(of: session.focusAddField) { _, _ in addFocused = true }
        .onAppear { addFocused = true }
    }

    private func footer(_ group: VariantGroup) -> some View {
        HStack(spacing: 14) {
            Button {
                session.aiAlternatives(groupID: group.id)
            } label: {
                Label("Suggest", systemImage: "sparkle")
            }
            .disabled(session.aiLoadingGroup != nil)
            .help("Ask AI for more alternatives (or type ?? above)")
            .pointingHandOnHover()
            Spacer()
            Menu {
                Button("Clear AI Suggestions") { session.clearAISuggestions(groupID: group.id) }
                    .disabled(!group.options.contains { $0.source == .ai })
                Button("Keep Current, Remove Alternatives") { session.dissolve(groupID: group.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointingHandOnHover()
            .help("More")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Color.inkSecondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Text("Hover the underlined text and press ← →")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.inkSecondary.opacity(0.7))
                .offset(y: 18)
        }
        .padding(.bottom, 22)
    }

    private func submit(_ group: VariantGroup) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        if text == "??" {
            session.aiAlternatives(groupID: group.id)
        } else if !text.isEmpty {
            session.addOption(groupID: group.id, text: text, source: .human)
        }
        addFocused = true
    }

    private func explode(_ option: VariantOption, in group: VariantGroup) {
        guard group.options.count > 1 else { return }
        if let frame = rowFrames[option.id] {
            let burst = Burst(center: CGPoint(x: frame.midX, y: frame.midY), width: frame.width)
            bursts.append(burst)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { bursts.removeAll { $0.id == burst.id } }
        }
        Sounds.shared.play(.pop)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            session.removeOption(groupID: group.id, optionID: option.id)
        }
    }
}

private struct OptionRow: View {
    let option: VariantOption
    let isOriginal: Bool
    let isSelected: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if option.source == .ai {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.aiTint)
                } else {
                    Circle()
                        .fill(Color.inkSecondary.opacity(0.7))
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 10)
            .help(option.source == .ai ? "Suggested by AI" : "Written by you")

            VStack(alignment: .leading, spacing: 2) {
                Text(option.text)
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if isOriginal {
                    Text("original")
                        .font(.system(size: 9.5, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            Spacer(minLength: 0)
            if hovering && canDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 18))
                .pointingHandOnHover()
                .help("Delete (or select and press Delete)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accent.opacity(0.13) : hovering ? Color.ink.opacity(0.04) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .pointingHandOnHover()
        .help(isSelected ? "In use" : "Click to use this version")
    }
}

private struct RowFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Fun

struct Burst: Identifiable {
    let id = UUID()
    let center: CGPoint
    let width: CGFloat
}

/// Confetti-ish shards flung out from a deleted alternative.
struct ExplosionView: View {
    let burst: Burst
    @State private var fired = false
    @State private var shards: [Shard] = (0..<34).map { _ in Shard() }

    struct Shard {
        let angle = Double.random(in: 0..<(2 * .pi))
        let distance = CGFloat.random(in: 40...130)
        let size = CGFloat.random(in: 2.5...6)
        let spin = Double.random(in: -260...260)
        let xOffset = CGFloat.random(in: -0.45...0.45)
        let isAccent = Bool.random()
        let isRound = Bool.random()
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.accent.opacity(0.5), lineWidth: 1.5)
                .frame(width: fired ? 120 : 6, height: fired ? 120 : 6)
                .opacity(fired ? 0 : 0.9)
            ForEach(shards.indices, id: \.self) { i in
                let s = shards[i]
                RoundedRectangle(cornerRadius: s.isRound ? s.size : 1)
                    .fill(s.isAccent ? Color.accent : Color.ink.opacity(0.55))
                    .frame(width: s.size, height: s.isRound ? s.size : s.size * 0.6)
                    .rotationEffect(.degrees(fired ? s.spin : 0))
                    .offset(
                        x: s.xOffset * burst.width + (fired ? cos(s.angle) * s.distance : 0),
                        y: fired ? sin(s.angle) * s.distance * 0.7 + 26 : 0
                    )
                    .opacity(fired ? 0 : 1)
            }
        }
        .position(burst.center)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.75)) { fired = true }
        }
    }
}

/// Three dots that bounce while AI thinks up alternatives.
struct DancingDots: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    let phase = t * 7 - Double(i) * 0.7
                    Image(systemName: "sparkle")
                        .font(.system(size: 9 + 2 * max(0, sin(phase)), weight: .medium))
                        .foregroundStyle(Color.aiTint.opacity(0.55 + 0.45 * max(0, sin(phase))))
                        .offset(y: -5 * max(0, sin(phase)))
                        .rotationEffect(.degrees(18 * sin(phase * 0.5)))
                }
            }
            .frame(height: 18)
        }
    }
}

/// A shortcut drawn as a small key.
struct Keycap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.panel))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.ink.opacity(0.18)))
            .shadow(color: .black.opacity(0.1), radius: 0, y: 1)
    }
}

/// A small icon button: secondary ink, with a soft round highlight on hover
/// that deepens while pressed.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        Body(size: size, pressed: configuration.isPressed) { configuration.label }
    }

    private struct Body<Label: View>: View {
        let size: CGFloat
        let pressed: Bool
        @ViewBuilder let label: () -> Label
        @State private var hovering = false

        var body: some View {
            label()
                .foregroundStyle(hovering ? Color.ink : Color.inkSecondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.ink.opacity(pressed ? 0.14 : hovering ? 0.07 : 0)))
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

struct PanelHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.inkSecondary)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .pointingHandOnHover()
            .help("Close")
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 12)
    }
}

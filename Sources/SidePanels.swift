import SwiftUI

/// Right-hand drawer for writing you're not ready to use or lose.
struct OverflowPanel: View {
    @ObservedObject var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Overflow") { session.rightPanel = nil }
            Text("Extra paragraphs, notes, words you like. Select text and choose Stash in Overflow (\(AppShortcut.stash.label)) to send it here.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.inkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            OverflowEditor(session: session)
        }
        .background(Color.panel)
    }
}

/// Right-hand Lab: AI editing passes that point things out but never rewrite.
struct LabPanel: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var store = LabToolStore.shared
    @State private var editing: LabTool?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Lab") { session.rightPanel = nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Review") {
                        ForEach(store.tools(of: .flag)) { tool in row(tool) }
                    }
                    section("Trim") {
                        ForEach(store.tools(of: .cut)) { tool in row(tool) }
                    }
                    NewToolButton { editing = .blank() }
                    results
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
            .disabled(session.busy != nil)
        }
        .background(Color.panel)
        .sheet(item: $editing) { tool in
            LabToolEditor(tool: tool) { session.runLabTool($0) }
        }
    }

    private func row(_ tool: LabTool) -> some View {
        LabButton(title: tool.name, icon: tool.icon, edited: store.isEdited(tool)) {
            session.runLabTool(tool)
        } edit: {
            editing = tool
        }
        .contextMenu {
            Button("Run") { session.runLabTool(tool) }
            Button("Edit Prompt…") { editing = tool }
            Button("Duplicate…") {
                var copy = tool
                copy.id = UUID().uuidString
                copy.name = tool.name + " copy"
                editing = copy
            }
            if !tool.isPreset {
                Divider()
                Button("Delete", role: .destructive) { store.delete(tool.id) }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.inkSecondary)
                .padding(.leading, 4)
                .padding(.bottom, 2)
            content()
        }
    }

    @ViewBuilder
    private var results: some View {
        if let busy = session.busy {
            HStack(spacing: 8) {
                DancingDots()
                Text(busy).font(.system(size: 12)).foregroundStyle(Color.inkSecondary)
            }
            .padding(.leading, 4)
        }
        if let note = session.labNote {
            Text(note)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ink)
                .padding(.leading, 4)
        }
        if !session.cuts.isEmpty {
            HStack(spacing: 12) {
                Button("Cut all") { session.acceptAllCuts() }.pointingHandOnHover()
                Button("Ghost all") { session.ghostAllCuts() }.pointingHandOnHover()
                Button("Keep all") { session.clearLab() }.pointingHandOnHover()
                Spacer()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accent)
            .padding(.leading, 4)

            VStack(spacing: 6) {
                ForEach(session.cuts) { cut in
                    ResultCard(quote: cut.quote, note: cut.reason, strike: true) {
                        session.reveal(.proposedCut, id: cut.id)
                    } actions: {
                        Button { session.acceptCut(cut.id) } label: { Label("Cut", systemImage: "scissors") }
                            .pointingHandOnHover()
                        Button { session.keepCut(cut.id) } label: { Label("Keep", systemImage: "arrow.uturn.backward") }
                            .pointingHandOnHover()
                    }
                }
            }
        }
        if !session.findings.isEmpty {
            HStack {
                Spacer()
                Button("Clear") { session.clearLab() }
                    .pointingHandOnHover()
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accent)
            }
            VStack(spacing: 6) {
                ForEach(session.findings) { finding in
                    ResultCard(quote: finding.quote, note: finding.note, strike: false) {
                        session.reveal(.labMark, id: finding.id)
                    } actions: {
                        Button { session.dismissFinding(finding.id) } label: { Label("Dismiss", systemImage: "checkmark") }
                            .pointingHandOnHover()
                    }
                }
            }
        }
    }
}

private struct LabButton: View {
    let title: String
    let icon: String
    let edited: Bool
    let action: () -> Void
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(Color.accent)
                Text(title).font(.system(size: 13)).lineLimit(1)
                if edited {
                    Circle().fill(Color.accent.opacity(0.7)).frame(width: 5, height: 5)
                        .help("Prompt edited")
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .padding(.trailing, hovering ? 24 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .overlay(alignment: .trailing) {
            if hovering {
                Button(action: edit) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.inkSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit prompt")
                .pointingHandOnHover()
                .padding(.trailing, 3)
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.ink.opacity(0.05) : .clear))
        .onHover { hovering = $0 }
    }
}

private struct NewToolButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)
                Text("New tool").font(.system(size: 12.5, weight: .medium))
                Spacer()
            }
            .foregroundStyle(hovering ? Color.accent : Color.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(hovering ? Color.accent.opacity(0.5) : Color.hairline.opacity(2.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointingHandOnHover()
        .help("Write your own Lab tool")
    }
}

private struct ResultCard<Actions: View>: View {
    let quote: String
    let note: String
    let strike: Bool
    let onTap: () -> Void
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(quote)
                .font(.system(size: 13.5, design: .serif))
                .strikethrough(strike, color: Color(nsColor: Theme.cutStrike))
                .foregroundStyle(Color.ink.opacity(strike ? 0.6 : 0.9))
                .lineLimit(4)
            Text(note)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.inkSecondary)
            HStack(spacing: 14) { actions() }
                .buttonStyle(.plain)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).fill(Color.ink.opacity(hovering ? 0.03 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovering ? Color.accent.opacity(0.35) : Color.hairline))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .pointingHandOnHover()
        .help("Show in the text")
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

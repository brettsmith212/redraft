import SwiftUI

/// One Lab pass: a prompt that either highlights passages with a note or
/// proposes cuts. The built-in tools can have their prompt edited (and
/// restored); your own tools can be changed freely or deleted.
struct LabTool: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case flag, cut
        var id: String { rawValue }

        var title: String { self == .flag ? "Highlight" : "Suggest cuts" }

        var explanation: String {
            switch self {
            case .flag: "Marks passages in your text, each with a short note. Nothing is changed."
            case .cut: "Proposes deletions you can cut or keep one by one. Nothing is rewritten."
            }
        }

        /// Instructions Redraft adds to every prompt so it can find and
        /// mark the results in your text.
        var contract: String {
            switch self {
            case .flag:
                "Quote each passage exactly as it appears in the text, character for character, using the shortest span that captures it. Add a short note (under 15 words) for each. Do not rewrite anything. Flagging nothing is fine."
            case .cut:
                "Only delete: never rewrite, reorder or add a word. Return each deletion as an exact, character-for-character quote of contiguous text, in document order and non-overlapping, with a short reason (under 12 words) in the note. After all deletions, every remaining sentence must still read grammatically."
            }
        }
    }

    var id: String
    var name: String
    var icon: String
    var kind: Kind
    var prompt: String

    var isPreset: Bool { LabTool.presets.contains { $0.id == id } }

    /// The full system prompt sent to the model.
    var systemPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + kind.contract
    }

    static func blank() -> LabTool {
        LabTool(id: UUID().uuidString, name: "", icon: "sparkles", kind: .flag, prompt: "")
    }

    static let presets: [LabTool] = [
        LabTool(id: "convoluted", name: "Mark convoluted sentences", icon: "scribble.variable", kind: .flag, prompt: """
        You are a careful line editor. Find sentences that are convoluted: hard to follow on a first read because of stacked clauses, buried subjects, piled-up qualifiers or unclear references.

        Flag only the genuinely difficult ones, at most 8. Quote whole sentences, and say in the note what makes each one hard.
        """),
        LabTool(id: "tone", name: "Find words that don't fit the tone", icon: "tuningfork", kind: .flag, prompt: """
        You are a careful line editor. First work out the dominant tone of the piece. Then find words or short phrases that don't fit it, for example ornate, jargony or stiff wording in plain writing, or slang in formal writing.

        Flag only real mismatches, at most 10. In each note, name the mismatch and the plainer direction to take.
        """),
        trim("trim10", "Slight trim", "scissors", 10),
        trim("trim20", "Tighten", "arrow.down.right.and.arrow.up.left", 20),
        trim("trim30", "Even sharper", "wand.and.rays", 30),
        trim("trim50", "Cut in half", "circle.lefthalf.filled", 50),
    ]

    private static func trim(_ id: String, _ name: String, _ icon: String, _ percent: Int) -> LabTool {
        LabTool(id: id, name: name, icon: icon, kind: .cut, prompt: """
        You are an editor who tightens writing only by deleting. Choose passages to delete so the piece gets about \(percent)% shorter while keeping its meaning, its voice and its strongest material.

        Good candidates: redundant sentences, throat-clearing, hedges, filler words and phrases, repeated points and weak asides.
        """)
    }

    static let icons = [
        "sparkles", "scribble.variable", "tuningfork", "scissors", "wand.and.rays", "text.magnifyingglass",
        "quote.bubble", "exclamationmark.bubble", "checkmark.seal", "lightbulb", "eye", "ear",
        "textformat", "character.cursor.ibeam", "list.bullet.indent", "arrow.down.right.and.arrow.up.left",
        "circle.lefthalf.filled", "target", "ruler", "flame", "leaf", "hare", "tortoise", "heart",
    ]
}

/// The Lab's tools: built-in presets (with any prompt edits) followed by
/// your own, saved in UserDefaults.
@MainActor
final class LabToolStore: ObservableObject {
    static let shared = LabToolStore()

    @Published private(set) var custom: [LabTool] = []
    @Published private(set) var promptOverrides: [String: String] = [:]

    private let customKey = "lab.customTools"
    private let overridesKey = "lab.presetPrompts"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: customKey), let tools = try? JSONDecoder().decode([LabTool].self, from: data) {
            custom = tools
        }
        promptOverrides = defaults.dictionary(forKey: overridesKey) as? [String: String] ?? [:]
    }

    var tools: [LabTool] { presets + custom }

    var presets: [LabTool] {
        LabTool.presets.map { preset in
            var tool = preset
            if let prompt = promptOverrides[preset.id] { tool.prompt = prompt }
            return tool
        }
    }

    func tools(of kind: LabTool.Kind) -> [LabTool] { tools.filter { $0.kind == kind } }

    func defaultPrompt(for id: String) -> String? {
        LabTool.presets.first { $0.id == id }?.prompt
    }

    func isEdited(_ tool: LabTool) -> Bool {
        promptOverrides[tool.id] != nil
    }

    func save(_ tool: LabTool) {
        if let preset = LabTool.presets.first(where: { $0.id == tool.id }) {
            // Built-ins keep their name, icon and kind; only the prompt changes.
            promptOverrides[tool.id] = tool.prompt == preset.prompt ? nil : tool.prompt
        } else {
            var tool = tool
            if tool.name.trimmingCharacters(in: .whitespaces).isEmpty { tool.name = "Untitled tool" }
            if let index = custom.firstIndex(where: { $0.id == tool.id }) {
                custom[index] = tool
            } else {
                custom.append(tool)
            }
        }
        persist()
    }

    func delete(_ id: String) {
        custom.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: customKey) }
        defaults.set(promptOverrides, forKey: overridesKey)
    }
}

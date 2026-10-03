import Foundation

/// Model and reasoning choices, one of each per provider, used for every AI
/// feature (alternatives, ??, and the Lab).
enum AISettings {
    static func key(_ provider: AIProvider, _ field: String) -> String {
        "ai.\(provider.rawValue).\(field)"
    }

    /// The chosen model, or "" for the default.
    static func storedModel(_ provider: AIProvider) -> String {
        (UserDefaults.standard.string(forKey: key(provider, "model")) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// The reasoning effort to request ("" means let the model decide).
    static func effort(_ provider: AIProvider) -> String {
        UserDefaults.standard.string(forKey: key(provider, "effort")) ?? defaultEffort(provider)
    }

    static func defaultEffort(_ provider: AIProvider) -> String {
        provider == .chatGPT ? "medium" : "low"
    }

    static let defaultAnthropicModel = "claude-sonnet-5-5"

    /// Workspace for Anthropic keys that aren't tied to one ("" when not needed).
    static var anthropicWorkspace: String {
        (UserDefaults.standard.string(forKey: "ai.anthropic.workspace") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var anthropicModel: String {
        let stored = storedModel(.anthropic)
        if !stored.isEmpty { return stored }
        return UserDefaults.standard.string(forKey: "aiModel") ?? defaultAnthropicModel
    }

    static var openAIModel: String {
        let stored = storedModel(.openAI)
        if !stored.isEmpty { return stored }
        let legacy = (UserDefaults.standard.string(forKey: "openAIModel") ?? "").trimmingCharacters(in: .whitespaces)
        if !legacy.isEmpty { return legacy }
        return UserDefaults.standard.string(forKey: OpenAIModels.recommendedKey) ?? AIClient.defaultOpenAIModel
    }

    /// Reasoning choices offered in Settings.
    static func efforts(for provider: AIProvider) -> [(value: String, title: String)] {
        switch provider {
        case .anthropic:
            [("low", "Low"), ("medium", "Medium"), ("high", "High")]
        case .openAI, .chatGPT:
            [("", "Automatic"), ("minimal", "Minimal"), ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra high")]
        }
    }

    static func title(forEffort effort: String) -> String {
        switch effort {
        case "": "Automatic"
        case "xhigh": "Extra high"
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }

    /// OpenAI efforts from least to most thinking, for stepping down when a
    /// model rejects the requested level.
    static let openAIEffortLadder = ["minimal", "low", "medium", "high", "xhigh", "max"]
}

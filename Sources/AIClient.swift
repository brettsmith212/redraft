import Foundation
import Security

enum AIError: LocalizedError {
    case noKey(String)
    /// Nothing connected yet: the app offers to set AI up.
    case notSetUp
    case http(String)
    case refusal
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noKey(let provider): "Add your \(provider) API key in Settings (⌘,) to use AI features."
        case .notSetUp: "Connect AI to use this feature."
        case .http(let message): message
        case .refusal: "The model declined this request."
        case .badResponse: "Couldn't read the model's response. Try again."
        }
    }
}

struct QuotedNote: Decodable {
    let quote: String
    let note: String
}

enum AIProvider: String, CaseIterable, Identifiable {
    // Listed in this order in Settings: the ChatGPT plan first.
    case chatGPT, openAI, anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: "Anthropic API key"
        case .openAI: "OpenAI API key"
        case .chatGPT: "ChatGPT plan (Sign in with ChatGPT)"
        }
    }
}

/// Every call asks for structured JSON so the editor can map results
/// straight back onto the text. Three ways to reach a model: the Claude
/// API, the OpenAI API, or the writer's own ChatGPT plan via Sign in with
/// ChatGPT.
enum AIClient {
    static let defaultAnthropicModel = "claude-sonnet-5-5"
    static let anthropicModels: [(id: String, name: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
    ]
    static let defaultOpenAIModel = "gpt-5"

    static var provider: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .chatGPT
    }

    /// Asks for a JSON object whose `key` holds a list, and delivers each
    /// list element the moment it's complete (on the OpenAI-based paths, which
    /// stream). Returns the full list.
    @MainActor
    static func streamList<E: Decodable>(
        _ type: E.Type,
        key: String,
        system: String,
        user: String,
        schema: [String: Any],
        onElement: @escaping (E) -> Void
    ) async throws -> [E] {
        var parser = StreamingArrayParser(key: key)
        var delivered: [E] = []
        func deliver(_ text: String) {
            for raw in parser.newElements(in: text) {
                guard let element = StreamingArrayParser.decode(raw, as: E.self) else { continue }
                delivered.append(element)
                onElement(element)
            }
        }
        let text: String
        switch provider {
        case .anthropic:
            text = try await anthropic(system: system, user: user, schema: schema,
                                       model: AISettings.anthropicModel, effort: AISettings.effort(.anthropic))
        case .openAI:
            guard let apiKey = APIKeyStore.openAI.key else { throw AIError.noKey("OpenAI") }
            text = try await ResponsesStream.run(
                bearer: apiKey, model: AISettings.openAIModel, instructions: system, input: user, schema: schema,
                effort: AISettings.effort(.openAI),
                failure: { body, status in
                    let message = ((body as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                    return AIError.http(message ?? "OpenAI API error (HTTP \(status)).")
                },
                onText: deliver
            )
        case .chatGPT:
            text = try await ChatGPTAuth.shared.respond(instructions: system, input: user, schema: schema, onText: deliver)
        }
        // Anything the stream didn't surface (or the whole list, for non-streaming paths).
        deliver(text)
        if delivered.isEmpty, !text.contains("\"\(key)\"") { throw AIError.badResponse }
        return delivered
    }

    /// Opens a connection to the current provider ahead of a request.
    @MainActor
    static func prewarm() {
        ResponsesStream.prewarm(host: provider == .anthropic ? "api.anthropic.com" : "api.openai.com")
    }

    private static func post(_ url: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw AIError.http(message.map(friendlyAnthropicError) ?? "API error (HTTP \(status)).")
        }
        return json
    }

    /// Headers for every Anthropic request; adds the workspace when one is set
    /// (needed for keys that aren't tied to a workspace).
    static func anthropicHeaders(key: String) -> [String: String] {
        var headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
        let workspace = AISettings.anthropicWorkspace
        if !workspace.isEmpty { headers["anthropic-workspace-id"] = workspace }
        return headers
    }

    static func isWorkspaceError(_ message: String) -> Bool {
        message.contains("not scoped to a workspace") || message.contains("anthropic-workspace-id")
    }

    static func friendlyAnthropicError(_ message: String) -> String {
        isWorkspaceError(message)
            ? "This key isn't tied to a workspace. Enter its Workspace ID in Settings → AI, or create a key inside a workspace in the Claude Console."
            : message
    }

    private static func anthropic(system: String, user: String, schema: [String: Any], model: String, effort: String) async throws -> String {
        guard let key = APIKeyStore.anthropic.key else { throw AIError.noKey("Anthropic") }
        var headers = anthropicHeaders(key: key)
        headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        let json = try await post(
            "https://api.anthropic.com/v1/messages",
            headers: headers,
            body: [
                "model": model,
                "max_tokens": 16000,
                "system": system,
                "messages": [["role": "user", "content": user]],
                "output_config": [
                    "effort": effort,
                    "format": ["type": "json_schema", "schema": schema],
                ],
                "fallbacks": "default",
            ]
        )
        if json["stop_reason"] as? String == "refusal" { throw AIError.refusal }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw AIError.badResponse
        }
        return text
    }

    // MARK: Schemas

    private static let stringListSchema: [String: Any] = [
        "type": "object",
        "properties": ["alternatives": ["type": "array", "items": ["type": "string"]]],
        "required": ["alternatives"],
        "additionalProperties": false,
    ]

    private static let quotedNotesSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["quote": ["type": "string"], "note": ["type": "string"]],
                    "required": ["quote", "note"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["items"],
        "additionalProperties": false,
    ]


    // MARK: Tasks

    @MainActor
    static func alternatives(
        for selection: String, context: String, existing: [String], onEach: @escaping (String) -> Void
    ) async throws -> [String] {
        let system = """
        You help a writer explore other ways to say something. Given a selected passage and the \
        paragraph it sits in, propose distinct alternatives that could replace the selection verbatim, \
        in place. Read the whole paragraph: choose wording that fits the sentence's grammar, rhythm and \
        meaning, not dictionary synonyms. Keep the writer's voice and register and roughly the same \
        length. A single word gets single words or short phrases; a sentence or paragraph gets a full \
        rewrite of the same scope. Match the selection's capitalization at the start and its trailing \
        punctuation. Make each option meaningfully different, and never repeat an existing option.
        """
        let user = """
        Paragraph:
        <<<
        \(context)
        >>>

        Selection to replace:
        <<<
        \(selection)
        >>>

        Options the writer already has:
        \(existing.map { "- " + $0 }.joined(separator: "\n"))

        Give 5 new alternatives.
        """
        return try await streamList(String.self, key: "alternatives", system: system, user: user,
                                    schema: stringListSchema, onElement: onEach)
    }

    /// Runs a Lab tool: its prompt plus the output rules Redraft needs.
    @MainActor
    static func lab(_ tool: LabTool, text: String, onEach: @escaping (QuotedNote) -> Void) async throws -> [QuotedNote] {
        let user = "\(tool.kind == .cut ? "Document" : "Text"):\n<<<\n\(text)\n>>>"
        return try await streamList(QuotedNote.self, key: "items", system: tool.systemPrompt, user: user,
                                    schema: quotedNotesSchema, onElement: onEach)
    }
}

/// API keys live in the login Keychain, with environment variables as a fallback.
struct APIKeyStore {
    static let anthropic = APIKeyStore(account: "anthropic-api-key", environment: "ANTHROPIC_API_KEY")
    static let openAI = APIKeyStore(account: "openai-api-key", environment: "OPENAI_API_KEY")

    private static let service = "com.brettsmith.Redraft"
    let account: String
    let environment: String

    var key: String? {
        if let stored = storedKey(), !stored.isEmpty { return stored }
        if let env = ProcessInfo.processInfo.environment[environment], !env.isEmpty { return env }
        return nil
    }

    func storedKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func save(_ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

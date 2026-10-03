import Foundation

/// The models an OpenAI API key can use, for the Settings model picker.
/// Loaded from GET /v1/models when a key is saved (and on Refresh), and
/// remembered between launches.
@MainActor
final class OpenAIModels: ObservableObject {
    static let shared = OpenAIModels()

    struct Model: Identifiable, Hashable, Codable {
        let id: String
        let created: Int
        /// Reasoning levels, when the API reports them (otherwise the standard set is offered).
        var levels: [String] = []
    }

    @Published private(set) var models: [Model] = []
    @Published private(set) var loading = false
    @Published private(set) var lastError: String?

    private let cacheKey = "openAIModelsCache"

    private init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([Model].self, from: data) {
            models = cached
        }
    }

    func load() async {
        guard let key = APIKeyStore.openAI.key else {
            models = []
            lastError = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard status == 200, let json else {
                let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "OpenAI returned HTTP \(status)."
                throw AIError.http(status == 401 ? "That API key wasn't accepted. Check it and save again." : message)
            }
            models = Self.parse(json)
            lastError = models.isEmpty ? "No writing models are available to this key." : nil
            if let data = try? JSONEncoder().encode(models) { UserDefaults.standard.set(data, forKey: cacheKey) }
            if let recommended { UserDefaults.standard.set(recommended, forKey: Self.recommendedKey) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Keeps the models that can write text, newest first: GPT and o-series,
    /// without dated snapshots or audio, image, embedding and other special-purpose models.
    static func parse(_ json: [String: Any]) -> [Model] {
        let list = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        let excluded = ["audio", "realtime", "tts", "transcribe", "search", "image", "embedding",
                        "moderation", "instruct", "dall-e", "whisper", "davinci", "babbage", "computer-use",
                        "live", "codex"]
        let dated = try! NSRegularExpression(pattern: #"-\d{4}-\d{2}-\d{2}$|-\d{4}$"#)
        return list.compactMap { item -> Model? in
            guard let id = (item["id"] as? String) ?? (item["slug"] as? String) else { return nil }
            let lower = id.lowercased()
            let isWriter = lower.hasPrefix("gpt-") || lower.range(of: #"^o\d"#, options: .regularExpression) != nil
            guard isWriter, !excluded.contains(where: { lower.contains($0) }),
                  dated.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) == nil else { return nil }
            let levels = (item["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
            return Model(id: id, created: item["created"] as? Int ?? 0, levels: levels)
        }
        .sorted { $0.created != $1.created ? $0.created > $1.created : $0.id < $1.id }
    }

    static let recommendedKey = "openAIDefaultModelCache"

    /// The default when no model is chosen: the newest Astra model this key
    /// has (matching the ChatGPT plan's default), else the newest model.
    var recommended: String? {
        models.first { $0.id.lowercased().contains("astra") }?.id ?? models.first?.id
    }

    func levels(for id: String) -> [String] {
        models.first { $0.id == id }?.levels ?? []
    }
}

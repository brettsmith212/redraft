import Foundation

/// Streams a Responses API request (OpenAI API key or ChatGPT plan) and
/// reports the text as it grows.
@MainActor
enum ResponsesStream {
    /// The effort that worked for each model and requested level, so later
    /// requests skip values the model rejected. "" means "don't send one".
    private static var workingEffort: [String: String] = [:]

    /// Time to first text and total time of the last request (for tuning).
    private(set) static var lastTiming: (first: TimeInterval?, total: TimeInterval)?

    static func run(
        bearer: String,
        model: String,
        instructions: String,
        input: String,
        schema: [String: Any]?,
        effort: String,
        ladder: [String]? = nil,
        failure: (Any?, Int) -> Error,
        onText: ((String) -> Void)?
    ) async throws -> String {
        // The requested level, then gentler ones, then the model's own default.
        let memo = "\(model)|\(effort)"
        var candidates: [String]
        if let known = workingEffort[memo] {
            candidates = [known]
        } else if effort.isEmpty {
            candidates = [""]
        } else {
            // Step down through this model's own levels when it has published them.
            let levels = ladder ?? AISettings.openAIEffortLadder
            if let index = levels.firstIndex(of: effort) {
                candidates = [effort] + levels[..<index].reversed() + [""]
            } else {
                candidates = [effort, ""]
            }
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                let text = try await once(
                    bearer: bearer, model: model, instructions: instructions, input: input,
                    schema: schema, effort: candidate.isEmpty ? nil : candidate, failure: failure, onText: onText
                )
                workingEffort[memo] = candidate
                return text
            } catch let error as StreamRejection where error.mentionsReasoning {
                lastError = error.underlying
                continue
            }
        }
        throw lastError ?? AIError.badResponse
    }

    private struct StreamRejection: Error {
        let underlying: Error
        let mentionsReasoning: Bool
    }

    private static func once(
        bearer: String, model: String, instructions: String, input: String,
        schema: [String: Any]?, effort: String?, failure: (Any?, Int) -> Error, onText: ((String) -> Void)?
    ) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [["role": "user", "content": input]],
            "store": false,
            "stream": true,
        ]
        if let schema {
            body["text"] = ["format": ["type": "json_schema", "name": "result", "schema": schema, "strict": true]]
        }
        if let effort { body["reasoning"] = ["effort": effort] }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        var firstText: TimeInterval?
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 1_000_000 { break } }
            let json = try? JSONSerialization.jsonObject(with: data)
            let error = failure(json, status)
            let raw = String(decoding: data, as: UTF8.self).lowercased()
            if status == 400, effort != nil, raw.contains("reasoning") {
                throw StreamRejection(underlying: error, mentionsReasoning: true)
            }
            throw error
        }

        var text = ""
        var completed = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "response.output_text.delta":
                text += event["delta"] as? String ?? ""
                if firstText == nil { firstText = Date().timeIntervalSince(started) }
                onText?(text)
            case "response.refusal.delta", "response.refusal.done":
                throw AIError.refusal
            case "response.completed":
                completed = true
            case "response.failed", "error":
                throw failure(event["response"] ?? event, status)
            case "response.incomplete":
                throw AIError.http("The model stopped before finishing. Try again.")
            default:
                break
            }
            if completed { break }
        }
        lastTiming = (firstText, Date().timeIntervalSince(started))
        guard completed else { throw AIError.http("The connection was interrupted. Try again.") }
        return text
    }

    // MARK: Warm-up

    private static var lastWarm: [String: Date] = [:]

    /// Opens the HTTPS connection ahead of a request so the first one doesn't
    /// pay for DNS and the TLS handshake. Cheap, and at most once a minute.
    static func prewarm(host: String) {
        if let last = lastWarm[host], Date().timeIntervalSince(last) < 60 { return }
        lastWarm[host] = Date()
        var request = URLRequest(url: URL(string: "https://\(host)/")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request).resume()
    }
}

/// Pulls finished elements out of a JSON array while the JSON is still being
/// written, e.g. each string in `{"alternatives": ["a", "b", …` as soon as its
/// closing quote arrives.
struct StreamingArrayParser {
    let key: String
    private(set) var emitted = 0

    init(key: String) { self.key = key }

    /// Elements completed since the last call, as raw JSON.
    mutating func newElements(in text: String) -> [String] {
        let all = Self.completeElements(in: text, key: key)
        guard all.count > emitted else { return [] }
        let fresh = Array(all[emitted...])
        emitted = all.count
        return fresh
    }

    static func completeElements(in text: String, key: String) -> [String] {
        let bytes = Array(text.utf8)
        let marker = Array("\"\(key)\"".utf8)
        guard let keyEnd = Self.find(marker, in: bytes) else { return [] }
        var i = keyEnd
        while i < bytes.count, bytes[i] != UInt8(ascii: "[") { i += 1 }
        guard i < bytes.count else { return [] }
        i += 1

        var elements: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var start: Int?
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                if escaped {
                    escaped = false
                } else if b == UInt8(ascii: "\\") {
                    escaped = true
                } else if b == UInt8(ascii: "\"") {
                    inString = false
                    if depth == 0, let s = start {
                        elements.append(String(decoding: bytes[s...i], as: UTF8.self))
                        start = nil
                    }
                }
            } else {
                switch b {
                case UInt8(ascii: "\""):
                    if depth == 0, start == nil { start = i }
                    inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    if depth == 0, start == nil { start = i }
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    if depth == 0 { return elements }  // end of the array
                    depth -= 1
                    if depth == 0, let s = start {
                        elements.append(String(decoding: bytes[s...i], as: UTF8.self))
                        start = nil
                    }
                default:
                    break
                }
            }
            i += 1
        }
        return elements
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where haystack[i..<(i + needle.count)].elementsEqual(needle) {
            return i + needle.count
        }
        return nil
    }

    /// Decodes one raw element (a string or an object).
    static func decode<E: Decodable>(_ raw: String, as type: E.Type) -> E? {
        (try? JSONDecoder().decode([E].self, from: Data("[\(raw)]".utf8)))?.first
    }
}

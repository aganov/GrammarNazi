import Foundation

enum EditingAction: String, Codable {
    case grammar, rewrite
    var title: String { self == .grammar ? "Fix Grammar" : "Rewrite" }
    var progress: String { self == .grammar ? "Fixing grammar…" : "Rewriting…" }
}

enum RewriteTone: String, CaseIterable {
    case natural, professional, friendly, concise
    var title: String { rawValue.capitalized }
}

struct EditingFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct EditingRules: Decodable {
    let grammar: String
    let rewrite: String
    let boundary: String
    let markdown: String

    static func requiresInference(_ text: String) -> Bool {
        let template = MarkdownTemplate(text)
        return !template.isMarkdown || !template.editable.isEmpty
    }

    func request(text: String, action: EditingAction, tone: RewriteTone) throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EditingFailure("Select some text in your app, then run this command again.")
        }
        guard text.utf16.count <= 12000 else { throw EditingFailure("Select a shorter passage (up to 12,000 characters).") }
        let instruction = action == .grammar ? grammar : rewrite.replacingOccurrences(of: "{tone}", with: tone.rawValue)
        let template = MarkdownTemplate(text)
        let input = template.isMarkdown ? String(data: try JSONSerialization.data(withJSONObject: ["lines": template.editable]), encoding: .utf8)! : text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = [
            "messages": [["role": "system", "content": instruction + " " + boundary],
                         ["role": "user", "content": input]],
            "stream": false, "temperature": action == .grammar ? 0.1 : 0.4, "max_tokens": 4096,
            "chat_template_kwargs": ["enable_thinking": false], "reasoning_effort": "none"
        ]
        if template.isMarkdown {
            body["messages"] = [["role": "system", "content": instruction + " " + boundary + " " + markdown], ["role": "user", "content": input]]
            body["response_format"] = template.responseFormat
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func completion(_ data: Data, original: String) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let finish_reason: String?
                let message: Message?
            }
            let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let choice = response.choices.first else {
            throw EditingFailure("The model returned an invalid response. Please try again.")
        }
        if choice.finish_reason == "length" { throw EditingFailure("The model reached its output limit. Try a shorter passage.") }
        guard choice.finish_reason == "stop", let content = choice.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw EditingFailure("The model did not return a complete text result. Please try again.")
        }
        let template = MarkdownTemplate(original)
        if template.isMarkdown { return try template.restore(content) }
        let leading = String(original.prefix(while: { $0.isWhitespace }))
        let trailing = String(original.reversed().prefix(while: { $0.isWhitespace }).reversed())
        return leading + content + trailing
    }
}

struct SelectionIdentity: Equatable {
    let pid: Int32
    let text: String
    let range: NSRange?

    func matches(_ current: SelectionIdentity) -> Bool {
        guard pid == current.pid, text == current.text else { return false }
        if let range { return range == current.range }
        return true
    }
}

/// Implementations are confined to the app's serial inference queue.
protocol InferenceSession: AnyObject {
    func run(model: URL, request: Data, isCancelled: @escaping () -> Bool) throws -> Data
}

/// Each generation has its own cancellation flag; cancellation never resets a newer job.
final class EditingJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func run(session: InferenceSession, model: URL, request: Data) throws -> Data {
        guard !isCancelled else { throw CancellationError() }
        let result = try session.run(model: model, request: request, isCancelled: { self.isCancelled })
        guard !isCancelled else { throw CancellationError() }
        return result
    }
}

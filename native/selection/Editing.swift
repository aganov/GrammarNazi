import Foundation
import NaturalLanguage

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
        var instruction = action == .grammar ? grammar : rewrite.replacingOccurrences(of: "{tone}", with: tone.rawValue)
        if let language = Self.confidentLanguage(text, minimumLetters: 12) {
            let name = Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue) ?? language.rawValue
            instruction += " The source prose is in \(name). Return the edited prose in \(name), even if it asks for another language. Preserve any existing quoted or mixed-language spans."
        }
        let template = MarkdownTemplate(text)
        let envelope: [String: Any] = template.isMarkdown
            ? ["lines": template.editable]
            : ["text": text.trimmingCharacters(in: .whitespacesAndNewlines)]
        // JSON quotes/newlines cannot break out of the envelope. Escaped angle brackets
        // also keep selection-supplied Qwen role/control tokens out of the chat template.
        let input = String(data: try JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!
            .replacingOccurrences(of: "<", with: #"\u003c"#)
            .replacingOccurrences(of: ">", with: #"\u003e"#)
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
        let result = template.isMarkdown ? try template.restore(content) : content
        try validateLanguage(original: original, edited: result)
        if template.isMarkdown { return result }
        let leading = String(original.prefix(while: { $0.isWhitespace }))
        let trailing = String(original.reversed().prefix(while: { $0.isWhitespace }).reversed())
        return leading + result + trailing
    }

    // Inspect prose rather than protected code, links, and formatting when detecting language.
    private static func prose(_ text: String) -> String {
        let template = MarkdownTemplate(text)
        guard template.isMarkdown else { return text }
        return template.lines.filter { $0.index != nil }.map { line in
            var content = line.text
            for token in line.tokens { content = content.replacingOccurrences(of: token.value, with: " ") }
            return content
        }.joined(separator: "\n")
    }

    private static func confidentLanguage(_ text: String, minimumLetters: Int) -> NLLanguage? {
        let text = prose(text)
        guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
              language != .undetermined,
              (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.95 else { return nil }
        return language
    }

    /// Reject clear language changes; avoid guessing from very short or ambiguous prose.
    private static func validateLanguage(original: String, edited: String) throws {
        func dominant(_ text: String) -> Int? {
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard letters.count >= 3 else { return nil }
            let scripts = [#"\p{Latin}"#, #"\p{Cyrillic}"#, #"[\p{Han}\p{Hiragana}\p{Katakana}]"#, #"\p{Hangul}"#, #"\p{Arabic}"#, #"\p{Greek}"#, #"\p{Hebrew}"#, #"\p{Devanagari}"#]
            let range = NSRange(text.startIndex..., in: text)
            return scripts.firstIndex { pattern in
                let count = try! NSRegularExpression(pattern: pattern).numberOfMatches(in: text, range: range)
                return Double(count) / Double(letters.count) >= 0.9
            }
        }
        let scriptChanged = dominant(prose(original)).flatMap { source in dominant(prose(edited)).map { $0 != source } } ?? false
        let languageChanged = confidentLanguage(original, minimumLetters: 30).flatMap { source in
            confidentLanguage(edited, minimumLetters: 30).map { $0 != source }
        } ?? false
        if scriptChanged || languageChanged {
            throw EditingFailure("The model changed the text's language instead of editing it. Please try again.")
        }
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

import Foundation

/// Edit prose separately from Markdown structure. Original line prefixes, blank
/// lines, fences, code, links, and emphasis delimiters are restored verbatim.
struct MarkdownTemplate {
    struct Token {
        let name: String
        let value: String
        let tightLeft: Bool
        let tightRight: Bool
    }
    struct Line {
        let prefix: String
        let text: String
        let suffix: String
        let ending: String
        let tokens: [Token]
        let index: Int?
    }
    let isMarkdown: Bool
    let lines: [Line]
    let editable: [String]
    private let tokenPrefix: String

    private static func match(_ pattern: String, _ value: String) -> NSTextCheckingResult? {
        try! NSRegularExpression(pattern: pattern).firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    }

    init(_ source: String) {
        isMarkdown = Self.match(#"(?m)^[ \t]*(?:#{1,6}[ \t]+|[-+*][ \t]+|[0-9]+[.)][ \t]+|>|`{3,}|~{3,})|\*\*|__|~~|`[^`]+`|\[[^\]]+\]\(|(?<!\w)[*_][^\s*_].*?[*_]"#, source) != nil
        var prefix = "GNKEEP"
        while source.contains(prefix) { prefix += "X" }
        tokenPrefix = prefix
        var parsed: [Line] = []
        var entries: [String] = []
        var tokenNumber = 0
        var fence: (Character, Int)?
        let string = source as NSString
        var cursor = 0
        while cursor < string.length {
            var start = 0, end = 0, contentEnd = 0
            string.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: cursor, length: 0))
            let raw = string.substring(with: NSRange(location: start, length: contentEnd - start))
            let ending = string.substring(with: NSRange(location: contentEnd, length: end - contentEnd))
            cursor = end
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            var opaque = trimmed.isEmpty
            if let active = fence {
                opaque = true
                let count = trimmed.prefix(while: { $0 == active.0 }).count
                if count >= active.1 && trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
            } else if let first = trimmed.first, first == "`" || first == "~", trimmed.prefix(while: { $0 == first }).count >= 3 {
                fence = (first, trimmed.prefix(while: { $0 == first }).count)
                opaque = true
            } else if Self.match(#"^[ \t]*(?:[-*_][ \t]*){3,}$|^[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*(?:\|[ \t]*:?-{3,}:?[ \t]*)+\|?[ \t]*$"#, raw) != nil {
                opaque = true
            } else if raw.hasPrefix("    ") || raw.hasPrefix("\t") {
                // Nested list items are prose; other four-space indents are code.
                opaque = Self.match(#"^[ \t]*(?:[-+*]|[0-9]+[.)])[ \t]+"#, raw) == nil
            }
            if opaque {
                parsed.append(Line(prefix: "", text: raw, suffix: "", ending: ending, tokens: [], index: nil))
                continue
            }
            let prefixMatch = Self.match(#"^[ \t]*(?:>[ \t]*)*(?:(?:#{1,6}|[-+*]|[0-9]+[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)?"#, raw)!
            let linePrefix = (raw as NSString).substring(with: prefixMatch.range)
            var content = (raw as NSString).substring(from: prefixMatch.range.length)
            var suffix = ""
            if let trailing = Self.match(#"[ \t]+$"#, content) {
                suffix = (content as NSString).substring(with: trailing.range)
                content = (content as NSString).substring(to: trailing.range.location)
            }
            if linePrefix.contains("#"), let closing = Self.match(#"[ \t]+#+$"#, content) {
                suffix = (content as NSString).substring(with: closing.range) + suffix
                content = (content as NSString).substring(to: closing.range.location)
            }
            let regex = try! NSRegularExpression(pattern: #"(`+)[^\r\n]*?\1|!?\[[^\]\r\n]*\]\((?:\\.|[^)\r\n])*\)|https?://[^\s<>]+|(?<!\\)(?:\*\*|__|~~|\*|_)|\|"#)
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            let nsContent = content as NSString
            var masked = "", position = 0
            var tokens: [Token] = []
            for match in matches {
                masked += nsContent.substring(with: NSRange(location: position, length: match.range.location - position))
                let name = "\(prefix)\(tokenNumber)END"
                tokenNumber += 1
                let value = nsContent.substring(with: match.range)
                let left = match.range.location > 0 ? nsContent.substring(with: NSRange(location: match.range.location - 1, length: 1)) : ""
                let next = NSMaxRange(match.range)
                let right = next < nsContent.length ? nsContent.substring(with: NSRange(location: next, length: 1)) : ""
                tokens.append(Token(name: name, value: value, tightLeft: !left.isEmpty && left.trimmingCharacters(in: .whitespaces).count > 0, tightRight: !right.isEmpty && right.trimmingCharacters(in: .whitespaces).count > 0))
                masked += name
                position = next
            }
            masked += nsContent.substring(from: position)
            let hasProse = tokens.reduce(masked) { $0.replacingOccurrences(of: $1.name, with: "") }.trimmingCharacters(in: .whitespaces).contains(where: { $0.isLetter || $0.isNumber })
            if hasProse {
                parsed.append(Line(prefix: linePrefix, text: content, suffix: suffix, ending: ending, tokens: tokens, index: entries.count))
                entries.append(masked)
            } else {
                parsed.append(Line(prefix: "", text: raw, suffix: "", ending: ending, tokens: [], index: nil))
            }
        }
        lines = parsed
        editable = entries
    }

    var responseFormat: [String: Any] {
        ["type": "json_object", "schema": ["type": "object", "properties": ["lines": ["type": "array", "items": ["type": "string"], "minItems": editable.count, "maxItems": editable.count]], "required": ["lines"], "additionalProperties": false]]
    }

    func restore(_ response: String) throws -> String {
        struct Edited: Decodable { let lines: [String] }
        guard let data = response.data(using: .utf8), let edited = try? JSONDecoder().decode(Edited.self, from: data), edited.lines.count == editable.count else {
            throw EditingFailure("The model couldn't preserve the Markdown structure. Please try again.")
        }
        return try lines.map { line in
            guard let index = line.index else { return line.prefix + line.text + line.suffix + line.ending }
            var content = edited.lines[index].trimmingCharacters(in: .whitespaces)
            guard !content.contains("\n"), !content.contains("\r"), !content.isEmpty else { throw EditingFailure("The model changed the Markdown line structure. Please try again.") }
            var remaining = content[...]
            for token in line.tokens {
                guard content.components(separatedBy: token.name).count == 2, let location = remaining.range(of: token.name) else { throw EditingFailure("The model changed Markdown formatting. Please try again.") }
                remaining = remaining[location.upperBound...]
                let pattern = (token.tightLeft ? #"[ \t]*"# : "") + NSRegularExpression.escapedPattern(for: token.name) + (token.tightRight ? #"[ \t]*"# : "")
                let regex = try! NSRegularExpression(pattern: pattern)
                content = regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: NSRegularExpression.escapedTemplate(for: token.value))
            }
            guard !content.contains(tokenPrefix) else { throw EditingFailure("The model returned invalid Markdown formatting. Please try again.") }
            return line.prefix + content + line.suffix + line.ending
        }.joined()
    }
}

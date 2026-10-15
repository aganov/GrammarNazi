import AppKit

enum MarkdownPreview {
    static func render(_ source: String, raw: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 4
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        if raw {
            var attributes = base
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            return NSAttributedString(string: source, attributes: attributes)
        }
        let result = NSMutableAttributedString(string: "")
        var fence: Character?
        for line in source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, (first == "`" || first == "~"), trimmed.prefix(while: { $0 == first }).count >= 3 {
                if fence == nil { fence = first } else if fence == first { fence = nil }
                continue
            }
            let nestedList = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-+*]|[0-9]+[.)])[ \t]+"#).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            if fence != nil || ((line.hasPrefix("    ") || line.hasPrefix("\t")) && !nestedList) {
                var attributes = base
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor
                result.append(NSAttributedString(string: line + "\n", attributes: attributes))
                continue
            }
            var text = line
            var size: CGFloat = 15
            var heading = false
            if let match = try! NSRegularExpression(pattern: #"^[ ]{0,3}(#{1,6})[ \t]+"#).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                size = CGFloat(23 - min(match.range(at: 1).length, 5))
                heading = true
                text = (line as NSString).substring(from: match.range.length)
            } else if let match = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-+*])[ \t]+(?:\[([ xX])\][ \t]+)?"#).firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let indent = (line as NSString).substring(with: match.range(at: 1))
                var bullet = "• "
                if match.range(at: 2).location != NSNotFound {
                    bullet = (line as NSString).substring(with: match.range(at: 2)).lowercased() == "x" ? "☑ " : "☐ "
                }
                text = indent + bullet + (line as NSString).substring(from: match.range.length)
            }
            let inline = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            if let inline {
                for run in inline.runs {
                    var attributes = base
                    var font = NSFont.systemFont(ofSize: size, weight: heading ? .semibold : .regular)
                    if let intent = run.inlinePresentationIntent {
                        if intent.contains(.code) { font = .monospacedSystemFont(ofSize: 13, weight: .regular); attributes[.backgroundColor] = NSColor.quaternaryLabelColor }
                        var traits: NSFontTraitMask = []
                        if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                        if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                        if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
                        if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    }
                    attributes[.font] = font
                    if let link = run.link { attributes[.link] = link }
                    result.append(NSAttributedString(string: String(inline[run.range].characters), attributes: attributes))
                }
                result.append(NSAttributedString(string: "\n", attributes: base))
            } else { result.append(NSAttributedString(string: line + "\n", attributes: base)) }
        }
        return result
    }
}

/// A finite text container and unlimited document height allow TextKit to wrap
/// oversized words/URLs and grow vertically inside its own clipped scroll view.
final class PreviewTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = max(1, newSize.width - textContainerInset.width * 2)
        if let textContainer, abs(textContainer.size.width - width) > 0.5 {
            textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
    }
}

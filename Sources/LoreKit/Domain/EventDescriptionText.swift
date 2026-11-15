import Foundation

/// How an event description is shown: as plain text, cut to a preview, with its web links found.
/// Pure text rules. Nothing here reads the calendar or touches the UI.
public enum EventDescriptionText {
    public struct Preview: Sendable, Equatable {
        public let text: String
        public let isCut: Bool
    }

    public struct Link: Sendable, Equatable {
        public let range: Range<String.Index>
        public let url: URL
    }

    /// Plain text for a description that is plain text or HTML. Text without an HTML tag is returned as it is.
    public static func plainText(from description: String) -> String {
        let source = description.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard containsTag(source) else { return source.trimmingCharacters(in: .whitespacesAndNewlines) }
        var converter = HTMLConverter()
        converter.convert(source)
        return converter.result()
    }

    /// At most `maxLines` lines and `maxCharacters` characters. A cut at the character limit moves back to the
    /// last whitespace so a word or a link is not split, and a cut text ends with "…".
    public static func preview(_ text: String, maxLines: Int, maxCharacters: Int) -> Preview {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var isCut = false
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            isCut = true
        }
        var result = lines.joined(separator: "\n")
        if result.count > maxCharacters {
            var head = String(result.prefix(maxCharacters))
            let nextStartsWord = !result[result.index(result.startIndex, offsetBy: maxCharacters)].isWhitespace
            if nextStartsWord, let space = head.lastIndex(where: \.isWhitespace) { head = String(head[..<space]) }
            result = head
            isCut = true
        }
        guard isCut else { return Preview(text: text, isCut: false) }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return Preview(text: trimmed + "…", isCut: true)
    }

    /// `http` and `https` addresses in the text. Other schemes, such as `file:` or an app's own scheme, are ignored.
    public static func links(in text: String) -> [Link] {
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, let range = Range(match.range, in: text),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return Link(range: range, url: url)
        }
    }

    /// A tag is `<name` followed by whitespace, `/`, or `>`, so `<https://example.com>` is not one.
    private static func containsTag(_ text: String) -> Bool {
        text.range(of: #"</?[A-Za-z][A-Za-z0-9]*(\s[^<>]*)?/?>"#, options: .regularExpression) != nil
    }
}

private struct HTMLConverter {
    private static let lineBreakers: Set<String> = [
        "p", "div", "li", "ul", "ol", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "section", "article", "header", "footer", "hr",
    ]
    private static let blockEnders: Set<String> = ["p", "ul", "ol", "table"]
    private static let hiddenContent: Set<String> = ["script", "style", "head"]
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
        "hellip": "…", "copy": "©", "reg": "®", "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
    ]

    private var output = ""
    /// Open `<a>` tags: the address and where its text starts in `output`.
    private var anchors: [(href: String, textStart: String.Index)] = []
    private var hiddenDepth: [String] = []

    mutating func convert(_ source: String) {
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "<", let tag = Self.tag(in: source, at: index) {
                handle(tag.name, isClosing: tag.isClosing, attributes: tag.attributes)
                index = tag.end
            } else if character == "&", let entity = Self.entity(in: source, at: index) {
                append(entity.text)
                index = entity.end
            } else {
                append(String(character))
                index = source.index(after: index)
            }
        }
        closeOpenAnchors()
    }

    func result() -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.trimmingCharacters(in: .whitespaces)
        }
        var collapsed: [String] = []
        for line in lines {
            if line.isEmpty, collapsed.last?.isEmpty == true { continue }
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func handle(_ name: String, isClosing: Bool, attributes: String) {
        if !hiddenDepth.isEmpty {
            if isClosing, hiddenDepth.last == name { hiddenDepth.removeLast() }
            return
        }
        if !isClosing, Self.hiddenContent.contains(name) {
            hiddenDepth.append(name)
            return
        }
        switch name {
        case "br":
            newline(1)
        case "a":
            if isClosing { closeAnchor() } else { anchors.append((Self.attribute("href", in: attributes) ?? "", output.endIndex)) }
        case "td", "th":
            if isClosing { append(" ") }
        case "li" where !isClosing:
            newline(1)
            output += "• "
        default:
            if Self.lineBreakers.contains(name) { newline(isClosing && Self.blockEnders.contains(name) ? 2 : 1) }
        }
    }

    /// One line break, or a blank line when `count` is 2. Never more than one blank line in a row.
    private mutating func newline(_ count: Int) {
        guard !output.isEmpty else { return }
        let trailing = output.reversed().prefix { $0 == "\n" || $0 == " " }.filter { $0 == "\n" }.count
        output += String(repeating: "\n", count: max(0, count - trailing))
    }

    private mutating func append(_ text: String) {
        if hiddenDepth.isEmpty == false { return }
        for character in text {
            if character == "\n" || character == "\t" || character == " " {
                if output.last != " " && output.last != "\n" && !output.isEmpty { output.append(" ") }
            } else {
                output.append(character)
            }
        }
    }

    private mutating func closeAnchor() {
        guard let anchor = anchors.popLast() else { return }
        let label = output[anchor.textStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !anchor.href.isEmpty, let scheme = URL(string: anchor.href)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https", Self.normalized(label) != Self.normalized(anchor.href) else { return }
        output += label.isEmpty ? anchor.href : " (\(anchor.href))"
    }

    private mutating func closeOpenAnchors() {
        while !anchors.isEmpty { closeAnchor() }
    }

    private static func normalized(_ address: String) -> String {
        var value = address.lowercased()
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func tag(in source: String, at start: String.Index) -> (name: String, isClosing: Bool, attributes: String, end: String.Index)? {
        var index = source.index(after: start)
        guard index < source.endIndex else { return nil }
        if source[index...].hasPrefix("!--") {
            guard let close = source.range(of: "-->", range: index..<source.endIndex) else { return nil }
            return ("!--", false, "", close.upperBound)
        }
        var isClosing = false
        if source[index] == "/" {
            isClosing = true
            index = source.index(after: index)
        }
        guard index < source.endIndex, source[index].isASCII, source[index].isLetter else { return nil }
        var name = ""
        while index < source.endIndex, source[index].isASCII, source[index].isLetter || source[index].isNumber {
            name.append(source[index])
            index = source.index(after: index)
        }
        guard index < source.endIndex, source[index] == ">" || source[index] == "/" || source[index].isWhitespace else { return nil }
        guard let close = source[index...].firstIndex(of: ">") else { return nil }
        return (name.lowercased(), isClosing, String(source[index..<close]), source.index(after: close))
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = "\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: attributes) { return decode(String(attributes[range])) }
        }
        return nil
    }

    private static func decode(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let entity = entity(in: text, at: index) {
                result += entity.text
                index = entity.end
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func entity(in source: String, at start: String.Index) -> (text: String, end: String.Index)? {
        guard let semicolon = source[start...].prefix(12).firstIndex(of: ";") else { return nil }
        let body = source[source.index(after: start)..<semicolon]
        let end = source.index(after: semicolon)
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return (String(Character(scalar)), end)
        }
        guard let text = namedEntities[String(body)] else { return nil }
        return (text, end)
    }
}

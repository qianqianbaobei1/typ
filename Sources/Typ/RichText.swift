import AppKit

/// Converts the small Markdown subset the LLM is allowed to use into HTML / RTF / plain text.
enum RichText {
    private enum Block {
        case heading(Int, String)
        case bullet(String)
        case numbered(String)
        case line(String)
        case blank
    }

    private static func parse(_ md: String) -> [Block] {
        md.components(separatedBy: "\n").map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return .blank }
            if let m = line.range(of: #"^#{1,4}\s+"#, options: .regularExpression) {
                let level = line[m].filter { $0 == "#" }.count
                return .heading(level, String(line[m.upperBound...]))
            }
            if let m = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) { return .bullet(String(line[m.upperBound...])) }
            if let m = line.range(of: #"^\d+[.)、]\s*"#, options: .regularExpression) { return .numbered(String(line[m.upperBound...])) }
            return .line(line)
        }
    }

    /// True when the text uses Markdown that would look wrong pasted as plain text.
    static func hasMarkup(_ s: String) -> Bool {
        s.range(of: #"\*\*[^*\n]+\*\*|(?m)^#{1,4}\s|(?m)^[-*]\s|\[[^\]]+\]\([^)]+\)"#, options: .regularExpression) != nil
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inlineHTML(_ s: String) -> String {
        var t = escape(s)
        t = t.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#, with: "<i>$1</i>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        return t
    }

    private static func inlinePlain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)\s]+)\)"#, with: "$1 ($2)", options: .regularExpression)
        return t
    }

    static func html(_ md: String) -> String {
        var out = ""
        var list: String?
        var para: [String] = []
        func flushPara() {
            if !para.isEmpty { out += "<p>" + para.joined(separator: "<br>") + "</p>"; para.removeAll() }
        }
        func closeList() {
            if let l = list { out += "</\(l)>"; list = nil }
        }
        for block in parse(md) {
            switch block {
            case .heading(let level, let text):
                flushPara(); closeList()
                out += "<h\(level)>\(inlineHTML(text))</h\(level)>"
            case .bullet(let text), .numbered(let text):
                flushPara()
                let tag: String
                if case .bullet = block { tag = "ul" } else { tag = "ol" }
                if list != tag { closeList(); out += "<\(tag)>"; list = tag }
                out += "<li>\(inlineHTML(text))</li>"
            case .line(let text):
                closeList()
                para.append(inlineHTML(text))
            case .blank:
                flushPara(); closeList()
            }
        }
        flushPara(); closeList()
        return "<meta charset=\"utf-8\"><div style=\"font-family: -apple-system, 'PingFang SC', sans-serif;\">\(out)</div>"
    }

    static func plain(_ md: String) -> String {
        var n = 0
        return parse(md).map { block -> String in
            switch block {
            case .heading(_, let t): n = 0; return inlinePlain(t)
            case .bullet(let t): n = 0; return "• " + inlinePlain(t)
            case .numbered(let t): n += 1; return "\(n). " + inlinePlain(t)
            case .line(let t): n = 0; return inlinePlain(t)
            case .blank: n = 0; return ""
            }
        }.joined(separator: "\n")
    }

    @MainActor
    static func rtf(fromHTML html: String) -> Data? {
        guard let data = html.data(using: .utf8),
              let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                       .characterEncoding: String.Encoding.utf8.rawValue],
                                                 documentAttributes: nil) else { return nil }
        return try? attr.data(from: NSRange(location: 0, length: attr.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
}

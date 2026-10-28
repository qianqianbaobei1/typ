import AppKit

/// Actions "Ask anything" can take outside the current text field.
/// Everything only opens or pre-fills — nothing is sent or posted automatically.
enum Actions {
    /// Web templates the model fills with parameters; Typ does the URL encoding.
    static let templates: [String: (desc: String, build: ([String: String]) -> String)] = [
        "web_search": ("Google search. params: query", { "https://www.google.com/search?q=\(enc($0["query"]))" }),
        "baidu_search": ("Baidu search (for Chinese queries if the user asks for Baidu). params: query", { "https://www.baidu.com/s?wd=\(enc($0["query"]))" }),
        "maps": ("Google Maps place/route search. params: query", { "https://www.google.com/maps/search/\(enc($0["query"]))" }),
        "youtube_search": ("YouTube search. params: query", { "https://www.youtube.com/results?search_query=\(enc($0["query"]))" }),
        "bilibili_search": ("Bilibili search. params: query", { "https://search.bilibili.com/all?keyword=\(enc($0["query"]))" }),
        "x_post": ("Draft a post on X/Twitter. params: text", { "https://x.com/intent/post?text=\(enc($0["text"]))" }),
        "weibo_post": ("Draft a Weibo post. params: text", { "https://service.weibo.com/share/share.php?title=\(enc($0["text"]))" }),
        "reddit_post": ("Draft a Reddit post. params: title, text, subreddit (optional)", { p in
            let sub = (p["subreddit"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "r/ "))
            return "https://www.reddit.com/\(sub.isEmpty ? "" : "r/\(sub)/")submit?title=\(enc(p["title"]))&text=\(enc(p["text"]))"
        }),
        "gmail_compose": ("Draft an email in Gmail. params: to, subject, body", { p in
            "https://mail.google.com/mail/?view=cm&fs=1&to=\(enc(p["to"]))&su=\(enc(p["subject"]))&body=\(enc(p["body"]))"
        }),
        "mail_compose": ("Draft an email in the default Mail app. params: to, subject, body", { p in
            "mailto:\(enc(p["to"]))?subject=\(enc(p["subject"]))&body=\(enc(p["body"]))"
        }),
        "new_google_doc": ("Create a new Google Doc. params: none", { _ in "https://docs.new" }),
        "translate_page": ("Google Translate a text. params: text, target (language code)", { p in
            "https://translate.google.com/?sl=auto&tl=\(enc(p["target"] ?? "en"))&text=\(enc(p["text"]))&op=translate"
        }),
    ]

    static var templateList: String {
        templates.keys.sorted().map { "- \($0): \(templates[$0]!.desc)" }.joined(separator: "\n")
    }

    private static func enc(_ s: String?) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return (s ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Opens a template or a plain URL. Returns a short label of what was opened.
    @MainActor
    static func open(template: String?, params: [String: String], url: String?) -> String? {
        var target: URL?
        if let template, let t = templates[template] {
            target = URL(string: t.build(params))
        } else if let url, let u = URL(string: url.trimmingCharacters(in: .whitespaces)) {
            target = u
        }
        guard let target, let scheme = target.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        NSWorkspace.shared.open(target)
        return target.host ?? (scheme == "mailto" ? "邮件" : target.absoluteString)
    }

    /// Launches an installed app by (localized) name. Returns the matched app name.
    @MainActor
    static func launch(app name: String) -> String? {
        let query = name.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var best: (url: URL, name: String, score: Int)?
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = dir + "/" + item
                let file = String(item.dropLast(4))
                let display = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                for candidate in [display, file] {
                    let c = candidate.lowercased()
                    let score = c == query ? 3 : c.hasPrefix(query) ? 2 : c.contains(query) || query.contains(c) && c.count >= 2 ? 1 : 0
                    if score > (best?.score ?? 0) { best = (URL(fileURLWithPath: path), display, score) }
                }
            }
        }
        guard let best else { return nil }
        NSWorkspace.shared.openApplication(at: best.url, configuration: NSWorkspace.OpenConfiguration())
        return best.name
    }
}

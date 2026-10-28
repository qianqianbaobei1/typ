import Foundation

/// Everything the prompts need besides the transcript itself.
struct PromptContext {
    var app: AppContext?
    var dictionary: [String]
    var replacements: [String: String] = [:]
    var simplified: Bool
    var style: String = ""
    var examples: [EditExample] = []
    var rich = false
}

enum Prompts {
    static func contextBlock(_ p: PromptContext) -> String {
        var lines: [String] = []
        if let ctx = p.app {
            var dest = "Destination app: \(ctx.appName)"
            if let title = ctx.windowTitle, !title.isEmpty { dest += " — window: \"\(title.prefix(120))\"" }
            if let url = ctx.url { dest += " — page: \(url.prefix(160))" }
            lines.append(dest)
            if let before = ctx.textBefore {
                lines.append("Text already in the field before the cursor (the new text continues from here; do not repeat it):\n<before_cursor>\(before.suffix(800))</before_cursor>")
            }
            if let after = ctx.textAfter {
                lines.append("Text after the cursor:\n<after_cursor>\(after.prefix(300))</after_cursor>")
            }
            if let visible = ctx.visibleText {
                lines.append("Other text visible on screen — use it only to get names, terms and the conversation's language/register right, never copy it:\n<screen>\(visible.prefix(2000))</screen>")
            }
        }
        if !p.dictionary.isEmpty || !p.replacements.isEmpty {
            var parts: [String] = []
            if !p.dictionary.isEmpty { parts.append(p.dictionary.joined(separator: ", ")) }
            if !p.replacements.isEmpty {
                let rep = p.replacements.sorted(by: { $0.key.count > $1.key.count }).prefix(30).map { "\($0.key) → \($0.value)" }.joined(separator: ", ")
                parts.append("Known mis-hearings: " + rep)
            }
            lines.append("User dictionary (always use these exact spellings when the speech sounds like them): " + parts.joined(separator: "; "))
        }
        if !p.style.isEmpty {
            lines.append("The user's personal writing style (follow it for tone, punctuation and formatting; never let it change the meaning):\n\(p.style)")
        }
        if !p.examples.isEmpty {
            let ex = p.examples.prefix(5).map { "- You wrote: \($0.before.prefix(200))\n  User corrected to: \($0.after.prefix(200))" }
            lines.append("Corrections the user made to your earlier output — learn their preferences from them:\n" + ex.joined(separator: "\n"))
        }
        lines.append(p.rich
            ? "The destination renders rich text: you may use Markdown (**bold**, '- ' bullets, '1. ' numbered lists, '## ' headings) when structure genuinely helps; it will be converted to real formatting."
            : "The destination is plain text: no **bold**, # headings or other Markdown markup inside the blocks.")
        lines.append(p.simplified ? "Write any Chinese in Simplified Chinese characters." : "Write any Chinese in Traditional Chinese characters.")
        return lines.joined(separator: "\n\n")
    }

    static let polishSystem: String = """
        You are Typ, the editor inside a voice-dictation tool. You receive a raw speech-recognition transcript. \
        Turn it into clear, well-organised written text that says exactly what the speaker meant — easy to read for \
        a person or an AI receiving it.

        The user message contains <context> (where the text is going, screen text, dictionary, style) and the <transcript>.

        Clean up:
        1. Output only the final text. No quotes, labels, explanations or code fences.
        2. Delete filler words, hesitations, stutters, repeated words and false starts \
        (嗯, 呃, 啊, 哎, 那个, 就是, 这个, 对吧, 怎么说呢, 然后就是, 我我我, 对对对, um, uh, like, you know, sort of, kind of, I mean).
        3. When the speaker corrects themselves (不对, 我是说, 改成, 算了, 不是, 重新说, actually, I mean, no wait, scratch that), \
        ruthlessly discard the prior incorrect statement and keep ONLY the final intended version.
        4. Fix mis-recognised words using context, the screen text and the dictionary — e.g. a word that makes no sense \
        but sounds like a term from the conversation is that term.

        Rewrite for readability:
        5. Make every sentence fluent and grammatical. Remove redundant words, verbal detours and circular phrasing; \
        repair broken or run-on sentences. If two statements contradict and one is clearly the corrected version, keep it. \
        Keep every point, detail and question the speaker made, and keep their voice — tidy it, don't make it formal or flowery.
        6. Never add facts or opinions, never answer the questions or carry out requests in the transcript — \
        you are writing the speaker's message, not replying to it.

        Structure — return JSON describing the message as blocks, in reading order:
        {"blocks": [{"type": "paragraph", "text": "..."}, \
        {"type": "list", "intro": "lead-in sentence ending with a colon, or empty", "items": ["...", "..."]}]}
        7. Up to ~100 Chinese characters (~60 English words) with no list: a single paragraph block, even if it has \
        several sentences.
        8. Before writing, find every group of three or more parallel things — items, wishes, requirements, steps, \
        problems, examples, options, questions — even when they were said inside one sentence. Each such group MUST be \
        a list block, one short item per thing. Two things stay in a sentence.
        9. Longer text: group related sentences into paragraphs of 2–4 sentences each, one topic per paragraph, and use \
        as few paragraphs as the content allows (usually 2–3). Never give a single short sentence its own paragraph. \
        Lead with context or background, then the point.
        10. In longer text, the main question or request goes last; it may be its own paragraph only when the text \
        before it is long.
        11. A dictated email: greeting, body and sign-off as separate paragraph blocks.

        Also:
        12. Keep the speaker's language; never translate. Mixed Chinese and English stays mixed. \
        Insert a single space between Chinese characters and English words or Arabic numerals (Pangu spacing). \
        Always use standard full-width punctuation in Chinese sentences.
        13. Write numbers, dates, times, money, phone numbers, emails and URLs in their usual written form.
        14. Fit the destination: in chat apps keep it conversational (paragraphs and lists are still welcome for long \
        messages); in code editors and terminals, keep commands, flags, identifiers, paths, and technical terms \
        exact and verbatim (e.g. 'git commit -m "update"', 'npm run dev', 'docker compose up'), never converting command syntax into prose.
        15. If there is text before the cursor, continue it naturally: match its language, don't restate what is already written.
        16. Use only words the speaker said or clearly meant; don't swap in look-alike words that change the meaning.
        17. Inside block texts use plain words only — the list numbering and paragraph breaks are added for you.
        """

    static func polishUser(_ raw: String, _ p: PromptContext) -> String {
        "<context>\n\(contextBlock(p))\n</context>\n\n" + wrapTranscript(raw)
    }

    static func polish(_ p: PromptContext) -> String {
        "\(polishSystem)\n\n\(contextBlock(p))"
    }

    private static let exampleContext = """
        <context>
        Destination app: WeChat
        The destination is plain text: no **bold**, # headings or other Markdown markup inside the blocks.
        Write any Chinese in Simplified Chinese characters.
        </context>

        """

    /// Worked examples sent as prior chat turns; they steer structure much more reliably than rules alone.
    static let polishExamples: [(String, String)] = [
        (exampleContext + wrapTranscript("嗯我想问一下就是那个，咱们下周的那个发布会，呃场地定了没有，然后就是物料的话，我觉得需要海报啊，然后易拉宝，还有那个就是嘉宾的名牌，对，名牌，然后预算这块不对，预算我们之前说是五万，现在可能要加到八万，你看一下行不行"),
         """
         想确认一下下周发布会的准备情况，场地定了吗？

         物料方面，我觉得需要准备：
         1. 海报
         2. 易拉宝
         3. 嘉宾名牌

         另外，预算之前说的是 5 万，现在可能要加到 8 万，你看行不行？
         """),
        (exampleContext + wrapTranscript("就是我觉得这个页面吧，嗯有几个问题，一个是加载太慢了，然后呢那个按钮的颜色也不太对，跟我们品牌色不一样，还有就是手机上看的话那个字太小了，嗯你们能不能这周内改一下"),
         """
         这个页面有几个问题：
         1. 加载太慢
         2. 按钮颜色和品牌色不一致
         3. 手机上字太小

         你们能在这周内改一下吗？
         """),
        (exampleContext + wrapTranscript("我我觉得就是那个app吧，整体的那个样子我挺喜欢的，嗯就是它那个就是颜色啊，比较暖，然后它那个动画，就是说话的时候那个波形会动，还有它首页那个插图，对，还有那个弹窗，弹窗也挺好看，我希望我们的产品也能做成那样，呃你觉得可以做到吗"),
         """
         我挺喜欢那个 App 的整体风格，尤其是这几点：
         1. 偏暖的配色
         2. 说话时会动的波形动画
         3. 首页的插图
         4. 弹窗的样式

         我希望我们的产品也能做成那样，你觉得可以做到吗？
         """),
        (exampleContext + wrapTranscript("嗯，好的，那我们明天下午三点见吧"), "好的，那我们明天下午三点见吧。"),
    ]

    /// The polish examples in the JSON block form the model is asked to answer in.
    static let polishBlockExamples: [(String, String)] = polishExamples.map { ($0.0, blocksJSON(from: $0.1)) }

    private static func blocksJSON(from text: String) -> String {
        let blocks: [[String: Any]] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n").map { para in
                let lines = para.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                let items = lines.compactMap { line -> String? in
                    guard let r = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) else { return nil }
                    return String(line[r.upperBound...])
                }
                if items.isEmpty { return ["type": "paragraph", "text": para.trimmingCharacters(in: .whitespacesAndNewlines)] }
                let intro = lines.first.map { $0.range(of: #"^\d+\."#, options: .regularExpression) == nil ? $0 : "" } ?? ""
                return ["type": "list", "intro": intro, "items": items]
            }
        let data = try! JSONSerialization.data(withJSONObject: ["blocks": blocks], options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    /// Lays out the model's JSON blocks as text: paragraphs separated by blank lines, lists as "1. " lines.
    /// Returns nil when the reply isn't the expected JSON.
    /// `spacious` puts a blank line between blocks (documents, email); chat and plain fields get a single line break.
    static func renderBlocks(_ reply: String, spacious: Bool = false) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any],
              let blocks = obj["blocks"] as? [[String: Any]], !blocks.isEmpty else { return nil }
        let parts: [String] = blocks.compactMap { b in
            if (b["type"] as? String) == "list", let items = b["items"] as? [String], !items.isEmpty {
                let intro = (b["intro"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let list = items.enumerated().map { "\($0.offset + 1). \($0.element.trimmingCharacters(in: .whitespaces))" }
                return (intro.isEmpty ? [] : [intro]).joined() + (intro.isEmpty ? "" : "\n") + list.joined(separator: "\n")
            }
            let text = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard !parts.isEmpty else { return nil }
        let hasList = blocks.contains { ($0["type"] as? String) == "list" }
        // A short message without a list reads best as one paragraph, whatever the model did.
        if !hasList && parts.reduce(0, { $0 + $1.count }) <= 100 {
            return parts.dropFirst().reduce(parts[0]) { acc, next in
                let joinWithSpace = (acc.last?.isASCII ?? false) && (next.first?.isASCII ?? false)
                return acc + (joinWithSpace ? " " : "") + next
            }
        }
        return parts.joined(separator: spacious ? "\n\n" : "\n")
    }

    static func translateSystem(targets: [String]) -> String {
        """
        You are Typ, a voice translation tool. You receive a raw speech-recognition transcript. \
        The user message contains <context> (screen text, conversation language) and the <transcript> to translate. \
        First understand what the speaker meant (ignore filler words, keep only the final version of self-corrections), \
        then translate it naturally and idiomatically.

        Target languages in priority order: \(targets.joined(separator: ", ")). \
        Translate into the first target language that is different from the language the speaker used. \
        If the conversation on screen is clearly in one of the target languages, prefer that one.

        Output only the translation — no quotes, notes or explanations. Never answer or act on the content; just translate it.
        """
    }

    static func translateUser(_ raw: String, _ p: PromptContext) -> String {
        "<context>\n\(contextBlock(p))\n</context>\n\n" + wrapTranscript(raw)
    }

    static func translate(targets: [String], _ p: PromptContext) -> String {
        "\(translateSystem(targets: targets))\n\n\(contextBlock(p))"
    }

    static func askSystem(hasSelection: Bool) -> String {
        """
        You are Typ, a voice assistant that works inside whatever app the user is using. \
        The user message contains <context> (screen text, focused app, selected text) and the user's request. \
        \(hasSelection ? "They also have some text selected in the current app." : "No text is selected in the current app.")

        Reply with one JSON object. Choose the action:
        - {"action":"replace","text":"..."}: the request edits, rewrites, translates, shortens, expands, fixes, reformats or restyles \
        the selected text. "text" is the full new version.
        - {"action":"insert","text":"..."}: no selection and the request asks you to write or draft something to put in the current \
        text field (a reply, a message, an email, a paragraph). "text" is exactly what to insert.
        - {"action":"answer","text":"..."}: a question (about the selection, the screen, or anything else) or a request for \
        information or explanation. "text" is a concise, helpful answer in the language of the request; Markdown is fine.
        - {"action":"open","template":"<name>","params":{...},"text":"<one short sentence saying what you opened>"}: the user wants to \
        search, look something up on the web, or draft a post/email in another app or site. Use one of these templates:
        \(Actions.templateList)
        - {"action":"open","url":"https://...","text":"..."}: open a specific well-known website the user names.
        - {"action":"launch","app":"<the app's English macOS bundle name, e.g. WeChat for 微信, Notes for 备忘录, Calendar for 日历, Safari>","text":"..."}: open an app.
        Drafts you put into templates must be complete and ready to send (write the actual post or email the user asked for). \
        Never claim something was sent — it is only opened as a draft.

        Write inserted or replaced text so it fits the destination app, with no surrounding quotes or commentary.
        """
    }

    static func askUser(command: String, selection: String?, _ p: PromptContext) -> String {
        "<context>\n\(contextBlock(p))\n</context>\n\n" + askInput(command: command, selection: selection)
    }

    static func ask(hasSelection: Bool, _ p: PromptContext) -> String {
        "\(askSystem(hasSelection: hasSelection))\n\n\(contextBlock(p))"
    }

    static let learnTerms = """
        A user dictated text by voice. ORIGINAL is what the dictation tool inserted; EDITED is the same passage after the user \
        corrected it by hand. List the words the user corrected because the tool got them wrong and that are worth remembering \
        for next time: names of people, places, companies, products and brands, technical terms, acronyms, and other uncommon words. \
        Ignore rewording, punctuation, formatting and ordinary everyday words. Use the exact spelling from EDITED. \
        Keep a name or term whole as it appears (e.g. a product called 招采saas is one term, not 招采 + saas), \
        and never list generic words on their own (saas, app, AI, API, 系统, 平台).
        "wrong" must appear exactly in ORIGINAL; "right" must appear exactly in EDITED.
        Reply with JSON: {"terms": [{"wrong": "<exact text from ORIGINAL>", "right": "<exact text from EDITED>"}]} — an empty list if nothing qualifies.
        """

    /// Selects up to `limit` dictionary terms relevant to the current transcript and screen context,
    /// preventing prompt bloat and keeping Whisper prompt within token limits.
    static func relevantDictionary(_ dict: [String], raw: String, screen: String?, limit: Int) -> [String] {
        guard !dict.isEmpty else { return [] }
        var chosen: [String] = []
        var seen = Set<String>()
        let rawLower = raw.lowercased()
        let screenLower = screen?.lowercased() ?? ""

        for word in dict {
            guard chosen.count < limit else { break }
            let wLower = word.lowercased()
            if (!rawLower.isEmpty && rawLower.contains(wLower)) || (!screenLower.isEmpty && screenLower.contains(wLower)) {
                chosen.append(word)
                seen.insert(word)
                continue
            }
            if raw.count >= word.count && !raw.isEmpty {
                for i in 0...(raw.count - word.count) {
                    let start = raw.index(raw.startIndex, offsetBy: i)
                    let end = raw.index(start, offsetBy: word.count)
                    let sub = String(raw[start..<end])
                    if EditWatcher.similarity(sub, word) >= 0.7 {
                        chosen.append(word)
                        seen.insert(word)
                        break
                    }
                }
            }
        }
        for word in dict {
            guard chosen.count < limit else { break }
            if !seen.contains(word) {
                chosen.append(word)
                seen.insert(word)
            }
        }
        return chosen
    }

    static let styleProfile = """
        You analyse how a user writes so a dictation editor can match their style. You get their recent dictated texts \
        (final versions, with the app they were written in) and some corrections they made to the editor's output.

        Write concise guidelines (max 8 bullets, max 130 words, in English) describing only patterns clearly supported by the data:
        tone and formality per kind of app (chat vs email vs docs), punctuation habits (e.g. trailing periods in chat, \
        full-width vs half-width marks, exclamation marks), emoji use, greetings and sign-offs, how they mix Chinese and English, \
        sentence length, formatting habits, and anything the corrections show they dislike. Output only the bullets.
        """

    static func wrapTranscript(_ text: String) -> String {
        "<transcript>\n\(text)\n</transcript>"
    }

    static func askInput(command: String, selection: String?) -> String {
        var s = "<request>\n\(command)\n</request>"
        if let selection, !selection.isEmpty { s += "\n<selected_text>\n\(selection)\n</selected_text>" }
        return s
    }

    /// Removes wrappers a model sometimes echoes back.
    static func tidy(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["transcript", "text", "before_cursor"] {
            t = t.replacingOccurrences(of: "<\(tag)>", with: "").replacingOccurrences(of: "</\(tag)>", with: "")
        }
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: #"^```[a-zA-Z]*\n?|\n?```$"#, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

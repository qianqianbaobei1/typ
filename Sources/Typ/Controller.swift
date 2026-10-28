import AppKit

/// Turns hotkey presses into dictation sessions:
/// hold the key to talk and release to insert, or tap it once for hands-free and tap again to finish.
@MainActor
final class Controller {
    let settings = Settings.shared
    let history: HistoryStore
    let whisper: WhisperEngine
    let bar = FloatingBar()
    let answers = AnswerPanel()
    private let recorder = AudioRecorder()
    let hotkeys = HotkeyMonitor()
    let style: StyleProfile
    private let editWatcher = EditWatcher()

    private enum State { case idle, recording, processing }
    private var state = State.idle
    private var mode = Mode.dictate
    private var pressStart = Date()
    private var pressActive = false
    private var handsFree = false
    private var ignoreUntilReleased = false
    private var sessionID = UUID()
    private var context: AppContext?
    private var contextTask: Task<AppContext, Never>?
    private var selectionTask: Task<String?, Never>?
    private var streamer: StreamingTranscriber?
    private var mutedByUs = false

    /// Taps shorter than this switch to hands-free mode.
    private let tapThreshold: TimeInterval = 0.35
    /// While a chord is forming (fn, then Shift), the mode may still change.
    private let chordWindow: TimeInterval = 0.6

    init(history: HistoryStore, whisper: WhisperEngine, style: StyleProfile) {
        self.history = history
        self.whisper = whisper
        self.style = style
        history.prune(retentionDays: settings.historyRetentionDays)
        editWatcher.onCorrection = { [weak self] inserted, edited in self?.learn(inserted: inserted, edited: edited) }
        hotkeys.interceptKeyDown = { [weak self] code, flags in
            MainActor.assumeIsolated {
                guard let self, self.state == .idle, self.settings.autoLearn || self.settings.personalization else { return false }
                return self.editWatcher.intercept(code, flags)
            }
        }
        hotkeys.onPressedChange = { [weak self] p in MainActor.assumeIsolated { self?.pressedChanged(p) } }
        hotkeys.onKeyDown = { [weak self] code in MainActor.assumeIsolated { self?.keyDown(code) } }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.bar.model.push(level: level) } }
        }
        bar.model.onStop = { [weak self] in self?.finish() }
        bar.model.onCancel = { [weak self] in self?.cancel(silent: false) }
    }

    // MARK: - Hotkey state machine

    private func pressedChanged(_ pressed: Set<Int64>) {
        if ignoreUntilReleased {
            if pressed.isEmpty { ignoreUntilReleased = false }
            return
        }
        let matched = settings.mode(matching: pressed)
        if matched != nil || state != .idle { Log.write("keys \(pressed.sorted()) -> \(matched?.rawValue ?? "none") state=\(state)") }
        switch state {
        case .idle:
            if let m = matched { begin(m) }
        case .recording:
            if pressActive {
                let held = Date().timeIntervalSince(pressStart)
                if pressed.isEmpty {
                    pressActive = false
                    if held < tapThreshold {
                        handsFree = true
                        bar.model.handsFree = true
                        bar.refresh()
                    } else {
                        finish()
                    }
                } else if let m = matched, m != mode, held < chordWindow {
                    switchMode(to: m)
                }
            } else if matched != nil {
                // Hands-free: pressing any Typ hotkey again finishes.
                ignoreUntilReleased = true
                finish()
            }
        case .processing:
            if matched != nil { ignoreUntilReleased = true }
        }
    }

    private func keyDown(_ code: Int64) {
        guard state == .recording else { return }
        if code == 53 { // Esc
            cancel(silent: false)
        } else if pressActive && !handsFree {
            // The modifier was part of a normal shortcut (fn+←, ⌥+key …), not a dictation.
            cancel(silent: true)
        }
    }

    // MARK: - Session

    private func begin(_ m: Mode) {
        Log.write("begin \(m.rawValue): engine=\(whisper.status.label) ax=\(Permissions.accessibility)")
        guard whisper.status == .ready else {
            ignoreUntilReleased = true
            bar.flash(whisper.status == .starting ? "语音模型加载中，请稍候…" : "语音引擎未就绪：\(whisper.status.label)", isError: true)
            return
        }
        if m != .dictate && !settings.hasAPIKey {
            ignoreUntilReleased = true
            bar.flash("\(m.title)需要 DeepSeek API Key，请在设置中填写", isError: true)
            return
        }
        answers.close()
        editWatcher.check()
        let basic = ContextReader.basic()
        context = basic
        let deep = settings.deepContext
        let privacy = settings.privacyProtection
        let bottomUpWeb = settings.bottomUpWebContext
        contextTask = Task.detached(priority: .userInitiated) {
            ContextReader.enrich(basic, deep: deep, privacy: privacy, bottomUpWeb: bottomUpWeb)
        }
        do {
            try recorder.start(deviceUID: settings.micUID)
        } catch {
            Log.write("recorder failed: \(error.localizedDescription)")
            ignoreUntilReleased = true
            bar.flash(error.localizedDescription, isError: true)
            return
        }
        let lang = settings.speechLanguage
        let kind = whisper.kind
        let s = StreamingTranscriber(recorder: recorder, basePrompt: kind == .whisper ? whisperPrompt : "") { wav, prompt in
            try await WhisperEngine.transcribe(kind: kind, wav: wav, language: lang, prompt: prompt)
        }
        s.start()
        streamer = s
        if settings.hasAPIKey { Self.prewarm(settings.apiBaseURL) }
        state = .recording
        mode = m
        pressActive = true
        handsFree = false
        pressStart = Date()
        let id = UUID()
        sessionID = id
        if m == .ask { selectionTask = Task { await TextInserter.selectedText() } }

        // Show UI a beat later so modifier+key shortcuts don't flash the bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.sessionID == id, self.state == .recording else { return }
                self.bar.model.handsFree = self.handsFree
                self.bar.showRecording(mode: self.mode)
                if self.settings.sounds { Sounds.start() }
                if self.settings.muteWhileDictating {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        MainActor.assumeIsolated {
                            guard self.sessionID == id, self.state == .recording, !SystemAudio.isMuted() else { return }
                            SystemAudio.setMuted(true)
                            self.mutedByUs = true
                        }
                    }
                }
            }
        }
    }

    private func switchMode(to m: Mode) {
        if m != .dictate && !settings.hasAPIKey { return }
        mode = m
        bar.model.mode = m
        if m == .ask && selectionTask == nil { selectionTask = Task { await TextInserter.selectedText() } }
    }

    private func restoreAudio() {
        if mutedByUs {
            SystemAudio.setMuted(false)
            mutedByUs = false
        }
    }

    func cancel(silent: Bool) {
        guard state == .recording else { return }
        Log.write("cancel silent=\(silent)")
        _ = recorder.stop()
        streamer?.cancel()
        streamer = nil
        state = .idle
        sessionID = UUID()
        ignoreUntilReleased = pressActive
        selectionTask?.cancel()
        selectionTask = nil
        restoreAudio()
        if silent { bar.hide() } else { bar.flash("已取消") }
    }

    func finish() {
        guard state == .recording else { return }
        let samples = recorder.stop()
        state = .processing
        sessionID = UUID()
        restoreAudio()
        if settings.sounds { Sounds.stop() }
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        Log.write(String(format: "finish: %.1fs audio, rms %.4f", duration, AudioRecorder.rms(samples)))
        let stream = streamer
        streamer = nil
        guard duration >= 0.3, AudioRecorder.rms(samples) > 0.002 else {
            stream?.cancel()
            state = .idle
            bar.flash("没有听到声音，请检查麦克风")
            return
        }
        bar.showProcessing()
        let mode = self.mode, basic = context, ctxTask = contextTask, selection = selectionTask
        selectionTask = nil
        contextTask = nil
        let released = Date()
        Task {
            await process(samples: samples, duration: duration, mode: mode, basic: basic, ctxTask: ctxTask,
                          stream: stream, selection: selection, released: released)
            state = .idle
        }
    }

    private var llm: LLMClient? {
        settings.hasAPIKey ? LLMClient(baseURL: settings.apiBaseURL, apiKey: settings.apiKey, model: settings.apiModel) : nil
    }

    private var whisperPrompt: String {
        var parts: [String] = []
        if settings.speechLanguage == "zh" || settings.speechLanguage == "auto" {
            parts.append(settings.simplifiedChinese ? "以下是普通话的句子，使用简体中文和标点。" : "以下是普通話的句子，使用繁體中文和標點。")
        }
        if !settings.dictionary.isEmpty { parts.append(settings.dictionary.joined(separator: ", ")) }
        return parts.joined(separator: " ")
    }

    private static func looksJapaneseOrKorean(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }

    /// Whisper emits ASCII punctuation after Chinese text; switch it to full-width there.
    static func fullWidthPunctuation(_ s: String) -> String {
        let map: [Character: Character] = [",": "，", "?": "？", "!": "！", ":": "：", ";": "；"]
        let chars = Array(s)
        var out = ""
        for (i, c) in chars.enumerated() {
            if let w = map[c], i > 0, chars[i - 1].unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
                out.append(w)
            } else {
                out.append(c)
            }
        }
        return out
    }


    private func promptContext(_ ctx: AppContext?, rich: Bool) -> PromptContext {
        PromptContext(
            app: ctx, dictionary: settings.dictionary, simplified: settings.simplifiedChinese,
            style: settings.personalization ? style.profile : "",
            examples: settings.personalization ? style.examples : [],
            rich: rich)
    }

    private func useRich(_ ctx: AppContext?) -> Bool { settings.richText && (ctx?.acceptsRichText ?? false) }

    /// Pastes the result, as rich text where supported, and starts watching for the user's corrections.
    private func insert(_ text: String, ctx: AppContext?) async -> String {
        var plain = text
        var html: String?
        if RichText.hasMarkup(text) {
            plain = RichText.plain(text)
            if useRich(ctx) { html = RichText.html(text) }
        }
        // Keep English words apart when continuing a sentence.
        if let last = ctx?.textBefore?.last, !last.isWhitespace, let first = plain.first,
           first.isASCII && (first.isLetter || first.isNumber),
           last.isASCII && (last.isLetter || last.isNumber || ".,!?;:".contains(last)) {
            plain = " " + plain
        }
        await TextInserter.insert(plain: plain, html: html, context: ctx, preserveClipboard: settings.preserveClipboard)
        if settings.autoLearn || settings.personalization {
            editWatcher.copyBeforeSend = settings.copyBeforeSend
            editWatcher.watch(element: ctx?.isPrivate == true ? nil : ctx?.element,
                              pid: ctx?.pid ?? 0,
                              inserted: plain.trimmingCharacters(in: .whitespaces),
                              app: ctx?.appName ?? "?",
                              allowRead: ctx?.isPrivate != true)
        }
        return plain
    }

    private static func cleanJoined(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Opens the HTTPS connection to the LLM while the user is still talking.
    private static func prewarm(_ base: String) {
        guard let url = URL(string: base) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        Task.detached { _ = try? await URLSession.shared.data(for: req) }
    }

    /// The task's value if it is ready within `seconds`, otherwise `fallback`.
    private static func value<T: Sendable>(of task: Task<T, Never>?, within seconds: Double, fallback: T) async -> T {
        guard let task else { return fallback }
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? fallback
        }
    }

    private func process(samples: [Float], duration: Double, mode: Mode, basic: AppContext?, ctxTask: Task<AppContext, Never>?,
                         stream: StreamingTranscriber?, selection: Task<String?, Never>?, released: Date) async {
        var raw = ""
        var ctx = basic
        var marks: [String] = []
        var lap = released
        func mark(_ label: String) {
            marks.append(String(format: "%@ %.1fs", label, Date().timeIntervalSince(lap)))
            lap = Date()
        }
        do {
            if let stream {
                raw = Self.cleanJoined(try await stream.finish(all: samples))
            } else {
                raw = try await WhisperEngine.transcribe(kind: whisper.kind, wav: AudioRecorder.wav(samples),
                                                         language: settings.speechLanguage, prompt: whisperPrompt)
            }
            mark(stream.map { $0.segments > 1 ? "识别(分\($0.segments)段)" : "识别" } ?? "识别")
            if let basic { ctx = await Self.value(of: ctxTask, within: 0.15, fallback: basic) }
            if settings.simplifiedChinese, !Self.looksJapaneseOrKorean(raw),
               let s = raw.applyingTransform(StringTransform("Hant-Hans"), reverse: false) {
                raw = s
            }
            raw = Self.fullWidthPunctuation(raw)
            guard !raw.isEmpty else {
                bar.flash("没有识别到内容")
                return
            }
            let pc = promptContext(ctx, rich: useRich(ctx))

            var output = raw
            switch mode {
            case .dictate:
                if settings.polishEnabled, settings.skipPolishShort,
                   let quick = LocalCleanup.shortcut(raw, maxChars: settings.skipPolishMaxChars) {
                    output = quick
                    mark("本地整理")
                } else if settings.polishEnabled, let llm {
                    do {
                        let userPrompt = Prompts.polishUser(raw, pc)
                        Log.write("polish prompt: \(Prompts.polishSystem.count) (sys) + \(userPrompt.count) (user) chars")
                        let reply = try await llm.fastChat(system: Prompts.polishSystem, user: userPrompt,
                                                           examples: Prompts.polishBlockExamples, json: true, deadline: 6)
                        output = Prompts.renderBlocks(reply, spacious: ctx?.acceptsRichText ?? false) ?? Prompts.tidy(reply)
                        if output.isEmpty { output = raw }
                    } catch {
                        output = raw
                        marks.append("润色失败，已插入原文")
                        bar.flash("润色超时，已插入识别原文", seconds: 2)
                        Log.write("polish failed, inserted raw: \(error.localizedDescription)")
                    }
                    mark("润色")
                }
                output = await insert(output, ctx: ctx)

            case .translate:
                guard let llm else { throw TypError.message("翻译需要 DeepSeek API Key") }
                let targets = settings.translateTargets.isEmpty ? ["English"] : settings.translateTargets
                let system = Prompts.translateSystem(targets: targets)
                let userPrompt = Prompts.translateUser(raw, pc)
                output = Prompts.tidy(try await llm.fastChat(system: system, user: userPrompt, deadline: 15))
                mark("翻译")
                output = await insert(output, ctx: ctx)

            case .ask:
                guard let llm else { throw TypError.message("随便问需要 DeepSeek API Key") }
                let selected = await selection?.value
                let system = Prompts.askSystem(hasSelection: selected != nil)
                let userPrompt = Prompts.askUser(command: raw, selection: selected, pc)
                let reply = try await llm.fastChat(system: system, user: userPrompt, json: true,
                                                   temperature: 0.4, hedgeAfter: 4, deadline: 25)
                mark("AI")
                let obj = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any]
                let action = obj?["action"] as? String ?? "answer"
                output = Prompts.tidy(obj?["text"] as? String ?? reply)
                switch action {
                case "replace", "insert":
                    output = await insert(output, ctx: ctx)
                case "open" where settings.askActions:
                    let params = (obj?["params"] as? [String: Any] ?? [:]).compactMapValues { "\($0)" }
                    guard let opened = Actions.open(template: obj?["template"] as? String, params: params, url: obj?["url"] as? String) else {
                        throw TypError.message("无法打开：\(output)")
                    }
                    bar.flash(output.isEmpty ? "已打开 \(opened)" : output, seconds: 3)
                case "launch" where settings.askActions:
                    let name = obj?["app"] as? String ?? ""
                    guard let launched = Actions.launch(app: name) else { throw TypError.message("没有找到应用：\(name)") }
                    output = "已打开 \(launched)"
                    bar.flash(output)
                default:
                    answers.show(question: raw, answer: output)
                }
            }
            marks.append(String(format: "共 %.1fs", Date().timeIntervalSince(released)))
            Log.write("done \(mode.rawValue) in \(ctx?.appName ?? "?"): \(marks.joined(separator: " · "))")
            history.add(HistoryItem(date: Date(), mode: mode, raw: raw, text: output, appName: ctx?.appName ?? "",
                                    duration: duration, timing: marks.joined(separator: " · "), url: ctx?.url),
                        retentionDays: settings.historyRetentionDays)
            if case .message = bar.model.phase {} else { bar.hide() }
            if settings.personalization && mode != .ask { style.didDictate(history: history.items, llm: llm) }
        } catch {
            Log.write("error: \(error.localizedDescription)")
            if settings.sounds { Sounds.error() }
            bar.flash(error.localizedDescription, isError: true, seconds: 4)
            history.add(HistoryItem(date: Date(), mode: mode, raw: raw, text: "", appName: ctx?.appName ?? "",
                                    duration: duration, error: error.localizedDescription, url: ctx?.url),
                        retentionDays: settings.historyRetentionDays)
        }
    }

    // MARK: - Learning from corrections

    private func learn(inserted: String, edited: String) {
        let mod = EditWatcher.analysisModification(original: inserted, current: edited)
        if mod.isLargeModify {
            Log.write("learn: skipped large modification (+/- \(mod.changedCount) chars) in style & dictionary")
            return
        }
        if settings.personalization { style.addExample(before: inserted, after: edited) }
        guard settings.autoLearn, let llm else { return }
        Task {
            let reply: String
            do {
                reply = try await llm.fastChat(system: Prompts.learnTerms,
                                               user: "ORIGINAL:\n\(inserted)\n\nEDITED:\n\(edited)", json: true, temperature: 0, deadline: 20)
            } catch {
                Log.write("learn: term extraction failed: \(error.localizedDescription)")
                return
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any],
                  let terms = obj["terms"] as? [String] else {
                Log.write("learn: unexpected reply: \(reply.prefix(120))")
                return
            }
            let known = Set(settings.dictionary.map { $0.lowercased() })
            // Only words that were actually fixed: present after the edit, absent from what Typ wrote.
            let fresh = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { (2...40).contains($0.count) && !known.contains($0.lowercased()) && edited.contains($0) && !inserted.contains($0) }
            Log.write("learn: model suggested \(terms), new: \(fresh)")
            guard !fresh.isEmpty else { return }
            settings.dictionary.insert(contentsOf: fresh, at: 0)
            settings.autoLearned.append(contentsOf: fresh)
            if state == .idle { bar.flash("已学习：\(fresh.joined(separator: "、"))", seconds: 2) }
        }
    }
}

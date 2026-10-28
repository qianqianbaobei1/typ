# Typ 优化方案（交给本地 Claude Code 执行）

> 本文是一份**可直接执行的改造清单**。每一项都写明了：问题、涉及文件、具体改法、验收方式。
> 按 P0 → P1 → P2 → P3 顺序做；每完成一项单独 commit，并 `swift build -c release` 确认能编译。
> 所有行号基于提交 `d74eb7d`，若有偏移以函数名为准。

执行约定（给本地 Claude 的说明）：
- 保持现有代码风格：注释密度、命名、中文 UI 文案风格与现有代码一致。
- 不要引入第三方 Swift 依赖。
- 每个任务做完后在 `typ.log` 能看到的地方保留/补充必要的 `Log.write`，方便验证。
- 改完全部 P0 后先让用户实测一次再继续。

---

## P0 — 必须先修的 Bug

### P0-1 黑名单 App（微信等）被当成“密码框”逐字键入，多段文字会被拆成多条消息发出

**问题**
- `Context.swift` `ContextReader.enrich`：命中隐私黑名单时设置 `ctx.isSecureField = true`。
- `TextInserter.swift` `insert(plain:html:context:)`：`isTerminalApp || isSecureField` 时走 `typeUnicode` 逐字敲。
- 微信在黑名单里 → 润色结果里的 `\n` 被当成回车 → 一段话被拆成多条消息发出。终端同理，多行文字里的换行可能直接执行命令。

**改法**
1. `AppContext` 新增字段，把“不读取内容”和“是不是密码框”分开：
   ```swift
   /// The app or page is on the privacy blacklist: don't read its text (insertion still works normally).
   var isPrivate = false
   ```
2. `enrich` 中命中黑名单时改为 `ctx.isPrivate = true`（不再动 `isSecureField`），然后 `return ctx`。
3. `TextInserter.insert` 改为：
   ```swift
   if let ctx = context {
       if ctx.isSecureField {
           // Password fields: type it, on one line, never via the clipboard.
           await typeUnicode(text.replacingOccurrences(of: "\n", with: " "))
           return
       }
       if ctx.isTerminalApp {
           // A newline in a terminal would run the command; keep dictation on one line.
           await paste(plain: Self.singleLine(text), html: nil, preserveClipboard: preserveClipboard)
           return
       }
   }
   await paste(plain: text, html: html, preserveClipboard: preserveClipboard)
   ```
   其中 `singleLine` 把 `\n+` 替换为单个空格并 trim。（终端粘贴本身走 bracketed paste，单行后更安全。）
4. `Controller.insert` 里给 `editWatcher.watch` 的逻辑不变；`isPrivate` 的 App 不传 `element`（不读取它的内容）：`element: ctx?.isPrivate == true ? nil : ctx?.element`。另外 `copyBeforeSend`（⌘A⌘C 读取）对 `isPrivate` 的 App 也要跳过：`watch` 增加参数 `allowRead: Bool`，为 false 时直接 return。

**验收**
- 在微信里听写一段会被分成 2 段以上的话（含列表），应作为**一条**消息粘贴进输入框，不会自动发出。
- 在 Terminal 里听写长句，内容成单行插入，不会自动执行。
- 微信里听写后修改再发送，`typ.log` 中不应出现读取微信输入框的日志。

### P0-2 `typeUnicode` 会拆坏 emoji、长文本丢字

**问题**：`TextInserter.swift` `typeUnicode` 按 UTF-16 单元逐个发送，代理对（emoji）被拆开；连续发送无间隔，长文本丢字。

**改法**：改成 `async`，按字符簇（Character）分组，每个事件最多 20 个 UTF-16 单元，事件之间稍作停顿：
```swift
@MainActor
static func typeUnicode(_ text: String) async {
    let src = CGEventSource(stateID: .privateState)
    var chunk: [UniChar] = []
    func flush() {
        guard !chunk.isEmpty else { return }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
            e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cghidEventTap)
        }
        chunk.removeAll(keepingCapacity: true)
    }
    for ch in text {
        let units = Array(String(ch).utf16)
        if chunk.count + units.count > 20 {
            flush()
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        chunk.append(contentsOf: units)
    }
    flush()
}
```
调用处都改成 `await`。

**验收**：在密码框以外临时强制走 `typeUnicode`，输入 “你好 👋🏽 test 中文”，emoji 完整，无丢字。

### P0-3 URL 黑名单永远不生效

**问题**：`enrich` 一开始就调用 `isBlacklisted(bundleID:url:)`，此时 `ctx.url` 还是 nil；URL 要到后面才读出来。

**改法**：调整 `enrich` 顺序：
1. 先拿 `appEl`、`window`、`ctx.element`（这些不读用户文本）。
2. 用 `findWebInfoByTraversingUp(from:)` 拿到 `url/title`。
3. **再**判断 `isBlacklisted(bundleID:url:)`，命中则 `ctx.isPrivate = true; return ctx`（此时还未读取 `kAXValue`、未做 `Scan`）。
4. 然后才读取光标前后文本、做 `Scan`。
5. `Scan` 拿到的 `scan.url` 如果之前为 nil，也要补一次黑名单判断：命中则清空 `visibleText`、`textBefore`、`textAfter`，并设置 `isPrivate`。

**验收**：在 Safari/Chrome 打开 `https://docs.qq.com/doc/...`，听写后 `typ.log` 中的 polish prompt 字数明显变小（无屏幕文本）。可临时加一行 `Log.write("context: private=\(ctx.isPrivate) url=\(ctx.url ?? "-")")`。

### P0-4 两个设置开关没有任何作用

**问题**：`Settings.privacyProtection`、`Settings.bottomUpWebContext` 只在 `Views.swift` 里绑定，业务代码从未使用。

**改法**：`enrich` 是 nonisolated 的静态函数，不能直接读 `Settings.shared`。给它加参数：
```swift
static func enrich(_ base: AppContext, deep: Bool, privacy: Bool, bottomUpWeb: Bool) -> AppContext
```
- `privacy == false` 时跳过黑名单判断（`isBlacklisted` 不调用）。
- `bottomUpWeb == false` 时不调用 `findWebInfoByTraversingUp`，只依赖 `Scan` 的 `url`。
- `Controller.begin` 里在主线程读取这两个设置后传入。

**验收**：关掉“敏感应用隐私保护”后，在微信听写，`typ.log` 显示 `private=false`。

### P0-5 回车拦截 / 编辑监视在主线程同步做 Accessibility 读取，可能卡键盘

**问题**
- `Learning.swift` `EditWatcher.intercept` 在 CGEventTap 回调里（主线程）直接 `poll()`，对每个 pending 元素同步 `AXUIElementCopyAttributeValue`，而这些元素**没有设置超时**（默认约 6 秒）。目标 App 卡住时，整个系统键盘输入跟着卡，事件 tap 还可能被系统禁用。
- 定时器每 0.7 s 也在主线程做同样的读取，与热键处理争用主线程。

**改法**
1. `registerField` 中对 `resolved` 设置超时：`AXUIElementSetMessagingTimeout(resolved, 0.15)`。
2. 定时轮询改为后台读取、主线程应用结果：
   ```swift
   private let axQueue = DispatchQueue(label: "typ.editwatcher.ax", qos: .utility)
   private var polling = false

   private func poll() {
       expire()
       guard !polling, !pendings.isEmpty else { return }
       polling = true
       let elements = pendings.map { $0.element }
       axQueue.async { [weak self] in
           let values = elements.map { AX.string($0, kAXValueAttribute) }
           DispatchQueue.main.async {
               MainActor.assumeIsolated {
                   self?.polling = false
                   self?.apply(values: values, for: elements)
               }
           }
       }
   }
   ```
   把原 `poll()` 中“根据 value 更新 pending”的逻辑搬到 `apply(values:for:)`，通过 `CFEqual(element, p.element)` 对应回 pending（期间 pending 可能已被移除，找不到就忽略）。
3. `intercept` 里 Enter 时：**不要**同步读取；改为调用异步 `poll()`（尽力而为）。因为 0.7 s 轮询本来就能捕获绝大部分修改，这里少量精度损失可以接受，避免卡键盘更重要。
4. `HotkeyMonitor.handle` 已经处理 `tapDisabledByTimeout`，保持不变。

**验收**：在一个可读输入框中听写后，快速连续敲字和回车，无卡顿；`typ.log` 中修正学习仍能正常出现 `learn: correction captured`。

### P0-6 日语汉字被繁→简转换

**问题**：`Controller.process` 中只要开了简体中文，就对所有识别结果执行 `Hant-Hans`，日语里的汉字也会被改掉。

**改法**：
1. 识别结果包含假名（U+3040–U+30FF）或韩文（U+AC00–U+D7AF）时跳过转换：
   ```swift
   private static func looksJapaneseOrKorean(_ s: String) -> Bool {
       s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
   }
   ```
2. 同理，`fullWidthPunctuation` 已按前一个字是否为汉字判断，保持不变。

**验收**：说话语言设为 auto，说一句日语，插入结果保留日文汉字原形。

### P0-7 英文/数字前补空格的条件优先级错误

**问题**：`Controller.insert` 中 `first.isASCII && first.isLetter || first.isNumber` 实际是 `(ASCII 且字母) 或 数字`，`"三".isNumber` 为 true，导致英文后紧跟中文数字时多出空格。

**改法**：
```swift
if let last = ctx?.textBefore?.last, !last.isWhitespace, let first = plain.first,
   first.isASCII && (first.isLetter || first.isNumber),
   last.isASCII && (last.isLetter || last.isNumber || ".,!?;:".contains(last)) {
    plain = " " + plain
}
```

---

## P1 — 更快

### P1-1 让 DeepSeek 前缀缓存命中（润色延迟大头）

**问题**：DeepSeek 自动缓存相同的请求前缀。目前 messages 的结构是：
`system = 固定规则 + contextBlock(每次都变)` → `4 组示例` → `user(transcript)`。
变化的 contextBlock 夹在中间，导致其后的几 KB 示例**每次都无法命中缓存**。

**改法**
1. `Prompts.polish(_:)` 拆成两部分：
   - `static let polishSystem: String` —— 原规则文本，去掉末尾的 `\(contextBlock(p))`；规则开头加一句：
     `The user message contains <context> (where the text is going, screen text, dictionary, style) and the <transcript>.`
   - `static func polishUser(_ raw: String, _ p: PromptContext) -> String`：
     ```swift
     "<context>\n\(contextBlock(p))\n</context>\n\n" + wrapTranscript(raw)
     ```
2. 示例 `polishBlockExamples` 的 user 部分也要包上一个**固定的**最小 `<context>`（例如 `Destination app: WeChat` + plain text 那一行），让模型看到一致的格式。示例内容固定不变，因此可被缓存。
3. `Controller.process` 中的调用改为：
   ```swift
   let reply = try await llm.fastChat(system: Prompts.polishSystem, user: Prompts.polishUser(raw, pc),
                                      examples: Prompts.polishBlockExamples, json: true, deadline: 6)
   ```
4. `translate` 和 `ask` 同理：system 固定，contextBlock 移入 user。
5. `LLMClient.chat` 解析响应里的 `usage.prompt_cache_hit_tokens`（DeepSeek 字段），写到日志：
   `Log.write("LLM usage: prompt \(p) (cache hit \(h)), completion \(c), \(elapsed)s")`。

**验收**：连续听写 3 次，第 2 次起日志中 `cache hit` 应 ≥ 规则+示例的 token 数（约 1500+）；润色耗时（history 的 timing 字段 “润色 x.xs”）中位数下降。

### P1-2 短句跳过大模型，本地清理

**改法**
1. 新文件 `Sources/Typ/LocalCleanup.swift`：
   ```swift
   import Foundation

   /// Cheap local tidy-up for short, clean utterances that don't need the LLM.
   enum LocalCleanup {
       static let fillers = ["嗯", "呃", "啊", "哎", "那个", "就是", "这个", "对吧", "怎么说呢", "然后",
                             "um", "uh", "like", "you know", "I mean"]
       static let corrections = ["不对", "我是说", "改成", "算了", "不是", "重新说", "actually", "no wait", "scratch that"]

       /// Returns the text to insert without polishing, or nil when the LLM should handle it.
       static func shortcut(_ raw: String, maxChars: Int) -> String? {
           let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
           guard !t.isEmpty, t.count <= maxChars else { return nil }
           let lower = t.lowercased()
           if fillers.contains(where: { lower.contains($0.lowercased()) }) { return nil }
           if corrections.contains(where: { lower.contains($0.lowercased()) }) { return nil }
           return pangu(t)
       }

       /// Inserts a space between CJK and ASCII letters/digits.
       static func pangu(_ s: String) -> String {
           var t = s.replacingOccurrences(of: #"([\p{Han}])([A-Za-z0-9])"#, with: "$1 $2", options: .regularExpression)
           t = t.replacingOccurrences(of: #"([A-Za-z0-9])([\p{Han}])"#, with: "$1 $2", options: .regularExpression)
           return t
       }
   }
   ```
   注意：`"就是"`、`"然后"` 在正常句子中也常见，这里宁可多走 LLM 也不要误判。
2. `Settings` 新增 `@Published var skipPolishShort: Bool`（默认 true）与 `skipPolishMaxChars: Int`（默认 20），`Views.swift` 设置页“润色”区域加一个开关。
3. `Controller.process` `.dictate` 分支：
   ```swift
   if settings.polishEnabled, settings.skipPolishShort,
      let quick = LocalCleanup.shortcut(raw, maxChars: settings.skipPolishMaxChars) {
       output = quick
       mark("本地整理")
   } else if settings.polishEnabled, let llm { ... 原逻辑 ... }
   ```

**验收**：说“好的明天见”，history 中 timing 只有“识别 + 本地整理”，总耗时 < 0.5 s；说一句带“嗯…那个…”的短句，仍走润色。

### P1-3 SenseVoice 改用 int8 模型

**改法**
1. `Resources/sensevoice_server.py`：优先使用 int8：
   ```python
   MODEL = next(p for p in (os.path.join(MODEL_DIR, n) for n in ("model.int8.onnx", "model.onnx")) if os.path.exists(p))
   ```
2. `scripts/setup_sensevoice.sh`：判断条件改为 `model.int8.onnx` 不存在才下载；解压后移动 `model.int8.onnx` 和 `tokens.txt`（不再移动 fp32 的 `model.onnx`）。已有 fp32 模型的用户：下载 int8 后删除旧的 `model.onnx` 节省约 900 MB（脚本打印提示）。
3. `scripts/create_share_package.py` 中内嵌的安装脚本做同样修改（`model_cache/` 也改为 int8 文件；提示文案“约 890MB”改为“下载约 1GB 压缩包，安装后占用约 230MB”——压缩包本身仍包含两个模型）。
4. `WhisperEngine.senseVoiceInstalled` 只检查 `tokens.txt`，无需修改。

**验收**：`whisper.log` 中启动行显示 `(model.int8.onnx)`；Typ 启动到“就绪”的时间缩短；活动监视器中 python 进程内存明显下降。

### P1-4 SenseVoice 首次识别慢 / 多语言重复加载模型

**问题**：服务启动只预加载 `auto`；如果用户设置的是 `zh`，第一次说话时才加载第二份完整模型（几秒卡顿 + 内存翻倍）。

**改法**
1. `sensevoice_server.py` 接收第 3 个参数作为默认语言并预加载它；线程数按 CPU 计算：
   ```python
   DEFAULT_LANG = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] in LANGS else "auto"
   THREADS = max(2, min(8, (os.cpu_count() or 4) - 2))
   ...
   recognizer(DEFAULT_LANG)
   ```
   `do_POST` 中 SenseVoice 不支持的语言（如 fr/de）：`auto` 已加载就用 `auto`，否则用已加载的 `DEFAULT_LANG`，避免临时再加载一份模型：
   ```python
   if lang not in LANGS:
       lang = "auto" if "auto" in recognizers else DEFAULT_LANG
   ```
2. `WhisperEngine.start(kind:modelPath:)` 增加 `language: String` 参数，SenseVoice 启动参数追加该语言；所有调用处（`AppDelegate`、`Views.swift` 的两处）传 `settings.speechLanguage`。
3. `Views.swift` 中 “说话语言” Picker 增加 `.onChange(of: settings.speechLanguage)`：若当前引擎是 SenseVoice，后台发一个 0.5 秒静音 WAV 预热新语言（`WhisperEngine.transcribe(kind: .sensevoice, wav: AudioRecorder.wav([Float](repeating: 0, count: 8000)), language: lang, prompt: "")`，忽略结果），避免用户切换后第一句卡顿。

**验收**：语言设为“中文”，重启 Typ 后第一句话的“识别”耗时与第二句相当。

---

## P2 — 更准

### P2-1 自动学习“误识别 → 正确写法”对照表，并在本地直接替换

**问题**：目前自动学习只记录正确写法（如 `招采saas`），没有记录它被识别成了什么（如 `招财 saas`）。SenseVoice 不支持热词，关掉润色时词典完全不起作用。

**改法**
1. `Settings` 新增：
   ```swift
   /// Learned speech-recognition fixes: what the engine heard -> what the user meant.
   @Published var replacements: [String: String] { didSet { d.set(replacements, forKey: "replacements") } }
   ```
2. `Prompts.learnTerms` 输出格式改为：
   ```
   Reply with JSON: {"terms": [{"wrong": "<exact text from ORIGINAL>", "right": "<exact text from EDITED>"}]}
   ```
   并强调 `wrong` 必须原样出现在 ORIGINAL 中、`right` 必须原样出现在 EDITED 中。
3. `Controller.learn` 解析新格式：校验 `inserted.contains(wrong) && edited.contains(right) && !inserted.contains(right)`，`wrong.count >= 2`，`wrong != right`；通过的：
   - `right` 照旧加入 `dictionary` / `autoLearned`；
   - `replacements[wrong] = right`。
   兼容旧格式（`terms` 为字符串数组时按原逻辑处理）。
4. `Controller.process` 在繁简转换和 `fullWidthPunctuation` 之后、润色之前，执行本地替换（按 key 长度降序，避免短 key 抢先）：
   ```swift
   for (wrong, right) in settings.replacements.sorted(by: { $0.key.count > $1.key.count }) where raw.contains(wrong) {
       raw = raw.replacingOccurrences(of: wrong, with: right)
   }
   ```
5. `Prompts.contextBlock` 的词典行增加：`Known mis-hearings: 招财 saas → 招采saas, ...`（最多 30 条）。
6. `Views.swift` 词典页增加一个“自动纠错”列表，可查看和删除每一条对照（误学习时用户能撤销）。

**验收**：手动把 “招财 saas” 改成 “招采saas” 并发送；之后关闭润色再说一次，插入结果直接是 “招采saas”。

### P2-2 词典限量，避免提示词膨胀

**问题**：词典只增不减，全部塞进 LLM 提示词和 Whisper prompt；Whisper prompt 上限约 224 token，超出会被截断，词太多反而干扰识别。

**改法**
1. 新增 `Prompts.relevantDictionary(_ dict: [String], raw: String, screen: String?, limit: Int) -> [String]`：
   - 先选出在 `raw` 或 `screen` 中出现、或与 `raw` 中某个片段编辑距离很近的词（可用 `EditWatcher.similarity` 做 ≥0.7 的粗筛，仅对长度相近的子串）；
   - 再按词典顺序（新词在前）补足到 `limit`。
2. LLM 提示词用 `limit = 80`；Whisper 的 `whisperPrompt` 用 `limit = 30` 且总长度不超过 200 字符。
3. 词典本身不删，只是送进提示词时筛选。

**验收**：词典超过 200 条时，`polish prompt: N chars` 日志的 N 不再随词典线性增长。

### P2-3 录音引擎复用，减少开口吞字

**问题**：每次按下热键都新建 `AVAudioEngine`，启动 100–300 ms，开头一两个字容易丢。

**改法**（不常驻打开麦克风，避免一直亮橙色隐私指示灯）：
1. `AudioRecorder` 持有一个可复用的 `AVAudioEngine`，只在设备 UID 变化或配置变更通知（`AVAudioEngineConfigurationChange`）时重建；`stop()` 只 `removeTap` + `stop()`，不置空 engine。
2. `start` 中复用已 `prepare()` 的 engine，省去创建与图构建时间。
3. 在 `Log` 中记录 “hotkey → 首个音频 buffer” 的延迟（在 `consume` 第一次被调用时记一次），方便对比。

**验收**：日志中首个 buffer 延迟下降；按下热键立刻说话，第一个字不丢。

---

## P3 — 更智能 / 体验

### P3-1 按 App 区分写作风格

- `StyleProfile.refresh` 现在只生成一份全局画像。改为按 App 类别（聊天 / 邮件 / 文档 / 代码）各生成一段，存成 `[String: String]`；`promptContext` 根据当前 `bundleID` 选取对应的一段（无则用全局）。
- 类别映射写成一个静态表（WeChat/Slack/Telegram/飞书 → chat，Mail/Outlook/Gmail 域名 → email，Notes/Pages/Notion/文档域名 → doc，Xcode/VSCode/终端 → code）。

### P3-2 按 App 记住是否润色

- 在 `learn` 中统计每个 App 的“大改”次数（`isLargeModify` 的情况也计数，而不是直接丢弃）。某个 App 最近 10 次中大改 ≥ 5 次，则在设置页提示“在 XX 中你经常大幅修改润色结果，要在这里关闭润色吗？”，并提供按 App 关闭润色的列表。

### P3-3 “随便问”流式显示

- `LLMClient` 新增 `stream(system:user:...) -> AsyncThrowingStream<String, Error>`（SSE，`"stream": true`）。
- `ask` 模式下若最终 action 是 `answer`，`AnswerPanel` 边收边显示。由于 ask 返回 JSON，可改为让模型先输出一行 `ACTION: answer` 再输出正文，或保持 JSON 但对 `"text"` 字段做增量解析；推荐前者，更简单可靠。

### P3-4 API Key 存入钥匙串

- `Settings.readKey/writeKey` 改用 Keychain（`SecItemAdd/SecItemCopyMatching/SecItemUpdate`，service = `local.typ.app`，account = `apiKey`）。
- 首次启动时如果旧文件 `apikey` 存在：读入 → 写入钥匙串 → 删除文件。

### P3-5 构建脚本去掉写死的本机路径

- `scripts/bundle_release.py` 的 `PROJECT_DIR` 改为 `os.path.dirname(os.path.dirname(os.path.abspath(__file__)))`。

---

## 建议的提交顺序

1. `fix: insert into blacklisted apps by paste, single-line in terminals`（P0-1）
2. `fix: type unicode in grapheme chunks`（P0-2）
3. `fix: apply URL blacklist after URL is known; wire privacy/web-context toggles`（P0-3、P0-4）
4. `fix: read watched fields off the main thread with short AX timeouts`（P0-5）
5. `fix: skip Hant→Hans for Japanese/Korean; fix spacing precedence`（P0-6、P0-7）
6. `perf: cacheable prompt prefix for DeepSeek`（P1-1）
7. `perf: skip LLM polish for short clean utterances`（P1-2）
8. `perf: SenseVoice int8 model, preload configured language`（P1-3、P1-4）
9. `feat: learn mis-hearing replacements; cap dictionary in prompts`（P2-1、P2-2）
10. `perf: reuse audio engine`（P2-3）
11. P3 各项按需。

## 回归检查清单（每批改完都过一遍）

- [ ] fn 按住说话、松开插入；轻点进入免手模式，再按结束
- [ ] fn+Shift 翻译、fn+Control 随便问（有选区 / 无选区）
- [ ] 微信、备忘录、Safari 网页输入框、Terminal、密码框各听写一次
- [ ] 剪贴板里事先复制一张图片，听写后图片仍在剪贴板
- [ ] 修改一次插入结果并发送，日志出现 `learn: correction captured`
- [ ] 切换 SenseVoice / Whisper 引擎，均能就绪并识别
- [ ] `swift build -c release` 无警告新增

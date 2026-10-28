import AVFoundation
import SwiftUI

struct MainView: View {
    @EnvironmentObject var nav: Navigation

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 210)
                .background(Theme.sidebar)
            Rectangle().fill(Theme.border).frame(width: 1)
            Group {
                switch nav.tab {
                case .home: HomeView()
                case .history: HistoryView()
                case .dictionary: DictionaryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .ignoresSafeArea()
        .tint(Theme.clay)
        .frame(minWidth: 780, minHeight: 540)
    }
}

struct Sidebar: View {
    @EnvironmentObject var nav: Navigation
    @EnvironmentObject var whisper: WhisperEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                TypMark(size: 26)
                Text("Typ").font(Theme.display(21, .medium)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10)
            .padding(.top, 46)
            .padding(.bottom, 18)

            ForEach(Tab.allCases) { tab in
                Button { nav.tab = tab } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.symbol).frame(width: 18)
                        Text(tab.title)
                        Spacer()
                    }
                    .font(.system(size: 13, weight: nav.tab == tab ? .semibold : .regular))
                    .foregroundStyle(nav.tab == tab ? Theme.text : Theme.text2)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(nav.tab == tab ? Theme.card : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(nav.tab == tab ? Theme.border : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(whisper.status == .ready ? Theme.green : Theme.clay).frame(width: 7, height: 7)
                Text(whisper.kind == .sensevoice ? "SenseVoice" : "Whisper").font(.system(size: 11, weight: .medium))
                Text(whisper.status.label).font(.system(size: 11)).lineLimit(1)
            }
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 10).padding(.bottom, 16)
        }
        .padding(.horizontal, 10)
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var history: HistoryStore

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 6 ? "夜深了" : h < 12 ? "早上好" : h < 18 ? "下午好" : "晚上好"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(greeting).font(Theme.display(34)).foregroundStyle(Theme.text)
                        Text("说话就是打字。在任何 App 里按住快捷键说话，松开即插入整理好的文字。")
                            .font(.system(size: 14)).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text("按住").foregroundStyle(Theme.text3)
                            KeyCap(text: settings.dictateTrigger.label)
                            Text("开始说话").foregroundStyle(Theme.text3)
                        }
                        .font(.system(size: 12))
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                    VoiceIllustration()
                }
                .padding(.top, 34)

                SetupChecklist()

                HStack(spacing: 12) {
                    StatCard(title: "总字数", value: "\(history.totalWords)", symbol: "text.word.spacing", color: Theme.clay)
                    StatCard(title: "听写次数", value: "\(history.successful.count)", symbol: "waveform", color: Theme.blue)
                    StatCard(title: "平均速度", value: "\(history.wordsPerMinute)", unit: "字/分", symbol: "speedometer", color: Theme.green)
                    StatCard(title: "节省时间", value: "\(history.minutesSaved)", unit: "分钟", symbol: "clock", color: Theme.clay)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("三种用法").font(Theme.display(19)).foregroundStyle(Theme.text)
                    HStack(alignment: .top, spacing: 12) {
                        UsageCard(mode: .dictate, trigger: settings.dictateTrigger,
                                  text: "去掉口头禅、理解改口、加标点，自动整理成列表或邮件格式。")
                        UsageCard(mode: .translate, trigger: settings.translateTrigger,
                                  text: "说任何语言，插入\(settings.translateTargets.joined(separator: "、"))译文。")
                        UsageCard(mode: .ask, trigger: settings.askTrigger,
                                  text: "选中文字说指令直接改写，或者提问、打开 App 和网站。")
                    }
                    Text("轻按一下快捷键进入免提模式，说完再按一次；录音时按 Esc 取消。")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                }

                if let last = history.successful.first {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最近一次").font(Theme.display(19)).foregroundStyle(Theme.text)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(last.text).font(.system(size: 14)).lineSpacing(3).foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                            HStack(spacing: 8) {
                                Text(last.appName)
                                Text(last.date, format: .dateTime.hour().minute())
                                if let t = last.timing { Text(t) }
                            }
                            .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .typCard()
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 36)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }
}

struct UsageCard: View {
    let mode: Mode
    let trigger: HotkeyTrigger
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: mode.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent(for: mode)))
                Spacer()
                KeyCap(text: trigger.label)
            }
            Text(mode.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .typCard()
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var unit: String?
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Theme.display(26)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.6)
                if let unit { Text(unit).font(.system(size: 11)).foregroundStyle(Theme.text3) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .typCard(padding: 14)
    }
}

struct SetupChecklist: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var whisper: WhisperEngine
    @EnvironmentObject var nav: Navigation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let ax = Permissions.accessibility
            let engine = whisper.status == .ready
            let key = settings.hasAPIKey
            if !(mic && ax && engine && key) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.clay)
                        Text("还差几步就能用了").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    CheckRow(ok: mic, title: "麦克风权限", detail: "用于录音") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                        Permissions.openSettings("Privacy_Microphone")
                    }
                    CheckRow(ok: ax, title: "辅助功能权限", detail: "用于监听快捷键、把文字插入到其它 App") {
                        Permissions.requestAccessibility()
                        Permissions.openSettings("Privacy_Accessibility")
                    }
                    CheckRow(ok: engine, title: "本地语音引擎", detail: whisper.status.label, actionTitle: "重启") {
                        whisper.start(kind: settings.speechEngine, modelPath: settings.modelPath)
                    }
                    CheckRow(ok: key, title: "DeepSeek API Key", detail: "用于润色、翻译和随便问", actionTitle: "去填写") {
                        nav.tab = .settings
                    }
                    Text("如果按 fn 会弹出表情或切换输入法：系统设置 → 键盘 → “按下 🌐 键时”选择“无操作”。")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.clayTint))
            }
        }
    }
}

struct CheckRow: View {
    let ok: Bool
    let title: String
    let detail: String
    var actionTitle = "授权"
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 15))
                .foregroundStyle(ok ? Theme.green : Theme.clay)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.text2)
            }
            Spacer()
            if !ok { Button(actionTitle, action: action).buttonStyle(ClayButtonStyle()) }
        }
    }
}

// MARK: - History

struct SearchField: View {
    @Binding var text: String
    var prompt: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
            TextField(prompt, text: $text).textFieldStyle(.plain)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }
}

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @StateObject private var query = Box("")
    @StateObject private var confirmClear = Box(false)

    private var filtered: [HistoryItem] {
        query.value.isEmpty ? history.items : history.items.filter {
            $0.text.localizedCaseInsensitiveContains(query.value) || $0.raw.localizedCaseInsensitiveContains(query.value)
                || $0.appName.localizedCaseInsensitiveContains(query.value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                PageHeader(title: "历史记录", subtitle: "每次听写都只保存在这台电脑上")
                Button("清空") { confirmClear.value = true }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(history.items.isEmpty)
            }
            SearchField(text: $query.value, prompt: "搜索文字或 App")
            if history.items.isEmpty {
                EmptyState(symbol: "clock", title: "还没有记录", text: "按住快捷键说一句话试试。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { item in
                            HistoryRow(item: item)
                                .contextMenu {
                                    Button("复制") { TextInserter.copyToClipboard(item.text) }
                                    Button("复制原始转写") { TextInserter.copyToClipboard(item.raw) }
                                    Divider()
                                    Button("删除", role: .destructive) { history.delete(item.id) }
                                }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 46)
        .confirmationDialog("清空所有历史记录？此操作无法撤销。", isPresented: $confirmClear.value) {
            Button("清空", role: .destructive) { history.clear() }
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(Theme.clay.opacity(0.7))
            Text(title).font(Theme.display(18)).foregroundStyle(Theme.text)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    @StateObject private var showRaw = Box(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = item.error {
                Text(err).font(.system(size: 13)).foregroundStyle(Theme.clayStrong)
                if !item.raw.isEmpty { Text(item.raw).font(.system(size: 13)).foregroundStyle(Theme.text2) }
            } else {
                Text(item.text).font(.system(size: 14)).lineSpacing(3).foregroundStyle(Theme.text).textSelection(.enabled)
                if showRaw.value && item.raw != item.text {
                    Text("原始转写：\(item.raw)").font(.system(size: 12)).foregroundStyle(Theme.text2).textSelection(.enabled)
                }
            }
            HStack(spacing: 8) {
                Text(item.mode.title)
                    .foregroundStyle(Theme.accent(for: item.mode))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.accent(for: item.mode).opacity(0.13)))
                Text(item.date, format: .dateTime.month().day().hour().minute())
                if !item.appName.isEmpty { Text(item.appName) }
                if let url = item.url, !url.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "globe").font(.system(size: 9))
                        Text(url).lineLimit(1)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.clayTint))
                    .foregroundStyle(Theme.clay)
                }
                Text(String(format: "%.1f 秒", item.duration))
                if let timing = item.timing { Text("⏱ " + timing) }
                Spacer()
                if item.error == nil && item.raw != item.text {
                    Button(showRaw.value ? "隐藏原文" : "查看原文") { showRaw.value.toggle() }
                        .buttonStyle(.plain).foregroundStyle(Theme.clay)
                }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .typCard(padding: 14)
    }
}

// MARK: - Dictionary

struct DictionaryView: View {
    @EnvironmentObject var settings: Settings
    @StateObject private var newWord = Box("")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "词典", subtitle: "人名、公司名、专业术语。Typ 会优先按这些写法输出；你插入后手动改正的词也会被自动学习。")
            HStack(spacing: 8) {
                TextField("添加词语，例如：平方网、广联达", text: $newWord.value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
                    .onSubmit(add)
                Button("添加", action: add)
                    .buttonStyle(ClayButtonStyle())
                    .disabled(newWord.value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if settings.dictionary.isEmpty {
                EmptyState(symbol: "character.book.closed", title: "还没有词语", text: "加几个你常说的专有名词吧。")
            } else {
                ScrollView {
                    FlowLayout(spacing: 8) {
                        ForEach(settings.dictionary, id: \.self) { word in
                            WordChip(word: word, auto: settings.autoLearned.contains(word)) {
                                settings.dictionary.removeAll { $0 == word }
                                settings.autoLearned.removeAll { $0 == word }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 46)
    }

    private func add() {
        let w = newWord.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !settings.dictionary.contains(w) else { newWord.value = ""; return }
        settings.dictionary.insert(w, at: 0)
        newWord.value = ""
    }
}

struct WordChip: View {
    let word: String
    let auto: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(word).font(.system(size: 13)).foregroundStyle(Theme.text)
            if auto {
                Text("自动").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.clay)
            }
            Button(action: onDelete) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Capsule().fill(auto ? Theme.clayTint : Theme.card))
        .overlay(Capsule().strokeBorder(auto ? Theme.clay.opacity(0.3) : Theme.border))
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var whisper: WhisperEngine
    @EnvironmentObject var style: StyleProfile
    @EnvironmentObject var history: HistoryStore
    @StateObject private var testResult = Box("")
    @StateObject private var testing = Box(false)
    @StateObject private var mics = Box<[AudioDevice]>([])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "设置")
                .padding(.horizontal, 36).padding(.top, 46).padding(.bottom, 4)
            form
        }
        .onAppear { mics.value = AudioDevices.inputDevices() }
    }

    private var form: some View {
        Form {
            Section("快捷键") {
                Picker("听写", selection: $settings.dictateTrigger) { triggerOptions }
                Picker("翻译", selection: $settings.translateTrigger) { triggerOptions }
                Picker("随便问", selection: $settings.askTrigger) { triggerOptions }
                Text("按住说话、松开插入；轻按一下进入免提模式，再按一次结束。").font(.caption).foregroundStyle(.secondary)
            }

            Section("语音识别（本地）") {
                LabeledContent("状态") {
                    HStack {
                        Text(whisper.status.label).foregroundStyle(whisper.status == .ready ? Theme.green : Theme.text2)
                        Button("重启引擎") { whisper.start(kind: settings.speechEngine, modelPath: settings.modelPath) }.buttonStyle(SoftButtonStyle())
                    }
                }
                Picker("识别引擎", selection: $settings.speechEngine) {
                    ForEach(SpeechEngineKind.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.speechEngine) { _, kind in whisper.start(kind: kind, modelPath: settings.modelPath) }
                if settings.speechEngine == .sensevoice && !WhisperEngine.senseVoiceInstalled {
                    Text("SenseVoice 未安装，正在使用 Whisper。运行 scripts/setup_sensevoice.sh 安装。").font(.caption).foregroundStyle(.orange)
                }
                Picker("说话语言", selection: $settings.speechLanguage) {
                    ForEach(speechLanguages, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("中文输出", selection: $settings.simplifiedChinese) {
                    Text("简体").tag(true)
                    Text("繁體").tag(false)
                }
                TextField("Whisper 模型文件", text: $settings.modelPath).font(.caption.monospaced())
            }

            Section("AI 润色（DeepSeek）") {
                Toggle("听写时自动润色", isOn: $settings.polishEnabled)
                SecureField("API Key", text: $settings.apiKey, prompt: Text("sk-..."))
                TextField("接口地址", text: $settings.apiBaseURL)
                TextField("模型", text: $settings.apiModel)
                HStack {
                    Button(testing.value ? "测试中…" : "测试连接", action: test).buttonStyle(ClayButtonStyle()).disabled(testing.value || !settings.hasAPIKey)
                    Text(testResult.value).font(.caption).foregroundStyle(.secondary)
                }
                Text("在 platform.deepseek.com 创建 API Key。兼容任何 OpenAI 格式接口。").font(.caption).foregroundStyle(.secondary)
            }

            Section("智能功能") {
                Toggle(isOn: $settings.deepContext) {
                    Text("读取上下文")
                    Text("读取输入框里已有的文字和屏幕上的文字，让润色更贴合。密码框不会读取。")
                }
                Toggle(isOn: $settings.autoLearn) {
                    Text("自动学习词典")
                    Text("在任何 App 里，插入后你手动改正的人名、术语，都会自动加入词典。")
                }
                Toggle(isOn: $settings.copyBeforeSend) {
                    Text("输入框读不到的 App 里，发送前读取修改")
                    Text("大多数 App 的输入框 Typ 能直接读到；少数读不到的（如微信、QQ、钉钉），插入后 90 秒内你按回车时，Typ 会先全选复制读一下输入框再发出，用来学习你的改正。")
                }
                .disabled(!settings.autoLearn)
                Toggle(isOn: $settings.richText) {
                    Text("富文本插入")
                    Text("在备忘录、邮件、Pages、Word、Notion、飞书、Google Docs 等处插入加粗、列表和标题。")
                }
                Toggle(isOn: $settings.askActions) {
                    Text("随便问可以执行动作")
                    Text("打开 App、网站、搜索，起草 X / 微博 / Reddit / Gmail / 邮件草稿（只打开草稿，不会自动发送）。")
                }
            }

            Section("系统级增强（Typeless 对齐）") {
                Toggle(isOn: $settings.preserveClipboard) {
                    Text("剪贴板保护与静默恢复")
                    Text("打字上屏不破坏你原先复制的文本与图片，并标记瞬态类型，防止剪贴板历史工具（如 Raycast/Paste）被听写文字污染。")
                }
                Toggle(isOn: $settings.bottomUpWebContext) {
                    Text("浏览器深层上下文追溯")
                    Text("自底向上多级回溯 WebKit/Chromium 可访问性树，自动获取当前网页的完整 URL 和标题，大幅提升网页场景转写与润色精度。")
                }
                Toggle(isOn: $settings.privacyProtection) {
                    Text("敏感应用隐私保护")
                    Text("当焦点处于 1Password、Bitwarden、KeePass 等密码管理器时，自动熔断上下文读取，杜绝敏感凭据泄露。")
                }
            }

            Section("个性化") {
                Toggle(isOn: $settings.personalization) {
                    Text("学习我的写作风格")
                    Text("每 \(style.refreshEvery) 次听写，根据你的历史和改动更新一次风格画像。")
                }
                if settings.personalization {
                    if style.profile.isEmpty {
                        Text("还没有风格画像，至少需要 10 条听写记录。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(style.profile).font(.callout).textSelection(.enabled)
                        if let at = style.updatedAt {
                            Text("更新于 \(at.formatted(date: .abbreviated, time: .shortened))，已记住 \(style.examples.count) 次改动")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if style.totalDictations > 0 {
                        Text("文字采纳率：\(Int(style.adoptionRate * 100))%（累计听写 \(style.totalDictations) 次，手动微调 \(style.totalModifications) 次）")
                            .font(.caption).foregroundStyle(Theme.green)
                    }
                    HStack {
                        Button(style.updating ? "更新中…" : "立即更新") {
                            let client = settings.hasAPIKey ? LLMClient(baseURL: settings.apiBaseURL, apiKey: settings.apiKey, model: settings.apiModel) : nil
                            Task { await style.refresh(history: history.items, llm: client) }
                        }
                        .disabled(style.updating || !settings.hasAPIKey)
                        Button("重置") { style.reset() }
                    }
                }
            }

            Section("翻译目标语言（最多 3 个）") {
                ForEach(settings.translateTargets.indices, id: \.self) { i in
                    HStack {
                        Picker("目标 \(i + 1)", selection: Binding(
                            get: { settings.translateTargets[i] },
                            set: { settings.translateTargets[i] = $0 })) {
                            ForEach(translationLanguages, id: \.self) { Text($0).tag($0) }
                        }
                        if settings.translateTargets.count > 1 {
                            Button { settings.translateTargets.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if settings.translateTargets.count < 3 {
                    Button("添加语言") {
                        settings.translateTargets.append(translationLanguages.first { !settings.translateTargets.contains($0) } ?? "English")
                    }
                }
                Text("会翻译成第一个与你说话语言不同的目标语言。").font(.caption).foregroundStyle(.secondary)
            }

            Section("音频") {
                Picker("麦克风", selection: $settings.micUID) {
                    Text("系统默认").tag("")
                    ForEach(mics.value) { Text($0.name).tag($0.uid) }
                }
                Toggle("提示音", isOn: $settings.sounds)
                Toggle("听写时静音其它声音", isOn: $settings.muteWhileDictating)
            }

            Section("通用") {
                Toggle("开机自动启动", isOn: $settings.launchAtLogin)
                Toggle("在程序坞中显示", isOn: $settings.showInDock)
                Picker("历史记录保留时长", selection: $settings.historyRetentionDays) {
                    Text("永久保存").tag(0)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                }
                .onChange(of: settings.historyRetentionDays) { _, days in
                    history.prune(retentionDays: days)
                }
                LabeledContent("数据位置") {
                    Button("在访达中显示") { NSWorkspace.shared.open(Paths.support) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var triggerOptions: some View {
        ForEach(HotkeyTrigger.allCases) { Text($0.label).tag($0) }
    }

    private func test() {
        testing.value = true
        testResult.value = ""
        let client = LLMClient(baseURL: settings.apiBaseURL, apiKey: settings.apiKey, model: settings.apiModel)
        Task {
            do {
                let r = try await client.chat(system: "Reply with exactly: OK", user: "ping")
                testResult.value = "连接成功：\(r.prefix(20))"
            } catch {
                testResult.value = error.localizedDescription
            }
            testing.value = false
        }
    }
}

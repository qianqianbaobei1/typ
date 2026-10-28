import Foundation
import ServiceManagement

enum Mode: String, Codable, CaseIterable, Identifiable {
    case dictate, translate, ask
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dictate: return "听写"
        case .translate: return "翻译"
        case .ask: return "随便问"
        }
    }
    var symbol: String {
        switch self {
        case .dictate: return "mic.fill"
        case .translate: return "globe"
        case .ask: return "sparkles"
        }
    }
}

/// A modifier-only hotkey. Each slot is a set of interchangeable key codes (e.g. left/right Shift).
enum HotkeyTrigger: String, CaseIterable, Codable, Identifiable {
    case fn, fnShift, fnControl, fnOption, rightOption, rightCommand, rightControl, mouseMiddle, mouseSideBack, mouseSideForward, off
    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "fn 🌐"
        case .fnShift: return "fn + ⇧ Shift"
        case .fnControl: return "fn + ⌃ Control"
        case .fnOption: return "fn + ⌥ Option"
        case .rightOption: return "右 ⌥ Option"
        case .rightCommand: return "右 ⌘ Command"
        case .rightControl: return "右 ⌃ Control"
        case .mouseMiddle: return "🖱️ 鼠标中键 (MouseButton2)"
        case .mouseSideBack: return "🖱️ 鼠标侧键后退 (MouseButton3)"
        case .mouseSideForward: return "🖱️ 鼠标侧键前进 (MouseButton4)"
        case .off: return "关闭"
        }
    }

    var slots: [Set<Int64>] {
        let fn: Set<Int64> = [63], shift: Set<Int64> = [56, 60], control: Set<Int64> = [59, 62], option: Set<Int64> = [58, 61]
        switch self {
        case .fn: return [fn]
        case .fnShift: return [fn, shift]
        case .fnControl: return [fn, control]
        case .fnOption: return [fn, option]
        case .rightOption: return [[61]]
        case .rightCommand: return [[54]]
        case .rightControl: return [[62]]
        case .mouseMiddle: return [[0x1002]]
        case .mouseSideBack: return [[0x1003]]
        case .mouseSideForward: return [[0x1004]]
        case .off: return []
        }
    }

    /// Slots are disjoint, so an exact-size match where every slot is hit is an exact chord match.
    func matches(_ pressed: Set<Int64>) -> Bool {
        let s = slots
        guard !s.isEmpty, pressed.count == s.count else { return false }
        return s.allSatisfy { !$0.isDisjoint(with: pressed) }
    }
}

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typ", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var models: URL { support.appendingPathComponent("models", isDirectory: true) }
    static var history: URL { support.appendingPathComponent("history.json") }
    static var apiKey: URL { support.appendingPathComponent("apikey") }
    static var whisperLog: URL { support.appendingPathComponent("whisper.log") }
    static var defaultModel: String { models.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path }
}

let speechLanguages: [(code: String, name: String)] = [
    ("auto", "自动检测"), ("zh", "中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"),
    ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"), ("ru", "Русский"), ("yue", "粤语"),
]

let translationLanguages = [
    "English", "简体中文", "繁體中文", "日本語", "한국어", "Français", "Deutsch", "Español",
    "Português", "Italiano", "Русский", "العربية", "ไทย", "Tiếng Việt", "Bahasa Indonesia",
]

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var dictateTrigger: HotkeyTrigger { didSet { d.set(dictateTrigger.rawValue, forKey: "dictateTrigger") } }
    @Published var translateTrigger: HotkeyTrigger { didSet { d.set(translateTrigger.rawValue, forKey: "translateTrigger") } }
    @Published var askTrigger: HotkeyTrigger { didSet { d.set(askTrigger.rawValue, forKey: "askTrigger") } }

    @Published var speechLanguage: String { didSet { d.set(speechLanguage, forKey: "speechLanguage") } }
    @Published var simplifiedChinese: Bool { didSet { d.set(simplifiedChinese, forKey: "simplifiedChinese") } }
    @Published var modelPath: String { didSet { d.set(modelPath, forKey: "modelPath") } }
    @Published var speechEngine: SpeechEngineKind { didSet { d.set(speechEngine.rawValue, forKey: "speechEngine") } }

    @Published var polishEnabled: Bool { didSet { d.set(polishEnabled, forKey: "polishEnabled") } }
    @Published var skipPolishShort: Bool { didSet { d.set(skipPolishShort, forKey: "skipPolishShort") } }
    @Published var skipPolishMaxChars: Int { didSet { d.set(skipPolishMaxChars, forKey: "skipPolishMaxChars") } }
    @Published var apiBaseURL: String { didSet { d.set(apiBaseURL, forKey: "apiBaseURL") } }
    @Published var apiModel: String { didSet { d.set(apiModel, forKey: "apiModel") } }
    @Published var apiKey: String { didSet { Self.writeKey(apiKey) } }

    @Published var translateTargets: [String] { didSet { d.set(translateTargets, forKey: "translateTargets") } }

    @Published var micUID: String { didSet { d.set(micUID, forKey: "micUID") } }
    @Published var sounds: Bool { didSet { d.set(sounds, forKey: "sounds") } }
    @Published var muteWhileDictating: Bool { didSet { d.set(muteWhileDictating, forKey: "muteWhileDictating") } }

    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    @Published var dictionary: [String] { didSet { d.set(dictionary, forKey: "dictionary") } }
    /// Dictionary entries Typ added by itself from the user's corrections.
    @Published var autoLearned: [String] { didSet { d.set(autoLearned, forKey: "autoLearned") } }
    /// Learned speech-recognition fixes: what the engine heard -> what the user meant.
    @Published var replacements: [String: String] { didSet { d.set(replacements, forKey: "replacements") } }

    @Published var autoLearn: Bool { didSet { d.set(autoLearn, forKey: "autoLearn") } }
    @Published var personalization: Bool { didSet { d.set(personalization, forKey: "personalization") } }
    @Published var deepContext: Bool { didSet { d.set(deepContext, forKey: "deepContext") } }
    @Published var richText: Bool { didSet { d.set(richText, forKey: "richText") } }
    @Published var askActions: Bool { didSet { d.set(askActions, forKey: "askActions") } }
    @Published var copyBeforeSend: Bool { didSet { d.set(copyBeforeSend, forKey: "copyBeforeSend") } }

    // System-level enhancements aligned with Typeless
    @Published var preserveClipboard: Bool { didSet { d.set(preserveClipboard, forKey: "preserveClipboard") } }
    @Published var bottomUpWebContext: Bool { didSet { d.set(bottomUpWebContext, forKey: "bottomUpWebContext") } }
    @Published var privacyProtection: Bool { didSet { d.set(privacyProtection, forKey: "privacyProtection") } }
    @Published var historyRetentionDays: Int { didSet { d.set(historyRetentionDays, forKey: "historyRetentionDays") } }

    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Typ: launch at login change failed: \(error)")
            }
        }
    }

    private init() {
        let d = UserDefaults.standard
        func trig(_ k: String, _ def: HotkeyTrigger) -> HotkeyTrigger { HotkeyTrigger(rawValue: d.string(forKey: k) ?? "") ?? def }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        dictateTrigger = trig("dictateTrigger", .fn)
        translateTrigger = trig("translateTrigger", .fnShift)
        askTrigger = trig("askTrigger", .fnControl)
        speechLanguage = d.string(forKey: "speechLanguage") ?? "auto"
        simplifiedChinese = bool("simplifiedChinese", true)
        modelPath = d.string(forKey: "modelPath") ?? Paths.defaultModel
        speechEngine = SpeechEngineKind(rawValue: d.string(forKey: "speechEngine") ?? "") ?? .sensevoice
        polishEnabled = bool("polishEnabled", true)
        skipPolishShort = bool("skipPolishShort", true)
        skipPolishMaxChars = d.object(forKey: "skipPolishMaxChars") == nil ? 20 : d.integer(forKey: "skipPolishMaxChars")
        apiBaseURL = d.string(forKey: "apiBaseURL") ?? "https://api.deepseek.com"
        apiModel = d.string(forKey: "apiModel") ?? "deepseek-chat"
        apiKey = Self.readKey()
        translateTargets = d.stringArray(forKey: "translateTargets") ?? ["English"]
        micUID = d.string(forKey: "micUID") ?? ""
        sounds = bool("sounds", true)
        muteWhileDictating = bool("muteWhileDictating", false)
        showInDock = bool("showInDock", true)
        dictionary = d.stringArray(forKey: "dictionary") ?? []
        autoLearned = d.stringArray(forKey: "autoLearned") ?? []
        replacements = (d.dictionary(forKey: "replacements") as? [String: String]) ?? [:]
        autoLearn = bool("autoLearn", true)
        personalization = bool("personalization", true)
        deepContext = bool("deepContext", true)
        richText = bool("richText", true)
        askActions = bool("askActions", true)
        copyBeforeSend = bool("copyBeforeSend", true)
        preserveClipboard = bool("preserveClipboard", true)
        bottomUpWebContext = bool("bottomUpWebContext", true)
        privacyProtection = bool("privacyProtection", true)
        historyRetentionDays = d.object(forKey: "historyRetentionDays") == nil ? 30 : d.integer(forKey: "historyRetentionDays")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func trigger(for mode: Mode) -> HotkeyTrigger {
        switch mode {
        case .dictate: return dictateTrigger
        case .translate: return translateTrigger
        case .ask: return askTrigger
        }
    }

    func mode(matching pressed: Set<Int64>) -> Mode? {
        Mode.allCases.first { trigger(for: $0).matches(pressed) }
    }

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    private static func readKey() -> String {
        (try? String(contentsOf: Paths.apiKey, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func writeKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { try? FileManager.default.removeItem(at: Paths.apiKey); return }
        try? k.write(to: Paths.apiKey, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.apiKey.path)
    }
}

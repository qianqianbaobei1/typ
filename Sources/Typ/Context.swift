import AppKit
import ApplicationServices

/// What Typ knows about where the text is going.
struct AppContext {
    var appName: String
    var bundleID: String
    var pid: pid_t
    var windowTitle: String?
    var url: String?
    /// Field content just before / after the cursor (excluding the selection).
    var textBefore: String?
    var textAfter: String?
    /// Other text on screen in the focused window, used for spelling names and terms.
    var visibleText: String?
    var isSecureField = false
    var element: AXUIElement?

    private static let richApps: Set<String> = [
        "com.apple.Notes", "com.apple.mail", "com.apple.iWork.Pages", "com.apple.iWork.Keynote", "com.apple.TextEdit",
        "com.microsoft.Word", "com.microsoft.Outlook", "com.microsoft.Powerpoint", "com.microsoft.onenote.mac",
        "notion.id", "com.electron.lark", "com.bytedance.lark", "com.tencent.WeWorkMac", "com.alibaba.DingTalkMac",
        "com.evernote.Evernote", "com.yinxiang.Mac", "com.craft.craft",
    ]
    private static let richHosts = [
        "docs.google.com", "mail.google.com", "notion.so", "notion.site", "feishu.cn", "larksuite.com",
        "outlook.live.com", "outlook.office.com", "office.com", "yuque.com", "docs.qq.com", "atlassian.net", "kdocs.cn",
    ]

    /// Whether pasting HTML/RTF here yields real formatting rather than garbage.
    var acceptsRichText: Bool {
        if Self.richApps.contains(bundleID) { return true }
        let n = appName.lowercased()
        if n.contains("飞书") || n.contains("lark") || n.contains("notion") { return true }
        if let url, let host = URL(string: url)?.host?.lowercased() {
            return Self.richHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        return false
    }

    /// Whether this is a terminal or command-line interface.
    var isTerminalApp: Bool {
        let terminals: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.github.wez.wezterm",
            "dev.warp.Warp-GDK", "co.zeit.hyper", "com.mitchellh.ghostty", "net.kovidgoyal.kitty"
        ]
        return terminals.contains(bundleID) || appName.lowercased().contains("terminal")
    }
}

enum ContextReader {
    /// Privacy blacklist: sensitive password managers, financial spreadsheets, private messaging and code editors.
    /// Aligns directly with official Typeless 2.8.3 built-in vp.app_blacklist.macos.
    private static let privacyBlacklist: Set<String> = [
        "com.agilebits.onepassword", "com.1password.1password",
        "com.bitwarden.desktop", "net.keepassxc.keepassxc",
        "com.apple.keychainaccess",
        "com.tencent.xinWeChat",        // 微信：保护私密聊天
        "com.microsoft.Excel",          // Excel：保护商业表格与财报
        "com.kingsoft.wpsoffice.mac",   // WPS Office
        "com.sublimetext.4",
        "dev.zed.Zed"
    ]

    /// URL prefixes that should not capture accessibility text (avoiding nested canvas / iframe freezes).
    /// Aligns with official Typeless 2.8.3 built-in vp.url_blacklist.prefix.
    private static let urlBlacklist = [
        "https://docs.google.com/document/d",
        "https://docs.qq.com/doc/",
        "https://docs.qq.com/sheet/"
    ]

    static func isBlacklisted(bundleID: String, url: String?) -> Bool {
        if privacyBlacklist.contains(bundleID) { return true }
        if let u = url?.lowercased() {
            return urlBlacklist.contains { u.starts(with: $0.lowercased()) }
        }
        return false
    }

    /// Cheap, main-thread snapshot taken the moment recording starts.
    @MainActor
    static func basic() -> AppContext {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        var ctx = AppContext(appName: app?.localizedName ?? "Unknown", bundleID: app?.bundleIdentifier ?? "", pid: pid)
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        if let el = AX.element(sys, kAXFocusedUIElementAttribute) { ctx.element = el }
        return ctx
    }

    /// Bottom-up URL and Web Title traversal starting directly from the focused input element.
    /// Traverses up through parent nodes to find the authentic AXWebArea container, bypassing tab/iframe nesting issues.
    static func findWebInfoByTraversingUp(from element: AXUIElement?) -> (url: String?, title: String?) {
        guard let start = element else { return (nil, nil) }
        var current: AXUIElement? = start
        var steps = 0
        while let el = current, steps < 30 {
            steps += 1
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" || role == "AXScrollArea" {
                if let rawURL = AX.value(el, "AXURL") {
                    let urlStr = (rawURL as? URL)?.absoluteString ?? (rawURL as? String)
                    let titleStr = AX.string(el, kAXTitleAttribute)
                    if let u = urlStr, !u.isEmpty {
                        return (u, titleStr)
                    }
                }
            }
            if let parent = AX.element(el, kAXParentAttribute) {
                current = parent
            } else {
                break
            }
        }
        return (nil, nil)
    }

    /// Slower Accessibility reads; run off the main thread while the user is speaking.
    static func enrich(_ base: AppContext, deep: Bool) -> AppContext {
        var ctx = base
        guard ctx.pid != 0 else { return ctx }

        // Privacy guard: if targeting a blacklisted sensitive app, refuse to capture text
        if isBlacklisted(bundleID: ctx.bundleID, url: ctx.url) {
            ctx.isSecureField = true
            return ctx
        }

        let appEl = AXUIElementCreateApplication(ctx.pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        
        // Chromium/Electron apps: activate both manual accessibility and enhanced UI trees
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        let window = AX.element(appEl, kAXFocusedWindowAttribute)
        if let window {
            ctx.windowTitle = AX.string(window, kAXTitleAttribute)
            // Also set enhanced user interface directly on the focused window (matching Typeless setFocusedWindowEnhancedUserInterface)
            AXUIElementSetAttributeValue(window, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        if ctx.element == nil { ctx.element = AX.element(appEl, kAXFocusedUIElementAttribute) }

        if let el = ctx.element {
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            let subrole = AX.string(el, kAXSubroleAttribute) ?? ""
            ctx.isSecureField = role == "AXSecureTextField" || subrole == "AXSecureTextField"
            if deep && !ctx.isSecureField, let value = AX.string(el, kAXValueAttribute), !value.isEmpty {
                let ns = value as NSString
                var range = CFRange(location: ns.length, length: 0)
                if let r = AX.range(el, kAXSelectedTextRangeAttribute), r.location != kCFNotFound,
                   r.location + r.length <= ns.length {
                    range = r
                }
                let before = ns.substring(to: range.location)
                let after = ns.substring(from: range.location + range.length)
                ctx.textBefore = before.isEmpty ? nil : String(before.suffix(1200))
                ctx.textAfter = after.isEmpty ? nil : String(after.prefix(400))
            }

            // Bottom-up traversal first: locate current tab's URL and title accurately
            let webInfo = findWebInfoByTraversingUp(from: el)
            if let u = webInfo.url {
                ctx.url = u
                if let t = webInfo.title, !t.isEmpty { ctx.windowTitle = t }
            }
        }

        if let window, !ctx.isSecureField {
            var scan = AX.Scan(budgetNodes: deep ? 1200 : 300, budgetChars: deep ? 2500 : 0, skip: ctx.element,
                               deadline: Date().addingTimeInterval(deep ? 0.6 : 0.2))
            scan.walk(window, depth: 0)
            if ctx.url == nil { ctx.url = scan.url }
            if deep {
                let text = scan.texts.joined(separator: "\n")
                ctx.visibleText = text.isEmpty ? nil : text
            }
        }
        return ctx
    }
}

/// Small Accessibility helpers.
enum AX {
    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? { value(el, attr) as? String }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func range(_ el: AXUIElement, _ attr: String) -> CFRange? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (value(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Finds an editable element in the app's focused window whose value contains `text`.
    /// Used when the app doesn't report a focused element (e.g. WeChat). Also returns a short
    /// summary of the roles seen, for diagnostics.
    static func findField(pid: pid_t, containing text: String) -> (AXUIElement?, String) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else {
            return (nil, "no window")
        }
        let needle = String(text.prefix(30))
        var roles: [String: Int] = [:]
        var budget = 4000
        let deadline = Date().addingTimeInterval(1.5)
        var found: AXUIElement?
        var queue = [window]
        while !queue.isEmpty, found == nil, budget > 0, Date() < deadline {
            let el = queue.removeFirst()
            budget -= 1
            let role = string(el, kAXRoleAttribute) ?? "?"
            roles[role, default: 0] += 1
            if role != "AXStaticText", let v = string(el, kAXValueAttribute), v.contains(needle) {
                found = el
                break
            }
            queue.append(contentsOf: children(el))
        }
        let summary = roles.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        return (found, "\(4000 - budget) nodes: \(summary)")
    }

    /// Breadth-limited walk collecting static text and the page URL of a web area.
    struct Scan {
        var budgetNodes: Int
        var budgetChars: Int
        let skip: AXUIElement?
        let deadline: Date
        var texts: [String] = []
        var url: String?
        private var chars = 0
        private var seen = Set<String>()

        init(budgetNodes: Int, budgetChars: Int, skip: AXUIElement?, deadline: Date) {
            self.budgetNodes = budgetNodes
            self.budgetChars = budgetChars
            self.skip = skip
            self.deadline = deadline
        }

        mutating func walk(_ el: AXUIElement, depth: Int) {
            guard budgetNodes > 0, depth < 40 else { return }
            budgetNodes -= 1
            if budgetNodes % 50 == 0 && Date() > deadline { budgetNodes = 0; return }
            if let skip, CFEqual(el, skip) { return }
            let role = string(el, kAXRoleAttribute) ?? ""
            if role == "AXSecureTextField" { return }
            if role == "AXWebArea", url == nil, let u = value(el, "AXURL") {
                url = (u as? URL)?.absoluteString ?? (u as? String)
            }
            if budgetChars > 0, chars < budgetChars, role == "AXStaticText" || role == "AXHeading" || role == "AXLink" {
                let t = (string(el, kAXValueAttribute) ?? string(el, kAXTitleAttribute) ?? string(el, kAXDescriptionAttribute) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count >= 2, !seen.contains(t) {
                    seen.insert(t)
                    let piece = String(t.prefix(300))
                    texts.append(piece)
                    chars += piece.count
                }
            }
            if budgetChars > 0 && chars >= budgetChars && url != nil { return }
            for child in children(el) {
                walk(child, depth: depth + 1)
                if budgetNodes <= 0 { return }
            }
        }
    }
}

import AppKit
import AVFoundation
import Combine
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case home, history, dictionary, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "首页"
        case .history: return "历史记录"
        case .dictionary: return "词典"
        case .settings: return "设置"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class Navigation: ObservableObject {
    @Published var tab: Tab = .home
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = Settings.shared
    let history = HistoryStore()
    let whisper = WhisperEngine()
    let nav = Navigation()
    let style = StyleProfile()
    private(set) var controller: Controller!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = Controller(history: history, whisper: whisper, style: style)
        setupMainMenu()
        applyDockPolicy()
        settings.$showInDock.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyDockPolicy() }
        }.store(in: &bag)

        setupStatusItem()
        whisper.start(kind: settings.speechEngine, modelPath: settings.modelPath)

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("local.typ.app.showWindow"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showWindow(nil)
            }
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        let tapOK = controller.hotkeys.start()
        Log.write("launch: mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) ax=\(Permissions.accessibility) input=\(Permissions.inputMonitoring) tap=\(tapOK)")
        if !tapOK {
            Permissions.requestInputMonitoring()
        }
        if !Permissions.accessibility {
            Permissions.requestAccessibility()
        }
        // The event tap can only be created once Input Monitoring is granted; keep retrying.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.controller.hotkeys.isRunning else { return }
                if self.controller.hotkeys.start() { Log.write("hotkey tap started (input=\(Permissions.inputMonitoring))") }
            }
        }

        if !UserDefaults.standard.bool(forKey: "launchedBefore") || !Permissions.accessibility || !Permissions.inputMonitoring {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            showWindow(.home)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        whisper.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func applyDockPolicy() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    // MARK: - Window

    func showWindow(_ tab: Tab?) {
        if let tab { nav.tab = tab }
        if window == nil {
            let root = MainView()
                .environmentObject(settings)
                .environmentObject(history)
                .environmentObject(whisper)
                .environmentObject(nav)
                .environmentObject(style)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Typ"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: root)
            w.setFrameAutosaveName("TypMain")
            if !w.setFrameUsingName("TypMain") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Main menu

    /// Text fields only get ⌘C/⌘V/⌘A/⌘Z through these menu items, so the app needs an Edit menu.
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("设置…", #selector(openSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 Typ", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(item("退出 Typ", #selector(quit), "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = createTrayIcon()
            button.imagePosition = .imageOnly
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func createTrayIcon() -> NSImage {
        let img = NSImage()
        var added = false
        if let url1x = Bundle.main.url(forResource: "tray", withExtension: "png"),
           let data1x = try? Data(contentsOf: url1x),
           let rep1x = NSBitmapImageRep(data: data1x) {
            img.addRepresentation(rep1x)
            added = true
        }
        if let url2x = Bundle.main.url(forResource: "tray@2x", withExtension: "png"),
           let data2x = try? Data(contentsOf: url2x),
           let rep2x = NSBitmapImageRep(data: data2x) {
            img.addRepresentation(rep2x)
            added = true
        }
        if added {
            img.size = NSSize(width: 16, height: 16)
            img.isTemplate = true
            return img
        }
        let sf = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Typ") ?? NSImage()
        sf.isTemplate = true
        return sf
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: "语音引擎（\(whisper.kind == .sensevoice ? "SenseVoice" : "Whisper")）：\(whisper.status.label)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item("打开 Typ", #selector(openHome), "o"))
        menu.addItem(item("历史记录", #selector(openHistory), "y"))
        menu.addItem(item("添加词语到词典…", #selector(openDictionary), ""))
        menu.addItem(item("设置…", #selector(openSettings), ","))

        let micItem = NSMenuItem(title: "选择麦克风", action: nil, keyEquivalent: "")
        let mics = NSMenu()
        let def = item("系统默认", #selector(selectMic(_:)), "")
        def.representedObject = ""
        def.state = settings.micUID.isEmpty ? .on : .off
        mics.addItem(def)
        for d in AudioDevices.inputDevices() {
            let i = item(d.name, #selector(selectMic(_:)), "")
            i.representedObject = d.uid
            i.state = settings.micUID == d.uid ? .on : .off
            mics.addItem(i)
        }
        micItem.submenu = mics
        menu.addItem(micItem)

        menu.addItem(.separator())
        menu.addItem(item("退出 Typ", #selector(quit), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openHome() { showWindow(.home) }
    @objc private func openHistory() { showWindow(.history) }
    @objc private func openDictionary() { showWindow(.dictionary) }
    @objc private func openSettings() { showWindow(.settings) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func selectMic(_ sender: NSMenuItem) { settings.micUID = sender.representedObject as? String ?? "" }
}

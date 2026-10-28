// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Typ",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Typ", path: "Sources/Typ")
    ]
)

// =========================================================================================
// 🚨 核心架构规范与改动红线（后续进行任何代码改动前必须先阅读）
// =========================================================================================
/*
 1. 启动生命周期与 AVAudioEngine 致命异常防范（绝对红线）：
    - 严禁在 AudioRecorder.init() 或 resetEngine() 中无条件调用 AVAudioEngine.prepare()。
    - 根因：当系统麦克风权限尚未就绪或未授权时，AVAudioEngine 内部访问 inputNode 会抛出底层 Objective-C 异常。
      该异常在 Swift 中无法使用 do-catch 捕获，会直接硬中断当前执行线程（或截断 applicationDidFinishLaunching 执行流）。
    - 致命后果：由于 applicationDidFinishLaunching 在半途夭折，后续的：
        * setupStatusItem()（系统菜单栏托盘图标）
        * hotkeys.start()（全局 Fn / 快捷键监听）
        * DistributedNotificationCenter（唤醒主窗口通知）
        * whisper.start()（本地语音引擎）
      全部没有被执行！导致应用陷入“点不开、菜单栏无图标、通知无法唤醒”的假死状态。
    - 正确做法：
        * 初始化与重置阶段只做对象分配，不调用 engine.prepare()；
        * 必须在 AudioRecorder.start(deviceUID:) 录音前显式检查：
          AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
          若未授权则抛出可读的 TypError，严禁让引擎在无授权状态下访问底层音频硬件。

 2. 编译打包与本地代码签名规范：
    - 严禁手动编译后用 ad-hoc（无名/临时签名）直接替换覆盖 /Applications/Typ.app。
    - macOS TCC 安全机制对 ad-hoc 签名的二进制每次构建变更其 CDHash，会导致系统的辅助功能（Accessibility）
      和输入监控（Input Monitoring）权限静默失效。
    - 后续任何编译安装必须严格执行：
        bash scripts/install.sh
      该脚本会自动查找并使用 "Typ Local Signing" 证书进行稳定签名，确保系统权限在多次重建时有效保留。
    - 若开发调试中遇到热键监听无效，先前往：
      系统设置 → 隐私与安全性 → 辅助功能 & 输入监控，将 Typ 开关关闭一次再重新开启以刷新系统绑定。
*/

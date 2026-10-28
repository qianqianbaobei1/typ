# Typ 开发与改动核心规范（改动代码前必读）

## 1. 启动生命周期与 AVAudioEngine 致命异常防范（绝对红线）
- **严禁在 `AudioRecorder.init()` 或 `resetEngine()` 中无条件调用 `AVAudioEngine.prepare()`**。
- **根因分析**：
  在系统麦克风未授权或权限未就绪时，`AVAudioEngine` 访问底层 `inputNode` 会直接抛出底层的 Objective-C 异常。该异常在 Swift 中无法使用 `do-catch` 捕获，会直接截断 `applicationDidFinishLaunching`。
- **致命后果**：
  `applicationDidFinishLaunching` 执行流在中间中断，导致后续的：
  - `setupStatusItem()`（菜单栏托盘图标）
  - `hotkeys.start()`（全局 Fn 热键监听）
  - `DistributedNotificationCenter`（唤醒窗口通知）
  - `whisper.start()`（本地语音引擎）
  全部未被执行，表现为**“点不开、菜单栏无图标、唤醒不了”**。
- **代码规范**：
  - 初始化与重置阶段只做内存分配，不调用 `engine.prepare()`。
  - 启动录音前必须显式检查麦克风权限：
    ```swift
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        throw TypError.message("请在系统设置中允许 Typ 使用麦克风")
    }
    ```

## 2. 编译打包与本地代码签名规范
- **严禁手动直接覆盖 ad-hoc 签名的 `/Applications/Typ.app`**。
  ad-hoc 签名每次编译的 CDHash 都会变动，macOS TCC 权限机制会将旧的授权置为无效（表现为设置里虽然显示勾选，但底层实际拒绝事件监听）。
- **必须通过脚本安装部署**：
  ```bash
  bash scripts/install.sh
  ```
  该脚本会查找并使用稳定的 `Typ Local Signing` 证书进行签名，使辅助功能和输入监控权限跨重建保持有效。
- **权限恢复指引**：
  如果重新编译后出现热键无反应：前往 **系统设置 → 隐私与安全性 → 辅助功能 & 输入监控**，找到 Typ 关闭一次再重新开启即可重新绑定。

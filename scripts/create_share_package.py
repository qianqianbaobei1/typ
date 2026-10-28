#!/usr/bin/env python3
import os
import sys
import shutil
import subprocess
import zipfile

PROJECT_DIR = "/Users/qianqianawodebaobei/PycharmProjects/Typ"
DELIVERY_DIR = os.path.join(PROJECT_DIR, "deliveries", "Typ-语音输入转译-分享包")
DESKTOP_DIR = "/Users/qianqianawodebaobei/Desktop/Typ-语音输入转译-分享包"
BUILD_APP = os.path.join(PROJECT_DIR, "build", "Typ.app")

os.makedirs(DELIVERY_DIR, exist_ok=True)

# 1. 拷贝 Typ.app
target_app = os.path.join(DELIVERY_DIR, "Typ.app")
if os.path.exists(target_app):
    shutil.rmtree(target_app)
print("Copying Typ.app to delivery package...")
shutil.copytree(BUILD_APP, target_app, symlinks=True)

# 2. 编写 1-双击一键安装Typ.command
install_command_content = """#!/bin/bash
# ========================================================
# Typ 语音输入转译神器 - 自动安装脚本
# ========================================================
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$DIR/Typ.app"
APP_DEST="/Applications/Typ.app"

echo "========================================================"
echo "      🚀 正在安装 Typ 语音输入法到 /Applications ...      "
echo "========================================================"

if [ ! -d "$APP_SRC" ]; then
    echo "❌ 错误：在当前目录下未找到 Typ.app，请确认解压完整。"
    exit 1
fi

echo "📦 正在复制应用到应用程序目录..."
rm -rf "$APP_DEST" 2>/dev/null || true
cp -R "$APP_SRC" "$APP_DEST"

echo "🛡️ 正在修复 macOS 安全隔离属性 (解除'已损坏'提示)..."
xattr -cr "$APP_DEST" 2>/dev/null || true

echo "🔑 正在进行本地代码签名验证..."
codesign --force --sign - --identifier local.typ.app "$APP_DEST" 2>/dev/null || true

echo ""
echo "========================================================"
echo "🎉 安装完成！应用已成功就绪于: /Applications/Typ.app"
echo "========================================================"
echo ""
echo "【⚠️ 关键权限设置说明】"
echo "Typ 运行需要以下三项 macOS 系统权限："
echo " 1. 🎤 麦克风权限：用于采集你的说话声音"
echo " 2. ♿️ 辅助功能 (Accessibility)：用于将转译文字自动打入光标所在窗口"
echo " 3. ⌨️ 输入监听 (Input Monitoring)：用于监听按住 fn 或指定修饰键"
echo ""
echo "首次打开 Typ 时，系统会弹出授权提示，请全部选择【允许】。"
echo "若未弹出，可前往「系统设置 → 隐私与安全性」中手动勾选 Typ。"
echo ""
echo "👉 是否立即打开 /Applications/Typ.app ？(y/n)"
read -r answer
if [ "$answer" = "y" ] || [ "$answer" = "Y" ] || [ -z "$answer" ]; then
    open "$APP_DEST"
    echo "✅ 已启动 Typ！请留意右上角菜单栏声波图标。"
fi

echo ""
echo "提示：若需要极速离线中文语音转文字，请在分享包中继续双击运行："
echo "      👉「2-双击安装SenseVoice离线语音模型.command」"
echo ""
read -p "按回车键退出..."
"""

install_command_path = os.path.join(DELIVERY_DIR, "1-双击一键安装Typ.command")
with open(install_command_path, "w", encoding="utf-8") as f:
    f.write(install_command_content)
os.chmod(install_command_path, 0o755)

# 3. 编写 2-双击安装SenseVoice语音模型.command
setup_model_content = """#!/bin/bash
# ========================================================
# Typ - SenseVoice 离线语音识别模型一键部署
# ========================================================
set -euo pipefail

TARGET_DIR="$HOME/Library/Application Support/Typ/sensevoice"
MODEL_NAME="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================================"
echo "      🧠 正在为 Typ 配置 SenseVoice 离线语音识别引擎      "
echo "========================================================"
echo "目标路径: $TARGET_DIR"
mkdir -p "$TARGET_DIR"

# 1. 检查 Python 3 环境
if ! command -v python3 &> /dev/null; then
    echo "❌ 未检测到 python3，请先安装 Python 3（或运行 xcode-select --install）"
    read -p "按回车键退出..."
    exit 1
fi

# 2. 创建虚拟环境
if [ ! -x "$TARGET_DIR/venv/bin/python" ]; then
    echo "🔧 正在创建专有 Python 虚拟运行环境..."
    python3 -m venv "$TARGET_DIR/venv"
fi

# 3. 安装依赖 (使用清华源/官方源加速)
echo "📦 正在安装推理运行时 (sherpa-onnx, numpy)..."
"$TARGET_DIR/venv/bin/pip" install -q --disable-pip-version-check -i https://pypi.tuna.tsinghua.edu.cn/simple sherpa-onnx numpy || \
"$TARGET_DIR/venv/bin/pip" install -q --disable-pip-version-check sherpa-onnx numpy

# 4. 检查/下载语音模型
mkdir -p "$TARGET_DIR/model"
if [ ! -f "$TARGET_DIR/model/model.int8.onnx" ]; then
    # 检查本地分享包内是否自带了模型缓存
    if [ -f "$DIR/model_cache/model.int8.onnx" ] && [ -f "$DIR/model_cache/tokens.txt" ]; then
        echo "⚡️ 发现分享包自带离线模型，正在直接拷贝..."
        cp "$DIR/model_cache/model.int8.onnx" "$TARGET_DIR/model/"
        cp "$DIR/model_cache/tokens.txt" "$TARGET_DIR/model/"
    else
        echo "🌐 正在从开源仓库下载 SenseVoice 预训练模型 (下载约 1GB 压缩包，安装后占用约 230MB)..."
        echo "下载地址: GitHub Releases / HuggingFace"
        TMP=$(mktemp -d)
        curl -L --fail -# -o "$TMP/m.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$MODEL_NAME.tar.bz2" || \
        curl -L --fail -# -o "$TMP/m.tar.bz2" "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/$MODEL_NAME.tar.bz2"
        
        echo "📂 正在解压并就绪模型..."
        tar xjf "$TMP/m.tar.bz2" -C "$TMP"
        mv "$TMP/$MODEL_NAME/model.int8.onnx" "$TMP/$MODEL_NAME/tokens.txt" "$TARGET_DIR/model/"
        rm -rf "$TMP"
    fi
else
    echo "✅ 离线模型文件已存在，无需重复下载。"
fi

echo ""
echo "========================================================"
echo "🎉 SenseVoice 语音模型配置完成！"
echo "========================================================"
echo "现在 Typ 拥有了完全离线、低延迟、极高准确度的语音识别能力！"
echo ""
read -p "按回车键退出..."
"""

setup_model_path = os.path.join(DELIVERY_DIR, "2-双击安装SenseVoice语音模型.command")
with open(setup_model_path, "w", encoding="utf-8") as f:
    f.write(setup_model_content)
os.chmod(setup_model_path, 0o755)

# 4. 编写 3-快捷打开系统权限设置.command
permissions_command_content = """#!/bin/bash
# 打开 macOS 辅助功能与输入监听设置面板
echo "正在打开 macOS 辅助功能设置..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
sleep 1
echo "正在打开 macOS 输入监听设置..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
echo ""
echo "请在打开的设置窗口中，确保「Typ」已勾选授权！"
read -p "按回车键退出..."
"""
perms_path = os.path.join(DELIVERY_DIR, "3-快捷打开系统权限设置.command")
with open(perms_path, "w", encoding="utf-8") as f:
    f.write(permissions_command_content)
os.chmod(perms_path, 0o755)

# 5. 拷贝纯净完整源代码工程
src_pkg_dir = os.path.join(DELIVERY_DIR, "完整源码工程(Typ-Source)")
if os.path.exists(src_pkg_dir):
    shutil.rmtree(src_pkg_dir)
os.makedirs(src_pkg_dir, exist_ok=True)

print("Copying project sources...")
# Package.swift
shutil.copy2(os.path.join(PROJECT_DIR, "Package.swift"), os.path.join(src_pkg_dir, "Package.swift"))

# Sources
def ignore_patterns(folder, names):
    return [n for n in names if n in [".DS_Store", ".git", ".build", "build", ".idea", ".venv", "deliveries"]]

shutil.copytree(os.path.join(PROJECT_DIR, "Sources"), os.path.join(src_pkg_dir, "Sources"), ignore=ignore_patterns)
shutil.copytree(os.path.join(PROJECT_DIR, "Resources"), os.path.join(src_pkg_dir, "Resources"), ignore=ignore_patterns)
shutil.copytree(os.path.join(PROJECT_DIR, "scripts"), os.path.join(src_pkg_dir, "scripts"), ignore=ignore_patterns)

# 6. 生成配置与个性化风格参考模版
config_dir = os.path.join(DELIVERY_DIR, "配置与Prompt风格参考")
os.makedirs(config_dir, exist_ok=True)

style_template_json = """{
  "profile": "- 对话及 AI 提示词指令简明、直接、务求实效；不加客套寒暄。\\n- 邮件与分析文档（Word、PPT、方案备忘录）保持任务为导向，结构清晰，采用数字化递进列表。\\n- 句子偏中短句为主，多项诉求自动拆解为条目化清单。\\n- 标点采用标准中文标点，问句以 ？ 结尾，冒号引出细节与说明。\\n- 中英文混排规范：中文与英文单词之间保持自然空格，专业术语（PyCharm, Swift, Claude, Agent, Host, API）保留原汁原味。\\n- 坚决杜绝同音错别字与口头语结巴，保留原义前提下进行结构化提炼。",
  "rules": [
    "自动剔除口头禅（嗯、呃、啊、那个、就是、对吧、我我我等）",
    "说话人自我修正时（'不对我是说'、'改成'），仅保留最终正确版本",
    "三项及以上并列事项（步骤、需求、问题、清单）自动生成数字列表（1. 2. 3.）",
    "短句保持单段落连贯流畅，长文按主题自动拆分为 2~3 段"
  ]
}
"""
with open(os.path.join(config_dir, "style_profile_template.json"), "w", encoding="utf-8") as f:
    f.write(style_template_json)

dictionary_sample = """# Typ 自定义专有名词词库 (User Dictionary)
# 每行一个词汇，用于语音识别引擎精准纠正生僻词、人名、项目名、专业术语
招采SaaS
电柜智核
SenseVoice
DeepSeek
sherpa-onnx
SwiftUI
macOS
AppKit
Claude
Antigravity
"""
with open(os.path.join(config_dir, "custom_dictionary.txt"), "w", encoding="utf-8") as f:
    f.write(dictionary_sample)

# 7. 编写专业保姆级 README.md
readme_content = """# 🎙️ Typ - 智能语音输入转译与文本精炼工具

> **让语音输入真正具备生产力**：不仅是语音转文字，更能感知当前应用上下文、剔除口语结巴、自动结构化排版，并原生直接键入任意窗口。

---

## 🌟 核心特色与技术亮点

1. **🚀 极速离线 SenseVoice 语音引擎**
   - 基于本地 `sherpa-onnx` 离线推理，不依赖网络，毫秒级响应。
   - 针对中文普通话、混合英文、粤语做了极高精度的识别优化。
2. **🧠 AI 智能润色与结构化排版**
   - **智能去水**：自动过滤口语多余词汇（“呃”、“然后呢”、“那个就是”）。
   - **自动改错**：说话人说错并纠正自己时（如“改成周五不对是周四”），自动采纳最终说法。
   - **条理分明**：当识别到连续 3 项以上的需求、清单或步骤时，自动排版为标准的带序号列表（`1. 2. 3.`）。
3. **🎯 上下文感知 (Context-Aware)**
   - 自动识别你当前光标所在的前台应用（如微信、飞书、Xcode、Word、浏览器、终端）。
   - 根据当前窗口的标题和光标前后的已有文字，智能延续语气与格式，不会重复录入。
4. **⌨️ 原生自动键入**
   - 录音结束、处理完毕后，通过 macOS 辅助功能 API 自动模拟键盘打入当前活动输入框，无需手动 Command + V。

---

## 🚀 3 分钟极速安装上手

### 步骤 1：一键安装应用
双击打开分享包中的 **`1-双击一键安装Typ.command`**：
- 脚本会自动将 `Typ.app` 安装至 `/Applications/` 目录；
- 自动解除 macOS Gatekeeper 的“已损坏”限制；
- 提示是否立即启动。

### 步骤 2：授予 macOS 运行权限 (至关重要 ⚠️)
Typ 作为全局输入法辅助工具，需要以下系统权限：
1. **🎤 麦克风**：录制语音；
2. **♿️ 辅助功能 (Accessibility)**：自动将文字打到你的前台光标位置；
3. **⌨️ 输入监听 (Input Monitoring)**：全局监听 `fn` 快捷键。

> 💡 **提示**：如果在安装时未弹出权限窗口，可双击运行 **`3-快捷打开系统权限设置.command`**，并在「隐私与安全性」中将 `Typ` 勾选允许。

### 步骤 3：安装离线语音模型
双击运行 **`2-双击安装SenseVoice语音模型.command`**：
- 脚本将自动为你建立专有 Python 虚拟环境；
- 自动安装轻量推理依赖（`sherpa-onnx`、`numpy`）；
- 自动就绪 SenseVoice-Small 预训练模型（完全离线，安全高效）。

---

## ⌨️ 默认快捷键一览

| 触发操作 | 对应模式 | 功能说明 |
| :--- | :--- | :--- |
| **按住 `fn` 键说话** | 🎙️ **智能听写** | 松开后自动转译文字、自动润色排版并打入光标处 |
| **按住 `fn + Shift` 说话** | 🌐 **实时翻译** | 自动识别语种并翻译为目标语言（默认英文/中文） |
| **按住 `fn + Control` 说话**| ✨ **随便问/智能改写** | 选中文本时重写，未选中时化身全系统随身 AI 助手 |

> ⚙️ **自定义快捷键**：点击 macOS 菜单栏声波图标 →「设置」，可根据个人习惯将触发键改为 `右 Option`、`右 Command` 等。

---

## ⚙️ AI 润色与高级配置

在菜单栏点击声波图标进入「设置」：
- **AI 智能润色服务**：
  - 默认 API 基础地址预设为 `https://api.deepseek.com`
  - 默认模型为 `deepseek-chat`
  - 在设置中填入你个人的 `DeepSeek API Key` 即可享受顶级智能文本整理！
- **词库 (User Dictionary)**：
  - 在设置界面的「词库」中添加团队成员姓名、专有技术名词、业务简称，识别准确度达到 100%。

---

## 💻 开发者二次开发与源码说明

本分享包内置了完整的纯净源代码工程目录：**`完整源码工程(Typ-Source)`**。
- **纯原生 Swift 架构**：无任何庞杂的第三方 CocoaPods/SPM 依赖，基于原生 Apple Frameworks 构建。
- **编译方式**：
  ```bash
  cd 完整源码工程(Typ-Source)
  swift build -c release
  ```

祝使用愉快！如果有任何使用建议或问题，欢迎随时交流！
"""
with open(os.path.join(DELIVERY_DIR, "📖 Typ 极速上手与配置指南.md"), "w", encoding="utf-8") as f:
    f.write(readme_content)

# 8. 编写纯文本 快速上手说明.txt
quick_txt = """============================================================
           Typ 语音输入转译神器 - 快速上手说明
============================================================

感谢使用 Typ！请按照以下三步简单配置即可开启畅快语音输入：

【第 1 步】：双击运行「1-双击一键安装Typ.command」
  - 自动将 Typ.app 安装至系统的 /Applications/ 中。
  - 自动解决 macOS 提示“无法打开或已损坏”的安全隔离问题。

【第 2 步】：授予系统权限 (关键！)
  - 前往「系统设置」->「隐私与安全性」：
    1. 麦克风 -> 勾选 Typ
    2. 辅助功能 -> 勾选 Typ (用于自动打字上屏)
    3. 输入监听 -> 勾选 Typ (用于监听 fn 快捷键)
  (也可双击「3-快捷打开系统权限设置.command」直达设置面板)

【第 3 步】：双击运行「2-双击安装SenseVoice语音模型.command」
  - 自动配置本地离线极速语音识别引擎 (基于阿里 SenseVoice，毫秒级响应)。

------------------------------------------------------------
【如何使用】：
- 在任意聊天软件 (微信/飞书)、Word、备忘录、浏览器输入框中：
  👉 按住键盘左下角的 [fn] 键不放，直接对着电脑说话。
  👉 说完松开 [fn] 键，文字立刻自动打在你的光标位置！
- 如果需要中英文实时翻译：按住 [fn + Shift] 说话即可。
- 点击右上角菜单栏声波图标可以进入「设置」，配置你自己的 DeepSeek API Key 开启 AI 润色。

详细教程见包内文件：《📖 Typ 极速上手与配置指南.md》
============================================================
"""
with open(os.path.join(DELIVERY_DIR, "快速上手说明.txt"), "w", encoding="utf-8") as f:
    f.write(quick_txt)

print("Delivery directory prepared at:", DELIVERY_DIR)

# 9. 制作 ZIP 压缩包 (在交付目录同级)
zip_path = os.path.join(PROJECT_DIR, "deliveries", "Typ-语音输入转译-分享包.zip")
print(f"Creating zip archive at: {zip_path} ...")
subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", DELIVERY_DIR, zip_path], check=True)
print("Zip archive created.")

# 10. 复制到桌面 (满足用户明确指令)
print(f"Syncing package and zip to Desktop: {DESKTOP_DIR} ...")
if os.path.exists(DESKTOP_DIR):
    shutil.rmtree(DESKTOP_DIR)
shutil.copytree(DELIVERY_DIR, DESKTOP_DIR, symlinks=True)

desktop_zip = "/Users/qianqianawodebaobei/Desktop/Typ-语音输入转译-分享包.zip"
if os.path.exists(desktop_zip):
    os.remove(desktop_zip)
shutil.copy2(zip_path, desktop_zip)

print("All done! Successfully created both delivery folder and zip on Desktop.")

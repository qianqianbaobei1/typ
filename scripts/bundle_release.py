#!/usr/bin/env python3
import os
import sys
import shutil
import subprocess

PROJECT_DIR = "/Users/qianqianawodebaobei/PycharmProjects/Typ"
BUILD_DIR = os.path.join(PROJECT_DIR, "build")
APP_DIR = os.path.join(BUILD_DIR, "Typ.app")

os.makedirs(BUILD_DIR, exist_ok=True)

# 1. 确保图标存在
icon_path = os.path.join(BUILD_DIR, "AppIcon.icns")
if not os.path.exists(icon_path):
    existing_app_icon = "/Applications/Typ.app/Contents/Resources/AppIcon.icns"
    if os.path.exists(existing_app_icon):
        shutil.copy(existing_app_icon, icon_path)
        print(f"Copied icon from {existing_app_icon}")
    else:
        iconset_dir = os.path.join(BUILD_DIR, "AppIcon.iconset")
        os.makedirs(iconset_dir, exist_ok=True)
        subprocess.run(["swift", "scripts/make_icon.swift", iconset_dir], cwd=PROJECT_DIR, check=True)
        subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", icon_path], cwd=PROJECT_DIR, check=True)
        print("Generated AppIcon.icns")

# 2. 组装 Typ.app
if os.path.exists(APP_DIR):
    shutil.rmtree(APP_DIR)

macos_dir = os.path.join(APP_DIR, "Contents", "MacOS")
resources_dir = os.path.join(APP_DIR, "Contents", "Resources")
os.makedirs(macos_dir, exist_ok=True)
os.makedirs(resources_dir, exist_ok=True)

# 拷贝二进制
binary_src = os.path.join(PROJECT_DIR, ".build", "release", "Typ")
binary_dst = os.path.join(macos_dir, "Typ")
shutil.copy2(binary_src, binary_dst)
os.chmod(binary_dst, 0o755)

# 拷贝 Info.plist
plist_src = os.path.join(PROJECT_DIR, "Resources", "Info.plist")
plist_dst = os.path.join(APP_DIR, "Contents", "Info.plist")
shutil.copy2(plist_src, plist_dst)

# 拷贝资源
py_src = os.path.join(PROJECT_DIR, "Resources", "sensevoice_server.py")
py_dst = os.path.join(resources_dir, "sensevoice_server.py")
shutil.copy2(py_src, py_dst)

shutil.copy2(icon_path, os.path.join(resources_dir, "AppIcon.icns"))

# 3. 对 Typ.app 进行签名
sign_res = subprocess.run(
    ["codesign", "--force", "--sign", "-", "--identifier", "local.typ.app", APP_DIR],
    capture_output=True, text=True
)
print("Code sign status:", sign_res.returncode, sign_res.stderr.strip() or "Signed successfully")

print("Typ.app built successfully at:", APP_DIR)

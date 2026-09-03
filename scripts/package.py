#!/usr/bin/env python3
"""Build one local installer and its matching source archive; never install/upload.

--development explicitly permits ad-hoc application/driver and unsigned packages.
A production build requires publisher-provided Application and Installer identities;
notarization and clean-machine acceptance remain separate, explicit release steps.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN_INFO = plistlib.loads((ROOT / "apps/macos/Info.plist").read_bytes())
VERSION = MAIN_INFO["CFBundleShortVersionString"]
BUILD = MAIN_INFO["CFBundleVersion"]
DRIVER_INFO = plistlib.loads((ROOT / "driver/Info.plist").read_bytes())
DRIVER_VERSION = DRIVER_INFO["CFBundleShortVersionString"]
DRIVER_BUILD = DRIVER_INFO["CFBundleVersion"]
TYPELESS_REFERENCE_REVISION = "9e019112fc88534004641499b0b1efc50b491e5e"
APP_ID = "org.rc001remote.assistant"
DRIVER_ID = "org.rc001remote.audio"
HID_SERVICE_ID = "org.rc001remote.assistant.hid-core-service"
UNINSTALLER_ID = "org.rc001remote.assistant.uninstaller"
HID_SERVICE_NAME = "OpenRemoteHIDCoreService.app"
RECEIPT = "org.rc001remote.assistant.pkg"
CS_RUNTIME = 0x10000
FORBIDDEN_CODE_SIGNING_ENTITLEMENTS = {
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.allow-unsigned-executable-memory",
}
SUPPORTED_REMOTE = {
    "profile_id": "xiaomi-rc003-ms-v2-2671",
    "retail_model": "RC003-MS",
    "reported_model": "RC003",
    "manufacturer": "MIOM",
    "hardware_version": "V2.0",
    "firmware_version": "2671",
    "software_version": "A.7.0.6",
    "pnp_id": {
        "vendor_id_source": 1,
        "vendor_id": "0x2717",
        "product_id": "0x32b8",
        "product_version": "0x00a4",
    },
}
ATVV_CAPABILITIES = {
    "response_hex": "0b0100000300780000",
    "accepted_response_hex": [
        "0b0100000300780000",
        "0b0100020300780000",
    ],
    "protocol_version": 1,
    "codec": 2,
    "sample_rate_hz": 16000,
    "frame_bytes": 120,
}
VOICE_SHORTCUT_PRESETS = {
    "typeless": "toggle_fn",
    "doubao": "hold_fn",
    "wechat_input": "hold_fn",
    "lightning_direct": "toggle_fn",
    "lightning_assist": "hold_fn",
}
PAYLOAD_EXECUTABLES = {
    "Applications/遥控器助手.app/Contents/MacOS/OpenRemoteAssistant",
    "Applications/遥控器助手.app/Contents/Helpers/OpenRemoteUninstallHelper",
    "Applications/遥控器助手.app/Contents/Helpers/OpenRemoteAudioServiceHelper",
    "Applications/遥控器助手.app/Contents/Helpers/卸载遥控器助手.app/Contents/MacOS/OpenRemoteUninstaller",
    "Applications/遥控器助手.app/Contents/Helpers/OpenRemoteHIDCoreService.app/Contents/MacOS/OpenRemoteHIDCoreService",
    "Library/Audio/Plug-Ins/HAL/OpenRemoteAudio.driver/Contents/MacOS/OpenRemoteAudio",
    "Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app/Contents/MacOS/OpenRemoteHIDCoreService",
}

def run(*args: str) -> None:
    # The shared workspace adds com.apple.provenance to newly-created files.
    # libarchive would otherwise serialize those xattrs as AppleDouble `._*`
    # payload entries, leaving useless metadata on every installed component.
    environment = os.environ.copy()
    environment["COPYFILE_DISABLE"] = "1"
    subprocess.run(args, check=True, env=environment)

def package_payload_path_is_allowed(value: str) -> bool:
    if value == ".":
        return True
    parts = Path(value).parts
    return bool(parts) and all(part != ".DS_Store" and not part.startswith("._") for part in parts)

def component_members_are_complete(values: list[str]) -> bool:
    return set(values) == {"PackageInfo", "Bom", "Payload", "Scripts"} and len(values) == 4

def parse_codesign_flags(details: str) -> int | None:
    match = re.search(r"(?:^|\n)CodeDirectory\b[^\n]*\bflags=0x([0-9a-fA-F]+)", details)
    return int(match.group(1), 16) if match else None

def validate_hardened_runtime(path: Path) -> None:
    details = subprocess.run(["codesign", "-d", "--verbose=4", str(path)],
                             capture_output=True, text=True)
    flags = parse_codesign_flags(details.stdout + details.stderr)
    if details.returncode != 0 or flags is None or flags & CS_RUNTIME == 0:
        raise RuntimeError(f"发行产物未启用 hardened runtime：{path}")
    entitlements_result = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", str(path)], capture_output=True)
    if entitlements_result.returncode != 0:
        raise RuntimeError(f"无法审计发行产物代码签名权限：{path}")
    if entitlements_result.stdout:
        try:
            entitlements = plistlib.loads(entitlements_result.stdout)
        except Exception as error:
            raise RuntimeError(f"发行产物代码签名权限无法解析：{path}") from error
        if not isinstance(entitlements, dict):
            raise RuntimeError(f"发行产物代码签名权限结构异常：{path}")
        forbidden = FORBIDDEN_CODE_SIGNING_ENTITLEMENTS.intersection(entitlements)
        if forbidden:
            raise RuntimeError(f"发行产物含不安全代码签名权限：{', '.join(sorted(forbidden))}")

def validate_package_payload(package: Path) -> None:
    environment = os.environ.copy()
    environment["COPYFILE_DISABLE"] = "1"
    result = subprocess.run(["pkgutil", "--payload-files", str(package)], check=True,
                            capture_output=True, text=True, env=environment)
    paths = [line for line in result.stdout.splitlines() if line]
    if not paths or any(not package_payload_path_is_allowed(path) for path in paths):
        raise RuntimeError("安装包 payload 含 AppleDouble、Finder 元数据或无法审计")

def validate_product_install_structure(package: Path) -> None:
    """Expand the final product archive and prove its declared script exists."""
    environment = os.environ.copy()
    environment["COPYFILE_DISABLE"] = "1"
    with tempfile.TemporaryDirectory(prefix="final-package-audit-", dir=package.parent) as temporary:
        expanded = Path(temporary) / "expanded"
        subprocess.run(["pkgutil", "--expand", str(package), str(expanded)], check=True, env=environment)
        component = expanded / "component.pkg"
        distribution_file = expanded / "Distribution"
        package_info = component / "PackageInfo"
        bom = component / "Bom"
        payload = component / "Payload"
        scripts = component / "Scripts"
        if not (component.is_dir() and package_info.is_file() and bom.is_file()
                and payload.is_file() and scripts.is_dir() and distribution_file.is_file()):
            raise RuntimeError("最终安装包缺少 Distribution，或 component 缺少 PackageInfo、Bom、Payload、Scripts")

        distribution_tree = ET.parse(distribution_file)
        required_close_ids = [app.get("id") for app in
                              distribution_tree.findall(f".//pkg-ref[@id='{RECEIPT}']/must-close/app")]
        if required_close_ids != [APP_ID]:
            raise RuntimeError("最终安装包未要求在升级前退出已运行的遥控器助手")

        tree = ET.parse(package_info)
        root = tree.getroot()
        payload_element = root.find("payload")
        preinstall_element = root.find("./scripts/preinstall")
        if payload_element is None or preinstall_element is None or preinstall_element.get("file") != "./preinstall":
            raise RuntimeError("最终 PackageInfo 的 payload 或 preinstall 声明无效")
        relocate = root.find("relocate")
        if root.get("relocatable") != "false" or relocate is None or len(relocate) != 0:
            raise RuntimeError("最终 PackageInfo 未明确禁止 bundle relocation")
        driver_bundles = [item for item in root.findall("bundle")
                          if item.get("path") == "./Library/Audio/Plug-Ins/HAL/OpenRemoteAudio.driver"]
        if (len(driver_bundles) != 1 or driver_bundles[0].get("id") != DRIVER_ID
                or driver_bundles[0].get("CFBundleShortVersionString") != DRIVER_VERSION
                or driver_bundles[0].get("CFBundleVersion") != DRIVER_BUILD):
            raise RuntimeError("最终 PackageInfo 的音频驱动身份或升级版本不匹配")
        payload_paths = subprocess.run(["pkgutil", "--payload-files", str(package)], check=True,
                                       capture_output=True, text=True,
                                       env=environment).stdout.splitlines()
        bom_paths = subprocess.run(["lsbom", "-s", str(bom)], check=True,
                                   capture_output=True, text=True,
                                   env=environment).stdout.splitlines()
        if (not payload_paths or set(payload_paths) != set(bom_paths)
                or len(payload_paths) != len(bom_paths)
                or payload_element.get("numberOfFiles") != str(len(payload_paths))):
            raise RuntimeError("最终 PackageInfo、Bom 与 Payload 路径不一致")

        script_paths = sorted(path.name for path in scripts.iterdir())
        preinstall = scripts / "preinstall"
        audio_state = scripts / "audio-state"
        if (script_paths != ["audio-state", "preinstall"]
                or not preinstall.is_file() or not audio_state.is_file()
                or stat.S_IMODE(preinstall.stat().st_mode) != 0o755
                or stat.S_IMODE(audio_state.stat().st_mode) != 0o755
                or preinstall.read_text() != GUARDS + '\n"${0:A:h}/audio-state" --install-check\n'):
            raise RuntimeError("最终安装脚本缺失、权限错误或内容不匹配")
        subprocess.run(["/bin/zsh", "-n", str(preinstall)], check=True, env=environment)
        subprocess.run(["codesign", "--verify", "--strict", str(audio_state)], check=True, env=environment)

def write_portable_cpio(root: Path, destination: Path, workspace: Path, label: str) -> list[str]:
    entries = ["."] + ["./" + path.relative_to(root).as_posix() for path in sorted(root.rglob("*"))]
    if any("\n" in entry or "\r" in entry or not package_payload_path_is_allowed(entry)
           for entry in entries):
        raise RuntimeError(f"{label} 含不可归档的路径")
    raw_cpio = workspace / f"{label}.cpio"
    environment = os.environ.copy()
    environment["COPYFILE_DISABLE"] = "1"
    with raw_cpio.open("wb") as output:
        result = subprocess.run(["cpio", "-o", "--format", "odc", "-R", "root:wheel"],
                                input=("\n".join(entries) + "\n").encode(), cwd=root,
                                stdout=output, stderr=subprocess.PIPE, env=environment)
    if result.returncode != 0:
        raise RuntimeError(f"无法生成不含扩展属性的{label}")
    with destination.open("wb") as output:
        subprocess.run(["gzip", "-9", "-n", "-c", str(raw_cpio)], check=True,
                       stdout=output, env=environment)
    return entries

def rewrite_component_payload_without_xattrs(component: Path, payload: Path, scripts: Path) -> None:
    """Replace pkgbuild's xattr-bearing payload with a portable cpio archive.

    The workspace applies a non-removable `com.apple.provenance` attribute to
    generated files. pkgbuild serializes that attribute as zero-byte `._*`
    records. The installer does not need it, so retain pkgbuild's PackageInfo
    and scripts while rebuilding Payload/Bom from explicit ordinary paths.
    """
    with tempfile.TemporaryDirectory(prefix="component-repack-", dir=component.parent) as temporary:
        extracted = Path(temporary)
        run("xar", "-xf", str(component), "-C", str(extracted))
        required = [extracted / "PackageInfo", extracted / "Bom", extracted / "Payload", extracted / "Scripts"]
        if any(not path.is_file() for path in required):
            raise RuntimeError("pkgbuild 组件缺少 PackageInfo、Payload、Bom 或 Scripts")

        environment = os.environ.copy()
        environment["COPYFILE_DISABLE"] = "1"
        entries = write_portable_cpio(payload, extracted / "Payload", extracted, "Payload")
        script_entries = write_portable_cpio(scripts, extracted / "Scripts", extracted, "Scripts")
        if set(script_entries) != {".", "./audio-state", "./preinstall"}:
            raise RuntimeError("安装脚本归档内容不完整或含额外文件")

        listing = subprocess.run(["lsbom", str(extracted / "Bom")], check=True,
                                 capture_output=True, text=True, env=environment).stdout.splitlines()
        filtered = [line for line in listing
                    if line and package_payload_path_is_allowed(line.split("\t", 1)[0])]
        filtered_paths = [line.split("\t", 1)[0] for line in filtered]
        if not filtered or len(filtered_paths) != len(entries) or set(filtered_paths) != set(entries):
            raise RuntimeError("安装 payload 与过滤后的 Bom 清单不一致")
        bom_list = extracted / "Bom.list"
        bom_list.write_text("\n".join(filtered) + "\n")
        run("mkbom", "-i", str(bom_list), str(extracted / "Bom"))

        package_info = extracted / "PackageInfo"
        tree = ET.parse(package_info)
        root = tree.getroot()
        payload_element = root.find("payload")
        preinstall = root.find("./scripts/preinstall")
        if payload_element is None or preinstall is None or preinstall.get("file") != "./preinstall":
            raise RuntimeError("PackageInfo 缺少 payload 或 preinstall 声明")
        payload_element.set("numberOfFiles", str(len(entries)))
        tree.write(package_info, encoding="utf-8", xml_declaration=True)

        members = ["PackageInfo", "Bom", "Payload", "Scripts"]
        rewritten = component.with_name("component-without-xattrs.pkg")
        subprocess.run(["xar", "-cf", str(rewritten), "--compression", "none", *members],
                       check=True, cwd=extracted, env=environment)
        archived_members = subprocess.run(["xar", "-tf", str(rewritten)], check=True,
                                          capture_output=True, text=True,
                                          env=environment).stdout.splitlines()
        if not component_members_are_complete(archived_members):
            raise RuntimeError("重写后的组件包缺少 Payload、Bom、PackageInfo 或 Scripts")
        os.replace(rewritten, component)
    validate_package_payload(component)

def script(path: Path, text: str) -> None:
    path.write_text(text)
    path.chmod(0o755)

def publish_staged_artifact(staged: Path, destination: Path, preserve_previous: bool = True) -> None:
    """Publish only a fully validated staged file under its user-facing name."""
    if destination.exists() and preserve_previous:
        suffix = 0
        while True:
            marker = f"-{suffix}" if suffix else ""
            previous = destination.with_name(f"previous-{destination.name}-{os.getpid()}{marker}")
            if not previous.exists(): break
            suffix += 1
        destination.rename(previous)
    os.replace(staged, destination)

def normalize_payload_modes(root: Path) -> None:
    """Set deterministic package modes without changing signed file bytes."""
    for path in [root, *sorted(root.rglob("*"))]:
        if path.is_symlink():
            raise RuntimeError("payload 不可含符号链接")
        mode = path.stat().st_mode
        if path.is_dir():
            path.chmod(0o755)
        elif path.is_file() and stat.S_ISREG(mode):
            relative = path.relative_to(root).as_posix()
            path.chmod(0o755 if relative in PAYLOAD_EXECUTABLES else 0o644)
        else:
            raise RuntimeError("payload 只允许普通文件和目录")

def validate_bundle(bundle: Path, expected_identifier: str, release_versioned: bool = False,
                    expected_version: str | None = None, expected_build: str | None = None) -> None:
    if bundle.is_symlink() or not bundle.is_dir():
        raise RuntimeError("构建产物缺失、类型异常或是符号链接")
    info = bundle / "Contents/Info.plist"
    if info.is_symlink() or not info.is_file():
        raise RuntimeError("构建产物 Info.plist 缺失、类型异常或是符号链接")
    values = plistlib.loads(info.read_bytes())
    if values.get("CFBundleIdentifier") != expected_identifier:
        raise RuntimeError("构建产物身份不匹配")
    if release_versioned and (values.get("CFBundleShortVersionString") != VERSION or
                              values.get("CFBundleVersion") != BUILD):
        raise RuntimeError(f"构建产物版本不一致：需要 {VERSION}（{BUILD}）")
    if expected_version is not None and expected_build is not None and (
            values.get("CFBundleShortVersionString") != expected_version or
            values.get("CFBundleVersion") != expected_build):
        raise RuntimeError(f"构建产物版本不一致：需要 {expected_version}（{expected_build}）")
    if any(path.is_symlink() for path in bundle.rglob("*")):
        raise RuntimeError("发行产物不可含未审核符号链接")

def stage_payload(app: Path, driver: Path, payload: Path) -> list[Path]:
    hid_service = app / "Contents/Helpers" / HID_SERVICE_NAME
    uninstaller = app / "Contents/Helpers/卸载遥控器助手.app"
    validate_bundle(app, APP_ID, release_versioned=True)
    validate_bundle(driver, DRIVER_ID, expected_version=DRIVER_VERSION, expected_build=DRIVER_BUILD)
    validate_bundle(hid_service, HID_SERVICE_ID, release_versioned=True)
    validate_bundle(uninstaller, UNINSTALLER_ID, release_versioned=True)
    (payload / "Applications").mkdir(parents=True)
    (payload / "Library/Audio/Plug-Ins/HAL").mkdir(parents=True)
    (payload / "Library/PrivilegedHelperTools").mkdir(parents=True)
    destinations = [payload / "Applications/遥控器助手.app",
                    payload / "Library/Audio/Plug-Ins/HAL/OpenRemoteAudio.driver",
                    payload / "Library/PrivilegedHelperTools" / HID_SERVICE_NAME]
    for source, destination in zip([app, driver, hid_service], destinations):
        shutil.copytree(source, destination)
    normalize_payload_modes(payload)
    return destinations

def source_files() -> list[Path]:
    files = []
    for pattern in ["LICENSE", "COPYRIGHT", "THIRD_PARTY_NOTICES.md", "README*.md", ".gitignore",
                    "apps/macos/Info.plist", "apps/macos/Sources/*.swift", "apps/macos/Tests/*.swift",
                    "apps/macos/Resources/INSTALL.html", "apps/macos/Uninstaller/*.swift",
                    "apps/macos/Uninstaller/Info.plist", "apps/macos/UninstallerTests/*.swift", "apps/macos/AudioService/*.swift", "apps/macos/HIDService/*.swift", "scripts/*.py", "scripts/*.swift", "scripts/*.zsh",
                    "apps/macos/HIDService/Info.plist", "docs/*.md", "driver/Info.plist", "driver/*.md", "driver/LICENSE", "driver/Sources/*",
                    "driver/Tests/*", "driver/upstream/BlackHole.c", "driver/upstream/LICENSE", "driver/upstream/manifest.json"]:
        files.extend(p for p in ROOT.glob(pattern) if p.is_file())
    return sorted(set(files))

def source_hashes(files: list[Path]) -> dict[str, str]:
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}

def public_tar_info(info: tarfile.TarInfo) -> tarfile.TarInfo:
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mtime = 0
    info.mode = 0o644
    info.pax_headers = {}
    return info

GUARDS = '''#!/bin/zsh
set -euo pipefail
[[ "$EUID" -eq 0 && "${3:-/}" == "/" ]] || { print -u2 "仅支持由系统安装器在当前启动磁盘执行。"; exit 1; }
check_parent() {
    local parent_path="$1"
    [[ ! -L "$parent_path" ]] || { print -u2 "安装父目录是符号链接，已停止。"; exit 1; }
    [[ ! -e "$parent_path" || -d "$parent_path" ]] || { print -u2 "安装父路径不是目录，已停止。"; exit 1; }
}
check_root_parent() {
    local parent_path="$1"
    check_parent "$parent_path"
    if [[ -e "$parent_path" ]]; then
        local metadata=$(/usr/bin/stat -f '%u:%g:%Lp' "$parent_path") || exit 1
        [[ "$metadata" == '0:0:755' ]] || { print -u2 "受保护安装父目录所有权或权限异常，已停止。"; exit 1; }
    fi
}
check_component() {
    local component_path="$1" expected_id="$2"
    [[ ! -L "$component_path" ]] || { print -u2 "目标是符号链接，已停止。"; exit 1; }
    if [[ -e "$component_path" ]]; then
        [[ -d "$component_path" && ! -L "$component_path/Contents" && ! -L "$component_path/Contents/Info.plist" ]] || { print -u2 "目标结构含符号链接或类型异常，已停止。"; exit 1; }
        local found_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$component_path/Contents/Info.plist" 2>/dev/null) || exit 1
        [[ "$found_id" == "$expected_id" ]] || { print -u2 "目标身份不属于本产品，已停止。"; exit 1; }
    fi
}
for parent_path in /Applications /Library /Library/Audio /Library/Audio/Plug-Ins /Library/Audio/Plug-Ins/HAL /Library/PrivilegedHelperTools; do
    check_parent "$parent_path"
done
check_root_parent '/Library'
check_root_parent '/Library/Audio'
check_root_parent '/Library/Audio/Plug-Ins'
check_root_parent '/Library/Audio/Plug-Ins/HAL'
check_root_parent '/Library/PrivilegedHelperTools'
check_component '/Applications/遥控器助手.app' 'org.rc001remote.assistant'
check_component '/Library/Audio/Plug-Ins/HAL/OpenRemoteAudio.driver' 'org.rc001remote.audio'
check_component '/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app' 'org.rc001remote.assistant.hid-core-service'
# The native audio-state --install-check below also checks full process paths.
# macOS pgrep without -f silently misses executable names longer than 19 chars.
'''

def distribution(path: Path, component: str, development: bool) -> None:
    warning = "开发测试包：未进行生产签名和公证，请勿作为公开发行版传播。" if development else "签名候选包：仍须完成公证及实体验收。"
    (path.parent / "welcome.html").write_text(
        f'<!doctype html><meta charset="utf-8"><h2>遥控器助手 {VERSION}（build {BUILD}）</h2><p>{warning}</p>'
        '<p><strong>升级前必须在旧版“遥控器助手”中按 ⌘Q 完全退出；只关闭窗口后程序仍可能驻留。系统安装器也会在继续前检查并提示退出。</strong></p>'
        '<p>安装应用、兼容清理用按键组件和专用麦克风；0.2.9 的按键映射只使用主程序权限，不启动该旧按键组件，并加入多种语音软件 Fn 预设。安装、重载与连接本身不会自动更改默认音频设备。应用内置“卸载遥控器助手”窗口，可选清除当前用户数据。</p>'
        '<p>固定安装位置：<code>/Applications/遥控器助手.app</code>、<code>/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app</code>、<code>/Library/Audio/Plug-Ins/HAL/OpenRemoteAudio.driver</code>。</p>'
        '<p>安装需要管理员授权，不要求重启电脑，也不会自动重启音频服务。完成后退出安装器，打开“应用程序”中的遥控器助手，程序会检查音频组件是否生效。</p>'
        '<p>若显示“已安装，尚未生效”，可点击“重新加载音频服务…”。这会暂时中断整台电脑的声音、录音及会议，请先结束音频工作；只有再次确认并通过管理员授权后才执行，也可选择稍后处理。</p>'
        '<p>支持范围：Apple Silicon、macOS 26；RC003-MS（设备自报 RC003）/ MIOM / 硬件 V2.0 / 固件 2671 / 软件 A.7.0.6。</p>'
        '<p>目标软件仍需麦克风权限；如果它在组件生效前已经打开，可能需要完全退出并重新启动。能选择设备的软件请直接选择“遥控器麦克风”；公开输入使用 USB-compatible transport 元数据以兼容会过滤普通虚拟设备的软件，但不代表实体 USB 连接。只跟随系统默认输入的软件，可由用户在助手中明确设置。设置与恢复只改输入、不改输出，保存原输入设备的 UID，并等待系统通知与回读确认；外部改选后旧恢复记录失效。退出不会静默切换默认输入，只有当前仍是遥控器且存在有效恢复对象时才让用户明确选择恢复或保留。</p>'
        '<p>已核实设备身份、ATVV 拓扑和能力响应，并已收到真实遥控器音频帧；公开输入已被 AVFoundation 与 FFmpeg 枚举并成功打开。正常松开语音键会在最长 0.75 秒内排空已进入电脑的尾音；错误、断连和退出仍立即停止。真实 HID 按键、真实人声进入目标软件及系统端到端输入仍需安装后实测。</p>')
    path.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>遥控器助手</title><welcome file="welcome.html"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <volume-check><allowed-os-versions><os-version min="26.0"/></allowed-os-versions></volume-check>
  <choices-outline><line choice="main"/></choices-outline>
  <choice id="main" visible="false"><pkg-ref id="{RECEIPT}"/></choice>
  <pkg-ref id="{RECEIPT}" version="{VERSION}" onConclusion="None">
    <must-close><app id="{APP_ID}"/></must-close>
    {component}
  </pkg-ref>
</installer-gui-script>
''')

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--development", action="store_true")
    args = parser.parse_args()
    app_sign = os.environ.get("OPENREMOTE_APPLICATION_IDENTITY", "-")
    pkg_sign = os.environ.get("OPENREMOTE_INSTALLER_IDENTITY")
    if not args.development and (app_sign == "-" or not pkg_sign):
        parser.error("正式构建必须提供发行者的Application和Installer签名身份；本地候选请显式使用--development。")
    artifacts = ROOT / "artifacts"
    artifacts.mkdir(exist_ok=True)
    files = source_files()
    frozen_sources = source_hashes(files)
    run("/bin/zsh", str(ROOT / "scripts/build-driver.zsh"))
    run("/bin/zsh", str(ROOT / "scripts/build-app.zsh"))
    app = artifacts / "遥控器助手.app"
    driver = ROOT / "driver/build/OpenRemoteAudio.driver"
    validate_hardened_runtime(app)
    validate_hardened_runtime(app / "Contents/Helpers" / HID_SERVICE_NAME)
    validate_hardened_runtime(app / "Contents/Helpers/OpenRemoteAudioServiceHelper")
    validate_hardened_runtime(app / "Contents/Helpers/OpenRemoteUninstallHelper")
    validate_hardened_runtime(app / "Contents/Helpers/卸载遥控器助手.app")
    signing = ["--sign", pkg_sign] if pkg_sign else []
    suffix = "-development" if args.development else "-signed-candidate"
    # GitHub strips non-ASCII characters from release asset filenames. Keep
    # the public artifact name portable so SHA256SUMS remains directly usable.
    final_package = artifacts / f"OpenRemoteAssistant-{VERSION}{suffix}.pkg"
    final_archive = artifacts / f"OpenRemoteAssistant-{VERSION}-source.tar.gz"
    final_version_manifest = artifacts / f"manifest-{VERSION}.json"
    final_manifest = artifacts / "manifest.json"
    # Standard artifact names appear only after the package, corresponding
    # source and manifest have all passed validation and source-freeze checks.
    with tempfile.TemporaryDirectory(prefix=f"release-{VERSION}-", dir=artifacts) as release_temporary:
        release_stage = Path(release_temporary)
        staged_package = release_stage / final_package.name
        staged_archive = release_stage / final_archive.name
        with tempfile.TemporaryDirectory(prefix="package-", dir=release_stage) as temporary:
            stage = Path(temporary)
            resources = stage / "resources"; resources.mkdir()
            payload = stage / "payload"
            copied_bundles = stage_payload(app, driver, payload)
            for copied_bundle in copied_bundles:
                run("codesign", "--verify", "--deep", "--strict", str(copied_bundle))
            install_scripts = stage / "install-scripts"; install_scripts.mkdir()
            run("xcrun", "swiftc", "-O", "-target", "arm64-apple-macos26.0", str(ROOT / "scripts/AudioState.swift"),
                "-framework", "CoreAudio", "-o", str(install_scripts / "audio-state"))
            sign_options = ["--options", "runtime", "--timestamp=none"] if app_sign == "-" else ["--options", "runtime", "--timestamp"]
            run("codesign", "--force", *sign_options, "--sign", app_sign, str(install_scripts / "audio-state"))
            run("codesign", "--verify", "--strict", str(install_scripts / "audio-state"))
            validate_hardened_runtime(install_scripts / "audio-state")
            script(install_scripts / "preinstall", GUARDS + '\n"${0:A:h}/audio-state" --install-check\n')
            component_plist = stage / "components.plist"
            run("pkgbuild", "--analyze", "--root", str(payload), str(component_plist))
            components = plistlib.loads(component_plist.read_bytes())
            for item in components:
                item["BundleIsRelocatable"] = False
                item["BundleOverwriteAction"] = "upgrade"
                item["BundleHasStrictIdentifier"] = True
                item["BundleIsVersionChecked"] = True
            component_plist.write_bytes(plistlib.dumps(components))
            run("pkgbuild", "--root", str(payload), "--ownership", "recommended", "--install-location", "/",
                "--component-plist", str(component_plist), "--identifier", RECEIPT, "--version", VERSION,
                "--scripts", str(install_scripts), str(stage / "component.pkg"))
            rewrite_component_payload_without_xattrs(stage / "component.pkg", payload, install_scripts)
            distribution(resources / "distribution.xml", "component.pkg", args.development)
            run("productbuild", "--distribution", str(resources / "distribution.xml"), "--resources", str(resources),
                "--package-path", str(stage), *signing, str(staged_package))
            validate_package_payload(staged_package)
            validate_product_install_structure(staged_package)
        if source_files() != files or source_hashes(files) != frozen_sources:
            raise RuntimeError("构建期间源码发生变化；未发布安装包，请重新构建。")
        with tarfile.open(staged_archive, "w:gz") as tar:
            for path in files:
                if path.is_symlink(): raise RuntimeError("源码清单包含符号链接")
                tar.add(path, arcname=str(Path("OpenRemoteAssistant") / path.relative_to(ROOT)), recursive=False, filter=public_tar_info)
        if source_files() != files or source_hashes(files) != frozen_sources:
            raise RuntimeError("归档期间源码发生变化；未发布这组产物。")
        manifest = {"version": VERSION, "build": BUILD, "development_build": args.development,
            "supported_remote": SUPPORTED_REMOTE,
            "bluetooth_identity_verified": True,
            "atvv_topology_verified": True,
            "atvv_capabilities_verified": True,
            "atvv_capabilities": ATVV_CAPABILITIES,
            "notarized": False, "installed": False, "physical_microphone_verified": True,
            "physical_hid_verified": False, "system_end_to_end_verified": True,
            "installation_requires_restart": False, "audio_service_reload_verified": False,
            "privileged_hid_session_verified": False, "mapping_session_requires_administrator": False,
            "mapping_mode": "bound-device seize with shared-read event-suppression fallback",
            "helper_input_monitoring_verified": False, "fixed_hid_helper_identity": True,
            "fixed_hid_service_installed": True, "persistent_hid_daemon_installed": False,
            "audio_driver_version": DRIVER_VERSION, "audio_driver_build": DRIVER_BUILD,
            "public_input_transport": "USB-compatible metadata", "hidden_output_transport": "Virtual",
            "normal_release_audio_drain_max_ms": 750,
            "typeless_compatibility_included": True,
            "typeless_reference_revision": TYPELESS_REFERENCE_REVISION,
            "software_fn_event": {"virtual_key": 63, "flag": "maskSecondaryFn", "source": "hidSystemState"},
            "voice_shortcut_presets": VOICE_SHORTCUT_PRESETS,
            "typeless_basic_user_confirmed": True,
            "typeless_physical_end_to_end_verified": True,
            "full_physical_acceptance_verified": False,
            "clean_install_verified": False,
            "verification_scope": "user-confirmed basic RC003-MS microphone to Typeless path; preset matrix and stress checklist pending",
            "source_files": frozen_sources,
            "artifacts": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [staged_package, staged_archive]}}
        manifest_text = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
        staged_version_manifest = release_stage / final_version_manifest.name
        staged_manifest = release_stage / final_manifest.name
        staged_version_manifest.write_text(manifest_text)
        staged_manifest.write_text(manifest_text)
        publish_staged_artifact(staged_archive, final_archive)
        publish_staged_artifact(staged_package, final_package)
        publish_staged_artifact(staged_version_manifest, final_version_manifest)
        publish_staged_artifact(staged_manifest, final_manifest, preserve_previous=False)
    print(f"已生成安装包与对应源码，未安装、未上传：{final_package}")

if __name__ == "__main__":
    main()

#!/usr/bin/env bash
set -euo pipefail

# VibeCode macOS 原生 Finder Sync Extension 构建与安装脚本
# 用法: ./macos/build.sh [--install-dir /Applications] [--adhoc] [--no-launch]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUPPORT_DIR="$HOME/Library/Application Support/VibeCode"
INSTALL_DIR="/Applications"
FORCE_ADHOC="0"
NO_LAUNCH="0"
EXT_BUNDLE_ID="com.vibecode.contextmenu.FinderSync"
APP_VERSION="1.0.0"
if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    APP_VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
fi
BUILD_NUMBER="$(git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null || echo "1")"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --version)
            APP_VERSION="$2"
            shift 2
            ;;
        --adhoc)
            FORCE_ADHOC="1"
            shift
            ;;
        --no-launch)
            NO_LAUNCH="1"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--install-dir <dir>] [--version <x.y.z>] [--adhoc] [--no-launch]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "错误: 此脚本仅支持 macOS。" >&2
    exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
    echo "错误: 未检测到 swiftc，请先安装 Xcode 或 Xcode Command Line Tools (xcode-select --install)。" >&2
    exit 1
fi

if [[ ! -w "$INSTALL_DIR" ]]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
fi

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"
SDK_PATH="$(xcrun --show-sdk-path)"

BUILD_WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibecode-build-XXXXXX")"
trap 'rm -rf "$BUILD_WORK"' EXIT

APP_BUNDLE="$BUILD_WORK/VibeCode.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_PLUGINS="$APP_CONTENTS/PlugIns"

EXT_BUNDLE="$APP_PLUGINS/VibeCodeFinderSync.appex"
EXT_CONTENTS="$EXT_BUNDLE/Contents"
EXT_MACOS="$EXT_CONTENTS/MacOS"
EXT_RESOURCES="$EXT_CONTENTS/Resources"

mkdir -p "$APP_MACOS" "$APP_RESOURCES/icons" "$EXT_MACOS" "$EXT_RESOURCES/icons" "$BUILD_WORK/src"
# 复制源码到本机 APFS 临时目录再编译，避免外接卷（NTFS/exFAT）时间戳差异触发 swiftc 误报
cp -f "$SCRIPT_DIR/icon_convert.swift" "$BUILD_WORK/src/icon_convert.swift"
cp -f "$SCRIPT_DIR/HostApp/main.swift" "$BUILD_WORK/src/HostApp.swift"
cp -f "$SCRIPT_DIR/FinderSyncExtension/FinderSync.swift" "$BUILD_WORK/src/FinderSync.swift"

echo "==> [1/6] 转换官方图标 (.ico -> .png / AppIcon.icns)..."
ICON_TOOL="$BUILD_WORK/icon_convert"
swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target "$TARGET" \
    "$BUILD_WORK/src/icon_convert.swift" -o "$ICON_TOOL"
"$ICON_TOOL" "$PROJECT_ROOT/ico" "$APP_RESOURCES/icons" "$APP_RESOURCES/AppIcon.icns"
cp -f "$APP_RESOURCES/icons/"*.png "$EXT_RESOURCES/icons/"

echo "==> [2/6] 编译宿主应用 (VibeCode.app)..."
swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target "$TARGET" \
    -framework AppKit -framework Foundation -framework UniformTypeIdentifiers \
    "$BUILD_WORK/src/HostApp.swift" \
    -o "$APP_MACOS/VibeCode"

echo "==> [3/6] 编译 Finder Sync 扩展 (VibeCodeFinderSync.appex)..."
swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target "$TARGET" \
    -application-extension -parse-as-library \
    -module-name VibeCodeFinderSync \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -framework FinderSync -framework AppKit -framework Foundation \
    "$BUILD_WORK/src/FinderSync.swift" \
    -o "$EXT_MACOS/VibeCodeFinderSync"

echo "==> [4/6] 组装 Bundle 与资源 (版本: v${APP_VERSION}, build ${BUILD_NUMBER})..."
cp -f "$SCRIPT_DIR/HostApp/Info.plist" "$APP_CONTENTS/Info.plist"
cp -f "$SCRIPT_DIR/FinderSyncExtension/Info.plist" "$EXT_CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP_CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$EXT_CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$EXT_CONTENTS/Info.plist"
cp -f "$PROJECT_ROOT/tools.json" "$APP_RESOURCES/tools.json"
cp -f "$PROJECT_ROOT/tools.json" "$EXT_RESOURCES/tools.json"
cp -f "$SCRIPT_DIR/launcher/launch-vibecode-tool.sh" "$APP_RESOURCES/launch-vibecode-tool.sh"
chmod +x "$APP_RESOURCES/launch-vibecode-tool.sh"

# 选择代码签名身份：优先使用本机有效 Apple Development 证书，否则回退 ad-hoc
SIGN_IDENTITY="-"
if [[ "$FORCE_ADHOC" != "1" ]]; then
    DETECTED_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/{print $2; exit}')"
    if [[ -n "$DETECTED_ID" ]]; then
        SIGN_IDENTITY="$DETECTED_ID"
    fi
fi

echo "==> [5/6] 代码签名 (身份: $SIGN_IDENTITY)..."
codesign --force --timestamp=none \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$SCRIPT_DIR/FinderSyncExtension/Entitlements.plist" \
    "$EXT_BUNDLE"

codesign --force --timestamp=none \
    --sign "$SIGN_IDENTITY" \
    "$APP_BUNDLE"

codesign --verify --deep --strict "$APP_BUNDLE"
echo "  [OK] 代码签名校验通过。"

echo "==> [6/6] 部署配置与安装到 $INSTALL_DIR/VibeCode.app..."
mkdir -p "$SUPPORT_DIR/icons"
cp -f "$APP_RESOURCES/icons/"*.png "$SUPPORT_DIR/icons/"
cp -f "$SCRIPT_DIR/launcher/launch-vibecode-tool.sh" "$SUPPORT_DIR/launch-vibecode-tool.sh"
chmod +x "$SUPPORT_DIR/launch-vibecode-tool.sh"
rm -f "$SUPPORT_DIR/VibeCode.sh"
cp -f "$PROJECT_ROOT/tools.json" "$SUPPORT_DIR/tools.json"

# 初始化或更新 macos.json（保留用户已配置的顺序与默认终端）
/usr/bin/python3 - "$SUPPORT_DIR/macos.json" "$PROJECT_ROOT" "$SUPPORT_DIR/tools.json" <<'PYEOF'
import json, os, shutil, subprocess, sys

macos_path, project_root, tools_path = sys.argv[1:4]
existing = {}
if os.path.isfile(macos_path):
    try:
        with open(macos_path, "r", encoding="utf-8") as f:
            existing = json.load(f) or {}
    except Exception:
        existing = {}

existing["projectDir"] = project_root
existing.setdefault("terminal", "Terminal")
existing.setdefault("showMenuBarIcon", True)
existing.setdefault("contextMenuEnabled", True)
existing.setdefault("menuLayout", "auto")
existing.setdefault("showNormalMode", True)
existing.setdefault("showSuperMode", True)
existing.setdefault("showResumeMode", True)

with open(tools_path, "r", encoding="utf-8-sig") as f:
    tools_cfg = json.load(f)
known_names = [t["name"] for t in tools_cfg.get("tools", []) if t.get("name")]
known_set = set(known_names)

if isinstance(existing.get("enabledTools"), list):
    # 清理无效或已删除的条目
    cleaned = [n for n in existing["enabledTools"] if n in known_set]
    existing["enabledTools"] = cleaned

if "enabledTools" not in existing or not existing["enabledTools"]:
    # 首次初始化：通过用户登录 zsh 检测已安装的 CLI 工具（带标记前缀避免混入登录提示）
    probe_cmd = (
        'export PATH="$HOME/.local/bin:$HOME/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; '
        + "; ".join(
            f'command -v {t["command"].split()[0]} >/dev/null 2>&1 && echo "__VC_FOUND__:{t["name"]}"'
            for t in tools_cfg.get("tools", [])
            if t.get("name") and t.get("command") and t["command"].split()
        )
    )
    env = dict(os.environ)
    env["SHELL_SESSIONS_DISABLE"] = "1"
    try:
        out = subprocess.check_output(
            ["/bin/zsh", "-l", "-i", "-c", probe_cmd],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=8,
            env=env,
        )
        detected = []
        for line in out.splitlines():
            s = line.strip()
            if s.startswith("__VC_FOUND__:"):
                name = s.split(":", 1)[1].strip()
                if name in known_set and name not in detected:
                    detected.append(name)
    except Exception:
        detected = []
    existing["enabledTools"] = detected if detected else known_names

with open(macos_path, "w", encoding="utf-8") as f:
    json.dump(existing, f, ensure_ascii=False, indent=2)
    f.write("\n")
PYEOF

# 结束旧进程并替换 .app
pkill -x VibeCode 2>/dev/null || true
pkill -x VibeCodeFinderSync 2>/dev/null || true
sleep 0.3

DEST_APP="$INSTALL_DIR/VibeCode.app"
rm -rf "$DEST_APP"
cp -R "$APP_BUNDLE" "$DEST_APP"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

# 注册 LaunchServices 与 Finder Sync Extension
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
fi

pluginkit -a "$DEST_APP/Contents/PlugIns/VibeCodeFinderSync.appex" >/dev/null 2>&1 || true
pluginkit -e use -i "$EXT_BUNDLE_ID" >/dev/null 2>&1 || true

if [[ "$NO_LAUNCH" != "1" ]]; then
    open -g "$DEST_APP" >/dev/null 2>&1 || true
fi

echo ""
echo "========================================"
echo "  VibeCode macOS 构建与安装完成！"
echo "========================================"
echo "  应用路径: $DEST_APP"
echo "  配置目录: $SUPPORT_DIR"
echo "  扩展状态:"
pluginkit -m -p com.apple.FinderSync 2>/dev/null | grep "$EXT_BUNDLE_ID" || echo "  (等待系统注册扩展)"
echo ""
echo "提示: 若右键暂未显示 VibeCode 菜单，请打开「系统设置 -> 通用 -> 登录项与扩展 -> Finder」，确认勾选「VibeCode 右键菜单」。"

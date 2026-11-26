#!/usr/bin/env bash
set -euo pipefail

# VibeCode macOS 发布安装包打包脚本（支持 Universal Binary、版本号、DMG 与可选 PKG）
# 用法:
#   ./macos/pack.sh
#   ./macos/pack.sh --version 1.1.0 --pkg
#   ./macos/pack.sh --sign "Developer ID Application: Your Name (TEAMID)" --notarize-profile "AC_PROFILE"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_ROOT/dist"
EXT_BUNDLE_ID="com.vibecode.contextmenu.FinderSync"

APP_VERSION="1.0.0"
if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    APP_VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
fi
BUILD_NUMBER="$(git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null || echo "1")"
ARCH_MODE="universal"   # universal | arm64 | x86_64
SIGN_IDENTITY="-"       # 分发包默认 ad-hoc 签名；正式公证时传入 Developer ID Application
INSTALLER_SIGN_IDENTITY=""
BUILD_PKG="0"
NOTARIZE_PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            APP_VERSION="$2"
            shift 2
            ;;
        --build)
            BUILD_NUMBER="$2"
            shift 2
            ;;
        --arch)
            ARCH_MODE="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --sign)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --installer-sign)
            INSTALLER_SIGN_IDENTITY="$2"
            shift 2
            ;;
        --pkg)
            BUILD_PKG="1"
            shift
            ;;
        --notarize-profile)
            NOTARIZE_PROFILE="$2"
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
VibeCode macOS 安装包打包脚本

用法:
  ./macos/pack.sh [选项]

选项:
  --version <x.y.z>            指定版本号（默认读取 macos/VERSION）
  --build <num>                指定 Build 号（默认取 git commit 数）
  --arch <universal|arm64|x86_64>  构建架构（默认 universal，同时支持 M 系列与 Intel）
  --output-dir <dir>           输出目录（默认 dist/）
  --sign <identity>            代码签名身份（默认 "-" 即 ad-hoc；正式分发可传 Developer ID Application）
  --installer-sign <identity>  PKG 安装包签名身份（Developer ID Installer，可选）
  --pkg                        除 .dmg 外，同时生成 .pkg 安装向导包
  --notarize-profile <name>    使用 notarytool keychain profile 提交 Apple 公证并装订票据
EOF
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            exit 1
            ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "错误: 此脚本仅支持在 macOS 上运行。" >&2
    exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
    echo "错误: 未检测到 swiftc，请先安装 Xcode 或 Xcode Command Line Tools。" >&2
    exit 1
fi

if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "错误: 版本号格式无效: $APP_VERSION（示例: 1.0.0）" >&2
    exit 1
fi

case "$ARCH_MODE" in
    universal)
        ARCH_LIST=("arm64" "x86_64")
        ;;
    arm64|x86_64)
        ARCH_LIST=("$ARCH_MODE")
        ;;
    *)
        echo "错误: 不支持的 --arch 参数: $ARCH_MODE（可选 universal / arm64 / x86_64）" >&2
        exit 1
        ;;
esac

SDK_PATH="$(xcrun --show-sdk-path)"
HOST_ARCH="$(uname -m)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibecode-pack-XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/src" "$WORK_DIR/bin" "$OUTPUT_DIR"
cp -f "$SCRIPT_DIR/icon_convert.swift" "$WORK_DIR/src/icon_convert.swift"
cp -f "$SCRIPT_DIR/HostApp/main.swift" "$WORK_DIR/src/HostApp.swift"
cp -f "$SCRIPT_DIR/FinderSyncExtension/FinderSync.swift" "$WORK_DIR/src/FinderSync.swift"

APP_BUNDLE="$WORK_DIR/VibeCode.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_PLUGINS="$APP_CONTENTS/PlugIns"

EXT_BUNDLE="$APP_PLUGINS/VibeCodeFinderSync.appex"
EXT_CONTENTS="$EXT_BUNDLE/Contents"
EXT_MACOS="$EXT_CONTENTS/MacOS"
EXT_RESOURCES="$EXT_CONTENTS/Resources"

mkdir -p "$APP_MACOS" "$APP_RESOURCES/icons" "$EXT_MACOS" "$EXT_RESOURCES/icons"

echo "========================================"
echo "  VibeCode macOS 安装包打包"
echo "  版本: v${APP_VERSION} (build ${BUILD_NUMBER}) | 架构: ${ARCH_MODE}"
echo "========================================"

echo "==> [1/6] 转换官方图标..."
ICON_TOOL="$WORK_DIR/bin/icon_convert"
swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target "${HOST_ARCH}-apple-macos13.0" \
    "$WORK_DIR/src/icon_convert.swift" -o "$ICON_TOOL"
"$ICON_TOOL" "$PROJECT_ROOT/ico" "$APP_RESOURCES/icons" "$APP_RESOURCES/AppIcon.icns"
cp -f "$APP_RESOURCES/icons/"*.png "$EXT_RESOURCES/icons/"

echo "==> [2/6] 编译宿主应用与 Finder 扩展 (${ARCH_LIST[*]})..."
HOST_BINS=()
EXT_BINS=()
for arch in "${ARCH_LIST[@]}"; do
    target="${arch}-apple-macos13.0"
    host_out="$WORK_DIR/bin/VibeCode-${arch}"
    ext_out="$WORK_DIR/bin/VibeCodeFinderSync-${arch}"

    echo "  [..] 编译 ${arch}..."
    swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target "$target" \
        -framework AppKit -framework Foundation -framework UniformTypeIdentifiers \
        "$WORK_DIR/src/HostApp.swift" \
        -o "$host_out"

    swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target "$target" \
        -application-extension -parse-as-library \
        -module-name VibeCodeFinderSync \
        -Xlinker -e -Xlinker _NSExtensionMain \
        -framework FinderSync -framework AppKit -framework Foundation \
        "$WORK_DIR/src/FinderSync.swift" \
        -o "$ext_out"

    HOST_BINS+=("$host_out")
    EXT_BINS+=("$ext_out")
done

if [[ "${#ARCH_LIST[@]}" -gt 1 ]]; then
    lipo -create "${HOST_BINS[@]}" -output "$APP_MACOS/VibeCode"
    lipo -create "${EXT_BINS[@]}" -output "$EXT_MACOS/VibeCodeFinderSync"
else
    cp -f "${HOST_BINS[0]}" "$APP_MACOS/VibeCode"
    cp -f "${EXT_BINS[0]}" "$EXT_MACOS/VibeCodeFinderSync"
fi
chmod +x "$APP_MACOS/VibeCode" "$EXT_MACOS/VibeCodeFinderSync"
echo "  [OK] $(lipo -info "$APP_MACOS/VibeCode")"

echo "==> [3/6] 组装自包含 Bundle 与纯净配置..."
cp -f "$SCRIPT_DIR/HostApp/Info.plist" "$APP_CONTENTS/Info.plist"
cp -f "$SCRIPT_DIR/FinderSyncExtension/Info.plist" "$EXT_CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP_CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$EXT_CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$EXT_CONTENTS/Info.plist"

# 清理本机 proxy 配置后再打包，避免泄露个人本地代理地址
CLEAN_TOOLS="$WORK_DIR/tools.clean.json"
/usr/bin/python3 - "$PROJECT_ROOT/tools.json" "$CLEAN_TOOLS" <<'PYEOF'
import json, sys
src, dst = sys.argv[1:3]
with open(src, "r", encoding="utf-8-sig") as f:
    data = json.load(f)
stripped = False
if "proxy" in data:
    data.pop("proxy", None)
    stripped = True
for t in data.get("tools", []):
    if "useProxy" in t:
        t.pop("useProxy", None)
        stripped = True
with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
if stripped:
    print("  [--] 已从打包副本 tools.json 中剔除本机 proxy 配置。")
PYEOF

cp -f "$CLEAN_TOOLS" "$APP_RESOURCES/tools.json"
cp -f "$CLEAN_TOOLS" "$EXT_RESOURCES/tools.json"
cp -f "$SCRIPT_DIR/launcher/launch-vibecode-tool.sh" "$APP_RESOURCES/launch-vibecode-tool.sh"
chmod +x "$APP_RESOURCES/launch-vibecode-tool.sh"

echo "==> [4/6] 代码签名 (身份: ${SIGN_IDENTITY})..."
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SIGN_FLAGS+=(--timestamp=none)
else
    # 正式发布证书开启 Hardened Runtime + 时间戳，满足 Apple 公证要求
    SIGN_FLAGS+=(--options runtime --timestamp)
fi

codesign "${SIGN_FLAGS[@]}" \
    --entitlements "$SCRIPT_DIR/FinderSyncExtension/Entitlements.plist" \
    "$EXT_BUNDLE"
codesign "${SIGN_FLAGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
echo "  [OK] 签名验证通过。"

BASE_NAME="VibeCode-v${APP_VERSION}-macOS-${ARCH_MODE}"
DMG_PATH="$OUTPUT_DIR/${BASE_NAME}.dmg"

echo "==> [5/6] 生成 DMG 安装镜像..."
DMG_STAGE="$WORK_DIR/dmg-stage"
mkdir -p "$DMG_STAGE"
cp -R "$APP_BUNDLE" "$DMG_STAGE/VibeCode.app"
ln -s /Applications "$DMG_STAGE/Applications"
cat > "$DMG_STAGE/安装说明.txt" <<EOF
VibeCode Context Menu v${APP_VERSION} (macOS)
作者: 清风惹尘丶
GitHub: https://github.com/myucxy/VibeCodeContextMenu

【安装步骤】
1. 将左侧 VibeCode.app 拖入右侧 Applications（应用程序）文件夹。
2. 在「应用程序」中打开 VibeCode.app，首次启动会自动检测本机已安装的 AI CLI 并激活访达右键扩展。
3. 如访达右键尚未显示 VibeCode，请前往：
   「系统设置 -> 通用 -> 登录项与扩展 -> Finder」，勾选「VibeCode 右键菜单」。

【若打开时提示“无法验证开发者 / 已损坏”】
本安装包为开源社区构建（未做付费 Apple 公证），在终端执行以下一行命令解除隔离即可正常打开：
  xattr -cr /Applications/VibeCode.app
EOF

rm -f "$DMG_PATH" "${DMG_PATH}.sha256"
hdiutil create \
    -volname "VibeCode v${APP_VERSION}" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

if [[ -n "$NOTARIZE_PROFILE" ]]; then
    echo "  [..] 提交 DMG 至 Apple 公证 (profile: $NOTARIZE_PROFILE)..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARIZE_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
fi

DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo "${DMG_SHA}  $(basename "$DMG_PATH")" > "${DMG_PATH}.sha256"
DMG_SIZE="$(du -h "$DMG_PATH" | awk '{print $1}')"

PKG_PATH=""
PKG_SHA=""
PKG_SIZE=""
if [[ "$BUILD_PKG" == "1" ]]; then
    echo "==> [6/6] 生成 PKG 安装向导包..."
    PKG_ROOT="$WORK_DIR/pkg-root"
    PKG_SCRIPTS="$WORK_DIR/pkg-scripts"
    mkdir -p "$PKG_ROOT/Applications" "$PKG_SCRIPTS"
    cp -R "$APP_BUNDLE" "$PKG_ROOT/Applications/VibeCode.app"

    cat > "$PKG_SCRIPTS/postinstall" <<'POSTEOF'
#!/bin/sh
set -e
APP="/Applications/VibeCode.app"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi
CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    CONSOLE_UID="$(id -u "$CONSOLE_USER")"
    launchctl asuser "$CONSOLE_UID" /usr/bin/pluginkit -a "$APP/Contents/PlugIns/VibeCodeFinderSync.appex" >/dev/null 2>&1 || true
    launchctl asuser "$CONSOLE_UID" /usr/bin/pluginkit -e use -i com.vibecode.contextmenu.FinderSync >/dev/null 2>&1 || true
    launchctl asuser "$CONSOLE_UID" /usr/bin/open "$APP" >/dev/null 2>&1 || true
fi
exit 0
POSTEOF
    chmod +x "$PKG_SCRIPTS/postinstall"

    COMPONENT_PKG="$WORK_DIR/VibeCode-component.pkg"
    PKG_PATH="$OUTPUT_DIR/${BASE_NAME}.pkg"
    rm -f "$PKG_PATH" "${PKG_PATH}.sha256"

    pkgbuild \
        --root "$PKG_ROOT" \
        --scripts "$PKG_SCRIPTS" \
        --identifier "com.vibecode.contextmenu" \
        --version "$APP_VERSION" \
        --install-location "/" \
        "$COMPONENT_PKG" >/dev/null

    if [[ -n "$INSTALLER_SIGN_IDENTITY" ]]; then
        productbuild \
            --package "$COMPONENT_PKG" \
            --sign "$INSTALLER_SIGN_IDENTITY" \
            "$PKG_PATH" >/dev/null
    else
        productbuild \
            --package "$COMPONENT_PKG" \
            "$PKG_PATH" >/dev/null
    fi

    if [[ -n "$NOTARIZE_PROFILE" ]]; then
        echo "  [..] 提交 PKG 至 Apple 公证 (profile: $NOTARIZE_PROFILE)..."
        xcrun notarytool submit "$PKG_PATH" --keychain-profile "$NOTARIZE_PROFILE" --wait
        xcrun stapler staple "$PKG_PATH"
    fi

    PKG_SHA="$(shasum -a 256 "$PKG_PATH" | awk '{print $1}')"
    echo "${PKG_SHA}  $(basename "$PKG_PATH")" > "${PKG_PATH}.sha256"
    PKG_SIZE="$(du -h "$PKG_PATH" | awk '{print $1}')"
else
    echo "==> [6/6] 跳过 PKG（如需同时生成 .pkg 可加 --pkg 参数）。"
fi

echo ""
echo "========================================"
echo "  打包完成！v${APP_VERSION} (${ARCH_MODE})"
echo "========================================"
echo "  DMG:    $DMG_PATH ($DMG_SIZE)"
echo "  SHA256: $DMG_SHA"
if [[ -n "$PKG_PATH" ]]; then
    echo "  PKG:    $PKG_PATH ($PKG_SIZE)"
    echo "  SHA256: $PKG_SHA"
fi

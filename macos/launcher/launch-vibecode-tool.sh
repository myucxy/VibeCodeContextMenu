#!/usr/bin/env bash
set -euo pipefail

# VibeCode macOS 统一启动器
# 用法: launch-vibecode-tool.sh <ToolLabel> <TargetPath> [--dry-run]

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <ToolLabel> <TargetPath> [--dry-run]" >&2
    exit 1
fi

TOOL_LABEL="$1"
TARGET_PATH="$2"
DRY_RUN="0"
if [[ "${3:-}" == "--dry-run" ]]; then
    DRY_RUN="1"
fi

SUPPORT_DIR="${VIBECODE_SUPPORT_DIR:-$HOME/Library/Application Support/VibeCode}"
CONFIG_PATH="$SUPPORT_DIR/tools.json"
MACOS_CONFIG_PATH="$SUPPORT_DIR/macos.json"
API_ENV_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/vibecode/env"

if [[ ! -f "$CONFIG_PATH" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [[ -f "$SCRIPT_DIR/tools.json" ]]; then
        CONFIG_PATH="$SCRIPT_DIR/tools.json"
    elif [[ -f "$SCRIPT_DIR/../../tools.json" ]]; then
        CONFIG_PATH="$SCRIPT_DIR/../../tools.json"
    else
        echo "VibeCode config not found: $CONFIG_PATH" >&2
        exit 1
    fi
fi

# 若传入的是文件路径，自动解析其所在目录
if [[ -f "$TARGET_PATH" ]]; then
    TARGET_DIR="$(cd "$(dirname "$TARGET_PATH")" && pwd)"
elif [[ -d "$TARGET_PATH" ]]; then
    TARGET_DIR="$(cd "$TARGET_PATH" && pwd)"
else
    echo "Target directory does not exist: $TARGET_PATH" >&2
    exit 1
fi

RUNNER_DIR="${TMPDIR:-/tmp}/vibecode-runners"
mkdir -p "$RUNNER_DIR"
chmod 700 "$RUNNER_DIR" 2>/dev/null || true

# 使用系统自带 python3 安全解析 tools.json / macos.json 并生成唯一临时执行脚本
PY_OUT="$(/usr/bin/python3 - "$CONFIG_PATH" "$MACOS_CONFIG_PATH" "$TOOL_LABEL" "$TARGET_DIR" "$API_ENV_PATH" "$RUNNER_DIR" <<'PYEOF'
import json
import os
import shlex
import subprocess
import sys
import tempfile

config_path, macos_config_path, tool_label, target_dir, api_env_path, runner_dir = sys.argv[1:7]

with open(config_path, "r", encoding="utf-8-sig") as f:
    config = json.load(f)

macos_cfg = {}
if os.path.isfile(macos_config_path):
    try:
        with open(macos_config_path, "r", encoding="utf-8") as f:
            macos_cfg = json.load(f) or {}
    except Exception:
        macos_cfg = {}

tool_map = {}
for t in config.get("tools", []):
    use_proxy = t.get("useProxy", True) is not False
    name = t.get("name", "")
    command = t.get("command", "")
    if not name or not command:
        continue
    tool_map[name] = {
        "command": command,
        "env": {},
        "useProxy": use_proxy,
    }
    super_cfg = t.get("super")
    if isinstance(super_cfg, dict) and super_cfg.get("label") and super_cfg.get("command"):
        super_env = super_cfg.get("env") if isinstance(super_cfg.get("env"), dict) else {}
        super_label = super_cfg["label"]
        super_cmd = super_cfg["command"]
        tool_map[super_label] = {
            "command": super_cmd,
            "env": super_env,
            "useProxy": use_proxy,
        }
        resume_cfg = super_cfg.get("resume")
        if isinstance(resume_cfg, dict) and resume_cfg.get("command"):
            resume_cmd = resume_cfg["command"]
        else:
            resume_cmd = f"{super_cmd} -R"
        tool_map[f"{super_label}-R"] = {
            "command": resume_cmd,
            "env": super_env,
            "useProxy": use_proxy,
        }

if tool_label not in tool_map:
    sys.stderr.write(f"Unknown VibeCode tool: {tool_label}\n")
    sys.exit(2)

entry = tool_map[tool_label]
proxy_cfg = config.get("proxy") if isinstance(config.get("proxy"), dict) else {}
global_env = config.get("globalEnv") if isinstance(config.get("globalEnv"), dict) else {}

env_lines = []

# 加载用户通过 VibeCode 配置的 API Key 环境变量文件
env_lines.append(f'if [[ -f {shlex.quote(api_env_path)} ]]; then source {shlex.quote(api_env_path)}; fi')

# 代理环境变量控制（对齐 Windows 版逻辑，同时兼容大小写变量名，支持 system 实时跟随与 manual 固定地址）
def detect_macos_system_proxy():
    try:
        out = subprocess.check_output(["/usr/sbin/scutil", "--proxy"], text=True, timeout=3)
    except Exception:
        return ""
    kv = {}
    for line in out.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            kv[k.strip()] = v.strip()
    if kv.get("HTTPSEnable") == "1" and kv.get("HTTPSProxy") and kv.get("HTTPSPort"):
        return f"http://{kv['HTTPSProxy']}:{kv['HTTPSPort']}"
    if kv.get("HTTPEnable") == "1" and kv.get("HTTPProxy") and kv.get("HTTPPort"):
        return f"http://{kv['HTTPProxy']}:{kv['HTTPPort']}"
    if kv.get("SOCKSEnable") == "1" and kv.get("SOCKSProxy") and kv.get("SOCKSPort"):
        return f"socks5://{kv['SOCKSProxy']}:{kv['SOCKSPort']}"
    return ""

if not entry["useProxy"]:
    env_lines.append("unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy")
elif proxy_cfg.get("enabled"):
    proxy_mode = str(proxy_cfg.get("mode") or "manual").strip().lower()
    proxy_url = detect_macos_system_proxy() if proxy_mode == "system" else str(proxy_cfg.get("url", "")).strip()
    if proxy_url:
        no_proxy = str(proxy_cfg.get("noProxy") or "localhost,127.0.0.1,::1").strip()
        q_url = shlex.quote(proxy_url)
        q_no = shlex.quote(no_proxy)
        env_lines.append(f"export HTTP_PROXY={q_url} HTTPS_PROXY={q_url} http_proxy={q_url} https_proxy={q_url}")
        env_lines.append(f"export NO_PROXY={q_no} no_proxy={q_no}")
        if proxy_url.lower().startswith("socks"):
            env_lines.append(f"export ALL_PROXY={q_url} all_proxy={q_url}")
    elif proxy_mode == "system":
        env_lines.append("unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy")

# 全局环境变量
for k, v in global_env.items():
    if isinstance(k, str) and k and all(ch.isalnum() or ch == "_" for ch in k):
        env_lines.append(f"export {k}={shlex.quote(str(v))}")

# Super 专用环境变量（覆盖同名 globalEnv）
for k, v in entry["env"].items():
    if isinstance(k, str) and k and all(ch.isalnum() or ch == "_" for ch in k):
        env_lines.append(f"export {k}={shlex.quote(str(v))}")

env_block = "\n".join(env_lines)
dir_name = os.path.basename(target_dir.rstrip("/")) or "/"
title = f"VibeCode - {tool_label} ({dir_name})"
command_str = entry["command"]
primary_bin = shlex.split(command_str)[0] if command_str.strip() else ""

# 内层脚本：在登录交互 Shell 中执行，保证 nvm / homebrew / ~/.local/bin / ~/.opencode/bin 全部加载
inner_script = f"""
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
cd -- {shlex.quote(target_dir)} || exit 1
printf '\\033]0;%s\\007' {shlex.quote(title)}
{env_block}
if ! command -v {shlex.quote(primary_bin)} >/dev/null 2>&1; then
    printf '\\033[31m[VibeCode] 未找到命令: %s\\033[0m\\n' {shlex.quote(primary_bin)}
    printf '当前 PATH: %s\\n' "$PATH"
else
    printf '\\033[36m[VibeCode] %s\\033[0m -> %s\\n' {shlex.quote(tool_label)} {shlex.quote(target_dir)}
    eval {shlex.quote(command_str)}
fi
exec "${{SHELL:-/bin/zsh}}" -l
"""

runner_content = (
    "#!/bin/sh\n"
    'rm -f "$0"\n'
    'export SHELL_SESSIONS_DISABLE=1\n'
    'USER_SHELL="${SHELL:-/bin/zsh}"\n'
    'case "$USER_SHELL" in\n'
    '    */zsh|*/bash)\n'
    f'        exec "$USER_SHELL" -l -i -c {shlex.quote(inner_script)}\n'
    '        ;;\n'
    '    *)\n'
    f'        exec /bin/zsh -l -i -c {shlex.quote(inner_script)}\n'
    '        ;;\n'
    'esac\n'
)

fd, runner_file = tempfile.mkstemp(prefix="vibecode-", suffix=".command", dir=runner_dir)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(runner_content)
os.chmod(runner_file, 0o700)

terminal_pref = str(macos_cfg.get("terminal") or "Terminal").strip()
terminal_app_path = str(macos_cfg.get("terminalAppPath") or "").strip()
print(terminal_pref)
print(terminal_app_path)
print(runner_file)
PYEOF
)"

{
    IFS= read -r TERMINAL_APP
    IFS= read -r TERMINAL_APP_PATH
    IFS= read -r RUNNER_FILE
} <<< "$PY_OUT"

if [[ "$DRY_RUN" == "1" ]]; then
    echo "TERMINAL=$TERMINAL_APP"
    echo "TERMINAL_APP_PATH=$TERMINAL_APP_PATH"
    echo "RUNNER=$RUNNER_FILE"
    cat "$RUNNER_FILE"
    rm -f "$RUNNER_FILE"
    exit 0
fi

resolve_app_path() {
    local preferred="$1"
    shift
    if [[ -n "$preferred" && -d "$preferred" ]]; then
        echo "$preferred"
        return 0
    fi
    for candidate in "$@"; do
        if [[ -d "/Applications/$candidate" ]]; then
            echo "/Applications/$candidate"
            return 0
        fi
        if [[ -d "$HOME/Applications/$candidate" ]]; then
            echo "$HOME/Applications/$candidate"
            return 0
        fi
    done
    return 1
}

launch_warp() {
    local warp_dir="$HOME/.warp/launch_configurations"
    mkdir -p "$warp_dir"
    local warp_yaml="$warp_dir/vibecode-launch.yaml"
    /usr/bin/python3 - "$warp_yaml" "$TARGET_DIR" "$RUNNER_FILE" <<'PYEOF'
import json, shlex, sys
yaml_path, target_dir, runner_file = sys.argv[1:4]
# 使用 JSON 字符串转义保证 YAML 合法（YAML 1.2 完全兼容 JSON 双引号字符串）
content = (
    "---\n"
    "name: VibeCode Launch\n"
    "windows:\n"
    "  - tabs:\n"
    "      - layout:\n"
    f"          cwd: {json.dumps(target_dir, ensure_ascii=False)}\n"
    "          commands:\n"
    f"            - exec: {json.dumps(shlex.quote(runner_file), ensure_ascii=False)}\n"
)
with open(yaml_path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
    open "warp://launch/vibecode-launch.yaml"
}

launch_terminal() {
    local term="$1"
    local app_path=""
    case "$term" in
        iTerm|iTerm2)
            if open -b com.googlecode.iterm2 "$RUNNER_FILE" 2>/dev/null; then
                return 0
            fi
            if app_path="$(resolve_app_path "$TERMINAL_APP_PATH" "iTerm.app" "iTerm2.app")"; then
                open -a "$app_path" "$RUNNER_FILE"
                return 0
            fi
            ;;
        Ghostty)
            if app_path="$(resolve_app_path "$TERMINAL_APP_PATH" "Ghostty.app")"; then
                open -na "$app_path" --args -e "$RUNNER_FILE"
                return 0
            fi
            ;;
        Warp)
            if resolve_app_path "$TERMINAL_APP_PATH" "Warp.app" "WarpPreview.app" >/dev/null 2>&1; then
                launch_warp
                return 0
            fi
            ;;
        WezTerm)
            if app_path="$(resolve_app_path "$TERMINAL_APP_PATH" "WezTerm.app")"; then
                open -na "$app_path" --args start --cwd "$TARGET_DIR" -- "$RUNNER_FILE"
                return 0
            fi
            ;;
        Kitty|kitty)
            if app_path="$(resolve_app_path "$TERMINAL_APP_PATH" "kitty.app")"; then
                open -na "$app_path" --args --directory "$TARGET_DIR" "$RUNNER_FILE"
                return 0
            fi
            ;;
        Alacritty)
            if app_path="$(resolve_app_path "$TERMINAL_APP_PATH" "Alacritty.app")"; then
                open -na "$app_path" --args --working-directory "$TARGET_DIR" -e "$RUNNER_FILE"
                return 0
            fi
            ;;
        Rio)
            if app_path="$(resolve_app_path "$TERMINAL_APP_PATH" "Rio.app")"; then
                open -na "$app_path" --args --working-dir "$TARGET_DIR" -e "$RUNNER_FILE"
                return 0
            fi
            ;;
        Tabby)
            if app_path="$(resolve_app_path "$TERMINAL_APP_PATH" "Tabby.app")"; then
                open -na "$app_path" --args run "$RUNNER_FILE"
                return 0
            fi
            ;;
        Hyper)
            if app_path="$(resolve_app_path "$TERMINAL_APP_PATH" "Hyper.app")"; then
                open -a "$app_path" "$RUNNER_FILE"
                return 0
            fi
            ;;
        Terminal|"")
            open -b com.apple.Terminal "$RUNNER_FILE" 2>/dev/null || open -a "Terminal" "$RUNNER_FILE"
            return 0
            ;;
        *)
            if [[ -n "$TERMINAL_APP_PATH" && -d "$TERMINAL_APP_PATH" ]]; then
                open -a "$TERMINAL_APP_PATH" "$RUNNER_FILE"
                return 0
            elif [[ -d "/Applications/${term}.app" ]]; then
                open -a "$term" "$RUNNER_FILE"
                return 0
            fi
            ;;
    esac
    # 回退到系统自带 Terminal.app
    open -b com.apple.Terminal "$RUNNER_FILE" 2>/dev/null || open -a "Terminal" "$RUNNER_FILE"
}

launch_terminal "$TERMINAL_APP"

# VibeCode Context Menu

Windows 右键菜单管理工具，为文件夹快速启动各种 AI CLI 工具。
![样例](a.png)
## 目录结构

```
VibeCodeContextMenu/
├── VibeCode.ps1          # 主程序（PowerShell）
├── VibeCode.bat          # 双击运行入口
├── tools.json            # 工具配置文件（首次运行自动生成）
├── README.md             # 使用说明
├── a.png                 # 使用示例图
├── installers/           # Terminal、PowerShell、NVM、Node、AI CLI 离线包
├── ico/                  # 图标文件
│   ├── vibecode.ico         # 主菜单图标
│   ├── claude.ico
│   ├── codex.ico
│   └── opencode.ico
```

## 快速开始

双击 `VibeCode.bat`，或在 PowerShell 中运行：

```powershell
.\VibeCode.ps1
```

选择 `1) 安装右键菜单`，再输入一个或多个工具编号。安装列表默认不选择任何工具，直接回车会取消；多个编号可用逗号或空格分隔。

本项目仅支持 64 位 Windows（x64/ARM64）。在 32 位 Windows 上启动时会直接提示不支持并退出。

安装脚本会自动检查 Windows Terminal 和 PowerShell 7。两项基础运行环境缺失时仍只使用项目携带的对应架构离线包，不访问 Microsoft Store 或下载安装程序。
所选的 Codex、Claude、OpenCode 缺失时会先征求确认：网络可用则通过 npm 安装最新版，网络不可用或在线安装失败则使用项目内离线 CLI 束。Grok CLI 由其官方安装程序独立管理，本项目检测到 `grok` 命令后即可为它安装菜单。
最终写入可执行文件的稳定完整路径，可兼容 Windows Terminal 配置为管理员启动的场景。

## 制作可分发离线包

项目源码根目录提供 `Pack-VibeCode.bat` 和 `Pack-VibeCode.ps1`。直接双击 `Pack-VibeCode.bat` 即可生成压缩包；窗口会保留打包结果，按任意键后关闭。

也可以在 PowerShell 中运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Pack-VibeCode.ps1
```

默认生成 `dist\VibeCodeContextMenu-offline.zip`。再次生成时使用 `-Force` 覆盖已有文件，也可以通过 `-OutputPath` 指定其他 ZIP 路径。

`Pack-VibeCode.bat` 默认自动启用 `-Force`，方便反复双击重新打包。命令行调用 BAT 时可添加 `-NoPause`，让打包结束后直接返回。

打包脚本会先校验全部离线资源的 SHA-256，再根据运行时白名单生成压缩包并复查包内文件。成品包含使用说明和示例图，但不会包含打包脚本、`.git`、`.claude`、`.agents`、`dev`、`dist`、开发缓存或未使用的安装资料。

## 功能菜单

```
========================================
  VibeCode 工具管理
========================================

  1) 安装右键菜单     # 选择一个或多个 AI 工具后注册对应菜单
  2) 卸载右键菜单     # 按 AI 工具成组卸载（支持多选或全部）
  3) 查看工具状态     # 显示运行环境与各工具安装情况
  4) 安装/修复运行环境
  5) 安装/更新 Codex、Claude、OpenCode CLI
  6) 配置 Codex/Claude API
  0/Q) 退出
```

## 运行环境离线部署

### Windows Terminal

1. 检测已有的 `wt.exe` 或 VibeCode 独立版；检测阶段不执行 `wt.exe`，避免探测命令产生额外 Terminal 窗口。
2. 缺失时按当前系统架构读取 `installers/windows-terminal` 中的 ZIP。
3. SHA-256 与 Microsoft 数字签名验证通过后，部署到 `%LOCALAPPDATA%\Programs\VibeCodeRuntime\WindowsTerminal`。
4. 使用 portable mode，不需要管理员权限，也不会调用商店或下载安装程序。

项目携带 x64、ARM64 两种架构的官方 Terminal 独立包，版本与 SHA-256 记录在 `installers/installers.json`。

### PowerShell 7

1. 检测 PowerShell 7；系统自带 Windows PowerShell 5.1 不会被误认为满足条件。
2. 缺失时按当前系统架构读取 `installers/powershell` 中的 ZIP。
3. SHA-256 与 `pwsh.exe` 的 Microsoft 数字签名验证通过后，部署到 `%LOCALAPPDATA%\Programs\VibeCodeRuntime\PowerShell`。
4. 项目携带 PowerShell 7.6.4 的 x64、ARM64 两种官方 portable ZIP，不需要 MSI 或 UAC。

即使系统中完全没有 PowerShell，`VibeCode.bat` 也只会使用项目内离线 ZIP：通过系统自带的 `certutil` 校验 SHA-256，使用 `tar` 解压并启动。缺包或校验失败会直接报错，不会尝试联网。

> 两类运行环境的文件名、版本和 SHA-256 均记录在 `installers/installers.json`。卸载右键菜单不会删除已部署的运行环境。

仓库使用 Git LFS 保存 `installers/**/*.zip`。制作离线副本时必须包含 LFS 实体文件；若 ZIP 只有一行 LFS 指针文本，离线部署会因 SHA-256 校验失败而停止。

## AI CLI 自动安装

安装右键菜单时只检查本次选择的工具。所选工具包含缺失的 `codex`、`claude`、`opencode` 时，可进入自动安装：

1. 检测 Node.js 22 或更高版本；缺失时把 NVM 1.2.2 免安装版部署到 `%LOCALAPPDATA%\Programs\VibeCodeRuntime\Nvm`。
2. 网络可用时，从 Node.js 官方清单下载并校验最新 LTS；失败或断网时使用内置 Node.js 24.18.0 LTS。
3. 网络可用时，通过 npm 安装三款 CLI 的 `latest`；任一在线安装失败时启用对应架构的离线 CLI 束。
4. 离线束当前固定版本：Codex 0.145.0、Claude 2.1.220、OpenCode 1.18.6，包含 x64 与 ARM64 平台二进制。

Grok CLI 不在 npm/离线 CLI 束中；请先使用 Grok 官方方式安装，使 `grok` 命令进入 PATH。菜单安装页会显示其检测状态。

整个项目仅支持 64 位 Windows（x64/ARM64），不包含任何 32 位离线包。代理可通过 `HTTP_PROXY`、`HTTPS_PROXY` 用户或进程环境变量提供。

## Codex/Claude API 配置

右键菜单安装完成后，脚本会检查已安装的 Codex/Claude 是否存在 API Key；缺失时询问是否进入配置引导。也可随时选择主菜单 `6` 手动配置。

| 工具 | Key 环境变量 | API 地址环境变量 | 未设置 API 地址时 |
|------|---------------|------------------|-------------------|
| Codex | `OPENAI_API_KEY` | `OPENAI_BASE_URL` | 使用 OpenAI 官方默认地址 |
| Claude | `ANTHROPIC_API_KEY` | `ANTHROPIC_BASE_URL` | 使用 Anthropic 官方默认地址 |

Key 使用隐藏输入，并保存到当前用户环境变量；脚本状态页只显示“已配置/未配置”，不会输出 Key。启动器每次运行都会从用户环境重新加载这些变量，因此无需重启 Explorer，也不会把密钥写入项目或发布 ZIP。

## 配置文件 (tools.json)

首次运行时自动生成默认配置，也可手动编辑。

### 基本结构

```json
{
  "menuName": "VibeCode",
  "menuLabel": "VibeCode",
  "globalEnv": {},
  "tools": [...]
}
```

| 字段 | 说明 |
|------|------|
| `menuName` | 注册表中的键名；必须是 1-80 字符的安全单目录名称，不能包含路径分隔符、非法字符、Windows 保留设备名或受保护的系统目录名 |
| `menuLabel` | 右键菜单显示的名称 |
| `globalEnv` | 所有工具共享的环境变量 |

### 工具配置

每个工具是一个对象，支持以下字段：

```json
{
  "name": "claude",
  "command": "claude",
  "icon": "claude.ico",
  "super": {
    "command": "claude --dangerously-skip-permissions",
    "label": "claudeSuper",
    "env": {},
    "resume": {
      "command": "claude --dangerously-skip-permissions -r"
    }
  }
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `name` | 是 | 菜单项名称 |
| `command` | 是 | 用于检测是否已安装（`Get-Command`） |
| `icon` | 是 | 图标文件名（放在 `ico/` 目录下） |
| `super` | 否 | Super 模式配置，不填则不生成 Super 菜单 |
| `super.command` | 是 | Super 模式执行的命令 |
| `super.label` | 是 | Super 菜单项名称 |
| `super.env` | 否 | Super 模式专用的环境变量 |
| `super.resume.command` | 否 | Super 恢复菜单执行的命令；省略时使用 `super.command -R` |

### 添加新工具示例

添加 GitHub Copilot（无 Super 模式）：

```json
{
  "name": "copilot",
  "command": "gh",
  "icon": "copilot.ico"
}
```

添加 Aider（带 Super 模式）：

```json
{
  "name": "aider",
  "command": "aider",
  "icon": "aider.ico",
  "super": {
    "command": "aider --yes-always",
    "label": "aiderSuper"
  }
}
```

添加 npm 全局安装的工具：

```json
{
  "name": "my-ai-tool",
  "command": "npx",
  "icon": "mytool.ico",
  "super": {
    "command": "npx @scope/ai-tool --unsafe",
    "label": "myToolSuper"
  }
}
```

## Super 模式说明

右键菜单中带 **Super** 后缀的菜单项，是对应工具的「超级模式」，用于跳过安全确认、启用全自动执行。典型场景：

| 工具 | 普通模式 | Super 模式 | 区别 |
|------|----------|------------|------|
| Claude | `claude` | `claude --dangerously-skip-permissions` | 跳过权限确认，自动执行所有操作 |
| Grok | `grok` | `grok --always-approve` | 自动批准所有工具执行；恢复菜单额外使用 `-r` |
| Aider | `aider` | `aider --yes-always` | 自动确认所有代码修改 |
| OpenCode | `opencode` | `opencode` + `OPENCODE_PERMISSION=full` | 通过环境变量授予完整权限 |

**适用场景**：在沙箱/虚拟机/测试环境中，信任 AI 对文件的全部操作，不想被反复弹窗打断。

**注意**：Super 模式会绕过工具内置的安全检查，请仅在安全可控的环境中使用。

## 工作原理

1. **安装时**：先选择一个或多个工具；仅检查所选 AI CLI，并按“在线最新版、离线兜底”准备可自动安装的缺失工具；随后从项目内离线包确保 Terminal 与 PowerShell 7 可用，再将启动器、配置和图标释放到 `%LOCALAPPDATA%\VibeCode\`，并使已知工具菜单与本次选择保持一致
2. **点击菜单时**：Windows Terminal 打开 PowerShell，运行启动器脚本，根据配置执行对应命令
3. **卸载时**：删除注册表项和部署文件

## 环境变量说明

- `globalEnv`：所有工具启动前都会设置的环境变量
- `super.env`：仅 Super 模式启动前设置的环境变量（如 `OPENCODE_PERMISSION`）

两者可同时使用，Super 模式的环境变量会覆盖 `globalEnv` 中的同名变量。

## 图标

- 主菜单图标固定使用 `ico/vibecode.ico`
- 各工具图标通过 `tools.json` 中的 `icon` 字段指定
- 图标放在 `ico/` 目录下，安装时会复制到部署目录

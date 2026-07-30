# VibeCode 离线安装资源

本目录携带运行 VibeCode 所需的 x64/ARM64 离线兜底资源：

- `windows-terminal/`：Microsoft 官方 Windows Terminal standalone ZIP。
- `powershell/`：Microsoft 官方 PowerShell 7 portable ZIP。
- `nvm/`：NVM for Windows 1.2.2 noinstall ZIP。
- `node/`：Node.js 24.18.0 LTS x64/ARM64 ZIP。
- `ai-cli/`：Codex、Claude、OpenCode 的 x64/ARM64 完整离线依赖束。

版本、文件名与 SHA-256 记录在 `installers.json`。Terminal 与 PowerShell 始终只从本目录离线部署。AI CLI 安装采用在线最新版优先；网络不可用或在线安装失败时校验并部署本目录资产。

`VibeCode.bat` 在系统完全没有 PowerShell 时读取 `powershell/portable-sha256.txt`，校验对应 ZIP 后离线引导 PowerShell 7。

本项目不支持 32 位 Windows，不携带 32 位离线包。

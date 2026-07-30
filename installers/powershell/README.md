# PowerShell 7 离线包

本目录已包含 PowerShell 7.6.4 官方 portable ZIP：

- `PowerShell-7.6.4-win-x64.zip`
- `PowerShell-7.6.4-win-arm64.zip`

`installers.json` 是 PowerShell 主脚本使用的校验清单；`portable-sha256.txt` 是系统完全没有 PowerShell 时供 `VibeCode.bat` 使用的 ASCII 校验表。

安装逻辑不会访问网络。ZIP 缺失、数量异常或 SHA-256 不匹配时会停止部署。

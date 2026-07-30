#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Host '不支持 32 位 Windows。本项目仅支持 64 位 Windows（x64/ARM64）。' `
        -ForegroundColor Red
    exit 1
}

$script:VibeCodeRuntimeRoot = Join-Path $env:LOCALAPPDATA 'Programs\VibeCodeRuntime'
$script:VibeCodeInstallerManifest = Join-Path $PSScriptRoot 'installers\installers.json'
$script:VibeCodeNvmRoot = Join-Path $script:VibeCodeRuntimeRoot 'Nvm'
$script:VibeCodeNodeLink = Join-Path $script:VibeCodeRuntimeRoot 'NodeCurrent'
$script:VibeCodeAiCliRoot = Join-Path $script:VibeCodeRuntimeRoot 'AiCli'

# ============================================================
# 内嵌启动器 (Start-VibeCodeTool.ps1)
# ============================================================
$EmbeddedLauncher = @'
param(
    [Parameter(Mandatory = $true)]
    [string]$Tool,

    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$configPath = Join-Path $scriptDir 'tools.json'

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Host "Config not found: $configPath" -ForegroundColor Red
    return
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Host "Folder does not exist: $Path" -ForegroundColor Red
    return
}

Set-Location -LiteralPath $Path

# Explorer may not immediately inherit newly written user environment variables.
# Refresh the API settings and VibeCode-managed runtime paths for every launch.
foreach ($name in @(
    'OPENAI_API_KEY',
    'OPENAI_BASE_URL',
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_BASE_URL',
    'NVM_HOME',
    'NVM_SYMLINK'
)) {
    $value = [Environment]::GetEnvironmentVariable($name, 'User')
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Machine')
    }
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        Set-Item -Path "env:$name" -Value $value
    }
}

$runtimeRoot = Join-Path $env:LOCALAPPDATA 'Programs\VibeCodeRuntime'
$preferredPaths = @(
    (Join-Path $runtimeRoot 'NodeCurrent'),
    (Join-Path $runtimeRoot 'Nvm')
)
$currentUserPaths = @()
foreach ($scope in @('Machine', 'User')) {
    $scopePath = [Environment]::GetEnvironmentVariable('Path', $scope)
    if (-not [string]::IsNullOrWhiteSpace($scopePath)) {
        $currentUserPaths += $scopePath -split ';'
    }
}
$fallbackPaths = @(
    (Join-Path $runtimeRoot 'AiCli\node_modules\.bin')
)
if ($env:APPDATA) {
    $fallbackPaths += Join-Path $env:APPDATA 'npm'
}
$env:Path = @(
    $preferredPaths + $currentUserPaths + @($env:Path -split ';') + $fallbackPaths |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim()) } |
        Select-Object -Unique
) -join ';'

$toolMap = @{}

foreach ($t in $config.tools) {
    $toolMap[$t.name] = @{
        Command = $t.command
        Env     = $null
    }

    if ($t.super) {
        $envVars = $null
        if ($t.super.env) {
            $envVars = @{}
            $t.super.env.PSObject.Properties | ForEach-Object {
                $envVars[$_.Name] = $_.Value
            }
        }
        $toolMap[$t.super.label] = @{
            Command = $t.super.command
            Env     = $envVars
        }
        $resumeCommand = if ($t.super.resume -and $t.super.resume.command) {
            $t.super.resume.command
        } else {
            "$($t.super.command) -R"
        }
        $toolMap["$($t.super.label)-R"] = @{
            Command = $resumeCommand
            Env     = $envVars
        }
    }
}

if (-not $toolMap.ContainsKey($Tool)) {
    Write-Host "Unknown tool: $Tool" -ForegroundColor Red
    return
}

$entry = $toolMap[$Tool]

if ($config.globalEnv) {
    $config.globalEnv.PSObject.Properties | ForEach-Object {
        Set-Item -Path "env:$($_.Name)" -Value $_.Value
    }
}

if ($entry.Env) {
    foreach ($kv in $entry.Env.GetEnumerator()) {
        Set-Item -Path "env:$($kv.Key)" -Value $kv.Value
    }
}

Invoke-Expression $entry.Command
'@

# ============================================================
# 辅助函数
# ============================================================
function Test-ToolInstalled {
    param([string]$CommandName)
    return [bool](Get-Command $CommandName -ErrorAction SilentlyContinue)
}

function Get-NativeArchitecture {
    $architecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = if ($env:PROCESSOR_ARCHITEW6432) {
            $env:PROCESSOR_ARCHITEW6432
        } else {
            $env:PROCESSOR_ARCHITECTURE
        }
    }

    switch ($architecture.ToUpperInvariant()) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default {
            throw "不支持的系统架构: $architecture。本项目仅支持 x64/ARM64。"
        }
    }
}

function Get-SafeMenuName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 80) {
        throw 'menuName 必须是 1 到 80 个字符的单目录名称。'
    }
    if ($Name.Trim() -ne $Name -or $Name -in @('.', '..')) {
        throw "不安全的 menuName: $Name"
    }
    if ($Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        [IO.Path]::IsPathRooted($Name)) {
        throw "menuName 不能包含路径或文件名非法字符: $Name"
    }
    if ($Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
        throw "menuName 不能使用 Windows 保留名称: $Name"
    }
    if ($Name -match '^(?i:Programs|Microsoft|Packages|Temp)$') {
        throw "menuName 不能使用受保护的系统目录名称: $Name"
    }

    return $Name
}

function Get-VibeCodeDeployDirectory {
    param([Parameter(Mandatory = $true)][string]$MenuName)

    $null = Get-SafeMenuName -Name $MenuName
    $localAppDataRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
    $deployDirectory = [IO.Path]::GetFullPath(
        (Join-Path $localAppDataRoot 'VibeCode')
    ).TrimEnd('\')
    $expectedDirectory = "$localAppDataRoot\VibeCode"
    if (-not $deployDirectory.Equals($expectedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw "部署目录超出允许范围: $deployDirectory"
    }

    return $deployDirectory
}

function Update-ProcessPath {
    $pathEntries = @()
    foreach ($scope in @('Machine', 'User')) {
        $scopePath = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ($scopePath) {
            $pathEntries += $scopePath -split ';'
        }
    }

    if ($env:Path) {
        $pathEntries += $env:Path -split ';'
    }

    $pathEntries += @(
        (Join-Path $script:VibeCodeRuntimeRoot 'PowerShell'),
        (Join-Path $script:VibeCodeAiCliRoot 'node_modules\.bin'),
        $script:VibeCodeNodeLink,
        $script:VibeCodeNvmRoot,
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
    )
    if ($env:APPDATA) {
        $pathEntries += Join-Path $env:APPDATA 'npm'
    }
    foreach ($name in @('NVM_HOME', 'NVM_SYMLINK')) {
        foreach ($scope in @('User', 'Machine')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if ($value) {
                $pathEntries += $value
            }
        }
    }

    $pathEntries = @($script:VibeCodeNodeLink, $script:VibeCodeNvmRoot) + $pathEntries
    $env:Path = @($pathEntries |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim()) } |
        Select-Object -Unique) -join ';'
}

function Test-PowerShellAppxAlias {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        try {
            $package = Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction Stop
            return $package -and $package.Status -eq 'Ok' -and
                $package.Version.Major -ge 7
        } catch {
            return $false
        }
    }

    $windowsPowerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        return $false
    }

    $probe = @'
$package = Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction SilentlyContinue
if ($package -and $package.Status -eq 'Ok' -and $package.Version.Major -ge 7) { exit 0 }
exit 1
'@
    $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
    & $windowsPowerShell -NoLogo -NoProfile -NonInteractive `
        -EncodedCommand $encodedProbe *> $null
    return $LASTEXITCODE -eq 0
}

function Test-PowerShell7Path {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $storeAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    if ($Path.Equals($storeAlias, [StringComparison]::OrdinalIgnoreCase)) {
        return Test-PowerShellAppxAlias -Path $Path
    }

    try {
        $output = @(& $Path -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.Major' 2>$null)
        $exitCode = $LASTEXITCODE
        $major = 0
        return $exitCode -eq 0 -and
            [int]::TryParse([string]($output | Select-Object -Last 1), [ref]$major) -and
            $major -ge 7
    } catch {
        return $false
    }
}

function Test-WindowsTerminalPath {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $standaloneDirectory = Join-Path $script:VibeCodeRuntimeRoot 'WindowsTerminal'
    if ($Path.StartsWith($standaloneDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        $windowsTerminalPath = Join-Path $standaloneDirectory 'WindowsTerminal.exe'
        return (Test-Path -LiteralPath (Join-Path $standaloneDirectory '.portable') -PathType Leaf) -and
            (Test-MicrosoftSignature -Path $Path) -and
            (Test-MicrosoftSignature -Path $windowsTerminalPath)
    }

    $storeAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    if ($Path.Equals($storeAlias, [StringComparison]::OrdinalIgnoreCase)) {
        return Test-WindowsTerminalAppxAlias -Path $Path
    }

    # Do not execute wt.exe for detection: some Terminal versions treat unknown
    # switches as a new-tab command and would open a visible window.
    return Test-MicrosoftSignature -Path $Path
}

function Test-WindowsTerminalAppxAlias {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        try {
            $package = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction Stop
            return $package -and $package.Status -eq 'Ok'
        } catch {
            return $false
        }
    }

    $windowsPowerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) {
        $probe = @'
$package = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue
if ($package -and $package.Status -eq 'Ok') { exit 0 }
exit 1
'@
        $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        & $windowsPowerShell -NoLogo -NoProfile -NonInteractive `
            -EncodedCommand $encodedProbe *> $null
        return $LASTEXITCODE -eq 0
    }

    # Without the AppX provider there is no reliable non-launching health probe.
    # Treat the alias as unavailable so the verified standalone package is used.
    return $false
}

function Get-PowerShell7Path {
    $candidates = @()

    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    }
    $candidates += Join-Path $script:VibeCodeRuntimeRoot 'PowerShell\pwsh.exe'

    foreach ($registryRoot in @(
        'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions',
        'HKCU:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions'
    )) {
        if (Test-Path -LiteralPath $registryRoot) {
            Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue | ForEach-Object {
                $installLocation = $_.GetValue('InstallLocation')
                if ($installLocation) {
                    $candidates += Join-Path $installLocation 'pwsh.exe'
                }
            }
        }
    }

    $candidates += Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    $command = Get-Command 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command -and $command.Path -and $command.Path -notmatch '\\Program Files\\WindowsApps\\') {
        $candidates += $command.Path
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (Test-PowerShell7Path -Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-WindowsTerminalPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'),
        (Join-Path $script:VibeCodeRuntimeRoot 'WindowsTerminal\wt.exe')
    )

    $command = Get-Command 'wt.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command -and $command.Path -and $command.Path -notmatch '\\Program Files\\WindowsApps\\') {
        $candidates += $command.Path
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (Test-WindowsTerminalPath -Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-InstallerManifest {
    if (-not (Test-Path -LiteralPath $script:VibeCodeInstallerManifest -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $script:VibeCodeInstallerManifest -Raw -Encoding UTF8 |
            ConvertFrom-Json
    } catch {
        Write-Host "  [--] 安装包清单无效: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Test-ExpectedFileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return $actual -eq $ExpectedSha256
}

function Test-MicrosoftSignature {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    return $signature.Status -eq 'Valid' -and
        $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match '(?i)CN=Microsoft (Corporation|Windows)'
}

function Get-TerminalStandalonePackage {
    param([Parameter(Mandatory = $true)][string]$Architecture)

    $manifest = Get-InstallerManifest
    if (-not $manifest -or -not $manifest.windowsTerminal -or
        -not $manifest.windowsTerminal.portable) {
        throw '离线安装包清单中缺少 Windows Terminal 配置。'
    }

    $assetProperty = $manifest.windowsTerminal.portable.assets.PSObject.Properties[$Architecture]
    if (-not $assetProperty) {
        throw "离线安装包清单中缺少 Windows Terminal $Architecture 包。"
    }

    $entry = $assetProperty.Value
    $fileName = [IO.Path]::GetFileName([string]$entry.file)
    if ($fileName -ne [string]$entry.file -or [string]$entry.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Windows Terminal $Architecture 离线包清单无效。"
    }

    $localPath = Join-Path (Join-Path $PSScriptRoot 'installers\windows-terminal') $fileName
    if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
        throw "缺少 Windows Terminal $Architecture 离线包: $localPath"
    }
    if (-not (Test-ExpectedFileHash -Path $localPath -ExpectedSha256 $entry.sha256)) {
        throw "Windows Terminal $Architecture 离线包 SHA-256 校验失败。"
    }

    Write-Host "  [..] 使用项目携带的 Windows Terminal 离线包。" -ForegroundColor Cyan
    return $localPath
}

function Get-PowerShellStandalonePackage {
    param([Parameter(Mandatory = $true)][string]$Architecture)

    $manifest = Get-InstallerManifest
    if (-not $manifest -or -not $manifest.powerShell -or
        -not $manifest.powerShell.portable) {
        throw '离线安装包清单中缺少 PowerShell 7 配置。'
    }

    $assetProperty = $manifest.powerShell.portable.assets.PSObject.Properties[$Architecture]
    if (-not $assetProperty) {
        throw "离线安装包清单中缺少 PowerShell 7 $Architecture 包。"
    }

    $entry = $assetProperty.Value
    $fileName = [IO.Path]::GetFileName([string]$entry.file)
    if ($fileName -ne [string]$entry.file -or [string]$entry.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "PowerShell 7 $Architecture 离线包清单无效。"
    }

    $localPath = Join-Path (Join-Path $PSScriptRoot 'installers\powershell') $fileName
    if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
        throw "缺少 PowerShell 7 $Architecture 离线包: $localPath"
    }
    if (-not (Test-ExpectedFileHash -Path $localPath -ExpectedSha256 $entry.sha256)) {
        throw "PowerShell 7 $Architecture 离线包 SHA-256 校验失败。"
    }

    Write-Host "  [..] 使用项目携带的 PowerShell 7 离线包。" -ForegroundColor Cyan
    return $localPath
}

function Install-WindowsTerminalStandalone {
    param([Parameter(Mandatory = $true)][string]$PackagePath)

    $stagingRoot = Join-Path $script:VibeCodeRuntimeRoot (
        'staging-terminal-' + [guid]::NewGuid().ToString('N')
    )
    $targetDirectory = Join-Path $script:VibeCodeRuntimeRoot 'WindowsTerminal'

    try {
        New-Item -Path $stagingRoot -ItemType Directory -Force | Out-Null
        Expand-Archive -LiteralPath $PackagePath -DestinationPath $stagingRoot -Force

        $terminalExe = Get-ChildItem -LiteralPath $stagingRoot -Recurse `
            -Filter 'WindowsTerminal.exe' -File | Select-Object -First 1
        if (-not $terminalExe) {
            throw 'Terminal 独立包中缺少 WindowsTerminal.exe。'
        }

        $sourceDirectory = $terminalExe.Directory.FullName
        $wtPath = Join-Path $sourceDirectory 'wt.exe'
        if (-not (Test-MicrosoftSignature -Path $terminalExe.FullName) -or
            -not (Test-MicrosoftSignature -Path $wtPath)) {
            throw 'Terminal 独立包的 Microsoft 数字签名无效。'
        }

        New-Item -Path (Join-Path $sourceDirectory '.portable') -ItemType File -Force | Out-Null
        if (-not (Test-Path -LiteralPath $script:VibeCodeRuntimeRoot)) {
            New-Item -Path $script:VibeCodeRuntimeRoot -ItemType Directory -Force | Out-Null
        }
        if (Test-Path -LiteralPath $targetDirectory) {
            Remove-Item -LiteralPath $targetDirectory -Recurse -Force
        }
        Move-Item -LiteralPath $sourceDirectory -Destination $targetDirectory

        $installedPath = Join-Path $targetDirectory 'wt.exe'
        if (-not (Test-WindowsTerminalPath -Path $installedPath)) {
            throw 'Terminal 独立版部署完成，但启动验证失败。'
        }
        Write-Host "  [OK] Windows Terminal 独立版已部署。" -ForegroundColor Green
        return $installedPath
    } finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-PowerShellPortable {
    param([Parameter(Mandatory = $true)][string]$PackagePath)

    $stagingRoot = Join-Path $script:VibeCodeRuntimeRoot (
        'staging-powershell-' + [guid]::NewGuid().ToString('N')
    )
    $targetDirectory = Join-Path $script:VibeCodeRuntimeRoot 'PowerShell'

    try {
        New-Item -Path $stagingRoot -ItemType Directory -Force | Out-Null
        Expand-Archive -LiteralPath $PackagePath -DestinationPath $stagingRoot -Force

        $pwshExe = Get-ChildItem -LiteralPath $stagingRoot -Recurse `
            -Filter 'pwsh.exe' -File | Select-Object -First 1
        if (-not $pwshExe -or -not (Test-MicrosoftSignature -Path $pwshExe.FullName)) {
            throw 'PowerShell 独立包缺少有效 Microsoft 签名的 pwsh.exe。'
        }

        $sourceDirectory = $pwshExe.Directory.FullName
        if (Test-Path -LiteralPath $targetDirectory) {
            Remove-Item -LiteralPath $targetDirectory -Recurse -Force
        }
        Move-Item -LiteralPath $sourceDirectory -Destination $targetDirectory
        Update-ProcessPath

        $installedPath = Join-Path $targetDirectory 'pwsh.exe'
        if (-not (Test-PowerShell7Path -Path $installedPath)) {
            throw 'PowerShell 独立版部署完成，但启动验证失败。'
        }
        Write-Host '  [OK] PowerShell 7 独立版已部署。' -ForegroundColor Green
        return $installedPath
    } finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-WindowsTerminalRuntime {
    if ([Environment]::OSVersion.Version.Build -lt 19041) {
        throw '最新版 Windows Terminal 要求 Windows 10 2004 (Build 19041) 或更高版本。'
    }

    $architecture = Get-NativeArchitecture
    $packagePath = Get-TerminalStandalonePackage -Architecture $architecture
    return Install-WindowsTerminalStandalone -PackagePath $packagePath
}

function Install-PowerShell7Runtime {
    $architecture = Get-NativeArchitecture
    $zipPath = Get-PowerShellStandalonePackage -Architecture $architecture
    return Install-PowerShellPortable -PackagePath $zipPath
}

function Ensure-VibeCodeRuntime {
    Update-ProcessPath

    $terminalPath = Get-WindowsTerminalPath
    if ($terminalPath) {
        Write-Host "  [OK] Windows Terminal: $terminalPath" -ForegroundColor Green
    } else {
        Write-Host '  [--] 未检测到可用的 Windows Terminal，开始离线部署。' -ForegroundColor Yellow
        $terminalPath = Install-WindowsTerminalRuntime
    }
    if (-not $terminalPath) {
        throw 'Windows Terminal 安装后仍不可用。'
    }

    $powerShellPath = Get-PowerShell7Path
    if ($powerShellPath) {
        Write-Host "  [OK] PowerShell 7: $powerShellPath" -ForegroundColor Green
    } else {
        Write-Host '  [--] 未检测到 PowerShell 7，开始离线部署。' -ForegroundColor Yellow
        $powerShellPath = Install-PowerShell7Runtime
    }
    if (-not $powerShellPath) {
        throw 'PowerShell 7 安装后仍不可用。'
    }

    return [pscustomobject]@{
        TerminalPath = $terminalPath
        PowerShellPath = $powerShellPath
    }
}

# ============================================================
# AI CLI、Node 与 API 配置
# ============================================================
function Get-AiCliDefinitions {
    return @(
        [pscustomobject]@{ Name = 'Codex'; Command = 'codex'; Package = '@openai/codex' },
        [pscustomobject]@{ Name = 'Claude'; Command = 'claude'; Package = '@anthropic-ai/claude-code' },
        [pscustomobject]@{ Name = 'OpenCode'; Command = 'opencode'; Package = 'opencode-ai' }
    )
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    try {
        $answer = Read-Host "$Prompt $suffix"
    } catch {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultYes
    }
    return $answer.Trim().ToLowerInvariant() -in @('y', 'yes', '1', '是')
}

function Add-UserPathEntry {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($userPath -split ';' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    if (-not @($entries | Where-Object {
        ([Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\')).Equals(
            $fullPath, [StringComparison]::OrdinalIgnoreCase
        )
    }).Count) {
        $entries += $fullPath
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    }
    if (-not @($env:Path -split ';' | Where-Object {
        $_.Trim().TrimEnd('\').Equals($fullPath, [StringComparison]::OrdinalIgnoreCase)
    }).Count) {
        $env:Path = "$env:Path;$fullPath"
    }
}

function Get-EffectiveEnvironmentValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($scope in @('Process', 'User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }
    return $null
}

function Set-UserEnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -Path "env:$Name" -Value $Value
}

function Get-ProxyUri {
    foreach ($name in @('HTTPS_PROXY', 'HTTP_PROXY')) {
        $value = Get-EffectiveEnvironmentValue -Name $name
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $uri = $null
            if ([Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
                return $uri.AbsoluteUri
            }
        }
    }
    return $null
}

function Invoke-VibeCodeWebRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$OutFile,
        [int]$TimeoutSec = 20
    )

    $proxy = Get-ProxyUri
    $curl = Get-Command 'curl.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($curl) {
        $arguments = @(
            '--fail',
            '--silent',
            '--show-error',
            '--location',
            '--connect-timeout', ([string][math]::Min($TimeoutSec, 15)),
            '--max-time', ([string]$TimeoutSec),
            '--header', 'User-Agent: VibeCodeContextMenu'
        )
        if ($proxy) {
            $arguments += @('--proxy', $proxy)
        }
        if ($OutFile) {
            $arguments += @('--output', $OutFile)
        }
        $arguments += $Uri
        $curlOutput = @(& $curl.Source @arguments 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "curl 请求失败: $([string]($curlOutput | Select-Object -Last 1))"
        }
        return [pscustomobject]@{
            Content = if ($OutFile) { $null } else { $curlOutput -join [Environment]::NewLine }
        }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        # TLS is selected automatically on newer PowerShell versions.
    }

    $parameters = @{
        Uri = $Uri
        UseBasicParsing = $true
        TimeoutSec = $TimeoutSec
        Headers = @{ 'User-Agent' = 'VibeCodeContextMenu' }
        ErrorAction = 'Stop'
    }
    if ($proxy) {
        $parameters.Proxy = $proxy
    }
    if ($OutFile) {
        $parameters.OutFile = $OutFile
    }
    return Invoke-WebRequest @parameters
}

function Test-InternetAvailable {
    foreach ($uri in @(
        'https://registry.npmjs.org/-/ping',
        'https://nodejs.org/dist/index.json'
    )) {
        try {
            $null = Invoke-VibeCodeWebRequest -Uri $uri -TimeoutSec 6
            return $true
        } catch {
            continue
        }
    }
    return $false
}

function Get-VerifiedDeveloperAsset {
    param(
        [Parameter(Mandatory = $true)]$Asset,
        [Parameter(Mandatory = $true)][string]$RelativeDirectory,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $fileName = [string]$Asset.file
    $expectedHash = [string]$Asset.sha256
    if ([string]::IsNullOrWhiteSpace($fileName) -or
        [IO.Path]::GetFileName($fileName) -ne $fileName -or
        $expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw "$Description 离线包清单无效。"
    }
    $path = Join-Path (Join-Path $PSScriptRoot $RelativeDirectory) $fileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "缺少 $Description 离线包: $path"
    }
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if (-not $actualHash.Equals($expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description 离线包 SHA-256 校验失败。"
    }
    return [pscustomobject]@{
        Path = $path
        FileName = $fileName
        Sha256 = $expectedHash.ToLowerInvariant()
    }
}

function Get-NvmPath {
    Update-ProcessPath
    $candidates = @(
        (Join-Path $script:VibeCodeNvmRoot 'nvm.exe')
    )
    $nvmHome = Get-EffectiveEnvironmentValue -Name 'NVM_HOME'
    if ($nvmHome) {
        $candidates += Join-Path $nvmHome 'nvm.exe'
    }
    $command = Get-Command 'nvm.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        $candidates += $command.Source
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Install-NvmPortable {
    $existing = Get-NvmPath
    if ($existing) {
        Write-Host "  [OK] NVM: $existing" -ForegroundColor Green
        return $existing
    }

    $manifest = Get-InstallerManifest
    if (-not $manifest -or -not $manifest.developerTools -or
        -not $manifest.developerTools.nvmWindows.portable) {
        throw '离线安装包清单中缺少 NVM 配置。'
    }
    $package = Get-VerifiedDeveloperAsset `
        -Asset $manifest.developerTools.nvmWindows.portable `
        -RelativeDirectory 'installers\nvm' -Description 'NVM'

    $stagingRoot = Join-Path $script:VibeCodeRuntimeRoot (
        'staging-nvm-' + [guid]::NewGuid().ToString('N')
    )
    $payload = Join-Path $stagingRoot 'payload'
    try {
        New-Item -Path $payload -ItemType Directory -Force | Out-Null
        Expand-Archive -LiteralPath $package.Path -DestinationPath $payload -Force
        $nvmExecutable = Get-ChildItem -LiteralPath $payload -Filter 'nvm.exe' `
            -Recurse -File | Select-Object -First 1
        if (-not $nvmExecutable) {
            throw 'NVM 离线包中缺少 nvm.exe。'
        }
        $sourceDirectory = $nvmExecutable.Directory.FullName
        if (Test-Path -LiteralPath $script:VibeCodeNvmRoot) {
            Remove-Item -LiteralPath $script:VibeCodeNvmRoot -Recurse -Force
        }
        Move-Item -LiteralPath $sourceDirectory -Destination $script:VibeCodeNvmRoot

        $settingsPath = Join-Path $script:VibeCodeNvmRoot 'settings.txt'
        [IO.File]::WriteAllLines($settingsPath, @(
            "root: $script:VibeCodeNvmRoot",
            "path: $script:VibeCodeNodeLink"
        ), [Text.UTF8Encoding]::new($false))

        Set-UserEnvironmentValue -Name 'NVM_HOME' -Value $script:VibeCodeNvmRoot
        Set-UserEnvironmentValue -Name 'NVM_SYMLINK' -Value $script:VibeCodeNodeLink
        Add-UserPathEntry -Path $script:VibeCodeNvmRoot
        Add-UserPathEntry -Path $script:VibeCodeNodeLink
        $installed = Join-Path $script:VibeCodeNvmRoot 'nvm.exe'
        if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) {
            throw 'NVM 部署完成，但启动文件不存在。'
        }
        Write-Host "  [OK] NVM 已离线部署: $installed" -ForegroundColor Green
        return $installed
    } finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-NodeRuntime {
    Update-ProcessPath
    $node = Get-Command 'node.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $npm = Get-Command 'npm.cmd' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $node -or -not $npm) {
        return $null
    }
    try {
        $versionText = [string](@(& $node.Source --version 2>$null) | Select-Object -Last 1)
        $major = 0
        if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '^v?(\d+)\.' -or
            -not [int]::TryParse($Matches[1], [ref]$major)) {
            return $null
        }
        return [pscustomobject]@{
            NodePath = $node.Source
            NpmPath = $npm.Source
            Version = $versionText.Trim()
            Major = $major
        }
    } catch {
        return $null
    }
}

function Get-OnlineNodeLtsPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$WorkDirectory
    )

    $index = (Invoke-VibeCodeWebRequest `
        -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 15).Content |
        ConvertFrom-Json
    $fileKind = "win-$Architecture-zip"
    $release = @($index | Where-Object {
        $_.lts -and $_.files -contains $fileKind
    } | Select-Object -First 1)
    if ($release.Count -eq 0) {
        throw "Node.js 官方清单中没有 $Architecture LTS ZIP。"
    }
    $versionWithPrefix = [string]$release[0].version
    $version = $versionWithPrefix.TrimStart('v')
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        throw 'Node.js 在线版本号无效。'
    }
    $fileName = "node-$versionWithPrefix-win-$Architecture.zip"
    $baseUri = "https://nodejs.org/dist/$versionWithPrefix"
    $sums = (Invoke-VibeCodeWebRequest `
        -Uri "$baseUri/SHASUMS256.txt" -TimeoutSec 15).Content -split "`r?`n"
    $hashLine = @($sums | Where-Object {
        $_ -match ('\s+' + [regex]::Escape($fileName) + '$')
    } | Select-Object -First 1)
    if ($hashLine.Count -eq 0) {
        throw "Node.js 官方哈希清单中缺少 $fileName。"
    }
    $expectedHash = ($hashLine[0] -split '\s+')[0].ToLowerInvariant()
    $packagePath = Join-Path $WorkDirectory $fileName
    $null = Invoke-VibeCodeWebRequest -Uri "$baseUri/$fileName" `
        -OutFile $packagePath -TimeoutSec 180
    $actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw '在线 Node.js ZIP 的 SHA-256 校验失败。'
    }
    return [pscustomobject]@{
        Path = $packagePath
        Version = $version
        Source = 'online'
    }
}

function Get-OfflineNodePackage {
    param([Parameter(Mandatory = $true)][string]$Architecture)

    $manifest = Get-InstallerManifest
    if (-not $manifest -or -not $manifest.developerTools -or
        -not $manifest.developerTools.node.portable) {
        throw '离线安装包清单中缺少 Node.js 配置。'
    }
    $portable = $manifest.developerTools.node.portable
    $assetProperty = $portable.assets.PSObject.Properties[$Architecture]
    if (-not $assetProperty) {
        throw "离线安装包清单中缺少 Node.js $Architecture 包。"
    }
    $asset = Get-VerifiedDeveloperAsset -Asset $assetProperty.Value `
        -RelativeDirectory 'installers\node' -Description "Node.js $Architecture"
    return [pscustomobject]@{
        Path = $asset.Path
        Version = [string]$portable.version
        Source = 'offline'
    }
}

function Install-NodePackage {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$NvmPath
    )

    if ($Package.Version -notmatch '^\d+\.\d+\.\d+$') {
        throw 'Node.js 版本号无效。'
    }
    $nvmHome = Split-Path -Parent $NvmPath
    $versionDirectory = Join-Path $nvmHome ("v" + $Package.Version)
    $stagingRoot = Join-Path $script:VibeCodeRuntimeRoot (
        'staging-node-' + [guid]::NewGuid().ToString('N')
    )
    $payload = Join-Path $stagingRoot 'payload'
    try {
        New-Item -Path $payload -ItemType Directory -Force | Out-Null
        Expand-Archive -LiteralPath $Package.Path -DestinationPath $payload -Force
        $nodeExecutable = Get-ChildItem -LiteralPath $payload -Filter 'node.exe' `
            -Recurse -File | Where-Object {
                Test-Path -LiteralPath (Join-Path $_.Directory.FullName 'npm.cmd') -PathType Leaf
            } | Select-Object -First 1
        if (-not $nodeExecutable) {
            throw 'Node.js ZIP 中缺少 node.exe 或 npm.cmd。'
        }
        $sourceDirectory = $nodeExecutable.Directory.FullName
        $reuseExistingVersion = $false
        $existingNode = Join-Path $versionDirectory 'node.exe'
        $existingNpm = Join-Path $versionDirectory 'npm.cmd'
        if ((Test-Path -LiteralPath $existingNode -PathType Leaf) -and
            (Test-Path -LiteralPath $existingNpm -PathType Leaf)) {
            $existingVersion = [string](@(& $existingNode --version 2>$null) |
                Select-Object -Last 1)
            $reuseExistingVersion = $LASTEXITCODE -eq 0 -and
                $existingVersion.TrimStart('v') -eq $Package.Version
        }
        if (-not $reuseExistingVersion) {
            if (Test-Path -LiteralPath $versionDirectory) {
                Remove-Item -LiteralPath $versionDirectory -Recurse -Force
            }
            Move-Item -LiteralPath $sourceDirectory -Destination $versionDirectory
        } else {
            Write-Host "  [OK] NVM 中已存在 Node.js $($Package.Version)，保留原目录。" `
                -ForegroundColor Green
        }

        $managedNvm = ([IO.Path]::GetFullPath($nvmHome).TrimEnd('\')).Equals(
            ([IO.Path]::GetFullPath($script:VibeCodeNvmRoot).TrimEnd('\')),
            [StringComparison]::OrdinalIgnoreCase
        )
        $activeDirectory = $null
        if (-not $managedNvm) {
            try {
                $nvmOutput = @(& $NvmPath use $Package.Version 2>&1)
                $configuredLink = Get-EffectiveEnvironmentValue -Name 'NVM_SYMLINK'
                if ($LASTEXITCODE -eq 0 -and $configuredLink -and
                    (Test-Path -LiteralPath (Join-Path $configuredLink 'node.exe') -PathType Leaf)) {
                    $activeDirectory = $configuredLink
                } else {
                    Write-Host "  [--] 现有 NVM 激活失败，使用 VibeCode NodeCurrent。" `
                        -ForegroundColor Yellow
                }
            } catch {
                Write-Host '  [--] 现有 NVM 无法激活新版本，使用 VibeCode NodeCurrent。' `
                    -ForegroundColor Yellow
            }
        }

        if (-not $activeDirectory) {
            if (Test-Path -LiteralPath $script:VibeCodeNodeLink) {
                $linkItem = Get-Item -LiteralPath $script:VibeCodeNodeLink -Force
                if (($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    [IO.Directory]::Delete($script:VibeCodeNodeLink)
                } else {
                    Remove-Item -LiteralPath $script:VibeCodeNodeLink -Recurse -Force
                }
            }
            try {
                New-Item -Path $script:VibeCodeNodeLink -ItemType Junction `
                    -Target $versionDirectory -Force | Out-Null
                $activeDirectory = $script:VibeCodeNodeLink
            } catch {
                Write-Host '  [--] 无法创建 NodeCurrent Junction，改用版本目录。' `
                    -ForegroundColor Yellow
                $activeDirectory = $versionDirectory
            }
        }

        if ($managedNvm) {
            Set-UserEnvironmentValue -Name 'NVM_HOME' -Value $nvmHome
            Set-UserEnvironmentValue -Name 'NVM_SYMLINK' -Value $script:VibeCodeNodeLink
        }
        Add-UserPathEntry -Path $nvmHome
        Add-UserPathEntry -Path $activeDirectory
        $env:Path = "$activeDirectory;$nvmHome;$env:Path"

        $nodePath = Join-Path $activeDirectory 'node.exe'
        $npmPath = Join-Path $activeDirectory 'npm.cmd'
        $versionOutput = [string](@(& $nodePath --version 2>$null) | Select-Object -Last 1)
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $npmPath -PathType Leaf)) {
            throw 'Node.js 部署完成，但启动验证失败。'
        }
        Write-Host "  [OK] Node.js $versionOutput ($($Package.Source))" -ForegroundColor Green
        return [pscustomobject]@{
            NodePath = $nodePath
            NpmPath = $npmPath
            Version = $versionOutput
            Major = [int]($Package.Version -split '\.')[0]
        }
    } finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Ensure-NodeRuntime {
    param([bool]$OnlinePreferred)

    $existing = Get-NodeRuntime
    if ($existing -and $existing.Major -ge 22) {
        if (-not (Get-NvmPath)) {
            $null = Install-NvmPortable
        }
        Write-Host "  [OK] Node.js $($existing.Version): $($existing.NodePath)" -ForegroundColor Green
        return $existing
    }
    if ($existing) {
        Write-Host "  [--] Node.js $($existing.Version) 低于所需的 22，准备 LTS。" -ForegroundColor Yellow
    } else {
        Write-Host '  [--] 未检测到可用的 Node.js/npm。' -ForegroundColor Yellow
    }

    $architecture = Get-NativeArchitecture
    $nvmPath = Install-NvmPortable
    $workDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'VibeCodeNode-' + [guid]::NewGuid().ToString('N')
    )
    try {
        New-Item -Path $workDirectory -ItemType Directory -Force | Out-Null
        $package = $null
        if ($OnlinePreferred) {
            try {
                Write-Host '  [..] 正在获取官方最新 Node.js LTS...' -ForegroundColor Cyan
                $package = Get-OnlineNodeLtsPackage -Architecture $architecture `
                    -WorkDirectory $workDirectory
            } catch {
                Write-Host "  [--] 在线 Node.js 获取失败，使用离线包: $($_.Exception.Message)" `
                    -ForegroundColor Yellow
            }
        }
        if (-not $package) {
            $package = Get-OfflineNodePackage -Architecture $architecture
        }
        return Install-NodePackage -Package $package -NvmPath $nvmPath
    } finally {
        if (Test-Path -LiteralPath $workDirectory) {
            Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-OfflineAiCliBundle {
    param([Parameter(Mandatory = $true)]$NodeRuntime)

    $architecture = Get-NativeArchitecture
    $manifest = Get-InstallerManifest
    if (-not $manifest -or -not $manifest.developerTools -or
        -not $manifest.developerTools.aiCli) {
        throw '离线安装包清单中缺少 AI CLI 配置。'
    }
    $assetProperty = $manifest.developerTools.aiCli.assets.PSObject.Properties[$architecture]
    if (-not $assetProperty) {
        throw "离线安装包清单中缺少 AI CLI $architecture 包。"
    }
    $package = Get-VerifiedDeveloperAsset -Asset $assetProperty.Value `
        -RelativeDirectory 'installers\ai-cli' -Description "AI CLI $architecture"
    $stagingRoot = Join-Path $script:VibeCodeRuntimeRoot (
        'staging-ai-cli-' + [guid]::NewGuid().ToString('N')
    )
    $payload = Join-Path $stagingRoot 'payload'
    try {
        New-Item -Path $payload -ItemType Directory -Force | Out-Null
        Expand-Archive -LiteralPath $package.Path -DestinationPath $payload -Force
        $binDirectory = Join-Path $payload 'node_modules\.bin'
        foreach ($command in @('codex.cmd', 'claude.cmd', 'opencode.cmd')) {
            if (-not (Test-Path -LiteralPath (Join-Path $binDirectory $command) -PathType Leaf)) {
                throw "AI CLI 离线束中缺少 $command。"
            }
        }

        $claudePostInstall = Join-Path $payload `
            'node_modules\@anthropic-ai\claude-code\install.cjs'
        $openCodePostInstall = Join-Path $payload `
            'node_modules\opencode-ai\postinstall.mjs'
        & $NodeRuntime.NodePath $claudePostInstall
        if ($LASTEXITCODE -ne 0) {
            throw 'Claude 离线平台二进制配置失败。'
        }
        & $NodeRuntime.NodePath $openCodePostInstall
        if ($LASTEXITCODE -ne 0) {
            throw 'OpenCode 离线平台二进制配置失败。'
        }

        $oldPath = $env:Path
        try {
            $env:Path = "$(Split-Path -Parent $NodeRuntime.NodePath);$binDirectory;$env:Path"
            foreach ($definition in Get-AiCliDefinitions) {
                $commandPath = Join-Path $binDirectory ($definition.Command + '.cmd')
                $null = @(& $commandPath --version 2>$null)
                if ($LASTEXITCODE -ne 0) {
                    throw "$($definition.Name) 离线启动验证失败。"
                }
            }
        } finally {
            $env:Path = $oldPath
        }

        if (Test-Path -LiteralPath $script:VibeCodeAiCliRoot) {
            Remove-Item -LiteralPath $script:VibeCodeAiCliRoot -Recurse -Force
        }
        Move-Item -LiteralPath $payload -Destination $script:VibeCodeAiCliRoot
        $installedBin = Join-Path $script:VibeCodeAiCliRoot 'node_modules\.bin'
        Add-UserPathEntry -Path $installedBin
        Update-ProcessPath
        Write-Host "  [OK] AI CLI 离线束已部署: $installedBin" -ForegroundColor Green
    } finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-OnlineAiCliPackage {
    param(
        [Parameter(Mandatory = $true)]$Definition,
        [Parameter(Mandatory = $true)]$NodeRuntime
    )

    Write-Host "  [..] 在线安装 $($Definition.Name) 最新版..." -ForegroundColor Cyan
    $output = @(& $NodeRuntime.NpmPath install --global `
        ($Definition.Package + '@latest') --no-audit --no-fund 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $message = [string]($output | Select-Object -Last 1)
        throw "$($Definition.Name) npm 安装失败: $message"
    }
    $prefixOutput = @(& $NodeRuntime.NpmPath prefix --global 2>$null)
    if ($LASTEXITCODE -eq 0 -and $prefixOutput.Count -gt 0) {
        $prefix = [string]($prefixOutput | Select-Object -Last 1)
        if (Test-Path -LiteralPath $prefix -PathType Container) {
            Add-UserPathEntry -Path $prefix
        }
    }
    Update-ProcessPath
    if (-not (Test-ToolInstalled -CommandName $Definition.Command)) {
        throw "$($Definition.Name) 安装完成，但命令未进入 PATH。"
    }
    Write-Host "  [OK] $($Definition.Name) 已在线安装。" -ForegroundColor Green
}

function Install-AiCliTools {
    param(
        [switch]$UpdateExisting,
        [string[]]$Commands
    )

    Update-ProcessPath
    $definitions = @(Get-AiCliDefinitions)
    if ($Commands -and $Commands.Count -gt 0) {
        $definitions = @($definitions | Where-Object { $_.Command -in $Commands })
    }
    if ($definitions.Count -eq 0) {
        Write-Host '没有可由本项目自动安装的所选 AI CLI。' -ForegroundColor Yellow
        return
    }
    $targets = if ($UpdateExisting) {
        $definitions
    } else {
        @($definitions | Where-Object {
            -not (Test-ToolInstalled -CommandName $_.Command)
        })
    }
    if ($targets.Count -eq 0) {
        Write-Host '所选 AI CLI 均已安装，无需处理。' -ForegroundColor Green
        return
    }

    $architecture = Get-NativeArchitecture
    Write-Host "待安装: $($targets.Name -join ', ')" -ForegroundColor Cyan
    $online = Test-InternetAvailable
    if ($online) {
        Write-Host '网络可用：优先安装在线最新版。' -ForegroundColor Green
    } else {
        Write-Host '网络不可用：使用项目内离线版本。' -ForegroundColor Yellow
    }

    try {
        $nodeRuntime = Ensure-NodeRuntime -OnlinePreferred $online
        $failed = @($targets)
        if ($online) {
            $failed = @()
            foreach ($definition in $targets) {
                try {
                    Install-OnlineAiCliPackage -Definition $definition -NodeRuntime $nodeRuntime
                } catch {
                    Write-Host "  [--] $($_.Exception.Message)" -ForegroundColor Yellow
                    $failed += $definition
                }
            }
        }
        if (-not $online -or $failed.Count -gt 0) {
            Write-Host '  [..] 启用 AI CLI 离线兜底包。' -ForegroundColor Cyan
            Install-OfflineAiCliBundle -NodeRuntime $nodeRuntime
        }

        Update-ProcessPath
        Write-Host ''
        Write-Host 'AI CLI 状态:' -ForegroundColor Cyan
        foreach ($definition in $definitions) {
            $installed = Test-ToolInstalled -CommandName $definition.Command
            $label = if ($installed) { '[OK]' } else { '[--]' }
            $color = if ($installed) { 'Green' } else { 'Yellow' }
            Write-Host "  $label $($definition.Name)" -ForegroundColor $color
        }
    } catch {
        Write-Host "AI CLI 自动安装失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-ApiProviderDefinitions {
    return @(
        [pscustomobject]@{
            Name = 'Codex'
            Command = 'codex'
            KeyVariable = 'OPENAI_API_KEY'
            BaseVariable = 'OPENAI_BASE_URL'
            OfficialBase = 'https://api.openai.com/v1'
        },
        [pscustomobject]@{
            Name = 'Claude'
            Command = 'claude'
            KeyVariable = 'ANTHROPIC_API_KEY'
            BaseVariable = 'ANTHROPIC_BASE_URL'
            OfficialBase = 'https://api.anthropic.com'
        }
    )
}

function Show-ApiConfigurationStatus {
    Update-ProcessPath
    foreach ($provider in Get-ApiProviderDefinitions) {
        if (-not (Test-ToolInstalled -CommandName $provider.Command)) {
            Write-Host "  [--] $($provider.Name): CLI 未安装" -ForegroundColor DarkGray
            continue
        }
        $key = Get-EffectiveEnvironmentValue -Name $provider.KeyVariable
        $base = Get-EffectiveEnvironmentValue -Name $provider.BaseVariable
        $keyLabel = if ($key) { 'Key 已配置' } else { 'Key 未配置' }
        $baseLabel = if ($base) { $base } else { "官方默认 ($($provider.OfficialBase))" }
        $color = if ($key) { 'Green' } else { 'Yellow' }
        Write-Host "  $($provider.Name): $keyLabel；API: $baseLabel" -ForegroundColor $color
    }
}

function Read-SecretValue {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    $secure = Read-Host $Prompt -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Configure-AiApiSettings {
    param(
        [switch]$OnlyMissing,
        [switch]$PromptFirst,
        [string[]]$Commands
    )

    Update-ProcessPath
    $providers = @(Get-ApiProviderDefinitions | Where-Object {
        (Test-ToolInstalled -CommandName $_.Command) -and
        (-not $Commands -or $Commands.Count -eq 0 -or $_.Command -in $Commands)
    })
    if ($providers.Count -eq 0) {
        Write-Host 'Codex 和 Claude CLI 均未安装，暂不配置 API。' -ForegroundColor Yellow
        return
    }
    $targets = if ($OnlyMissing) {
        @($providers | Where-Object {
            -not (Get-EffectiveEnvironmentValue -Name $_.KeyVariable)
        })
    } else {
        $providers
    }
    if ($targets.Count -eq 0) {
        Write-Host 'Codex/Claude API Key 均已配置。' -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host 'Codex/Claude API 配置检查:' -ForegroundColor Cyan
    Show-ApiConfigurationStatus
    if ($PromptFirst -and -not (Read-YesNo -Prompt '是否现在进入 API 配置引导？' -DefaultYes $true)) {
        return
    }

    foreach ($provider in $targets) {
        $currentKey = Get-EffectiveEnvironmentValue -Name $provider.KeyVariable
        $currentBase = Get-EffectiveEnvironmentValue -Name $provider.BaseVariable
        $verb = if ($currentKey) { '重新配置' } else { '配置' }
        if (-not (Read-YesNo -Prompt "是否$verb $($provider.Name)？" `
            -DefaultYes (-not [bool]$currentKey))) {
            continue
        }

        $baseHint = if ($currentBase) {
            "直接回车保留 $currentBase"
        } else {
            "直接回车使用官方默认 $($provider.OfficialBase)"
        }
        $baseInput = Read-Host "$($provider.Name) API Base URL（$baseHint）"
        if (-not [string]::IsNullOrWhiteSpace($baseInput)) {
            $uri = $null
            if (-not [Uri]::TryCreate($baseInput.Trim(), [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -notin @('http', 'https')) {
                Write-Host 'API URL 无效，已跳过该工具配置。' -ForegroundColor Red
                continue
            }
            Set-UserEnvironmentValue -Name $provider.BaseVariable -Value $uri.AbsoluteUri.TrimEnd('/')
        }

        $keyHint = if ($currentKey) { '直接回车保留现有 Key' } else { '输入内容不会显示' }
        $keyInput = Read-SecretValue -Prompt "$($provider.Name) API Key（$keyHint）"
        if (-not [string]::IsNullOrWhiteSpace($keyInput)) {
            Set-UserEnvironmentValue -Name $provider.KeyVariable -Value $keyInput.Trim()
            Write-Host "  [OK] $($provider.Name) API 配置已保存到当前用户环境变量。" `
                -ForegroundColor Green
        } elseif (-not $currentKey) {
            Write-Host "  [--] 未输入 $($provider.Name) Key，已跳过。" -ForegroundColor Yellow
        }
    }
}

function Get-Config {
    $scriptDir = $PSScriptRoot
    $configPath = Join-Path $scriptDir 'tools.json'

    if (-not (Test-Path -LiteralPath $configPath)) {
        New-DefaultConfig -Path $configPath
    }

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $config.menuName = Get-SafeMenuName -Name $config.menuName
    return $config
}

function New-DefaultConfig {
    param([string]$Path)
    $default = @'
{
  "menuName": "VibeCode",
  "menuLabel": "VibeCode",
  "globalEnv": {},
  "tools": [
    {
      "name": "claude",
      "command": "claude",
      "icon": "claude.ico",
      "super": {
        "command": "claude --dangerously-skip-permissions",
        "label": "claudeSuper",
        "resume": {
          "command": "claude --dangerously-skip-permissions -r"
        }
      }
    },
    {
      "name": "codex",
      "command": "codex",
      "icon": "codex.ico",
      "super": {
        "command": "codex --dangerously-bypass-approvals-and-sandbox",
        "label": "codexSuper",
        "resume": {
          "command": "codex --dangerously-bypass-approvals-and-sandbox resume"
        }
      }
    },
    {
      "name": "openCode",
      "command": "opencode",
      "icon": "opencode.ico",
      "super": {
        "command": "opencode",
        "env": { "OPENCODE_PERMISSION": "\"allow\"" },
        "label": "openCodeSuper",
        "resume": {
          "command": "opencode -c"
        }
      }
    },
    {
      "name": "grok",
      "command": "grok",
      "icon": "grok.ico",
      "super": {
        "command": "grok --always-approve",
        "label": "grokSuper",
        "resume": {
          "command": "grok --always-approve -r"
        }
      }
    }
  ]
}
'@
    Set-Content -LiteralPath $Path -Value $default -Encoding UTF8
    Write-Host "已生成默认配置: $Path" -ForegroundColor Cyan
}

function Get-MenuItems {
    param([Parameter(Mandatory = $true)]$Config)

    $allItems = @()
    $i = 0
    foreach ($t in $Config.tools) {
        $i++; $prefix = '{0:D2}' -f $i
        $allItems += @{
            Key = "${prefix}_$($t.name)"; Label = $t.name
            Tool = $t.name; Command = $t.command; Icon = $t.icon; Group = $t.name
        }
        if ($t.super) {
            $i++; $prefix = '{0:D2}' -f $i
            $allItems += @{
                Key = "${prefix}_$($t.super.label)"; Label = $t.super.label
                Tool = $t.super.label; Command = $t.command; Icon = $t.icon; Group = $t.name
            }
            $i++; $prefix = '{0:D2}' -f $i
            $allItems += @{
                Key = "${prefix}_$($t.super.label)-R"; Label = "$($t.super.label)-R"
                Tool = "$($t.super.label)-R"; Command = $t.command; Icon = $t.icon; Group = $t.name
            }
        }
    }

    return $allItems
}

function Select-MenuTools {
    param([Parameter(Mandatory = $true)]$Config)

    $tools = @($Config.tools)
    if ($tools.Count -eq 0) {
        Write-Host '配置中没有可安装的工具菜单。' -ForegroundColor Yellow
        return @()
    }

    $allItems = @(Get-MenuItems -Config $Config)
    Write-Host ''
    Write-Host '请选择要安装的 AI 工具菜单:' -ForegroundColor Cyan
    Write-Host ''
    for ($i = 0; $i -lt $tools.Count; $i++) {
        $tool = $tools[$i]
        $installed = Test-ToolInstalled -CommandName $tool.command
        $status = if ($installed) { '已安装' } else { '未安装' }
        $color = if ($installed) { 'Green' } else { 'DarkGray' }
        $labels = @($allItems | Where-Object { $_.Group -eq $tool.name } |
            ForEach-Object { $_.Label })
        Write-Host "  $($i + 1)) $($tool.name) [$status] ($($labels -join ', '))" `
            -ForegroundColor $color
    }
    Write-Host ''

    try {
        $choice = Read-Host '输入编号（可用逗号或空格多选，直接回车取消）'
    } catch {
        return @()
    }
    if ([string]::IsNullOrWhiteSpace($choice)) {
        Write-Host '未选择任何工具菜单，已取消安装。' -ForegroundColor Yellow
        return @()
    }

    $selectedIndexes = @()
    foreach ($token in ($choice.Trim() -split '[,，、;；\s]+')) {
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        $number = 0
        if (-not [int]::TryParse($token, [ref]$number) -or
            $number -lt 1 -or $number -gt $tools.Count) {
            Write-Host "无效的工具编号: $token，已取消安装。" -ForegroundColor Red
            return @()
        }
        $index = $number - 1
        if ($index -notin $selectedIndexes) {
            $selectedIndexes += $index
        }
    }

    if ($selectedIndexes.Count -eq 0) {
        Write-Host '未选择任何工具菜单，已取消安装。' -ForegroundColor Yellow
        return @()
    }
    return @($selectedIndexes | Sort-Object | ForEach-Object { $tools[$_] })
}

# ============================================================
# 安装
# ============================================================
function Install-Menu {
    $config = Get-Config

    $selectedTools = @(Select-MenuTools -Config $config)
    if ($selectedTools.Count -eq 0) {
        return
    }

    Update-ProcessPath
    $selectedCommands = @($selectedTools | ForEach-Object { $_.command })
    $missingSupported = @(Get-AiCliDefinitions | Where-Object {
        $_.Command -in $selectedCommands -and
        -not (Test-ToolInstalled -CommandName $_.Command)
    })
    if ($missingSupported.Count -gt 0) {
        Write-Host ''
        Write-Host "未检测到: $($missingSupported.Name -join ', ')" -ForegroundColor Yellow
        if (Read-YesNo -Prompt '是否自动准备 Node.js 并安装所选的缺失 AI CLI？' `
            -DefaultYes $false) {
            Install-AiCliTools -Commands @($missingSupported.Command)
            Update-ProcessPath
        }
    }

    $allItems = @(Get-MenuItems -Config $config)
    $availableTools = @($selectedTools | Where-Object {
        Test-ToolInstalled -CommandName $_.command
    })
    $availableGroups = @($availableTools | ForEach-Object { $_.name })
    $items = @($allItems | Where-Object { $_.Group -in $availableGroups })
    $skipped = @($selectedTools | Where-Object {
        -not (Test-ToolInstalled -CommandName $_.command)
    })

    if ($items.Count -eq 0) {
        Write-Host ""
        Write-Host '未检测到所选的 AI CLI 工具，无法安装菜单。' -ForegroundColor Yellow
        Write-Host "请先安装: $($selectedCommands -join ', ')" -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host '将安装以下工具菜单:' -ForegroundColor Green
    $availableTools | ForEach-Object {
        Write-Host "  [OK] $($_.name)"
    }
    if ($skipped.Count -gt 0) {
        Write-Host 'CLI 未安装（菜单已跳过）:' -ForegroundColor DarkGray
        $skipped | ForEach-Object { Write-Host "  [--] $($_.name) -> $($_.command)" }
    }

    Write-Host ""
    Write-Host "检查运行环境:" -ForegroundColor Cyan
    try {
        $runtime = Ensure-VibeCodeRuntime
        $terminalPath = $runtime.TerminalPath
        $powerShellPath = $runtime.PowerShellPath
    } catch {
        Write-Host "运行环境准备失败: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "未写入右键菜单，请确认 installers 目录中的离线包完整。" -ForegroundColor Yellow
        return
    }

    # 部署目录
    $deployDir = Get-VibeCodeDeployDirectory -MenuName $config.menuName
    if (-not (Test-Path -LiteralPath $deployDir)) {
        New-Item -Path $deployDir -ItemType Directory -Force | Out-Null
    }

    # 释放启动器
    $launcherPath = Join-Path $deployDir 'Start-VibeCodeTool.ps1'
    Set-Content -LiteralPath $launcherPath -Value $EmbeddedLauncher -Encoding UTF8 -Force

    # 释放配置
    $scriptDir = $PSScriptRoot
    $configSource = Join-Path $scriptDir 'tools.json'
    Copy-Item -LiteralPath $configSource -Destination (Join-Path $deployDir 'tools.json') -Force

    # 复制图标
    $icoDir = Join-Path $scriptDir 'ico'
    $icoSource = if (Test-Path -LiteralPath $icoDir) { $icoDir } else { $scriptDir }
    Get-ChildItem -LiteralPath $icoSource -Filter '*.ico' -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $deployDir $_.Name) -Force
    }

    $roots = @(
        'HKCU:\Software\Classes\Directory\shell',
        'HKCU:\Software\Classes\Directory\Background\shell'
    )
    $configuredKeys = @($allItems | ForEach-Object { $_.Key })
    $configuredLabels = @($allItems | ForEach-Object { $_.Label })

    foreach ($root in $roots) {
        $token = if ($root -match 'Background') { '%V' } else { '%1' }
        $menuPath = Join-Path $root $config.menuName

        if (-not (Test-Path -LiteralPath $menuPath)) {
            New-Item -Path $menuPath -Force | Out-Null
        }
        New-ItemProperty -Path $menuPath -Name 'MUIVerb' -Value $config.menuLabel -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $menuPath -Name 'SubCommands' -Value '' -PropertyType String -Force | Out-Null

        $mainIcon = Join-Path $deployDir 'vibecode.ico'
        if (Test-Path -LiteralPath $mainIcon -PathType Leaf) {
            New-ItemProperty -Path $menuPath -Name 'Icon' -Value $mainIcon -PropertyType String -Force | Out-Null
        }

        Remove-ItemProperty -Path $menuPath -Name 'ExtendedSubCommandsKey' -ErrorAction SilentlyContinue

        # 安装操作以本次明确选择为准，先移除所有已知工具的旧菜单项。
        $shellPath = Join-Path $menuPath 'shell'
        if (Test-Path -LiteralPath $shellPath) {
            Get-ChildItem -LiteralPath $shellPath -ErrorAction SilentlyContinue | ForEach-Object {
                $label = $_.GetValue('MUIVerb')
                if ($_.PSChildName -in $configuredKeys -or $label -in $configuredLabels) {
                    Remove-Item -LiteralPath $_.PSPath -Recurse -Force
                }
            }
        }

        foreach ($item in $items) {
            $itemPath = Join-Path $menuPath ("shell\" + $item.Key)
            $commandPath = Join-Path $itemPath 'command'

            New-Item -Path $commandPath -Force | Out-Null
            New-ItemProperty -Path $itemPath -Name 'MUIVerb' -Value $item.Label -PropertyType String -Force | Out-Null

            $iconPath = Join-Path $deployDir $item.Icon
            if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
                New-ItemProperty -Path $itemPath -Name 'Icon' -Value $iconPath -PropertyType String -Force | Out-Null
            }

            $cmd = '"{0}" -d "{1}" "{2}" -NoExit -ExecutionPolicy Bypass -File "{3}" -Tool "{4}" -Path "{1}"' -f $terminalPath, $token, $powerShellPath, $launcherPath, $item.Tool
            Set-ItemProperty -Path $commandPath -Name '(default)' -Value $cmd
        }
    }

    Write-Host ""
    Write-Host "安装完成！已部署到: $deployDir" -ForegroundColor Green
    Write-Host "已安装菜单: $($availableGroups -join ', ')" -ForegroundColor Green
    Write-Host "右键文件夹或文件夹空白处，即可看到 $($config.menuLabel) 菜单。" -ForegroundColor Cyan
    $selectedApiCommands = @($availableTools | Where-Object {
        $_.command -in @('codex', 'claude')
    } | ForEach-Object { $_.command })
    if ($selectedApiCommands.Count -gt 0) {
        Configure-AiApiSettings -OnlyMissing -PromptFirst -Commands $selectedApiCommands
    }
}

# ============================================================
# 卸载
# ============================================================
function Uninstall-Menu {
    $config = Get-Config
    $menuName = $config.menuName

    $roots = @(
        'HKCU:\Software\Classes\Directory\shell',
        'HKCU:\Software\Classes\Directory\Background\shell'
    )

    $registeredItems = @{}
    foreach ($root in $roots) {
        $shellPath = Join-Path (Join-Path $root $menuName) 'shell'
        if (Test-Path -LiteralPath $shellPath) {
            Get-ChildItem -LiteralPath $shellPath -ErrorAction SilentlyContinue | ForEach-Object {
                $key = $_.PSChildName
                if (-not $registeredItems.ContainsKey($key)) {
                    $registeredItems[$key] = [pscustomobject]@{
                        Key = $key
                        Label = $_.GetValue('MUIVerb')
                    }
                }
            }
        }
    }

    if ($registeredItems.Count -eq 0) {
        Write-Host ""
        Write-Host "未找到 $menuName 右键菜单，无需卸载。" -ForegroundColor Yellow
        return
    }

    $configuredItems = @(Get-MenuItems -Config $config)
    $groups = @()
    foreach ($tool in $config.tools) {
        $toolItems = @($configuredItems | Where-Object { $_.Group -eq $tool.name })
        $keys = @($registeredItems.Values | Where-Object {
            $registeredItem = $_
            @($toolItems | Where-Object {
                $_.Key -eq $registeredItem.Key -or $_.Label -eq $registeredItem.Label
            }).Count -gt 0
        } | ForEach-Object { $_.Key } | Select-Object -Unique)

        if ($keys.Count -gt 0) {
            $groups += [pscustomobject]@{
                Name = $tool.name
                Keys = $keys
            }
        }
    }

    $knownKeys = @($groups | ForEach-Object { $_.Keys })
    $unknownKeys = @($registeredItems.Keys | Where-Object { $_ -notin $knownKeys } | Sort-Object)
    if ($unknownKeys.Count -gt 0) {
        $groups += [pscustomobject]@{
            Name = '其他（配置中未识别）'
            Keys = $unknownKeys
        }
    }

    Write-Host ""
    Write-Host "当前已注册的 AI 工具:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  0) 全部删除" -ForegroundColor Red
    $i = 1
    foreach ($group in $groups) {
        $labels = @($group.Keys | ForEach-Object {
            $label = $registeredItems[$_].Label
            if ($label) { $label } else { $_ }
        })
        Write-Host "  $i) $($group.Name) ($($group.Keys.Count) 个菜单项: $($labels -join ', '))"
        $i++
    }
    Write-Host ""

    $choice = Read-Host "输入 AI 工具编号卸载（逗号分隔），输入 0 全部卸载"

    $removeAll = $choice.Trim() -eq '0'
    $selectedGroups = @()
    if ($removeAll) {
        $selectedGroups = @($groups)
    } else {
        foreach ($c in ($choice -split ',')) {
            $number = 0
            if ([int]::TryParse($c.Trim(), [ref]$number)) {
                $idx = $number - 1
                if ($idx -ge 0 -and $idx -lt $groups.Count) {
                    $selectedGroups += $groups[$idx]
                }
            }
        }
    }

    $selectedGroups = @($selectedGroups | Sort-Object Name -Unique)
    $selected = @($selectedGroups | ForEach-Object { $_.Keys } | Select-Object -Unique)

    if ($selected.Count -eq 0) {
        Write-Host "未选择任何 AI 工具，已取消。" -ForegroundColor Yellow
        return
    }

    foreach ($root in $roots) {
        $menuPath = Join-Path $root $menuName
        $shellPath = Join-Path $menuPath 'shell'

        foreach ($item in $selected) {
            $itemPath = Join-Path $shellPath $item
            if (Test-Path -LiteralPath $itemPath) {
                Remove-Item -LiteralPath $itemPath -Recurse -Force
            }
        }

        if (Test-Path -LiteralPath $shellPath) {
            $remaining = @(Get-ChildItem -LiteralPath $shellPath -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $shellPath -Recurse -Force
            }
        }

        if (Test-Path -LiteralPath $menuPath) {
            $parentRemaining = @(Get-ChildItem -LiteralPath $menuPath -ErrorAction SilentlyContinue)
            if ($parentRemaining.Count -eq 0) {
                Remove-Item -LiteralPath $menuPath -Force
            }
        }
    }

    if ($removeAll) {
        foreach ($root in $roots) {
            $menuPath = Join-Path $root $menuName
            if (Test-Path -LiteralPath $menuPath) {
                Remove-Item -LiteralPath $menuPath -Recurse -Force
            }
        }

        $deployDir = Get-VibeCodeDeployDirectory -MenuName $menuName
        if (Test-Path -LiteralPath $deployDir) {
            $managedFiles = @(
                'Start-VibeCodeTool.ps1',
                'tools.json',
                'vibecode.ico'
            ) + @($config.tools | ForEach-Object { $_.icon })
            foreach ($fileName in @($managedFiles | Select-Object -Unique)) {
                if ([string]::IsNullOrWhiteSpace($fileName)) {
                    continue
                }
                $filePath = Join-Path $deployDir ([IO.Path]::GetFileName($fileName))
                if (Test-Path -LiteralPath $filePath -PathType Leaf) {
                    Remove-Item -LiteralPath $filePath -Force
                }
            }

            $remaining = @(Get-ChildItem -LiteralPath $deployDir -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $deployDir -Force
                Write-Host "已清理部署目录: $deployDir" -ForegroundColor DarkGray
            } else {
                Write-Host "部署目录含有非 VibeCode 文件，已保留: $deployDir" -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""
    Write-Host "已卸载 $($selectedGroups.Count) 个 AI 工具（共 $($selected.Count) 个菜单项）:" -ForegroundColor Green
    $selectedGroups | ForEach-Object { Write-Host "  [x] $($_.Name)" }

    $parentExists = $false
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath (Join-Path $root $menuName)) {
            $parentExists = $true; break
        }
    }
    if ($parentExists) {
        Write-Host "$menuName 菜单仍有剩余项。" -ForegroundColor DarkGray
    } else {
        Write-Host "$menuName 菜单已完全移除。" -ForegroundColor Green
    }
}

# ============================================================
# 查看工具状态
# ============================================================
function Show-Status {
    $config = Get-Config
    Update-ProcessPath

    $terminalPath = Get-WindowsTerminalPath
    $powerShellPath = Get-PowerShell7Path
    Write-Host ""
    Write-Host "运行环境:" -ForegroundColor Cyan
    if ($terminalPath) {
        Write-Host "  [已安装] Windows Terminal -> $terminalPath" -ForegroundColor Green
    } else {
        Write-Host "  [未安装] Windows Terminal" -ForegroundColor Yellow
    }
    if ($powerShellPath) {
        Write-Host "  [已安装] PowerShell 7 -> $powerShellPath" -ForegroundColor Green
    } else {
        Write-Host "  [未安装] PowerShell 7" -ForegroundColor Yellow
    }

    $nvmPath = Get-NvmPath
    $nodeRuntime = Get-NodeRuntime
    if ($nvmPath) {
        Write-Host "  [已安装] NVM -> $nvmPath" -ForegroundColor Green
    } else {
        Write-Host '  [未安装] NVM' -ForegroundColor DarkGray
    }
    if ($nodeRuntime) {
        Write-Host "  [已安装] Node.js $($nodeRuntime.Version) -> $($nodeRuntime.NodePath)" `
            -ForegroundColor Green
    } else {
        Write-Host '  [未安装] Node.js/npm' -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "已配置的工具:" -ForegroundColor Cyan
    Write-Host ""
    foreach ($t in $config.tools) {
        $installed = Test-ToolInstalled $t.command
        $status = if ($installed) { "[已安装]" } else { "[未安装]" }
        $color = if ($installed) { "Green" } else { "DarkGray" }
        $superInfo = if ($t.super) { " (Super: $($t.super.label), Resume: $($t.super.label)-R)" } else { "" }
        Write-Host "  $status $($t.name) -> $($t.command)$superInfo" -ForegroundColor $color
    }

    Write-Host ''
    Write-Host 'API 配置（Key 仅显示是否存在）:' -ForegroundColor Cyan
    Show-ApiConfigurationStatus
}

function Install-RuntimeDependencies {
    Write-Host ""
    Write-Host "安装或修复运行环境:" -ForegroundColor Cyan
    try {
        $runtime = Ensure-VibeCodeRuntime
        Write-Host ""
        Write-Host "运行环境已就绪。" -ForegroundColor Green
        Write-Host "  Terminal: $($runtime.TerminalPath)"
        Write-Host "  PowerShell: $($runtime.PowerShellPath)"
    } catch {
        Write-Host "运行环境安装失败: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "请确认 installers 目录中包含当前架构的完整离线包。" -ForegroundColor Yellow
    }
}

# ============================================================
# 主菜单
# ============================================================
while ($true) {
    $config = Get-Config
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  $($config.menuLabel) 工具管理" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1) 安装右键菜单（自动检查运行环境）"
    Write-Host "  2) 卸载右键菜单"
    Write-Host "  3) 查看工具状态"
    Write-Host "  4) 安装/修复运行环境"
    Write-Host "  5) 安装/更新 Codex、Claude、OpenCode CLI"
    Write-Host "  6) 配置 Codex/Claude API"
    Write-Host "  0/Q) 退出"
    Write-Host ""

    try {
        $choice = Read-Host "请选择操作"
    } catch {
        return
    }
    if ([string]::IsNullOrWhiteSpace($choice)) {
        return
    }
    $choice = $choice.Trim().ToLowerInvariant()

    switch ($choice) {
        '1' { Install-Menu }
        '2' { Uninstall-Menu }
        '3' { Show-Status }
        '4' { Install-RuntimeDependencies }
        '5' { Install-AiCliTools -UpdateExisting }
        '6' { Configure-AiApiSettings }
        '0' { return }
        'q' { return }
        'qq' { return }
        'quit' { return }
        'exit' { return }
        default { Write-Host "无效选择，请重新输入。" -ForegroundColor Yellow }
    }
}

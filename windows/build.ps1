#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('auto', 'win-x64', 'win-arm64')]
    [string]$Runtime = 'auto',
    [string]$Version,
    [switch]$FrameworkDependent,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$projectRoot = Split-Path -Parent $scriptDir
$csproj = Join-Path $scriptDir 'VibeCodeApp\VibeCodeApp.csproj'
$versionFile = Join-Path $scriptDir 'VERSION'

if (-not (Get-Command 'dotnet' -ErrorAction SilentlyContinue)) {
    throw '未检测到 .NET SDK（dotnet）。请先安装 .NET 8 SDK: https://dotnet.microsoft.com/download/dotnet/8.0'
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = if (Test-Path -LiteralPath $versionFile) {
        (Get-Content -LiteralPath $versionFile -Raw).Trim()
    } else {
        '1.0.0'
    }
}

if ($Runtime -eq 'auto') {
    $arch = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = $env:PROCESSOR_ARCHITECTURE }
    $Runtime = if ($arch -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
}

$selfContained = if ($FrameworkDependent) { 'false' } else { 'true' }
$publishDir = Join-Path ([IO.Path]::GetTempPath()) ("VibeCodeWinBuild-" + [guid]::NewGuid().ToString('N'))
$deployDir = Join-Path $env:LOCALAPPDATA 'VibeCode'

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  VibeCode Windows 原生版构建" -ForegroundColor Cyan
    Write-Host "  版本: v$Version | 架构: $Runtime | 独立单文件: $selfContained" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    Write-Host '==> [1/3] 正在发布 VibeCode.exe...' -ForegroundColor Cyan
    & dotnet publish $csproj `
        -c Release `
        -r $Runtime `
        --self-contained $selfContained `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        "-p:Version=$Version" `
        -o $publishDir
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish 失败（退出码 $LASTEXITCODE）。"
    }

    $builtExe = Join-Path $publishDir 'VibeCode.exe'
    if (-not (Test-Path -LiteralPath $builtExe -PathType Leaf)) {
        throw "构建产物不存在: $builtExe"
    }

    Write-Host "==> [2/3] 部署到 $deployDir..." -ForegroundColor Cyan
    Get-Process -Name 'VibeCode' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300

    New-Item -Path $deployDir -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $builtExe -Destination (Join-Path $deployDir 'VibeCode.exe') -Force

    # 记录项目目录，便于设置页修改 tools.json 时双向同步
    $winCfgPath = Join-Path $deployDir 'windows.json'
    if (Test-Path -LiteralPath $winCfgPath -PathType Leaf) {
        try {
            $cfg = Get-Content -LiteralPath $winCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $cfg | Add-Member -NotePropertyName 'projectDir' -NotePropertyValue $projectRoot -Force
            $json = ($cfg | ConvertTo-Json -Depth 10) + "`r`n"
            [IO.File]::WriteAllText($winCfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            # 忽略解析异常，首次启动时由应用重建
        }
    }

    Write-Host '==> [3/3] 完成安装！' -ForegroundColor Green
    $installedExe = Join-Path $deployDir 'VibeCode.exe'
    Write-Host "  可执行文件: $installedExe" -ForegroundColor Green

    if (-not $NoLaunch) {
        Start-Process -FilePath $installedExe
        Write-Host '  已启动 VibeCode，可在系统托盘与设置窗口中管理右键菜单。' -ForegroundColor Cyan
    }
} finally {
    if (Test-Path -LiteralPath $publishDir) {
        Remove-Item -LiteralPath $publishDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64', 'all')]
    [string]$Runtime = 'win-x64',
    [string]$Version,
    [string]$OutputDir,
    [switch]$FrameworkDependent,
    [switch]$InnoSetup
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$projectRoot = Split-Path -Parent $scriptDir
$csproj = Join-Path $scriptDir 'VibeCodeApp\VibeCodeApp.csproj'
$versionFile = Join-Path $scriptDir 'VERSION'
$issScript = Join-Path $scriptDir 'installer\VibeCode.iss'

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
if ($Version -notmatch '^\d+(\.\d+){1,2}(-[0-9A-Za-z.-]+)?$') {
    throw "版本号格式无效: $Version（示例: 1.0.0）"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $projectRoot 'dist'
} elseif (-not [IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path (Get-Location).Path $OutputDir
}
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null

$runtimes = if ($Runtime -eq 'all') { @('win-x64', 'win-arm64') } else { @($Runtime) }
$selfContained = if ($FrameworkDependent) { 'false' } else { 'true' }
$workRoot = Join-Path ([IO.Path]::GetTempPath()) ("VibeCodeWinPack-" + [guid]::NewGuid().ToString('N'))

try {
    New-Item -Path $workRoot -ItemType Directory -Force | Out-Null

    # 生成剔除本机 proxy / useProxy 配置的纯净 tools.json 供打包内嵌
    $cleanToolsPath = Join-Path $workRoot 'tools.clean.json'
    $sourceTools = Get-Content -LiteralPath (Join-Path $projectRoot 'tools.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $sourceTools.PSObject.Properties['proxy']) {
        $sourceTools.PSObject.Properties.Remove('proxy')
    }
    foreach ($tool in @($sourceTools.tools)) {
        if ($null -ne $tool.PSObject.Properties['useProxy']) {
            $tool.PSObject.Properties.Remove('useProxy')
        }
    }
    $cleanJson = ($sourceTools | ConvertTo-Json -Depth 10) + "`r`n"
    [IO.File]::WriteAllText($cleanToolsPath, $cleanJson, (New-Object System.Text.UTF8Encoding($false)))

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $results = @()

    foreach ($rid in $runtimes) {
        $archTag = $rid.Replace('win-', '')
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  打包 VibeCode Windows 原生版 v$Version ($rid)" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan

        $publishDir = Join-Path $workRoot "pub-$rid"
        & dotnet publish $csproj `
            -c Release `
            -r $rid `
            --self-contained $selfContained `
            -p:PublishSingleFile=true `
            -p:IncludeNativeLibrariesForSelfExtract=true `
            "-p:Version=$Version" `
            "-p:CleanToolsJsonPath=$cleanToolsPath" `
            -o $publishDir
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet publish ($rid) 失败（退出码 $LASTEXITCODE）。"
        }

        $builtExe = Join-Path $publishDir 'VibeCode.exe'
        if (-not (Test-Path -LiteralPath $builtExe -PathType Leaf)) {
            throw "未找到发布产物: $builtExe"
        }

        # 1. 组装绿色单文件便携 ZIP 包
        $stageDir = Join-Path $workRoot "stage-$rid"
        $bundleRoot = Join-Path $stageDir "VibeCode-v$Version-win-$archTag"
        New-Item -Path $bundleRoot -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $builtExe -Destination (Join-Path $bundleRoot 'VibeCode.exe') -Force

        $guideText = @"
VibeCode Context Menu v$Version (Windows $archTag 原生软件版)
作者: 清风惹尘丶
GitHub: https://github.com/myucxy/VibeCodeContextMenu

【使用说明】
1. 将 VibeCode.exe 放到固定目录（建议 %LOCALAPPDATA%\VibeCode\），双击运行即可。
2. 首次启动会自动探测本机已安装的 AI CLI 与终端，并自动注册资源管理器右键级联菜单（无需管理员权限）。
3. 双击或右键系统托盘中的 VibeCode 图标，可随时管理 AI 工具、拖拽排序、开关右键菜单、配置代理与默认终端。
4. 如需彻底移除右键菜单，可在设置窗口关闭「显示右键菜单」开关，或在命令行执行：
   VibeCode.exe --uninstall
"@
        [IO.File]::WriteAllText((Join-Path $bundleRoot '安装说明.txt'), $guideText, (New-Object System.Text.UTF8Encoding($false)))

        $zipName = "VibeCode-v$Version-win-$archTag.zip"
        $zipPath = Join-Path $OutputDir $zipName
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        [IO.Compression.ZipFile]::CreateFromDirectory($stageDir, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)

        $zipSha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText("$zipPath.sha256", "$zipSha  $zipName`r`n", (New-Object System.Text.UTF8Encoding($false)))
        $zipSizeMiB = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)

        Write-Host "  [OK] ZIP: $zipPath ($zipSizeMiB MiB)" -ForegroundColor Green
        Write-Host "       SHA256: $zipSha" -ForegroundColor DarkGray
        $results += [pscustomobject]@{ Type = 'ZIP'; Arch = $archTag; Path = $zipPath; SizeMiB = $zipSizeMiB; SHA256 = $zipSha }

        # 2. 可选调用 Inno Setup (ISCC.exe) 生成标准 Setup 安装向导 .exe
        if ($InnoSetup) {
            $iscc = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $iscc) {
                foreach ($p in @(
                    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
                    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
                )) {
                    if (Test-Path -LiteralPath $p -PathType Leaf) {
                        $iscc = [pscustomobject]@{ Source = $p }
                        break
                    }
                }
            }
            if (-not $iscc) {
                Write-Host '  [--] 未检测到 Inno Setup 6 (ISCC.exe)，已跳过 Setup 安装包生成。' -ForegroundColor Yellow
            } else {
                $setupBase = "VibeCode-v$Version-win-$archTag-Setup"
                & $iscc.Source `
                    "/DMyAppVersion=$Version" `
                    "/DMyAppArch=$archTag" `
                    "/DMySourceExe=$builtExe" `
                    "/DMyIconFile=$(Join-Path $projectRoot 'ico\vibecode.ico')" `
                    "/DMyOutputDir=$OutputDir" `
                    "/DMyOutputBaseFilename=$setupBase" `
                    $issScript
                if ($LASTEXITCODE -ne 0) {
                    throw "Inno Setup 编译失败（退出码 $LASTEXITCODE）。"
                }
                $setupPath = Join-Path $OutputDir "$setupBase.exe"
                $setupSha = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
                [IO.File]::WriteAllText("$setupPath.sha256", "$setupSha  $setupBase.exe`r`n", (New-Object System.Text.UTF8Encoding($false)))
                $setupSizeMiB = [math]::Round((Get-Item -LiteralPath $setupPath).Length / 1MB, 2)
                Write-Host "  [OK] Setup: $setupPath ($setupSizeMiB MiB)" -ForegroundColor Green
                Write-Host "       SHA256: $setupSha" -ForegroundColor DarkGray
                $results += [pscustomobject]@{ Type = 'Setup'; Arch = $archTag; Path = $setupPath; SizeMiB = $setupSizeMiB; SHA256 = $setupSha }
            }
        }
    }

    Write-Host ""
    Write-Host "打包完成，共生成 $($results.Count) 个产物（输出目录: $OutputDir）。" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

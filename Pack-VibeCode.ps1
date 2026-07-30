#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$Force,
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-RequiredFileSpec {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "打包所需文件不存在: $RelativePath"
    }

    [pscustomobject]@{
        SourcePath   = (Get-Item -LiteralPath $sourcePath).FullName
        RelativePath = $RelativePath
    }
}

function Assert-SafeFileName {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($FileName) -or
        [IO.Path]::GetFileName($FileName) -ne $FileName -or
        $FileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "$Description 的文件名不安全: $FileName"
    }
}

$sourceRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($sourceRoot)) {
    throw '无法确定项目根目录。'
}
$sourceRoot = [IO.Path]::GetFullPath($sourceRoot)

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $sourceRoot 'dist\VibeCodeContextMenu-offline.zip'
} elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $sourceRoot $OutputPath
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

if ([IO.Path]::GetExtension($OutputPath) -ine '.zip') {
    throw '输出文件必须使用 .zip 扩展名。'
}

$installersRoot = [IO.Path]::GetFullPath((Join-Path $sourceRoot 'installers')).TrimEnd('\') + '\'
if ($OutputPath.StartsWith($installersRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw '输出压缩包不能放入 installers 目录，以免覆盖离线源包。'
}

if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "输出文件已存在，请使用 -Force 覆盖: $OutputPath"
}

$toolsPath = Join-Path $sourceRoot 'tools.json'
try {
    $toolsConfig = Get-Content -LiteralPath $toolsPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    throw "tools.json 无法读取: $($_.Exception.Message)"
}

$manifestPath = Join-Path $sourceRoot 'installers\installers.json'
try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    throw "installers.json 无法读取: $($_.Exception.Message)"
}

$fileSpecs = @()
foreach ($relativePath in @(
    'VibeCode.bat',
    'VibeCode.ps1',
    'tools.json',
    'README.md',
    'a.png',
    'installers\installers.json',
    'installers\powershell\portable-sha256.txt'
)) {
    $fileSpecs += Get-RequiredFileSpec -SourceRoot $sourceRoot -RelativePath $relativePath
}

$iconNames = @('vibecode.ico')
foreach ($tool in @($toolsConfig.tools)) {
    if ($tool.icon) {
        $iconNames += [string]$tool.icon
    }
}
foreach ($iconName in @($iconNames | Sort-Object -Unique)) {
    Assert-SafeFileName -FileName $iconName -Description '图标'
    if ([IO.Path]::GetExtension($iconName) -ine '.ico') {
        throw "图标必须使用 .ico 扩展名: $iconName"
    }
    $fileSpecs += Get-RequiredFileSpec -SourceRoot $sourceRoot -RelativePath (Join-Path 'ico' $iconName)
}

$assetGroups = @(
    [pscustomobject]@{
        Key       = 'windowsTerminal'
        Name      = 'Windows Terminal'
        Directory = 'installers\windows-terminal'
    },
    [pscustomobject]@{
        Key       = 'powerShell'
        Name      = 'PowerShell'
        Directory = 'installers\powershell'
    }
)
$assetRecords = @()
$powerShellAssets = @()

foreach ($group in $assetGroups) {
    $sectionProperty = $manifest.PSObject.Properties[$group.Key]
    if ($null -eq $sectionProperty -or
        $null -eq $sectionProperty.Value.portable -or
        $null -eq $sectionProperty.Value.portable.assets) {
        throw "installers.json 缺少 $($group.Name) portable 配置。"
    }

    $assets = $sectionProperty.Value.portable.assets
    foreach ($architecture in @('x64', 'arm64')) {
        $assetProperty = $assets.PSObject.Properties[$architecture]
        if ($null -eq $assetProperty) {
            throw "installers.json 缺少 $($group.Name) $architecture 离线包。"
        }

        $fileName = [string]$assetProperty.Value.file
        $expectedHash = [string]$assetProperty.Value.sha256
        Assert-SafeFileName -FileName $fileName -Description "$($group.Name) $architecture"
        if ([IO.Path]::GetExtension($fileName) -ine '.zip') {
            throw "$($group.Name) $architecture 离线包必须是 ZIP: $fileName"
        }
        if ($expectedHash -notmatch '\A[0-9a-fA-F]{64}\z') {
            throw "$($group.Name) $architecture SHA-256 无效。"
        }

        $relativePath = Join-Path $group.Directory $fileName
        $spec = Get-RequiredFileSpec -SourceRoot $sourceRoot -RelativePath $relativePath
        $record = [pscustomobject]@{
            Name          = $group.Name
            Architecture  = $architecture
            FileName      = $fileName
            SourcePath    = $spec.SourcePath
            RelativePath  = $spec.RelativePath
            ExpectedHash  = $expectedHash.ToLowerInvariant()
        }
        $assetRecords += $record
        $fileSpecs += $spec
        if ($group.Key -eq 'powerShell') {
            $powerShellAssets += $record
        }
    }
}

if ($null -eq $manifest.developerTools -or
    $null -eq $manifest.developerTools.nvmWindows.portable -or
    $null -eq $manifest.developerTools.node.portable -or
    $null -eq $manifest.developerTools.aiCli) {
    throw 'installers.json 缺少开发工具离线包配置。'
}

$developerAssets = @(
    [pscustomobject]@{
        Name = 'NVM'
        Architecture = 'all'
        Directory = 'installers\nvm'
        Asset = $manifest.developerTools.nvmWindows.portable
    }
)
foreach ($architecture in @('x64', 'arm64')) {
    $nodeProperty = $manifest.developerTools.node.portable.assets.PSObject.Properties[$architecture]
    $cliProperty = $manifest.developerTools.aiCli.assets.PSObject.Properties[$architecture]
    if ($null -eq $nodeProperty -or $null -eq $cliProperty) {
        throw "installers.json 缺少开发工具 $architecture 离线包。"
    }
    $developerAssets += [pscustomobject]@{
        Name = 'Node.js'
        Architecture = $architecture
        Directory = 'installers\node'
        Asset = $nodeProperty.Value
    }
    $developerAssets += [pscustomobject]@{
        Name = 'AI CLI'
        Architecture = $architecture
        Directory = 'installers\ai-cli'
        Asset = $cliProperty.Value
    }
}

foreach ($developerAsset in $developerAssets) {
    $fileName = [string]$developerAsset.Asset.file
    $expectedHash = [string]$developerAsset.Asset.sha256
    Assert-SafeFileName -FileName $fileName `
        -Description "$($developerAsset.Name) $($developerAsset.Architecture)"
    if ([IO.Path]::GetExtension($fileName) -ine '.zip' -or
        $expectedHash -notmatch '\A[0-9a-fA-F]{64}\z') {
        throw "$($developerAsset.Name) $($developerAsset.Architecture) 离线包清单无效。"
    }
    $relativePath = Join-Path $developerAsset.Directory $fileName
    $spec = Get-RequiredFileSpec -SourceRoot $sourceRoot -RelativePath $relativePath
    $record = [pscustomobject]@{
        Name = $developerAsset.Name
        Architecture = $developerAsset.Architecture
        FileName = $fileName
        SourcePath = $spec.SourcePath
        RelativePath = $spec.RelativePath
        ExpectedHash = $expectedHash.ToLowerInvariant()
    }
    $assetRecords += $record
    $fileSpecs += $spec
}

$duplicatePaths = @($fileSpecs | Group-Object -Property RelativePath | Where-Object { $_.Count -gt 1 })
if ($duplicatePaths.Count -gt 0) {
    throw "打包白名单包含重复路径: $($duplicatePaths[0].Name)"
}

$portableHashPath = Join-Path $sourceRoot 'installers\powershell\portable-sha256.txt'
$portableHashes = @{}
foreach ($line in @(Get-Content -LiteralPath $portableHashPath -Encoding ASCII)) {
    if ($line -match '\A([0-9a-fA-F]{64}) \*(.+)\z') {
        $portableHashes[$Matches[2]] = $Matches[1].ToLowerInvariant()
    }
}
foreach ($asset in $powerShellAssets) {
    if (-not $portableHashes.ContainsKey($asset.FileName) -or
        $portableHashes[$asset.FileName] -ne $asset.ExpectedHash) {
        throw "portable-sha256.txt 与清单不一致: $($asset.FileName)"
    }
}

Write-Host "正在校验 $($assetRecords.Count) 个离线资源..." -ForegroundColor Cyan
foreach ($asset in $assetRecords) {
    $actualHash = (Get-FileHash -LiteralPath $asset.SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $asset.ExpectedHash) {
        throw "$($asset.Name) $($asset.Architecture) 离线包 SHA-256 校验失败。"
    }
    Write-Host "  [OK] $($asset.Name) $($asset.Architecture)" -ForegroundColor Green
}

$expectedFileHashes = @{}
foreach ($asset in $assetRecords) {
    $expectedFileHashes[$asset.RelativePath] = $asset.ExpectedHash
}
foreach ($spec in $fileSpecs) {
    if (-not $expectedFileHashes.ContainsKey($spec.RelativePath)) {
        $expectedFileHashes[$spec.RelativePath] =
            (Get-FileHash -LiteralPath $spec.SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('VibeCodePackage-' + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $stagingRoot 'VibeCodeContextMenu'
$archiveBaseName = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
$partialPath = Join-Path $outputDirectory ('.{0}.{1}.partial.zip' -f $archiveBaseName, [guid]::NewGuid().ToString('N'))
$backupPath = Join-Path $outputDirectory ('.{0}.{1}.backup.zip' -f $archiveBaseName, [guid]::NewGuid().ToString('N'))
$replacementSucceeded = $false

try {
    New-Item -Path $packageRoot -ItemType Directory -Force | Out-Null

    foreach ($spec in $fileSpecs) {
        $destination = Join-Path $packageRoot $spec.RelativePath
        $destinationDirectory = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
            New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
        }
        Copy-Item -LiteralPath $spec.SourcePath -Destination $destination -Force
    }

    Write-Host '正在复核临时打包目录...' -ForegroundColor Cyan
    foreach ($spec in $fileSpecs) {
        $stagedPath = Join-Path $packageRoot $spec.RelativePath
        $stagedHash = (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($stagedHash -ne $expectedFileHashes[$spec.RelativePath]) {
            throw "文件在打包过程中发生变化: $($spec.RelativePath)"
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Write-Host '正在生成离线压缩包...' -ForegroundColor Cyan
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingRoot,
        $partialPath,
        [IO.Compression.CompressionLevel]::NoCompression,
        $false
    )

    $expectedEntries = @($fileSpecs | ForEach-Object {
        'VibeCodeContextMenu/' + $_.RelativePath.Replace('\', '/')
    } | Sort-Object)

    $zip = [IO.Compression.ZipFile]::OpenRead($partialPath)
    try {
        $actualEntries = @($zip.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) } |
            ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object)
    } finally {
        $zip.Dispose()
    }

    $entryDifferences = @(Compare-Object -ReferenceObject $expectedEntries -DifferenceObject $actualEntries)
    if ($entryDifferences.Count -gt 0) {
        $details = ($entryDifferences | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join '; '
        throw "压缩包内容与白名单不一致: $details"
    }

    if (Test-Path -LiteralPath $OutputPath) {
        if (-not $Force) {
            throw "输出文件在打包过程中已出现，请使用 -Force 覆盖: $OutputPath"
        }
        [IO.File]::Replace($partialPath, $OutputPath, $backupPath, $true)
        $replacementSucceeded = $true
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    } else {
        [IO.File]::Move($partialPath, $OutputPath)
    }

    $archiveItem = Get-Item -LiteralPath $OutputPath
    $archiveHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "打包完成: $OutputPath" -ForegroundColor Green
    Write-Host "SHA-256: $archiveHash" -ForegroundColor DarkGray

    [pscustomobject]@{
        Path          = $archiveItem.FullName
        SizeMiB       = [math]::Round($archiveItem.Length / 1MB, 2)
        FileCount     = $expectedEntries.Count
        SHA256        = $archiveHash
    }
} finally {
    if (Test-Path -LiteralPath $partialPath) {
        Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
    }
    if ($replacementSucceeded -and (Test-Path -LiteralPath $backupPath)) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

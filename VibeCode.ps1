#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

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

function Get-Config {
    $scriptDir = $PSScriptRoot
    $configPath = Join-Path $scriptDir 'tools.json'

    if (-not (Test-Path -LiteralPath $configPath)) {
        New-DefaultConfig -Path $configPath
    }

    return Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
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
    }
  ]
}
'@
    Set-Content -LiteralPath $Path -Value $default -Encoding UTF8
    Write-Host "已生成默认配置: $Path" -ForegroundColor Cyan
}

function Get-IcoPath {
    param([string]$IconName)
    $scriptDir = $PSScriptRoot
    $icoPath = Join-Path (Join-Path $scriptDir 'ico') $IconName
    if (Test-Path -LiteralPath $icoPath) { return $icoPath }
    $icoPath = Join-Path $scriptDir $IconName
    if (Test-Path -LiteralPath $icoPath) { return $icoPath }
    return $null
}

# ============================================================
# 安装
# ============================================================
function Install-Menu {
    $config = Get-Config

    # 部署目录
    $deployDir = Join-Path $env:LOCALAPPDATA $config.menuName
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

    # 构建菜单项
    $allItems = @()
    $i = 0
    foreach ($t in $config.tools) {
        $i++; $prefix = '{0:D2}' -f $i
        $allItems += @{
            Key = "${prefix}_$($t.name)"; Label = $t.name
            Tool = $t.name; Command = $t.command; Icon = $t.icon
        }
        if ($t.super) {
            $i++; $prefix = '{0:D2}' -f $i
            $allItems += @{
                Key = "${prefix}_$($t.super.label)"; Label = $t.super.label
                Tool = $t.super.label; Command = $t.command; Icon = $t.icon
            }
            $i++; $prefix = '{0:D2}' -f $i
            $allItems += @{
                Key = "${prefix}_$($t.super.label)-R"; Label = "$($t.super.label)-R"
                Tool = "$($t.super.label)-R"; Command = $t.command; Icon = $t.icon
            }
        }
    }

    $items = @($allItems | Where-Object { Test-ToolInstalled $_.Command })
    $skipped = @($allItems |
        Where-Object { -not (Test-ToolInstalled $_.Command) } |
        ForEach-Object { $_.Command } | Select-Object -Unique)

    if ($items.Count -eq 0) {
        Write-Host ""
        Write-Host "未检测到任何 AI CLI 工具，无法安装。" -ForegroundColor Yellow
        Write-Host "请先安装以下工具之一: $($config.tools | ForEach-Object { $_.command })" -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "已检测到的工具:" -ForegroundColor Green
    $items | ForEach-Object { $_.Command } | Select-Object -Unique | ForEach-Object {
        Write-Host "  [OK] $_"
    }
    if ($skipped) {
        Write-Host "未安装（已跳过）:" -ForegroundColor DarkGray
        $skipped | ForEach-Object { Write-Host "  [--] $_" }
    }

    $roots = @(
        'HKCU:\Software\Classes\Directory\shell',
        'HKCU:\Software\Classes\Directory\Background\shell'
    )

    foreach ($root in $roots) {
        $token = if ($root -match 'Background') { '%V' } else { '%1' }
        $menuPath = Join-Path $root $config.menuName

        if (-not (Test-Path -LiteralPath $menuPath)) {
            New-Item -Path $menuPath -Force | Out-Null
        }
        New-ItemProperty -Path $menuPath -Name 'MUIVerb' -Value $config.menuLabel -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $menuPath -Name 'SubCommands' -Value '' -PropertyType String -Force | Out-Null

        $mainIcon = Get-IcoPath 'vibecode.ico'
        if ($mainIcon) {
            New-ItemProperty -Path $menuPath -Name 'Icon' -Value $mainIcon -PropertyType String -Force | Out-Null
        }

        Remove-ItemProperty -Path $menuPath -Name 'ExtendedSubCommandsKey' -ErrorAction SilentlyContinue

        foreach ($item in $items) {
            $itemPath = Join-Path $menuPath ("shell\" + $item.Key)
            $commandPath = Join-Path $itemPath 'command'

            New-Item -Path $commandPath -Force | Out-Null
            New-ItemProperty -Path $itemPath -Name 'MUIVerb' -Value $item.Label -PropertyType String -Force | Out-Null

            $iconPath = Get-IcoPath $item.Icon
            if ($iconPath) {
                New-ItemProperty -Path $itemPath -Name 'Icon' -Value $iconPath -PropertyType String -Force | Out-Null
            }

            $cmd = 'wt.exe -d "{0}" pwsh.exe -NoExit -ExecutionPolicy Bypass -File "{1}" -Tool "{2}" -Path "{0}"' -f $token, $launcherPath, $item.Tool
            Set-ItemProperty -Path $commandPath -Name '(default)' -Value $cmd
        }
    }

    Write-Host ""
    Write-Host "安装完成！已部署到: $deployDir" -ForegroundColor Green
    Write-Host "右键文件夹或文件夹空白处，即可看到 $($config.menuLabel) 菜单。" -ForegroundColor Cyan
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

    $subItems = @()
    foreach ($root in $roots) {
        $shellPath = Join-Path (Join-Path $root $menuName) 'shell'
        if (Test-Path -LiteralPath $shellPath) {
            Get-ChildItem -LiteralPath $shellPath -ErrorAction SilentlyContinue |
                ForEach-Object { $subItems += $_.PSChildName }
        }
    }
    $subItems = @($subItems | Select-Object -Unique)

    if ($subItems.Count -eq 0) {
        Write-Host ""
        Write-Host "未找到 $menuName 右键菜单，无需卸载。" -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "当前已注册的菜单项:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  0) 全部删除" -ForegroundColor Red
    $i = 1
    foreach ($item in $subItems) {
        Write-Host "  $i) $item"
        $i++
    }
    Write-Host ""

    $choice = Read-Host "输入编号删除（逗号分隔），输入 0 删除全部"

    $selected = @()
    if ($choice -eq '0') {
        $selected = @($subItems)
    } else {
        foreach ($c in ($choice -split ',')) {
            $idx = [int]$c.Trim() - 1
            if ($idx -ge 0 -and $idx -lt $subItems.Count) {
                $selected += $subItems[$idx]
            }
        }
    }

    if ($selected.Count -eq 0) {
        Write-Host "未选择任何项，已取消。" -ForegroundColor Yellow
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

    if ($choice -eq '0') {
        foreach ($root in $roots) {
            $menuPath = Join-Path $root $menuName
            if (Test-Path -LiteralPath $menuPath) {
                Remove-Item -LiteralPath $menuPath -Recurse -Force
            }
        }

        $deployDir = Join-Path $env:LOCALAPPDATA $menuName
        if (Test-Path -LiteralPath $deployDir) {
            Remove-Item -LiteralPath $deployDir -Recurse -Force
            Write-Host "已清理部署文件: $deployDir" -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host "已删除 $($selected.Count) 个菜单项:" -ForegroundColor Green
    $selected | ForEach-Object { Write-Host "  [x] $_" }

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
    Write-Host "  1) 安装右键菜单"
    Write-Host "  2) 卸载右键菜单"
    Write-Host "  3) 查看工具状态"
    Write-Host "  0) 退出"
    Write-Host ""

    $choice = Read-Host "请选择操作"

    switch ($choice) {
        '1' { Install-Menu }
        '2' { Uninstall-Menu }
        '3' { Show-Status }
        '0' { return }
        default { Write-Host "无效选择，请重新输入。" -ForegroundColor Yellow }
    }
}

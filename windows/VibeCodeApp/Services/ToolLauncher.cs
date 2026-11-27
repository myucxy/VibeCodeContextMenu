using System.Diagnostics;
using System.Text;
using VibeCodeApp.Models;

namespace VibeCodeApp.Services;

/// <summary>
/// 独立 CLI 启动器（VibeCode.exe --launch &lt;toolKey&gt; &lt;targetPath&gt;）。
/// 通过自清理临时脚本注入最新环境变量、代理与 globalEnv/super.env，
/// 彻底规避 Windows Terminal 单实例进程丢环境变量的经典坑，且不强依赖 PowerShell 7。
/// </summary>
public static class ToolLauncher
{
    private sealed record ResolvedLaunch(
        string Command,
        Dictionary<string, string>? ExtraEnv,
        bool UseProxy);

    public static void Launch(string toolKey, string rawTargetPath)
    {
        var targetDir = NormalizeTargetDirectory(rawTargetPath);
        if (string.IsNullOrWhiteSpace(targetDir) || !Directory.Exists(targetDir))
        {
            MessageBox.Show(
                $"目标文件夹不存在:\n{rawTargetPath}",
                "VibeCode 启动失败",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return;
        }

        var toolsCfg = ConfigService.LoadToolsConfig();
        var winCfg = ConfigService.LoadWindowsConfig();

        var toolMap = BuildToolMap(toolsCfg);
        if (!toolMap.TryGetValue(toolKey, out var entry))
        {
            MessageBox.Show(
                $"未在配置中找到工具: {toolKey}",
                "VibeCode 启动失败",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return;
        }

        var terminalId = winCfg.Terminal;
        var exePath = ResolveTerminalExe(terminalId, winCfg.TerminalExePath);

        // 选定的终端被卸载时回退到首个可用终端
        if (string.IsNullOrWhiteSpace(exePath))
        {
            var fallback = TerminalService.DetectInstalledTerminals().FirstOrDefault();
            if (fallback is null)
            {
                MessageBox.Show("未找到可用的终端程序。", "VibeCode 启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            terminalId = fallback.Spec.Id;
            exePath = fallback.ExecutablePath;
        }

        try
        {
            LaunchInTerminal(terminalId, exePath, toolKey, targetDir, toolsCfg, entry, winCfg.RunTerminalAsAdmin);
        }
        catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            // 用户在 UAC 弹窗点击了“否/取消”，静默忽略
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                $"启动终端失败:\n{ex.Message}",
                "VibeCode 启动失败",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private static string NormalizeTargetDirectory(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return string.Empty;
        // 处理 Windows 注册表 "%V" 在盘符根目录（如 C:\）时尾部反斜杠转义引号的经典问题
        var cleaned = raw.Trim().Trim('"');
        if (cleaned.Length == 2 && char.IsLetter(cleaned[0]) && cleaned[1] == ':')
        {
            cleaned += "\\";
        }
        if (File.Exists(cleaned))
        {
            return Path.GetDirectoryName(cleaned) ?? string.Empty;
        }
        return cleaned;
    }

    private static Dictionary<string, ResolvedLaunch> BuildToolMap(ToolsConfig config)
    {
        var map = new Dictionary<string, ResolvedLaunch>(StringComparer.OrdinalIgnoreCase);
        foreach (var t in config.Tools)
        {
            if (string.IsNullOrWhiteSpace(t.Name) || string.IsNullOrWhiteSpace(t.Command)) continue;
            var useProxy = t.UseProxy != false;
            map[t.Name] = new ResolvedLaunch(t.Command, null, useProxy);

            if (t.Super is not null && !string.IsNullOrWhiteSpace(t.Super.Label) && !string.IsNullOrWhiteSpace(t.Super.Command))
            {
                map[t.Super.Label] = new ResolvedLaunch(t.Super.Command, t.Super.Env, useProxy);
                var resumeCmd = !string.IsNullOrWhiteSpace(t.Super.Resume?.Command)
                    ? t.Super.Resume.Command
                    : $"{t.Super.Command} -R";
                map[$"{t.Super.Label}-R"] = new ResolvedLaunch(resumeCmd, t.Super.Env, useProxy);
            }
        }
        return map;
    }

    private static string? ResolveTerminalExe(string terminalId, string? savedPath)
    {
        if (!string.IsNullOrWhiteSpace(savedPath) && File.Exists(savedPath))
        {
            return savedPath;
        }
        return TerminalService.FindTerminalExecutable(terminalId);
    }

    private static void LaunchInTerminal(
        string terminalId,
        string terminalExe,
        string toolKey,
        string targetDir,
        ToolsConfig config,
        ResolvedLaunch entry,
        bool runAsAdmin)
    {
        var dirName = Path.GetFileName(targetDir.TrimEnd('\\', '/'));
        if (string.IsNullOrEmpty(dirName)) dirName = targetDir;
        var windowTitle = $"VibeCode - {toolKey} ({dirName})";

        switch (terminalId)
        {
            case "WindowsTerminal":
            {
                var pwsh = TerminalService.FindTerminalExecutable("PowerShell7");
                if (!string.IsNullOrWhiteSpace(pwsh))
                {
                    var ps1 = WriteTempPowerShellRunner(toolKey, targetDir, windowTitle, config, entry);
                    StartProcess(terminalExe, $"-d \"{targetDir}\" \"{pwsh}\" -NoLogo -NoExit -ExecutionPolicy Bypass -File \"{ps1}\"", targetDir, runAsAdmin);
                }
                else
                {
                    var cmdScript = WriteTempCmdRunner(toolKey, targetDir, windowTitle, config, entry);
                    StartProcess(terminalExe, $"-d \"{targetDir}\" cmd.exe /d /k \"{cmdScript}\"", targetDir, runAsAdmin);
                }
                break;
            }

            case "PowerShell7":
            case "WindowsPowerShell":
            {
                var ps1 = WriteTempPowerShellRunner(toolKey, targetDir, windowTitle, config, entry);
                StartProcess(terminalExe, $"-NoLogo -NoExit -ExecutionPolicy Bypass -File \"{ps1}\"", targetDir, runAsAdmin);
                break;
            }

            case "WezTerm":
            {
                var cmdScript = WriteTempCmdRunner(toolKey, targetDir, windowTitle, config, entry);
                StartProcess(terminalExe, $"start --cwd \"{targetDir}\" -- cmd.exe /d /k \"{cmdScript}\"", targetDir, runAsAdmin);
                break;
            }

            case "Alacritty":
            {
                var cmdScript = WriteTempCmdRunner(toolKey, targetDir, windowTitle, config, entry);
                StartProcess(terminalExe, $"--working-directory \"{targetDir}\" -e cmd.exe /d /k \"{cmdScript}\"", targetDir, runAsAdmin);
                break;
            }

            case "GitBash":
            {
                var shScript = WriteTempBashRunner(toolKey, targetDir, windowTitle, config, entry);
                var shPosix = shScript.Replace('\\', '/');
                StartProcess(terminalExe, $"--cd=\"{targetDir}\" -c \"bash '{shPosix}'\"", targetDir, runAsAdmin);
                break;
            }

            case "Warp":
            {
                var cmdScript = WriteTempCmdRunner(toolKey, targetDir, windowTitle, config, entry);
                var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
                var warpDir = Path.Combine(appData, "warp", "Warp", "data", "launch_configurations");
                Directory.CreateDirectory(warpDir);
                var yamlPath = Path.Combine(warpDir, "vibecode-launch.yaml");
                var jsonDir = System.Text.Json.JsonSerializer.Serialize(targetDir);
                var jsonExec = System.Text.Json.JsonSerializer.Serialize($"cmd.exe /d /k \"{cmdScript}\"");
                var yaml = $"---\nname: VibeCode Launch\nwindows:\n  - tabs:\n      - layout:\n          cwd: {jsonDir}\n          commands:\n            - exec: {jsonExec}\n";
                File.WriteAllText(yamlPath, yaml, new UTF8Encoding(false));
                StartProcess("warp://launch/vibecode-launch.yaml", string.Empty, targetDir, runAsAdmin: false);
                break;
            }

            case "Tabby":
            {
                var cmdScript = WriteTempCmdRunner(toolKey, targetDir, windowTitle, config, entry);
                StartProcess(terminalExe, $"run cmd.exe /d /k \"{cmdScript}\"", targetDir, runAsAdmin);
                break;
            }

            case "Hyper":
            {
                // Hyper 对外部传命令参数支持有限，通过新 CMD 窗口兜底确保目标 AI CLI 可靠启动
                var cmdScript = WriteTempCmdRunner(toolKey, targetDir, windowTitle, config, entry);
                StartProcess("cmd.exe", $"/d /k \"{cmdScript}\"", targetDir, runAsAdmin);
                break;
            }

            case "Cmd":
            default:
            {
                var cmdScript = WriteTempCmdRunner(toolKey, targetDir, windowTitle, config, entry);
                StartProcess("cmd.exe", $"/d /k \"{cmdScript}\"", targetDir, runAsAdmin);
                break;
            }
        }
    }

    private static void StartProcess(string fileName, string arguments, string workingDir, bool runAsAdmin = false)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            WorkingDirectory = workingDir,
            UseShellExecute = true
        };
        if (runAsAdmin)
        {
            psi.Verb = "runas";
        }
        Process.Start(psi);
    }

    private static string GetRunnersDirectory()
    {
        var dir = Path.Combine(Path.GetTempPath(), "vibecode-runners");
        Directory.CreateDirectory(dir);
        // 自动清理 10 分钟前的旧临时启动脚本，避免堆积，同时规避 CMD 批处理自删报错
        try
        {
            var cutoff = DateTime.UtcNow.AddMinutes(-10);
            foreach (var file in Directory.EnumerateFiles(dir, "vibecode-*"))
            {
                if (File.GetLastWriteTimeUtc(file) < cutoff)
                {
                    File.Delete(file);
                }
            }
        }
        catch
        {
            // 忽略清理异常
        }
        return dir;
    }

    private static (Dictionary<string, string> SetVars, List<string> UnsetVars) BuildEnvironmentDelta(
        ToolsConfig config,
        ResolvedLaunch entry)
    {
        // 使用 Ordinal 以便同时保留大写与小写代理变量（Git Bash 环境变量区分大小写）
        var setVars = new Dictionary<string, string>(StringComparer.Ordinal);
        var unsetVars = new List<string>();

        // 1. 刷新用户与系统级 API Key 与 NVM 路径（兼容无需重启 Explorer）
        foreach (var name in new[] { "OPENAI_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "NVM_HOME", "NVM_SYMLINK" })
        {
            var val = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User);
            if (string.IsNullOrWhiteSpace(val))
            {
                val = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Machine);
            }
            if (!string.IsNullOrWhiteSpace(val))
            {
                setVars[name] = val;
            }
        }

        // 2. 代理控制（同时设置/清除大小写变量；支持 system 实时跟随与 manual 固定地址）
        var proxyNames = new[] { "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy" };
        if (!entry.UseProxy)
        {
            unsetVars.AddRange(proxyNames);
        }
        else if (config.Proxy is { Enabled: true } proxy)
        {
            var isSystemMode = string.Equals(proxy.Mode, "system", StringComparison.OrdinalIgnoreCase);
            var url = isSystemMode
                ? ProxyService.DetectWindowsSystemProxy()
                : proxy.Url?.Trim();

            if (!string.IsNullOrWhiteSpace(url))
            {
                var noProxy = string.IsNullOrWhiteSpace(proxy.NoProxy) ? AppMetadata.DefaultNoProxy : proxy.NoProxy.Trim();
                setVars["HTTP_PROXY"] = url;
                setVars["HTTPS_PROXY"] = url;
                setVars["http_proxy"] = url;
                setVars["https_proxy"] = url;
                setVars["NO_PROXY"] = noProxy;
                setVars["no_proxy"] = noProxy;
                if (url.StartsWith("socks", StringComparison.OrdinalIgnoreCase))
                {
                    setVars["ALL_PROXY"] = url;
                    setVars["all_proxy"] = url;
                }
            }
            else if (isSystemMode)
            {
                // 跟随系统模式且系统代理当前未开启：清除残留代理变量，确保直连
                unsetVars.AddRange(proxyNames);
            }
        }

        // 3. globalEnv
        if (config.GlobalEnv is not null)
        {
            foreach (var kv in config.GlobalEnv)
            {
                if (!string.IsNullOrWhiteSpace(kv.Key)) setVars[kv.Key] = kv.Value;
            }
        }

        // 4. super.env（覆盖同名 globalEnv）
        if (entry.ExtraEnv is not null)
        {
            foreach (var kv in entry.ExtraEnv)
            {
                if (!string.IsNullOrWhiteSpace(kv.Key)) setVars[kv.Key] = kv.Value;
            }
        }

        return (setVars, unsetVars);
    }

    private static string PsEscape(string value) => value.Replace("'", "''");

    private static string WriteTempPowerShellRunner(
        string toolKey,
        string targetDir,
        string title,
        ToolsConfig config,
        ResolvedLaunch entry)
    {
        var (setVars, unsetVars) = BuildEnvironmentDelta(config, entry);
        var fullPath = string.Join(";", ToolDetector.BuildSearchPaths());
        var sb = new StringBuilder();

        sb.AppendLine("$ErrorActionPreference = 'Continue'");
        sb.AppendLine("try { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue } catch {}");
        sb.AppendLine($"$Host.UI.RawUI.WindowTitle = '{PsEscape(title)}'");
        sb.AppendLine($"Set-Location -LiteralPath '{PsEscape(targetDir)}'");
        sb.AppendLine($"$env:Path = '{PsEscape(fullPath)}'");

        foreach (var name in unsetVars)
        {
            sb.AppendLine($"Remove-Item -Path 'env:{PsEscape(name)}' -ErrorAction SilentlyContinue");
        }
        foreach (var kv in setVars)
        {
            sb.AppendLine($"Set-Item -Path 'env:{PsEscape(kv.Key)}' -Value '{PsEscape(kv.Value)}'");
        }

        sb.AppendLine($"Write-Host '[VibeCode] {PsEscape(toolKey)} -> {PsEscape(targetDir)}' -ForegroundColor Cyan");
        sb.AppendLine($"Invoke-Expression '{PsEscape(entry.Command)}'");

        var path = Path.Combine(GetRunnersDirectory(), $"vibecode-{Guid.NewGuid():N}.ps1");
        // PowerShell 5.1 必须带 UTF-8 BOM 才能正确解析中文路径
        File.WriteAllText(path, sb.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
        return path;
    }

    private static string CmdEscape(string value) => value.Replace("%", "%%");

    private static string CmdEscapeMeta(string value) => value
        .Replace("^", "^^")
        .Replace("%", "%%")
        .Replace("&", "^&")
        .Replace("|", "^|")
        .Replace("<", "^<")
        .Replace(">", "^>");

    private static string FormatCmdSetLine(string key, string value)
    {
        // 值内含双引号（例如 OPENCODE_PERMISSION="allow"）时不能再用外层引号包裹，否则 CMD 会截断解析
        if (value.Contains('"'))
        {
            return $"set {key}={CmdEscapeMeta(value)}";
        }
        return $"set \"{key}={CmdEscape(value)}\"";
    }

    private static string WriteTempCmdRunner(
        string toolKey,
        string targetDir,
        string title,
        ToolsConfig config,
        ResolvedLaunch entry)
    {
        var (setVars, unsetVars) = BuildEnvironmentDelta(config, entry);
        var fullPath = string.Join(";", ToolDetector.BuildSearchPaths());
        var sb = new StringBuilder();

        sb.AppendLine("@echo off");
        sb.AppendLine("chcp 65001 >nul");
        sb.AppendLine($"title {CmdEscapeMeta(title)}");
        sb.AppendLine($"cd /d \"{CmdEscape(targetDir)}\"");
        sb.AppendLine($"set \"PATH={CmdEscape(fullPath)}\"");

        foreach (var name in unsetVars)
        {
            sb.AppendLine($"set \"{name}=\"");
        }
        foreach (var kv in setVars)
        {
            sb.AppendLine(FormatCmdSetLine(kv.Key, kv.Value));
        }

        sb.AppendLine($"echo [VibeCode] {CmdEscapeMeta(toolKey)} -^> {CmdEscapeMeta(targetDir)}");
        sb.AppendLine($"call {entry.Command}");

        var path = Path.Combine(GetRunnersDirectory(), $"vibecode-{Guid.NewGuid():N}.cmd");
        File.WriteAllText(path, sb.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        return path;
    }

    private static string ShQuote(string value) => "'" + value.Replace("'", "'\\''") + "'";

    private static string WriteTempBashRunner(
        string toolKey,
        string targetDir,
        string title,
        ToolsConfig config,
        ResolvedLaunch entry)
    {
        var (setVars, unsetVars) = BuildEnvironmentDelta(config, entry);
        var sb = new StringBuilder();

        sb.AppendLine("#!/usr/bin/env bash");
        sb.AppendLine("rm -f \"$0\"");
        sb.AppendLine($"printf '\\033]0;%s\\007' {ShQuote(title)}");
        sb.AppendLine($"cd -- {ShQuote(targetDir.Replace('\\', '/'))} || exit 1");

        if (unsetVars.Count > 0)
        {
            sb.AppendLine("unset " + string.Join(" ", unsetVars));
        }
        foreach (var kv in setVars)
        {
            sb.AppendLine($"export {kv.Key}={ShQuote(kv.Value)}");
        }

        sb.AppendLine($"printf '\\033[36m[VibeCode] %s\\033[0m -> %s\\n' {ShQuote(toolKey)} {ShQuote(targetDir)}");
        sb.AppendLine($"eval {ShQuote(entry.Command)}");
        sb.AppendLine("exec bash -l");

        var path = Path.Combine(GetRunnersDirectory(), $"vibecode-{Guid.NewGuid():N}.sh");
        File.WriteAllText(path, sb.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        return path;
    }
}

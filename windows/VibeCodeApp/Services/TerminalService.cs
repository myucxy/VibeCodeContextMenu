using Microsoft.Win32;

namespace VibeCodeApp.Services;

public sealed record SupportedTerminal(
    string Id,
    string DisplayName,
    string ShortName);

public sealed record DetectedTerminal(
    SupportedTerminal Spec,
    string ExecutablePath);

/// <summary>
/// Windows 10 款主流终端全盘自动检测服务（下拉列表只展示本机已检测到的终端）。
/// </summary>
public static class TerminalService
{
    public static readonly IReadOnlyList<SupportedTerminal> AllSupported = new List<SupportedTerminal>
    {
        new("WindowsTerminal", "Windows Terminal", "Windows Terminal"),
        new("PowerShell7", "PowerShell 7", "PowerShell 7"),
        new("WindowsPowerShell", "Windows PowerShell (系统自带)", "PowerShell 5.1"),
        new("Cmd", "命令提示符 (CMD)", "CMD"),
        new("WezTerm", "WezTerm", "WezTerm"),
        new("Alacritty", "Alacritty", "Alacritty"),
        new("Warp", "Warp", "Warp"),
        new("Tabby", "Tabby", "Tabby"),
        new("Hyper", "Hyper", "Hyper"),
        new("GitBash", "Git Bash", "Git Bash"),
    };

    public static List<DetectedTerminal> DetectInstalledTerminals()
    {
        var searchPaths = ToolDetector.BuildSearchPaths();
        var results = new List<DetectedTerminal>();

        foreach (var spec in AllSupported)
        {
            var exePath = FindTerminalExecutable(spec.Id, searchPaths);
            if (!string.IsNullOrWhiteSpace(exePath))
            {
                results.Add(new DetectedTerminal(spec, exePath));
            }
        }

        return results;
    }

    public static string? FindTerminalExecutable(string terminalId, IReadOnlyList<string>? searchPaths = null)
    {
        searchPaths ??= ToolDetector.BuildSearchPaths();
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var systemDir = Environment.GetFolderPath(Environment.SpecialFolder.System);

        return terminalId switch
        {
            "WindowsTerminal" => FirstExisting(
                Path.Combine(localAppData, "Microsoft", "WindowsApps", "wt.exe"),
                Path.Combine(AppPaths.RuntimeRoot, "WindowsTerminal", "wt.exe"),
                FindViaAppPaths("wt.exe"),
                ToolDetector.ResolveCommandPath("wt.exe", searchPaths)),

            "PowerShell7" => FindPowerShell7(programFiles, localAppData, searchPaths),

            "WindowsPowerShell" => FirstExisting(
                Path.Combine(systemDir, "WindowsPowerShell", "v1.0", "powershell.exe"),
                ToolDetector.ResolveCommandPath("powershell.exe", searchPaths)),

            "Cmd" => FirstExisting(
                Path.Combine(systemDir, "cmd.exe"),
                ToolDetector.ResolveCommandPath("cmd.exe", searchPaths)),

            "WezTerm" => FirstExisting(
                Path.Combine(programFiles, "WezTerm", "wezterm-gui.exe"),
                Path.Combine(localAppData, "Programs", "WezTerm", "wezterm-gui.exe"),
                FindViaAppPaths("wezterm-gui.exe"),
                ToolDetector.ResolveCommandPath("wezterm-gui.exe", searchPaths),
                ToolDetector.ResolveCommandPath("wezterm.exe", searchPaths)),

            "Alacritty" => FirstExisting(
                Path.Combine(programFiles, "Alacritty", "alacritty.exe"),
                Path.Combine(localAppData, "Programs", "Alacritty", "alacritty.exe"),
                FindViaAppPaths("alacritty.exe"),
                ToolDetector.ResolveCommandPath("alacritty.exe", searchPaths)),

            "Warp" => FirstExisting(
                Path.Combine(localAppData, "Programs", "Warp", "warp.exe"),
                Path.Combine(programFiles, "Warp", "warp.exe"),
                FindViaAppPaths("warp.exe"),
                ToolDetector.ResolveCommandPath("warp.exe", searchPaths)),

            "Tabby" => FirstExisting(
                Path.Combine(localAppData, "Programs", "Tabby", "Tabby.exe"),
                Path.Combine(programFiles, "Tabby", "Tabby.exe"),
                FindViaAppPaths("Tabby.exe"),
                ToolDetector.ResolveCommandPath("Tabby.exe", searchPaths)),

            "Hyper" => FirstExisting(
                Path.Combine(localAppData, "Programs", "Hyper", "Hyper.exe"),
                Path.Combine(localAppData, "hyper", "Hyper.exe"),
                FindViaAppPaths("Hyper.exe")),

            "GitBash" => FirstExisting(
                Path.Combine(programFiles, "Git", "git-bash.exe"),
                Path.Combine(programFilesX86, "Git", "git-bash.exe"),
                Path.Combine(localAppData, "Programs", "Git", "git-bash.exe"),
                FindViaAppPaths("git-bash.exe")),

            _ => null
        };
    }

    private static string? FindPowerShell7(string programFiles, string localAppData, IReadOnlyList<string> searchPaths)
    {
        var candidates = new List<string?>
        {
            Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe"),
            Path.Combine(AppPaths.RuntimeRoot, "PowerShell", "pwsh.exe")
        };

        // 读取 PowerShellCore 注册表安装记录
        foreach (var root in new[] { Registry.LocalMachine, Registry.CurrentUser })
        {
            try
            {
                using var key = root.OpenSubKey(@"SOFTWARE\Microsoft\PowerShellCore\InstalledVersions");
                if (key is null) continue;
                foreach (var subName in key.GetSubKeyNames())
                {
                    using var sub = key.OpenSubKey(subName);
                    var loc = sub?.GetValue("InstallLocation") as string;
                    if (!string.IsNullOrWhiteSpace(loc))
                    {
                        candidates.Add(Path.Combine(loc, "pwsh.exe"));
                    }
                }
            }
            catch
            {
                // 忽略注册表访问异常
            }
        }

        candidates.Add(Path.Combine(localAppData, "Microsoft", "WindowsApps", "pwsh.exe"));
        candidates.Add(ToolDetector.ResolveCommandPath("pwsh.exe", searchPaths));

        return FirstExisting(candidates.ToArray());
    }

    private static string? FindViaAppPaths(string exeName)
    {
        foreach (var root in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            try
            {
                using var key = root.OpenSubKey($@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\{exeName}");
                var val = key?.GetValue(null) as string;
                if (!string.IsNullOrWhiteSpace(val))
                {
                    var cleaned = Environment.ExpandEnvironmentVariables(val.Trim().Trim('"'));
                    if (File.Exists(cleaned)) return cleaned;
                }
            }
            catch
            {
                // 忽略
            }
        }
        return null;
    }

    private static string? FirstExisting(params string?[] candidates)
    {
        foreach (var c in candidates)
        {
            if (string.IsNullOrWhiteSpace(c)) continue;
            try
            {
                var expanded = Environment.ExpandEnvironmentVariables(c.Trim().Trim('"'));
                if (File.Exists(expanded)) return expanded;
            }
            catch
            {
                // 忽略非法路径
            }
        }
        return null;
    }
}

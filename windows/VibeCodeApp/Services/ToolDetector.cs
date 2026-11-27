namespace VibeCodeApp.Services;

public static class ToolDetector
{
    private static readonly string[] WindowsExecExtensions = [".exe", ".cmd", ".bat", ".com", ".ps1"];

    public static string ExtractPrimaryCommand(string fullCommand)
    {
        if (string.IsNullOrWhiteSpace(fullCommand)) return string.Empty;
        var trimmed = fullCommand.Trim();
        if (trimmed.StartsWith('"'))
        {
            var closing = trimmed.IndexOf('"', 1);
            if (closing > 1) return trimmed[1..closing];
        }
        var space = trimmed.IndexOfAny([' ', '\t']);
        return space > 0 ? trimmed[..space] : trimmed;
    }

    public static List<string> BuildSearchPaths()
    {
        var dirs = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void AddDir(string? path)
        {
            if (string.IsNullOrWhiteSpace(path)) return;
            var expanded = Environment.ExpandEnvironmentVariables(path.Trim().Trim('"')).TrimEnd('\\');
            if (!string.IsNullOrWhiteSpace(expanded) && seen.Add(expanded))
            {
                dirs.Add(expanded);
            }
        }

        // VibeCodeRuntime 与常见用户工具目录优先
        AddDir(Path.Combine(AppPaths.RuntimeRoot, "NodeCurrent"));
        AddDir(Path.Combine(AppPaths.RuntimeRoot, "Nvm"));

        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        AddDir(Path.Combine(userProfile, ".local", "bin"));
        AddDir(Path.Combine(userProfile, ".opencode", "bin"));
        AddDir(Path.Combine(userProfile, ".cargo", "bin"));
        AddDir(Path.Combine(userProfile, ".volta", "bin"));
        AddDir(Path.Combine(userProfile, ".bun", "bin"));
        AddDir(Path.Combine(userProfile, "scoop", "shims"));
        AddDir(Path.Combine(localAppData, "pnpm"));
        AddDir(Path.Combine(localAppData, "agy", "bin"));
        AddDir(Path.Combine(appData, "npm"));
        AddDir(Path.Combine(localAppData, "Microsoft", "WindowsApps"));

        // 从注册表读取最新 Machine / User PATH（无需重启资源管理器或应用）
        foreach (var target in new[] { EnvironmentVariableTarget.User, EnvironmentVariableTarget.Machine, EnvironmentVariableTarget.Process })
        {
            var rawPath = Environment.GetEnvironmentVariable("PATH", target);
            if (!string.IsNullOrWhiteSpace(rawPath))
            {
                foreach (var entry in rawPath.Split(';', StringSplitOptions.RemoveEmptyEntries))
                {
                    AddDir(entry);
                }
            }
        }

        foreach (var envVar in new[] { "NVM_SYMLINK", "NVM_HOME" })
        {
            var userVal = Environment.GetEnvironmentVariable(envVar, EnvironmentVariableTarget.User);
            var machineVal = Environment.GetEnvironmentVariable(envVar, EnvironmentVariableTarget.Machine);
            AddDir(userVal);
            AddDir(machineVal);

            // 若 NVM 符号链接因权限或未激活无法直接解析，自动兜底扫描 NVM_HOME 下的版本目录
            if (envVar == "NVM_HOME")
            {
                foreach (var nvmDir in new[] { userVal, machineVal })
                {
                    if (!string.IsNullOrWhiteSpace(nvmDir) && Directory.Exists(nvmDir))
                    {
                        try
                        {
                            foreach (var verDir in Directory.GetDirectories(nvmDir, "v*").OrderByDescending(d => d, StringComparer.OrdinalIgnoreCase))
                            {
                                AddDir(verDir);
                            }
                        }
                        catch
                        {
                            // 忽略目录枚举异常
                        }
                    }
                }
            }
        }

        AddDir(Path.Combine(AppPaths.RuntimeRoot, "AiCli", "node_modules", ".bin"));
        return dirs;
    }

    public static string? ResolveCommandPath(string command, IReadOnlyList<string>? cachedSearchPaths = null)
    {
        if (string.IsNullOrWhiteSpace(command)) return null;
        var primary = ExtractPrimaryCommand(command);
        if (string.IsNullOrWhiteSpace(primary)) return null;

        // 绝对或相对路径直接检查
        if (primary.Contains('\\') || primary.Contains('/'))
        {
            var expanded = Environment.ExpandEnvironmentVariables(primary);
            if (File.Exists(expanded)) return expanded;
            foreach (var ext in WindowsExecExtensions)
            {
                if (File.Exists(expanded + ext)) return expanded + ext;
            }
            return null;
        }

        var hasExt = Path.HasExtension(primary);
        var searchPaths = cachedSearchPaths ?? BuildSearchPaths();

        foreach (var dir in searchPaths)
        {
            if (!Directory.Exists(dir)) continue;

            if (hasExt)
            {
                var candidate = Path.Combine(dir, primary);
                if (File.Exists(candidate)) return candidate;
            }
            else
            {
                foreach (var ext in WindowsExecExtensions)
                {
                    var candidate = Path.Combine(dir, primary + ext);
                    if (File.Exists(candidate)) return candidate;
                }
            }
        }

        return null;
    }

    public static bool IsCommandInstalled(string command, IReadOnlyList<string>? cachedSearchPaths = null) =>
        ResolveCommandPath(command, cachedSearchPaths) is not null;
}

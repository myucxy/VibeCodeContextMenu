using Microsoft.Win32;
using VibeCodeApp.Models;

namespace VibeCodeApp.Services;

/// <summary>
/// Windows HKCU 用户级右键级联菜单注册服务（免管理员权限）。
/// 支持：右键总开关、平铺/折叠二级子菜单（auto/flat/grouped）、普通/Super/恢复筛选、自定义顺序与原生分割线。
/// </summary>
public static class RegistryMenuService
{
    private static readonly (string RootPath, string PathToken)[] RegistryRoots =
    [
        (@"Software\Classes\Directory\shell", "%1"),
        (@"Software\Classes\Directory\Background\shell", "%V")
    ];

    private sealed record ModeSpec(string FlatLabel, string GroupedLabel, string ToolKey);
    private sealed record ToolGroupSpec(string Name, string? IconName, List<ModeSpec> Modes);

    public static bool IsMenuRegistered(string menuName = AppMetadata.DefaultMenuName)
    {
        var safeName = SanitizeMenuName(menuName);
        foreach (var (rootPath, _) in RegistryRoots)
        {
            using var key = Registry.CurrentUser.OpenSubKey($@"{rootPath}\{safeName}");
            if (key is not null) return true;
        }
        return false;
    }

    public static void RemoveContextMenu(string menuName = AppMetadata.DefaultMenuName)
    {
        var safeName = SanitizeMenuName(menuName);
        foreach (var (rootPath, _) in RegistryRoots)
        {
            try
            {
                using var root = Registry.CurrentUser.OpenSubKey(rootPath, writable: true);
                root?.DeleteSubKeyTree(safeName, throwOnMissingSubKey: false);
            }
            catch
            {
                // 忽略不存在或权限问题
            }
        }
    }

    public static void SyncContextMenu(ToolsConfig toolsConfig, WindowsAppConfig winConfig)
    {
        var menuName = SanitizeMenuName(toolsConfig.MenuName);
        var menuLabel = string.IsNullOrWhiteSpace(toolsConfig.MenuLabel) ? AppMetadata.DefaultMenuName : toolsConfig.MenuLabel;

        // 先彻底移除旧键，确保顺序、折叠状态或关闭状态立即干净生效
        RemoveContextMenu(menuName);

        if (!winConfig.ContextMenuEnabled)
        {
            return;
        }

        var groups = BuildToolGroups(toolsConfig, winConfig);
        if (groups.Count == 0)
        {
            return;
        }

        var layout = (winConfig.MenuLayout ?? "auto").ToLowerInvariant();
        var totalEntries = groups.Sum(g => g.Modes.Count);
        var useGrouped = layout switch
        {
            "grouped" => true,
            "flat" => false,
            _ => groups.Count > 5 || totalEntries > 15
        };

        var mainIconPath = IconService.EnsureMainIconPath();
        var exePath = AppPaths.ExecutablePath;

        foreach (var (rootPath, token) in RegistryRoots)
        {
            using var menuKey = Registry.CurrentUser.CreateSubKey($@"{rootPath}\{menuName}", writable: true);
            if (menuKey is null) continue;

            menuKey.SetValue("MUIVerb", menuLabel, RegistryValueKind.String);
            menuKey.SetValue("SubCommands", string.Empty, RegistryValueKind.String);
            menuKey.SetValue("Icon", mainIconPath, RegistryValueKind.String);

            using var shellKey = menuKey.CreateSubKey("shell", writable: true);
            if (shellKey is null) continue;

            if (useGrouped)
            {
                var width = Math.Max(2, groups.Count.ToString().Length);
                var idx = 0;
                foreach (var group in groups)
                {
                    idx++;
                    var iconPath = IconService.EnsureToolIconPath(group.Name, group.IconName);
                    var keyPrefix = idx.ToString($"D{width}");

                    if (group.Modes.Count == 1)
                    {
                        var only = group.Modes[0];
                        WriteCommandLeaf(
                            shellKey,
                            $"{keyPrefix}_{SanitizeKeySegment(only.FlatLabel)}",
                            only.FlatLabel,
                            iconPath,
                            BuildLaunchCommand(exePath, only.ToolKey, token));
                    }
                    else
                    {
                        using var groupKey = shellKey.CreateSubKey(
                            $"{keyPrefix}_{SanitizeKeySegment(group.Name)}",
                            writable: true);
                        if (groupKey is null) continue;

                        groupKey.SetValue("MUIVerb", group.Name, RegistryValueKind.String);
                        groupKey.SetValue("SubCommands", string.Empty, RegistryValueKind.String);
                        groupKey.SetValue("Icon", iconPath, RegistryValueKind.String);

                        using var subShell = groupKey.CreateSubKey("shell", writable: true);
                        if (subShell is null) continue;

                        var mIdx = 0;
                        foreach (var mode in group.Modes)
                        {
                            mIdx++;
                            WriteCommandLeaf(
                                subShell,
                                $"{mIdx:D2}_{SanitizeKeySegment(mode.ToolKey)}",
                                mode.GroupedLabel,
                                iconPath,
                                BuildLaunchCommand(exePath, mode.ToolKey, token));
                        }
                    }
                }
            }
            else
            {
                var width = Math.Max(2, totalEntries.ToString().Length);
                var idx = 0;
                foreach (var group in groups)
                {
                    var iconPath = IconService.EnsureToolIconPath(group.Name, group.IconName);
                    foreach (var mode in group.Modes)
                    {
                        idx++;
                        var keyName = $"{idx.ToString($"D{width}")}_{SanitizeKeySegment(mode.FlatLabel)}";
                        WriteCommandLeaf(
                            shellKey,
                            keyName,
                            mode.FlatLabel,
                            iconPath,
                            BuildLaunchCommand(exePath, mode.ToolKey, token));
                    }
                }
            }

            // 菜单末尾添加原生分割线 + "管理 VibeCode..." 入口
            using var manageKey = shellKey.CreateSubKey("zz_manage", writable: true);
            if (manageKey is not null)
            {
                manageKey.SetValue("MUIVerb", "管理 VibeCode...", RegistryValueKind.String);
                manageKey.SetValue("Icon", mainIconPath, RegistryValueKind.String);
                // ECF_SEPARATORBEFORE (0x20): 在该菜单项上方显示分割线
                manageKey.SetValue("CommandFlags", 0x20, RegistryValueKind.DWord);
                using var cmdKey = manageKey.CreateSubKey("command", writable: true);
                cmdKey?.SetValue(null, $"\"{exePath}\" --manage", RegistryValueKind.String);
            }
        }
    }

    private static List<ToolGroupSpec> BuildToolGroups(ToolsConfig toolsConfig, WindowsAppConfig winConfig)
    {
        var searchPaths = ToolDetector.BuildSearchPaths();
        var byName = toolsConfig.Tools
            .Where(t => !string.IsNullOrWhiteSpace(t.Name))
            .GroupBy(t => t.Name, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);

        var orderedTools = new List<ToolEntry>();
        if (winConfig.EnabledTools is not null)
        {
            foreach (var name in winConfig.EnabledTools)
            {
                if (byName.TryGetValue(name, out var tool))
                {
                    // 二次保护：只把本机已安装的 CLI 注册进右键菜单
                    var bin = ToolDetector.ExtractPrimaryCommand(tool.Command);
                    if (ToolDetector.IsCommandInstalled(bin, searchPaths))
                    {
                        orderedTools.Add(tool);
                    }
                }
            }
        }
        else
        {
            foreach (var tool in toolsConfig.Tools)
            {
                var bin = ToolDetector.ExtractPrimaryCommand(tool.Command);
                if (ToolDetector.IsCommandInstalled(bin, searchPaths))
                {
                    orderedTools.Add(tool);
                }
            }
        }

        var result = new List<ToolGroupSpec>();
        foreach (var tool in orderedTools)
        {
            var modes = new List<ModeSpec>();
            if (winConfig.ShowNormalMode)
            {
                modes.Add(new ModeSpec(tool.Name, $"普通模式 ({tool.Name})", tool.Name));
            }
            if (tool.Super is not null && !string.IsNullOrWhiteSpace(tool.Super.Label) && !string.IsNullOrWhiteSpace(tool.Super.Command))
            {
                if (winConfig.ShowSuperMode)
                {
                    modes.Add(new ModeSpec(tool.Super.Label, $"Super 模式 ({tool.Super.Label})", tool.Super.Label));
                }
                if (winConfig.ShowResumeMode)
                {
                    var resumeKey = $"{tool.Super.Label}-R";
                    modes.Add(new ModeSpec(resumeKey, $"恢复会话 ({resumeKey})", resumeKey));
                }
            }
            else if (modes.Count == 0)
            {
                modes.Add(new ModeSpec(tool.Name, tool.Name, tool.Name));
            }

            if (modes.Count > 0)
            {
                result.Add(new ToolGroupSpec(tool.Name, tool.Icon, modes));
            }
        }
        return result;
    }

    private static void WriteCommandLeaf(
        RegistryKey parentShellKey,
        string subKeyName,
        string label,
        string iconPath,
        string commandLine)
    {
        using var itemKey = parentShellKey.CreateSubKey(subKeyName, writable: true);
        if (itemKey is null) return;
        itemKey.SetValue("MUIVerb", label, RegistryValueKind.String);
        itemKey.SetValue("Icon", iconPath, RegistryValueKind.String);
        using var cmdKey = itemKey.CreateSubKey("command", writable: true);
        cmdKey?.SetValue(null, commandLine, RegistryValueKind.String);
    }

    private static string BuildLaunchCommand(string exePath, string toolKey, string pathToken)
    {
        var safeTool = toolKey.Replace("\"", "\\\"");
        return $"\"{exePath}\" --launch \"{safeTool}\" \"{pathToken}\"";
    }

    private static string SanitizeMenuName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return AppMetadata.DefaultMenuName;
        var invalid = Path.GetInvalidFileNameChars();
        var cleaned = new string(name.Trim().Where(c => !invalid.Contains(c) && c != '\\' && c != '/').ToArray());
        if (string.IsNullOrWhiteSpace(cleaned) || cleaned is "." or "..") return AppMetadata.DefaultMenuName;
        return cleaned.Length > 80 ? cleaned[..80] : cleaned;
    }

    private static string SanitizeKeySegment(string label)
    {
        var chars = label.Select(c => (c == '\\' || c == '/' || char.IsControl(c)) ? '_' : c).ToArray();
        var s = new string(chars).Trim();
        return string.IsNullOrWhiteSpace(s) ? "item" : s;
    }
}

using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using VibeCodeApp.Models;

namespace VibeCodeApp.Services;

public static class ConfigService
{
    private static readonly UTF8Encoding Utf8NoBom = new(false);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    public static ToolsConfig LoadToolsConfig()
    {
        try
        {
            if (File.Exists(AppPaths.ToolsConfigPath))
            {
                var raw = File.ReadAllText(AppPaths.ToolsConfigPath, Encoding.UTF8);
                var parsed = JsonSerializer.Deserialize<ToolsConfig>(raw, JsonOptions);
                if (parsed is not null)
                {
                    parsed.MenuName = string.IsNullOrWhiteSpace(parsed.MenuName) ? AppMetadata.DefaultMenuName : parsed.MenuName;
                    parsed.MenuLabel = string.IsNullOrWhiteSpace(parsed.MenuLabel) ? AppMetadata.DefaultMenuName : parsed.MenuLabel;
                    parsed.Tools ??= new List<ToolEntry>();
                    return parsed;
                }
            }
        }
        catch
        {
            // 回退默认配置
        }

        return new ToolsConfig
        {
            MenuName = AppMetadata.DefaultMenuName,
            MenuLabel = AppMetadata.DefaultMenuName,
            GlobalEnv = new Dictionary<string, string>(),
            Tools = BuiltinPresets.All.Take(5).Select(p => p.ToToolEntry()).ToList()
        };
    }

    public static void SaveToolsConfig(ToolsConfig config)
    {
        Directory.CreateDirectory(AppPaths.SupportDir);
        var json = JsonSerializer.Serialize(config, JsonOptions) + Environment.NewLine;

        File.WriteAllText(AppPaths.ToolsConfigPath, json, Utf8NoBom);

        // 若记录了源码仓库目录，同步写回项目 tools.json（与 macOS / 原版 VibeCode.ps1 行为一致）
        var winCfg = LoadWindowsConfig();
        if (!string.IsNullOrWhiteSpace(winCfg.ProjectDir))
        {
            var projectTools = Path.Combine(winCfg.ProjectDir, "tools.json");
            if (File.Exists(projectTools))
            {
                try
                {
                    File.WriteAllText(projectTools, json, Utf8NoBom);
                }
                catch
                {
                    // 仓库目录只读时忽略
                }
            }
        }
    }

    public static WindowsAppConfig LoadWindowsConfig()
    {
        try
        {
            if (File.Exists(AppPaths.WindowsConfigPath))
            {
                var raw = File.ReadAllText(AppPaths.WindowsConfigPath, Encoding.UTF8);
                var parsed = JsonSerializer.Deserialize<WindowsAppConfig>(raw, JsonOptions);
                if (parsed is not null)
                {
                    parsed.MenuLayout = string.IsNullOrWhiteSpace(parsed.MenuLayout) ? "auto" : parsed.MenuLayout;
                    parsed.Terminal = string.IsNullOrWhiteSpace(parsed.Terminal) ? "WindowsTerminal" : parsed.Terminal;
                    return parsed;
                }
            }
        }
        catch
        {
            // 回退默认状态
        }

        return new WindowsAppConfig();
    }

    public static void SaveWindowsConfig(WindowsAppConfig config)
    {
        Directory.CreateDirectory(AppPaths.SupportDir);
        var json = JsonSerializer.Serialize(config, JsonOptions) + Environment.NewLine;
        File.WriteAllText(AppPaths.WindowsConfigPath, json, Utf8NoBom);
    }

    /// <summary>
    /// 首次运行时自动检测本机已安装的 AI CLI 与默认终端，初始化 windows.json 并注册右键菜单。
    /// </summary>
    public static void InitializeFirstRunDefaults()
    {
        var toolsCfg = LoadToolsConfig();
        var searchPaths = ToolDetector.BuildSearchPaths();

        var detectedEnabled = new List<string>();
        foreach (var t in toolsCfg.Tools)
        {
            var bin = ToolDetector.ExtractPrimaryCommand(t.Command);
            if (ToolDetector.IsCommandInstalled(bin, searchPaths))
            {
                detectedEnabled.Add(t.Name);
            }
        }

        // 同时检测其余内置主流 AI CLI（如 gemini / qwen / kimi / aider），若已装则自动加入
        var existingNames = new HashSet<string>(toolsCfg.Tools.Select(t => t.Name), StringComparer.OrdinalIgnoreCase);
        var addedExtra = false;
        foreach (var preset in BuiltinPresets.All)
        {
            if (existingNames.Contains(preset.Name)) continue;
            var bin = ToolDetector.ExtractPrimaryCommand(preset.Command);
            if (ToolDetector.IsCommandInstalled(bin, searchPaths))
            {
                toolsCfg.Tools.Add(preset.ToToolEntry());
                detectedEnabled.Add(preset.Name);
                addedExtra = true;
            }
        }

        if (addedExtra)
        {
            SaveToolsConfig(toolsCfg);
        }

        var detectedTerminals = TerminalService.DetectInstalledTerminals();
        var defaultTerminal = detectedTerminals.FirstOrDefault();

        var winCfg = new WindowsAppConfig
        {
            EnabledTools = detectedEnabled,
            ToolOrder = null,
            ContextMenuEnabled = true,
            MenuLayout = "auto",
            ShowNormalMode = true,
            ShowSuperMode = true,
            ShowResumeMode = true,
            Terminal = defaultTerminal?.Spec.Id ?? "Cmd",
            TerminalExePath = defaultTerminal?.ExecutablePath,
            ProjectDir = null
        };

        SaveWindowsConfig(winCfg);
        RegistryMenuService.SyncContextMenu(toolsCfg, winCfg);
    }
}

using System.Text.Json.Serialization;

namespace VibeCodeApp.Models;

public static class AppMetadata
{
    public const string AuthorName = "清风惹尘丶";
    public const string GitHubUrl = "https://github.com/myucxy/VibeCodeContextMenu";
    public const string DefaultNoProxy = "localhost,127.0.0.1,::1";
    public const string DefaultMenuName = "VibeCode";
}

/// <summary>
/// 与项目根目录 tools.json 100% 兼容的配置结构。
/// </summary>
public sealed class ToolsConfig
{
    [JsonPropertyName("menuName")]
    public string MenuName { get; set; } = AppMetadata.DefaultMenuName;

    [JsonPropertyName("menuLabel")]
    public string MenuLabel { get; set; } = AppMetadata.DefaultMenuName;

    [JsonPropertyName("globalEnv")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public Dictionary<string, string>? GlobalEnv { get; set; } = new();

    [JsonPropertyName("proxy")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ProxySettings? Proxy { get; set; }

    [JsonPropertyName("tools")]
    public List<ToolEntry> Tools { get; set; } = new();
}

public sealed class ProxySettings
{
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; }

    /// <summary>
    /// system（实时跟随 Windows 系统代理） | manual（固定代理地址，省略时默认 manual）
    /// </summary>
    [JsonPropertyName("mode")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Mode { get; set; }

    [JsonPropertyName("url")]
    public string Url { get; set; } = string.Empty;

    [JsonPropertyName("noProxy")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? NoProxy { get; set; } = AppMetadata.DefaultNoProxy;
}

public sealed class ToolEntry
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("command")]
    public string Command { get; set; } = string.Empty;

    [JsonPropertyName("icon")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Icon { get; set; }

    [JsonPropertyName("useProxy")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? UseProxy { get; set; }

    [JsonPropertyName("super")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public SuperEntry? Super { get; set; }

    public ToolEntry Clone()
    {
        return new ToolEntry
        {
            Name = Name,
            Command = Command,
            Icon = Icon,
            UseProxy = UseProxy,
            Super = Super?.Clone()
        };
    }
}

public sealed class SuperEntry
{
    [JsonPropertyName("command")]
    public string Command { get; set; } = string.Empty;

    [JsonPropertyName("env")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public Dictionary<string, string>? Env { get; set; }

    [JsonPropertyName("label")]
    public string Label { get; set; } = string.Empty;

    [JsonPropertyName("resume")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ResumeEntry? Resume { get; set; }

    public SuperEntry Clone()
    {
        return new SuperEntry
        {
            Command = Command,
            Label = Label,
            Env = Env is null ? null : new Dictionary<string, string>(Env),
            Resume = Resume is null ? null : new ResumeEntry { Command = Resume.Command }
        };
    }
}

public sealed class ResumeEntry
{
    [JsonPropertyName("command")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Command { get; set; }
}

/// <summary>
/// Windows 端独立状态配置（保存在 %LOCALAPPDATA%\VibeCode\windows.json）。
/// </summary>
public sealed class WindowsAppConfig
{
    [JsonPropertyName("enabledTools")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? EnabledTools { get; set; }

    [JsonPropertyName("toolOrder")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? ToolOrder { get; set; }

    [JsonPropertyName("contextMenuEnabled")]
    public bool ContextMenuEnabled { get; set; } = true;

    /// <summary>
    /// auto（>5 项折叠） | flat（平铺展开） | grouped（按工具折叠二级子菜单）
    /// </summary>
    [JsonPropertyName("menuLayout")]
    public string MenuLayout { get; set; } = "auto";

    [JsonPropertyName("showNormalMode")]
    public bool ShowNormalMode { get; set; } = true;

    [JsonPropertyName("showSuperMode")]
    public bool ShowSuperMode { get; set; } = true;

    [JsonPropertyName("showResumeMode")]
    public bool ShowResumeMode { get; set; } = true;

    [JsonPropertyName("terminal")]
    public string Terminal { get; set; } = "WindowsTerminal";

    [JsonPropertyName("terminalExePath")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? TerminalExePath { get; set; }

    [JsonPropertyName("runTerminalAsAdmin")]
    public bool RunTerminalAsAdmin { get; set; }

    [JsonPropertyName("projectDir")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ProjectDir { get; set; }
}

public sealed class ToolRowModel
{
    public ToolEntry Entry { get; set; } = new();
    public string? DisplaySubtitle { get; set; }
    public bool IsBuiltinPreset { get; set; }
    public bool PersistedInToolsJson { get; set; }
    public bool Installed { get; set; }
    public bool Enabled { get; set; }
}

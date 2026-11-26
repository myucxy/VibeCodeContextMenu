namespace VibeCodeApp.Models;

public sealed record AiCliPreset(
    string DisplayName,
    string Category,
    string Name,
    string Command,
    string? SuperLabel,
    string? SuperCommand,
    Dictionary<string, string>? SuperEnv,
    string? ResumeCommand,
    bool DirectByDefault,
    string Note)
{
    public ToolEntry ToToolEntry()
    {
        SuperEntry? superObj = null;
        if (!string.IsNullOrWhiteSpace(SuperLabel) && !string.IsNullOrWhiteSpace(SuperCommand))
        {
            superObj = new SuperEntry
            {
                Label = SuperLabel,
                Command = SuperCommand,
                Env = SuperEnv is null ? null : new Dictionary<string, string>(SuperEnv),
                Resume = string.IsNullOrWhiteSpace(ResumeCommand)
                    ? null
                    : new ResumeEntry { Command = ResumeCommand }
            };
        }

        return new ToolEntry
        {
            Name = Name,
            Command = Command,
            Icon = null,
            UseProxy = DirectByDefault ? false : null,
            Super = superObj
        };
    }
}

/// <summary>
/// 与 macOS 版 1:1 对齐的 19 款主流 AI CLI 预置模板库（国际 + 国内直连）。
/// </summary>
public static class BuiltinPresets
{
    public static readonly IReadOnlyList<AiCliPreset> All = new List<AiCliPreset>
    {
        new("Claude Code (Anthropic)", "国际", "claude", "claude",
            "claudeSuper", "claude --dangerously-skip-permissions", null,
            "claude --dangerously-skip-permissions -r", false,
            "Anthropic 官方终端编码 Agent"),

        new("Codex CLI (OpenAI)", "国际", "codex", "codex",
            "codexSuper", "codex --dangerously-bypass-approvals-and-sandbox", null,
            "codex --dangerously-bypass-approvals-and-sandbox resume", false,
            "OpenAI 官方终端编码 Agent"),

        new("OpenCode", "国际", "openCode", "opencode",
            "openCodeSuper", "opencode",
            new Dictionary<string, string> { ["OPENCODE_PERMISSION"] = "\"allow\"" },
            "opencode -c", false,
            "开源多模型终端编码 Agent"),

        new("Grok CLI (xAI)", "国际", "grok", "grok",
            "grokSuper", "grok --always-approve", null,
            "grok --always-approve -r", false,
            "xAI Grok 终端编码工具"),

        new("Antigravity CLI (agy)", "国际", "agy", "agy",
            "agySuper", "agy --dangerously-skip-permissions", null,
            "agy --dangerously-skip-permissions -c", false,
            "Google Antigravity 终端 Agent"),

        new("Gemini CLI (Google)", "国际", "gemini", "gemini",
            "geminiSuper", "gemini --yolo", null,
            "gemini --yolo --resume", false,
            "Google 官方 Gemini 开源 CLI"),

        new("Qwen Code (通义千问)", "国内", "qwen", "qwen",
            "qwenSuper", "qwen --yolo", null,
            "qwen --yolo --resume", true,
            "阿里通义千问编码 CLI（默认直连）"),

        new("Kimi CLI (月之暗面)", "国内", "kimi", "kimi",
            "kimiSuper", "kimi --yolo", null,
            "kimi --yolo --continue", true,
            "Moonshot Kimi 终端编码 Agent（默认直连）"),

        new("CodeBuddy CLI (腾讯)", "国内", "codebuddy", "codebuddy",
            "codebuddySuper", "codebuddy --dangerously-skip-permissions", null,
            "codebuddy --dangerously-skip-permissions -c", true,
            "腾讯 CodeBuddy 终端 Agent（默认直连）"),

        new("GitHub Copilot CLI", "国际", "copilot", "copilot",
            "copilotSuper", "copilot --allow-all-tools", null,
            "copilot --allow-all-tools --resume", false,
            "GitHub 官方独立 Copilot Agent CLI"),

        new("Cursor Agent CLI", "国际", "cursor-agent", "cursor-agent",
            "cursorSuper", "cursor-agent -f", null,
            "cursor-agent -f resume", false,
            "Cursor 官方终端 Agent"),

        new("Aider", "国际", "aider", "aider",
            "aiderSuper", "aider --yes-always", null,
            "aider --yes-always --restore-chat-history", false,
            "经典开源 Git 集成 AI 结对编程工具"),

        new("Kiro CLI (AWS)", "国际", "kiro", "kiro-cli chat",
            "kiroSuper", "kiro-cli chat --trust-all-tools", null,
            "kiro-cli chat --trust-all-tools --resume", false,
            "AWS Kiro / Amazon Q 终端编程助手"),

        new("Cline CLI", "国际", "cline", "cline",
            "clineSuper", "cline --yolo", null,
            null, false,
            "Cline 开源终端自治 Agent"),

        new("Amp (Sourcegraph)", "国际", "amp", "amp",
            "ampSuper", "amp --dangerously-allow-all", null,
            "amp threads continue", false,
            "Sourcegraph Amp 终端编程 Agent"),

        new("Goose (Block)", "国际", "goose", "goose session",
            null, null, null, null, false,
            "Block 开源可扩展本地 AI Agent"),

        new("Augment CLI (auggie)", "国际", "auggie", "auggie",
            null, null, null, null, false,
            "Augment Code 终端 Agent"),

        new("Crush (Charm)", "国际", "crush", "crush",
            "crushSuper", "crush --yolo", null,
            null, false,
            "Charm 出品的高颜值终端编码 Agent"),

        new("Mistral Vibe", "国际", "vibe", "vibe",
            "vibeSuper", "vibe --auto-approve", null,
            "vibe --auto-approve --continue", false,
            "Mistral 官方终端编程 Agent"),
    };

    public static AiCliPreset? FindByName(string name) =>
        All.FirstOrDefault(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase));
}

import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - 配置模型与元信息

private let kAuthorName = "清风惹尘丶"
private let kGitHubURLString = "https://github.com/myucxy/VibeCodeContextMenu"
private let kDefaultNoProxy = "localhost,127.0.0.1,::1"

private struct HostToolsConfig: Codable {
    var menuName: String?
    var menuLabel: String?
    var globalEnv: [String: String]?
    var proxy: ProxySettings?
    var tools: [HostToolEntry]
}

private struct ProxySettings: Codable {
    var enabled: Bool
    var mode: String?
    var url: String
    var noProxy: String?
}

private struct GitHubReleaseAsset: Codable {
    var name: String
    var browser_download_url: String
    var size: Int64
}

private struct GitHubReleaseInfo: Codable {
    var tag_name: String
    var name: String?
    var body: String?
    var html_url: String
    var assets: [GitHubReleaseAsset]?
}

private struct UpdateCheckResult {
    var hasUpdate: Bool
    var currentVersion: String
    var latestVersion: String
    var release: GitHubReleaseInfo
    var installerAsset: GitHubReleaseAsset?
    var sha256Asset: GitHubReleaseAsset?
}

private struct HostToolEntry: Codable {
    var name: String
    var command: String
    var icon: String?
    var useProxy: Bool?
    var superConfig: HostSuperEntry?

    enum CodingKeys: String, CodingKey {
        case name
        case command
        case icon
        case useProxy
        case superConfig = "super"
    }
}

private struct HostSuperEntry: Codable {
    var command: String
    var label: String
    var env: [String: String]?
    var resume: HostResumeEntry?
}

private struct HostResumeEntry: Codable {
    var command: String?
}

private struct SupportedTerminal {
    let id: String
    let displayName: String
    let bundleIDs: [String]
    let fallbackAppNames: [String]
}

private struct DetectedTerminal {
    let spec: SupportedTerminal
    let appURL: URL
}

private let kSupportedTerminals: [SupportedTerminal] = [
    SupportedTerminal(
        id: "Terminal",
        displayName: "Terminal (系统自带)",
        bundleIDs: ["com.apple.Terminal"],
        fallbackAppNames: ["Terminal.app"]
    ),
    SupportedTerminal(
        id: "iTerm",
        displayName: "iTerm2",
        bundleIDs: ["com.googlecode.iterm2"],
        fallbackAppNames: ["iTerm.app", "iTerm2.app"]
    ),
    SupportedTerminal(
        id: "Ghostty",
        displayName: "Ghostty",
        bundleIDs: ["com.mitchellh.ghostty"],
        fallbackAppNames: ["Ghostty.app"]
    ),
    SupportedTerminal(
        id: "Warp",
        displayName: "Warp",
        bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"],
        fallbackAppNames: ["Warp.app", "WarpPreview.app"]
    ),
    SupportedTerminal(
        id: "WezTerm",
        displayName: "WezTerm",
        bundleIDs: ["com.github.wez.wezterm"],
        fallbackAppNames: ["WezTerm.app"]
    ),
    SupportedTerminal(
        id: "kitty",
        displayName: "kitty",
        bundleIDs: ["net.kovidgoyal.kitty"],
        fallbackAppNames: ["kitty.app"]
    ),
    SupportedTerminal(
        id: "Alacritty",
        displayName: "Alacritty",
        bundleIDs: ["org.alacritty"],
        fallbackAppNames: ["Alacritty.app"]
    ),
    SupportedTerminal(
        id: "Rio",
        displayName: "Rio",
        bundleIDs: ["com.raphaelamorim.rio"],
        fallbackAppNames: ["Rio.app"]
    ),
    SupportedTerminal(
        id: "Tabby",
        displayName: "Tabby",
        bundleIDs: ["org.tabby"],
        fallbackAppNames: ["Tabby.app"]
    ),
    SupportedTerminal(
        id: "Hyper",
        displayName: "Hyper",
        bundleIDs: ["co.zeit.hyper"],
        fallbackAppNames: ["Hyper.app"]
    ),
]

private struct HostMacOSConfig: Codable {
    var enabledTools: [String]?
    var toolOrder: [String]?
    var contextMenuEnabled: Bool?
    /// "auto" | "flat" | "grouped"
    var menuLayout: String?
    var showNormalMode: Bool?
    var showSuperMode: Bool?
    var showResumeMode: Bool?
    var terminal: String?
    var terminalAppPath: String?
    var showMenuBarIcon: Bool?
    var projectDir: String?
}

// MARK: - 主流 AI CLI 预置模板库（19 款覆盖国际与国内主流终端 Agent）

private struct AiCliPreset {
    let displayName: String
    let category: String
    let name: String
    let command: String
    let superLabel: String?
    let superCommand: String?
    let superEnv: [String: String]?
    let resumeCommand: String?
    let directByDefault: Bool
    let note: String

    func toToolEntry() -> HostToolEntry {
        let superObj: HostSuperEntry?
        if let sLabel = superLabel, let sCmd = superCommand {
            let resumeObj = resumeCommand.map { HostResumeEntry(command: $0) }
            superObj = HostSuperEntry(command: sCmd, label: sLabel, env: superEnv, resume: resumeObj)
        } else {
            superObj = nil
        }
        return HostToolEntry(
            name: name,
            command: command,
            icon: nil,
            useProxy: directByDefault ? false : nil,
            superConfig: superObj
        )
    }
}

private let kBuiltinAiCliPresets: [AiCliPreset] = [
    AiCliPreset(
        displayName: "Claude Code (Anthropic)",
        category: "国际",
        name: "claude",
        command: "claude",
        superLabel: "claudeSuper",
        superCommand: "claude --dangerously-skip-permissions",
        superEnv: nil,
        resumeCommand: "claude --dangerously-skip-permissions -r",
        directByDefault: false,
        note: "Anthropic 官方终端编码 Agent"
    ),
    AiCliPreset(
        displayName: "Codex CLI (OpenAI)",
        category: "国际",
        name: "codex",
        command: "codex",
        superLabel: "codexSuper",
        superCommand: "codex --dangerously-bypass-approvals-and-sandbox",
        superEnv: nil,
        resumeCommand: "codex --dangerously-bypass-approvals-and-sandbox resume",
        directByDefault: false,
        note: "OpenAI 官方终端编码 Agent"
    ),
    AiCliPreset(
        displayName: "OpenCode",
        category: "国际",
        name: "openCode",
        command: "opencode",
        superLabel: "openCodeSuper",
        superCommand: "opencode",
        superEnv: ["OPENCODE_PERMISSION": "\"allow\""],
        resumeCommand: "opencode -c",
        directByDefault: false,
        note: "开源多模型终端编码 Agent"
    ),
    AiCliPreset(
        displayName: "Grok CLI (xAI)",
        category: "国际",
        name: "grok",
        command: "grok",
        superLabel: "grokSuper",
        superCommand: "grok --always-approve",
        superEnv: nil,
        resumeCommand: "grok --always-approve -r",
        directByDefault: false,
        note: "xAI Grok 终端编码工具"
    ),
    AiCliPreset(
        displayName: "Antigravity CLI (agy)",
        category: "国际",
        name: "agy",
        command: "agy",
        superLabel: "agySuper",
        superCommand: "agy --dangerously-skip-permissions",
        superEnv: nil,
        resumeCommand: "agy --dangerously-skip-permissions -c",
        directByDefault: false,
        note: "Google Antigravity 终端 Agent"
    ),
    AiCliPreset(
        displayName: "Gemini CLI (Google)",
        category: "国际",
        name: "gemini",
        command: "gemini",
        superLabel: "geminiSuper",
        superCommand: "gemini --yolo",
        superEnv: nil,
        resumeCommand: "gemini --yolo --resume",
        directByDefault: false,
        note: "Google 官方 Gemini 开源 CLI"
    ),
    AiCliPreset(
        displayName: "Qwen Code (通义千问)",
        category: "国内",
        name: "qwen",
        command: "qwen",
        superLabel: "qwenSuper",
        superCommand: "qwen --yolo",
        superEnv: nil,
        resumeCommand: "qwen --yolo --resume",
        directByDefault: true,
        note: "阿里通义千问编码 CLI（默认直连）"
    ),
    AiCliPreset(
        displayName: "Kimi CLI (月之暗面)",
        category: "国内",
        name: "kimi",
        command: "kimi",
        superLabel: "kimiSuper",
        superCommand: "kimi --yolo",
        superEnv: nil,
        resumeCommand: "kimi --yolo --continue",
        directByDefault: true,
        note: "Moonshot Kimi 终端编码 Agent（默认直连）"
    ),
    AiCliPreset(
        displayName: "CodeBuddy CLI (腾讯)",
        category: "国内",
        name: "codebuddy",
        command: "codebuddy",
        superLabel: "codebuddySuper",
        superCommand: "codebuddy --dangerously-skip-permissions",
        superEnv: nil,
        resumeCommand: "codebuddy --dangerously-skip-permissions -c",
        directByDefault: true,
        note: "腾讯 CodeBuddy 终端 Agent（默认直连）"
    ),
    AiCliPreset(
        displayName: "GitHub Copilot CLI",
        category: "国际",
        name: "copilot",
        command: "copilot",
        superLabel: "copilotSuper",
        superCommand: "copilot --allow-all-tools",
        superEnv: nil,
        resumeCommand: "copilot --allow-all-tools --resume",
        directByDefault: false,
        note: "GitHub 官方独立 Copilot Agent CLI"
    ),
    AiCliPreset(
        displayName: "Cursor Agent CLI",
        category: "国际",
        name: "cursor-agent",
        command: "cursor-agent",
        superLabel: "cursorSuper",
        superCommand: "cursor-agent -f",
        superEnv: nil,
        resumeCommand: "cursor-agent -f resume",
        directByDefault: false,
        note: "Cursor 官方终端 Agent"
    ),
    AiCliPreset(
        displayName: "Aider",
        category: "国际",
        name: "aider",
        command: "aider",
        superLabel: "aiderSuper",
        superCommand: "aider --yes-always",
        superEnv: nil,
        resumeCommand: "aider --yes-always --restore-chat-history",
        directByDefault: false,
        note: "经典开源 Git 集成 AI 结对编程工具"
    ),
    AiCliPreset(
        displayName: "Kiro CLI (AWS)",
        category: "国际",
        name: "kiro",
        command: "kiro-cli chat",
        superLabel: "kiroSuper",
        superCommand: "kiro-cli chat --trust-all-tools",
        superEnv: nil,
        resumeCommand: "kiro-cli chat --trust-all-tools --resume",
        directByDefault: false,
        note: "AWS Kiro / Amazon Q 终端编程助手"
    ),
    AiCliPreset(
        displayName: "Cline CLI",
        category: "国际",
        name: "cline",
        command: "cline",
        superLabel: "clineSuper",
        superCommand: "cline --yolo",
        superEnv: nil,
        resumeCommand: nil,
        directByDefault: false,
        note: "Cline 开源终端自治 Agent"
    ),
    AiCliPreset(
        displayName: "Amp (Sourcegraph)",
        category: "国际",
        name: "amp",
        command: "amp",
        superLabel: "ampSuper",
        superCommand: "amp --dangerously-allow-all",
        superEnv: nil,
        resumeCommand: "amp threads continue",
        directByDefault: false,
        note: "Sourcegraph Amp 终端编程 Agent"
    ),
    AiCliPreset(
        displayName: "Goose (Block)",
        category: "国际",
        name: "goose",
        command: "goose session",
        superLabel: nil,
        superCommand: nil,
        superEnv: nil,
        resumeCommand: nil,
        directByDefault: false,
        note: "Block 开源可扩展本地 AI Agent"
    ),
    AiCliPreset(
        displayName: "Augment CLI (auggie)",
        category: "国际",
        name: "auggie",
        command: "auggie",
        superLabel: nil,
        superCommand: nil,
        superEnv: nil,
        resumeCommand: nil,
        directByDefault: false,
        note: "Augment Code 终端 Agent"
    ),
    AiCliPreset(
        displayName: "Crush (Charm)",
        category: "国际",
        name: "crush",
        command: "crush",
        superLabel: "crushSuper",
        superCommand: "crush --yolo",
        superEnv: nil,
        resumeCommand: nil,
        directByDefault: false,
        note: "Charm 出品的高颜值终端编码 Agent"
    ),
    AiCliPreset(
        displayName: "Mistral Vibe",
        category: "国际",
        name: "vibe",
        command: "vibe",
        superLabel: "vibeSuper",
        superCommand: "vibe --auto-approve",
        superEnv: nil,
        resumeCommand: "vibe --auto-approve --continue",
        directByDefault: false,
        note: "Mistral 官方终端编程 Agent"
    ),
]

// MARK: - 添加 / 编辑自定义工具弹窗

private final class ToolEditorPanel {
    static func present(
        parent: NSWindow?,
        appDelegate: VibeCodeAppDelegate,
        existingTool: HostToolEntry?,
        existingNames: Set<String>
    ) -> (entry: HostToolEntry, importedIconSource: URL?)? {
        let isEditing = existingTool != nil
        let searchPaths = appDelegate.cliSearchPaths()
        let availablePresets = kBuiltinAiCliPresets.filter { !existingNames.contains($0.name) }
        let showPresetRow = !isEditing && !availablePresets.isEmpty

        let alert = NSAlert()
        alert.messageText = isEditing ? "编辑工具: \(existingTool!.name)" : "添加自定义 AI CLI 工具"
        alert.informativeText = isEditing
            ? "修改命令、Super 模式、环境变量或代理策略（自动同步 tools.json）。"
            : "填写任意自定义终端命令（19 款主流 AI CLI 已全部展示在主列表中）。"
        alert.addButton(withTitle: isEditing ? "保存修改" : "添加工具")
        alert.addButton(withTitle: "取消")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: showPresetRow ? 355 : 315))

        var y: CGFloat = container.frame.height - 28
        let labelW: CGFloat = 95
        let fieldX: CGFloat = 102
        let fieldW: CGFloat = 360

        func addRow(_ title: String, view: NSView, height: CGFloat = 24) {
            let lbl = NSTextField(labelWithString: title)
            lbl.alignment = .right
            lbl.font = NSFont.systemFont(ofSize: 12)
            lbl.frame = NSRect(x: 0, y: y + (height - 17) / 2, width: labelW, height: 17)
            view.frame = NSRect(x: fieldX, y: y, width: fieldW, height: height)
            container.addSubview(lbl)
            container.addSubview(view)
            y -= (height + 10)
        }

        let nameField = NSTextField(string: existingTool?.name ?? "")
        nameField.placeholderString = "例如: droid / lazygit / my-ai"

        let cmdField = NSTextField(string: existingTool?.command ?? "")
        cmdField.placeholderString = "例如: droid 或 npx @scope/cli"

        let superEnableCheck = NSButton(checkboxWithTitle: "启用 Super 模式（自动批准 / 跳过确认）", target: nil, action: nil)
        superEnableCheck.state = (existingTool?.superConfig != nil) ? .on : .off

        let superLabelField = NSTextField(string: existingTool?.superConfig?.label ?? "")
        superLabelField.placeholderString = "例如: myAiSuper"

        let superCmdField = NSTextField(string: existingTool?.superConfig?.command ?? "")
        superCmdField.placeholderString = "例如: my-ai --yolo"

        let resumeCmdField = NSTextField(string: existingTool?.superConfig?.resume?.command ?? "")
        resumeCmdField.placeholderString = "留空默认使用 <Super命令> -R"

        let envPairs: String = {
            guard let env = existingTool?.superConfig?.env, !env.isEmpty else { return "" }
            return env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }()
        let superEnvField = NSTextField(string: envPairs)
        superEnvField.placeholderString = "可选，例如: OPENCODE_PERMISSION=\"allow\""

        let directCheck = NSButton(checkboxWithTitle: "强制直连（忽略 VibeCode CLI 代理，适合国内模型）", target: nil, action: nil)
        directCheck.state = (existingTool?.useProxy == false) ? .on : .off

        var importedIconURL: URL? = nil
        let iconRowView = NSView(frame: NSRect(x: 0, y: 0, width: fieldW, height: 24))
        let iconStatusField = NSTextField(labelWithString: existingTool?.icon ?? "自动生成品牌圆角图标")
        iconStatusField.font = NSFont.systemFont(ofSize: 11)
        iconStatusField.textColor = .secondaryLabelColor
        iconStatusField.lineBreakMode = .byTruncatingMiddle
        iconStatusField.frame = NSRect(x: 0, y: 3, width: 245, height: 17)

        class PickerBridge: NSObject {
            let onPickPreset: (Int) -> Void
            let onPickIcon: () -> Void
            let onToggleSuper: () -> Void
            init(
                onPickPreset: @escaping (Int) -> Void,
                onPickIcon: @escaping () -> Void,
                onToggleSuper: @escaping () -> Void
            ) {
                self.onPickPreset = onPickPreset
                self.onPickIcon = onPickIcon
                self.onToggleSuper = onToggleSuper
            }
            @objc func presetChanged(_ sender: NSPopUpButton) { onPickPreset(sender.indexOfSelectedItem) }
            @objc func pickIcon(_ sender: NSButton) { onPickIcon() }
            @objc func toggleSuper(_ sender: NSButton) { onToggleSuper() }
        }

        let updateSuperFieldsEnabled = {
            let on = (superEnableCheck.state == .on)
            superLabelField.isEnabled = on
            superCmdField.isEnabled = on
            resumeCmdField.isEnabled = on
            superEnvField.isEnabled = on
        }

        let bridge = PickerBridge(
            onPickPreset: { index in
                guard index > 0 && index - 1 < availablePresets.count else { return }
                let preset = availablePresets[index - 1]
                nameField.stringValue = preset.name
                cmdField.stringValue = preset.command
                if let supCmd = preset.superCommand, let supLabel = preset.superLabel {
                    superEnableCheck.state = .on
                    superLabelField.stringValue = supLabel
                    superCmdField.stringValue = supCmd
                    resumeCmdField.stringValue = preset.resumeCommand ?? ""
                    if let env = preset.superEnv {
                        superEnvField.stringValue = env.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
                    } else {
                        superEnvField.stringValue = ""
                    }
                } else {
                    superEnableCheck.state = .off
                    superLabelField.stringValue = ""
                    superCmdField.stringValue = ""
                    resumeCmdField.stringValue = ""
                    superEnvField.stringValue = ""
                }
                directCheck.state = preset.directByDefault ? .on : .off
                updateSuperFieldsEnabled()
            },
            onPickIcon: {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.png, .icns, .ico, .jpeg]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url {
                    importedIconURL = url
                    iconStatusField.stringValue = "已选: \(url.lastPathComponent)"
                }
            },
            onToggleSuper: {
                updateSuperFieldsEnabled()
            }
        )

        if showPresetRow {
            let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            presetPopup.addItem(withTitle: "— 自定义工具，或选择模板 —")
            for preset in availablePresets {
                let primaryBin = preset.command.split(separator: " ").first.map(String.init) ?? preset.command
                let installedTag = appDelegate.isCommandInstalled(primaryBin, in: searchPaths) ? " [已安装]" : ""
                let directTag = preset.directByDefault ? " · 直连" : ""
                presetPopup.addItem(withTitle: "[\(preset.category)] \(preset.displayName)\(installedTag)\(directTag)")
            }
            presetPopup.target = bridge
            presetPopup.action = #selector(PickerBridge.presetChanged(_:))
            addRow("快速模板:", view: presetPopup, height: 26)
        }

        addRow("工具名称:", view: nameField)
        addRow("基础命令:", view: cmdField)

        superEnableCheck.target = bridge
        superEnableCheck.action = #selector(PickerBridge.toggleSuper(_:))
        addRow("", view: superEnableCheck, height: 22)

        addRow("Super 名称:", view: superLabelField)
        addRow("Super 命令:", view: superCmdField)
        addRow("恢复命令:", view: resumeCmdField)
        addRow("Super 环境变量:", view: superEnvField)
        addRow("", view: directCheck, height: 22)

        let chooseIconBtn = NSButton(title: "选择自定义图标...", target: bridge, action: #selector(PickerBridge.pickIcon(_:)))
        chooseIconBtn.bezelStyle = .rounded
        chooseIconBtn.frame = NSRect(x: 248, y: 0, width: 112, height: 24)
        iconRowView.addSubview(iconStatusField)
        iconRowView.addSubview(chooseIconBtn)
        addRow("菜单图标:", view: iconRowView, height: 24)

        updateSuperFieldsEnabled()
        alert.accessoryView = container

        withExtendedLifetime(bridge) {
            if let parent = parent {
                parent.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response != .alertFirstButtonReturn {
                importedIconURL = nil
                nameField.stringValue = ""
            }
        }

        let finalName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalCmd = cmdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalName.isEmpty, !finalCmd.isEmpty else {
            return nil
        }

        if !isEditing && existingNames.contains(finalName) {
            let warn = NSAlert()
            warn.alertStyle = .warning
            warn.messageText = "工具名已存在"
            warn.informativeText = "工具「\(finalName)」已在列表中，请直接编辑它或更换名称。"
            warn.runModal()
            return nil
        }

        var superEntry: HostSuperEntry? = nil
        if superEnableCheck.state == .on {
            let sCmd = superCmdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sCmd.isEmpty {
                let sLabelRaw = superLabelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let sLabel = sLabelRaw.isEmpty ? "\(finalName)Super" : sLabelRaw
                let rCmd = resumeCmdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let resumeObj = rCmd.isEmpty ? nil : HostResumeEntry(command: rCmd)

                var parsedEnv: [String: String] = [:]
                let rawEnv = superEnvField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawEnv.isEmpty {
                    for part in rawEnv.split(separator: ";") {
                        let pair = part.split(separator: "=", maxSplits: 1)
                        if pair.count == 2 {
                            let k = pair[0].trimmingCharacters(in: .whitespaces)
                            let v = pair[1].trimmingCharacters(in: .whitespaces)
                            if !k.isEmpty {
                                parsedEnv[k] = v
                            }
                        }
                    }
                }
                superEntry = HostSuperEntry(
                    command: sCmd,
                    label: sLabel,
                    env: parsedEnv.isEmpty ? nil : parsedEnv,
                    resume: resumeObj
                )
            }
        }

        let entry = HostToolEntry(
            name: finalName,
            command: finalCmd,
            icon: existingTool?.icon,
            useProxy: directCheck.state == .on ? false : nil,
            superConfig: superEntry
        )
        return (entry, importedIconURL)
    }
}

// MARK: - 主设置窗口（三标签页：工具与右键菜单 / 代理与终端 / 关于）

private enum MainTabIndex: Int {
    case tools = 0
    case proxyAndTerminal = 1
    case about = 2
}

private struct ToolRowModel {
    var entry: HostToolEntry
    let displaySubtitle: String?
    let isBuiltinPreset: Bool
    var persistedInToolsJson: Bool
    let installed: Bool
    var enabled: Bool
}

private final class MainSettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowDragType = NSPasteboard.PasteboardType("com.vibecode.contextmenu.toolrow")

    private unowned let appDelegate: VibeCodeAppDelegate
    private let tabView = NSTabView()

    // Tab 1: 工具与右键菜单
    private var rows: [ToolRowModel] = []
    private let masterSwitch = NSSwitch()
    private let masterStatusLabel = NSTextField(labelWithString: "")
    private let layoutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let normalModeCheck = NSButton(checkboxWithTitle: "普通", target: nil, action: nil)
    private let superModeCheck = NSButton(checkboxWithTitle: "Super", target: nil, action: nil)
    private let resumeModeCheck = NSButton(checkboxWithTitle: "恢复 (-R)", target: nil, action: nil)
    private let tableView = NSTableView()
    private let addButton = NSButton(title: "+ 自定义工具", target: nil, action: nil)
    private let editButton = NSButton(title: "编辑", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private let moveUpButton = NSButton(title: "上移 ↑", target: nil, action: nil)
    private let moveDownButton = NSButton(title: "下移 ↓", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新检测", target: nil, action: nil)
    private let countHintLabel = NSTextField(labelWithString: "")

    // Tab 2: 代理与终端
    private let terminalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let terminalDetectHintLabel = NSTextField(labelWithString: "")
    private var detectedTerminals: [DetectedTerminal] = []
    private let extStatusValueLabel = NSTextField(labelWithString: "")
    private let proxyEnableSwitch = NSSwitch()
    private let proxyFollowSystemCheck = NSButton(checkboxWithTitle: "跟随 macOS 系统代理（开代理生效，关代理直连）", target: nil, action: nil)
    private let sysProxyHintLabel = NSTextField(labelWithString: "")
    private let fillSysProxyButton = NSButton(title: "填入系统代理", target: nil, action: nil)
    private let proxyUrlField = NSTextField(string: "")
    private let noProxyField = NSTextField(string: "")
    private let saveProxyButton = NSButton(title: "保存代理设置", target: nil, action: nil)
    private let testProxyButton = NSButton(title: "测试连通性", target: nil, action: nil)
    private let proxyFeedbackLabel = NSTextField(labelWithString: "")
    private let proxyTestOutputView = NSTextView()
    private var detectedSystemProxy: String?

    // Tab 3: 关于与更新检测
    private let updateBannerBox = NSBox()
    private let updateBannerTitleLabel = NSTextField(labelWithString: "")
    private let updateBannerDetailLabel = NSTextField(labelWithString: "")
    private let bannerOnlineUpdateBtn = NSButton(title: "在线更新", target: nil, action: nil)
    private let bannerManualDownloadBtn = NSButton(title: "手动下载 (网页)", target: nil, action: nil)
    private let bannerNotesBtn = NSButton(title: "更新日志", target: nil, action: nil)
    private let checkUpdateButton = NSButton(title: "检查更新", target: nil, action: nil)
    private let updateStatusLabel = NSTextField(labelWithString: "点击「检查更新」检测 GitHub Releases 新版本")
    private var latestUpdateResult: UpdateCheckResult?
    private var isCheckingUpdate = false
    private var isDownloadingUpdate = false

    init(appDelegate: VibeCodeAppDelegate) {
        self.appDelegate = appDelegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 530)
        window.title = "VibeCode 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
        reloadAllFromDisk()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndRefresh(selecting tab: MainTabIndex? = nil) {
        reloadAllFromDisk()
        if let tab = tab, tab.rawValue < tabView.numberOfTabViewItems {
            tabView.selectTabViewItem(at: tab.rawValue)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])

        let toolsItem = NSTabViewItem(identifier: "tools")
        toolsItem.label = "工具与右键菜单"
        toolsItem.view = buildToolsTabView()
        tabView.addTabViewItem(toolsItem)

        let proxyItem = NSTabViewItem(identifier: "proxy")
        proxyItem.label = "代理与终端"
        proxyItem.view = buildProxyAndTerminalTabView()
        tabView.addTabViewItem(proxyItem)

        let aboutItem = NSTabViewItem(identifier: "about")
        aboutItem.label = "关于"
        aboutItem.view = buildAboutTabView()
        tabView.addTabViewItem(aboutItem)
    }

    // MARK: - Tab 1 UI: 工具与右键菜单

    private func buildToolsTabView() -> NSView {
        let root = NSView()

        let headerBox = makeCardBox()
        root.addSubview(headerBox)

        let titleLabel = NSTextField(labelWithString: "在访达右键菜单中显示 VibeCode")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        masterStatusLabel.font = NSFont.systemFont(ofSize: 12)
        masterStatusLabel.textColor = .secondaryLabelColor
        masterStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        masterSwitch.target = self
        masterSwitch.action = #selector(handleDisplayOptionChanged)
        masterSwitch.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let layoutLabel = NSTextField(labelWithString: "菜单排版:")
        layoutLabel.font = NSFont.systemFont(ofSize: 12)
        layoutLabel.textColor = .secondaryLabelColor
        layoutLabel.translatesAutoresizingMaskIntoConstraints = false

        layoutPopup.addItems(withTitles: [
            "自动（>5 个工具时折叠）",
            "平铺展开（全部同级）",
            "按工具折叠二级子菜单",
        ])
        layoutPopup.target = self
        layoutPopup.action = #selector(handleDisplayOptionChanged)
        layoutPopup.translatesAutoresizingMaskIntoConstraints = false

        let modesLabel = NSTextField(labelWithString: "显示项:")
        modesLabel.font = NSFont.systemFont(ofSize: 12)
        modesLabel.textColor = .secondaryLabelColor
        modesLabel.translatesAutoresizingMaskIntoConstraints = false

        for chk in [normalModeCheck, superModeCheck, resumeModeCheck] {
            chk.target = self
            chk.action = #selector(handleDisplayOptionChanged)
            chk.translatesAutoresizingMaskIntoConstraints = false
        }

        for v in [titleLabel, masterStatusLabel, masterSwitch, divider, layoutLabel, layoutPopup, modesLabel, normalModeCheck, superModeCheck, resumeModeCheck] {
            headerBox.addSubview(v)
        }

        let sectionLabel = NSTextField(labelWithString: "全部 AI 工具（未安装项不可勾选；拖拽或上下移排序，双击编辑）")
        sectionLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        sectionLabel.textColor = .secondaryLabelColor
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sectionLabel)

        countHintLabel.font = NSFont.systemFont(ofSize: 11)
        countHintLabel.textColor = .tertiaryLabelColor
        countHintLabel.alignment = .right
        countHintLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(countHintLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ToolColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 46
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleEditSelected)
        tableView.registerForDraggedTypes([Self.rowDragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        for btn in [addButton, editButton, deleteButton, moveUpButton, moveDownButton, refreshButton] {
            btn.bezelStyle = .rounded
            btn.target = self
            btn.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(btn)
        }
        addButton.keyEquivalent = "n"
        addButton.action = #selector(handleAddTool)
        editButton.action = #selector(handleEditSelected)
        deleteButton.action = #selector(handleDeleteSelected)
        moveUpButton.action = #selector(handleMoveUp)
        moveDownButton.action = #selector(handleMoveDown)
        refreshButton.action = #selector(handleRefreshDetection)

        let footerHint = NSTextField(labelWithString: "仅本机已安装的 CLI 允许勾选到右键菜单；安装新 CLI 后点击「刷新检测」即可启用。")
        footerHint.font = NSFont.systemFont(ofSize: 11)
        footerHint.textColor = .tertiaryLabelColor
        footerHint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footerHint)

        NSLayoutConstraint.activate([
            headerBox.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            headerBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            headerBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            headerBox.heightAnchor.constraint(equalToConstant: 108),

            titleLabel.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: headerBox.topAnchor, constant: 12),

            masterStatusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            masterStatusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            masterStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: masterSwitch.leadingAnchor, constant: -12),

            masterSwitch.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor, constant: -14),
            masterSwitch.topAnchor.constraint(equalTo: headerBox.topAnchor, constant: 16),

            divider.topAnchor.constraint(equalTo: masterStatusLabel.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor, constant: -12),

            layoutLabel.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor, constant: 14),
            layoutLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 11),

            layoutPopup.leadingAnchor.constraint(equalTo: layoutLabel.trailingAnchor, constant: 6),
            layoutPopup.centerYAnchor.constraint(equalTo: layoutLabel.centerYAnchor),
            layoutPopup.widthAnchor.constraint(equalToConstant: 195),

            modesLabel.leadingAnchor.constraint(equalTo: layoutPopup.trailingAnchor, constant: 18),
            modesLabel.centerYAnchor.constraint(equalTo: layoutLabel.centerYAnchor),

            normalModeCheck.leadingAnchor.constraint(equalTo: modesLabel.trailingAnchor, constant: 6),
            normalModeCheck.centerYAnchor.constraint(equalTo: layoutLabel.centerYAnchor),

            superModeCheck.leadingAnchor.constraint(equalTo: normalModeCheck.trailingAnchor, constant: 10),
            superModeCheck.centerYAnchor.constraint(equalTo: layoutLabel.centerYAnchor),

            resumeModeCheck.leadingAnchor.constraint(equalTo: superModeCheck.trailingAnchor, constant: 10),
            resumeModeCheck.centerYAnchor.constraint(equalTo: layoutLabel.centerYAnchor),

            sectionLabel.topAnchor.constraint(equalTo: headerBox.bottomAnchor, constant: 12),
            sectionLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),

            countHintLabel.centerYAnchor.constraint(equalTo: sectionLabel.centerYAnchor),
            countHintLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            countHintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: sectionLabel.trailingAnchor, constant: 8),

            scrollView.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -12),

            addButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            addButton.bottomAnchor.constraint(equalTo: footerHint.topAnchor, constant: -10),

            editButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 6),
            editButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            deleteButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 6),
            deleteButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            moveUpButton.leadingAnchor.constraint(equalTo: deleteButton.trailingAnchor, constant: 16),
            moveUpButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            moveDownButton.leadingAnchor.constraint(equalTo: moveUpButton.trailingAnchor, constant: 6),
            moveDownButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            refreshButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            footerHint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footerHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footerHint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])

        return root
    }

    // MARK: - Tab 2 UI: 代理与终端

    private func buildProxyAndTerminalTabView() -> NSView {
        let root = NSView()

        // 卡片 1：默认终端与访达扩展
        let termBox = makeCardBox()
        root.addSubview(termBox)

        let termHeader = NSTextField(labelWithString: "终端与访达扩展")
        termHeader.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        termHeader.translatesAutoresizingMaskIntoConstraints = false

        let termLabel = NSTextField(labelWithString: "默认终端:")
        termLabel.font = NSFont.systemFont(ofSize: 12)
        termLabel.textColor = .secondaryLabelColor
        termLabel.translatesAutoresizingMaskIntoConstraints = false

        terminalPopup.target = self
        terminalPopup.action = #selector(handleTerminalPopupChanged)
        terminalPopup.translatesAutoresizingMaskIntoConstraints = false

        let redetectTermBtn = NSButton(title: "重新检测", target: self, action: #selector(handleRedetectTerminals))
        redetectTermBtn.bezelStyle = .rounded
        redetectTermBtn.translatesAutoresizingMaskIntoConstraints = false

        terminalDetectHintLabel.font = NSFont.systemFont(ofSize: 11)
        terminalDetectHintLabel.textColor = .tertiaryLabelColor
        terminalDetectHintLabel.lineBreakMode = .byTruncatingTail
        terminalDetectHintLabel.translatesAutoresizingMaskIntoConstraints = false

        let extLabel = NSTextField(labelWithString: "访达扩展:")
        extLabel.font = NSFont.systemFont(ofSize: 12)
        extLabel.textColor = .secondaryLabelColor
        extLabel.translatesAutoresizingMaskIntoConstraints = false

        extStatusValueLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        extStatusValueLabel.translatesAutoresizingMaskIntoConstraints = false

        let reactivateExtBtn = NSButton(title: "激活/刷新扩展", target: self, action: #selector(handleReactivateExtension))
        reactivateExtBtn.bezelStyle = .rounded
        reactivateExtBtn.translatesAutoresizingMaskIntoConstraints = false

        let openSysExtBtn = NSButton(title: "系统扩展设置...", target: self, action: #selector(handleOpenSysExtSettings))
        openSysExtBtn.bezelStyle = .rounded
        openSysExtBtn.translatesAutoresizingMaskIntoConstraints = false

        for v in [termHeader, termLabel, terminalPopup, redetectTermBtn, terminalDetectHintLabel, extLabel, extStatusValueLabel, reactivateExtBtn, openSysExtBtn] {
            termBox.addSubview(v)
        }

        // 卡片 2：CLI 代理设置与测速
        let proxyBox = makeCardBox()
        root.addSubview(proxyBox)

        let proxyHeader = NSTextField(labelWithString: "CLI 代理（仅注入给 VibeCode 启动的工具）")
        proxyHeader.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        proxyHeader.translatesAutoresizingMaskIntoConstraints = false

        proxyEnableSwitch.target = self
        proxyEnableSwitch.action = #selector(handleProxySwitchToggled)
        proxyEnableSwitch.translatesAutoresizingMaskIntoConstraints = false

        proxyFollowSystemCheck.target = self
        proxyFollowSystemCheck.action = #selector(handleProxyFollowSystemToggled)
        proxyFollowSystemCheck.translatesAutoresizingMaskIntoConstraints = false

        sysProxyHintLabel.font = NSFont.systemFont(ofSize: 12)
        sysProxyHintLabel.textColor = .secondaryLabelColor
        sysProxyHintLabel.translatesAutoresizingMaskIntoConstraints = false

        fillSysProxyButton.bezelStyle = .rounded
        fillSysProxyButton.target = self
        fillSysProxyButton.action = #selector(handleFillSystemProxy)
        fillSysProxyButton.translatesAutoresizingMaskIntoConstraints = false

        let urlLabel = NSTextField(labelWithString: "代理地址:")
        urlLabel.font = NSFont.systemFont(ofSize: 12)
        urlLabel.alignment = .right
        urlLabel.translatesAutoresizingMaskIntoConstraints = false

        proxyUrlField.placeholderString = "例如: http://127.0.0.1:7897 或 socks5://127.0.0.1:7897"
        proxyUrlField.translatesAutoresizingMaskIntoConstraints = false

        let noProxyLabel = NSTextField(labelWithString: "NO_PROXY:")
        noProxyLabel.font = NSFont.systemFont(ofSize: 12)
        noProxyLabel.alignment = .right
        noProxyLabel.translatesAutoresizingMaskIntoConstraints = false

        noProxyField.placeholderString = kDefaultNoProxy
        noProxyField.translatesAutoresizingMaskIntoConstraints = false

        saveProxyButton.bezelStyle = .rounded
        saveProxyButton.keyEquivalent = "\r"
        saveProxyButton.target = self
        saveProxyButton.action = #selector(handleSaveProxy)
        saveProxyButton.translatesAutoresizingMaskIntoConstraints = false

        testProxyButton.bezelStyle = .rounded
        testProxyButton.target = self
        testProxyButton.action = #selector(handleTestProxy)
        testProxyButton.translatesAutoresizingMaskIntoConstraints = false

        proxyFeedbackLabel.font = NSFont.systemFont(ofSize: 12)
        proxyFeedbackLabel.textColor = .secondaryLabelColor
        proxyFeedbackLabel.translatesAutoresizingMaskIntoConstraints = false

        let directTipLabel = NSTextField(labelWithString: "提示: 如需为某个国内 CLI（如 qwen / kimi）单独设直连，请在「工具与右键菜单」双击该工具勾选「强制直连」。")
        directTipLabel.font = NSFont.systemFont(ofSize: 11)
        directTipLabel.textColor = .tertiaryLabelColor
        directTipLabel.translatesAutoresizingMaskIntoConstraints = false

        proxyTestOutputView.isEditable = false
        proxyTestOutputView.isSelectable = true
        proxyTestOutputView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        proxyTestOutputView.textColor = .labelColor
        proxyTestOutputView.backgroundColor = NSColor.textBackgroundColor
        proxyTestOutputView.textContainerInset = NSSize(width: 8, height: 8)
        proxyTestOutputView.string = "点击「测试连通性」可检测当前代理访问 Google、Antigravity、Anthropic 与 OpenAI 的状态。"

        let outputScroll = NSScrollView()
        outputScroll.documentView = proxyTestOutputView
        outputScroll.hasVerticalScroller = true
        outputScroll.borderType = .bezelBorder
        outputScroll.translatesAutoresizingMaskIntoConstraints = false

        for v in [proxyHeader, proxyEnableSwitch, proxyFollowSystemCheck, sysProxyHintLabel, fillSysProxyButton, urlLabel, proxyUrlField, noProxyLabel, noProxyField, saveProxyButton, testProxyButton, proxyFeedbackLabel, directTipLabel, outputScroll] {
            proxyBox.addSubview(v)
        }

        NSLayoutConstraint.activate([
            termBox.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            termBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            termBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            termBox.heightAnchor.constraint(equalToConstant: 138),

            termHeader.topAnchor.constraint(equalTo: termBox.topAnchor, constant: 12),
            termHeader.leadingAnchor.constraint(equalTo: termBox.leadingAnchor, constant: 14),

            termLabel.topAnchor.constraint(equalTo: termHeader.bottomAnchor, constant: 14),
            termLabel.leadingAnchor.constraint(equalTo: termBox.leadingAnchor, constant: 14),

            terminalPopup.centerYAnchor.constraint(equalTo: termLabel.centerYAnchor),
            terminalPopup.leadingAnchor.constraint(equalTo: termLabel.trailingAnchor, constant: 8),
            terminalPopup.widthAnchor.constraint(equalToConstant: 210),

            redetectTermBtn.centerYAnchor.constraint(equalTo: termLabel.centerYAnchor),
            redetectTermBtn.leadingAnchor.constraint(equalTo: terminalPopup.trailingAnchor, constant: 8),

            terminalDetectHintLabel.topAnchor.constraint(equalTo: termLabel.bottomAnchor, constant: 6),
            terminalDetectHintLabel.leadingAnchor.constraint(equalTo: termBox.leadingAnchor, constant: 14),
            terminalDetectHintLabel.trailingAnchor.constraint(equalTo: termBox.trailingAnchor, constant: -14),

            extLabel.topAnchor.constraint(equalTo: terminalDetectHintLabel.bottomAnchor, constant: 14),
            extLabel.leadingAnchor.constraint(equalTo: termBox.leadingAnchor, constant: 14),

            extStatusValueLabel.centerYAnchor.constraint(equalTo: extLabel.centerYAnchor),
            extStatusValueLabel.leadingAnchor.constraint(equalTo: extLabel.trailingAnchor, constant: 8),

            openSysExtBtn.centerYAnchor.constraint(equalTo: extLabel.centerYAnchor),
            openSysExtBtn.trailingAnchor.constraint(equalTo: termBox.trailingAnchor, constant: -14),

            reactivateExtBtn.centerYAnchor.constraint(equalTo: extLabel.centerYAnchor),
            reactivateExtBtn.trailingAnchor.constraint(equalTo: openSysExtBtn.leadingAnchor, constant: -8),

            proxyBox.topAnchor.constraint(equalTo: termBox.bottomAnchor, constant: 12),
            proxyBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            proxyBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            proxyBox.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            proxyHeader.topAnchor.constraint(equalTo: proxyBox.topAnchor, constant: 12),
            proxyHeader.leadingAnchor.constraint(equalTo: proxyBox.leadingAnchor, constant: 14),

            proxyEnableSwitch.centerYAnchor.constraint(equalTo: proxyHeader.centerYAnchor),
            proxyEnableSwitch.trailingAnchor.constraint(equalTo: proxyBox.trailingAnchor, constant: -14),

            proxyFollowSystemCheck.topAnchor.constraint(equalTo: proxyHeader.bottomAnchor, constant: 8),
            proxyFollowSystemCheck.leadingAnchor.constraint(equalTo: proxyBox.leadingAnchor, constant: 14),

            sysProxyHintLabel.topAnchor.constraint(equalTo: proxyFollowSystemCheck.bottomAnchor, constant: 8),
            sysProxyHintLabel.leadingAnchor.constraint(equalTo: proxyBox.leadingAnchor, constant: 14),

            fillSysProxyButton.centerYAnchor.constraint(equalTo: sysProxyHintLabel.centerYAnchor),
            fillSysProxyButton.trailingAnchor.constraint(equalTo: proxyBox.trailingAnchor, constant: -14),

            urlLabel.topAnchor.constraint(equalTo: sysProxyHintLabel.bottomAnchor, constant: 16),
            urlLabel.leadingAnchor.constraint(equalTo: proxyBox.leadingAnchor, constant: 14),
            urlLabel.widthAnchor.constraint(equalToConstant: 76),

            proxyUrlField.centerYAnchor.constraint(equalTo: urlLabel.centerYAnchor),
            proxyUrlField.leadingAnchor.constraint(equalTo: urlLabel.trailingAnchor, constant: 8),
            proxyUrlField.trailingAnchor.constraint(equalTo: proxyBox.trailingAnchor, constant: -14),

            noProxyLabel.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 14),
            noProxyLabel.leadingAnchor.constraint(equalTo: proxyBox.leadingAnchor, constant: 14),
            noProxyLabel.widthAnchor.constraint(equalToConstant: 76),

            noProxyField.centerYAnchor.constraint(equalTo: noProxyLabel.centerYAnchor),
            noProxyField.leadingAnchor.constraint(equalTo: noProxyLabel.trailingAnchor, constant: 8),
            noProxyField.trailingAnchor.constraint(equalTo: proxyBox.trailingAnchor, constant: -14),

            saveProxyButton.topAnchor.constraint(equalTo: noProxyField.bottomAnchor, constant: 14),
            saveProxyButton.leadingAnchor.constraint(equalTo: proxyUrlField.leadingAnchor),

            testProxyButton.centerYAnchor.constraint(equalTo: saveProxyButton.centerYAnchor),
            testProxyButton.leadingAnchor.constraint(equalTo: saveProxyButton.trailingAnchor, constant: 8),

            proxyFeedbackLabel.centerYAnchor.constraint(equalTo: saveProxyButton.centerYAnchor),
            proxyFeedbackLabel.leadingAnchor.constraint(equalTo: testProxyButton.trailingAnchor, constant: 12),
            proxyFeedbackLabel.trailingAnchor.constraint(lessThanOrEqualTo: proxyBox.trailingAnchor, constant: -14),

            directTipLabel.topAnchor.constraint(equalTo: saveProxyButton.bottomAnchor, constant: 10),
            directTipLabel.leadingAnchor.constraint(equalTo: proxyBox.leadingAnchor, constant: 14),
            directTipLabel.trailingAnchor.constraint(equalTo: proxyBox.trailingAnchor, constant: -14),

            outputScroll.topAnchor.constraint(equalTo: directTipLabel.bottomAnchor, constant: 10),
            outputScroll.leadingAnchor.constraint(equalTo: proxyBox.leadingAnchor, constant: 14),
            outputScroll.trailingAnchor.constraint(equalTo: proxyBox.trailingAnchor, constant: -14),
            outputScroll.bottomAnchor.constraint(equalTo: proxyBox.bottomAnchor, constant: -14),
        ])

        return root
    }

    // MARK: - Tab 3 UI: 关于

    private func buildAboutTabView() -> NSView {
        let root = NSView()
        let card = makeCardBox()
        root.addSubview(card)

        let iconView = NSImageView()
        iconView.image = appDelegate.loadToolIcon(toolName: "VibeCode", iconFileName: "vibecode.ico", size: 72)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
        let appTitle = NSTextField(labelWithString: "VibeCode Context Menu")
        appTitle.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        appTitle.alignment = .center
        appTitle.translatesAutoresizingMaskIntoConstraints = false

        let versionLabel = NSTextField(labelWithString: "macOS 原生版 · v\(version)")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        let descLabel = NSTextField(labelWithString: "在访达右键文件夹及空白处一键启动各类 AI CLI 工具")
        descLabel.font = NSFont.systemFont(ofSize: 13)
        descLabel.textColor = .secondaryLabelColor
        descLabel.alignment = .center
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        let authorLabel = NSTextField(labelWithString: "作者：\(kAuthorName)")
        authorLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        authorLabel.alignment = .center
        authorLabel.translatesAutoresizingMaskIntoConstraints = false

        let linkAttr = NSAttributedString(
            string: kGitHubURLString,
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .font: NSFont.systemFont(ofSize: 13),
            ]
        )
        let githubLinkBtn = NSButton(title: kGitHubURLString, target: self, action: #selector(handleOpenGitHub))
        githubLinkBtn.isBordered = false
        githubLinkBtn.attributedTitle = linkAttr
        githubLinkBtn.translatesAutoresizingMaskIntoConstraints = false

        let openGitHubBtn = NSButton(title: "访问 GitHub 仓库", target: self, action: #selector(handleOpenGitHub))
        openGitHubBtn.bezelStyle = .rounded
        openGitHubBtn.translatesAutoresizingMaskIntoConstraints = false

        checkUpdateButton.bezelStyle = .rounded
        checkUpdateButton.target = self
        checkUpdateButton.action = #selector(handleCheckUpdate)
        checkUpdateButton.translatesAutoresizingMaskIntoConstraints = false

        updateStatusLabel.font = NSFont.systemFont(ofSize: 12)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.alignment = .center
        updateStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        // 检测到新版本时直接显示的高亮更新卡片（在线更新 / 手动下载 / 更新日志）
        updateBannerBox.boxType = .custom
        updateBannerBox.cornerRadius = 8
        updateBannerBox.borderWidth = 1
        updateBannerBox.borderColor = NSColor.systemBlue.withAlphaComponent(0.35)
        updateBannerBox.fillColor = NSColor.systemBlue.withAlphaComponent(0.08)
        updateBannerBox.isHidden = true
        updateBannerBox.translatesAutoresizingMaskIntoConstraints = false

        updateBannerTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        updateBannerTitleLabel.textColor = .systemBlue
        updateBannerTitleLabel.alignment = .center
        updateBannerTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        updateBannerDetailLabel.font = NSFont.systemFont(ofSize: 11.5)
        updateBannerDetailLabel.textColor = .secondaryLabelColor
        updateBannerDetailLabel.alignment = .center
        updateBannerDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        bannerOnlineUpdateBtn.bezelStyle = .rounded
        bannerOnlineUpdateBtn.bezelColor = .controlAccentColor
        bannerOnlineUpdateBtn.target = self
        bannerOnlineUpdateBtn.action = #selector(handleBannerOnlineUpdate)
        bannerOnlineUpdateBtn.translatesAutoresizingMaskIntoConstraints = false

        bannerManualDownloadBtn.bezelStyle = .rounded
        bannerManualDownloadBtn.target = self
        bannerManualDownloadBtn.action = #selector(handleBannerManualDownload)
        bannerManualDownloadBtn.translatesAutoresizingMaskIntoConstraints = false

        bannerNotesBtn.bezelStyle = .rounded
        bannerNotesBtn.target = self
        bannerNotesBtn.action = #selector(handleBannerShowNotes)
        bannerNotesBtn.translatesAutoresizingMaskIntoConstraints = false

        let bannerBtnStack = NSStackView(views: [bannerOnlineUpdateBtn, bannerManualDownloadBtn, bannerNotesBtn])
        bannerBtnStack.orientation = .horizontal
        bannerBtnStack.spacing = 8
        bannerBtnStack.translatesAutoresizingMaskIntoConstraints = false

        updateBannerBox.addSubview(updateBannerTitleLabel)
        updateBannerBox.addSubview(updateBannerDetailLabel)
        updateBannerBox.addSubview(bannerBtnStack)

        NSLayoutConstraint.activate([
            updateBannerTitleLabel.topAnchor.constraint(equalTo: updateBannerBox.topAnchor, constant: 10),
            updateBannerTitleLabel.centerXAnchor.constraint(equalTo: updateBannerBox.centerXAnchor),
            updateBannerTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: updateBannerBox.leadingAnchor, constant: 14),
            updateBannerTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: updateBannerBox.trailingAnchor, constant: -14),

            updateBannerDetailLabel.topAnchor.constraint(equalTo: updateBannerTitleLabel.bottomAnchor, constant: 4),
            updateBannerDetailLabel.centerXAnchor.constraint(equalTo: updateBannerBox.centerXAnchor),
            updateBannerDetailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: updateBannerBox.leadingAnchor, constant: 14),
            updateBannerDetailLabel.trailingAnchor.constraint(lessThanOrEqualTo: updateBannerBox.trailingAnchor, constant: -14),

            bannerBtnStack.topAnchor.constraint(equalTo: updateBannerDetailLabel.bottomAnchor, constant: 10),
            bannerBtnStack.centerXAnchor.constraint(equalTo: updateBannerBox.centerXAnchor),
            bannerBtnStack.bottomAnchor.constraint(equalTo: updateBannerBox.bottomAnchor, constant: -10),
        ])

        let openConfigDirBtn = NSButton(title: "打开配置目录", target: self, action: #selector(handleOpenConfigDir))
        openConfigDirBtn.bezelStyle = .rounded
        openConfigDirBtn.translatesAutoresizingMaskIntoConstraints = false

        let editToolsJsonBtn = NSButton(title: "编辑 tools.json", target: self, action: #selector(handleEditToolsJson))
        editToolsJsonBtn.bezelStyle = .rounded
        editToolsJsonBtn.translatesAutoresizingMaskIntoConstraints = false

        for v in [iconView, appTitle, versionLabel, descLabel, sep, authorLabel, githubLinkBtn, updateBannerBox, checkUpdateButton, openGitHubBtn, updateStatusLabel, openConfigDirBtn, editToolsJsonBtn] {
            card.addSubview(v)
        }

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),

            iconView.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            iconView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            appTitle.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            appTitle.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            versionLabel.topAnchor.constraint(equalTo: appTitle.bottomAnchor, constant: 4),
            versionLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            descLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 6),
            descLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            sep.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 16),
            sep.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 60),
            sep.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -60),

            authorLabel.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 14),
            authorLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            githubLinkBtn.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 6),
            githubLinkBtn.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            updateBannerBox.topAnchor.constraint(equalTo: githubLinkBtn.bottomAnchor, constant: 14),
            updateBannerBox.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            updateBannerBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),

            checkUpdateButton.topAnchor.constraint(equalTo: updateBannerBox.bottomAnchor, constant: 14),
            checkUpdateButton.trailingAnchor.constraint(equalTo: card.centerXAnchor, constant: -6),

            openGitHubBtn.centerYAnchor.constraint(equalTo: checkUpdateButton.centerYAnchor),
            openGitHubBtn.leadingAnchor.constraint(equalTo: card.centerXAnchor, constant: 6),

            updateStatusLabel.topAnchor.constraint(equalTo: checkUpdateButton.bottomAnchor, constant: 8),
            updateStatusLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            openConfigDirBtn.topAnchor.constraint(equalTo: updateStatusLabel.bottomAnchor, constant: 14),
            openConfigDirBtn.trailingAnchor.constraint(equalTo: card.centerXAnchor, constant: -6),

            editToolsJsonBtn.centerYAnchor.constraint(equalTo: openConfigDirBtn.centerYAnchor),
            editToolsJsonBtn.leadingAnchor.constraint(equalTo: card.centerXAnchor, constant: 6),
        ])

        if let cached = appDelegate.cachedUpdateResult {
            applyUpdateCheckResult(cached)
        }

        return root
    }

    private func makeCardBox() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = NSColor.separatorColor
        box.fillColor = NSColor.controlBackgroundColor
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    // MARK: - 数据加载与持久化

    func reloadAllFromDisk() {
        reloadToolsTabFromDisk()
        reloadProxyAndTerminalTabFromDisk()
    }

    private func reloadToolsTabFromDisk() {
        let toolsCfg = appDelegate.loadToolsConfig()
        let macCfg = appDelegate.loadMacOSConfig()

        let menuOn = macCfg.contextMenuEnabled ?? true
        masterSwitch.state = menuOn ? .on : .off
        updateMasterStatusText(menuOn: menuOn)

        switch (macCfg.menuLayout ?? "auto").lowercased() {
        case "flat": layoutPopup.selectItem(at: 1)
        case "grouped": layoutPopup.selectItem(at: 2)
        default: layoutPopup.selectItem(at: 0)
        }

        normalModeCheck.state = (macCfg.showNormalMode ?? true) ? .on : .off
        superModeCheck.state = (macCfg.showSuperMode ?? true) ? .on : .off
        resumeModeCheck.state = (macCfg.showResumeMode ?? true) ? .on : .off

        let configuredTools = toolsCfg?.tools ?? []
        let presetByName = Dictionary(uniqueKeysWithValues: kBuiltinAiCliPresets.map { ($0.name, $0) })

        var catalogByName: [String: (entry: HostToolEntry, preset: AiCliPreset?, persisted: Bool)] = [:]
        for t in configuredTools {
            catalogByName[t.name] = (t, presetByName[t.name], true)
        }
        for p in kBuiltinAiCliPresets {
            if catalogByName[p.name] == nil {
                catalogByName[p.name] = (p.toToolEntry(), p, false)
            }
        }

        let enabledList = macCfg.enabledTools ?? configuredTools.map(\.name)
        let enabledSet = Set(enabledList)

        let defaultNames = configuredTools.map(\.name) + kBuiltinAiCliPresets.map(\.name)
        var orderedNames: [String] = []
        for candidate in (macCfg.toolOrder ?? []) + enabledList + defaultNames {
            if catalogByName[candidate] != nil && !orderedNames.contains(candidate) {
                orderedNames.append(candidate)
            }
        }
        if !enabledList.isEmpty {
            let validEnabled = enabledList.filter { catalogByName[$0] != nil }
            let remaining = orderedNames.filter { !enabledSet.contains($0) }
            let enabledInOrder = orderedNames.filter { enabledSet.contains($0) }
            if macCfg.toolOrder == nil || enabledInOrder != validEnabled {
                orderedNames = validEnabled + remaining
            }
        }

        let searchPaths = appDelegate.cliSearchPaths()
        var installedRows: [ToolRowModel] = []
        var uninstalledRows: [ToolRowModel] = []

        for name in orderedNames {
            guard let item = catalogByName[name] else { continue }
            let primaryBin = item.entry.command.split(separator: " ").first.map(String.init) ?? item.entry.command
            let installed = appDelegate.isCommandInstalled(primaryBin, in: searchPaths)
            let isEnabled = installed && enabledSet.contains(name)
            let row = ToolRowModel(
                entry: item.entry,
                displaySubtitle: item.preset?.displayName,
                isBuiltinPreset: item.preset != nil,
                persistedInToolsJson: item.persisted,
                installed: installed,
                enabled: isEnabled
            )
            if installed {
                installedRows.append(row)
            } else {
                uninstalledRows.append(row)
            }
        }

        rows = installedRows + uninstalledRows
        tableView.reloadData()
        updateActionButtonsAndSummary()
    }

    private func reloadProxyAndTerminalTabFromDisk() {
        let macCfg = appDelegate.loadMacOSConfig()
        let toolsCfg = appDelegate.loadToolsConfig()

        // 终端下拉：只展示本机实际检测到的终端
        detectedTerminals = appDelegate.detectInstalledTerminals()
        let currentTerminalID = macCfg.terminal ?? "Terminal"
        terminalPopup.removeAllItems()
        for item in detectedTerminals {
            terminalPopup.addItem(withTitle: item.spec.displayName)
        }
        if let idx = detectedTerminals.firstIndex(where: { $0.spec.id == currentTerminalID }) {
            terminalPopup.selectItem(at: idx)
        } else if !detectedTerminals.isEmpty {
            terminalPopup.selectItem(at: 0)
            // 若此前配置的终端已被卸载，自动回退到首个已检测到的终端
            var fallbackCfg = macCfg
            fallbackCfg.terminal = detectedTerminals[0].spec.id
            fallbackCfg.terminalAppPath = detectedTerminals[0].appURL.path
            appDelegate.saveMacOSConfig(fallbackCfg)
        }
        let supportedNames = kSupportedTerminals.map { $0.id == "iTerm" ? "iTerm2" : $0.id }.joined(separator: " / ")
        terminalDetectHintLabel.stringValue = "已检测到 \(detectedTerminals.count)/\(kSupportedTerminals.count) 款（支持自动检测: \(supportedNames)）"

        // 访达扩展状态
        let extOn = appDelegate.isFinderExtensionEnabled()
        extStatusValueLabel.stringValue = extOn ? "已启用" : "未启用（请点击右侧激活或在系统设置勾选）"
        extStatusValueLabel.textColor = extOn ? .systemGreen : .systemOrange

        // 代理配置
        let proxy = toolsCfg?.proxy
        proxyEnableSwitch.state = (proxy?.enabled == true) ? .on : .off
        let isSystemMode = (proxy?.mode?.lowercased() == "system")
        proxyFollowSystemCheck.state = isSystemMode ? .on : .off
        proxyUrlField.stringValue = proxy?.url ?? ""
        noProxyField.stringValue = (proxy?.noProxy?.isEmpty == false) ? (proxy?.noProxy ?? kDefaultNoProxy) : kDefaultNoProxy

        detectedSystemProxy = appDelegate.detectMacOSSystemProxy()
        if let sys = detectedSystemProxy {
            sysProxyHintLabel.stringValue = "检测到 macOS 系统代理: \(sys)"
            sysProxyHintLabel.textColor = .secondaryLabelColor
        } else {
            sysProxyHintLabel.stringValue = "未检测到 macOS 系统代理（可勾选「跟随系统」或手动填写地址）"
            sysProxyHintLabel.textColor = .tertiaryLabelColor
        }
        updateProxyInputState()
    }

    private func updateMasterStatusText(menuOn: Bool) {
        let extActive = appDelegate.isFinderExtensionEnabled()
        if !menuOn {
            masterStatusLabel.stringValue = "当前已隐藏：访达右键不会显示 VibeCode 菜单"
            masterStatusLabel.textColor = .secondaryLabelColor
        } else if extActive {
            masterStatusLabel.stringValue = "当前已显示：访达右键文件夹及空白处均可见"
            masterStatusLabel.textColor = .systemGreen
        } else {
            masterStatusLabel.stringValue = "需在「系统设置 -> 扩展 -> Finder」启用 VibeCode 扩展"
            masterStatusLabel.textColor = .systemOrange
        }
    }

    private func persistMacOSConfigOnly() {
        var cfg = appDelegate.loadMacOSConfig()
        cfg.contextMenuEnabled = (masterSwitch.state == .on)
        cfg.menuLayout = ["auto", "flat", "grouped"][max(0, min(2, layoutPopup.indexOfSelectedItem))]

        if normalModeCheck.state == .off && superModeCheck.state == .off && resumeModeCheck.state == .off {
            normalModeCheck.state = .on
        }
        cfg.showNormalMode = (normalModeCheck.state == .on)
        cfg.showSuperMode = (superModeCheck.state == .on)
        cfg.showResumeMode = (resumeModeCheck.state == .on)
        cfg.toolOrder = rows.map(\.entry.name)
        cfg.enabledTools = rows.filter { $0.installed && $0.enabled }.map(\.entry.name)

        appDelegate.saveMacOSConfig(cfg)
        updateMasterStatusText(menuOn: masterSwitch.state == .on)
        updateActionButtonsAndSummary()
    }

    private func persistToolsAndMacOSConfig() {
        var toolsCfg = appDelegate.loadToolsConfig() ?? HostToolsConfig(
            menuName: "VibeCode",
            menuLabel: "VibeCode",
            globalEnv: [:],
            proxy: nil,
            tools: []
        )
        toolsCfg.tools = rows
            .filter { $0.persistedInToolsJson || ($0.installed && $0.enabled) }
            .map(\.entry)
        appDelegate.saveToolsConfig(toolsCfg)
        persistMacOSConfigOnly()
    }

    private func updateActionButtonsAndSummary() {
        let idx = tableView.selectedRow
        let hasSelection = idx >= 0 && idx < rows.count
        editButton.isEnabled = hasSelection
        if hasSelection {
            let row = rows[idx]
            deleteButton.isEnabled = !row.isBuiltinPreset || row.persistedInToolsJson
            deleteButton.title = row.isBuiltinPreset ? "重置" : "删除"
        } else {
            deleteButton.isEnabled = false
            deleteButton.title = "删除"
        }
        moveUpButton.isEnabled = hasSelection && idx > 0
        moveDownButton.isEnabled = hasSelection && idx < rows.count - 1

        let enabledCount = rows.filter { $0.installed && $0.enabled }.count
        let installedCount = rows.filter(\.installed).count
        countHintLabel.stringValue = "共 \(rows.count) 款 · 已安装 \(installedCount) · 右键显示 \(enabledCount)"
    }

    // MARK: - Tab 1 交互动作

    @objc private func handleDisplayOptionChanged() {
        if masterSwitch.state == .on {
            appDelegate.ensureFinderExtensionEnabled()
        }
        persistMacOSConfigOnly()
    }

    @objc private func handleRowCheckboxToggled(_ sender: NSButton) {
        let rowIdx = sender.tag
        guard rowIdx >= 0 && rowIdx < rows.count else { return }
        guard rows[rowIdx].installed else {
            sender.state = .off
            return
        }
        let nowEnabled = (sender.state == .on)
        rows[rowIdx].enabled = nowEnabled
        if nowEnabled && !rows[rowIdx].persistedInToolsJson {
            rows[rowIdx].persistedInToolsJson = true
            persistToolsAndMacOSConfig()
        } else {
            persistMacOSConfigOnly()
        }
    }

    @objc private func handleAddTool() {
        let existingNames = Set(rows.map(\.entry.name))
        guard let result = ToolEditorPanel.present(
            parent: window,
            appDelegate: appDelegate,
            existingTool: nil,
            existingNames: existingNames
        ) else { return }

        if let iconSource = result.importedIconSource {
            appDelegate.importCustomIcon(from: iconSource, forToolName: result.entry.name)
        }

        let searchPaths = appDelegate.cliSearchPaths()
        let primaryBin = result.entry.command.split(separator: " ").first.map(String.init) ?? result.entry.command
        let installed = appDelegate.isCommandInstalled(primaryBin, in: searchPaths)

        let newRow = ToolRowModel(
            entry: result.entry,
            displaySubtitle: nil,
            isBuiltinPreset: false,
            persistedInToolsJson: true,
            installed: installed,
            enabled: installed
        )
        let insertIndex = installed ? rows.prefix(while: \.installed).count : rows.count
        rows.insert(newRow, at: insertIndex)
        persistToolsAndMacOSConfig()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: insertIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(insertIndex)
        updateActionButtonsAndSummary()
    }

    @objc private func handleEditSelected() {
        let idx = tableView.selectedRow
        guard idx >= 0 && idx < rows.count else { return }
        let current = rows[idx].entry
        var otherNames = Set(rows.map(\.entry.name))
        otherNames.remove(current.name)

        guard let result = ToolEditorPanel.present(
            parent: window,
            appDelegate: appDelegate,
            existingTool: current,
            existingNames: otherNames
        ) else { return }

        if let iconSource = result.importedIconSource {
            appDelegate.importCustomIcon(from: iconSource, forToolName: result.entry.name)
        }

        let searchPaths = appDelegate.cliSearchPaths()
        let primaryBin = result.entry.command.split(separator: " ").first.map(String.init) ?? result.entry.command
        let installed = appDelegate.isCommandInstalled(primaryBin, in: searchPaths)
        let wasEnabled = rows[idx].enabled
        rows[idx] = ToolRowModel(
            entry: result.entry,
            displaySubtitle: rows[idx].displaySubtitle,
            isBuiltinPreset: rows[idx].isBuiltinPreset,
            persistedInToolsJson: true,
            installed: installed,
            enabled: installed && wasEnabled
        )

        persistToolsAndMacOSConfig()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        updateActionButtonsAndSummary()
    }

    @objc private func handleDeleteSelected() {
        let idx = tableView.selectedRow
        guard idx >= 0 && idx < rows.count else { return }
        let row = rows[idx]
        let name = row.entry.name

        if row.isBuiltinPreset {
            guard let preset = kBuiltinAiCliPresets.first(where: { $0.name == name }) else { return }
            let confirm = NSAlert()
            confirm.alertStyle = .informational
            confirm.messageText = "重置内置工具「\(name)」？"
            confirm.informativeText = "将恢复其默认命令与参数配置。"
            confirm.addButton(withTitle: "重置")
            confirm.addButton(withTitle: "取消")
            if confirm.runModal() != .alertFirstButtonReturn {
                return
            }
            var resetEntry = preset.toToolEntry()
            resetEntry.icon = row.entry.icon
            rows[idx].entry = resetEntry
            persistToolsAndMacOSConfig()
            tableView.reloadData()
            updateActionButtonsAndSummary()
            return
        }

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "确定删除自定义工具「\(name)」吗？"
        confirm.informativeText = "这将从 tools.json 中移除该工具配置（不会卸载 CLI 本身）。"
        confirm.addButton(withTitle: "删除")
        confirm.addButton(withTitle: "取消")
        if confirm.runModal() != .alertFirstButtonReturn {
            return
        }

        rows.remove(at: idx)
        persistToolsAndMacOSConfig()
        tableView.reloadData()
        updateActionButtonsAndSummary()
    }

    @objc private func handleMoveUp() {
        let idx = tableView.selectedRow
        guard idx > 0 && idx < rows.count else { return }
        rows.swapAt(idx, idx - 1)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: idx - 1), byExtendingSelection: false)
        persistMacOSConfigOnly()
    }

    @objc private func handleMoveDown() {
        let idx = tableView.selectedRow
        guard idx >= 0 && idx < rows.count - 1 else { return }
        rows.swapAt(idx, idx + 1)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: idx + 1), byExtendingSelection: false)
        persistMacOSConfigOnly()
    }

    @objc private func handleRefreshDetection() {
        reloadAllFromDisk()
    }

    // MARK: - Tab 2 交互动作（代理与终端）

    @objc private func handleTerminalPopupChanged() {
        let idx = terminalPopup.indexOfSelectedItem
        guard idx >= 0 && idx < detectedTerminals.count else { return }
        let chosen = detectedTerminals[idx]
        var cfg = appDelegate.loadMacOSConfig()
        cfg.terminal = chosen.spec.id
        cfg.terminalAppPath = chosen.appURL.path
        appDelegate.saveMacOSConfig(cfg)
    }

    @objc private func handleRedetectTerminals() {
        reloadProxyAndTerminalTabFromDisk()
    }

    @objc private func handleReactivateExtension() {
        appDelegate.ensureFinderExtensionEnabled()
        reloadAllFromDisk()
    }

    @objc private func handleOpenSysExtSettings() {
        appDelegate.openExtensionSystemSettings()
    }

    private func updateProxyInputState() {
        let followSystem = (proxyFollowSystemCheck.state == .on)
        proxyUrlField.isEnabled = !followSystem
        fillSysProxyButton.isEnabled = !followSystem && (detectedSystemProxy != nil)
    }

    @objc private func handleFillSystemProxy() {
        detectedSystemProxy = appDelegate.detectMacOSSystemProxy()
        guard let sys = detectedSystemProxy else {
            proxyFeedbackLabel.stringValue = "未检测到系统代理"
            proxyFeedbackLabel.textColor = .systemOrange
            return
        }
        proxyFollowSystemCheck.state = .off
        proxyUrlField.stringValue = sys
        if noProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            noProxyField.stringValue = kDefaultNoProxy
        }
        proxyEnableSwitch.state = .on
        updateProxyInputState()
        saveProxyFields()
    }

    @objc private func handleProxySwitchToggled() {
        updateProxyInputState()
        saveProxyFields()
    }

    @objc private func handleProxyFollowSystemToggled() {
        updateProxyInputState()
        saveProxyFields()
    }

    @objc private func handleSaveProxy() {
        saveProxyFields()
    }

    private func normalizeProxyURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let comps = URLComponents(string: candidate),
              let scheme = comps.scheme?.lowercased(),
              ["http", "https", "socks5", "socks5h"].contains(scheme),
              let host = comps.host, !host.isEmpty,
              let port = comps.port, port > 0 else {
            return nil
        }
        return "\(scheme)://\(host):\(port)"
    }

    private func saveProxyFields() {
        let enabled = (proxyEnableSwitch.state == .on)
        let followSystem = (proxyFollowSystemCheck.state == .on)
        let rawUrl = proxyUrlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let noProxyRaw = noProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNoProxy = noProxyRaw.isEmpty ? kDefaultNoProxy : noProxyRaw

        var finalUrl = ""
        if !rawUrl.isEmpty {
            if let normalized = normalizeProxyURL(rawUrl) {
                finalUrl = normalized
                proxyUrlField.stringValue = normalized
            } else if !followSystem {
                proxyFeedbackLabel.stringValue = "代理地址格式无效（示例: http://127.0.0.1:7897）"
                proxyFeedbackLabel.textColor = .systemRed
                return
            }
        } else if enabled && !followSystem {
            proxyFeedbackLabel.stringValue = "请先填写代理地址、点击「填入系统代理」或勾选「跟随系统」"
            proxyFeedbackLabel.textColor = .systemOrange
            proxyEnableSwitch.state = .off
            return
        }

        noProxyField.stringValue = finalNoProxy
        let mode = followSystem ? "system" : "manual"
        appDelegate.updateProxyInToolsJson(enabled: enabled, mode: mode, url: finalUrl, noProxy: finalNoProxy)
        if !enabled {
            proxyFeedbackLabel.stringValue = "已停用 CLI 代理"
            proxyFeedbackLabel.textColor = .secondaryLabelColor
        } else if followSystem {
            detectedSystemProxy = appDelegate.detectMacOSSystemProxy()
            if let sys = detectedSystemProxy {
                proxyFeedbackLabel.stringValue = "已启用（跟随系统: \(sys)）"
            } else {
                proxyFeedbackLabel.stringValue = "已启用（跟随系统，当前未开启代理将直连）"
            }
            proxyFeedbackLabel.textColor = .systemGreen
        } else {
            proxyFeedbackLabel.stringValue = "已启用固定代理: \(finalUrl)"
            proxyFeedbackLabel.textColor = .systemGreen
        }
    }

    @objc private func handleTestProxy() {
        let followSystem = (proxyFollowSystemCheck.state == .on)
        let rawUrl = proxyUrlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let testUrl: String?
        if followSystem {
            testUrl = appDelegate.detectMacOSSystemProxy()
        } else if !rawUrl.isEmpty {
            testUrl = normalizeProxyURL(rawUrl)
            if testUrl == nil {
                proxyTestOutputView.string = "[错误] 代理地址格式无效: \(rawUrl)\n支持 http://、https://、socks5://"
                return
            }
        } else {
            testUrl = appDelegate.detectMacOSSystemProxy()
        }

        guard let proxyTarget = testUrl else {
            proxyTestOutputView.string = "[提示] 请先填写代理地址，或开启系统代理后再测试。"
            return
        }

        testProxyButton.isEnabled = false
        proxyTestOutputView.string = "正在通过 \(proxyTarget) 测试连通性...\n"

        let targets = [
            "https://www.google.com/generate_204",
            "https://antigravity.google",
            "https://api.anthropic.com",
            "https://api.openai.com",
        ]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lines: [String] = ["测试代理: \(proxyTarget)", ""]
            for url in targets {
                let start = Date()
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                proc.arguments = [
                    "--silent",
                    "--output", "/dev/null",
                    "--write-out", "%{http_code}",
                    "--connect-timeout", "8",
                    "--max-time", "12",
                    "--proxy", proxyTarget,
                    url,
                ]
                let outPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = Pipe()
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    let codeData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let code = String(data: codeData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if proc.terminationStatus == 0 {
                        lines.append("[OK]   \(url)  (HTTP \(code), \(ms)ms)")
                    } else {
                        lines.append("[失败] \(url)  (curl 退出码 \(proc.terminationStatus))")
                    }
                } catch {
                    lines.append("[失败] \(url)  (\(error.localizedDescription))")
                }

                let partial = lines.joined(separator: "\n")
                DispatchQueue.main.async {
                    self?.proxyTestOutputView.string = partial
                }
            }

            DispatchQueue.main.async {
                self?.testProxyButton.isEnabled = true
            }
        }
    }

    // MARK: - Tab 3 交互动作（关于与更新）

    fileprivate func applyUpdateCheckResult(_ result: UpdateCheckResult) {
        latestUpdateResult = result
        if result.hasUpdate {
            updateBannerTitleLabel.stringValue = "发现新版本 v\(result.latestVersion)（当前 v\(result.currentVersion)）"
            if let asset = result.installerAsset {
                let mb = Double(asset.size) / (1024.0 * 1024.0)
                updateBannerDetailLabel.stringValue = String(format: "匹配安装包: %@ (%.1f MB)", asset.name, mb)
                bannerOnlineUpdateBtn.isHidden = false
            } else {
                updateBannerDetailLabel.stringValue = "请点击「手动下载」前往 GitHub Releases 页面下载"
                bannerOnlineUpdateBtn.isHidden = true
            }
            updateBannerBox.isHidden = false
            updateStatusLabel.isHidden = true
        } else {
            updateBannerBox.isHidden = true
            updateStatusLabel.isHidden = false
            updateStatusLabel.stringValue = "当前已是最新版本 (v\(result.currentVersion))"
            updateStatusLabel.textColor = .systemGreen
        }
    }

    @objc private func handleCheckUpdate() {
        triggerManualUpdateCheck()
    }

    fileprivate func triggerManualUpdateCheck() {
        if isCheckingUpdate { return }
        isCheckingUpdate = true
        checkUpdateButton.isEnabled = false
        updateStatusLabel.isHidden = false
        updateStatusLabel.stringValue = "正在连接 GitHub 检查最新版本..."
        updateStatusLabel.textColor = .secondaryLabelColor

        appDelegate.checkForUpdate { [weak self] outcome in
            guard let self = self else { return }
            self.isCheckingUpdate = false
            self.checkUpdateButton.isEnabled = true

            switch outcome {
            case .success(let result):
                self.applyUpdateCheckResult(result)
                if result.hasUpdate {
                    self.presentUpdateAlert(result: result)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "当前已是最新版本"
                    alert.informativeText = "VibeCode macOS 原生版当前版本为 v\(result.currentVersion)，暂无可用更新。"
                    alert.alertStyle = .informational
                    alert.runModal()
                }
            case .failure(let error):
                self.updateStatusLabel.stringValue = "检查更新失败: \(error.localizedDescription)"
                self.updateStatusLabel.textColor = .systemRed
                let alert = NSAlert()
                alert.messageText = "检查更新失败"
                alert.informativeText = "\(error.localizedDescription)\n\n是否直接打开 GitHub Releases 网页查看？"
                alert.addButton(withTitle: "打开网页")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "\(kGitHubURLString)/releases/latest") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    @objc private func handleBannerOnlineUpdate() {
        guard let result = latestUpdateResult, result.hasUpdate else { return }
        startOnlineUpdateDownload(result: result)
    }

    @objc private func handleBannerManualDownload() {
        let urlStr = latestUpdateResult?.release.html_url ?? "\(kGitHubURLString)/releases/latest"
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func handleBannerShowNotes() {
        guard let result = latestUpdateResult, result.hasUpdate else { return }
        presentUpdateAlert(result: result)
    }

    fileprivate func presentUpdateAlert(result: UpdateCheckResult) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 v\(result.latestVersion)（当前 v\(result.currentVersion)）"
        let notes = (result.release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = notes.isEmpty ? "是否立即下载最新版本，或打开网页手动下载？" : notes
        alert.alertStyle = .informational
        if result.installerAsset != nil {
            alert.addButton(withTitle: "在线更新")
        }
        alert.addButton(withTitle: "手动下载 (网页)")
        alert.addButton(withTitle: "稍后提醒")

        let resp = alert.runModal()
        if result.installerAsset != nil {
            if resp == .alertFirstButtonReturn {
                startOnlineUpdateDownload(result: result)
            } else if resp == .alertSecondButtonReturn {
                if let url = URL(string: result.release.html_url) {
                    NSWorkspace.shared.open(url)
                }
            }
        } else if resp == .alertFirstButtonReturn {
            if let url = URL(string: result.release.html_url) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    fileprivate func startOnlineUpdateDownload(result: UpdateCheckResult) {
        guard !isDownloadingUpdate, let asset = result.installerAsset else { return }
        isDownloadingUpdate = true
        bannerOnlineUpdateBtn.isEnabled = false
        updateBannerDetailLabel.stringValue = "正在下载 \(asset.name) 并校验 SHA-256..."

        appDelegate.downloadAndVerifyUpdate(asset: asset, sha256Asset: result.sha256Asset) { [weak self] outcome in
            guard let self = self else { return }
            self.isDownloadingUpdate = false
            self.bannerOnlineUpdateBtn.isEnabled = true

            switch outcome {
            case .success(let fileURL):
                self.updateBannerDetailLabel.stringValue = "校验通过，已打开 \(fileURL.lastPathComponent)"
                NSWorkspace.shared.open(fileURL)
            case .failure(let error):
                self.updateBannerDetailLabel.stringValue = "下载失败: \(error.localizedDescription)"
                let alert = NSAlert()
                alert.messageText = "在线下载失败"
                alert.informativeText = "\(error.localizedDescription)\n\n是否改为打开网页手动下载？"
                alert.addButton(withTitle: "打开网页")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: result.release.html_url) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    @objc private func handleOpenGitHub() {
        appDelegate.openGitHubRepository()
    }

    @objc private func handleOpenConfigDir() {
        appDelegate.openSupportDirectory()
    }

    @objc private func handleEditToolsJson() {
        appDelegate.openToolsJsonInEditor()
    }

    // MARK: - NSTableViewDataSource & Delegate（含拖拽重排）

    func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let tool = item.entry
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 46))

        let dragHandle = NSTextField(labelWithString: "≡")
        dragHandle.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        dragHandle.textColor = .tertiaryLabelColor
        dragHandle.translatesAutoresizingMaskIntoConstraints = false

        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(handleRowCheckboxToggled(_:)))
        checkbox.state = (item.installed && item.enabled) ? .on : .off
        checkbox.isEnabled = item.installed
        checkbox.toolTip = item.installed ? "勾选后在访达右键菜单中显示" : "未检测到「\(tool.command)」命令，安装后点击「刷新检测」即可勾选"
        checkbox.tag = row
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        let orderText = NSTextField(labelWithString: "\(row + 1).")
        orderText.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        orderText.textColor = item.installed ? .secondaryLabelColor : .tertiaryLabelColor
        orderText.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = appDelegate.loadToolIcon(toolName: tool.name, iconFileName: tool.icon, size: 22)
        iconView.alphaValue = item.installed ? 1.0 : 0.42
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleDisplay = item.displaySubtitle.map { "\(tool.name)  (\($0))" } ?? tool.name
        let nameLabel = NSTextField(labelWithString: titleDisplay)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: item.installed ? .semibold : .regular)
        nameLabel.textColor = item.installed ? .labelColor : .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let subText: String
        if let sup = tool.superConfig {
            subText = "\(tool.command)  ·  \(sup.label)  ·  \(sup.label)-R"
        } else {
            subText = tool.command
        }
        let detailLabel = NSTextField(labelWithString: subText)
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = item.installed ? .secondaryLabelColor : .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let proxyBadge = NSTextField(labelWithString: tool.useProxy == false ? "直连" : "")
        proxyBadge.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        proxyBadge.textColor = item.installed ? .systemOrange : .tertiaryLabelColor
        proxyBadge.translatesAutoresizingMaskIntoConstraints = false

        let statusBadge = NSTextField(labelWithString: item.installed ? "已安装" : "未安装")
        statusBadge.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusBadge.textColor = item.installed ? .systemGreen : .tertiaryLabelColor
        statusBadge.translatesAutoresizingMaskIntoConstraints = false

        for sub in [dragHandle, checkbox, orderText, iconView, nameLabel, detailLabel, proxyBadge, statusBadge] {
            cell.addSubview(sub)
        }

        NSLayoutConstraint.activate([
            dragHandle.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            dragHandle.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            checkbox.leadingAnchor.constraint(equalTo: dragHandle.trailingAnchor, constant: 8),
            checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            orderText.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            orderText.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            orderText.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),

            iconView.leadingAnchor.constraint(equalTo: orderText.trailingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: proxyBadge.leadingAnchor, constant: -8),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: proxyBadge.leadingAnchor, constant: -8),

            statusBadge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            statusBadge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            proxyBadge.trailingAnchor.constraint(equalTo: statusBadge.leadingAnchor, constant: -10),
            proxyBadge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionButtonsAndSummary()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowDragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard dropOperation == .above else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row destinationRow: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let str = info.draggingPasteboard.string(forType: Self.rowDragType),
              let sourceRow = Int(str),
              sourceRow >= 0 && sourceRow < rows.count else {
            return false
        }

        let moved = rows.remove(at: sourceRow)
        let targetIndex = sourceRow < destinationRow ? max(0, destinationRow - 1) : min(destinationRow, rows.count)
        rows.insert(moved, at: targetIndex)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: targetIndex), byExtendingSelection: false)
        persistMacOSConfigOnly()
        return true
    }
}

// MARK: - 宿主 App（非沙盒）：接收 vibecode:// URL 调度终端启动，并提供菜单栏与原生设置窗口

final class VibeCodeAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var settingsController: MainSettingsWindowController?
    private let extensionBundleID = "com.vibecode.contextmenu.FinderSync"

    private let supportDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibeCode", isDirectory: true)
    }()

    private var toolsConfigURL: URL { supportDir.appendingPathComponent("tools.json") }
    private var macosConfigURL: URL { supportDir.appendingPathComponent("macos.json") }
    private var launcherURL: URL { supportDir.appendingPathComponent("launch-vibecode-tool.sh") }

    private var launchedViaURL = false
    fileprivate var cachedUpdateResult: UpdateCheckResult?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isFirstRun = ensureSupportDirectoryPrepared()
        setupStatusBarIfNeeded()
        startBackgroundUpdateCheck()
        if isFirstRun {
            ensureFinderExtensionEnabled()
            // 全新机器首次打开 .app 时自动展示设置窗口（通过 vibecode:// 唤起时除外）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self = self, !self.launchedViaURL else { return }
                self.openSettingsWindow(tab: .tools)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        launchedViaURL = true
        for url in urls {
            handleIncomingURL(url)
        }
    }

    // MARK: - URL Scheme 路由（vibecode://launch | manage | proxy | about）

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "vibecode" else { return }
        let host = (url.host ?? "").lowercased()

        switch host {
        case "launch":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            let queryItems = components.queryItems ?? []
            let tool = queryItems.first(where: { $0.name == "tool" })?.value ?? ""
            let path = queryItems.first(where: { $0.name == "path" })?.value ?? ""
            guard !tool.isEmpty, !path.isEmpty else { return }
            launchTool(toolLabel: tool, targetPath: path)
        case "manage":
            openSettingsWindow(tab: .tools)
        case "proxy":
            openSettingsWindow(tab: .proxyAndTerminal)
        case "about":
            openSettingsWindow(tab: .about)
        default:
            break
        }
    }

    private func launchTool(toolLabel: String, targetPath: String) {
        let scriptPath: String
        if FileManager.default.isExecutableFile(atPath: launcherURL.path) {
            scriptPath = launcherURL.path
        } else if let bundled = Bundle.main.resourceURL?.appendingPathComponent("launch-vibecode-tool.sh"),
                  FileManager.default.fileExists(atPath: bundled.path) {
            scriptPath = bundled.path
        } else {
            showAlert(title: "VibeCode 启动失败", message: "未找到启动器脚本: \(launcherURL.path)")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptPath, toolLabel, targetPath]
            let stderrPipe = Pipe()
            proc.standardError = stderrPipe
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "未知错误"
                    DispatchQueue.main.async {
                        self.showAlert(title: "VibeCode 启动失败", message: errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.showAlert(title: "VibeCode 启动失败", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 菜单栏托盘

    private func setupStatusBarIfNeeded() {
        let macCfg = loadMacOSConfig()
        if macCfg.showMenuBarIcon == false {
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = loadToolIcon(toolName: "VibeCode", iconFileName: "vibecode.ico", size: 18)
            button.toolTip = "VibeCode"
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toolsCfg = loadToolsConfig()
        let macCfg = loadMacOSConfig()

        // 1. 在当前 Finder 目录快速启动
        let quickLaunchItem = NSMenuItem(title: "在当前 Finder 目录启动", action: nil, keyEquivalent: "")
        quickLaunchItem.image = loadToolIcon(toolName: "VibeCode", iconFileName: "vibecode.ico", size: 16)
        let quickSub = NSMenu()
        if let cfg = toolsCfg {
            let ordered = resolveOrderedTools(from: cfg, macOS: macCfg)
            let showNormal = macCfg.showNormalMode ?? true
            let showSuper = macCfg.showSuperMode ?? true
            let showResume = macCfg.showResumeMode ?? true
            let useGrouped = (macCfg.menuLayout == "grouped") || ((macCfg.menuLayout ?? "auto") == "auto" && ordered.count > 5)

            for tool in ordered {
                var modes: [(String, String, String)] = []
                if showNormal { modes.append((tool.name, "普通模式 (\(tool.name))", tool.name)) }
                if let sup = tool.superConfig {
                    if showSuper { modes.append((sup.label, "Super 模式 (\(sup.label))", sup.label)) }
                    if showResume { modes.append(("\(sup.label)-R", "恢复会话 (\(sup.label)-R)", "\(sup.label)-R")) }
                } else if modes.isEmpty {
                    modes.append((tool.name, tool.name, tool.name))
                }

                let icon = loadToolIcon(toolName: tool.name, iconFileName: tool.icon, size: 16)
                if useGrouped && modes.count > 1 {
                    let groupItem = NSMenuItem(title: tool.name, action: nil, keyEquivalent: "")
                    groupItem.image = icon
                    let sub = NSMenu()
                    for m in modes {
                        let mi = NSMenuItem(title: m.1, action: #selector(handleQuickLaunch(_:)), keyEquivalent: "")
                        mi.target = self
                        mi.representedObject = m.2
                        mi.image = icon
                        sub.addItem(mi)
                    }
                    groupItem.submenu = sub
                    quickSub.addItem(groupItem)
                } else {
                    for m in modes {
                        let mi = NSMenuItem(title: m.0, action: #selector(handleQuickLaunch(_:)), keyEquivalent: "")
                        mi.target = self
                        mi.representedObject = m.2
                        mi.image = icon
                        quickSub.addItem(mi)
                    }
                }
            }
        }
        if quickSub.items.isEmpty {
            let empty = NSMenuItem(title: "尚未启用任何工具", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            quickSub.addItem(empty)
        }
        quickLaunchItem.submenu = quickSub
        menu.addItem(quickLaunchItem)

        menu.addItem(.separator())

        // 2. 右键菜单总开关 & 设置窗口
        let contextMenuOn = macCfg.contextMenuEnabled ?? true
        let toggleContextItem = NSMenuItem(
            title: "显示访达右键菜单",
            action: #selector(handleToggleContextMenu),
            keyEquivalent: ""
        )
        toggleContextItem.target = self
        toggleContextItem.state = contextMenuOn ? .on : .off
        menu.addItem(toggleContextItem)

        let settingsItem = NSMenuItem(
            title: "打开 VibeCode 设置...",
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // 3. 默认终端快捷切换（仅展示已检测到的终端）
        let detectedList = detectInstalledTerminals()
        let currentTerminalID = macCfg.terminal ?? "Terminal"
        let currentDisplay = detectedList.first(where: { $0.spec.id == currentTerminalID })?.spec.displayName
            ?? detectedList.first?.spec.displayName
            ?? "Terminal"
        let terminalItem = NSMenuItem(title: "默认终端: \(currentDisplay)", action: nil, keyEquivalent: "")
        let terminalSub = NSMenu()
        for candidate in detectedList {
            let item = NSMenuItem(title: candidate.spec.displayName, action: #selector(handleSelectTerminal(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.spec.id
            item.state = (candidate.spec.id == currentTerminalID) ? .on : .off
            terminalSub.addItem(item)
        }
        terminalItem.submenu = terminalSub
        menu.addItem(terminalItem)

        // 4. CLI 代理快捷切换（支持跟随系统代理与固定地址）
        let sysProxy = detectMacOSSystemProxy()
        let proxyStatusText: String
        if let proxy = toolsCfg?.proxy, proxy.enabled {
            if proxy.mode?.lowercased() == "system" {
                proxyStatusText = sysProxy != nil ? "CLI 代理: 跟随系统 (\(sysProxy!))" : "CLI 代理: 跟随系统 (当前直连)"
            } else if !proxy.url.isEmpty {
                proxyStatusText = "CLI 代理: 已启用 (\(proxy.url))"
            } else {
                proxyStatusText = "CLI 代理: 未启用"
            }
        } else {
            proxyStatusText = "CLI 代理: 未启用"
        }
        let proxyItem = NSMenuItem(title: proxyStatusText, action: nil, keyEquivalent: "")
        let proxySub = NSMenu()

        let followSysTitle = sysProxy != nil ? "跟随 macOS 系统代理 (\(sysProxy!))" : "跟随 macOS 系统代理 (当前未开启)"
        let followSysItem = NSMenuItem(title: followSysTitle, action: #selector(handleFollowSystemProxy), keyEquivalent: "")
        followSysItem.target = self
        followSysItem.state = (toolsCfg?.proxy?.enabled == true && toolsCfg?.proxy?.mode?.lowercased() == "system") ? .on : .off
        proxySub.addItem(followSysItem)

        let useSysTitle = sysProxy != nil ? "固定使用当前系统代理 (\(sysProxy!))" : "未检测到 macOS 系统代理"
        let useSysItem = NSMenuItem(title: useSysTitle, action: #selector(handleEnableSystemProxy(_:)), keyEquivalent: "")
        useSysItem.target = self
        useSysItem.representedObject = sysProxy
        useSysItem.isEnabled = (sysProxy != nil)
        proxySub.addItem(useSysItem)

        let disableProxyItem = NSMenuItem(title: "停用 CLI 代理", action: #selector(handleDisableProxy), keyEquivalent: "")
        disableProxyItem.target = self
        disableProxyItem.isEnabled = (toolsCfg?.proxy?.enabled == true)
        proxySub.addItem(disableProxyItem)

        proxySub.addItem(.separator())
        let moreProxyItem = NSMenuItem(title: "代理配置与连通性测试...", action: #selector(handleOpenProxyTab), keyEquivalent: "")
        moreProxyItem.target = self
        proxySub.addItem(moreProxyItem)

        proxyItem.submenu = proxySub
        menu.addItem(proxyItem)

        menu.addItem(.separator())

        // 5. 扩展控制、关于与退出
        let extEnabled = isFinderExtensionEnabled()
        let extTitle = extEnabled ? "Finder 扩展: 已启用（点击刷新）" : "Finder 扩展: 未启用（点击激活）"
        let extItem = NSMenuItem(title: extTitle, action: #selector(handleEnableExtension), keyEquivalent: "")
        extItem.target = self
        menu.addItem(extItem)

        let sysExtItem = NSMenuItem(title: "打开系统设置 -> 扩展...", action: #selector(handleOpenExtensionSettings), keyEquivalent: "")
        sysExtItem.target = self
        menu.addItem(sysExtItem)

        menu.addItem(.separator())

        if let found = cachedUpdateResult, found.hasUpdate {
            let updateRoot = NSMenuItem(title: "发现新版本 (v\(found.latestVersion))", action: nil, keyEquivalent: "")
            let updateSub = NSMenu()
            if found.installerAsset != nil {
                let onlineItem = NSMenuItem(title: "在线更新（下载并打开安装包）", action: #selector(handleMenuOnlineUpdate), keyEquivalent: "")
                onlineItem.target = self
                updateSub.addItem(onlineItem)
            }
            let manualItem = NSMenuItem(title: "手动下载（打开网页）", action: #selector(handleMenuManualDownload), keyEquivalent: "")
            manualItem.target = self
            updateSub.addItem(manualItem)
            updateSub.addItem(.separator())
            let notesItem = NSMenuItem(title: "查看更新日志...", action: #selector(handleMenuShowUpdateNotes), keyEquivalent: "")
            notesItem.target = self
            updateSub.addItem(notesItem)
            updateRoot.submenu = updateSub
            menu.addItem(updateRoot)
        } else {
            let checkUpdateItem = NSMenuItem(title: "检查更新...", action: #selector(handleMenuCheckUpdate), keyEquivalent: "")
            checkUpdateItem.target = self
            menu.addItem(checkUpdateItem)
        }

        let aboutItem = NSMenuItem(title: "关于 VibeCode", action: #selector(handleAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出 VibeCode", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - 菜单栏动作

    @objc private func handleToggleContextMenu() {
        var cfg = loadMacOSConfig()
        let next = !(cfg.contextMenuEnabled ?? true)
        cfg.contextMenuEnabled = next
        saveMacOSConfig(cfg)
        if next {
            ensureFinderExtensionEnabled()
        }
        if settingsController?.window?.isVisible == true {
            settingsController?.reloadAllFromDisk()
        }
    }

    @objc private func handleOpenSettings() {
        openSettingsWindow(tab: .tools)
    }

    @objc private func handleOpenProxyTab() {
        openSettingsWindow(tab: .proxyAndTerminal)
    }

    @objc private func handleAbout() {
        openSettingsWindow(tab: .about)
    }

    fileprivate func openSettingsWindow(tab: MainTabIndex) {
        if settingsController == nil {
            settingsController = MainSettingsWindowController(appDelegate: self)
        }
        settingsController?.showAndRefresh(selecting: tab)
    }

    @objc private func handleQuickLaunch(_ sender: NSMenuItem) {
        guard let toolKey = sender.representedObject as? String else { return }
        let dir = currentFinderDirectory() ?? FileManager.default.homeDirectoryForCurrentUser.path
        launchTool(toolLabel: toolKey, targetPath: dir)
    }

    @objc private func handleSelectTerminal(_ sender: NSMenuItem) {
        guard let terminalID = sender.representedObject as? String else { return }
        let matched = detectInstalledTerminals().first(where: { $0.spec.id == terminalID })
        var cfg = loadMacOSConfig()
        cfg.terminal = terminalID
        cfg.terminalAppPath = matched?.appURL.path
        saveMacOSConfig(cfg)
        if settingsController?.window?.isVisible == true {
            settingsController?.reloadAllFromDisk()
        }
    }

    @objc private func handleFollowSystemProxy() {
        updateProxyInToolsJson(enabled: true, mode: "system", url: nil, noProxy: nil)
        if settingsController?.window?.isVisible == true {
            settingsController?.reloadAllFromDisk()
        }
    }

    @objc private func handleEnableSystemProxy(_ sender: NSMenuItem) {
        guard let proxyURL = sender.representedObject as? String, !proxyURL.isEmpty else { return }
        updateProxyInToolsJson(enabled: true, mode: "manual", url: proxyURL, noProxy: nil)
        if settingsController?.window?.isVisible == true {
            settingsController?.reloadAllFromDisk()
        }
    }

    @objc private func handleMenuCheckUpdate() {
        openSettingsWindow(tab: .about)
        settingsController?.triggerManualUpdateCheck()
    }

    @objc private func handleMenuOnlineUpdate() {
        guard let found = cachedUpdateResult, found.hasUpdate else { return }
        openSettingsWindow(tab: .about)
        settingsController?.startOnlineUpdateDownload(result: found)
    }

    @objc private func handleMenuManualDownload() {
        let urlStr = cachedUpdateResult?.release.html_url ?? "\(kGitHubURLString)/releases/latest"
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func handleMenuShowUpdateNotes() {
        guard let found = cachedUpdateResult, found.hasUpdate else { return }
        openSettingsWindow(tab: .about)
        settingsController?.presentUpdateAlert(result: found)
    }

    // MARK: - GitHub Releases 自动更新检测与下载校验

    private func startBackgroundUpdateCheck() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.checkForUpdate { outcome in
                if case .success(let result) = outcome {
                    self?.settingsController?.applyUpdateCheckResult(result)
                }
            }
        }
    }

    private func resolveEffectiveProxyForRequests() -> String? {
        if let proxy = loadToolsConfig()?.proxy, proxy.enabled {
            if proxy.mode?.lowercased() == "system" {
                return detectMacOSSystemProxy()
            }
            if !proxy.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return proxy.url.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return detectMacOSSystemProxy()
    }

    private func normalizeVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private func isNewerVersion(_ latest: String, than current: String) -> Bool {
        let lClean = normalizeVersion(latest).split(separator: "-").first.map(String.init) ?? ""
        let cClean = normalizeVersion(current).split(separator: "-").first.map(String.init) ?? ""
        let lParts = lClean.split(separator: ".").compactMap { Int($0) }
        let cParts = cClean.split(separator: ".").compactMap { Int($0) }
        let count = max(lParts.count, cParts.count)
        for i in 0..<count {
            let lv = i < lParts.count ? lParts[i] : 0
            let cv = i < cParts.count ? cParts[i] : 0
            if lv != cv { return lv > cv }
        }
        let lPre = latest.contains("-")
        let cPre = current.contains("-")
        return !lPre && cPre
    }

    fileprivate func checkForUpdate(completion: @escaping (Result<UpdateCheckResult, Error>) -> Void) {
        let proxyUrl = resolveEffectiveProxyForRequests()
        let currentVersion = normalizeVersion(
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var args = [
                "--fail", "--silent", "--show-error", "--location",
                "--connect-timeout", "10", "--max-time", "15",
                "-H", "Accept: application/vnd.github+json",
                "-H", "User-Agent: VibeCodeContextMenu/\(currentVersion)",
            ]
            if let p = proxyUrl, !p.isEmpty {
                args.append(contentsOf: ["--proxy", p])
            }
            args.append("https://api.github.com/repos/myucxy/VibeCodeContextMenu/releases/latest")

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            do {
                try proc.run()
                proc.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus != 0 {
                    let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HTTP 请求失败"
                    throw NSError(domain: "VibeCodeUpdate", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
                }

                let release = try JSONDecoder().decode(GitHubReleaseInfo.self, from: data)
                let latestVersion = self.normalizeVersion(release.tag_name)
                let hasUpdate = self.isNewerVersion(latestVersion, than: currentVersion)

                let assets = release.assets ?? []
                let installer = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
                    ?? assets.first(where: { $0.name.lowercased().hasSuffix(".pkg") })
                let sha256 = installer.flatMap { inst in
                    assets.first(where: { $0.name.lowercased() == (inst.name + ".sha256").lowercased() })
                }

                let result = UpdateCheckResult(
                    hasUpdate: hasUpdate,
                    currentVersion: currentVersion,
                    latestVersion: latestVersion,
                    release: release,
                    installerAsset: installer,
                    sha256Asset: sha256
                )
                DispatchQueue.main.async {
                    self.cachedUpdateResult = result
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    fileprivate func downloadAndVerifyUpdate(
        asset: GitHubReleaseAsset,
        sha256Asset: GitHubReleaseAsset?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let proxyUrl = resolveEffectiveProxyForRequests()
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let safeName = (asset.name as NSString).lastPathComponent
        let targetURL = downloadsDir.appendingPathComponent(safeName)
        let partURL = downloadsDir.appendingPathComponent(safeName + ".part")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var args = ["--fail", "--silent", "--show-error", "--location", "--max-time", "300", "-o", partURL.path]
                if let p = proxyUrl, !p.isEmpty {
                    args.append(contentsOf: ["--proxy", p])
                }
                args.append(asset.browser_download_url)

                let dlProc = Process()
                dlProc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                dlProc.arguments = args
                let dlErr = Pipe()
                dlProc.standardError = dlErr
                try dlProc.run()
                dlProc.waitUntilExit()
                if dlProc.terminationStatus != 0 {
                    let msg = String(data: dlErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "下载失败"
                    throw NSError(domain: "VibeCodeUpdate", code: Int(dlProc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])
                }

                if let sha = sha256Asset {
                    var shaArgs = ["--fail", "--silent", "--location", "--max-time", "20"]
                    if let p = proxyUrl, !p.isEmpty {
                        shaArgs.append(contentsOf: ["--proxy", p])
                    }
                    shaArgs.append(sha.browser_download_url)
                    let shaProc = Process()
                    shaProc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    shaProc.arguments = shaArgs
                    let shaPipe = Pipe()
                    shaProc.standardOutput = shaPipe
                    try shaProc.run()
                    shaProc.waitUntilExit()
                    if shaProc.terminationStatus == 0 {
                        let shaStr = String(data: shaPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        let expected = shaStr.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                        if expected.count == 64 {
                            let hashProc = Process()
                            hashProc.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
                            hashProc.arguments = ["-a", "256", partURL.path]
                            let hashPipe = Pipe()
                            hashProc.standardOutput = hashPipe
                            try hashProc.run()
                            hashProc.waitUntilExit()
                            let actualOut = String(data: hashPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                            let actual = actualOut.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                            if actual.lowercased() != expected.lowercased() {
                                try? FileManager.default.removeItem(at: partURL)
                                throw NSError(domain: "VibeCodeUpdate", code: -2, userInfo: [NSLocalizedDescriptionKey: "SHA-256 校验失败，已删除损坏文件"])
                            }
                        }
                    }
                }

                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.moveItem(at: partURL, to: targetURL)

                DispatchQueue.main.async {
                    completion(.success(targetURL))
                }
            } catch {
                try? FileManager.default.removeItem(at: partURL)
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    @objc private func handleDisableProxy() {
        updateProxyInToolsJson(enabled: false, url: nil, noProxy: nil)
        if settingsController?.window?.isVisible == true {
            settingsController?.reloadAllFromDisk()
        }
    }

    @objc private func handleEnableExtension() {
        ensureFinderExtensionEnabled()
        if settingsController?.window?.isVisible == true {
            settingsController?.reloadAllFromDisk()
        }
    }

    func ensureFinderExtensionEnabled() {
        let appexPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/VibeCodeFinderSync.appex").path
        runCommand("/usr/bin/pluginkit", args: ["-a", appexPath])
        runCommand("/usr/bin/pluginkit", args: ["-e", "use", "-i", extensionBundleID])
    }

    @objc private func handleOpenExtensionSettings() {
        openExtensionSystemSettings()
    }

    func openExtensionSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.FinderSync",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func openGitHubRepository() {
        if let url = URL(string: kGitHubURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    func openSupportDirectory() {
        NSWorkspace.shared.open(supportDir)
    }

    func openToolsJsonInEditor() {
        NSWorkspace.shared.open(toolsConfigURL)
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - 图标导入与渲染

    func importCustomIcon(from sourceURL: URL, forToolName toolName: String) {
        guard let image = NSImage(contentsOf: sourceURL) else { return }
        let safeStem = toolName.lowercased().replacingOccurrences(of: " ", with: "-")
        let iconsDir = supportDir.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
        let dest = iconsDir.appendingPathComponent("\(safeStem).png")

        let size = 64
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }

        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        image.draw(in: NSRect(origin: .zero, size: rep.size))
        NSGraphicsContext.restoreGraphicsState()

        if let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: dest)
        }
    }

    func loadToolIcon(toolName: String, iconFileName: String?, size: CGFloat) -> NSImage {
        var candidates: [URL] = []
        if let iconFileName = iconFileName, !iconFileName.isEmpty {
            let stem = URL(fileURLWithPath: iconFileName).deletingPathExtension().lastPathComponent
            candidates.append(supportDir.appendingPathComponent("icons/\(stem).png"))
            if let res = Bundle.main.resourceURL {
                candidates.append(res.appendingPathComponent("icons/\(stem).png"))
            }
        }
        let safeStem = toolName.lowercased().replacingOccurrences(of: " ", with: "-")
        candidates.append(supportDir.appendingPathComponent("icons/\(safeStem).png"))

        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path),
               let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: size, height: size)
                return img
            }
        }
        return renderBrandBadgeIcon(for: toolName, size: size)
    }

    private func renderBrandBadgeIcon(for name: String, size: CGFloat) -> NSImage {
        let key = name.lowercased()
        let palette: [String: (NSColor, String)] = [
            "gemini": (NSColor(calibratedRed: 0.26, green: 0.52, blue: 0.96, alpha: 1), "G"),
            "qwen": (NSColor(calibratedRed: 0.39, green: 0.34, blue: 0.95, alpha: 1), "Q"),
            "kimi": (NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 1), "K"),
            "copilot": (NSColor(calibratedRed: 0.48, green: 0.29, blue: 0.88, alpha: 1), "CP"),
            "cursor": (NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.18, alpha: 1), "CR"),
            "cursor-agent": (NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.18, alpha: 1), "CR"),
            "aider": (NSColor(calibratedRed: 0.11, green: 0.67, blue: 0.44, alpha: 1), "Ai"),
            "kiro": (NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.90, alpha: 1), "Ki"),
            "cline": (NSColor(calibratedRed: 0.08, green: 0.56, blue: 0.78, alpha: 1), "CL"),
            "amp": (NSColor(calibratedRed: 0.92, green: 0.34, blue: 0.20, alpha: 1), "A"),
            "goose": (NSColor(calibratedRed: 0.18, green: 0.45, blue: 0.68, alpha: 1), "GS"),
            "auggie": (NSColor(calibratedRed: 0.20, green: 0.60, blue: 0.54, alpha: 1), "Au"),
            "crush": (NSColor(calibratedRed: 0.85, green: 0.24, blue: 0.48, alpha: 1), "CR"),
            "codebuddy": (NSColor(calibratedRed: 0.05, green: 0.48, blue: 0.95, alpha: 1), "CB"),
            "vibe": (NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.12, alpha: 1), "V"),
            "droid": (NSColor(calibratedRed: 0.25, green: 0.28, blue: 0.35, alpha: 1), "DR"),
        ]

        let bgColor: NSColor
        let text: String
        if let hit = palette[key] {
            bgColor = hit.0
            text = hit.1
        } else {
            let fallbackColors: [NSColor] = [
                NSColor(calibratedRed: 0.24, green: 0.49, blue: 0.92, alpha: 1),
                NSColor(calibratedRed: 0.14, green: 0.64, blue: 0.47, alpha: 1),
                NSColor(calibratedRed: 0.56, green: 0.32, blue: 0.86, alpha: 1),
                NSColor(calibratedRed: 0.88, green: 0.42, blue: 0.18, alpha: 1),
                NSColor(calibratedRed: 0.12, green: 0.57, blue: 0.72, alpha: 1),
                NSColor(calibratedRed: 0.78, green: 0.26, blue: 0.48, alpha: 1),
            ]
            let hash = key.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
            bgColor = fallbackColors[abs(hash) % fallbackColors.count]
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            text = clean.isEmpty ? "AI" : String(clean.prefix(2)).uppercased()
        }

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let radius = rect.width * 0.24
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            bgColor.setFill()
            path.fill()

            let fontSize = text.count >= 2 ? rect.height * 0.44 : rect.height * 0.56
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let attrStr = NSAttributedString(string: text, attributes: attrs)
            let strSize = attrStr.size()
            let drawRect = NSRect(
                x: (rect.width - strSize.width) / 2.0,
                y: (rect.height - strSize.height) / 2.0 - 0.5,
                width: strSize.width,
                height: strSize.height
            )
            attrStr.draw(in: drawRect)
            return true
        }
        image.size = NSSize(width: size, height: size)
        return image
    }

    // MARK: - 系统环境探测与配置同步

    func cliSearchPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs: [String] = [
            "\(home)/.local/bin",
            "\(home)/.opencode/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for v in versions.sorted().reversed() {
                dirs.append("\(nvmRoot)/\(v)/bin")
            }
        }
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: envPath.split(separator: ":").map(String.init))
        }
        return dirs
    }

    func isCommandInstalled(_ command: String, in dirs: [String]) -> Bool {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command)
        }
        for dir in dirs {
            let full = (dir as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: full) {
                return true
            }
        }
        return false
    }

    private func currentFinderDirectory() -> String? {
        let script = """
        tell application "Finder"
            if (count of Finder windows) > 0 then
                return POSIX path of (target of front Finder window as alias)
            else
                return POSIX path of (insertion location as alias)
            end if
        end tell
        """
        guard let output = runCommandOutput("/usr/bin/osascript", args: ["-e", script]) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate func detectInstalledTerminals() -> [DetectedTerminal] {
        let fm = FileManager.default
        let homeApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let searchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeApps,
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        ]

        var detected: [DetectedTerminal] = []
        for spec in kSupportedTerminals {
            var foundURL: URL? = nil
            // 1. 优先通过 Bundle ID 经 LaunchServices 全盘检测（不受安装目录或改名限制）
            for bid in spec.bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
                   fm.fileExists(atPath: url.path) {
                    foundURL = url
                    break
                }
            }
            // 2. 回退到常见目录检测
            if foundURL == nil {
                outer: for root in searchRoots {
                    for appName in spec.fallbackAppNames {
                        let candidate = root.appendingPathComponent(appName, isDirectory: true)
                        if fm.fileExists(atPath: candidate.path) {
                            foundURL = candidate
                            break outer
                        }
                    }
                }
            }
            if let url = foundURL {
                detected.append(DetectedTerminal(spec: spec, appURL: url))
            }
        }
        return detected
    }

    func detectMacOSSystemProxy() -> String? {
        guard let output = runCommandOutput("/usr/sbin/scutil", args: ["--proxy"]) else {
            return nil
        }
        var dict: [String: String] = [:]
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                dict[key] = val
            }
        }
        if dict["HTTPSEnable"] == "1", let host = dict["HTTPSProxy"], let port = dict["HTTPSPort"], !host.isEmpty {
            return "http://\(host):\(port)"
        }
        if dict["HTTPEnable"] == "1", let host = dict["HTTPProxy"], let port = dict["HTTPPort"], !host.isEmpty {
            return "http://\(host):\(port)"
        }
        if dict["SOCKSEnable"] == "1", let host = dict["SOCKSProxy"], let port = dict["SOCKSPort"], !host.isEmpty {
            return "socks5://\(host):\(port)"
        }
        return nil
    }

    func updateProxyInToolsJson(enabled: Bool, mode: String? = nil, url: String?, noProxy: String?) {
        let targets = toolsJsonSyncTargets()
        let script = """
        import json, sys
        enabled = sys.argv[1] == "1"
        mode_arg = sys.argv[2]
        url = sys.argv[3]
        no_proxy_arg = sys.argv[4]
        paths = sys.argv[5:]
        for p in paths:
            with open(p, "r", encoding="utf-8-sig") as f:
                data = json.load(f)
            proxy = data.get("proxy") if isinstance(data.get("proxy"), dict) else {}
            final_mode = mode_arg if mode_arg else (proxy.get("mode") or "manual")
            final_url = url if url else proxy.get("url", "")
            final_no_proxy = no_proxy_arg if no_proxy_arg else (proxy.get("noProxy") or "localhost,127.0.0.1,::1")
            data["proxy"] = {
                "enabled": enabled,
                "mode": final_mode,
                "url": final_url,
                "noProxy": final_no_proxy,
            }
            with open(p, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
                f.write("\\n")
        """
        var args = ["-c", script, enabled ? "1" : "0", mode ?? "", url ?? "", noProxy ?? ""]
        args.append(contentsOf: targets.map(\.path))
        runCommand("/usr/bin/python3", args: args)
    }

    private func toolsJsonSyncTargets() -> [URL] {
        var list = [toolsConfigURL]
        if let proj = loadMacOSConfig().projectDir {
            let projTools = URL(fileURLWithPath: proj).appendingPathComponent("tools.json")
            if FileManager.default.fileExists(atPath: projTools.path) {
                list.append(projTools)
            }
        }
        return list
    }

    func isFinderExtensionEnabled() -> Bool {
        guard let output = runCommandOutput("/usr/bin/pluginkit", args: ["-m", "-p", "com.apple.FinderSync"]) else {
            return false
        }
        for line in output.components(separatedBy: "\n") {
            if line.contains(extensionBundleID) {
                return line.trimmingCharacters(in: .whitespaces).hasPrefix("+")
            }
        }
        return false
    }

    @discardableResult
    private func ensureSupportDirectoryPrepared() -> Bool {
        let fm = FileManager.default
        let isFirstRun = !fm.fileExists(atPath: macosConfigURL.path)

        let iconsDir = supportDir.appendingPathComponent("icons", isDirectory: true)
        try? fm.createDirectory(at: iconsDir, withIntermediateDirectories: true)

        // 1. 释放/更新内置启动器脚本，保证升级新版 .app 后启动器同步最新
        if let bundledLauncher = Bundle.main.resourceURL?.appendingPathComponent("launch-vibecode-tool.sh"),
           fm.fileExists(atPath: bundledLauncher.path) {
            try? fm.removeItem(at: launcherURL)
            try? fm.copyItem(at: bundledLauncher, to: launcherURL)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)
        }

        // 2. 释放内置官方图标（已存在则不覆盖用户自定义图标）
        if let bundledIconsDir = Bundle.main.resourceURL?.appendingPathComponent("icons", isDirectory: true),
           let iconItems = try? fm.contentsOfDirectory(at: bundledIconsDir, includingPropertiesForKeys: nil) {
            for src in iconItems where src.pathExtension.lowercased() == "png" {
                let dst = iconsDir.appendingPathComponent(src.lastPathComponent)
                if !fm.fileExists(atPath: dst.path) {
                    try? fm.copyItem(at: src, to: dst)
                }
            }
        }

        // 3. 首次运行释放默认 tools.json
        if !fm.fileExists(atPath: toolsConfigURL.path),
           let bundledTools = Bundle.main.url(forResource: "tools", withExtension: "json") {
            try? fm.copyItem(at: bundledTools, to: toolsConfigURL)
        }

        // 4. 首次运行自动探测本机已安装的 AI CLI 与终端，初始化 macos.json
        if isFirstRun {
            let searchPaths = cliSearchPaths()
            let toolsCfg = loadToolsConfig()
            let configuredTools = toolsCfg?.tools ?? []
            var detectedEnabled: [String] = []
            for t in configuredTools {
                let bin = t.command.split(separator: " ").first.map(String.init) ?? t.command
                if isCommandInstalled(bin, in: searchPaths) {
                    detectedEnabled.append(t.name)
                }
            }
            // 也顺便检测其余 19 款内置预设，若新机器装了 gemini/qwen/kimi 等也直接自动加入
            let existingSet = Set(configuredTools.map(\.name))
            var extraToolsToPersist: [HostToolEntry] = []
            for preset in kBuiltinAiCliPresets where !existingSet.contains(preset.name) {
                let bin = preset.command.split(separator: " ").first.map(String.init) ?? preset.command
                if isCommandInstalled(bin, in: searchPaths) {
                    extraToolsToPersist.append(preset.toToolEntry())
                    detectedEnabled.append(preset.name)
                }
            }
            if !extraToolsToPersist.isEmpty, var cfg = toolsCfg {
                cfg.tools.append(contentsOf: extraToolsToPersist)
                saveToolsConfig(cfg)
            }

            let firstTerminal = detectInstalledTerminals().first
            let initialMacCfg = HostMacOSConfig(
                enabledTools: detectedEnabled,
                toolOrder: nil,
                contextMenuEnabled: true,
                menuLayout: "auto",
                showNormalMode: true,
                showSuperMode: true,
                showResumeMode: true,
                terminal: firstTerminal?.spec.id ?? "Terminal",
                terminalAppPath: firstTerminal?.appURL.path,
                showMenuBarIcon: true,
                projectDir: nil
            )
            saveMacOSConfig(initialMacCfg)
        }

        return isFirstRun
    }

    private func stripUTF8BOM(_ data: Data) -> Data {
        if data.count >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
            return data.subdata(in: 3..<data.count)
        }
        return data
    }

    fileprivate func loadToolsConfig() -> HostToolsConfig? {
        guard let data = try? Data(contentsOf: toolsConfigURL) else { return nil }
        return try? JSONDecoder().decode(HostToolsConfig.self, from: stripUTF8BOM(data))
    }

    fileprivate func saveToolsConfig(_ cfg: HostToolsConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(cfg),
              var jsonStr = String(data: data, encoding: .utf8) else { return }
        jsonStr = jsonStr.replacingOccurrences(of: "\\/", with: "/") + "\n"
        guard let outData = jsonStr.data(using: .utf8) else { return }

        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        for target in toolsJsonSyncTargets() {
            try? outData.write(to: target)
        }
    }

    fileprivate func loadMacOSConfig() -> HostMacOSConfig {
        guard let data = try? Data(contentsOf: macosConfigURL),
              let cfg = try? JSONDecoder().decode(HostMacOSConfig.self, from: stripUTF8BOM(data)) else {
            return HostMacOSConfig(
                enabledTools: nil,
                toolOrder: nil,
                contextMenuEnabled: true,
                menuLayout: "auto",
                showNormalMode: true,
                showSuperMode: true,
                showResumeMode: true,
                terminal: "Terminal",
                terminalAppPath: nil,
                showMenuBarIcon: true,
                projectDir: nil
            )
        }
        return cfg
    }

    fileprivate func saveMacOSConfig(_ cfg: HostMacOSConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cfg) {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? data.write(to: macosConfigURL)
        }
    }

    private func resolveOrderedTools(from config: HostToolsConfig, macOS: HostMacOSConfig) -> [HostToolEntry] {
        guard let enabled = macOS.enabledTools else {
            return config.tools
        }
        let byName = Dictionary(uniqueKeysWithValues: config.tools.map { ($0.name, $0) })
        return enabled.compactMap { byName[$0] }
    }

    @discardableResult
    private func runCommand(_ executable: String, args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }

    private func runCommandOutput(_ executable: String, args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - 入口点

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = VibeCodeAppDelegate()
app.delegate = delegate
app.run()

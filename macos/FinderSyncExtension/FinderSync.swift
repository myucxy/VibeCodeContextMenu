import AppKit
import FinderSync
import Foundation
import os.log

// MARK: - 配置模型（完全兼容项目根目录 tools.json）

private struct ToolsConfig: Decodable {
    let menuName: String?
    let menuLabel: String?
    let tools: [ToolEntry]
}

private struct ToolEntry: Decodable {
    let name: String
    let command: String
    let icon: String?
    let superConfig: SuperEntry?

    enum CodingKeys: String, CodingKey {
        case name
        case command
        case icon
        case superConfig = "super"
    }
}

private struct SuperEntry: Decodable {
    let command: String
    let label: String
    let resume: ResumeEntry?
}

private struct ResumeEntry: Decodable {
    let command: String?
}

private struct MacOSConfig: Decodable {
    let enabledTools: [String]?
    let contextMenuEnabled: Bool?
    /// "auto"（默认，>5 个工具时自动折叠） | "flat"（平铺） | "grouped"（按工具折叠二级子菜单）
    let menuLayout: String?
    let showNormalMode: Bool?
    let showSuperMode: Bool?
    let showResumeMode: Bool?
}

private struct ResolvedModeItem {
    let flatLabel: String
    let groupedLabel: String
    let toolKey: String
}

private struct ResolvedToolGroup {
    let name: String
    let iconFileName: String?
    let modes: [ResolvedModeItem]
}

private struct ClickActionRecord {
    let toolKey: String
    let preferContainerDirectory: Bool
}

// MARK: - FinderSync 扩展主类

final class FinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "com.vibecode.contextmenu.FinderSync", category: "Menu")
    private var cachedToolsMTime: Date?
    private var cachedMacOSMTime: Date?
    private var cachedConfig: ToolsConfig?
    private var cachedMacOSConfig: MacOSConfig?
    private var iconCache: [String: NSImage] = [:]

    // FIFinderSync 的 NSMenu 会跨 XPC 序列化给 Finder，representedObject 会被丢弃为 nil，
    // 只有 tag / title / action 会跨进程保留，因此必须使用 tag 映射表记录动作参数。
    private var nextActionTag: Int = 1000
    private var actionTable: [Int: ClickActionRecord] = [:]

    private lazy var supportDir: URL = {
        FinderSync.realHomeDirectory()
            .appendingPathComponent("Library/Application Support/VibeCode", isDirectory: true)
    }()

    override init() {
        super.init()
        refreshWatchedDirectories()

        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            self,
            selector: #selector(handleVolumeChange(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(handleVolumeChange(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // 沙盒内 NSHomeDirectory() 指向容器目录，需通过 POSIX passwd 读取真实用户主目录
    private static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    @objc private func handleVolumeChange(_ notification: Notification) {
        refreshWatchedDirectories()
    }

    private func refreshWatchedDirectories() {
        var urls: Set<URL> = [URL(fileURLWithPath: "/", isDirectory: true)]
        if let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsBrowsableKey],
            options: [.skipHiddenVolumes]
        ) {
            for volumeURL in mounted {
                urls.insert(volumeURL)
            }
        }
        FIFinderSyncController.default().directoryURLs = urls
    }

    // MARK: - 右键菜单构建（不在访达工具栏默认添加按钮）

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        switch menuKind {
        case .contextualMenuForItems,
             .contextualMenuForContainer,
             .contextualMenuForSidebar:
            break
        case .toolbarItemMenu:
            return nil
        @unknown default:
            return nil
        }

        guard let config = loadConfig() else {
            return nil
        }

        let macOSCfg = loadMacOSConfig()
        if macOSCfg?.contextMenuEnabled == false {
            return nil
        }

        let groups = buildToolGroups(from: config, macOS: macOSCfg)
        guard !groups.isEmpty else {
            return nil
        }

        let layout = (macOSCfg?.menuLayout ?? "auto").lowercased()
        let useGrouped: Bool
        switch layout {
        case "grouped":
            useGrouped = true
        case "flat":
            useGrouped = false
        default:
            // auto：启用超过 5 个工具或总条目超过 15 条时自动按工具折叠，保持菜单整洁
            let totalEntries = groups.reduce(0) { $0 + $1.modes.count }
            useGrouped = groups.count > 5 || totalEntries > 15
        }

        let preferContainer = (menuKind == .contextualMenuForContainer)
        let submenu = NSMenu(title: config.menuLabel ?? "VibeCode")

        // 控制映射表大小，保留最近生成的菜单项映射
        if actionTable.count > 400 {
            actionTable.removeAll()
            nextActionTag = 1000
        }

        func registerAction(toolKey: String) -> Int {
            let tag = nextActionTag
            nextActionTag += 1
            actionTable[tag] = ClickActionRecord(
                toolKey: toolKey,
                preferContainerDirectory: preferContainer
            )
            return tag
        }

        if useGrouped {
            for group in groups {
                let icon = loadToolIcon(toolName: group.name, iconFileName: group.iconFileName, size: 16)
                if group.modes.count == 1, let only = group.modes.first {
                    let item = NSMenuItem(
                        title: only.flatLabel,
                        action: #selector(handleToolMenuClick(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.tag = registerAction(toolKey: only.toolKey)
                    item.image = icon
                    submenu.addItem(item)
                } else {
                    let groupItem = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
                    groupItem.image = icon
                    let childMenu = NSMenu(title: group.name)
                    for mode in group.modes {
                        let modeItem = NSMenuItem(
                            title: mode.groupedLabel,
                            action: #selector(handleToolMenuClick(_:)),
                            keyEquivalent: ""
                        )
                        modeItem.target = self
                        modeItem.tag = registerAction(toolKey: mode.toolKey)
                        modeItem.image = icon
                        childMenu.addItem(modeItem)
                    }
                    groupItem.submenu = childMenu
                    submenu.addItem(groupItem)
                }
            }
        } else {
            for group in groups {
                let icon = loadToolIcon(toolName: group.name, iconFileName: group.iconFileName, size: 16)
                for mode in group.modes {
                    let menuItem = NSMenuItem(
                        title: mode.flatLabel,
                        action: #selector(handleToolMenuClick(_:)),
                        keyEquivalent: ""
                    )
                    menuItem.target = self
                    menuItem.tag = registerAction(toolKey: mode.toolKey)
                    menuItem.image = icon
                    submenu.addItem(menuItem)
                }
            }
        }

        submenu.addItem(.separator())
        let manageItem = NSMenuItem(
            title: "管理 VibeCode...",
            action: #selector(handleManageClick(_:)),
            keyEquivalent: ""
        )
        manageItem.target = self
        if let gear = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil) {
            gear.size = NSSize(width: 15, height: 15)
            manageItem.image = gear
        }
        submenu.addItem(manageItem)

        // 右键菜单生成一级级联菜单项 "VibeCode > ..."
        let rootMenu = NSMenu(title: "")
        let parentItem = NSMenuItem(
            title: config.menuLabel ?? "VibeCode",
            action: nil,
            keyEquivalent: ""
        )
        parentItem.image = loadToolIcon(toolName: "VibeCode", iconFileName: "vibecode.ico", size: 16)
        parentItem.submenu = submenu
        rootMenu.addItem(parentItem)
        return rootMenu
    }

    // MARK: - 菜单动作

    @objc private func handleToolMenuClick(_ sender: NSMenuItem) {
        let toolKey: String
        let preferContainer: Bool

        if let record = actionTable[sender.tag] {
            toolKey = record.toolKey
            preferContainer = record.preferContainerDirectory
        } else {
            // 兜底：若从折叠标题 "Super 模式 (claudeSuper)" 触发，提取括号内 toolKey，否则直接用 title
            let title = sender.title
            if let openParen = title.lastIndex(of: "("),
               let closeParen = title.lastIndex(of: ")"),
               openParen < closeParen {
                toolKey = String(title[title.index(after: openParen)..<closeParen])
            } else {
                toolKey = title
            }
            preferContainer = false
        }

        guard let targetDir = resolveTargetDirectory(preferContainer: preferContainer) else {
            logger.error("Failed to resolve target directory for tool: \(toolKey, privacy: .public)")
            return
        }

        var components = URLComponents()
        components.scheme = "vibecode"
        components.host = "launch"
        components.queryItems = [
            URLQueryItem(name: "tool", value: toolKey),
            URLQueryItem(name: "path", value: targetDir.path),
        ]
        guard let launchURL = components.url else { return }
        logger.info("Launching tool=\(toolKey, privacy: .public) path=\(targetDir.path, privacy: .public)")
        openInHostApp(launchURL)
    }

    @objc private func handleManageClick(_ sender: NSMenuItem) {
        guard let url = URL(string: "vibecode://manage") else { return }
        openInHostApp(url)
    }

    private func resolveTargetDirectory(preferContainer: Bool) -> URL? {
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs()?.first
        let targeted = controller.targetedURL()

        let rawURL: URL?
        if preferContainer {
            rawURL = targeted ?? selected
        } else {
            rawURL = selected ?? targeted
        }
        guard let url = rawURL else { return nil }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue ? url : url.deletingLastPathComponent()
        }
        return url
    }

    private func openInHostApp(_ url: URL) {
        // 沙盒内通过自定义 URL Scheme 直接调用 NSWorkspace.shared.open(url) 是最可靠且无权限拦截的方式
        DispatchQueue.main.async {
            let ok = NSWorkspace.shared.open(url)
            if !ok {
                self.logger.error("NSWorkspace.shared.open failed for url: \(url.absoluteString, privacy: .public)")
            }
        }
    }

    // MARK: - 配置读取（热更新 + Bundle 兜底）

    private func stripUTF8BOM(_ data: Data) -> Data {
        if data.count >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
            return data.subdata(in: 3..<data.count)
        }
        return data
    }

    private func loadConfig() -> ToolsConfig? {
        let userFile = supportDir.appendingPathComponent("tools.json")
        if let mtime = fileModificationDate(userFile) {
            if cachedToolsMTime == mtime, let cached = cachedConfig {
                return cached
            }
            if let data = try? Data(contentsOf: userFile),
               let parsed = try? JSONDecoder().decode(ToolsConfig.self, from: stripUTF8BOM(data)) {
                cachedToolsMTime = mtime
                cachedConfig = parsed
                // 配置变更时顺带刷新图标缓存，确保导入的新图标立即生效
                iconCache.removeAll()
                return parsed
            }
        }

        if let cached = cachedConfig {
            return cached
        }
        if let bundleFile = Bundle.main.url(forResource: "tools", withExtension: "json"),
           let data = try? Data(contentsOf: bundleFile),
           let parsed = try? JSONDecoder().decode(ToolsConfig.self, from: stripUTF8BOM(data)) {
            cachedConfig = parsed
            return parsed
        }
        return nil
    }

    private func loadMacOSConfig() -> MacOSConfig? {
        let userFile = supportDir.appendingPathComponent("macos.json")
        guard let mtime = fileModificationDate(userFile) else {
            cachedMacOSMTime = nil
            cachedMacOSConfig = nil
            return nil
        }
        if cachedMacOSMTime == mtime {
            return cachedMacOSConfig
        }
        if let data = try? Data(contentsOf: userFile),
           let parsed = try? JSONDecoder().decode(MacOSConfig.self, from: stripUTF8BOM(data)) {
            cachedMacOSMTime = mtime
            cachedMacOSConfig = parsed
            return parsed
        }
        return nil
    }

    private func buildToolGroups(from config: ToolsConfig, macOS: MacOSConfig?) -> [ResolvedToolGroup] {
        let orderedTools: [ToolEntry]
        if let enabled = macOS?.enabledTools {
            if enabled.isEmpty {
                return []
            }
            let byName = Dictionary(uniqueKeysWithValues: config.tools.map { ($0.name, $0) })
            orderedTools = enabled.compactMap { byName[$0] }
        } else {
            orderedTools = config.tools
        }

        let showNormal = macOS?.showNormalMode ?? true
        let showSuper = macOS?.showSuperMode ?? true
        let showResume = macOS?.showResumeMode ?? true

        var groups: [ResolvedToolGroup] = []
        for tool in orderedTools {
            var modes: [ResolvedModeItem] = []
            if showNormal {
                modes.append(ResolvedModeItem(
                    flatLabel: tool.name,
                    groupedLabel: "普通模式 (\(tool.name))",
                    toolKey: tool.name
                ))
            }
            if let sup = tool.superConfig {
                if showSuper {
                    modes.append(ResolvedModeItem(
                        flatLabel: sup.label,
                        groupedLabel: "Super 模式 (\(sup.label))",
                        toolKey: sup.label
                    ))
                }
                if showResume {
                    modes.append(ResolvedModeItem(
                        flatLabel: "\(sup.label)-R",
                        groupedLabel: "恢复会话 (\(sup.label)-R)",
                        toolKey: "\(sup.label)-R"
                    ))
                }
            } else if modes.isEmpty {
                // 没有 super 配置的工具，即使关闭了普通模式也保留其唯一启动项，避免工具彻底消失
                modes.append(ResolvedModeItem(
                    flatLabel: tool.name,
                    groupedLabel: tool.name,
                    toolKey: tool.name
                ))
            }

            if !modes.isEmpty {
                groups.append(ResolvedToolGroup(
                    name: tool.name,
                    iconFileName: tool.icon,
                    modes: modes
                ))
            }
        }
        return groups
    }

    // MARK: - 图标加载与品牌色圆角徽标兜底

    private func loadToolIcon(toolName: String, iconFileName: String?, size: CGFloat) -> NSImage {
        let cacheKey = "\(toolName)_\(iconFileName ?? "")_\(Int(size))"
        if let cached = iconCache[cacheKey] {
            return cached
        }

        var candidates: [URL] = []
        if let iconFileName = iconFileName, !iconFileName.isEmpty {
            let stem = URL(fileURLWithPath: iconFileName).deletingPathExtension().lastPathComponent
            candidates.append(supportDir.appendingPathComponent("icons/\(stem).png"))
            if let res = Bundle.main.resourceURL {
                candidates.append(res.appendingPathComponent("icons/\(stem).png"))
            }
            candidates.append(supportDir.appendingPathComponent("icons/\(iconFileName)"))
            if let res = Bundle.main.resourceURL {
                candidates.append(res.appendingPathComponent("icons/\(iconFileName)"))
            }
        }
        // 也允许按工具名小写匹配自定义上传的 icons/<toolname>.png
        let safeStem = toolName.lowercased().replacingOccurrences(of: " ", with: "-")
        candidates.append(supportDir.appendingPathComponent("icons/\(safeStem).png"))

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path),
               let img = NSImage(contentsOf: candidate) {
                img.size = NSSize(width: size, height: size)
                iconCache[cacheKey] = img
                return img
            }
        }

        let badge = renderBrandBadgeIcon(for: toolName, size: size)
        iconCache[cacheKey] = badge
        return badge
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

    private func fileModificationDate(_ url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }
}

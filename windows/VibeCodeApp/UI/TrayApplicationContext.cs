using System.IO.Pipes;
using VibeCodeApp.Models;
using VibeCodeApp.Services;

namespace VibeCodeApp.UI;

/// <summary>
/// 系统托盘驻留上下文 + 命名管道单实例激活监听。
/// </summary>
public sealed class TrayApplicationContext : ApplicationContext
{
    public const string PipeName = "VibeCodeContextMenu_IPC_v1";

    private readonly NotifyIcon _notifyIcon;
    private readonly ContextMenuStrip _trayMenu;
    private readonly MainSettingsForm _settingsForm;
    private readonly CancellationTokenSource _ipcCts = new();

    public TrayApplicationContext(MainTabIndex? openTabOnStart)
    {
        _settingsForm = new MainSettingsForm();
        // 强制提前创建窗体句柄，确保以 --tray 静默启动时后台 IPC 线程调用 BeginInvoke 不会报错
        _ = _settingsForm.Handle;

        _trayMenu = new ContextMenuStrip();
        _trayMenu.Opening += (_, _) => RebuildTrayMenu();

        _notifyIcon = new NotifyIcon
        {
            Icon = IconService.LoadMainAppIcon(),
            Text = $"VibeCode v{AppPaths.AppVersion}",
            ContextMenuStrip = _trayMenu,
            Visible = true
        };
        _notifyIcon.DoubleClick += (_, _) => _settingsForm.ShowAndSelectTab(MainTabIndex.Tools);

        StartIpcServer();

        if (openTabOnStart.HasValue)
        {
            _settingsForm.ShowAndSelectTab(openTabOnStart.Value);
        }
    }

    private void RebuildTrayMenu()
    {
        _trayMenu.Items.Clear();

        var toolsCfg = ConfigService.LoadToolsConfig();
        var winCfg = ConfigService.LoadWindowsConfig();

        // 1. 右键总开关 & 设置窗口
        var toggleItem = new ToolStripMenuItem("显示资源管理器右键菜单")
        {
            Checked = winCfg.ContextMenuEnabled,
            CheckOnClick = false
        };
        toggleItem.Click += (_, _) =>
        {
            var cfg = ConfigService.LoadWindowsConfig();
            cfg.ContextMenuEnabled = !cfg.ContextMenuEnabled;
            ConfigService.SaveWindowsConfig(cfg);
            RegistryMenuService.SyncContextMenu(ConfigService.LoadToolsConfig(), cfg);
            if (_settingsForm.Visible) _settingsForm.ReloadAllFromDisk();
        };
        _trayMenu.Items.Add(toggleItem);

        var openSettingsItem = new ToolStripMenuItem("打开 VibeCode 设置...");
        openSettingsItem.Click += (_, _) => _settingsForm.ShowAndSelectTab(MainTabIndex.Tools);
        _trayMenu.Items.Add(openSettingsItem);

        _trayMenu.Items.Add(new ToolStripSeparator());

        // 2. 默认终端快捷切换（仅展示已检测到的终端）
        var detectedTerminals = TerminalService.DetectInstalledTerminals();
        var currentTermDisplay = detectedTerminals
            .FirstOrDefault(t => string.Equals(t.Spec.Id, winCfg.Terminal, StringComparison.OrdinalIgnoreCase))
            ?.Spec.DisplayName ?? winCfg.Terminal;

        var terminalRoot = new ToolStripMenuItem($"默认终端: {currentTermDisplay}");
        foreach (var dt in detectedTerminals)
        {
            var sub = new ToolStripMenuItem(dt.Spec.DisplayName)
            {
                Checked = string.Equals(dt.Spec.Id, winCfg.Terminal, StringComparison.OrdinalIgnoreCase)
            };
            var captured = dt;
            sub.Click += (_, _) =>
            {
                var cfg = ConfigService.LoadWindowsConfig();
                cfg.Terminal = captured.Spec.Id;
                cfg.TerminalExePath = captured.ExecutablePath;
                ConfigService.SaveWindowsConfig(cfg);
                if (_settingsForm.Visible) _settingsForm.ReloadAllFromDisk();
            };
            terminalRoot.DropDownItems.Add(sub);
        }
        _trayMenu.Items.Add(terminalRoot);

        // 3. CLI 代理快捷切换
        var proxyLabel = (toolsCfg.Proxy is { Enabled: true } p && !string.IsNullOrWhiteSpace(p.Url))
            ? $"CLI 代理: 已启用 ({p.Url})"
            : "CLI 代理: 未启用";
        var proxyRoot = new ToolStripMenuItem(proxyLabel);

        var sysProxy = ProxyService.DetectWindowsSystemProxy();
        var useSysItem = new ToolStripMenuItem(
            sysProxy is not null ? $"启用 Windows 系统代理 ({sysProxy})" : "未检测到 Windows 系统代理")
        {
            Enabled = sysProxy is not null
        };
        useSysItem.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(sysProxy)) return;
            var cfg = ConfigService.LoadToolsConfig();
            cfg.Proxy = new ProxySettings
            {
                Enabled = true,
                Url = sysProxy,
                NoProxy = string.IsNullOrWhiteSpace(cfg.Proxy?.NoProxy) ? AppMetadata.DefaultNoProxy : cfg.Proxy.NoProxy
            };
            ConfigService.SaveToolsConfig(cfg);
            if (_settingsForm.Visible) _settingsForm.ReloadAllFromDisk();
        };
        proxyRoot.DropDownItems.Add(useSysItem);

        var disableProxyItem = new ToolStripMenuItem("停用 CLI 代理")
        {
            Enabled = toolsCfg.Proxy?.Enabled == true
        };
        disableProxyItem.Click += (_, _) =>
        {
            var cfg = ConfigService.LoadToolsConfig();
            if (cfg.Proxy is not null)
            {
                cfg.Proxy.Enabled = false;
                ConfigService.SaveToolsConfig(cfg);
                if (_settingsForm.Visible) _settingsForm.ReloadAllFromDisk();
            }
        };
        proxyRoot.DropDownItems.Add(disableProxyItem);

        proxyRoot.DropDownItems.Add(new ToolStripSeparator());
        var moreProxyItem = new ToolStripMenuItem("代理配置与连通性测试...");
        moreProxyItem.Click += (_, _) => _settingsForm.ShowAndSelectTab(MainTabIndex.ProxyAndTerminal);
        proxyRoot.DropDownItems.Add(moreProxyItem);

        _trayMenu.Items.Add(proxyRoot);
        _trayMenu.Items.Add(new ToolStripSeparator());

        // 4. 关于 & 退出
        var aboutItem = new ToolStripMenuItem("关于 VibeCode");
        aboutItem.Click += (_, _) => _settingsForm.ShowAndSelectTab(MainTabIndex.About);
        _trayMenu.Items.Add(aboutItem);

        var quitItem = new ToolStripMenuItem("退出 VibeCode");
        quitItem.Click += (_, _) => ExitApplication();
        _trayMenu.Items.Add(quitItem);
    }

    private void StartIpcServer()
    {
        var token = _ipcCts.Token;
        _ = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    using var server = new NamedPipeServerStream(
                        PipeName,
                        PipeDirection.In,
                        1,
                        PipeTransmissionMode.Message,
                        PipeOptions.Asynchronous);

                    await server.WaitForConnectionAsync(token);
                    using var reader = new StreamReader(server);
                    var msg = (await reader.ReadToEndAsync(token)).Trim().ToLowerInvariant();

                    var targetTab = msg switch
                    {
                        "proxy" => MainTabIndex.ProxyAndTerminal,
                        "about" => MainTabIndex.About,
                        _ => MainTabIndex.Tools
                    };

                    if (!_settingsForm.IsDisposed)
                    {
                        _settingsForm.BeginInvoke(() => _settingsForm.ShowAndSelectTab(targetTab));
                    }
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch
                {
                    await Task.Delay(300, token).ConfigureAwait(false);
                }
            }
        }, token);
    }

    public static bool TryNotifyRunningInstance(string command)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            client.Connect(800);
            using var writer = new StreamWriter(client) { AutoFlush = true };
            writer.Write(command);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private void ExitApplication()
    {
        _ipcCts.Cancel();
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _settingsForm.Dispose();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _ipcCts.Cancel();
            _ipcCts.Dispose();
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            _trayMenu.Dispose();
            if (!_settingsForm.IsDisposed) _settingsForm.Dispose();
        }
        base.Dispose(disposing);
    }
}

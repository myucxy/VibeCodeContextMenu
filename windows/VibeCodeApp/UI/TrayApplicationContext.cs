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
    private UpdateCheckResult? _cachedUpdate;
    private bool _disposed;

    public TrayApplicationContext(MainTabIndex? openTabOnStart)
    {
        _settingsForm = new MainSettingsForm();
        // 强制提前创建窗体句柄，确保以 --tray 静默启动时后台 IPC 线程调用 BeginInvoke 不会报错
        _ = _settingsForm.Handle;

        _trayMenu = new ContextMenuStrip();
        _trayMenu.Opening += (_, _) => RebuildTrayMenu();

        _notifyIcon = new NotifyIcon
        {
            Icon = IconService.LoadTrayIcon(),
            Text = $"VibeCode v{AppPaths.AppVersion}",
            ContextMenuStrip = _trayMenu,
            Visible = true
        };
        _notifyIcon.DoubleClick += (_, _) => _settingsForm.ShowAndSelectTab(MainTabIndex.Tools);

        var shownHideTip = false;
        _settingsForm.VisibleChanged += (_, _) =>
        {
            if (!_settingsForm.Visible && !shownHideTip && !_disposed)
            {
                shownHideTip = true;
                _notifyIcon.ShowBalloonTip(
                    3000,
                    "VibeCode 已最小化到系统托盘",
                    "可在右下角托盘（或 ^ 隐藏图标）中右键管理菜单与代理。",
                    ToolTipIcon.Info);
            }
        };

        StartIpcServer();
        StartBackgroundUpdateCheck();

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
        var sysProxy = ProxyService.DetectWindowsSystemProxy();
        string proxyLabel;
        if (toolsCfg.Proxy is { Enabled: true } p)
        {
            if (string.Equals(p.Mode, "system", StringComparison.OrdinalIgnoreCase))
            {
                proxyLabel = !string.IsNullOrWhiteSpace(sysProxy)
                    ? $"CLI 代理: 跟随系统 ({sysProxy})"
                    : "CLI 代理: 跟随系统 (当前直连)";
            }
            else if (!string.IsNullOrWhiteSpace(p.Url))
            {
                proxyLabel = $"CLI 代理: 已启用 ({p.Url})";
            }
            else
            {
                proxyLabel = "CLI 代理: 未启用";
            }
        }
        else
        {
            proxyLabel = "CLI 代理: 未启用";
        }
        var proxyRoot = new ToolStripMenuItem(proxyLabel);

        var followSysItem = new ToolStripMenuItem(
            sysProxy is not null ? $"跟随 Windows 系统代理 ({sysProxy})" : "跟随 Windows 系统代理 (当前未开启)")
        {
            Checked = toolsCfg.Proxy is { Enabled: true } fp &&
                string.Equals(fp.Mode, "system", StringComparison.OrdinalIgnoreCase)
        };
        followSysItem.Click += (_, _) =>
        {
            var cfg = ConfigService.LoadToolsConfig();
            cfg.Proxy = new ProxySettings
            {
                Enabled = true,
                Mode = "system",
                Url = cfg.Proxy?.Url ?? string.Empty,
                NoProxy = string.IsNullOrWhiteSpace(cfg.Proxy?.NoProxy) ? AppMetadata.DefaultNoProxy : cfg.Proxy.NoProxy
            };
            ConfigService.SaveToolsConfig(cfg);
            if (_settingsForm.Visible) _settingsForm.ReloadAllFromDisk();
        };
        proxyRoot.DropDownItems.Add(followSysItem);

        var useSysItem = new ToolStripMenuItem(
            sysProxy is not null ? $"固定使用当前系统代理 ({sysProxy})" : "未检测到 Windows 系统代理")
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
                Mode = "manual",
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

        // 4. 检查更新、关于 & 退出
        var updateItemText = _cachedUpdate is { HasUpdate: true } found
            ? $"发现新版本 (v{found.LatestVersion})..."
            : "检查更新...";
        var updateItem = new ToolStripMenuItem(updateItemText);
        updateItem.Click += async (_, _) =>
        {
            if (_cachedUpdate is { HasUpdate: true } cached)
            {
                _settingsForm.ShowAndSelectTab(MainTabIndex.About);
                _settingsForm.ShowUpdateDialog(cached);
            }
            else
            {
                _settingsForm.ShowAndSelectTab(MainTabIndex.About);
                await _settingsForm.CheckForUpdateAsync(silent: false);
            }
        };
        _trayMenu.Items.Add(updateItem);

        var aboutItem = new ToolStripMenuItem("关于 VibeCode");
        aboutItem.Click += (_, _) => _settingsForm.ShowAndSelectTab(MainTabIndex.About);
        _trayMenu.Items.Add(aboutItem);

        var quitItem = new ToolStripMenuItem("退出 VibeCode");
        quitItem.Click += (_, _) => ExitApplication();
        _trayMenu.Items.Add(quitItem);
    }

    private void StartBackgroundUpdateCheck()
    {
        var token = _ipcCts.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                // 启动 5 秒后静默检查一次 GitHub Releases，不阻塞启动速度
                await Task.Delay(TimeSpan.FromSeconds(5), token).ConfigureAwait(false);
                var result = await UpdateService.CheckForUpdateAsync(token).ConfigureAwait(false);
                _cachedUpdate = result;

                if (!_settingsForm.IsDisposed && _settingsForm.IsHandleCreated)
                {
                    _settingsForm.BeginInvoke(() =>
                    {
                        if (_disposed || _settingsForm.IsDisposed) return;
                        _settingsForm.ApplyBackgroundUpdateResult(result);
                        if (result.HasUpdate)
                        {
                            _notifyIcon.ShowBalloonTip(
                                4000,
                                $"发现 VibeCode 新版本 v{result.LatestVersion}",
                                "右键托盘图标点击「发现新版本」可一键更新或打开网页手动下载。",
                                ToolTipIcon.Info);
                        }
                    });
                }
            }
            catch
            {
                // 静默检查失败不影响正常使用
            }
        }, token);
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
        if (!_disposed && disposing)
        {
            _disposed = true;
            try { _ipcCts.Cancel(); } catch (ObjectDisposedException) { }
            _ipcCts.Dispose();
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            _trayMenu.Dispose();
            if (!_settingsForm.IsDisposed) _settingsForm.Dispose();
        }
        base.Dispose(disposing);
    }
}

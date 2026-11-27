using VibeCodeApp.Services;
using VibeCodeApp.UI;

namespace VibeCodeApp;

internal static class Program
{
    private const string SingleInstanceMutexName = @"Local\VibeCodeContextMenu_WinApp_SingleInstance";

    [STAThread]
    private static void Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        // 1. 极速启动器模式：VibeCode.exe --launch <toolKey> <targetPath>
        //    不抢占单实例互斥锁，允许并发启动多个终端会话。
        if (args.Length >= 3 && string.Equals(args[0], "--launch", StringComparison.OrdinalIgnoreCase))
        {
            AppPaths.EnsureSupportDirectoryPrepared();
            ToolLauncher.Launch(args[1], args[2]);
            return;
        }

        // 2. 静默卸载清理模式（供 Inno Setup 卸载器调用）：VibeCode.exe --uninstall
        if (args.Length >= 1 && string.Equals(args[0], "--uninstall", StringComparison.OrdinalIgnoreCase))
        {
            var cfg = ConfigService.LoadToolsConfig();
            RegistryMenuService.RemoveContextMenu(cfg.MenuName);
            return;
        }

        // 3. 解析目标标签页（默认静默驻留托盘；仅显式传入 --manage / --proxy / --about 时打开窗口）
        var isTraySilent = args.Any(a => string.Equals(a, "--tray", StringComparison.OrdinalIgnoreCase));
        MainTabIndex? requestedTab = null;
        string ipcCommand = "manage";

        if (args.Any(a => string.Equals(a, "--proxy", StringComparison.OrdinalIgnoreCase)))
        {
            requestedTab = MainTabIndex.ProxyAndTerminal;
            ipcCommand = "proxy";
        }
        else if (args.Any(a => string.Equals(a, "--about", StringComparison.OrdinalIgnoreCase)))
        {
            requestedTab = MainTabIndex.About;
            ipcCommand = "about";
        }
        else if (args.Any(a => string.Equals(a, "--manage", StringComparison.OrdinalIgnoreCase)))
        {
            requestedTab = MainTabIndex.Tools;
            ipcCommand = "manage";
        }

        // 4. 单实例保护：若托盘实例已在运行，双击程序或带参数启动时直接唤醒设置窗口
        using var mutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out var createdNew);
        if (!createdNew)
        {
            if (!isTraySilent)
            {
                TrayApplicationContext.TryNotifyRunningInstance(ipcCommand);
            }
            return;
        }

        // 5. 首次启动自包含初始化（释放内置图标/默认配置、自动探测 AI CLI 与终端、写入右键菜单）
        var isFirstRun = AppPaths.EnsureSupportDirectoryPrepared();
        if (isFirstRun)
        {
            ConfigService.InitializeFirstRunDefaults();
        }
        else
        {
            // 每次启动同步一次右键菜单，确保 exe 路径搬迁后注册表指向最新路径
            RegistryMenuService.SyncContextMenu(
                ConfigService.LoadToolsConfig(),
                ConfigService.LoadWindowsConfig());
        }

        Application.Run(new TrayApplicationContext(requestedTab));
    }
}

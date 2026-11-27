using System.Diagnostics;
using System.Reflection;
using System.Security.Principal;

namespace VibeCodeApp.Services;

public static class AppPaths
{
    public static string LocalAppData =>
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    public static string SupportDir => Path.Combine(LocalAppData, "VibeCode");

    public static string IconsDir => Path.Combine(SupportDir, "icons");

    public static string ToolsConfigPath => Path.Combine(SupportDir, "tools.json");

    public static string WindowsConfigPath => Path.Combine(SupportDir, "windows.json");

    public static string RuntimeRoot => Path.Combine(LocalAppData, "Programs", "VibeCodeRuntime");

    public static string ExecutablePath =>
        Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "VibeCode.exe");

    public static bool IsRunningAsAdministrator()
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    public static bool TryStartElevatedInstance(string arguments = "--manage --wait-mutex")
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = ExecutablePath,
                Arguments = arguments,
                UseShellExecute = true,
                Verb = "runas"
            };
            return Process.Start(psi) is not null;
        }
        catch
        {
            return false;
        }
    }

    public static string AppVersion
    {
        get
        {
            var asm = Assembly.GetExecutingAssembly();
            var infoVer = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            if (!string.IsNullOrWhiteSpace(infoVer))
            {
                var plusIdx = infoVer.IndexOf('+');
                return plusIdx > 0 ? infoVer[..plusIdx] : infoVer;
            }
            var ver = asm.GetName().Version;
            return ver is null ? "1.0.0" : $"{ver.Major}.{ver.Minor}.{ver.Build}";
        }
    }

    /// <summary>
    /// 首次运行时从单文件内嵌资源自动释放默认配置与官方图标，保证脱离源码目录独立可用。
    /// 返回是否为全新机器首次运行（windows.json 尚未存在）。
    /// </summary>
    public static bool EnsureSupportDirectoryPrepared()
    {
        var isFirstRun = !File.Exists(WindowsConfigPath);
        Directory.CreateDirectory(SupportDir);
        Directory.CreateDirectory(IconsDir);

        var asm = Assembly.GetExecutingAssembly();

        // 1. 释放全部内置官方 .ico 到 icons/（同时在 SupportDir 根目录也保有一份 vibecode.ico 兼容旧路径）
        const string iconPrefix = "VibeCodeApp.Resources.ico.";
        foreach (var resName in asm.GetManifestResourceNames())
        {
            if (!resName.StartsWith(iconPrefix, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            var fileName = resName[iconPrefix.Length..];
            var targetPath = Path.Combine(IconsDir, fileName);
            if (!File.Exists(targetPath))
            {
                ExtractResource(asm, resName, targetPath);
            }
        }

        // 2. 首次运行释放默认 tools.json
        if (!File.Exists(ToolsConfigPath))
        {
            ExtractResource(asm, "VibeCodeApp.Resources.tools.json", ToolsConfigPath);
        }

        return isFirstRun;
    }

    private static void ExtractResource(Assembly asm, string resourceName, string targetPath)
    {
        using var stream = asm.GetManifestResourceStream(resourceName);
        if (stream is null) return;
        using var fs = new FileStream(targetPath, FileMode.Create, FileAccess.Write, FileShare.None);
        stream.CopyTo(fs);
    }
}

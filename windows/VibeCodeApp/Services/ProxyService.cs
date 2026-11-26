using System.Diagnostics;
using System.Net;
using Microsoft.Win32;

namespace VibeCodeApp.Services;

public static class ProxyService
{
    private static readonly string[] TestTargets =
    [
        "https://www.google.com/generate_204",
        "https://antigravity.google",
        "https://api.anthropic.com",
        "https://api.openai.com"
    ];

    /// <summary>
    /// 规范化代理地址；无协议时补 http://，支持 http / https / socks5 / socks5h。
    /// </summary>
    public static string? NormalizeProxyUrl(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var candidate = raw.Trim();
        if (!candidate.Contains("://", StringComparison.Ordinal))
        {
            candidate = "http://" + candidate;
        }
        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri)) return null;
        var scheme = uri.Scheme.ToLowerInvariant();
        if (scheme is not ("http" or "https" or "socks5" or "socks5h")) return null;
        if (string.IsNullOrWhiteSpace(uri.Host) || uri.Port <= 0) return null;
        if (uri.AbsolutePath != "/" || !string.IsNullOrEmpty(uri.Query)) return null;
        return $"{scheme}://{uri.Host}:{uri.Port}";
    }

    /// <summary>
    /// 读取 Windows「设置 > 网络 > 代理」中的系统手动代理（Clash Verge / v2rayN 等）。
    /// </summary>
    public static string? DetectWindowsSystemProxy()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
            if (key is null) return null;

            var enableObj = key.GetValue("ProxyEnable");
            if (enableObj is not int enable || enable != 1) return null;

            var server = key.GetValue("ProxyServer") as string;
            if (string.IsNullOrWhiteSpace(server)) return null;

            if (!server.Contains('='))
            {
                return NormalizeProxyUrl(server);
            }

            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var part in server.Split(';', StringSplitOptions.RemoveEmptyEntries))
            {
                var idx = part.IndexOf('=');
                if (idx > 0 && idx < part.Length - 1)
                {
                    map[part[..idx].Trim()] = part[(idx + 1)..].Trim();
                }
            }

            if (map.TryGetValue("https", out var httpsVal)) return NormalizeProxyUrl(httpsVal);
            if (map.TryGetValue("http", out var httpVal)) return NormalizeProxyUrl(httpVal);
            if (map.TryGetValue("socks", out var socksVal)) return NormalizeProxyUrl("socks5://" + socksVal);
            return null;
        }
        catch
        {
            return null;
        }
    }

    public static async Task RunConnectivityTestAsync(
        string proxyUrl,
        Action<string> onProgressLine,
        CancellationToken cancellationToken = default)
    {
        using var handler = new SocketsHttpHandler
        {
            Proxy = new WebProxy(proxyUrl),
            UseProxy = true,
            ConnectTimeout = TimeSpan.FromSeconds(8),
            AllowAutoRedirect = false
        };
        using var client = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(12)
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("VibeCodeContextMenu");

        foreach (var target in TestTargets)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var sw = Stopwatch.StartNew();
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, target);
                using var resp = await client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
                sw.Stop();
                onProgressLine($"[OK]   {target}  (HTTP {(int)resp.StatusCode}, {sw.ElapsedMilliseconds}ms)");
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception ex)
            {
                sw.Stop();
                var msg = ex.InnerException?.Message ?? ex.Message;
                onProgressLine($"[失败] {target}  ({msg})");
            }
        }
    }
}

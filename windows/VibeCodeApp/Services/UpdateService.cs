using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VibeCodeApp.Services;

public sealed class GitHubReleaseAsset
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("browser_download_url")]
    public string DownloadUrl { get; set; } = string.Empty;

    [JsonPropertyName("size")]
    public long Size { get; set; }
}

public sealed class GitHubReleaseInfo
{
    [JsonPropertyName("tag_name")]
    public string TagName { get; set; } = string.Empty;

    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("body")]
    public string Body { get; set; } = string.Empty;

    [JsonPropertyName("html_url")]
    public string HtmlUrl { get; set; } = string.Empty;

    [JsonPropertyName("published_at")]
    public DateTimeOffset? PublishedAt { get; set; }

    [JsonPropertyName("assets")]
    public List<GitHubReleaseAsset> Assets { get; set; } = new();
}

public sealed record UpdateCheckResult(
    bool HasUpdate,
    string CurrentVersion,
    string LatestVersion,
    GitHubReleaseInfo Release,
    GitHubReleaseAsset? InstallerAsset,
    GitHubReleaseAsset? Sha256Asset);

/// <summary>
/// 基于 GitHub Releases API 的自动版本更新检测、校验与下载服务（无需 Token，自动复用已配置代理）。
/// </summary>
public static class UpdateService
{
    private const string LatestReleaseApiUrl =
        "https://api.github.com/repos/myucxy/VibeCodeContextMenu/releases/latest";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    public static async Task<UpdateCheckResult> CheckForUpdateAsync(CancellationToken ct = default)
    {
        using var client = CreateHttpClient(TimeSpan.FromSeconds(15));
        using var req = new HttpRequestMessage(HttpMethod.Get, LatestReleaseApiUrl);
        req.Headers.Accept.ParseAdd("application/vnd.github+json");

        using var resp = await client.SendAsync(req, ct).ConfigureAwait(false);
        if (resp.StatusCode == HttpStatusCode.NotFound)
        {
            throw new InvalidOperationException("GitHub 仓库尚未发布任何 Release 版本。");
        }
        resp.EnsureSuccessStatusCode();

        var json = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        var release = JsonSerializer.Deserialize<GitHubReleaseInfo>(json, JsonOptions)
            ?? throw new InvalidOperationException("无法解析 GitHub Release 响应数据。");

        var currentVersion = NormalizeVersionString(AppPaths.AppVersion);
        var latestVersion = NormalizeVersionString(release.TagName);
        var hasUpdate = IsNewerVersion(latestVersion, currentVersion);

        var (installer, sha256) = SelectBestWindowsAsset(release.Assets);

        return new UpdateCheckResult(
            HasUpdate: hasUpdate,
            CurrentVersion: currentVersion,
            LatestVersion: latestVersion,
            Release: release,
            InstallerAsset: installer,
            Sha256Asset: sha256);
    }

    public static async Task<string> DownloadAndVerifyAsync(
        GitHubReleaseAsset asset,
        GitHubReleaseAsset? sha256Asset,
        IProgress<(long Downloaded, long Total, string Status)>? progress,
        CancellationToken ct = default)
    {
        var downloadDir = Path.Combine(Path.GetTempPath(), "VibeCodeUpdate");
        Directory.CreateDirectory(downloadDir);

        var safeName = Path.GetFileName(asset.Name);
        var targetPath = Path.Combine(downloadDir, safeName);
        var partPath = targetPath + ".part";

        using var client = CreateHttpClient(TimeSpan.FromMinutes(10));

        // 1. 下载安装包本体
        progress?.Report((0, asset.Size, $"正在下载 {safeName}..."));
        using (var resp = await client.GetAsync(asset.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false))
        {
            resp.EnsureSuccessStatusCode();
            var total = resp.Content.Headers.ContentLength ?? asset.Size;
            await using var netStream = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            await using var fileStream = new FileStream(partPath, FileMode.Create, FileAccess.Write, FileShare.None, 81920, useAsync: true);

            var buffer = new byte[81920];
            long downloaded = 0;
            int read;
            var lastReport = DateTime.UtcNow;

            while ((read = await netStream.ReadAsync(buffer.AsMemory(0, buffer.Length), ct).ConfigureAwait(false)) > 0)
            {
                await fileStream.WriteAsync(buffer.AsMemory(0, read), ct).ConfigureAwait(false);
                downloaded += read;

                var now = DateTime.UtcNow;
                if ((now - lastReport).TotalMilliseconds >= 120 || downloaded == total)
                {
                    lastReport = now;
                    var mbDone = downloaded / (1024.0 * 1024.0);
                    var mbTotal = total > 0 ? total / (1024.0 * 1024.0) : 0;
                    var status = total > 0
                        ? $"正在下载 {safeName} ({mbDone:F1} / {mbTotal:F1} MB)"
                        : $"正在下载 {safeName} ({mbDone:F1} MB)";
                    progress?.Report((downloaded, total, status));
                }
            }
        }

        // 2. 若 Release 附带了 .sha256 文件，下载并强制校验完整性
        if (sha256Asset is not null && !string.IsNullOrWhiteSpace(sha256Asset.DownloadUrl))
        {
            progress?.Report((asset.Size, asset.Size, "正在校验 SHA-256 完整性..."));
            var shaText = await client.GetStringAsync(sha256Asset.DownloadUrl, ct).ConfigureAwait(false);
            var expectedHash = shaText.Trim().Split([' ', '\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();

            if (!string.IsNullOrWhiteSpace(expectedHash) && expectedHash.Length == 64)
            {
                await using var verifyStream = File.OpenRead(partPath);
                var actualBytes = await SHA256.HashDataAsync(verifyStream, ct).ConfigureAwait(false);
                var actualHash = Convert.ToHexString(actualBytes);
                if (!actualHash.Equals(expectedHash, StringComparison.OrdinalIgnoreCase))
                {
                    try { File.Delete(partPath); } catch { }
                    throw new InvalidOperationException("下载文件的 SHA-256 校验失败，已中止安装，建议改为打开网页手动下载。");
                }
            }
        }

        File.Move(partPath, targetPath, overwrite: true);
        progress?.Report((asset.Size, asset.Size, "下载并校验完成！"));
        return targetPath;
    }

    public static string NormalizeVersionString(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "0.0.0";
        return raw.Trim().TrimStart('v', 'V');
    }

    public static bool IsNewerVersion(string latestRaw, string currentRaw)
    {
        var latestClean = StripPrerelease(NormalizeVersionString(latestRaw));
        var currentClean = StripPrerelease(NormalizeVersionString(currentRaw));

        if (Version.TryParse(latestClean, out var latestVer) &&
            Version.TryParse(currentClean, out var currentVer))
        {
            var cmp = latestVer.CompareTo(currentVer);
            if (cmp != 0) return cmp > 0;
            // 同主版本号时，正式版高于预发布版（1.0.0 > 1.0.0-beta.1）
            var latestIsPre = latestRaw.Contains('-');
            var currentIsPre = currentRaw.Contains('-');
            return !latestIsPre && currentIsPre;
        }

        return !string.Equals(latestRaw, currentRaw, StringComparison.OrdinalIgnoreCase);
    }

    private static string StripPrerelease(string ver)
    {
        var dash = ver.IndexOf('-');
        var core = dash > 0 ? ver[..dash] : ver;
        // System.Version 至少需要 major.minor
        if (!core.Contains('.')) core += ".0";
        return core;
    }

    private static (GitHubReleaseAsset? Installer, GitHubReleaseAsset? Sha256) SelectBestWindowsAsset(
        List<GitHubReleaseAsset> assets)
    {
        if (assets.Count == 0) return (null, null);

        var archTag = RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "win-arm64" : "win-x64";

        // 优先匹配 Setup.exe 安装向导，其次匹配便携版 .zip
        var installer = assets.FirstOrDefault(a =>
            a.Name.Contains(archTag, StringComparison.OrdinalIgnoreCase) &&
            a.Name.EndsWith("-Setup.exe", StringComparison.OrdinalIgnoreCase))
            ?? assets.FirstOrDefault(a =>
                a.Name.Contains(archTag, StringComparison.OrdinalIgnoreCase) &&
                a.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase));

        if (installer is null) return (null, null);

        var sha256 = assets.FirstOrDefault(a =>
            a.Name.Equals(installer.Name + ".sha256", StringComparison.OrdinalIgnoreCase));

        return (installer, sha256);
    }

    private static string? ResolveEffectiveProxyUrl()
    {
        var proxy = ConfigService.LoadToolsConfig().Proxy;
        if (proxy is { Enabled: true })
        {
            if (string.Equals(proxy.Mode, "system", StringComparison.OrdinalIgnoreCase))
            {
                return ProxyService.DetectWindowsSystemProxy();
            }
            if (!string.IsNullOrWhiteSpace(proxy.Url))
            {
                return proxy.Url.Trim();
            }
        }
        // 未在 VibeCode 单独配代理时，自动尝试系统代理以提升 GitHub 访问成功率
        return ProxyService.DetectWindowsSystemProxy();
    }

    private static HttpClient CreateHttpClient(TimeSpan timeout)
    {
        var handler = new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(10),
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
        };

        var proxyUrl = ResolveEffectiveProxyUrl();
        if (!string.IsNullOrWhiteSpace(proxyUrl))
        {
            handler.Proxy = new WebProxy(proxyUrl);
            handler.UseProxy = true;
        }

        var client = new HttpClient(handler) { Timeout = timeout };
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"VibeCodeContextMenu/{AppPaths.AppVersion}");
        return client;
    }
}

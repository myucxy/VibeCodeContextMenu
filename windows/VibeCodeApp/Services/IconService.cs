using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace VibeCodeApp.Services;

/// <summary>
/// 图标服务：加载官方 .ico、导入自定义图片转标准 PNG-in-ICO，
/// 并为没有专属图标的扩展/自定义 CLI 自动绘制品牌色圆角 .ico 图标。
/// </summary>
public static class IconService
{
    private static readonly Dictionary<string, (Color Bg, string Label)> BrandPalette = new(StringComparer.OrdinalIgnoreCase)
    {
        ["gemini"] = (Color.FromArgb(66, 133, 244), "G"),
        ["qwen"] = (Color.FromArgb(99, 87, 242), "Q"),
        ["kimi"] = (Color.FromArgb(30, 33, 41), "K"),
        ["copilot"] = (Color.FromArgb(122, 74, 224), "CP"),
        ["cursor"] = (Color.FromArgb(38, 38, 46), "CR"),
        ["cursor-agent"] = (Color.FromArgb(38, 38, 46), "CR"),
        ["aider"] = (Color.FromArgb(28, 171, 112), "Ai"),
        ["kiro"] = (Color.FromArgb(140, 64, 230), "Ki"),
        ["cline"] = (Color.FromArgb(20, 143, 199), "CL"),
        ["amp"] = (Color.FromArgb(235, 87, 51), "A"),
        ["goose"] = (Color.FromArgb(46, 115, 173), "GS"),
        ["auggie"] = (Color.FromArgb(51, 153, 138), "Au"),
        ["crush"] = (Color.FromArgb(217, 61, 122), "CR"),
        ["codebuddy"] = (Color.FromArgb(13, 122, 242), "CB"),
        ["vibe"] = (Color.FromArgb(242, 115, 31), "V"),
        ["droid"] = (Color.FromArgb(64, 71, 89), "DR"),
    };

    private static readonly Color[] FallbackColors =
    [
        Color.FromArgb(61, 125, 235),
        Color.FromArgb(36, 163, 120),
        Color.FromArgb(143, 82, 219),
        Color.FromArgb(224, 107, 46),
        Color.FromArgb(31, 145, 184),
        Color.FromArgb(199, 66, 122),
    ];

    public static string SanitizeFileStem(string toolName)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var chars = toolName.Trim().ToLowerInvariant()
            .Select(c => invalid.Contains(c) || char.IsWhiteSpace(c) ? '-' : c)
            .ToArray();
        var stem = new string(chars).Trim('-');
        return string.IsNullOrWhiteSpace(stem) ? "tool" : stem;
    }

    public static string EnsureMainIconPath()
    {
        Directory.CreateDirectory(AppPaths.IconsDir);
        var path = Path.Combine(AppPaths.IconsDir, "vibecode.ico");
        if (File.Exists(path)) return path;
        GenerateBrandIco("VibeCode", path);
        return path;
    }

    /// <summary>
    /// 为工具确保在 %LOCALAPPDATA%\VibeCode\icons 下存在可用的 .ico 文件（供 Explorer 右键菜单引用）。
    /// </summary>
    public static string EnsureToolIconPath(string toolName, string? configuredIconName)
    {
        Directory.CreateDirectory(AppPaths.IconsDir);

        if (!string.IsNullOrWhiteSpace(configuredIconName))
        {
            var direct = Path.Combine(AppPaths.IconsDir, Path.GetFileName(configuredIconName));
            if (File.Exists(direct)) return direct;
        }

        var stem = SanitizeFileStem(toolName);
        var byName = Path.Combine(AppPaths.IconsDir, $"{stem}.ico");
        if (File.Exists(byName)) return byName;

        // 自动生成高清品牌色圆角 .ico 图标
        GenerateBrandIco(toolName, byName);
        return byName;
    }

    /// <summary>
    /// 导入用户选择的 .ico / .png / .jpg 图片并转换为 32x32 标准 PNG-in-ICO 存入 icons/ 目录。
    /// </summary>
    public static string ImportCustomIcon(string sourceFilePath, string toolName)
    {
        Directory.CreateDirectory(AppPaths.IconsDir);
        var stem = SanitizeFileStem(toolName);
        var fileName = $"{stem}.ico";
        var destPath = Path.Combine(AppPaths.IconsDir, fileName);

        if (string.Equals(Path.GetExtension(sourceFilePath), ".ico", StringComparison.OrdinalIgnoreCase))
        {
            File.Copy(sourceFilePath, destPath, overwrite: true);
            return fileName;
        }

        using var srcImage = Image.FromFile(sourceFilePath);
        using var bmp = new Bitmap(32, 32, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            g.DrawImage(srcImage, new Rectangle(0, 0, 32, 32));
        }
        SaveBitmapAsIco(bmp, destPath);
        return fileName;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    public static Icon LoadMainAppIcon()
    {
        var path = EnsureMainIconPath();
        return LoadCrispIconFromIco(path, SystemInformation.IconSize);
    }

    public static Icon LoadTrayIcon()
    {
        var path = EnsureMainIconPath();
        // 按当前 DPI 下的真实托盘小图标尺寸（如 100%=16, 125%=20, 150%=24, 200%=32）
        // 从 ICO 内最高分辨率帧高质量双三次下采样，避免 16x16 强行放大发虚
        var size = SystemInformation.SmallIconSize;
        try
        {
            return LoadCrispIconFromIco(path, size);
        }
        catch
        {
            try
            {
                var assoc = Icon.ExtractAssociatedIcon(AppPaths.ExecutablePath);
                if (assoc is not null) return assoc;
            }
            catch
            {
                // 忽略回退异常
            }
            return (Icon)SystemIcons.Application.Clone();
        }
    }

    /// <summary>
    /// 从多帧 .ico 中提取分辨率最高的一帧（优先内嵌 PNG 256x256），
    /// 使用高质量双三次插值缩放到目标 DPI 像素尺寸并转为 32 位 ARGB HICON。
    /// </summary>
    private static Icon LoadCrispIconFromIco(string icoPath, Size targetSize)
    {
        var w = Math.Max(16, targetSize.Width);
        var h = Math.Max(16, targetSize.Height);
        try
        {
            using var hiRes = ExtractBestBitmapFromIco(icoPath);
            if (hiRes is not null)
            {
                using var scaled = new Bitmap(w, h, PixelFormat.Format32bppArgb);
                using (var g = Graphics.FromImage(scaled))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.SmoothingMode = SmoothingMode.HighQuality;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.CompositingQuality = CompositingQuality.HighQuality;
                    g.Clear(Color.Transparent);
                    g.DrawImage(hiRes, new Rectangle(0, 0, w, h));
                }
                var hIcon = scaled.GetHicon();
                try
                {
                    using var temp = Icon.FromHandle(hIcon);
                    return (Icon)temp.Clone();
                }
                finally
                {
                    DestroyIcon(hIcon);
                }
            }

            using var fallback = new Icon(icoPath, w, h);
            return (Icon)fallback.Clone();
        }
        catch
        {
            return (Icon)SystemIcons.Application.Clone();
        }
    }

    private static Bitmap? ExtractBestBitmapFromIco(string icoPath)
    {
        var bytes = File.ReadAllBytes(icoPath);
        if (bytes.Length < 22) return null;
        var count = BitConverter.ToUInt16(bytes, 4);
        if (count == 0 || bytes.Length < 6 + count * 16) return null;

        int bestWidth = 0;
        int bestOffset = -1;
        int bestSize = 0;
        for (var i = 0; i < count; i++)
        {
            var entryOff = 6 + i * 16;
            int ew = bytes[entryOff] == 0 ? 256 : bytes[entryOff];
            int dataSize = BitConverter.ToInt32(bytes, entryOff + 8);
            int dataOffset = BitConverter.ToInt32(bytes, entryOff + 12);
            if (dataOffset < 0 || dataSize <= 0 || dataOffset + dataSize > bytes.Length) continue;
            // 优先选择最大尺寸的 PNG 帧（256x256 PNG 下采样最锐利）
            var isPng = dataSize >= 8 &&
                        bytes[dataOffset] == 0x89 && bytes[dataOffset + 1] == 0x50 &&
                        bytes[dataOffset + 2] == 0x4E && bytes[dataOffset + 3] == 0x47;
            if (isPng && ew >= bestWidth)
            {
                bestWidth = ew;
                bestOffset = dataOffset;
                bestSize = dataSize;
            }
        }

        if (bestOffset >= 0)
        {
            using var ms = new MemoryStream(bytes, bestOffset, bestSize);
            using var img = Image.FromStream(ms);
            return new Bitmap(img);
        }

        using var icon = new Icon(icoPath, 256, 256);
        return icon.ToBitmap();
    }

    public static Bitmap LoadToolBitmap(string toolName, string? configuredIconName, int size = 24)
    {
        var icoPath = EnsureToolIconPath(toolName, configuredIconName);
        try
        {
            // 若是单帧 PNG-in-ICO（如自动生成的品牌徽标或导入的 PNG），直接解码内嵌 PNG 以规避 GDI+ Icon 构造限制
            var bytes = File.ReadAllBytes(icoPath);
            if (bytes.Length > 30 &&
                bytes[22] == 0x89 && bytes[23] == 0x50 && bytes[24] == 0x4E && bytes[25] == 0x47)
            {
                using var ms = new MemoryStream(bytes, 22, bytes.Length - 22);
                using var pngImg = Image.FromStream(ms);
                return ScaleToBitmap(pngImg, size);
            }

            using var icon = new Icon(icoPath, size, size);
            using var raw = icon.ToBitmap();
            return ScaleToBitmap(raw, size);
        }
        catch
        {
            return RenderBrandBadgeBitmap(toolName, size);
        }
    }

    private static Bitmap ScaleToBitmap(Image source, int size)
    {
        var scaled = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(scaled);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.SmoothingMode = SmoothingMode.HighQuality;
        g.Clear(Color.Transparent);
        g.DrawImage(source, new Rectangle(0, 0, size, size));
        return scaled;
    }

    private static void GenerateBrandIco(string toolName, string outputIcoPath)
    {
        using var bmp = RenderBrandBadgeBitmap(toolName, 32);
        SaveBitmapAsIco(bmp, outputIcoPath);
    }

    public static Bitmap RenderBrandBadgeBitmap(string toolName, int size)
    {
        Color bg;
        string text;
        if (BrandPalette.TryGetValue(toolName.Trim(), out var hit))
        {
            bg = hit.Bg;
            text = hit.Label;
        }
        else
        {
            var key = toolName.Trim().ToLowerInvariant();
            var hash = 0;
            foreach (var ch in key)
            {
                hash = unchecked(hash * 31 + ch);
            }
            bg = FallbackColors[Math.Abs(hash) % FallbackColors.Length];
            var clean = toolName.Trim();
            text = string.IsNullOrEmpty(clean)
                ? "AI"
                : (clean.Length >= 2 ? clean[..2] : clean).ToUpperInvariant();
        }

        var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        g.Clear(Color.Transparent);

        var rect = new RectangleF(1f, 1f, size - 2f, size - 2f);
        var radius = size * 0.24f;
        using var path = CreateRoundedRectPath(rect, radius);
        using var bgBrush = new SolidBrush(bg);
        g.FillPath(bgBrush, path);

        var fontSize = text.Length >= 2 ? size * 0.36f : size * 0.48f;
        using var font = new Font("Segoe UI", fontSize, FontStyle.Bold, GraphicsUnit.Pixel);
        using var textBrush = new SolidBrush(Color.White);
        using var sf = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center
        };
        g.DrawString(text, font, textBrush, rect, sf);
        return bmp;
    }

    private static GraphicsPath CreateRoundedRectPath(RectangleF rect, float radius)
    {
        var diameter = radius * 2f;
        var path = new GraphicsPath();
        path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
        path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270, 90);
        path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    /// <summary>
    /// 将 32x32 ARGB Bitmap 封装为标准 PNG-in-ICO 文件（22 字节 ICO 文件头 + PNG 数据，Windows Vista~11 原生支持全透明通道）。
    /// </summary>
    private static void SaveBitmapAsIco(Bitmap bmp, string destinationPath)
    {
        using var pngStream = new MemoryStream();
        bmp.Save(pngStream, ImageFormat.Png);
        var pngBytes = pngStream.ToArray();

        using var fs = new FileStream(destinationPath, FileMode.Create, FileAccess.Write, FileShare.None);
        using var bw = new BinaryWriter(fs);

        // ICONDIR (6 bytes)
        bw.Write((ushort)0); // Reserved
        bw.Write((ushort)1); // Type: 1 = ICO
        bw.Write((ushort)1); // Count: 1 image

        // ICONDIRENTRY (16 bytes)
        bw.Write((byte)(bmp.Width >= 256 ? 0 : bmp.Width));
        bw.Write((byte)(bmp.Height >= 256 ? 0 : bmp.Height));
        bw.Write((byte)0);   // Color palette count
        bw.Write((byte)0);   // Reserved
        bw.Write((ushort)1); // Color planes
        bw.Write((ushort)32); // Bits per pixel
        bw.Write((uint)pngBytes.Length);
        bw.Write((uint)22);  // Offset (6 + 16)

        bw.Write(pngBytes);
    }
}

using System.Diagnostics;
using VibeCodeApp.Services;

namespace VibeCodeApp.UI;

/// <summary>
/// 发现新版本弹窗：现代卡片风格，支持「在线更新」（自动下载 + SHA-256 校验 + 拉起安装）与「手动下载（打开网页）」。
/// </summary>
public sealed class UpdateDialog : Form
{
    private readonly UpdateCheckResult _result;
    private readonly bool _autoStartDownload;
    private readonly ProgressBar _progressBar = new();
    private readonly Label _statusLabel = new();
    private readonly Button _downloadBtn = new();
    private readonly Button _webBtn = new();
    private readonly Button _closeBtn = new();
    private CancellationTokenSource? _downloadCts;
    private bool _isDownloading;

    private static readonly Color AccentBlue = Color.FromArgb(0, 120, 212);
    private static readonly Color AccentBlueHover = Color.FromArgb(16, 110, 190);
    private static readonly Color SurfaceBg = Color.FromArgb(247, 248, 250);
    private static readonly Color DividerColor = Color.FromArgb(228, 231, 237);

    public UpdateDialog(UpdateCheckResult result, bool autoStartDownload = false)
    {
        _result = result;
        _autoStartDownload = autoStartDownload;

        Text = $"VibeCode 软件更新 - v{result.LatestVersion}";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(580, 450);
        MinimumSize = new Size(540, 400);
        BackColor = SurfaceBg;
        Font = new Font("Microsoft YaHei UI", 9f);
        Icon = IconService.LoadMainAppIcon();

        BuildUI();
        if (_autoStartDownload && _result.InstallerAsset is not null)
        {
            Shown += async (_, _) => await HandleDownloadAndInstallAsync();
        }
    }

    private void BuildUI()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 3,
            Margin = new Padding(0),
            Padding = new Padding(0)
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));      // 顶部白色卡片头
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));  // 中间更新日志与进度
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));      // 底部按钮区

        // 1. 顶部白色 Banner
        var headerPanel = new Panel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BackColor = Color.White,
            Padding = new Padding(20, 16, 20, 14)
        };
        headerPanel.Paint += (_, e) =>
        {
            using var pen = new Pen(DividerColor);
            e.Graphics.DrawLine(pen, 0, headerPanel.Height - 1, headerPanel.Width, headerPanel.Height - 1);
        };

        var headerGrid = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 2,
            RowCount = 2
        };
        headerGrid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        headerGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        headerGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        headerGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var iconPic = new PictureBox
        {
            Image = IconService.LoadToolBitmap("VibeCode", "vibecode.ico", 44),
            Size = new Size(44, 44),
            SizeMode = PictureBoxSizeMode.Zoom,
            Margin = new Padding(0, 2, 14, 2)
        };
        headerGrid.Controls.Add(iconPic, 0, 0);
        headerGrid.SetRowSpan(iconPic, 2);

        var titleLbl = new Label
        {
            Text = $"发现新版本 v{_result.LatestVersion}",
            Font = new Font("Microsoft YaHei UI", 12.5f, FontStyle.Bold),
            ForeColor = Color.FromArgb(24, 28, 36),
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 4)
        };
        headerGrid.Controls.Add(titleLbl, 1, 0);

        var sizeText = _result.InstallerAsset is not null
            ? $"  ·  {_result.InstallerAsset.Name} ({_result.InstallerAsset.Size / (1024.0 * 1024.0):F1} MB)"
            : string.Empty;
        var subLbl = new Label
        {
            Text = $"当前版本 v{_result.CurrentVersion}  →  最新 v{_result.LatestVersion}{sizeText}",
            ForeColor = Color.FromArgb(100, 108, 120),
            AutoSize = true,
            Margin = new Padding(0)
        };
        headerGrid.Controls.Add(subLbl, 1, 1);

        headerPanel.Controls.Add(headerGrid);
        root.Controls.Add(headerPanel, 0, 0);

        // 2. 中间内容区（更新日志 + 下载进度）
        var bodyGrid = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 4,
            Padding = new Padding(20, 14, 20, 8)
        };
        bodyGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        bodyGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        bodyGrid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        bodyGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        bodyGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var notesTitle = new Label
        {
            Text = "更新内容",
            Font = new Font(Font, FontStyle.Bold),
            ForeColor = Color.FromArgb(55, 62, 74),
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 6)
        };
        bodyGrid.Controls.Add(notesTitle, 0, 0);

        var notesText = string.IsNullOrWhiteSpace(_result.Release.Body)
            ? "（该版本未填写更新说明，可点击「手动下载」前往 GitHub Release 页面查看详情。）"
            : _result.Release.Body.Replace("\r\n", "\n").Replace("\n", "\r\n");

        var notesBox = new TextBox
        {
            Dock = DockStyle.Fill,
            Multiline = true,
            ReadOnly = true,
            ScrollBars = ScrollBars.Vertical,
            BorderStyle = BorderStyle.FixedSingle,
            BackColor = Color.White,
            ForeColor = Color.FromArgb(40, 45, 55),
            Text = notesText,
            Margin = new Padding(0, 0, 0, 10)
        };
        bodyGrid.Controls.Add(notesBox, 0, 1);

        _progressBar.Dock = DockStyle.Top;
        _progressBar.Height = 14;
        _progressBar.Minimum = 0;
        _progressBar.Maximum = 100;
        _progressBar.Visible = false;
        _progressBar.Margin = new Padding(0, 0, 0, 6);
        bodyGrid.Controls.Add(_progressBar, 0, 2);

        _statusLabel.AutoSize = true;
        _statusLabel.ForeColor = Color.FromArgb(95, 103, 115);
        _statusLabel.Margin = new Padding(0, 0, 0, 2);
        _statusLabel.Text = _result.InstallerAsset is not null
            ? "点击「在线更新」将自动下载安装包并校验 SHA-256，或点击「手动下载」在浏览器中下载。"
            : "当前 Release 未找到匹配的自动安装包，请点击「手动下载」前往网页下载。";
        bodyGrid.Controls.Add(_statusLabel, 0, 3);

        root.Controls.Add(bodyGrid, 0, 1);

        // 3. 底部按钮栏
        var footerPanel = new Panel
        {
            Dock = DockStyle.Bottom,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BackColor = Color.White,
            Padding = new Padding(20, 12, 20, 14)
        };
        footerPanel.Paint += (_, e) =>
        {
            using var pen = new Pen(DividerColor);
            e.Graphics.DrawLine(pen, 0, 0, footerPanel.Width, 0);
        };

        var btnBar = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 2,
            RowCount = 1,
            Margin = new Padding(0)
        };
        btnBar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        btnBar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        var leftFlow = new FlowLayoutPanel
        {
            Dock = DockStyle.Left,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Margin = new Padding(0)
        };

        var isSetupExe = _result.InstallerAsset?.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) == true;
        _downloadBtn.Text = isSetupExe ? "在线更新" : "在线下载更新包";
        StylePrimaryButton(_downloadBtn, 118);
        _downloadBtn.Enabled = _result.InstallerAsset is not null;
        _downloadBtn.Margin = new Padding(0, 0, 10, 0);
        _downloadBtn.Click += async (_, _) => await HandleDownloadAndInstallAsync();

        _webBtn.Text = "手动下载 (网页)";
        StyleSecondaryButton(_webBtn, 128);
        _webBtn.Margin = new Padding(0);
        _webBtn.Click += (_, _) => OpenWebPage();

        leftFlow.Controls.Add(_downloadBtn);
        leftFlow.Controls.Add(_webBtn);

        _closeBtn.Text = "稍后提醒";
        StyleSecondaryButton(_closeBtn, 92);
        _closeBtn.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        _closeBtn.Margin = new Padding(8, 0, 0, 0);
        _closeBtn.Click += (_, _) =>
        {
            if (_isDownloading)
            {
                _downloadCts?.Cancel();
            }
            else
            {
                Close();
            }
        };

        btnBar.Controls.Add(leftFlow, 0, 0);
        btnBar.Controls.Add(_closeBtn, 1, 0);
        footerPanel.Controls.Add(btnBar);
        root.Controls.Add(footerPanel, 0, 2);

        Controls.Add(root);
        CancelButton = _closeBtn;
    }

    private static void StylePrimaryButton(Button btn, int minWidth)
    {
        btn.AutoSize = true;
        btn.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        btn.MinimumSize = new Size(minWidth, 34);
        btn.Padding = new Padding(14, 4, 14, 4);
        btn.FlatStyle = FlatStyle.Flat;
        btn.FlatAppearance.BorderSize = 0;
        btn.FlatAppearance.MouseOverBackColor = AccentBlueHover;
        btn.BackColor = AccentBlue;
        btn.ForeColor = Color.White;
        btn.Font = new Font("Microsoft YaHei UI", 9f, FontStyle.Bold);
        btn.Cursor = Cursors.Hand;
    }

    private static void StyleSecondaryButton(Button btn, int minWidth)
    {
        btn.AutoSize = true;
        btn.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        btn.MinimumSize = new Size(minWidth, 34);
        btn.Padding = new Padding(12, 4, 12, 4);
        btn.FlatStyle = FlatStyle.Flat;
        btn.FlatAppearance.BorderColor = Color.FromArgb(208, 213, 221);
        btn.FlatAppearance.BorderSize = 1;
        btn.FlatAppearance.MouseOverBackColor = Color.FromArgb(242, 244, 247);
        btn.BackColor = Color.White;
        btn.ForeColor = Color.FromArgb(45, 52, 64);
        btn.Cursor = Cursors.Hand;
    }

    private void OpenWebPage()
    {
        var url = string.IsNullOrWhiteSpace(_result.Release.HtmlUrl)
            ? "https://github.com/myucxy/VibeCodeContextMenu/releases/latest"
            : _result.Release.HtmlUrl;
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"无法打开浏览器:\n{ex.Message}", "提示", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async Task HandleDownloadAndInstallAsync()
    {
        if (_result.InstallerAsset is null || _isDownloading) return;

        _isDownloading = true;
        _downloadBtn.Enabled = false;
        _closeBtn.Text = "取消下载";
        _progressBar.Visible = true;
        _progressBar.Value = 0;
        _statusLabel.ForeColor = Color.FromArgb(30, 35, 45);

        _downloadCts?.Dispose();
        _downloadCts = new CancellationTokenSource();

        var progress = new Progress<(long Downloaded, long Total, string Status)>(p =>
        {
            if (IsDisposed) return;
            _statusLabel.Text = p.Status;
            if (p.Total > 0)
            {
                var pct = (int)Math.Clamp(p.Downloaded * 100L / p.Total, 0, 100);
                _progressBar.Style = ProgressBarStyle.Blocks;
                _progressBar.Value = pct;
            }
            else
            {
                _progressBar.Style = ProgressBarStyle.Marquee;
            }
        });

        try
        {
            var localFile = await UpdateService.DownloadAndVerifyAsync(
                _result.InstallerAsset,
                _result.Sha256Asset,
                progress,
                _downloadCts.Token);

            _statusLabel.ForeColor = Color.ForestGreen;

            if (localFile.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            {
                _statusLabel.Text = "SHA-256 校验通过，正在启动安装向导...";
                Process.Start(new ProcessStartInfo(localFile) { UseShellExecute = true });
                DialogResult = DialogResult.OK;
                Close();
                Application.Exit();
            }
            else
            {
                _statusLabel.Text = $"已下载到: {localFile}";
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{localFile}\"") { UseShellExecute = true });
                _closeBtn.Text = "关闭";
            }
        }
        catch (OperationCanceledException)
        {
            _statusLabel.Text = "已取消下载。";
            _statusLabel.ForeColor = Color.DarkOrange;
        }
        catch (Exception ex)
        {
            _statusLabel.Text = $"下载失败: {ex.Message}";
            _statusLabel.ForeColor = Color.Crimson;
        }
        finally
        {
            _isDownloading = false;
            if (!IsDisposed)
            {
                _downloadBtn.Enabled = _result.InstallerAsset is not null;
                if (_closeBtn.Text == "取消下载") _closeBtn.Text = "关闭";
            }
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (_isDownloading)
        {
            _downloadCts?.Cancel();
        }
        base.OnFormClosing(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _downloadCts?.Cancel();
            _downloadCts?.Dispose();
        }
        base.Dispose(disposing);
    }
}

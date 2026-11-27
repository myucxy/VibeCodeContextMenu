using System.Diagnostics;
using VibeCodeApp.Services;

namespace VibeCodeApp.UI;

/// <summary>
/// 发现新版本弹窗：支持一键下载校验并拉起安装，或打开 GitHub Release 网页手动下载。
/// </summary>
public sealed class UpdateDialog : Form
{
    private readonly UpdateCheckResult _result;
    private readonly ProgressBar _progressBar = new();
    private readonly Label _statusLabel = new();
    private readonly Button _downloadBtn = new();
    private readonly Button _webBtn = new();
    private readonly Button _closeBtn = new();
    private CancellationTokenSource? _downloadCts;
    private bool _isDownloading;

    public UpdateDialog(UpdateCheckResult result)
    {
        _result = result;

        Text = $"发现新版本 v{result.LatestVersion}";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(560, 420);
        MinimumSize = new Size(520, 380);
        Font = new Font("Microsoft YaHei UI", 9f);
        Icon = IconService.LoadMainAppIcon();

        BuildUI();
    }

    private void BuildUI()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 5,
            Padding = new Padding(16, 14, 16, 14)
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));      // 标题与版本对比
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));  // 更新日志
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));      // 进度条
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));      // 状态文字
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));      // 按钮栏

        var header = new Label
        {
            Text = $"VibeCode 有新版本可用：v{_result.CurrentVersion}  →  v{_result.LatestVersion}",
            Font = new Font(Font, FontStyle.Bold),
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 10)
        };
        root.Controls.Add(header, 0, 0);

        var notesText = string.IsNullOrWhiteSpace(_result.Release.Body)
            ? "（该版本未填写更新说明，可点击下方按钮前往 GitHub 查看详情。）"
            : _result.Release.Body.Replace("\r\n", "\n").Replace("\n", "\r\n");

        var notesBox = new TextBox
        {
            Dock = DockStyle.Fill,
            Multiline = true,
            ReadOnly = true,
            ScrollBars = ScrollBars.Vertical,
            BackColor = SystemColors.Window,
            Text = notesText,
            Margin = new Padding(0, 0, 0, 10)
        };
        root.Controls.Add(notesBox, 0, 1);

        _progressBar.Dock = DockStyle.Top;
        _progressBar.Height = 18;
        _progressBar.Minimum = 0;
        _progressBar.Maximum = 100;
        _progressBar.Visible = false;
        _progressBar.Margin = new Padding(0, 0, 0, 6);
        root.Controls.Add(_progressBar, 0, 2);

        _statusLabel.AutoSize = true;
        _statusLabel.ForeColor = SystemColors.GrayText;
        _statusLabel.Margin = new Padding(0, 0, 0, 10);
        _statusLabel.Text = _result.InstallerAsset is not null
            ? $"匹配安装包: {_result.InstallerAsset.Name} ({_result.InstallerAsset.Size / (1024.0 * 1024.0):F1} MB)"
            : "当前 Release 未找到匹配的自动安装包，请点击「打开网页手动下载」。";
        root.Controls.Add(_statusLabel, 0, 3);

        var btnBar = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
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
        _downloadBtn.Text = isSetupExe ? "一键下载并安装" : "下载更新包";
        StyleButton(_downloadBtn, 128);
        _downloadBtn.Enabled = _result.InstallerAsset is not null;
        _downloadBtn.Margin = new Padding(0, 0, 8, 0);
        _downloadBtn.Click += async (_, _) => await HandleDownloadAndInstallAsync();

        _webBtn.Text = "打开网页手动下载";
        StyleButton(_webBtn, 132);
        _webBtn.Margin = new Padding(0);
        _webBtn.Click += (_, _) => OpenWebPage();

        leftFlow.Controls.Add(_downloadBtn);
        leftFlow.Controls.Add(_webBtn);

        _closeBtn.Text = "稍后提醒";
        StyleButton(_closeBtn, 92);
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
        root.Controls.Add(btnBar, 0, 4);

        Controls.Add(root);
        CancelButton = _closeBtn;
    }

    private static void StyleButton(Button btn, int minWidth)
    {
        btn.AutoSize = true;
        btn.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        btn.MinimumSize = new Size(minWidth, 32);
        btn.Padding = new Padding(10, 2, 10, 2);
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
        _statusLabel.ForeColor = SystemColors.WindowText;

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
                _statusLabel.Text = "校验通过，正在启动安装向导...";
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

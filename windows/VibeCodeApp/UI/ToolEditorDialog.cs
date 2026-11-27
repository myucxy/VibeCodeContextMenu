using System.Drawing;
using VibeCodeApp.Models;
using VibeCodeApp.Services;

namespace VibeCodeApp.UI;

/// <summary>
/// 添加自定义 CLI / 编辑已有工具弹窗（与 macOS ToolEditorPanel 1:1 对齐）。
/// </summary>
public sealed class ToolEditorDialog : Form
{
    private readonly TextBox _nameBox = new();
    private readonly TextBox _cmdBox = new();
    private readonly CheckBox _superEnableCheck = new();
    private readonly TextBox _superLabelBox = new();
    private readonly TextBox _superCmdBox = new();
    private readonly TextBox _resumeCmdBox = new();
    private readonly TextBox _superEnvBox = new();
    private readonly CheckBox _directCheck = new();
    private readonly Label _iconPathLabel = new();

    private readonly bool _isEditing;
    private readonly HashSet<string> _otherNames;
    private readonly string? _existingIconName;
    private string? _importedIconSourcePath;

    public ToolEntry? ResultEntry { get; private set; }
    public string? ImportedIconSourcePath => _importedIconSourcePath;

    public ToolEditorDialog(ToolEntry? existingTool, IEnumerable<string> existingNames)
    {
        _isEditing = existingTool is not null;
        _existingIconName = existingTool?.Icon;
        _otherNames = new HashSet<string>(existingNames, StringComparer.OrdinalIgnoreCase);
        if (existingTool is not null)
        {
            _otherNames.Remove(existingTool.Name);
        }

        Text = _isEditing ? $"编辑工具: {existingTool!.Name}" : "添加自定义 AI CLI 工具";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        MinimumSize = new Size(560, 0);
        Font = new Font("Microsoft YaHei UI", 9f);
        Icon = IconService.LoadMainAppIcon();

        BuildLayout(existingTool);
    }

    private void BuildLayout(ToolEntry? existing)
    {
        var grid = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 2,
            RowCount = 11,
            Padding = new Padding(16, 14, 16, 14)
        };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (var r = 0; r < 11; r++) grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var row = 0;
        void AddFieldRow(string labelText, Control ctrl)
        {
            var lbl = new Label
            {
                Text = labelText,
                AutoSize = true,
                Anchor = AnchorStyles.Right,
                Margin = new Padding(0, 6, 10, 8)
            };
            ctrl.Dock = DockStyle.Fill;
            ctrl.MinimumSize = new Size(360, 0);
            ctrl.Margin = new Padding(0, 2, 0, 8);
            grid.Controls.Add(lbl, 0, row);
            grid.Controls.Add(ctrl, 1, row);
            row++;
        }

        var tip = new Label
        {
            Text = _isEditing
                ? "修改命令、Super 模式、环境变量或代理策略（自动同步 tools.json）。"
                : "填写任意自定义终端命令（19 款主流 AI CLI 已全部展示在主列表中）。",
            ForeColor = SystemColors.GrayText,
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 12)
        };
        grid.Controls.Add(tip, 0, row);
        grid.SetColumnSpan(tip, 2);
        row++;

        _nameBox.Text = existing?.Name ?? string.Empty;
        _nameBox.PlaceholderText = "例如: droid / lazygit / my-ai";
        AddFieldRow("工具名称:", _nameBox);

        _cmdBox.Text = existing?.Command ?? string.Empty;
        _cmdBox.PlaceholderText = "例如: droid 或 npx @scope/cli";
        AddFieldRow("基础命令:", _cmdBox);

        _superEnableCheck.Text = "启用 Super 模式（自动批准 / 跳过确认）";
        _superEnableCheck.AutoSize = true;
        _superEnableCheck.Checked = existing?.Super is not null;
        _superEnableCheck.Margin = new Padding(0, 2, 0, 8);
        _superEnableCheck.CheckedChanged += (_, _) => UpdateSuperFieldsEnabled();
        grid.Controls.Add(_superEnableCheck, 1, row++);

        _superLabelBox.Text = existing?.Super?.Label ?? string.Empty;
        _superLabelBox.PlaceholderText = "例如: myAiSuper（留空默认 <名称>Super）";
        AddFieldRow("Super 名称:", _superLabelBox);

        _superCmdBox.Text = existing?.Super?.Command ?? string.Empty;
        _superCmdBox.PlaceholderText = "例如: my-ai --yolo";
        AddFieldRow("Super 命令:", _superCmdBox);

        _resumeCmdBox.Text = existing?.Super?.Resume?.Command ?? string.Empty;
        _resumeCmdBox.PlaceholderText = "留空默认使用 <Super命令> -R";
        AddFieldRow("恢复命令:", _resumeCmdBox);

        if (existing?.Super?.Env is { Count: > 0 } envDict)
        {
            _superEnvBox.Text = string.Join("; ", envDict.OrderBy(k => k.Key).Select(k => $"{k.Key}={k.Value}"));
        }
        _superEnvBox.PlaceholderText = "可选，多个用分号分隔，如: OPENCODE_PERMISSION=\"allow\"";
        AddFieldRow("Super 环境变量:", _superEnvBox);

        _directCheck.Text = "强制直连（忽略 VibeCode CLI 代理，适合国内模型）";
        _directCheck.AutoSize = true;
        _directCheck.Checked = existing?.UseProxy == false;
        _directCheck.Margin = new Padding(0, 2, 0, 10);
        grid.Controls.Add(_directCheck, 1, row++);

        // 自定义图标选择行
        var iconTitle = new Label
        {
            Text = "菜单图标:",
            AutoSize = true,
            Anchor = AnchorStyles.Right,
            Margin = new Padding(0, 6, 10, 10)
        };
        var iconRow = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 2,
            RowCount = 1,
            Margin = new Padding(0, 0, 0, 10)
        };
        iconRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        iconRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        _iconPathLabel.Text = string.IsNullOrWhiteSpace(_existingIconName) ? "自动生成品牌圆角图标" : _existingIconName;
        _iconPathLabel.ForeColor = SystemColors.GrayText;
        _iconPathLabel.AutoSize = true;
        _iconPathLabel.Anchor = AnchorStyles.Left;
        _iconPathLabel.Margin = new Padding(0, 6, 8, 0);

        var pickIconBtn = new Button
        {
            Text = "选择图标...",
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            MinimumSize = new Size(100, 30),
            Padding = new Padding(8, 2, 8, 2),
            Anchor = AnchorStyles.Right
        };
        pickIconBtn.Click += HandlePickIcon;

        iconRow.Controls.Add(_iconPathLabel, 0, 0);
        iconRow.Controls.Add(pickIconBtn, 1, 0);
        grid.Controls.Add(iconTitle, 0, row);
        grid.Controls.Add(iconRow, 1, row);
        row++;

        // 底部确定 / 取消按钮
        var btnFlow = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            FlowDirection = FlowDirection.RightToLeft,
            Margin = new Padding(0, 6, 0, 0)
        };

        var cancelBtn = new Button
        {
            Text = "取消",
            DialogResult = DialogResult.Cancel,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            MinimumSize = new Size(88, 32),
            Padding = new Padding(10, 2, 10, 2),
            Margin = new Padding(8, 0, 0, 0)
        };

        var okBtn = new Button
        {
            Text = _isEditing ? "保存修改" : "添加工具",
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            MinimumSize = new Size(96, 32),
            Padding = new Padding(10, 2, 10, 2),
            Margin = new Padding(0)
        };
        okBtn.Click += HandleConfirm;

        btnFlow.Controls.Add(cancelBtn);
        btnFlow.Controls.Add(okBtn);
        grid.Controls.Add(btnFlow, 0, row);
        grid.SetColumnSpan(btnFlow, 2);

        Controls.Add(grid);
        AcceptButton = okBtn;
        CancelButton = cancelBtn;

        UpdateSuperFieldsEnabled();
    }

    private void UpdateSuperFieldsEnabled()
    {
        var on = _superEnableCheck.Checked;
        _superLabelBox.Enabled = on;
        _superCmdBox.Enabled = on;
        _resumeCmdBox.Enabled = on;
        _superEnvBox.Enabled = on;
    }

    private void HandlePickIcon(object? sender, EventArgs e)
    {
        using var ofd = new OpenFileDialog
        {
            Title = "选择工具图标",
            Filter = "图标与图片 (*.ico;*.png;*.jpg;*.jpeg)|*.ico;*.png;*.jpg;*.jpeg|所有文件 (*.*)|*.*"
        };
        if (ofd.ShowDialog(this) == DialogResult.OK)
        {
            _importedIconSourcePath = ofd.FileName;
            _iconPathLabel.Text = $"已选: {Path.GetFileName(ofd.FileName)}";
        }
    }

    private void HandleConfirm(object? sender, EventArgs e)
    {
        var finalName = _nameBox.Text.Trim();
        var finalCmd = _cmdBox.Text.Trim();
        if (string.IsNullOrEmpty(finalName) || string.IsNullOrEmpty(finalCmd))
        {
            MessageBox.Show(this, "请填写工具名称和基础命令。", "输入不完整", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        if (_otherNames.Contains(finalName))
        {
            MessageBox.Show(this, $"工具「{finalName}」已存在，请更换名称或直接编辑该工具。", "名称重复", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        SuperEntry? superObj = null;
        if (_superEnableCheck.Checked)
        {
            var sCmd = _superCmdBox.Text.Trim();
            if (!string.IsNullOrEmpty(sCmd))
            {
                var sLabel = _superLabelBox.Text.Trim();
                if (string.IsNullOrEmpty(sLabel)) sLabel = $"{finalName}Super";

                var rCmd = _resumeCmdBox.Text.Trim();
                var envDict = new Dictionary<string, string>();
                var rawEnv = _superEnvBox.Text.Trim();
                if (!string.IsNullOrEmpty(rawEnv))
                {
                    foreach (var part in rawEnv.Split(';', StringSplitOptions.RemoveEmptyEntries))
                    {
                        var eq = part.IndexOf('=');
                        if (eq > 0 && eq < part.Length - 1)
                        {
                            var k = part[..eq].Trim();
                            var v = part[(eq + 1)..].Trim();
                            if (!string.IsNullOrEmpty(k)) envDict[k] = v;
                        }
                    }
                }

                superObj = new SuperEntry
                {
                    Label = sLabel,
                    Command = sCmd,
                    Env = envDict.Count > 0 ? envDict : null,
                    Resume = string.IsNullOrEmpty(rCmd) ? null : new ResumeEntry { Command = rCmd }
                };
            }
        }

        ResultEntry = new ToolEntry
        {
            Name = finalName,
            Command = finalCmd,
            Icon = _existingIconName,
            UseProxy = _directCheck.Checked ? false : null,
            Super = superObj
        };

        DialogResult = DialogResult.OK;
        Close();
    }
}

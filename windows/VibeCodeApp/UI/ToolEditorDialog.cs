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
        ClientSize = new Size(520, 415);
        Font = new Font("Microsoft YaHei UI", 9f);
        Icon = IconService.LoadMainAppIcon();

        BuildLayout(existingTool);
    }

    private void BuildLayout(ToolEntry? existing)
    {
        var y = 16;
        const int labelX = 16;
        const int labelW = 104;
        const int fieldX = 126;
        const int fieldW = 376;

        void AddFieldRow(string labelText, Control ctrl, int height = 25)
        {
            var lbl = new Label
            {
                Text = labelText,
                Location = new Point(labelX, y + 4),
                Size = new Size(labelW, 20),
                TextAlign = ContentAlignment.MiddleRight
            };
            ctrl.Location = new Point(fieldX, y);
            ctrl.Size = new Size(fieldW, height);
            Controls.Add(lbl);
            Controls.Add(ctrl);
            y += height + 10;
        }

        var tip = new Label
        {
            Text = _isEditing
                ? "修改命令、Super 模式、环境变量或代理策略（自动同步 tools.json）。"
                : "填写任意自定义终端命令（19 款主流 AI CLI 已全部展示在主列表中）。",
            ForeColor = SystemColors.GrayText,
            Location = new Point(16, y),
            Size = new Size(488, 22)
        };
        Controls.Add(tip);
        y += 30;

        _nameBox.Text = existing?.Name ?? string.Empty;
        _nameBox.PlaceholderText = "例如: droid / lazygit / my-ai";
        AddFieldRow("工具名称:", _nameBox);

        _cmdBox.Text = existing?.Command ?? string.Empty;
        _cmdBox.PlaceholderText = "例如: droid 或 npx @scope/cli";
        AddFieldRow("基础命令:", _cmdBox);

        _superEnableCheck.Text = "启用 Super 模式（自动批准 / 跳过确认）";
        _superEnableCheck.Checked = existing?.Super is not null;
        _superEnableCheck.Location = new Point(fieldX, y);
        _superEnableCheck.Size = new Size(fieldW, 24);
        _superEnableCheck.CheckedChanged += (_, _) => UpdateSuperFieldsEnabled();
        Controls.Add(_superEnableCheck);
        y += 30;

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
        _directCheck.Checked = existing?.UseProxy == false;
        _directCheck.Location = new Point(fieldX, y);
        _directCheck.Size = new Size(fieldW, 24);
        Controls.Add(_directCheck);
        y += 32;

        // 自定义图标选择行
        var iconTitle = new Label
        {
            Text = "菜单图标:",
            Location = new Point(labelX, y + 4),
            Size = new Size(labelW, 20),
            TextAlign = ContentAlignment.MiddleRight
        };
        _iconPathLabel.Text = string.IsNullOrWhiteSpace(_existingIconName) ? "自动生成品牌圆角图标" : _existingIconName;
        _iconPathLabel.ForeColor = SystemColors.GrayText;
        _iconPathLabel.Location = new Point(fieldX, y + 4);
        _iconPathLabel.Size = new Size(254, 20);
        _iconPathLabel.AutoEllipsis = true;

        var pickIconBtn = new Button
        {
            Text = "选择图标...",
            Location = new Point(fieldX + 260, y),
            Size = new Size(116, 26)
        };
        pickIconBtn.Click += HandlePickIcon;

        Controls.Add(iconTitle);
        Controls.Add(_iconPathLabel);
        Controls.Add(pickIconBtn);
        y += 40;

        // 底部确定 / 取消按钮
        var okBtn = new Button
        {
            Text = _isEditing ? "保存修改" : "添加工具",
            Location = new Point(316, y),
            Size = new Size(92, 30)
        };
        okBtn.Click += HandleConfirm;

        var cancelBtn = new Button
        {
            Text = "取消",
            DialogResult = DialogResult.Cancel,
            Location = new Point(414, y),
            Size = new Size(88, 30)
        };

        Controls.Add(okBtn);
        Controls.Add(cancelBtn);
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

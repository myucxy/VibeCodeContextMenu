using System.Diagnostics;
using System.Drawing;
using VibeCodeApp.Models;
using VibeCodeApp.Services;

namespace VibeCodeApp.UI;

public enum MainTabIndex
{
    Tools = 0,
    ProxyAndTerminal = 1,
    About = 2
}

/// <summary>
/// Windows 原生三标签页设置窗口（与 macOS 版 1:1 功能对齐）：
/// 1. 工具与右键菜单（总开关 / 排版 / 模式筛选 / 19+ 工具勾选与拖拽排序 / 自定义增删改）
/// 2. 代理与终端（10 款终端自动检测下拉 / Windows 系统代理填入 / 手动配置与异步测速）
/// 3. 关于（版本 / 作者 清风惹尘丶 / GitHub 链接 / 配置目录）
/// </summary>
public sealed class MainSettingsForm : Form
{
    private readonly TabControl _tabControl = new();

    // Tab 1: 工具与右键菜单
    private readonly List<ToolRowModel> _rows = new();
    private readonly ImageList _toolImageList = new() { ImageSize = new Size(20, 20), ColorDepth = ColorDepth.Depth32Bit };
    private readonly CheckBox _masterSwitch = new();
    private readonly Label _masterStatusLabel = new();
    private readonly ComboBox _layoutCombo = new();
    private readonly CheckBox _normalModeCheck = new();
    private readonly CheckBox _superModeCheck = new();
    private readonly CheckBox _resumeModeCheck = new();
    private readonly Label _countHintLabel = new();
    private readonly ListView _toolListView = new();
    private readonly Button _addBtn = new();
    private readonly Button _editBtn = new();
    private readonly Button _deleteBtn = new();
    private readonly Button _moveUpBtn = new();
    private readonly Button _moveDownBtn = new();
    private readonly Button _refreshBtn = new();
    private bool _suppressEvents;
    private bool _inhibitCheckOnDoubleClick;

    // Tab 2: 代理与终端
    private readonly ComboBox _terminalCombo = new();
    private readonly Label _terminalDetectHintLabel = new();
    private List<DetectedTerminal> _detectedTerminals = new();
    private readonly CheckBox _proxyEnableCheck = new();
    private readonly CheckBox _proxyFollowSystemCheck = new();
    private readonly Label _sysProxyHintLabel = new();
    private readonly Button _fillSysProxyBtn = new();
    private readonly TextBox _proxyUrlBox = new();
    private readonly TextBox _noProxyBox = new();
    private readonly Button _saveProxyBtn = new();
    private readonly Button _testProxyBtn = new();
    private readonly Label _proxyFeedbackLabel = new();
    private readonly TextBox _proxyTestOutputBox = new();
    private string? _detectedSystemProxy;
    private CancellationTokenSource? _proxyTestCts;

    public MainSettingsForm()
    {
        Text = "VibeCode 设置";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(740, 620);
        MinimumSize = new Size(700, 560);
        Font = new Font("Microsoft YaHei UI", 9f);
        Icon = IconService.LoadMainAppIcon();

        BuildUI();
        ReloadAllFromDisk();
    }

    public void ShowAndSelectTab(MainTabIndex? tab = null)
    {
        ReloadAllFromDisk();
        if (tab.HasValue && (int)tab.Value < _tabControl.TabPages.Count)
        {
            _tabControl.SelectedIndex = (int)tab.Value;
        }
        if (!Visible)
        {
            Show();
        }
        if (WindowState == FormWindowState.Minimized)
        {
            WindowState = FormWindowState.Normal;
        }
        Activate();
        BringToFront();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // 点击右上角关闭按钮时仅隐藏回系统托盘，不退出后台驻留
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            _proxyTestCts?.Cancel();
            Hide();
            return;
        }
        base.OnFormClosing(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _proxyTestCts?.Cancel();
            _proxyTestCts?.Dispose();
            _toolImageList.Dispose();
        }
        base.Dispose(disposing);
    }

    private void BuildUI()
    {
        _tabControl.Dock = DockStyle.Fill;
        _tabControl.Padding = new Point(14, 6);

        var toolsPage = new TabPage("工具与右键菜单") { Padding = new Padding(12) };
        BuildToolsTab(toolsPage);
        _tabControl.TabPages.Add(toolsPage);

        var proxyPage = new TabPage("代理与终端") { Padding = new Padding(12) };
        BuildProxyAndTerminalTab(proxyPage);
        _tabControl.TabPages.Add(proxyPage);

        var aboutPage = new TabPage("关于") { Padding = new Padding(16) };
        BuildAboutTab(aboutPage);
        _tabControl.TabPages.Add(aboutPage);

        var outer = new Panel { Dock = DockStyle.Fill, Padding = new Padding(10) };
        outer.Controls.Add(_tabControl);
        Controls.Add(outer);
    }

    // =========================================================================
    // Tab 1: 工具与右键菜单
    // =========================================================================

    private void BuildToolsTab(TabPage page)
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 5
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 114)); // 顶部控制卡片
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));  // 列表标题栏
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));  // 工具列表
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));  // 按钮栏
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 22));  // 底部提示

        // 1. 顶部控制分组框
        var headerGroup = new GroupBox
        {
            Text = "资源管理器右键菜单",
            Dock = DockStyle.Fill,
            Padding = new Padding(10, 6, 10, 6)
        };

        _masterSwitch.Text = "在资源管理器右键菜单中显示 VibeCode";
        _masterSwitch.Font = new Font(Font, FontStyle.Bold);
        _masterSwitch.Location = new Point(14, 22);
        _masterSwitch.AutoSize = true;
        _masterSwitch.CheckedChanged += (_, _) => HandleDisplayOptionChanged();

        _masterStatusLabel.Location = new Point(320, 24);
        _masterStatusLabel.Size = new Size(340, 20);
        _masterStatusLabel.TextAlign = ContentAlignment.MiddleRight;
        _masterStatusLabel.Anchor = AnchorStyles.Top | AnchorStyles.Right;

        var layoutLbl = new Label
        {
            Text = "菜单排版:",
            Location = new Point(14, 62),
            Size = new Size(68, 22),
            TextAlign = ContentAlignment.MiddleLeft
        };
        _layoutCombo.DropDownStyle = ComboBoxStyle.DropDownList;
        _layoutCombo.Items.AddRange([
            "自动（>5 个工具时折叠）",
            "平铺展开（全部同级）",
            "按工具折叠二级子菜单"
        ]);
        _layoutCombo.Location = new Point(84, 60);
        _layoutCombo.Size = new Size(196, 24);
        _layoutCombo.SelectedIndexChanged += (_, _) => HandleDisplayOptionChanged();

        var modeLbl = new Label
        {
            Text = "显示项:",
            Location = new Point(296, 62),
            Size = new Size(54, 22),
            TextAlign = ContentAlignment.MiddleLeft
        };

        _normalModeCheck.Text = "普通";
        _normalModeCheck.Location = new Point(354, 62);
        _normalModeCheck.AutoSize = true;
        _normalModeCheck.CheckedChanged += (_, _) => HandleDisplayOptionChanged();

        _superModeCheck.Text = "Super";
        _superModeCheck.Location = new Point(422, 62);
        _superModeCheck.AutoSize = true;
        _superModeCheck.CheckedChanged += (_, _) => HandleDisplayOptionChanged();

        _resumeModeCheck.Text = "恢复 (-R)";
        _resumeModeCheck.Location = new Point(496, 62);
        _resumeModeCheck.AutoSize = true;
        _resumeModeCheck.CheckedChanged += (_, _) => HandleDisplayOptionChanged();

        headerGroup.Controls.AddRange([_masterSwitch, _masterStatusLabel, layoutLbl, _layoutCombo, modeLbl, _normalModeCheck, _superModeCheck, _resumeModeCheck]);
        root.Controls.Add(headerGroup, 0, 0);

        // 2. 列表标题与计数栏
        var titleRow = new Panel { Dock = DockStyle.Fill };
        var sectionLabel = new Label
        {
            Text = "全部 AI 工具（未安装项不可勾选；拖拽或上下移排序，双击编辑）",
            ForeColor = SystemColors.GrayText,
            Dock = DockStyle.Left,
            AutoSize = true,
            Padding = new Padding(2, 6, 0, 0)
        };
        _countHintLabel.Dock = DockStyle.Right;
        _countHintLabel.AutoSize = true;
        _countHintLabel.ForeColor = SystemColors.GrayText;
        _countHintLabel.Padding = new Padding(0, 6, 2, 0);
        titleRow.Controls.Add(sectionLabel);
        titleRow.Controls.Add(_countHintLabel);
        root.Controls.Add(titleRow, 0, 1);

        // 3. 工具列表 ListView（支持勾选、图标、未安装拦截、拖拽重排）
        _toolListView.Dock = DockStyle.Fill;
        _toolListView.View = View.Details;
        _toolListView.FullRowSelect = true;
        _toolListView.GridLines = true;
        _toolListView.CheckBoxes = true;
        _toolListView.MultiSelect = false;
        _toolListView.HideSelection = false;
        _toolListView.AllowDrop = true;
        _toolListView.SmallImageList = _toolImageList;

        _toolListView.Columns.Add("工具名称", 210);
        _toolListView.Columns.Add("启动命令与模式", 265);
        _toolListView.Columns.Add("网络", 64, HorizontalAlignment.Center);
        _toolListView.Columns.Add("状态", 74, HorizontalAlignment.Center);

        _toolListView.MouseDown += (_, e) => _inhibitCheckOnDoubleClick = e.Clicks >= 2;
        _toolListView.ItemCheck += HandleToolItemCheck;
        _toolListView.SelectedIndexChanged += (_, _) => UpdateActionButtonsAndSummary();
        _toolListView.DoubleClick += (_, _) => HandleEditSelected();
        _toolListView.ItemDrag += HandleToolItemDrag;
        _toolListView.DragEnter += HandleToolDragEnter;
        _toolListView.DragOver += HandleToolDragEnter;
        _toolListView.DragDrop += HandleToolDragDrop;

        root.Controls.Add(_toolListView, 0, 2);

        // 4. 操作按钮栏
        var btnBar = new Panel { Dock = DockStyle.Fill, Size = new Size(680, 42), Padding = new Padding(0, 8, 0, 2) };

        _addBtn.Text = "+ 自定义工具";
        _addBtn.Location = new Point(0, 8);
        _addBtn.Size = new Size(102, 28);
        _addBtn.Click += (_, _) => HandleAddTool();

        _editBtn.Text = "编辑";
        _editBtn.Location = new Point(108, 8);
        _editBtn.Size = new Size(64, 28);
        _editBtn.Click += (_, _) => HandleEditSelected();

        _deleteBtn.Text = "删除";
        _deleteBtn.Location = new Point(178, 8);
        _deleteBtn.Size = new Size(64, 28);
        _deleteBtn.Click += (_, _) => HandleDeleteSelected();

        _moveUpBtn.Text = "上移 ↑";
        _moveUpBtn.Location = new Point(260, 8);
        _moveUpBtn.Size = new Size(74, 28);
        _moveUpBtn.Click += (_, _) => HandleMoveSelected(-1);

        _moveDownBtn.Text = "下移 ↓";
        _moveDownBtn.Location = new Point(340, 8);
        _moveDownBtn.Size = new Size(74, 28);
        _moveDownBtn.Click += (_, _) => HandleMoveSelected(+1);

        _refreshBtn.Text = "刷新检测";
        _refreshBtn.Size = new Size(88, 28);
        _refreshBtn.Location = new Point(btnBar.Width - 88, 8);
        _refreshBtn.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        _refreshBtn.Click += (_, _) => ReloadAllFromDisk();

        btnBar.Controls.AddRange([_addBtn, _editBtn, _deleteBtn, _moveUpBtn, _moveDownBtn, _refreshBtn]);
        root.Controls.Add(btnBar, 0, 3);

        // 5. 底部提示
        var footer = new Label
        {
            Text = "仅本机已安装的 CLI 允许勾选进右键菜单；所有修改实时写入注册表，无需重启资源管理器。",
            ForeColor = SystemColors.GrayText,
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft
        };
        root.Controls.Add(footer, 0, 4);

        page.Controls.Add(root);
    }

    // =========================================================================
    // Tab 2: 代理与终端
    // =========================================================================

    private void BuildProxyAndTerminalTab(TabPage page)
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 118));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        // 卡片 1: 默认终端自动检测
        var termGroup = new GroupBox
        {
            Text = "默认终端（下拉仅显示本机已检测到的终端）",
            Dock = DockStyle.Fill,
            Padding = new Padding(12, 8, 12, 8)
        };

        var termLbl = new Label
        {
            Text = "默认终端:",
            Location = new Point(14, 30),
            Size = new Size(74, 22),
            TextAlign = ContentAlignment.MiddleLeft
        };

        _terminalCombo.DropDownStyle = ComboBoxStyle.DropDownList;
        _terminalCombo.Location = new Point(92, 28);
        _terminalCombo.Size = new Size(240, 24);
        _terminalCombo.SelectedIndexChanged += (_, _) => HandleTerminalChanged();

        var redetectBtn = new Button
        {
            Text = "重新检测",
            Location = new Point(342, 27),
            Size = new Size(88, 26)
        };
        redetectBtn.Click += (_, _) => ReloadProxyAndTerminalTab();

        _terminalDetectHintLabel.Location = new Point(14, 66);
        _terminalDetectHintLabel.Size = new Size(650, 36);
        _terminalDetectHintLabel.ForeColor = SystemColors.GrayText;
        _terminalDetectHintLabel.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;

        termGroup.Controls.AddRange([termLbl, _terminalCombo, redetectBtn, _terminalDetectHintLabel]);
        root.Controls.Add(termGroup, 0, 0);

        // 卡片 2: CLI 代理配置与连通性测速
        var proxyGroup = new GroupBox
        {
            Text = "CLI 代理（仅注入给 VibeCode 启动的终端会话，不修改系统环境变量）",
            Dock = DockStyle.Fill,
            Padding = new Padding(12, 8, 12, 8)
        };

        var proxyLayout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2
        };
        proxyLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 184));
        proxyLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var proxyForm = new Panel { Dock = DockStyle.Fill, Size = new Size(660, 184) };

        _proxyEnableCheck.Text = "启用 CLI 代理";
        _proxyEnableCheck.Font = new Font(Font, FontStyle.Bold);
        _proxyEnableCheck.Location = new Point(4, 6);
        _proxyEnableCheck.AutoSize = true;
        _proxyEnableCheck.CheckedChanged += (_, _) =>
        {
            UpdateProxyInputState();
            if (!_suppressEvents) SaveProxySettings();
        };

        _proxyFollowSystemCheck.Text = "跟随 Windows 系统代理（开代理生效，关代理直连）";
        _proxyFollowSystemCheck.Location = new Point(140, 6);
        _proxyFollowSystemCheck.AutoSize = true;
        _proxyFollowSystemCheck.CheckedChanged += (_, _) =>
        {
            UpdateProxyInputState();
            if (!_suppressEvents) SaveProxySettings();
        };

        _sysProxyHintLabel.Location = new Point(4, 34);
        _sysProxyHintLabel.Size = new Size(520, 22);
        _sysProxyHintLabel.ForeColor = SystemColors.GrayText;
        _sysProxyHintLabel.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;

        _fillSysProxyBtn.Text = "填入系统代理";
        _fillSysProxyBtn.Size = new Size(112, 26);
        _fillSysProxyBtn.Location = new Point(proxyForm.Width - 116, 30);
        _fillSysProxyBtn.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        _fillSysProxyBtn.Click += (_, _) => HandleFillSystemProxy();

        var urlLbl = new Label
        {
            Text = "代理地址:",
            Location = new Point(4, 68),
            Size = new Size(76, 22),
            TextAlign = ContentAlignment.MiddleRight
        };
        _proxyUrlBox.PlaceholderText = "例如: http://127.0.0.1:7897 或 socks5://127.0.0.1:7897";
        _proxyUrlBox.Location = new Point(86, 66);
        _proxyUrlBox.Size = new Size(proxyForm.Width - 92, 25);
        _proxyUrlBox.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;

        var noProxyLbl = new Label
        {
            Text = "NO_PROXY:",
            Location = new Point(4, 100),
            Size = new Size(76, 22),
            TextAlign = ContentAlignment.MiddleRight
        };
        _noProxyBox.PlaceholderText = AppMetadata.DefaultNoProxy;
        _noProxyBox.Location = new Point(86, 98);
        _noProxyBox.Size = new Size(proxyForm.Width - 92, 25);
        _noProxyBox.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;

        _saveProxyBtn.Text = "保存代理设置";
        _saveProxyBtn.Location = new Point(86, 132);
        _saveProxyBtn.Size = new Size(106, 28);
        _saveProxyBtn.Click += (_, _) => SaveProxySettings();

        _testProxyBtn.Text = "测试连通性";
        _testProxyBtn.Location = new Point(200, 132);
        _testProxyBtn.Size = new Size(96, 28);
        _testProxyBtn.Click += async (_, _) => await HandleTestProxyAsync();

        _proxyFeedbackLabel.Location = new Point(308, 136);
        _proxyFeedbackLabel.Size = new Size(340, 22);
        _proxyFeedbackLabel.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;

        var directTip = new Label
        {
            Text = "提示: 如需为国内模型（如 qwen / kimi）单独直连，请在「工具与右键菜单」双击该工具勾选「强制直连」。",
            ForeColor = SystemColors.GrayText,
            Location = new Point(4, 164),
            Size = new Size(640, 18),
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right
        };

        proxyForm.Controls.AddRange([
            _proxyEnableCheck, _proxyFollowSystemCheck, _sysProxyHintLabel, _fillSysProxyBtn,
            urlLbl, _proxyUrlBox, noProxyLbl, _noProxyBox,
            _saveProxyBtn, _testProxyBtn, _proxyFeedbackLabel, directTip
        ]);

        _proxyTestOutputBox.Dock = DockStyle.Fill;
        _proxyTestOutputBox.Multiline = true;
        _proxyTestOutputBox.ReadOnly = true;
        _proxyTestOutputBox.ScrollBars = ScrollBars.Vertical;
        _proxyTestOutputBox.Font = new Font("Consolas", 9.5f);
        _proxyTestOutputBox.BackColor = SystemColors.Window;
        _proxyTestOutputBox.Text = "点击「测试连通性」可检测当前代理访问 Google、Antigravity、Anthropic 与 OpenAI 的状态。";

        proxyLayout.Controls.Add(proxyForm, 0, 0);
        proxyLayout.Controls.Add(_proxyTestOutputBox, 0, 1);
        proxyGroup.Controls.Add(proxyLayout);
        root.Controls.Add(proxyGroup, 0, 1);

        page.Controls.Add(root);
    }

    // =========================================================================
    // Tab 3: 关于
    // =========================================================================

    private void BuildAboutTab(TabPage page)
    {
        var card = new Panel
        {
            Dock = DockStyle.Fill,
            BorderStyle = BorderStyle.FixedSingle,
            BackColor = SystemColors.Window
        };

        var stack = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 9,
            Padding = new Padding(24, 34, 24, 24)
        };
        for (var i = 0; i < 8; i++)
        {
            stack.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        }
        stack.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var pic = new PictureBox
        {
            Image = IconService.LoadToolBitmap("VibeCode", "vibecode.ico", 64),
            Size = new Size(64, 64),
            SizeMode = PictureBoxSizeMode.Zoom,
            Anchor = AnchorStyles.None,
            Margin = new Padding(0, 6, 0, 10)
        };

        var title = new Label
        {
            Text = "VibeCode Context Menu",
            Font = new Font("Microsoft YaHei UI", 16f, FontStyle.Bold),
            AutoSize = true,
            Anchor = AnchorStyles.None
        };

        var ver = new Label
        {
            Text = $"Windows 原生版 · v{AppPaths.AppVersion}",
            ForeColor = SystemColors.GrayText,
            AutoSize = true,
            Anchor = AnchorStyles.None,
            Margin = new Padding(0, 4, 0, 8)
        };

        var desc = new Label
        {
            Text = "在资源管理器右键文件夹及空白处一键启动各类 AI CLI 工具",
            ForeColor = SystemColors.GrayText,
            AutoSize = true,
            Anchor = AnchorStyles.None,
            Margin = new Padding(0, 0, 0, 18)
        };

        var author = new Label
        {
            Text = $"作者：{AppMetadata.AuthorName}",
            Font = new Font("Microsoft YaHei UI", 11f, FontStyle.Bold),
            AutoSize = true,
            Anchor = AnchorStyles.None,
            Margin = new Padding(0, 8, 0, 8)
        };

        var githubLink = new LinkLabel
        {
            Text = AppMetadata.GitHubUrl,
            Font = new Font("Microsoft YaHei UI", 10f),
            AutoSize = true,
            Anchor = AnchorStyles.None,
            Margin = new Padding(0, 0, 0, 22)
        };
        githubLink.LinkClicked += (_, _) => OpenUrl(AppMetadata.GitHubUrl);

        var openGitBtn = new Button
        {
            Text = "访问 GitHub 仓库",
            Size = new Size(148, 32),
            Anchor = AnchorStyles.None,
            Margin = new Padding(0, 0, 0, 14)
        };
        openGitBtn.Click += (_, _) => OpenUrl(AppMetadata.GitHubUrl);

        var auxPanel = new FlowLayoutPanel
        {
            AutoSize = true,
            Anchor = AnchorStyles.None,
            FlowDirection = FlowDirection.LeftToRight
        };
        var openDirBtn = new Button { Text = "打开配置目录", Size = new Size(116, 28) };
        openDirBtn.Click += (_, _) => OpenPath(AppPaths.SupportDir);
        var editJsonBtn = new Button { Text = "编辑 tools.json", Size = new Size(116, 28) };
        editJsonBtn.Click += (_, _) => OpenPath(AppPaths.ToolsConfigPath);
        auxPanel.Controls.Add(openDirBtn);
        auxPanel.Controls.Add(editJsonBtn);

        stack.Controls.Add(pic, 0, 0);
        stack.Controls.Add(title, 0, 1);
        stack.Controls.Add(ver, 0, 2);
        stack.Controls.Add(desc, 0, 3);
        stack.Controls.Add(author, 0, 4);
        stack.Controls.Add(githubLink, 0, 5);
        stack.Controls.Add(openGitBtn, 0, 6);
        stack.Controls.Add(auxPanel, 0, 7);

        card.Controls.Add(stack);
        page.Controls.Add(card);
    }

    // =========================================================================
    // 数据刷新与持久化
    // =========================================================================

    public void ReloadAllFromDisk()
    {
        _suppressEvents = true;
        try
        {
            ReloadToolsTab();
            ReloadProxyAndTerminalTab();
        }
        finally
        {
            _suppressEvents = false;
        }
    }

    private void ReloadToolsTab()
    {
        var toolsCfg = ConfigService.LoadToolsConfig();
        var winCfg = ConfigService.LoadWindowsConfig();

        _masterSwitch.Checked = winCfg.ContextMenuEnabled;
        UpdateMasterStatusLabel(winCfg.ContextMenuEnabled, toolsCfg.MenuName);

        _layoutCombo.SelectedIndex = (winCfg.MenuLayout ?? "auto").ToLowerInvariant() switch
        {
            "flat" => 1,
            "grouped" => 2,
            _ => 0
        };
        _normalModeCheck.Checked = winCfg.ShowNormalMode;
        _superModeCheck.Checked = winCfg.ShowSuperMode;
        _resumeModeCheck.Checked = winCfg.ShowResumeMode;

        // 合并 tools.json + 全量 19 款内置 AI CLI 预置
        var configuredTools = toolsCfg.Tools;
        var presetByName = BuiltinPresets.All.ToDictionary(p => p.Name, StringComparer.OrdinalIgnoreCase);

        var catalog = new Dictionary<string, (ToolEntry Entry, AiCliPreset? Preset, bool Persisted)>(StringComparer.OrdinalIgnoreCase);
        foreach (var t in configuredTools)
        {
            if (string.IsNullOrWhiteSpace(t.Name)) continue;
            presetByName.TryGetValue(t.Name, out var preset);
            catalog[t.Name] = (t.Clone(), preset, true);
        }
        foreach (var p in BuiltinPresets.All)
        {
            if (!catalog.ContainsKey(p.Name))
            {
                catalog[p.Name] = (p.ToToolEntry(), p, false);
            }
        }

        var enabledList = winCfg.EnabledTools ?? configuredTools.Select(t => t.Name).ToList();
        var enabledSet = new HashSet<string>(enabledList, StringComparer.OrdinalIgnoreCase);

        var defaultNames = configuredTools.Select(t => t.Name).Concat(BuiltinPresets.All.Select(p => p.Name));
        var orderedNames = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in (winCfg.ToolOrder ?? Enumerable.Empty<string>()).Concat(enabledList).Concat(defaultNames))
        {
            if (catalog.ContainsKey(name) && seen.Add(name))
            {
                orderedNames.Add(name);
            }
        }

        var searchPaths = ToolDetector.BuildSearchPaths();
        var installedRows = new List<ToolRowModel>();
        var uninstalledRows = new List<ToolRowModel>();

        foreach (var name in orderedNames)
        {
            var item = catalog[name];
            var installed = ToolDetector.IsCommandInstalled(item.Entry.Command, searchPaths);
            var row = new ToolRowModel
            {
                Entry = item.Entry,
                DisplaySubtitle = item.Preset?.DisplayName,
                IsBuiltinPreset = item.Preset is not null,
                PersistedInToolsJson = item.Persisted,
                Installed = installed,
                Enabled = installed && enabledSet.Contains(name)
            };
            if (installed) installedRows.Add(row);
            else uninstalledRows.Add(row);
        }

        _rows.Clear();
        _rows.AddRange(installedRows);
        _rows.AddRange(uninstalledRows);

        RebuildListView(selectedIndex: -1);
    }

    private void RebuildListView(int selectedIndex)
    {
        var prevSuppress = _suppressEvents;
        _suppressEvents = true;
        try
        {
            _toolListView.BeginUpdate();
            _toolListView.Items.Clear();
            _toolImageList.Images.Clear();

            for (var i = 0; i < _rows.Count; i++)
            {
                var row = _rows[i];
                var tool = row.Entry;

                using var bmp = IconService.LoadToolBitmap(tool.Name, tool.Icon, 20);
                var imgKey = $"icon_{i}";
                _toolImageList.Images.Add(imgKey, bmp);

                var displayName = string.IsNullOrWhiteSpace(row.DisplaySubtitle)
                    ? $"{i + 1}. {tool.Name}"
                    : $"{i + 1}. {tool.Name} ({row.DisplaySubtitle})";

                var cmdPreview = tool.Super is not null
                    ? $"{tool.Command} · {tool.Super.Label} · {tool.Super.Label}-R"
                    : tool.Command;

                var lvi = new ListViewItem(displayName)
                {
                    ImageKey = imgKey,
                    Checked = row.Installed && row.Enabled,
                    Tag = i,
                    UseItemStyleForSubItems = false,
                    ToolTipText = row.Installed
                        ? "勾选后在资源管理器右键菜单中显示"
                        : $"未检测到「{tool.Command}」命令，安装后点击「刷新检测」即可勾选"
                };

                lvi.ForeColor = row.Installed ? SystemColors.WindowText : SystemColors.GrayText;

                var cmdSub = lvi.SubItems.Add(cmdPreview);
                cmdSub.ForeColor = row.Installed ? SystemColors.GrayText : Color.DarkGray;

                var netSub = lvi.SubItems.Add(tool.UseProxy == false ? "直连" : "默认");
                netSub.ForeColor = tool.UseProxy == false
                    ? (row.Installed ? Color.DarkOrange : SystemColors.GrayText)
                    : SystemColors.GrayText;

                var statusSub = lvi.SubItems.Add(row.Installed ? "已安装" : "未安装");
                statusSub.ForeColor = row.Installed ? Color.ForestGreen : SystemColors.GrayText;

                _toolListView.Items.Add(lvi);
            }

            if (selectedIndex >= 0 && selectedIndex < _toolListView.Items.Count)
            {
                _toolListView.Items[selectedIndex].Selected = true;
                _toolListView.Items[selectedIndex].Focused = true;
                _toolListView.EnsureVisible(selectedIndex);
            }

            _toolListView.EndUpdate();
            UpdateActionButtonsAndSummary();
        }
        finally
        {
            _suppressEvents = prevSuppress;
        }
    }

    private void ReloadProxyAndTerminalTab()
    {
        var prevSuppress = _suppressEvents;
        _suppressEvents = true;
        try
        {
            var winCfg = ConfigService.LoadWindowsConfig();
            var toolsCfg = ConfigService.LoadToolsConfig();

            // 终端下拉仅列出本机检测到的终端
            _detectedTerminals = TerminalService.DetectInstalledTerminals();
            _terminalCombo.Items.Clear();
            foreach (var dt in _detectedTerminals)
            {
                _terminalCombo.Items.Add(dt.Spec.DisplayName);
            }

            var currentIdx = _detectedTerminals.FindIndex(t =>
                string.Equals(t.Spec.Id, winCfg.Terminal, StringComparison.OrdinalIgnoreCase));
            if (currentIdx >= 0)
            {
                _terminalCombo.SelectedIndex = currentIdx;
            }
            else if (_detectedTerminals.Count > 0)
            {
                _terminalCombo.SelectedIndex = 0;
                winCfg.Terminal = _detectedTerminals[0].Spec.Id;
                winCfg.TerminalExePath = _detectedTerminals[0].ExecutablePath;
                ConfigService.SaveWindowsConfig(winCfg);
            }

            var supportedList = string.Join(" / ", TerminalService.AllSupported.Select(s => s.ShortName));
            _terminalDetectHintLabel.Text =
                $"已检测到 {_detectedTerminals.Count}/{TerminalService.AllSupported.Count} 款（支持自动检测: {supportedList}）";

            // 代理信息
            var proxy = toolsCfg.Proxy;
            _proxyEnableCheck.Checked = proxy?.Enabled == true;
            _proxyFollowSystemCheck.Checked = string.Equals(proxy?.Mode, "system", StringComparison.OrdinalIgnoreCase);
            _proxyUrlBox.Text = proxy?.Url ?? string.Empty;
            _noProxyBox.Text = string.IsNullOrWhiteSpace(proxy?.NoProxy) ? AppMetadata.DefaultNoProxy : proxy.NoProxy;

            _detectedSystemProxy = ProxyService.DetectWindowsSystemProxy();
            if (!string.IsNullOrWhiteSpace(_detectedSystemProxy))
            {
                _sysProxyHintLabel.Text = $"检测到 Windows 系统代理: {_detectedSystemProxy}";
                _fillSysProxyBtn.Enabled = true;
            }
            else
            {
                _sysProxyHintLabel.Text = "未检测到 Windows 系统代理（可勾选「跟随系统」或手动填写地址）";
                _fillSysProxyBtn.Enabled = false;
            }
            UpdateProxyInputState();
        }
        finally
        {
            _suppressEvents = prevSuppress;
        }
    }

    private void UpdateMasterStatusLabel(bool menuOn, string menuName)
    {
        if (!menuOn)
        {
            _masterStatusLabel.Text = "当前已隐藏：右键菜单已从注册表移除";
            _masterStatusLabel.ForeColor = SystemColors.GrayText;
        }
        else if (RegistryMenuService.IsMenuRegistered(menuName))
        {
            _masterStatusLabel.Text = "当前已注册：右键文件夹及空白处均可见";
            _masterStatusLabel.ForeColor = Color.ForestGreen;
        }
        else
        {
            _masterStatusLabel.Text = "请至少勾选 1 个已安装工具以生成右键菜单";
            _masterStatusLabel.ForeColor = Color.DarkOrange;
        }
    }

    private void UpdateActionButtonsAndSummary()
    {
        var idx = GetSelectedRowIndex();
        var hasSelection = idx >= 0 && idx < _rows.Count;
        _editBtn.Enabled = hasSelection;
        if (hasSelection)
        {
            var row = _rows[idx];
            _deleteBtn.Enabled = !row.IsBuiltinPreset || row.PersistedInToolsJson;
            _deleteBtn.Text = row.IsBuiltinPreset ? "重置" : "删除";
        }
        else
        {
            _deleteBtn.Enabled = false;
            _deleteBtn.Text = "删除";
        }

        _moveUpBtn.Enabled = hasSelection && idx > 0;
        _moveDownBtn.Enabled = hasSelection && idx < _rows.Count - 1;

        var installedCount = _rows.Count(r => r.Installed);
        var enabledCount = _rows.Count(r => r.Installed && r.Enabled);
        _countHintLabel.Text = $"共 {_rows.Count} 款 · 已安装 {installedCount} · 右键显示 {enabledCount}";
    }

    private int GetSelectedRowIndex() =>
        _toolListView.SelectedIndices.Count > 0 ? _toolListView.SelectedIndices[0] : -1;

    private void PersistWindowsConfigAndSyncRegistry()
    {
        var winCfg = ConfigService.LoadWindowsConfig();
        winCfg.ContextMenuEnabled = _masterSwitch.Checked;
        winCfg.MenuLayout = _layoutCombo.SelectedIndex switch
        {
            1 => "flat",
            2 => "grouped",
            _ => "auto"
        };

        if (!_normalModeCheck.Checked && !_superModeCheck.Checked && !_resumeModeCheck.Checked)
        {
            _suppressEvents = true;
            _normalModeCheck.Checked = true;
            _suppressEvents = false;
        }

        winCfg.ShowNormalMode = _normalModeCheck.Checked;
        winCfg.ShowSuperMode = _superModeCheck.Checked;
        winCfg.ShowResumeMode = _resumeModeCheck.Checked;
        winCfg.ToolOrder = _rows.Select(r => r.Entry.Name).ToList();
        winCfg.EnabledTools = _rows.Where(r => r.Installed && r.Enabled).Select(r => r.Entry.Name).ToList();

        ConfigService.SaveWindowsConfig(winCfg);

        var toolsCfg = ConfigService.LoadToolsConfig();
        RegistryMenuService.SyncContextMenu(toolsCfg, winCfg);
        UpdateMasterStatusLabel(winCfg.ContextMenuEnabled, toolsCfg.MenuName);
        UpdateActionButtonsAndSummary();
    }

    private void PersistToolsAndSyncRegistry()
    {
        var toolsCfg = ConfigService.LoadToolsConfig();
        toolsCfg.Tools = _rows
            .Where(r => r.PersistedInToolsJson || (r.Installed && r.Enabled))
            .Select(r => r.Entry.Clone())
            .ToList();
        ConfigService.SaveToolsConfig(toolsCfg);
        PersistWindowsConfigAndSyncRegistry();
    }

    // =========================================================================
    // Tab 1 交互事件
    // =========================================================================

    private void HandleDisplayOptionChanged()
    {
        if (_suppressEvents) return;
        PersistWindowsConfigAndSyncRegistry();
    }

    private void HandleToolItemCheck(object? sender, ItemCheckEventArgs e)
    {
        if (_suppressEvents) return;
        if (_inhibitCheckOnDoubleClick)
        {
            _inhibitCheckOnDoubleClick = false;
            e.NewValue = e.CurrentValue;
            return;
        }
        if (e.Index < 0 || e.Index >= _rows.Count) return;

        var row = _rows[e.Index];
        // 未安装的 CLI 物理拦截勾选
        if (!row.Installed)
        {
            e.NewValue = CheckState.Unchecked;
            return;
        }

        var nowEnabled = e.NewValue == CheckState.Checked;
        row.Enabled = nowEnabled;

        if (nowEnabled && !row.PersistedInToolsJson)
        {
            row.PersistedInToolsJson = true;
            BeginInvoke(() => PersistToolsAndSyncRegistry());
        }
        else
        {
            BeginInvoke(() => PersistWindowsConfigAndSyncRegistry());
        }
    }

    private void HandleAddTool()
    {
        using var dialog = new ToolEditorDialog(null, _rows.Select(r => r.Entry.Name));
        if (dialog.ShowDialog(this) != DialogResult.OK || dialog.ResultEntry is null) return;

        var entry = dialog.ResultEntry;
        if (!string.IsNullOrWhiteSpace(dialog.ImportedIconSourcePath))
        {
            entry.Icon = IconService.ImportCustomIcon(dialog.ImportedIconSourcePath, entry.Name);
        }

        var installed = ToolDetector.IsCommandInstalled(entry.Command);
        var newRow = new ToolRowModel
        {
            Entry = entry,
            DisplaySubtitle = null,
            IsBuiltinPreset = false,
            PersistedInToolsJson = true,
            Installed = installed,
            Enabled = installed
        };

        var insertIndex = installed ? _rows.TakeWhile(r => r.Installed).Count() : _rows.Count;
        _rows.Insert(insertIndex, newRow);
        PersistToolsAndSyncRegistry();
        RebuildListView(insertIndex);
    }

    private void HandleEditSelected()
    {
        var idx = GetSelectedRowIndex();
        if (idx < 0 || idx >= _rows.Count) return;

        var current = _rows[idx];
        using var dialog = new ToolEditorDialog(current.Entry, _rows.Select(r => r.Entry.Name));
        if (dialog.ShowDialog(this) != DialogResult.OK || dialog.ResultEntry is null) return;

        var updated = dialog.ResultEntry;
        if (!string.IsNullOrWhiteSpace(dialog.ImportedIconSourcePath))
        {
            updated.Icon = IconService.ImportCustomIcon(dialog.ImportedIconSourcePath, updated.Name);
        }

        var installed = ToolDetector.IsCommandInstalled(updated.Command);
        current.Entry = updated;
        current.PersistedInToolsJson = true;
        current.Installed = installed;
        current.Enabled = installed && current.Enabled;

        PersistToolsAndSyncRegistry();
        RebuildListView(idx);
    }

    private void HandleDeleteSelected()
    {
        var idx = GetSelectedRowIndex();
        if (idx < 0 || idx >= _rows.Count) return;

        var row = _rows[idx];
        if (row.IsBuiltinPreset)
        {
            var preset = BuiltinPresets.FindByName(row.Entry.Name);
            if (preset is null) return;
            var res = MessageBox.Show(
                this,
                $"确定重置内置工具「{row.Entry.Name}」为默认命令与参数配置吗？",
                "重置内置工具",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question);
            if (res != DialogResult.Yes) return;

            var resetEntry = preset.ToToolEntry();
            resetEntry.Icon = row.Entry.Icon;
            row.Entry = resetEntry;
            PersistToolsAndSyncRegistry();
            RebuildListView(idx);
            return;
        }

        var confirm = MessageBox.Show(
            this,
            $"确定删除自定义工具「{row.Entry.Name}」吗？（不会卸载 CLI 本身）",
            "删除工具",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning);
        if (confirm != DialogResult.Yes) return;

        _rows.RemoveAt(idx);
        PersistToolsAndSyncRegistry();
        RebuildListView(Math.Min(idx, _rows.Count - 1));
    }

    private void HandleMoveSelected(int delta)
    {
        var idx = GetSelectedRowIndex();
        var target = idx + delta;
        if (idx < 0 || target < 0 || target >= _rows.Count) return;

        (_rows[idx], _rows[target]) = (_rows[target], _rows[idx]);
        PersistWindowsConfigAndSyncRegistry();
        RebuildListView(target);
    }

    private void HandleToolItemDrag(object? sender, ItemDragEventArgs e)
    {
        if (e.Item is ListViewItem item)
        {
            DoDragDrop(item, DragDropEffects.Move);
        }
    }

    private void HandleToolDragEnter(object? sender, DragEventArgs e)
    {
        e.Effect = e.Data?.GetDataPresent(typeof(ListViewItem)) == true
            ? DragDropEffects.Move
            : DragDropEffects.None;
    }

    private void HandleToolDragDrop(object? sender, DragEventArgs e)
    {
        if (e.Data?.GetData(typeof(ListViewItem)) is not ListViewItem dragged) return;
        var sourceIdx = dragged.Index;
        if (sourceIdx < 0 || sourceIdx >= _rows.Count) return;

        var pt = _toolListView.PointToClient(new Point(e.X, e.Y));
        var targetItem = _toolListView.GetItemAt(pt.X, pt.Y);
        var targetIdx = targetItem is not null ? targetItem.Index : _rows.Count - 1;
        if (targetIdx == sourceIdx) return;

        var moved = _rows[sourceIdx];
        _rows.RemoveAt(sourceIdx);
        _rows.Insert(targetIdx, moved);

        PersistWindowsConfigAndSyncRegistry();
        RebuildListView(targetIdx);
    }

    // =========================================================================
    // Tab 2 交互事件（终端与代理）
    // =========================================================================

    private void HandleTerminalChanged()
    {
        if (_suppressEvents) return;
        var idx = _terminalCombo.SelectedIndex;
        if (idx < 0 || idx >= _detectedTerminals.Count) return;

        var chosen = _detectedTerminals[idx];
        var winCfg = ConfigService.LoadWindowsConfig();
        winCfg.Terminal = chosen.Spec.Id;
        winCfg.TerminalExePath = chosen.ExecutablePath;
        ConfigService.SaveWindowsConfig(winCfg);
    }

    private void UpdateProxyInputState()
    {
        var followSystem = _proxyFollowSystemCheck.Checked;
        _proxyUrlBox.Enabled = !followSystem;
        _fillSysProxyBtn.Enabled = !followSystem && !string.IsNullOrWhiteSpace(_detectedSystemProxy);
    }

    private void HandleFillSystemProxy()
    {
        _detectedSystemProxy = ProxyService.DetectWindowsSystemProxy();
        if (string.IsNullOrWhiteSpace(_detectedSystemProxy))
        {
            _proxyFeedbackLabel.Text = "未检测到系统代理";
            _proxyFeedbackLabel.ForeColor = Color.DarkOrange;
            return;
        }

        _suppressEvents = true;
        _proxyFollowSystemCheck.Checked = false;
        _proxyUrlBox.Text = _detectedSystemProxy;
        if (string.IsNullOrWhiteSpace(_noProxyBox.Text))
        {
            _noProxyBox.Text = AppMetadata.DefaultNoProxy;
        }
        _proxyEnableCheck.Checked = true;
        _suppressEvents = false;
        UpdateProxyInputState();
        SaveProxySettings();
    }

    private void SaveProxySettings()
    {
        var enabled = _proxyEnableCheck.Checked;
        var followSystem = _proxyFollowSystemCheck.Checked;
        var rawUrl = _proxyUrlBox.Text.Trim();
        var noProxy = string.IsNullOrWhiteSpace(_noProxyBox.Text) ? AppMetadata.DefaultNoProxy : _noProxyBox.Text.Trim();

        var finalUrl = string.Empty;
        if (!string.IsNullOrEmpty(rawUrl))
        {
            var normalized = ProxyService.NormalizeProxyUrl(rawUrl);
            if (normalized is null)
            {
                if (!followSystem)
                {
                    _proxyFeedbackLabel.Text = "代理地址格式无效（示例: http://127.0.0.1:7897）";
                    _proxyFeedbackLabel.ForeColor = Color.Crimson;
                    return;
                }
            }
            else
            {
                finalUrl = normalized;
                _proxyUrlBox.Text = normalized;
            }
        }
        else if (enabled && !followSystem)
        {
            _proxyFeedbackLabel.Text = "请先填写代理地址、点击「填入系统代理」或勾选「跟随系统」";
            _proxyFeedbackLabel.ForeColor = Color.DarkOrange;
            _suppressEvents = true;
            _proxyEnableCheck.Checked = false;
            _suppressEvents = false;
            return;
        }

        _noProxyBox.Text = noProxy;
        var toolsCfg = ConfigService.LoadToolsConfig();
        toolsCfg.Proxy = new ProxySettings
        {
            Enabled = enabled,
            Mode = followSystem ? "system" : "manual",
            Url = finalUrl,
            NoProxy = noProxy
        };
        ConfigService.SaveToolsConfig(toolsCfg);

        if (!enabled)
        {
            _proxyFeedbackLabel.Text = "已停用 CLI 代理";
            _proxyFeedbackLabel.ForeColor = SystemColors.GrayText;
        }
        else if (followSystem)
        {
            _detectedSystemProxy = ProxyService.DetectWindowsSystemProxy();
            _proxyFeedbackLabel.Text = !string.IsNullOrWhiteSpace(_detectedSystemProxy)
                ? $"已启用（跟随系统: {_detectedSystemProxy}）"
                : "已启用（跟随系统，当前未开启代理将直连）";
            _proxyFeedbackLabel.ForeColor = Color.ForestGreen;
        }
        else
        {
            _proxyFeedbackLabel.Text = $"已启用固定代理: {finalUrl}";
            _proxyFeedbackLabel.ForeColor = Color.ForestGreen;
        }
    }

    private async Task HandleTestProxyAsync()
    {
        var followSystem = _proxyFollowSystemCheck.Checked;
        var rawUrl = _proxyUrlBox.Text.Trim();
        string? targetProxy;
        if (followSystem)
        {
            targetProxy = ProxyService.DetectWindowsSystemProxy();
        }
        else if (!string.IsNullOrEmpty(rawUrl))
        {
            targetProxy = ProxyService.NormalizeProxyUrl(rawUrl);
            if (targetProxy is null)
            {
                _proxyTestOutputBox.Text = $"[错误] 代理地址格式无效: {rawUrl}\r\n支持 http://、https://、socks5://";
                return;
            }
        }
        else
        {
            targetProxy = ProxyService.DetectWindowsSystemProxy();
        }

        if (string.IsNullOrWhiteSpace(targetProxy))
        {
            _proxyTestOutputBox.Text = "[提示] 请先填写代理地址，或开启 Windows 系统代理后再测试。";
            return;
        }

        _proxyTestCts?.Cancel();
        _proxyTestCts = new CancellationTokenSource();
        var ct = _proxyTestCts.Token;

        _testProxyBtn.Enabled = false;
        _proxyTestOutputBox.Text = $"测试代理: {targetProxy}\r\n\r\n";

        try
        {
            await ProxyService.RunConnectivityTestAsync(
                targetProxy,
                line =>
                {
                    if (!IsDisposed && IsHandleCreated)
                    {
                        BeginInvoke(() => _proxyTestOutputBox.AppendText(line + "\r\n"));
                    }
                },
                ct);
        }
        catch (OperationCanceledException)
        {
            // 已取消
        }
        finally
        {
            if (!IsDisposed)
            {
                _testProxyBtn.Enabled = true;
            }
        }
    }

    private static void OpenUrl(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch
        {
            // 忽略浏览器启动异常
        }
    }

    private static void OpenPath(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch
        {
            // 忽略打开异常
        }
    }
}

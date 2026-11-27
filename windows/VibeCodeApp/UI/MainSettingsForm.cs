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
    private int _dragInsertIndex = -1;
    private int _dragSourceIndex = -1;
    private DateTime _lastAutoScrollTime = DateTime.MinValue;
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

    // Tab 3: 关于与更新检测
    private readonly Button _checkUpdateBtn = new();
    private readonly Label _updateStatusLabel = new();
    private UpdateCheckResult? _latestUpdateResult;
    private bool _checkingUpdate;

    public MainSettingsForm()
    {
        Text = "VibeCode 设置";
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(820, 650);
        MinimumSize = new Size(760, 580);
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

    private static void StyleAutoButton(Button btn, int minWidth = 72)
    {
        btn.AutoSize = true;
        btn.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        btn.MinimumSize = new Size(minWidth, 30);
        btn.Padding = new Padding(8, 2, 8, 2);
    }

    private void BuildToolsTab(TabPage page)
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 5
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));      // 顶部控制卡片
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));      // 列表标题栏
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));  // 工具列表
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));      // 按钮栏
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));      // 底部提示

        // 1. 顶部控制分组框（自适应高 DPI，避免固定坐标裁切文字）
        var headerGroup = new GroupBox
        {
            Text = "资源管理器右键菜单",
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(12, 8, 12, 10),
            Margin = new Padding(0, 0, 0, 6)
        };

        var headerGrid = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 2,
            RowCount = 2
        };
        headerGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        headerGrid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        headerGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        headerGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        _masterSwitch.Text = "在资源管理器右键菜单中显示 VibeCode";
        _masterSwitch.Font = new Font(Font, FontStyle.Bold);
        _masterSwitch.AutoSize = true;
        _masterSwitch.Anchor = AnchorStyles.Left;
        _masterSwitch.Margin = new Padding(0, 2, 8, 8);
        _masterSwitch.CheckedChanged += (_, _) => HandleDisplayOptionChanged();

        _masterStatusLabel.AutoSize = true;
        _masterStatusLabel.Anchor = AnchorStyles.Right;
        _masterStatusLabel.TextAlign = ContentAlignment.MiddleRight;
        _masterStatusLabel.Margin = new Padding(8, 2, 0, 8);

        var optionsFlow = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Margin = new Padding(0)
        };

        var layoutLbl = new Label
        {
            Text = "菜单排版:",
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            Margin = new Padding(0, 6, 6, 0)
        };
        _layoutCombo.DropDownStyle = ComboBoxStyle.DropDownList;
        _layoutCombo.Items.AddRange([
            "自动（>5 个工具时折叠）",
            "平铺展开（全部同级）",
            "按工具折叠二级子菜单"
        ]);
        _layoutCombo.Width = 220;
        _layoutCombo.Margin = new Padding(0, 2, 16, 2);
        _layoutCombo.SelectedIndexChanged += (_, _) => HandleDisplayOptionChanged();

        var modeLbl = new Label
        {
            Text = "显示项:",
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            Margin = new Padding(0, 6, 6, 0)
        };

        _normalModeCheck.Text = "普通";
        _normalModeCheck.AutoSize = true;
        _normalModeCheck.Margin = new Padding(0, 5, 10, 0);
        _normalModeCheck.CheckedChanged += (_, _) => HandleDisplayOptionChanged();

        _superModeCheck.Text = "Super";
        _superModeCheck.AutoSize = true;
        _superModeCheck.Margin = new Padding(0, 5, 10, 0);
        _superModeCheck.CheckedChanged += (_, _) => HandleDisplayOptionChanged();

        _resumeModeCheck.Text = "恢复 (-R)";
        _resumeModeCheck.AutoSize = true;
        _resumeModeCheck.Margin = new Padding(0, 5, 0, 0);
        _resumeModeCheck.CheckedChanged += (_, _) => HandleDisplayOptionChanged();

        optionsFlow.Controls.AddRange([layoutLbl, _layoutCombo, modeLbl, _normalModeCheck, _superModeCheck, _resumeModeCheck]);

        headerGrid.Controls.Add(_masterSwitch, 0, 0);
        headerGrid.Controls.Add(_masterStatusLabel, 1, 0);
        headerGrid.Controls.Add(optionsFlow, 0, 1);
        headerGrid.SetColumnSpan(optionsFlow, 2);

        headerGroup.Controls.Add(headerGrid);
        root.Controls.Add(headerGroup, 0, 0);

        // 2. 列表标题与计数栏
        var titleRow = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 2,
            RowCount = 1,
            Margin = new Padding(0, 2, 0, 4)
        };
        titleRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        titleRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        var sectionLabel = new Label
        {
            Text = "全部 AI 工具（未安装项不可勾选；拖拽或上下移排序，双击编辑）",
            ForeColor = SystemColors.GrayText,
            AutoSize = true,
            Anchor = AnchorStyles.Left,
            Margin = new Padding(2, 2, 8, 2)
        };
        _countHintLabel.AutoSize = true;
        _countHintLabel.Anchor = AnchorStyles.Right;
        _countHintLabel.ForeColor = SystemColors.GrayText;
        _countHintLabel.Margin = new Padding(8, 2, 2, 2);
        titleRow.Controls.Add(sectionLabel, 0, 0);
        titleRow.Controls.Add(_countHintLabel, 1, 0);
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
        // 开启双缓冲，彻底消除拖拽重绘与列表刷新时的闪烁
        typeof(Control).GetProperty("DoubleBuffered", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)
            ?.SetValue(_toolListView, true);

        _toolListView.Columns.Add("工具名称", 230);
        _toolListView.Columns.Add("启动命令与模式", 290);
        _toolListView.Columns.Add("网络", 70, HorizontalAlignment.Center);
        _toolListView.Columns.Add("状态", 80, HorizontalAlignment.Center);

        _toolListView.MouseDown += (_, e) => _inhibitCheckOnDoubleClick = e.Clicks >= 2;
        _toolListView.ItemCheck += HandleToolItemCheck;
        _toolListView.SelectedIndexChanged += (_, _) => UpdateActionButtonsAndSummary();
        _toolListView.DoubleClick += (_, _) => HandleEditSelected();
        _toolListView.KeyDown += HandleToolListKeyDown;
        _toolListView.ItemDrag += HandleToolItemDrag;
        _toolListView.DragEnter += HandleToolDragOver;
        _toolListView.DragOver += HandleToolDragOver;
        _toolListView.DragLeave += (_, _) => ClearDragIndicator();
        _toolListView.DragDrop += HandleToolDragDrop;

        root.Controls.Add(_toolListView, 0, 2);

        // 4. 操作按钮栏（AutoSize 按钮，避免高 DPI 截断文字）
        var btnBar = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 2,
            RowCount = 1,
            Margin = new Padding(0, 8, 0, 4)
        };
        btnBar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        btnBar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        var leftBtns = new FlowLayoutPanel
        {
            Dock = DockStyle.Left,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Margin = new Padding(0)
        };

        _addBtn.Text = "+ 自定义工具";
        StyleAutoButton(_addBtn, 108);
        _addBtn.Margin = new Padding(0, 0, 6, 0);
        _addBtn.Click += (_, _) => HandleAddTool();

        _editBtn.Text = "编辑";
        StyleAutoButton(_editBtn, 68);
        _editBtn.Margin = new Padding(0, 0, 6, 0);
        _editBtn.Click += (_, _) => HandleEditSelected();

        _deleteBtn.Text = "删除";
        StyleAutoButton(_deleteBtn, 68);
        _deleteBtn.Margin = new Padding(0, 0, 14, 0);
        _deleteBtn.Click += (_, _) => HandleDeleteSelected();

        _moveUpBtn.Text = "上移 ↑";
        StyleAutoButton(_moveUpBtn, 78);
        _moveUpBtn.Margin = new Padding(0, 0, 6, 0);
        _moveUpBtn.Click += (_, _) => HandleMoveSelected(-1);

        _moveDownBtn.Text = "下移 ↓";
        StyleAutoButton(_moveDownBtn, 78);
        _moveDownBtn.Margin = new Padding(0);
        _moveDownBtn.Click += (_, _) => HandleMoveSelected(+1);

        leftBtns.Controls.AddRange([_addBtn, _editBtn, _deleteBtn, _moveUpBtn, _moveDownBtn]);

        _refreshBtn.Text = "刷新检测";
        StyleAutoButton(_refreshBtn, 92);
        _refreshBtn.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        _refreshBtn.Margin = new Padding(8, 0, 0, 0);
        _refreshBtn.Click += (_, _) => ReloadAllFromDisk();

        btnBar.Controls.Add(leftBtns, 0, 0);
        btnBar.Controls.Add(_refreshBtn, 1, 0);
        root.Controls.Add(btnBar, 0, 3);

        // 5. 底部提示
        var footer = new Label
        {
            Text = "仅本机已安装的 CLI 允许勾选进右键菜单；所有修改实时写入注册表，无需重启资源管理器。",
            ForeColor = SystemColors.GrayText,
            AutoSize = true,
            Dock = DockStyle.Top,
            Margin = new Padding(2, 2, 2, 0)
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
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        // 卡片 1: 默认终端自动检测
        var termGroup = new GroupBox
        {
            Text = "默认终端（下拉仅显示本机已检测到的终端）",
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(12, 8, 12, 10),
            Margin = new Padding(0, 0, 0, 8)
        };

        var termGrid = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 1,
            RowCount = 2
        };
        termGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        termGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        termGrid.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var termRow = new FlowLayoutPanel
        {
            Dock = DockStyle.Left,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Margin = new Padding(0, 0, 0, 6)
        };

        var termLbl = new Label
        {
            Text = "默认终端:",
            AutoSize = true,
            Margin = new Padding(0, 6, 8, 0)
        };

        _terminalCombo.DropDownStyle = ComboBoxStyle.DropDownList;
        _terminalCombo.Width = 250;
        _terminalCombo.Margin = new Padding(0, 2, 10, 2);
        _terminalCombo.SelectedIndexChanged += (_, _) => HandleTerminalChanged();

        var redetectBtn = new Button { Text = "重新检测", Margin = new Padding(0, 1, 0, 1) };
        StyleAutoButton(redetectBtn, 90);
        redetectBtn.Click += (_, _) => ReloadProxyAndTerminalTab();

        termRow.Controls.AddRange([termLbl, _terminalCombo, redetectBtn]);

        _terminalDetectHintLabel.AutoSize = true;
        _terminalDetectHintLabel.MaximumSize = new Size(720, 0);
        _terminalDetectHintLabel.ForeColor = SystemColors.GrayText;
        _terminalDetectHintLabel.Margin = new Padding(2, 2, 2, 2);

        termGrid.Controls.Add(termRow, 0, 0);
        termGrid.Controls.Add(_terminalDetectHintLabel, 0, 1);
        termGroup.Controls.Add(termGrid);
        root.Controls.Add(termGroup, 0, 0);

        // 卡片 2: CLI 代理配置与连通性测速
        var proxyGroup = new GroupBox
        {
            Text = "CLI 代理（仅注入给 VibeCode 启动的终端会话，不修改系统环境变量）",
            Dock = DockStyle.Fill,
            Padding = new Padding(12, 8, 12, 10)
        };

        var proxyLayout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2
        };
        proxyLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        proxyLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        proxyLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var proxyForm = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 2,
            RowCount = 6,
            Margin = new Padding(0, 0, 0, 8)
        };
        proxyForm.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        proxyForm.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (var r = 0; r < 6; r++) proxyForm.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        // 行 0: 启用开关 + 跟随系统开关
        var checkFlow = new FlowLayoutPanel
        {
            Dock = DockStyle.Left,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Margin = new Padding(0, 2, 0, 6)
        };
        _proxyEnableCheck.Text = "启用 CLI 代理";
        _proxyEnableCheck.Font = new Font(Font, FontStyle.Bold);
        _proxyEnableCheck.AutoSize = true;
        _proxyEnableCheck.Margin = new Padding(0, 0, 16, 0);
        _proxyEnableCheck.CheckedChanged += (_, _) =>
        {
            UpdateProxyInputState();
            if (!_suppressEvents) SaveProxySettings();
        };

        _proxyFollowSystemCheck.Text = "跟随 Windows 系统代理（开代理生效，关代理直连）";
        _proxyFollowSystemCheck.AutoSize = true;
        _proxyFollowSystemCheck.Margin = new Padding(0);
        _proxyFollowSystemCheck.CheckedChanged += (_, _) =>
        {
            UpdateProxyInputState();
            if (!_suppressEvents) SaveProxySettings();
        };
        checkFlow.Controls.AddRange([_proxyEnableCheck, _proxyFollowSystemCheck]);
        proxyForm.Controls.Add(checkFlow, 0, 0);
        proxyForm.SetColumnSpan(checkFlow, 2);

        // 行 1: 系统代理提示 + 填入按钮
        var sysRow = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            ColumnCount = 2,
            RowCount = 1,
            Margin = new Padding(0, 0, 0, 6)
        };
        sysRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        sysRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        _sysProxyHintLabel.AutoSize = true;
        _sysProxyHintLabel.Anchor = AnchorStyles.Left;
        _sysProxyHintLabel.ForeColor = SystemColors.GrayText;
        _sysProxyHintLabel.Margin = new Padding(0, 5, 8, 0);

        _fillSysProxyBtn.Text = "填入系统代理";
        StyleAutoButton(_fillSysProxyBtn, 112);
        _fillSysProxyBtn.Anchor = AnchorStyles.Right;
        _fillSysProxyBtn.Margin = new Padding(0);
        _fillSysProxyBtn.Click += (_, _) => HandleFillSystemProxy();

        sysRow.Controls.Add(_sysProxyHintLabel, 0, 0);
        sysRow.Controls.Add(_fillSysProxyBtn, 1, 0);
        proxyForm.Controls.Add(sysRow, 0, 1);
        proxyForm.SetColumnSpan(sysRow, 2);

        // 行 2: 代理地址
        var urlLbl = new Label
        {
            Text = "代理地址:",
            AutoSize = true,
            Anchor = AnchorStyles.Right,
            Margin = new Padding(0, 6, 8, 6)
        };
        _proxyUrlBox.PlaceholderText = "例如: http://127.0.0.1:7897 或 socks5://127.0.0.1:7897";
        _proxyUrlBox.Dock = DockStyle.Fill;
        _proxyUrlBox.Margin = new Padding(0, 2, 0, 6);
        proxyForm.Controls.Add(urlLbl, 0, 2);
        proxyForm.Controls.Add(_proxyUrlBox, 1, 2);

        // 行 3: NO_PROXY
        var noProxyLbl = new Label
        {
            Text = "NO_PROXY:",
            AutoSize = true,
            Anchor = AnchorStyles.Right,
            Margin = new Padding(0, 6, 8, 6)
        };
        _noProxyBox.PlaceholderText = AppMetadata.DefaultNoProxy;
        _noProxyBox.Dock = DockStyle.Fill;
        _noProxyBox.Margin = new Padding(0, 2, 0, 6);
        proxyForm.Controls.Add(noProxyLbl, 0, 3);
        proxyForm.Controls.Add(_noProxyBox, 1, 3);

        // 行 4: 保存 / 测试 / 状态反馈
        var actionFlow = new FlowLayoutPanel
        {
            Dock = DockStyle.Left,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Margin = new Padding(0, 2, 0, 6)
        };

        _saveProxyBtn.Text = "保存代理设置";
        StyleAutoButton(_saveProxyBtn, 112);
        _saveProxyBtn.Margin = new Padding(0, 0, 8, 0);
        _saveProxyBtn.Click += (_, _) => SaveProxySettings();

        _testProxyBtn.Text = "测试连通性";
        StyleAutoButton(_testProxyBtn, 102);
        _testProxyBtn.Margin = new Padding(0, 0, 12, 0);
        _testProxyBtn.Click += async (_, _) => await HandleTestProxyAsync();

        _proxyFeedbackLabel.AutoSize = true;
        _proxyFeedbackLabel.Margin = new Padding(0, 6, 0, 0);

        actionFlow.Controls.AddRange([_saveProxyBtn, _testProxyBtn, _proxyFeedbackLabel]);
        proxyForm.Controls.Add(actionFlow, 1, 4);

        // 行 5: 提示
        var directTip = new Label
        {
            Text = "提示: 如需为国内模型（如 qwen / kimi）单独直连，请在「工具与右键菜单」双击该工具勾选「强制直连」。",
            ForeColor = SystemColors.GrayText,
            AutoSize = true,
            MaximumSize = new Size(720, 0),
            Margin = new Padding(0, 2, 0, 2)
        };
        proxyForm.Controls.Add(directTip, 0, 5);
        proxyForm.SetColumnSpan(directTip, 2);

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
            RowCount = 10,
            Padding = new Padding(24, 28, 24, 20)
        };
        for (var i = 0; i < 9; i++)
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

        var primaryPanel = new FlowLayoutPanel
        {
            AutoSize = true,
            Anchor = AnchorStyles.None,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Margin = new Padding(0, 0, 0, 8)
        };

        _checkUpdateBtn.Text = "检查更新";
        StyleAutoButton(_checkUpdateBtn, 120);
        _checkUpdateBtn.Margin = new Padding(0, 0, 10, 0);
        _checkUpdateBtn.Click += async (_, _) => await CheckForUpdateAsync(silent: false);

        var openGitBtn = new Button
        {
            Text = "访问 GitHub 仓库",
            Margin = new Padding(0)
        };
        StyleAutoButton(openGitBtn, 150);
        openGitBtn.Click += (_, _) => OpenUrl(AppMetadata.GitHubUrl);

        primaryPanel.Controls.Add(_checkUpdateBtn);
        primaryPanel.Controls.Add(openGitBtn);

        _updateStatusLabel.Text = "点击「检查更新」检测 GitHub Releases 新版本（支持一键更新或网页手动下载）";
        _updateStatusLabel.ForeColor = SystemColors.GrayText;
        _updateStatusLabel.AutoSize = true;
        _updateStatusLabel.Anchor = AnchorStyles.None;
        _updateStatusLabel.Margin = new Padding(0, 0, 0, 14);

        var auxPanel = new FlowLayoutPanel
        {
            AutoSize = true,
            Anchor = AnchorStyles.None,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false
        };
        var openDirBtn = new Button { Text = "打开配置目录", Margin = new Padding(0, 0, 8, 0) };
        StyleAutoButton(openDirBtn, 124);
        openDirBtn.Click += (_, _) => OpenPath(AppPaths.SupportDir);
        var editJsonBtn = new Button { Text = "编辑 tools.json", Margin = new Padding(0) };
        StyleAutoButton(editJsonBtn, 124);
        editJsonBtn.Click += (_, _) => OpenPath(AppPaths.ToolsConfigPath);
        auxPanel.Controls.Add(openDirBtn);
        auxPanel.Controls.Add(editJsonBtn);

        stack.Controls.Add(pic, 0, 0);
        stack.Controls.Add(title, 0, 1);
        stack.Controls.Add(ver, 0, 2);
        stack.Controls.Add(desc, 0, 3);
        stack.Controls.Add(author, 0, 4);
        stack.Controls.Add(githubLink, 0, 5);
        stack.Controls.Add(primaryPanel, 0, 6);
        stack.Controls.Add(_updateStatusLabel, 0, 7);
        stack.Controls.Add(auxPanel, 0, 8);

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
            // 提前创建 ImageList 句柄，避免在窗体句柄尚未建立时 Add(bmp) 仅保存引用、随后 using 释放导致 CreateHandle 崩溃
            _ = _toolImageList.Handle;

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

    private void HandleToolListKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Alt && e.KeyCode == Keys.Up)
        {
            HandleMoveSelected(-1);
            e.Handled = true;
            e.SuppressKeyPress = true;
        }
        else if (e.Alt && e.KeyCode == Keys.Down)
        {
            HandleMoveSelected(+1);
            e.Handled = true;
            e.SuppressKeyPress = true;
        }
    }

    private void HandleToolItemDrag(object? sender, ItemDragEventArgs e)
    {
        if (e.Item is ListViewItem item)
        {
            _dragSourceIndex = item.Index;
            _dragInsertIndex = -1;
            try
            {
                DoDragDrop(item, DragDropEffects.Move);
            }
            finally
            {
                ClearDragIndicator();
                _dragSourceIndex = -1;
            }
        }
    }

    private void HandleToolDragOver(object? sender, DragEventArgs e)
    {
        if (e.Data?.GetDataPresent(typeof(ListViewItem)) != true)
        {
            e.Effect = DragDropEffects.None;
            ClearDragIndicator();
            return;
        }

        e.Effect = DragDropEffects.Move;
        var pt = _toolListView.PointToClient(new Point(e.X, e.Y));

        // 接近列表顶部或底部边缘时自动平滑滚动
        var now = DateTime.UtcNow;
        if ((now - _lastAutoScrollTime).TotalMilliseconds >= 90 && _toolListView.Items.Count > 0)
        {
            var topItem = _toolListView.TopItem;
            if (pt.Y < 44 && topItem is not null && topItem.Index > 0)
            {
                _toolListView.EnsureVisible(topItem.Index - 1);
                _lastAutoScrollTime = now;
            }
            else if (pt.Y > _toolListView.ClientSize.Height - 28)
            {
                var hit = _toolListView.GetItemAt(16, _toolListView.ClientSize.Height - 10);
                if (hit is not null && hit.Index + 1 < _toolListView.Items.Count)
                {
                    _toolListView.EnsureVisible(hit.Index + 1);
                    _lastAutoScrollTime = now;
                }
            }
        }

        var insertIdx = ComputeDragInsertIndex(pt);
        if (insertIdx != _dragInsertIndex)
        {
            ClearDragIndicator();
            _dragInsertIndex = insertIdx;
            DrawDragInsertionLine(insertIdx);
        }
    }

    private int ComputeDragInsertIndex(Point clientPt)
    {
        if (_toolListView.Items.Count == 0) return 0;

        var targetItem = _toolListView.GetItemAt(Math.Max(16, clientPt.X), clientPt.Y);
        if (targetItem is not null)
        {
            var bounds = targetItem.GetBounds(ItemBoundsPortion.Entire);
            var insertAfter = clientPt.Y >= bounds.Top + bounds.Height / 2;
            return insertAfter ? targetItem.Index + 1 : targetItem.Index;
        }

        var firstBounds = _toolListView.Items[0].GetBounds(ItemBoundsPortion.Entire);
        return clientPt.Y < firstBounds.Top ? 0 : _toolListView.Items.Count;
    }

    private void DrawDragInsertionLine(int insertIdx)
    {
        if (insertIdx < 0 || _toolListView.Items.Count == 0) return;

        int lineY;
        if (insertIdx < _toolListView.Items.Count)
        {
            lineY = _toolListView.Items[insertIdx].GetBounds(ItemBoundsPortion.Entire).Top;
        }
        else
        {
            lineY = _toolListView.Items[_toolListView.Items.Count - 1].GetBounds(ItemBoundsPortion.Entire).Bottom - 1;
        }

        lineY = Math.Clamp(lineY, 24, _toolListView.ClientSize.Height - 2);
        using var g = _toolListView.CreateGraphics();
        var accent = Color.FromArgb(0, 120, 215);
        using var pen = new Pen(accent, 2f);
        using var brush = new SolidBrush(accent);
        var left = 4;
        var right = Math.Max(left + 20, _toolListView.ClientSize.Width - 6);
        g.DrawLine(pen, left, lineY, right, lineY);
        // 左侧小三角指示插入位置
        g.FillPolygon(brush, new Point[]
        {
            new Point(left, lineY - 4),
            new Point(left + 6, lineY),
            new Point(left, lineY + 4)
        });
    }

    private void ClearDragIndicator()
    {
        if (_dragInsertIndex >= 0)
        {
            _dragInsertIndex = -1;
            _toolListView.Invalidate();
            _toolListView.Update();
        }
    }

    private void HandleToolDragDrop(object? sender, DragEventArgs e)
    {
        if (e.Data?.GetData(typeof(ListViewItem)) is not ListViewItem dragged)
        {
            ClearDragIndicator();
            return;
        }

        var sourceIdx = _dragSourceIndex >= 0 ? _dragSourceIndex : dragged.Index;
        var pt = _toolListView.PointToClient(new Point(e.X, e.Y));
        var insertIdx = _dragInsertIndex >= 0 ? _dragInsertIndex : ComputeDragInsertIndex(pt);
        ClearDragIndicator();

        if (sourceIdx < 0 || sourceIdx >= _rows.Count) return;

        // 移除源项后，若目标在其之后需向前校正一位
        var finalIdx = insertIdx > sourceIdx ? insertIdx - 1 : insertIdx;
        finalIdx = Math.Clamp(finalIdx, 0, _rows.Count - 1);
        if (finalIdx == sourceIdx) return;

        var moved = _rows[sourceIdx];
        _rows.RemoveAt(sourceIdx);
        _rows.Insert(finalIdx, moved);

        PersistWindowsConfigAndSyncRegistry();
        RebuildListView(finalIdx);
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

    public void ApplyBackgroundUpdateResult(UpdateCheckResult result)
    {
        _latestUpdateResult = result;
        if (result.HasUpdate)
        {
            _updateStatusLabel.Text = $"发现新版本 v{result.LatestVersion}（当前 v{result.CurrentVersion}），点击「检查更新」即可升级";
            _updateStatusLabel.ForeColor = Color.DarkOrange;
        }
        else
        {
            _updateStatusLabel.Text = $"当前已是最新版本 (v{result.CurrentVersion})";
            _updateStatusLabel.ForeColor = Color.ForestGreen;
        }
    }

    public void ShowUpdateDialog(UpdateCheckResult result)
    {
        _latestUpdateResult = result;
        ApplyBackgroundUpdateResult(result);
        using var dlg = new UpdateDialog(result);
        dlg.ShowDialog(this);
    }

    public async Task CheckForUpdateAsync(bool silent = false)
    {
        if (_checkingUpdate) return;
        _checkingUpdate = true;
        _checkUpdateBtn.Enabled = false;
        _updateStatusLabel.Text = "正在连接 GitHub 检查最新版本...";
        _updateStatusLabel.ForeColor = SystemColors.GrayText;

        try
        {
            var result = await UpdateService.CheckForUpdateAsync();
            if (IsDisposed) return;

            ApplyBackgroundUpdateResult(result);
            if (!silent)
            {
                if (result.HasUpdate)
                {
                    using var dlg = new UpdateDialog(result);
                    dlg.ShowDialog(this);
                }
                else
                {
                    MessageBox.Show(
                        this,
                        $"当前已是最新版本 (v{result.CurrentVersion})。",
                        "检查更新",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                }
            }
        }
        catch (Exception ex)
        {
            if (IsDisposed) return;
            _updateStatusLabel.Text = $"检查更新失败: {ex.Message}";
            _updateStatusLabel.ForeColor = Color.Crimson;
            if (!silent)
            {
                var openWeb = MessageBox.Show(
                    this,
                    $"检查更新失败:\n{ex.Message}\n\n是否直接打开 GitHub Releases 网页查看？",
                    "检查更新失败",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning);
                if (openWeb == DialogResult.Yes)
                {
                    OpenUrl($"{AppMetadata.GitHubUrl}/releases/latest");
                }
            }
        }
        finally
        {
            _checkingUpdate = false;
            if (!IsDisposed)
            {
                _checkUpdateBtn.Enabled = true;
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

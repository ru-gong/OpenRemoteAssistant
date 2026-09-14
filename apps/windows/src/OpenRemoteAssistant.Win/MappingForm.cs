// SPDX-License-Identifier: GPL-3.0-only
// Mapping editor, redesigned after the macOS original: clickable remote
// illustration on the left, per-button configuration on the right, plus the
// voice-key shortcut section (toggle/hold, Typeless / input-method presets).

using System.Drawing.Drawing2D;

namespace OpenRemoteAssistant.Win;

public sealed class MappingForm : Form
{
    private readonly MappingStore _store;
    private readonly RemoteIllustration _illustration;
    private readonly ComboBox _presetCombo = new();
    private readonly Button _captureButton = new();
    private readonly Label _currentLabel = new();
    private readonly Label _selectedLabel = new();
    private readonly ComboBox _voiceModeCombo = new();
    private readonly ComboBox _voicePresetCombo = new();
    private readonly CheckBox _enableCheck = new();
    private RemoteButton? _selected;

    public MappingForm(MappingStore store)
    {
        _store = store;
        Text = "按键映射 — 遥控器助手";
        Width = 860;
        Height = 620;
        StartPosition = FormStartPosition.CenterParent;
        Font = new Font("Microsoft YaHei UI", 9F);
        MinimumSize = new Size(760, 540);

        // ---- Left: clickable remote illustration ----
        _illustration = new RemoteIllustration { Dock = DockStyle.Fill, BackColor = Color.White };
        _illustration.ButtonSelected += b => { _selected = b; RefreshConfigPanel(); };

        var leftPanel = new Panel { Dock = DockStyle.Left, Width = 300, Padding = new Padding(12, 16, 4, 12) };
        leftPanel.Controls.Add(_illustration);

        var hint = new Label
        {
            Dock = DockStyle.Top,
            Height = 30,
            Text = "点击示意图上的按键进行配置",
            TextAlign = ContentAlignment.MiddleCenter,
            ForeColor = Color.Gray,
            Padding = new Padding(0, 14, 0, 0),
        };
        leftPanel.Controls.Add(hint);

        // ---- Right: configuration ----
        var rightPanel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(12, 16, 12, 12) };

        _enableCheck.Text = "启用按键映射";
        _enableCheck.AutoSize = true;
        _enableCheck.Checked = store.Enabled;
        _enableCheck.Dock = DockStyle.Top;
        _enableCheck.Padding = new Padding(0, 0, 0, 10);
        _enableCheck.CheckedChanged += (s, e) => store.SetEnabled(_enableCheck.Checked);

        var configGroup = new GroupBox { Text = "选中按键的目标", Dock = DockStyle.Top, Height = 150, Padding = new Padding(12, 8, 12, 4) };
        _selectedLabel.Dock = DockStyle.Top;
        _selectedLabel.Height = 34;
        _selectedLabel.Font = new Font(Font, FontStyle.Bold);
        _selectedLabel.Text = "（先点击左侧示意图选择按键）";
        _presetCombo.Dock = DockStyle.Top;
        _presetCombo.DropDownStyle = ComboBoxStyle.DropDownList;
        _presetCombo.Items.Add("（未映射 — 保留默认行为）");
        foreach (var (label, _) in VkNames.Presets) _presetCombo.Items.Add(label);
        _presetCombo.SelectedIndex = 0;
        _presetCombo.SelectedIndexChanged += (s, e) =>
        {
            if (_selected is not { } button) return;
            if (_presetCombo.SelectedIndex == 0) _store.Set(button, null);
            else if (_presetCombo.SelectedIndex <= VkNames.Presets.Length)
                _store.Set(button, VkNames.Presets[_presetCombo.SelectedIndex - 1].Vks);
        };
        _captureButton.Text = "键盘录入组合键…";
        _captureButton.Dock = DockStyle.Top;
        _captureButton.Click += (s, e) =>
        {
            if (_selected is not { } button) return;
            _captureButton.Text = "请按下目标组合键（Esc 取消）…";
            _presetCombo.Enabled = false;
        };
        _currentLabel.Dock = DockStyle.Top;
        _currentLabel.Height = 28;
        _currentLabel.ForeColor = Color.DimGray;
        configGroup.Controls.Add(_currentLabel);
        configGroup.Controls.Add(_captureButton);
        configGroup.Controls.Add(_presetCombo);
        configGroup.Controls.Add(_selectedLabel);

        var voiceGroup = new GroupBox { Text = "语音键快捷方式（语音键不做普通映射）", Dock = DockStyle.Top, Height = 190, Padding = new Padding(12, 8, 12, 4) };
        var modeLabel = new Label { Text = "模式：", Dock = DockStyle.Top, Height = 24, Padding = new Padding(0, 4, 0, 0) };
        _voiceModeCombo.Dock = DockStyle.Top;
        _voiceModeCombo.DropDownStyle = ComboBoxStyle.DropDownList;
        _voiceModeCombo.Items.AddRange([
            "关闭（语音键仅开麦）",
            "点按开始 / 再点按结束（Typeless 式）",
            "按住说话 / 松开结束（输入法式）",
        ]);
        _voiceModeCombo.SelectedIndex = (int)store.VoiceMode;
        var presetLabel = new Label { Text = "目标按键预设：", Dock = DockStyle.Top, Height = 24, Padding = new Padding(0, 8, 0, 0) };
        _voicePresetCombo.Dock = DockStyle.Top;
        _voicePresetCombo.DropDownStyle = ComboBoxStyle.DropDownList;
        foreach (var (label, _) in VkNames.VoicePresets) _voicePresetCombo.Items.Add(label);
        _voicePresetCombo.SelectedIndex = 0;
        var voiceHint = new Label
        {
            Text = "点按式：按语音键=点按目标键开始，松开前软件收音，松开=再点按结束。\n按住式：按住语音键期间保持目标键按下，松开后 0.4 秒释放（尾音送完）。\n目标软件需先选择输入源（本程序回放或虚拟声卡）。",
            Dock = DockStyle.Top,
            Height = 84,
            ForeColor = Color.DimGray,
        };
        void ApplyVoice()
        {
            var mode = (VoiceShortcutMode)_voiceModeCombo.SelectedIndex;
            var vks = mode == VoiceShortcutMode.Off ? null : VkNames.VoicePresets[_voicePresetCombo.SelectedIndex].Vks;
            _store.SetVoiceShortcut(mode, vks);
        }
        _voiceModeCombo.SelectedIndexChanged += (s, e) => ApplyVoice();
        _voicePresetCombo.SelectedIndexChanged += (s, e) => ApplyVoice();
        voiceGroup.Controls.Add(voiceHint);
        voiceGroup.Controls.Add(_voicePresetCombo);
        voiceGroup.Controls.Add(presetLabel);
        voiceGroup.Controls.Add(_voiceModeCombo);
        voiceGroup.Controls.Add(modeLabel);

        rightPanel.Controls.Add(voiceGroup);
        rightPanel.Controls.Add(configGroup);
        rightPanel.Controls.Add(_enableCheck);

        Controls.Add(rightPanel);
        Controls.Add(leftPanel);

        KeyPreview = true;
        KeyDown += (s, e) =>
        {
            if (e.KeyCode == Keys.Escape)
            {
                _captureButton.Text = "键盘录入组合键…";
                _presetCombo.Enabled = true;
                e.Handled = true;
                return;
            }
            if (!_presetCombo.Enabled && _selected is { } button) // capturing
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                var vks = new List<ushort>();
                if (e.Modifiers.HasFlag(Keys.Control)) vks.Add(0xA2);
                if (e.Modifiers.HasFlag(Keys.Shift)) vks.Add(0xA0);
                if (e.Modifiers.HasFlag(Keys.Alt)) vks.Add(0xA4);
                if (e.KeyCode is not (Keys.Control or Keys.Shift or Keys.Alt or Keys.Menu))
                {
                    vks.Add((ushort)e.KeyValue);
                    _store.Set(button, vks.ToArray());
                    _captureButton.Text = "键盘录入组合键…";
                    _presetCombo.Enabled = true;
                    RefreshConfigPanel();
                }
            }
        };
    }

    private void RefreshConfigPanel()
    {
        if (_selected is not { } button)
        {
            _selectedLabel.Text = "（先点击左侧示意图选择按键）";
            _currentLabel.Text = "";
            return;
        }
        _selectedLabel.Text = $"「{button.Title()}」键";
        var current = _store.Get(button);
        _currentLabel.Text = current is null ? "当前：未映射" : $"当前：{current.Describe()}";
        _presetCombo.SelectedIndex = current is null ? 0
            : Array.FindIndex(VkNames.Presets, p => p.Vks.SequenceEqual(current.VirtualKeys)) is var i && i >= 0 ? i + 1 : 0;
        _illustration.Highlight = button;
        _illustration.Invalidate();
    }
}

/// <summary>Clickable RC003-MS illustration with macOS-style hotspot layout.</summary>
public sealed class RemoteIllustration : Control
{
    private static readonly (RemoteButton Button, float X, float Y, float W, float H)[] Hotspots =
    [
        // Layout mirrored from the macOS RemoteIllustrationLayout (180×480).
        (RemoteButton.Power, 20, 31, 42, 42),      // x=50-30, y=52-21 … normalized below
        (RemoteButton.Microphone, 109, 31, 42, 42),
        (RemoteButton.Up, 66, 94, 48, 30),
        (RemoteButton.Left, 26, 127, 32, 48),
        (RemoteButton.Ok, 68, 127, 44, 44),
        (RemoteButton.Right, 122, 127, 32, 48),
        (RemoteButton.Down, 66, 174, 48, 30),
        (RemoteButton.Back, 28, 233, 44, 44),
        (RemoteButton.Home, 28, 295, 44, 44),
        (RemoteButton.Menu, 28, 357, 44, 44),
        (RemoteButton.VolumeUp, 109, 253, 42, 44),
        (RemoteButton.VolumeDown, 109, 309, 42, 44),
        (RemoteButton.Tv, 109, 372, 44, 44),
    ];

    public event Action<RemoteButton>? ButtonSelected;

    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public RemoteButton? Highlight { get; set; }

    private RemoteButton? _hover;

    public RemoteIllustration()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
    }

    private RectangleF MapRect(float x, float y, float w, float h)
    {
        // Source layout space: 180×480 → scaled to control bounds.
        float sx = ClientRectangle.Width / 180f, sy = ClientRectangle.Height / 480f;
        return new RectangleF(x * sx, y * sy, w * sx, h * sy);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        // Device body
        float sx = ClientRectangle.Width / 180f, sy = ClientRectangle.Height / 480f;
        var body = new RectangleF(8 * sx, 10 * sy, 164 * sx, 460 * sy);
        using (var bodyPath = RoundedPath(g, body, 26 * sx))
        {
            using var fill = new LinearGradientBrush(body, Color.FromArgb(245, 246, 248), Color.FromArgb(225, 228, 233), 90f);
            g.FillPath(fill, bodyPath);
            using var pen = new Pen(Color.FromArgb(190, 194, 200), 1.4f);
            g.DrawPath(pen, bodyPath);
        }
        foreach (var (button, x, y, w, h) in Hotspots)
        {
            var rect = MapRect(x + 3, y + 3, w - 6, h - 6);
            bool selected = button == Highlight;
            bool hover = button == _hover;
            using (var path = RoundedPath(g, rect, 10 * Math.Min(sx, sy)))
            {
                using var brush = new SolidBrush(selected ? Color.FromArgb(0xD6, 0xEA, 0xFF) : hover ? Color.FromArgb(0xEC, 0xF3, 0xFB) : Color.FromArgb(0xF7, 0xF9, 0xFB));
                g.FillPath(brush, path);
                using var pen = new Pen(selected ? Color.FromArgb(0x1E, 0x88, 0xE5) : Color.FromArgb(0xC9, 0xD2, 0xDC), selected ? 2f : 1.2f);
                g.DrawPath(pen, path);
            }
            var label = button.Title();
            using var font = new Font("Microsoft YaHei UI", Math.Max(7.5f, 9f * Math.Min(sx, 1.1f)));
            using var text = new SolidBrush(selected ? Color.FromArgb(0x0D, 0x47, 0xA1) : Color.FromArgb(0x37, 0x47, 0x5C));
            var size = g.MeasureString(label, font);
            g.DrawString(label, font, text,
                rect.Left + (rect.Width - size.Width) / 2,
                rect.Top + (rect.Height - size.Height) / 2);
        }
    }

    private static System.Drawing.Drawing2D.GraphicsPath RoundedPath(Graphics g, RectangleF rect, float radius)
    {
        var path = new System.Drawing.Drawing2D.GraphicsPath();
        float r = Math.Min(radius, Math.Min(rect.Width, rect.Height) / 2);
        path.AddArc(rect.X, rect.Y, r * 2, r * 2, 180, 90);
        path.AddArc(rect.Right - r * 2, rect.Y, r * 2, r * 2, 270, 90);
        path.AddArc(rect.Right - r * 2, rect.Bottom - r * 2, r * 2, r * 2, 0, 90);
        path.AddArc(rect.X, rect.Bottom - r * 2, r * 2, r * 2, 90, 90);
        path.CloseFigure();
        return path;
    }

    private RemoteButton? HitTest(Point point)
    {
        float sx = ClientRectangle.Width / 180f, sy = ClientRectangle.Height / 480f;
        foreach (var (button, x, y, w, h) in Hotspots)
        {
            var rect = MapRect(x, y, w, h);
            if (rect.Contains(point)) return button;
        }
        return null;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var hit = HitTest(e.Location);
        if (hit != _hover) { _hover = hit; Invalidate(); Cursor = hit is null ? Cursors.Default : Cursors.Hand; }
        base.OnMouseMove(e);
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        if (HitTest(e.Location) is { } button) ButtonSelected?.Invoke(button);
        base.OnMouseClick(e);
    }
}

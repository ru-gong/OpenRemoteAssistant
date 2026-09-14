// SPDX-License-Identifier: GPL-3.0-only
// WebView2 main window: hosts the HTML UI and bridges it to the voice and
// mapping services through UiBridge.

using Microsoft.Web.WebView2.Core;
using System.Collections.Concurrent;
using System.Text;

namespace OpenRemoteAssistant.Win;

public sealed class MainForm : Form
{
    private readonly RemoteVoiceService _service = new();
    private readonly BindingStore _bindingStore = new();
    private readonly MappingStore _mappingStore;
    private readonly MappingEngine _mappingEngine;
    private readonly UiBridge _bridge;
    private readonly Microsoft.Web.WebView2.WinForms.WebView2 _webView = new();
    private RawInputObserver? _rawInput;
    private bool _engineActive;
    private readonly ConcurrentQueue<string> _logQueue = new();
    private int _logFlushScheduled;

    public MainForm()
    {
        Text = "遥控器助手";
        Font = new Font("Microsoft YaHei UI", 9F);

        // High-DPI displays (this target runs at 200%) make WinForms size in
        // device pixels: a fixed 980×700 collapses the WebView2 CSS viewport
        // to ~490 px and squeezes the whole UI into a narrow column. Size in
        // logical units instead so the HTML always gets a comfortable width.
        AutoScaleMode = AutoScaleMode.None;
        float dpiScale = 1f;
        try { using var g = CreateGraphics(); dpiScale = g.DpiX / 96f; } catch { }
        if (dpiScale < 1f) dpiScale = 1f;
        ClientSize = new Size((int)(1040 * dpiScale), (int)(660 * dpiScale));
        MinimumSize = new Size((int)(880 * dpiScale), (int)(580 * dpiScale));

        // Center on the working area ourselves: StartPosition=CenterScreen is
        // computed before the DPI-aware resize settles and lands off-screen.
        StartPosition = FormStartPosition.Manual;
        var work = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1920, 1080);
        Location = new Point(
            work.Left + Math.Max(0, (work.Width - Width) / 2),
            work.Top + Math.Max(0, (work.Height - Height) / 2));

        var dataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenRemoteAssistant");
        _mappingStore = new MappingStore(Path.Combine(dataDir, "mapping.json"));
        _mappingEngine = new MappingEngine(_mappingStore);
        _mappingEngine.OnLog = m => AppendLog(m);
        RawInputObserver.OnError = m => AppendLog(m);
        _bridge = new UiBridge(
            _service, _bindingStore, _mappingStore, _mappingEngine,
            () => _bindingStore.RecordingsFolder,
            (v) => _bindingStore.RecordingsFolder = v);
        _bridge.SetUiThread(this);
        _bridge.SetLogSink(m => BeginInvoke(() => AppendLog(m)));
        // GATT control chunks we don't natively parse (likely D-pad/other keys):
        // log the raw payload so the code table can be finalized from reality.
        _service.OnUnknownControl += payload =>
            AppendLog($"[GATT控制] 未解析块：{Convert.ToHexString(payload)}");
        _bridge.Attach(_webView);

        _webView.Dock = DockStyle.Fill;
        Controls.Add(_webView);

        // The form handle can be recreated (e.g. during WebView2 init); raw
        // input registrations bind to the handle, so re-register on recreation.
        HandleCreated += (s, e) =>
        {
            try { RegisterRawInput(); }
            catch (Exception ex) { AppendLog($"[映射] Raw Input 重注册失败：{ex.Message}"); }
        };

        Load += async (s, e) =>
        {
            try
            {
                var env = await CoreWebView2Environment.CreateAsync(
                    userDataFolder: Path.Combine(dataDir, "WebView2"));
                await _webView.EnsureCoreWebView2Async(env);
                _webView.CoreWebView2.Settings.AreDevToolsEnabled = false;
                _webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
                _webView.CoreWebView2.Settings.IsStatusBarEnabled = false;
                _webView.CoreWebView2.SetVirtualHostNameToFolderMapping(
                    "app.remote", Path.Combine(AppContext.BaseDirectory, "wwwroot"),
                    CoreWebView2HostResourceAccessKind.Allow);
                _webView.CoreWebView2.Navigate("https://app.remote/index.html");
                // Raw Input (keyboard + consumer pages) for button mapping:
                // register against this form's handle; WM_INPUT is routed in WndProc.
                try
                {
                    RegisterRawInput();
                    LogRawDevices();
                }
                catch (Exception ex)
                {
                    AppendLog($"[映射] Raw Input 初始化失败：{ex.Message}");
                }
                if (_mappingStore.Enabled) StartMapping();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this,
                    "界面组件（WebView2）初始化失败：\n" + ex.Message +
                    "\n\n请安装 Microsoft Edge WebView2 Runtime 后重试。",
                    "初始化失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
                Close();
            }
        };

        FormClosing += (s, e) =>
        {
            RawInputObserver.StaticEvent -= OnRawInput;
            try { _rawInput?.Dispose(); } catch { }
            try { _mappingEngine.Dispose(); } catch { }
            try { _service.Dispose(); } catch { }
            try { _bridge.ShutdownBleThread(); } catch { }
        };
    }

    private void RegisterRawInput()
    {
        _rawInput?.Dispose();
        _rawInput = new RawInputObserver(Handle);
        RawInputObserver.StaticEvent -= OnRawInput;
        RawInputObserver.StaticEvent += OnRawInput;
        AppendLog("[映射] Raw Input 已注册。");
    }

    /// <summary>
    /// Logs every raw-input device once at startup: makes it obvious which
    /// keyboard interface the remote exposes and whether it was matched.
    /// </summary>
    private void LogRawDevices()
    {
        var devices = RawInputObserver.EnumerateDevices();
        int keyboards = devices.Count(d => d.Type == 1);
        AppendLog($"[映射] 检测到 {devices.Count} 个输入设备（键盘类 {keyboards} 个）：");
        foreach (var (type, path, remote) in devices)
        {
            if (type != 1 && !remote) continue;
            AppendLog($"[映射]   {(remote ? "★ 遥控器  " : "  本地键盘")} {RemoteHidDevices.Describe(path)}");
        }
    }

    private void OnRawInput(RawKeyEvent evt)
    {
        try { _mappingEngine.HandleRawEvent(evt); } catch (Exception ex)
        {
            AppendLog($"[映射] 事件处理异常：{ex.Message}");
        }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x00FF) // WM_INPUT
        {
            try { RawInputObserver.ProcessWmInput(m.LParam); }
            catch { /* never let raw input kill the pump */ }
        }
        base.WndProc(ref m);
    }

    private void StartMapping()
    {
        try
        {
            _mappingEngine.Start();
            _engineActive = true;
            AppendLog("[映射] 已启用。");
        }
        catch (Exception ex)
        {
            AppendLog($"[映射] 启用失败：{ex.Message}");
        }
    }

    private void AppendLog(string message)
    {
        // Queue only: this is called from the keyboard-filter and Raw Input
        // paths, so it must never touch the disk. Identical runs are collapsed
        // when the queue drains (a held key can repeat thousands of times).
        _logQueue.Enqueue(message);
        if (Interlocked.CompareExchange(ref _logFlushScheduled, 1, 0) != 0) return;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(400);
                FlushLogs();
            }
            catch { }
            finally { Interlocked.Exchange(ref _logFlushScheduled, 0); }
        });
    }

    private void FlushLogs()
    {
        var lines = new List<string>();
        while (_logQueue.TryDequeue(out var line)) lines.Add(line);
        if (lines.Count == 0) return;

        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenRemoteAssistant");
        Directory.CreateDirectory(dir);
        var logPath = Path.Combine(dir, "app.log");
        try
        {
            // Keep the file bounded — it is a diagnostic trail, not a journal.
            var info = new FileInfo(logPath);
            if (info.Exists && info.Length > 4 * 1024 * 1024)
            {
                var old = Path.Combine(dir, "app.log.old");
                if (File.Exists(old)) File.Delete(old);
                File.Move(logPath, old);
            }
        }
        catch { }

        var sb = new StringBuilder();
        var stamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        int i = 0;
        while (i < lines.Count)
        {
            int j = i;
            while (j + 1 < lines.Count && lines[j + 1] == lines[i]) j++;
            sb.Append('[').Append(stamp).Append("] ").Append(lines[i]);
            if (j > i) sb.Append($"（重复 {j - i + 1} 次）");
            sb.Append('\n');
            i = j + 1;
        }
        if (lines.Count > 200) sb.Append($"[{stamp}] （本轮共 {lines.Count} 条已折叠写入）\n");
        try { File.AppendAllText(logPath, sb.ToString()); } catch { }
    }
}

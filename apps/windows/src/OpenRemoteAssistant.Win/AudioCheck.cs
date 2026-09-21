// SPDX-License-Identifier: GPL-3.0-only
// Audio path self-check for remote support.
//
// "Playback is on but the voice software hears nothing" has a handful of
// causes that look identical from the outside: the endpoints are not live yet
// (VB-CABLE needs a reboot), the configured output silently fell back to the
// real speakers, the endpoint is disabled, or Windows privacy settings block
// capture. This file turns that guesswork into measurements:
//
//   1. enumerate every endpoint with its actual state, plus the winmm list the
//      UI dropdown is built from;
//   2. push a 1 kHz tone through the *same* sink the voice session uses, so the
//      device-resolution logic is exercised for real;
//   3. capture the cable's recording endpoint at the same time and measure the
//      baseline noise floor versus the tone window.
//
// The whole report is plain text on purpose: a user can copy it out of the log
// or attach the file without us having to sit at their machine.

using System.Diagnostics;
using System.Globalization;
using System.Text;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace OpenRemoteAssistant.Win;

public sealed record AudioCheckResult(string Report, string Verdict, bool Passed);

public static class AudioCheck
{
    /// <summary>Tone length. Long enough to survive the sink's 120 ms prebuffer
    /// and the capture device's own startup lag, short enough to stay polite.</summary>
    public const int ToneMs = 1200;
    private const int ToneHz = 1000;
    private const short ToneAmplitude = 11000;
    /// <summary>Baseline window measured before the tone, to separate "the cable
    /// is permanently noisy" from "our audio actually arrived".</summary>
    private const int BaselineMs = 300;

    /// <summary>
    /// Runs the full check. <paramref name="renderDevice"/> is the same winmm
    /// name the settings store holds; <paramref name="captureDevice"/> is an
    /// optional capture endpoint name, auto-picked when null.
    /// </summary>
    public static AudioCheckResult Run(string? renderDevice = null, string? captureDevice = null)
    {
        var sb = new StringBuilder();
        sb.AppendLine("OpenRemoteAssistant 音频自检报告");
        sb.AppendLine($"版本  ：{VersionInfo.Version} (build {VersionInfo.Build})");
        sb.AppendLine($"时间  ：{DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        sb.AppendLine($"系统  ：{Environment.OSVersion} / {(Environment.Is64BitProcess ? "64" : "32")} 位进程");
        sb.AppendLine();

        // ---------------- 1. endpoints ----------------
        var renders = Enumerate(DataFlow.Render);
        var captures = Enumerate(DataFlow.Capture);
        DumpEndpoints(sb, "播放端点（WASAPI）", renders);
        DumpEndpoints(sb, "录制端点（WASAPI）", captures);

        sb.AppendLine("winmm 播放设备（界面下拉框的数据来源）");
        var winmm = WaveOutSink.EnumerateOutputDevices();
        if (winmm.Count == 0) sb.AppendLine("  （无）");
        foreach (var (index, name) in winmm)
        {
            // winmm truncates szPname at 31 chars — worth flagging, because a
            // name chopped mid-parenthesis is what the user sees in the picker.
            var note = name.Length >= 31 ? "   ← 可能被 winmm 截断" : "";
            sb.AppendLine($"  [{index}] {name}{note}");
        }
        sb.AppendLine();

        // ---------------- 2. driver + settings ----------------
        bool driverRegistered = UiBridge.IsCableDriverRegistered();
        bool cableLive = UiBridge.IsVirtualCableInstalled();
        sb.AppendLine("驱动与设置");
        sb.AppendLine($"  CABLE 驱动已注册（注册表）    ：{Yes(driverRegistered)}");
        sb.AppendLine($"  虚拟声卡端点在用（端点枚举）  ：{Yes(cableLive)}");
        sb.AppendLine($"  当前设定的回放输出            ：{(string.IsNullOrWhiteSpace(renderDevice) ? "（未设定，用系统默认）" : renderDevice)}");

        var fragment = UiBridge.WasapiFragmentFor(renderDevice);
        sb.AppendLine($"  解析出的匹配片段              ：{(fragment is null ? "（无）" : fragment)}");
        var muted = DetectLikelyMuted(renders, fragment);
        if (muted is not null)
            sb.AppendLine($"  ⚠ 注意：{muted}");

        using (var en = new MMDeviceEnumerator())
        {
            sb.AppendLine($"  Windows 默认播放设备          ：{TryDefaultName(en, DataFlow.Render)}");
            sb.AppendLine($"  Windows 默认录音设备          ：{TryDefaultName(en, DataFlow.Capture)}");
        }
        sb.AppendLine();

        // ---------------- 3. loopback ----------------
        sb.AppendLine($"回环测试（{ToneMs} ms / {ToneHz} Hz）");
        var target = PickCapture(captures, captureDevice);
        if (target is null)
        {
            sb.AppendLine("  录制端点：未找到可用端点（没有 CABLE Output / 立体声混音）。");
            sb.AppendLine("  说明：无法验证回环。请先确认虚拟声卡已安装并已重启电脑。");
            var noCap = "⚠️ 未找到可回环的录制端点（CABLE Output / 立体声混音），无法验证音频是否真正送达。";
            if (!cableLive)
                noCap = "❌ 未检测到在用的虚拟声卡端点。装上 VB-CABLE 后必须重启电脑，端点才会生效。";
            return new AudioCheckResult(sb.ToString(), noCap, false);
        }

        sb.AppendLine($"  录制端点：{target.FriendlyName}");

        var meter = new LevelMeter();
        WasapiCapture? capture = null;
        string? captureError = null;
        try
        {
            capture = new WasapiCapture(target);
            capture.DataAvailable += (_, e) => meter.Add(e.Buffer, e.BytesRecorded, capture.WaveFormat);
            capture.StartRecording();
        }
        catch (Exception ex)
        {
            captureError = ex.Message;
            try { capture?.Dispose(); } catch { }
            capture = null;
        }

        if (capture is null)
        {
            sb.AppendLine($"  ❌ 录制端点打不开：{captureError}");
            sb.AppendLine("     常见原因：Windows「隐私和安全性 → 麦克风」禁止桌面应用访问，或该设备被别的程序独占。");
            return new AudioCheckResult(sb.ToString(),
                $"❌ 无法从「{target.FriendlyName}」录音：{captureError}。请检查 Windows 麦克风隐私设置，或该设备是否被独占。",
                false);
        }

        double basePeak, tonePeak, toneRms;
        long toneSamples;
        bool prepared, fellBack, enqueued;
        string endpointUsed, sendError = "";
        try
        {
            Thread.Sleep(BaselineMs);            // baseline noise floor
            basePeak = meter.Peak;
            meter.Reset();

            using var sink = new WasapiOutSink(fragment);
            prepared = sink.Prepare();
            fellBack = sink.FellBackToDefault;
            endpointUsed = sink.EndpointName;
            enqueued = prepared && PlayToneThrough(sink);
            sendError = sink.LastError;

            // Let the sink's own drain timer (buffered tail + 300 ms) land
            // before reading the meter.
            Thread.Sleep(1500);
            tonePeak = meter.Peak;
            toneRms = meter.Rms;
            toneSamples = meter.Samples;
        }
        finally
        {
            try { capture.StopRecording(); } catch { }
            try { capture.Dispose(); } catch { }
        }

        sb.AppendLine($"  输出端点实际使用：{(prepared ? endpointUsed : "（打开失败）")}");
        if (fellBack)
            sb.AppendLine("  ⚠ 设定的设备没有匹配到，已悄悄回退到系统默认设备——这是最容易让人误判的一种情况。");
        sb.AppendLine($"  送出音调        ：{(enqueued ? $"已入队 {ToneMs} ms" : $"失败 {sendError}")}");
        sb.AppendLine($"  底噪峰值        ：{basePeak.ToString("F4", CultureInfo.InvariantCulture)}");
        sb.AppendLine($"  音调段峰值 / RMS：{tonePeak.ToString("F4", CultureInfo.InvariantCulture)} / {toneRms.ToString("F4", CultureInfo.InvariantCulture)}（{toneSamples:N0} 采样）");
        sb.AppendLine();

        var (verdict, passed) = Judge(prepared, fellBack, enqueued, sendError, basePeak, tonePeak, toneSamples, endpointUsed);
        sb.AppendLine("结论");
        sb.AppendLine($"  {verdict}");
        return new AudioCheckResult(sb.ToString(), verdict, passed);
    }

    /// <summary>
    /// Turns the measurements into a verdict. Thresholds are deliberately
    /// generous: a cable that carries *anything* clearly above its own noise
    /// floor is working, and we would rather pass a quiet-but-real link than
    /// send someone chasing a false alarm.
    /// </summary>
    private static (string Verdict, bool Passed) Judge(
        bool prepared, bool fellBack, bool enqueued, string sendError,
        double basePeak, double tonePeak, long toneSamples, string endpointUsed)
    {
        if (!prepared)
            return ($"❌ 回放输出端点「{endpointUsed}」打不开：{sendError}。该设备可能已被禁用，或未重启导致驱动尚未生效。", false);
        if (!enqueued)
            return ($"❌ 音频送不出去：{sendError}", false);
        if (toneSamples == 0)
            return ("❌ 录制端点在测试期间一个采样都没收到——设备可能未生效，或访问被系统阻止。", false);

        double floor = Math.Max(0.02, basePeak * 3);
        if (tonePeak >= floor)
        {
            var extra = fellBack
                ? " 但要留意：音频其实被送回了系统默认设备，说明设定的设备名没匹配上。"
                : "";
            return ($"✅ 链路通：{ToneMs} ms 测试音已从回放输出送达录制端点（峰值 {tonePeak:F4}，底噪 {basePeak:F4}）。{extra}"
                    + "若语音软件仍听不到，请把它的麦克风设为该录制端点。", true);
        }
        if (tonePeak <= 0.001)
            return ($"❌ 录制端点完全没有信号（峰值 {tonePeak:F4}）。音频没有到达虚拟声卡——"
                    + "最常见的原因是装完 VB-CABLE 没有重启电脑，其次是输出选成了真实扬声器。", false);
        return ($"⚠️ 收到信号但明显偏弱（峰值 {tonePeak:F4}，底噪 {basePeak:F4}）。"
                + "可能是设备音量被调低、系统正在做音量归一化，或选错了端点。", false);
    }

    /// <summary>
    /// Feeds the tone in real time (30 ms slices) rather than dumping it in one
    /// go, so the sink follows the same prebuffer-then-stream pattern a real
    /// hold produces. A bulk enqueue would play back fine but would not prove
    /// the path works under streaming conditions.
    /// </summary>
    private static bool PlayToneThrough(WasapiOutSink sink)
    {
        int rate = Rc003VoiceProtocol.SampleRate;
        int total = rate * ToneMs / 1000;
        var pcm = new short[total];
        int fade = rate / 50; // 20 ms
        for (int i = 0; i < total; i++)
        {
            double envelope = 1.0;
            if (i < fade) envelope = i / (double)fade;
            else if (i > total - fade) envelope = (total - i) / (double)fade;
            pcm[i] = (short)(Math.Sin(2 * Math.PI * ToneHz * i / rate) * ToneAmplitude * envelope);
        }

        const int chunk = 480; // 30 ms
        var clock = Stopwatch.StartNew();
        int sent = 0;
        while (sent < total)
        {
            int n = Math.Min(chunk, total - sent);
            if (!sink.Enqueue(pcm.AsSpan(sent, n))) return false;
            sent += n;
            long due = (long)(sent * 1000.0 / rate);
            int wait = (int)(due - clock.ElapsedMilliseconds);
            if (wait > 1) Thread.Sleep(wait);
        }
        sink.FinishAfterDraining();
        return true;
    }

    private static MMDevice? PickCapture(List<MMDevice> captures, string? wanted)
    {
        if (!string.IsNullOrWhiteSpace(wanted))
        {
            var hit = captures.FirstOrDefault(d =>
                d.FriendlyName.Contains(wanted, StringComparison.OrdinalIgnoreCase));
            if (hit is not null) return hit;
        }
        // The cable first, then Windows' own loopback device as a fallback.
        return captures.FirstOrDefault(d => d.FriendlyName.Contains("CABLE", StringComparison.OrdinalIgnoreCase))
            ?? captures.FirstOrDefault(d => d.FriendlyName.Contains("Virtual Audio", StringComparison.OrdinalIgnoreCase))
            ?? captures.FirstOrDefault(d => d.FriendlyName.Contains("混音", StringComparison.Ordinal))
            ?? captures.FirstOrDefault(d => d.FriendlyName.Contains("Stereo Mix", StringComparison.OrdinalIgnoreCase));
    }

    private static List<MMDevice> Enumerate(DataFlow flow)
    {
        var list = new List<MMDevice>();
        try
        {
            using var en = new MMDeviceEnumerator();
            // DeviceState.All, not .Active: a disabled or not-yet-rebooted
            // endpoint is exactly the case we need to be able to see.
            foreach (var d in en.EnumerateAudioEndPoints(flow, DeviceState.All)) list.Add(d);
        }
        catch { }
        return list;
    }

    private static void DumpEndpoints(StringBuilder sb, string title, List<MMDevice> devices)
    {
        sb.AppendLine(title);
        if (devices.Count == 0) { sb.AppendLine("  （无）"); sb.AppendLine(); return; }
        foreach (var d in devices)
        {
            sb.AppendLine($"  [{State(d)}] {d.FriendlyName}");
            try { sb.AppendLine($"      ID: {d.ID}"); } catch { }
        }
        sb.AppendLine();
    }

    private static string State(MMDevice d)
    {
        try
        {
            return d.State switch
            {
                DeviceState.Active => "在用",
                DeviceState.Disabled => "已禁用",
                DeviceState.NotPresent => "未安装",
                DeviceState.Unplugged => "未插入",
                _ => d.State.ToString(),
            };
        }
        catch { return "未知"; }
    }

    private static string TryDefaultName(MMDeviceEnumerator en, DataFlow flow)
    {
        try { return en.GetDefaultAudioEndpoint(flow, Role.Multimedia).FriendlyName; }
        catch { return "（无）"; }
    }

    /// <summary>
    /// Flags the classic "the picker kept a device name that no longer exists"
    /// case: a fragment was configured but no live endpoint carries it.
    /// </summary>
    private static string? DetectLikelyMuted(List<MMDevice> renders, string? fragment)
    {
        if (fragment is null) return null;
        bool anyActive = renders.Any(d =>
        {
            try { return d.State == DeviceState.Active && d.FriendlyName.Contains(fragment, StringComparison.OrdinalIgnoreCase); }
            catch { return false; }
        });
        if (anyActive) return null;
        bool existsButIdle = renders.Any(d => d.FriendlyName.Contains(fragment, StringComparison.OrdinalIgnoreCase));
        return existsButIdle
            ? $"设定的输出设备「{fragment}」存在但不是「在用」状态（可能被禁用或未重启），回放会静默回退到系统默认设备。"
            : $"设定的输出设备「{fragment}」在系统里不存在，回放会静默回退到系统默认设备。";
    }

    private static string Yes(bool value) => value ? "是" : "否";

    /// <summary>Accumulates peak/RMS for whatever the capture thread receives.</summary>
    private sealed class LevelMeter
    {
        private readonly object _lock = new();
        private double _peak;
        private double _sumSq;
        private long _samples;

        public double Peak { get { lock (_lock) return _peak; } }
        public long Samples { get { lock (_lock) return _samples; } }
        public double Rms
        {
            get
            {
                lock (_lock) return _samples == 0 ? 0 : Math.Sqrt(_sumSq / _samples);
            }
        }

        public void Reset()
        {
            lock (_lock) { _peak = 0; _sumSq = 0; _samples = 0; }
        }

        public void Add(byte[] buffer, int count, WaveFormat format)
        {
            if (count <= 0) return;
            bool isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat && format.BitsPerSample == 32;
            bool is16 = format.BitsPerSample == 16;
            if (!isFloat && !is16) return; // don't guess at exotic formats

            double peak = 0, sumSq = 0;
            long n = 0;
            if (isFloat)
            {
                for (int i = 0; i + 4 <= count; i += 4)
                {
                    double v = BitConverter.ToSingle(buffer, i);
                    double a = Math.Abs(v);
                    if (a > peak) peak = a;
                    sumSq += v * v;
                    n++;
                }
            }
            else
            {
                for (int i = 0; i + 2 <= count; i += 2)
                {
                    double v = BitConverter.ToInt16(buffer, i) / 32768.0;
                    double a = Math.Abs(v);
                    if (a > peak) peak = a;
                    sumSq += v * v;
                    n++;
                }
            }
            if (n == 0) return;
            lock (_lock)
            {
                if (peak > _peak) _peak = peak;
                _sumSq += sumSq;
                _samples += n;
            }
        }
    }
}

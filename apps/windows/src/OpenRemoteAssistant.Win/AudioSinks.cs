// SPDX-License-Identifier: GPL-3.0-only
// Audio sinks for the Windows port: WAV recording and winmm waveOut playback.
// The macOS original routes decoded PCM into a CoreAudio HAL driver
// (OpenRemoteAudio.driver); a kernel virtual microphone is out of scope for
// this MVP, so recording to WAV and/or real-time local playback is provided.

using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Text;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace OpenRemoteAssistant.Win;

/// <summary>Consumer of decoded 16 kHz mono s16le PCM frames.</summary>
public interface IVoiceAudioSink : IDisposable
{
    string Name { get; }
    /// <summary>Prepare the sink before the microphone opens. Returns false on failure.</summary>
    bool Prepare();
    /// <summary>Enqueue one decoded frame. Returns false when the sink failed.</summary>
    bool Enqueue(ReadOnlySpan<short> pcm);
    /// <summary>After a normal release: deliver already-queued tail audio, then finish.</summary>
    void FinishAfterDraining();
    /// <summary>Immediate teardown on failure or service stop.</summary>
    void StopImmediately();
}

/// <summary>No-op sink: both playback and recording disabled (voice-input-only mode).</summary>
public sealed class NullSink : IVoiceAudioSink
{
    public string Name => "无输出";
    public bool Prepare() => true;
    public bool Enqueue(ReadOnlySpan<short> pcm) => true;
    public void FinishAfterDraining() { }
    public void StopImmediately() { }
    public void Dispose() { }
}

/// <summary>
/// WASAPI shared-mode renderer (NAudio WasapiOut + BufferedWaveProvider).
/// Replaces the winmm waveOut path for routing into a virtual cable: event
/// driven playback, no manual buffer management, resilient to the bursty
/// arrival of BLE audio frames (underruns emit silence instead of glitches).
/// The buffered provider is pre-filled to ~200 ms before playback starts so
/// short notify gaps never reach the listener.
/// </summary>
public sealed class WasapiOutSink : IVoiceAudioSink
{
    private const int SampleRate = Rc003VoiceProtocol.SampleRate;
    private static readonly WaveFormat Format = new(SampleRate, 16, 1);

    private readonly string? _deviceIdFragment;
    private MMDeviceEnumerator? _enumerator;
    private WasapiOut? _output;
    private BufferedWaveProvider? _buffer;
    private bool _playing;

    public long EnqueuedFrames;
    public long EnqueuedBytes;
    public string EndpointName = "";
    public event Action? DrainCompleted;

    public WasapiOutSink(string? deviceIdFragment = null) =>
        _deviceIdFragment = string.IsNullOrWhiteSpace(deviceIdFragment) ? null : deviceIdFragment;

    public string Name => "wasapi";

    /// <summary>List WASAPI render endpoints (friendly names), for the UI.</summary>
    public static List<(string Id, string Name)> EnumerateEndpoints()
    {
        var list = new List<(string, string)>();
        using var en = new MMDeviceEnumerator();
        foreach (var d in en.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            list.Add((d.ID, d.FriendlyName));
        return list;
    }

    private MMDevice? ResolveDevice()
    {
        _enumerator = new MMDeviceEnumerator();
        if (_deviceIdFragment is { } frag)
        {
            foreach (var d in _enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            {
                if (d.FriendlyName.Contains(frag, StringComparison.OrdinalIgnoreCase))
                    return d;
            }
        }
        return _enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
    }

    public bool Prepare()
    {
        try
        {
            DisposeOutput();
            var device = ResolveDevice();
            if (device is null) return false;
            EndpointName = device.FriendlyName;
            _output = new WasapiOut(device, AudioClientShareMode.Shared, useEventSync: true, latency: 120);
            _buffer = new BufferedWaveProvider(Format)
            {
                // Default BufferDuration is 10 s — plenty of burst absorption.
                DiscardOnBufferOverflow = true,
                ReadFully = false, // underruns yield silence, not repeats
            };
            // Event-driven mode stops playback when the buffer runs dry.
            // Track that, or _playing stays true and we never resume.
            _output.PlaybackStopped += (_, _) => _playing = false;
            _output.Init(_buffer);
            return true;
        }
        catch
        {
            DisposeOutput();
            return false;
        }
    }

    public bool Enqueue(ReadOnlySpan<short> pcm)
    {
        var buffer = _buffer;
        var output = _output;
        if (buffer is null || output is null) return false;
        var bytes = MemoryMarshal.AsBytes(pcm).ToArray();
        buffer.AddSamples(bytes, 0, bytes.Length);
        Interlocked.Increment(ref EnqueuedFrames);
        Interlocked.Add(ref EnqueuedBytes, bytes.Length);

        // (Re)start playback whenever there is enough buffered audio. Covers
        // the first Play AND resuming after an underrun auto-stop.
        if (!_playing && buffer.BufferedDuration >= TimeSpan.FromMilliseconds(120))
        {
            try { output.Play(); _playing = true; }
            catch { return false; }
        }
        return true;
    }

    public void FinishAfterDraining()
    {
        // Give the buffered tail ~300 ms + its own duration to play out, then
        // stop. The sink is per-hold; full teardown happens in Dispose.
        var buffered = _buffer?.BufferedDuration ?? TimeSpan.Zero;
        var wait = buffered + TimeSpan.FromMilliseconds(300);
        var waiter = new Thread(() =>
        {
            Thread.Sleep(wait);
            try { _output?.Stop(); } catch { }
            _playing = false;
            DrainCompleted?.Invoke();
        })
        { IsBackground = true, Name = "wasapi-drain" };
        waiter.Start();
    }

    public void StopImmediately() => DisposeOutput();

    private void DisposeOutput()
    {
        try { _output?.Stop(); } catch { }
        _playing = false;
        try { _output?.Dispose(); } catch { }
        _output = null;
        _buffer = null;
        _enumerator?.Dispose();
        _enumerator = null;
    }

    public void Dispose() => DisposeOutput();
}

/// <summary>Runs several sinks together; fails closed if any member fails.</summary>
public sealed class CompositeSink : IVoiceAudioSink
{
    private readonly IVoiceAudioSink[] _sinks;
    public CompositeSink(params IVoiceAudioSink[] sinks) => _sinks = sinks;
    public string Name => string.Join("+", _sinks.Select(s => s.Name));
    public bool Prepare() => _sinks.All(s => s.Prepare());
    public bool Enqueue(ReadOnlySpan<short> pcm)
    {
        foreach (var s in _sinks) { if (!s.Enqueue(pcm)) return false; }
        return true;
    }
    public void FinishAfterDraining() { foreach (var s in _sinks) s.FinishAfterDraining(); }
    public void StopImmediately() { foreach (var s in _sinks) s.StopImmediately(); }
    public void Dispose() { foreach (var s in _sinks) s.Dispose(); }
}

/// <summary>
/// Accumulates one hold's PCM in memory and writes a WAV file on drain.
/// Mirrors the macOS behaviour of "no fixed recording length"; bounded to
/// 30 minutes of samples to keep memory predictable.
/// </summary>
public sealed class WavRecordSink : IVoiceAudioSink
{
    public const int MaxMinutes = 30;
    private readonly string _directory;
    private MemoryStream? _buffer;
    private int _samples;
    public string? LastWrittenFile { get; private set; }
    public event Action<string>? FileWritten;

    public WavRecordSink(string directory) => _directory = directory;
    public string Name => "wav";

    public bool Prepare()
    {
        try
        {
            Directory.CreateDirectory(_directory);
            _buffer = new MemoryStream(64 * 1024);
            _samples = 0;
            LastWrittenFile = null;
            return true;
        }
        catch { _buffer = null; return false; }
    }

    public bool Enqueue(ReadOnlySpan<short> pcm)
    {
        if (_buffer is null) return false;
        if (_samples >= MaxMinutes * 60 * Rc003VoiceProtocol.SampleRate) return true; // cap reached: keep file bounded
        _buffer.Write(MemoryMarshal.AsBytes(pcm));
        _samples += pcm.Length;
        return true;
    }

    public void FinishAfterDraining() => WriteFile();
    public void StopImmediately() => WriteFile();

    private void WriteFile()
    {
        if (_buffer is null) return;
        var ms = _buffer; _buffer = null;
        if (ms.Length == 0) { ms.Dispose(); return; }
        try
        {
            var stamp = DateTime.Now;
            var path = Path.Combine(_directory,
                $"遥控器录音_{stamp:yyyyMMdd_HHmmss}.{stamp.Millisecond:D3}.wav");
            // Same-millisecond collision guard: append a counter instead of
            // silently overwriting the previous hold's recording.
            int collision = 1;
            var candidate = path;
            while (File.Exists(candidate))
            {
                candidate = Path.Combine(_directory,
                    $"遥控器录音_{stamp:yyyyMMdd_HHmmss}.{stamp.Millisecond:D3}-{collision++}.wav");
            }
            path = candidate;
            using var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
            Span<byte> header = stackalloc byte[44];
            WriteWavHeader(header, (uint)ms.Length, (uint)_samples);
            fs.Write(header);
            ms.Position = 0;
            ms.CopyTo(fs);
            LastWrittenFile = path;
            FileWritten?.Invoke(path);
        }
        catch { /* keep failures silent in the sink; caller checks LastWrittenFile */ }
        finally { ms.Dispose(); }
    }

    private static void WriteWavHeader(Span<byte> h, uint dataBytes, uint samples)
    {
        "RIFF"u8.CopyTo(h); BinaryPrimitives.WriteUInt32LittleEndian(h[4..], 36 + dataBytes); "WAVE"u8.CopyTo(h[8..]);
        "fmt "u8.CopyTo(h[12..]); BinaryPrimitives.WriteUInt32LittleEndian(h[16..], 16);
        BinaryPrimitives.WriteUInt16LittleEndian(h[20..], 1);   // PCM
        BinaryPrimitives.WriteUInt16LittleEndian(h[22..], 1);   // mono
        BinaryPrimitives.WriteUInt32LittleEndian(h[24..], (uint)Rc003VoiceProtocol.SampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(h[28..], (uint)Rc003VoiceProtocol.SampleRate * 2);
        BinaryPrimitives.WriteUInt16LittleEndian(h[32..], 2);
        BinaryPrimitives.WriteUInt16LittleEndian(h[34..], 16);
        "data"u8.CopyTo(h[36..]); BinaryPrimitives.WriteUInt32LittleEndian(h[40..], dataBytes);
        _ = samples;
    }

    public void Dispose() => _buffer?.Dispose();
}

/// <summary>Real-time playback through winmm waveOut. The output device can
/// be selected so the stream can be routed into a virtual audio cable
/// (VB-Cable etc.), which other apps then see as a microphone.</summary>
public sealed class WaveOutSink : IVoiceAudioSink
{
    private const int BlockCount = 12;
    // 100 ms per block: large enough to survive BLE burst jitter between
    // notifications, small enough that the submitted blocks track real time
    // closely (250 ms blocks quantised speech into voice/silence/voice).
    private const int BlockSamples = Rc003VoiceProtocol.SampleRate / 10;
    private const int WaveFormatPcm = 1;

    private readonly string? _deviceId;
    private IntPtr _device = IntPtr.Zero;
    private readonly List<IntPtr> _buffers = [];
    private readonly Queue<PendingBlock> _pending = new();
    private readonly object _lock = new();
    /// <summary>Accumulates incoming frames until a full device block is
    /// filled. Writing half-filled blocks (frame + silence padding) turned
    /// every 250 ms into "32 ms of voice + 218 ms of silence" — the garbled
    /// noise heard on the wire.</summary>
    private readonly List<byte> _accum = [];
    private WAVEHDR[]? _headers;
    private byte[][]? _blocks;
    private bool _draining;
    public event Action? DrainCompleted;
    public string Name => "waveOut";

    /// <summary>
    /// deviceId: null/empty = default output ("WAVE_MAPPER"); otherwise a
    /// winmm device name (as from <see cref="EnumerateOutputDevices"/>).
    /// winmm identifies devices by index at open time, so the name is matched
    /// against the enumeration at Prepare().
    /// </summary>
    public WaveOutSink(string? deviceId = null) => _deviceId = string.IsNullOrWhiteSpace(deviceId) ? null : deviceId;

    /// <summary>All waveOut render endpoints: index + name, for the UI picker.</summary>
    public static List<(uint Index, string Name)> EnumerateOutputDevices()
    {
        var result = new List<(uint, string)>();
        uint count = waveOutGetNumDevs();
        for (uint i = 0; i < count; i++)
        {
            var caps = new WAVEOUTCAPS();
            if (waveOutGetDevCaps(i, ref caps, (uint)Marshal.SizeOf<WAVEOUTCAPS>()) == 0)
                result.Add((i, caps.szPname ?? $"设备 {i}"));
        }
        return result;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WAVEFORMATEX { public ushort wFormatTag, nChannels; public uint nSamplesPerSec, nAvgBytesPerSec; public ushort nBlockAlign, wBitsPerSample, cbSize; }

    [StructLayout(LayoutKind.Sequential)]
    private struct WAVEHDR { public IntPtr lpData; public uint dwBufferLength, dwBytesRecorded; public IntPtr dwUser; public uint dwFlags, dwLoops; public IntPtr lpNext, reserved; }

    private sealed record PendingBlock(byte[] Data);

    /// <summary>Diagnostics: open result and enqueue/write counters.</summary>
    public long EnqueuedFrames;
    public long WrittenBuffers;
    public int OpenResult;
    public int MatchedDeviceIndex = -1;
    public string MatchedDeviceName = "";

    [DllImport("winmm.dll")] private static extern int waveOutOpen(out IntPtr h, uint id, ref WAVEFORMATEX fmt, IntPtr callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] private static extern uint waveOutGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] private static extern int waveOutGetDevCaps(uint id, ref WAVEOUTCAPS caps, uint size);
    [DllImport("winmm.dll")] private static extern int waveOutPrepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] private static extern int waveOutUnprepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] private static extern int waveOutWrite(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] private static extern int waveOutReset(IntPtr h);
    [DllImport("winmm.dll")] private static extern int waveOutClose(IntPtr h);
    private const int WhdrPrepared = 2;
    private const int WhdrDone = 1;

    private void ReclaimBlock(int i)
    {
        // A played-out header keeps WHDR_PREPARED set (it is only cleared by
        // waveOutUnprepareHeader). Without reclaiming, all 8 blocks stay
        // "prepared" forever after their first use and every later frame is
        // stuck in _pending — measured live: enqueuedFrames=277,
        // writtenBuffers=8 (exactly 8 × 250 ms = the first two seconds).
        var header = Marshal.PtrToStructure<WAVEHDR>(_buffers[i]);
        if ((header.dwFlags & WhdrDone) != 0)
        {
            waveOutUnprepareHeader(_device, _buffers[i], Marshal.SizeOf<WAVEHDR>());
            header.dwFlags = 0;
            Marshal.StructureToPtr(header, _buffers[i], false);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WAVEOUTCAPS
    {
        public ushort wMid, wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string? szPname;
        public uint dwFormats, wChannels;
        public ushort wReserved1, dwSupport;
    }

    public bool Prepare()
    {
        lock (_lock)
        {
            StopImmediately();
            _accum.Clear();
            var fmt = new WAVEFORMATEX
            {
                wFormatTag = WaveFormatPcm, nChannels = 1,
                nSamplesPerSec = (uint)Rc003VoiceProtocol.SampleRate,
                wBitsPerSample = 16, nBlockAlign = 2,
            };
            fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;
            // Resolve the configured device name to a waveOut index. Names are
            // matched exactly first, then by prefix (some drivers append
            // suffixes). No match or no selection = WAVE_MAPPER.
            uint deviceId = 0xFFFFFFFF; // WAVE_MAPPER
            if (_deviceId is { } wanted)
            {
                foreach (var (index, name) in EnumerateOutputDevices())
                {
                    if (string.Equals(name, wanted, StringComparison.OrdinalIgnoreCase)
                        || name.StartsWith(wanted, StringComparison.OrdinalIgnoreCase))
                    {
                        deviceId = index;
                        MatchedDeviceIndex = (int)index;
                        MatchedDeviceName = name;
                        break;
                    }
                }
            }
            OpenResult = waveOutOpen(out _device, deviceId, ref fmt, IntPtr.Zero, IntPtr.Zero, 0 /*CALLBACK_NULL*/);
            if (OpenResult != 0)
                return false;
            _blocks = new byte[BlockCount][];
            _headers = new WAVEHDR[BlockCount];
            for (int i = 0; i < BlockCount; i++)
            {
                _blocks[i] = new byte[BlockSamples * 2];
                IntPtr header = Marshal.AllocHGlobal(Marshal.SizeOf<WAVEHDR>());
                _buffers.Add(header);
                _headers[i] = new WAVEHDR { lpData = Marshal.UnsafeAddrOfPinnedArrayElement(_blocks[i], 0), dwBufferLength = (uint)_blocks[i].Length };
                Marshal.StructureToPtr(_headers[i], header, false);
            }
            _draining = false;
            return true;
        }
    }

    public bool Enqueue(ReadOnlySpan<short> pcm)
    {
        lock (_lock)
        {
            if (_device == IntPtr.Zero || _headers is null || _draining) return false;
            var bytes = MemoryMarshal.AsBytes(pcm);
            int blockBytes = _blocks![0].Length;
            _accum.AddRange(bytes.ToArray());
            Interlocked.Increment(ref EnqueuedFrames);
            // Submit only FULL blocks. A partial tail stays in _accum and is
            // completed by the next frame — no silence padding, no choppy
            // playback. On drain, the tail is flushed as a short final block.
            while (_accum.Count >= blockBytes)
            {
                var full = _accum.GetRange(0, blockBytes);
                _accum.RemoveRange(0, blockBytes);
                _pending.Enqueue(new PendingBlock(full.ToArray()));
                Pump();
            }
            return true;
        }
    }

    private void Pump()
    {
        if (_device == IntPtr.Zero || _headers is null) return;
        for (int i = 0; i < BlockCount && _pending.Count > 0; i++)
        {
            ReclaimBlock(i);
            var header = Marshal.PtrToStructure<WAVEHDR>(_buffers[i]);
            if ((header.dwFlags & WhdrPrepared) != 0) continue; // still playing
            var block = _pending.Dequeue();
            Interlocked.Increment(ref WrittenBuffers);
            // block is always a FULL device block now (or the final partial
            // one flushed on drain, whose dwBufferLength is set below).
            int copy = Math.Min(block.Data.Length, _blocks![i].Length);
            Buffer.BlockCopy(block.Data, 0, _blocks[i], 0, copy);
            header.dwBufferLength = (uint)copy;
            header.dwFlags = 0;
            Marshal.StructureToPtr(header, _buffers[i], false);
            waveOutPrepareHeader(_device, _buffers[i], Marshal.SizeOf<WAVEHDR>());
            waveOutWrite(_device, _buffers[i], Marshal.SizeOf<WAVEHDR>());
        }
    }

    public void FinishAfterDraining()
    {
        // Flush any partial tail block, then let the queued audio finish and
        // close on a timer bounded by the remaining buffer length (≤ 2 s).
        lock (_lock)
        {
            _draining = true;
            if (_accum.Count > 0 && _device != IntPtr.Zero && _headers is not null)
            {
                _pending.Enqueue(new PendingBlock(_accum.ToArray()));
                _accum.Clear();
                Pump();
            }
        }
        var waiter = new Thread(WaitAndClose) { IsBackground = true, Name = "waveout-drain" };
        waiter.Start();
    }

    private void WaitAndClose()
    {
        // BlockCount × 100 ms = 1.2 s of audio; wait up to 3 s so long holds
        // finish playing before the device is torn down.
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(3);
        while (DateTime.UtcNow < deadline)
        {
            lock (_lock)
            {
                if (_pending.Count > 0) Pump();
                if (_pending.Count == 0 && AllBlocksDone()) break;
            }
            Thread.Sleep(40);
        }
        StopImmediately();
        DrainCompleted?.Invoke();
    }

    private bool AllBlocksDone()
    {
        if (_buffers.Count == 0) return true;
        foreach (var header in _buffers)
        {
            var h = Marshal.PtrToStructure<WAVEHDR>(header);
            if ((h.dwFlags & WhdrPrepared) != 0 && (h.dwFlags & WhdrDone) == 0) return false;
        }
        return true;
    }

    public void StopImmediately()
    {
        lock (_lock)
        {
            _pending.Clear();
            _draining = false;
            if (_device != IntPtr.Zero)
            {
                waveOutReset(_device);
                foreach (var header in _buffers)
                {
                    var h = Marshal.PtrToStructure<WAVEHDR>(header);
                    if ((h.dwFlags & WhdrPrepared) != 0)
                        waveOutUnprepareHeader(_device, header, Marshal.SizeOf<WAVEHDR>());
                }
                waveOutClose(_device);
                _device = IntPtr.Zero;
            }
            foreach (var header in _buffers) Marshal.FreeHGlobal(header);
            _buffers.Clear();
            _headers = null;
            _blocks = null;
        }
    }

    public void Dispose() => StopImmediately();
}

// SPDX-License-Identifier: GPL-3.0-only
// Headless CLI: self-checks that exercise the real stack without a GUI.
//   OpenRemoteAssistantWin.exe --device-check   verify the paired RC003-MS over GATT
//   OpenRemoteAssistantWin.exe --version        print version

using System.Reflection;

namespace OpenRemoteAssistant.Win;

public static class Headless
{
    public static int Run(string[] args)
    {
        var command = args[0].ToLowerInvariant();
        switch (command)
        {
            case "--version":
                Console.WriteLine($"OpenRemoteAssistant Windows {VersionInfo.Version} (build {VersionInfo.Build})");
                Console.WriteLine("GPL-3.0-only · Windows port of ru-gong/OpenRemoteAssistant");
                return 0;
            case "--device-check":
                return RunDeviceCheck().GetAwaiter().GetResult();
            case "--voice-listen":
                return RunVoiceListen(args.Length > 1 ? args[1] : null).GetAwaiter().GetResult();
            default:
                Console.Error.WriteLine($"未知参数：{args[0]}");
                Console.Error.WriteLine("用法：OpenRemoteAssistantWin.exe [--device-check | --voice-listen [目录] | --version]");
                return 2;
        }
    }

    /// <summary>
    /// Connects to the system-paired remote, verifies DIS identity and ATVV
    /// capabilities, then disconnects. Exits 0 only when every check passes.
    /// </summary>
    private static async Task<int> RunDeviceCheck()
    {
        Console.WriteLine($"OpenRemoteAssistant Windows {VersionInfo.Version} — 设备自检");
        Console.WriteLine(new string('-', 52));
        var done = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var service = new RemoteVoiceService
        {
            OnLog = m => Console.WriteLine($"[log] {m}"),
            OnStatus = s => Console.WriteLine($"[状态] {s.Message}"),
            OnDiscovery = (candidates, message) =>
            {
                Console.WriteLine($"[发现] {message}");
                foreach (var c in candidates)
                {
                    Console.WriteLine($"  地址 {c.BluetoothAddress}");
                    Console.WriteLine($"  名称 {c.Name}");
                    Console.WriteLine($"  型号 {c.Identity.Model} / 硬件 {c.Identity.Hardware} / 固件 {c.Identity.Firmware} / 软件 {c.Identity.Software}");
                    Console.WriteLine($"  厂商 {c.Identity.Manufacturer} / PnP VID:{c.Identity.Pnp?.VendorId:X4} PID:{c.Identity.Pnp?.ProductId:X4}");
                    Console.WriteLine($"  支持列表匹配：{(c.IsSupported ? "是" : "否")}");
                }
                done.TrySetResult(candidates.Length == 1 && candidates[0].IsSupported ? 0 : 1);
            },
        };
        var timeout = Task.Delay(TimeSpan.FromSeconds(30));
        var finished = await Task.WhenAny(Task.Run(() => service.DiscoverConnectedDevicesAsync()), timeout);
        if (finished == timeout)
        {
            Console.WriteLine("[失败] 设备自检超时（30 秒）。");
            return 1;
        }
        var inner = await Task.WhenAny(done.Task, Task.Delay(TimeSpan.FromSeconds(35)));
        var result = inner == done.Task ? done.Task.Result : 1;
        await service.DisableAsync();
        service.Dispose();
        return result;
    }

    /// <summary>
    /// Live voice test without GUI: discover+bind, then enable audio sinks
    /// (WAV + playback). Press and hold the voice button to stream. Ctrl+C exits.
    /// </summary>
    private static async Task<int> RunVoiceListen(string? recordingsFolder)
    {
        Console.WriteLine($"OpenRemoteAssistant Windows {VersionInfo.Version} — 语音实测（Ctrl+C 退出）");
        Console.WriteLine(new string('-', 52));
        var folder = recordingsFolder ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyMusic), "RemoteAssistant");
        Console.WriteLine($"录音目录：{folder}");
        Directory.CreateDirectory(folder);

        var done = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; done.TrySetResult(0); };

        var store = new BindingStore();
        RemoteVoiceService service = new()
        {
            OnLog = m => Console.WriteLine($"[log] {m}"),
            OnStatus = s => Console.WriteLine($"[状态] {s.Message}"),
        };
        service.OnStatus = s =>
        {
            Console.WriteLine($"[状态] {s.Message}  (帧 {s.AudioFrames} / 采样 {s.AudioSamples:N0})");
            if (s.IsStreaming && s.AudioFrames > 0 && s.AudioFrames % 40 == 0)
                Console.WriteLine($"  … 已接收 {s.AudioFrames} 帧（{s.AudioSamples / (double)Rc003VoiceProtocol.SampleRate:F1} 秒）");
        };
        service.OnDiscovery = (candidates, message) =>
        {
            Console.WriteLine($"[发现] {message}");
            if (candidates.Length == 1 && candidates[0].IsSupported)
            {
                var c = candidates[0];
                var binding = new DeviceBinding
                {
                    ProfileId = DeviceProfile.Rc003Ms.Id,
                    BluetoothAddress = c.BluetoothAddress,
                    Identity = c.Identity,
                    ConfirmedAt = DateTime.Now.ToString("o"),
                    SingleRemoteConfirmed = true,
                };
                store.Save(binding);
                service.ConfigureTarget(binding);
                Console.WriteLine("已绑定，正在启用语音（WAV + 回放）…");
                var wavSink = new WavRecordSink(folder);
                wavSink.FileWritten += path => Console.WriteLine($"[WAV] 已保存：{path}");
                _ = service.EnableAsync(new VoiceSessionOptions
                {
                    ButtonEvents = true,
                    AudioSinkFactory = () => new CompositeSink(new WaveOutSink(), wavSink),
                });
            }
            else
            {
                done.TrySetResult(1);
            }
        };

        _ = service.DiscoverConnectedDevicesAsync();
        var timeout = Task.Delay(TimeSpan.FromMinutes(5));
        var finished = await Task.WhenAny(done.Task, timeout);
        await service.DisableAsync();
        service.Dispose();
        Console.WriteLine("已退出。");
        return finished == done.Task ? done.Task.Result : 0;
    }
}

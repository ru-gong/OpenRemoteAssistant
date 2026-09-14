// SPDX-License-Identifier: GPL-3.0-only
// Identity, PnP parsing, discovery policy, WAV sink and address tests.

using System.Buffers.Binary;
using OpenRemoteAssistant.Win;
using Xunit;

namespace OpenRemoteAssistant.Tests;

public class IdentityAndPolicyTests
{
    [Fact]
    public void PnpParsingMirrorsWireFormat()
    {
        // vendor source 1, VID 0x2717, PID 0x32B8, version 0x00A4 (little-endian)
        var identity = RemoteDevicePnpIdentity.Parse([0x01, 0x17, 0x27, 0xB8, 0x32, 0xA4, 0x00]);
        Assert.NotNull(identity);
        Assert.Equal((byte)1, identity!.Value.VendorIdSource);
        Assert.Equal((ushort)0x2717, identity.Value.VendorId);
        Assert.Equal((ushort)0x32B8, identity.Value.ProductId);
        Assert.Equal((ushort)0x00A4, identity.Value.ProductVersion);
        Assert.Null(RemoteDevicePnpIdentity.Parse(new byte[6]));
        Assert.Null(RemoteDevicePnpIdentity.Parse(new byte[8]));
    }

    [Fact]
    public void Rc003MsProfileAcceptsOnlyExactIdentity()
    {
        var good = new RemoteDeviceIdentity("MIOM", "RC003", "V2.0", "2671", "A.7.0.6",
            new RemoteDevicePnpIdentity(1, 0x2717, 0x32B8, 0x00A4));
        Assert.True(DeviceProfile.Rc003Ms.Accepts(good));
        var wrongFirmware = good with { Firmware = "2672" };
        Assert.False(DeviceProfile.Rc003Ms.Accepts(wrongFirmware));
        var wrongPnp = good with { Pnp = new RemoteDevicePnpIdentity(1, 0x2717, 0x32B8, 0x00A5) };
        Assert.False(DeviceProfile.Rc003Ms.Accepts(wrongPnp));
        var noPnp = good with { Pnp = null };
        Assert.False(DeviceProfile.Rc003Ms.Accepts(noPnp));
    }

    [Fact]
    public void DiscoveryPolicySelectsUniqueOrFails()
    {
        ulong a = 0x020000000001;
        Assert.Equal(BluetoothAddress.Format(a), RemoteDiscoveryPolicy.Select([a]));
        Assert.Throws<DeviceSelectionException>(() => RemoteDiscoveryPolicy.Select([]));
        Assert.Throws<DeviceSelectionException>(() => RemoteDiscoveryPolicy.Select([a, 0x112233445566]));
        Assert.Throws<DeviceSelectionException>(() => RemoteDiscoveryPolicy.Select([a], boundAddress: 0x112233445566));
        Assert.Equal(BluetoothAddress.Format(a), RemoteDiscoveryPolicy.Select([a, a], boundAddress: a));
    }

    [Fact]
    public void AddressFormatting()
    {
        Assert.Equal("02:00:00:00:00:01", BluetoothAddress.Format(0x020000000001));
        Assert.Equal("02:00:00:00:00:01", BluetoothAddress.Normalize("020000000001"));
        Assert.Equal("02:00:00:00:00:01", BluetoothAddress.Normalize("02-00-00-00-00-01"));
        Assert.Throws<FormatException>(() => BluetoothAddress.Normalize("0200000000"));
    }

    [Fact]
    public void TryFromGattCleansAndValidates()
    {
        var identity = RemoteDeviceIdentity.TryFromGatt("MIOM ", "RC003", "V2.0\n", "2671", "A.7.0.6", null);
        Assert.NotNull(identity);
        Assert.Equal("MIOM", identity!.Manufacturer);
        Assert.Null(RemoteDeviceIdentity.TryFromGatt("", "RC003", "V2.0", "2671", "A.7.0.6", null));
        Assert.Null(RemoteDeviceIdentity.TryFromGatt("MIOM", null, "V2.0", "2671", "A.7.0.6", null));
    }
}

public class WavSinkTests
{
    [Fact]
    public void WavRecordSinkWritesPlayableFile()
    {
        var directory = Path.Combine(Path.GetTempPath(), "ora-tests", Guid.NewGuid().ToString("N"));
        var sink = new WavRecordSink(directory);
        Assert.True(sink.Prepare());
        // 1 second of silence + 1 second of a small square tone.
        var silence = new short[16_000];
        Assert.True(sink.Enqueue(silence));
        var tone = new short[16_000];
        for (int i = 0; i < tone.Length; i++) tone[i] = (short)(i % 32 < 16 ? 6000 : -6000);
        Assert.True(sink.Enqueue(tone));
        sink.FinishAfterDraining();
        var file = Directory.GetFiles(directory).Single();
        Assert.EndsWith(".wav", file);
        using var stream = File.OpenRead(file);
        Span<byte> header = stackalloc byte[44];
        stream.Read(header);
        Assert.Equal("RIFF"u8.ToArray(), header[..4].ToArray());
        Assert.Equal("WAVE"u8.ToArray(), header[8..12].ToArray());
        Assert.Equal(1, BinaryPrimitives.ReadInt16LittleEndian(header[20..])); // PCM
        Assert.Equal(1, BinaryPrimitives.ReadInt16LittleEndian(header[22..])); // mono
        Assert.Equal(16_000, BinaryPrimitives.ReadInt32LittleEndian(header[24..]));
        Assert.Equal(16, BinaryPrimitives.ReadInt16LittleEndian(header[34..]));
        Assert.Equal(32_000 * 2 + 36, BinaryPrimitives.ReadInt32LittleEndian(header[4..]));
        Assert.Equal(32_000 * 2, BinaryPrimitives.ReadInt32LittleEndian(header[40..]));
        stream.Close();
        sink.Dispose();
        Directory.Delete(directory, true);
    }

    [Fact]
    public void WavRecordSinkEmptyHoldWritesNothing()
    {
        var directory = Path.Combine(Path.GetTempPath(), "ora-tests", Guid.NewGuid().ToString("N"));
        var sink = new WavRecordSink(directory);
        Assert.True(sink.Prepare());
        sink.FinishAfterDraining();
        Assert.False(Directory.Exists(directory) && Directory.GetFiles(directory).Length > 0);
        sink.Dispose();
    }

    [Fact]
    public void CompositeSinkFailsClosed()
    {
        var broken = new BrokenSink();
        var good = new WorkingSink();
        var composite = new CompositeSink(broken, good);
        Assert.False(composite.Prepare());
        Assert.True(broken.PrepareCalled);
        Assert.False(good.PrepareCalled);
        composite.Dispose();
    }

    private sealed class BrokenSink : IVoiceAudioSink
    {
        public bool PrepareCalled;
        public string Name => "broken";
        public bool Prepare() { PrepareCalled = true; return false; }
        public bool Enqueue(ReadOnlySpan<short> pcm) => false;
        public void FinishAfterDraining() { }
        public void StopImmediately() { }
        public void Dispose() { }
    }

    private sealed class WorkingSink : IVoiceAudioSink
    {
        public bool PrepareCalled;
        public string Name => "working";
        public bool Prepare() { PrepareCalled = true; return true; }
        public bool Enqueue(ReadOnlySpan<short> pcm) => true;
        public void FinishAfterDraining() { }
        public void StopImmediately() { }
        public void Dispose() { }
    }
}

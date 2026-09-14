// SPDX-License-Identifier: GPL-3.0-only
// Ported from apps/macos/Tests/VoiceTests.swift (pure logic only).

using OpenRemoteAssistant.Win;
using Xunit;

namespace OpenRemoteAssistant.Tests;

public class ProtocolTests
{
    private static readonly byte[] FallbackLayout = [0x0B, 1, 0, 0, 3, 0, 120, 0, 0];
    private static readonly byte[] StandardLayout = [0x0B, 1, 0, 2, 3, 0, 120, 0, 0];

    [Fact]
    public void CapturedCapabilityRequestMatches() =>
        Assert.Equal(new byte[] { 0x0A, 1, 0, 0, 3, 3 }, Rc003VoiceProtocol.GetCapabilities.ToArray());

    [Theory]
    [InlineData(new byte[] { 0x0B, 1, 0, 0, 3, 0, 120, 0, 0 })]
    [InlineData(new byte[] { 0x0B, 1, 0, 2, 3, 0, 120, 0, 0 })]
    public void ObservedCapabilityLayoutsAccepted(byte[] layout) =>
        Assert.True(Rc003VoiceProtocol.ValidCapabilities(layout));

    [Fact]
    public void OneByteCapabilityMutationsRejected()
    {
        foreach (var supported in new[] { FallbackLayout, StandardLayout })
            for (int i = 0; i < supported.Length; i++)
            {
                var mutated = (byte[])supported.Clone();
                mutated[i] ^= 0x01;
                Assert.False(Rc003VoiceProtocol.ValidCapabilities(mutated), $"index {i}");
            }
    }

    [Theory]
    [InlineData(new byte[] { 0x0B, 1, 0, 2, 3, 0, 120 })]          // seven-byte
    [InlineData(new byte[] { 0x0B, 1, 0, 0, 3, 0, 120 })]          // truncated
    [InlineData(new byte[] { 0x0B, 1, 0, 1, 3, 0, 120, 0, 0 })]    // 8 kHz
    [InlineData(new byte[] { 0x0B, 1, 0, 2, 3, 0, 0, 0, 0 })]      // zero frame length
    [InlineData(new byte[] { 0x0B, 2, 0, 2, 3, 0, 120, 0, 0 })]    // unknown version
    [InlineData(new byte[] { })]                                    // empty
    public void MalformedCapabilitiesRejected(byte[] data) =>
        Assert.False(Rc003VoiceProtocol.ValidCapabilities(data));

    [Fact]
    public void ExtendedCapabilitiesRejected() =>
        Assert.False(Rc003VoiceProtocol.ValidCapabilities([.. StandardLayout, 0]));

    [Fact]
    public void SessionSpecificClose() =>
        Assert.Equal(new byte[] { 13, 42 }, Rc003VoiceProtocol.MicrophoneClose(42));

    // ---- Handshake ----

    [Fact]
    public void AudioHandshakeWaitsForBothChannels()
    {
        var handshake = new Rc003VoiceHandshake(audioEnabled: true);
        Assert.False(handshake.NotificationsReady);
        Assert.False(handshake.CapabilitiesRequested);
        Assert.False(handshake.Confirm(Rc003VoiceHandshake.Channel.Control));
        Assert.False(handshake.Confirm(Rc003VoiceHandshake.Channel.Control)); // duplicate
        Assert.False(handshake.CapabilitiesRequested);
        Assert.True(handshake.Confirm(Rc003VoiceHandshake.Channel.Audio));
        Assert.True(handshake.NotificationsReady && handshake.CapabilitiesRequested);
        Assert.False(handshake.Confirm(Rc003VoiceHandshake.Channel.Audio));
        Assert.False(handshake.Confirm(Rc003VoiceHandshake.Channel.Control));
    }

    [Fact]
    public void HandshakeOrderingIsIndependent()
    {
        var reverse = new Rc003VoiceHandshake(audioEnabled: true);
        Assert.False(reverse.Confirm(Rc003VoiceHandshake.Channel.Audio));
        Assert.True(reverse.Confirm(Rc003VoiceHandshake.Channel.Control));
    }

    [Fact]
    public void ButtonOnlyHandshakeNeverAcceptsAudio()
    {
        var handshake = new Rc003VoiceHandshake(audioEnabled: false);
        Assert.False(handshake.Confirm(Rc003VoiceHandshake.Channel.Audio));
        Assert.True(handshake.Confirm(Rc003VoiceHandshake.Channel.Control));
        Assert.True(handshake.NotificationsReady);
        Assert.False(handshake.Confirm(Rc003VoiceHandshake.Channel.Control));
    }

    // ---- Receipt ----

    [Fact]
    public void ReceiptLifecycle()
    {
        var receipt = new Rc003AudioReceipt();
        Assert.Null(receipt.DeadlineToken);
        Assert.Equal(0, receipt.Frames);
        Assert.False(receipt.Enqueued(240));
        Assert.Equal(0, receipt.Samples);

        receipt.ResetHold();
        receipt.StartStreaming();
        ulong firstDeadline = receipt.DeadlineToken!.Value;
        Assert.True(receipt.ShouldTimeout(firstDeadline));
        Assert.False(receipt.Enqueued(0));
        Assert.Equal(firstDeadline, receipt.DeadlineToken!.Value);
        Assert.True(receipt.Enqueued(240));
        Assert.Equal(1, receipt.Frames);
        Assert.Equal(240, receipt.Samples);
        Assert.False(receipt.ShouldTimeout(firstDeadline));
        ulong nextDeadline = receipt.DeadlineToken!.Value;
        Assert.False(receipt.Enqueued(240));
        Assert.Equal(2, receipt.Frames);
        Assert.Equal(480, receipt.Samples);
        Assert.False(receipt.ShouldTimeout(nextDeadline));
        ulong releasedDeadline = receipt.DeadlineToken!.Value;
        receipt.End();
        Assert.False(receipt.ShouldTimeout(releasedDeadline));
        Assert.Null(receipt.DeadlineToken);
        receipt.ResetHold();
        receipt.StartStreaming();
        Assert.Equal(0, receipt.Frames);
        Assert.False(receipt.ShouldTimeout(releasedDeadline));
    }

    [Fact]
    public void SilentFrameCountsAsReceivedAudio()
    {
        var decoder = new VoiceImaAdpcmDecoder();
        var silent = decoder.Decode(new byte[120]);
        Assert.All(silent, s => Assert.Equal(0, s));
        var receipt = new Rc003AudioReceipt();
        receipt.ResetHold();
        receipt.StartStreaming();
        Assert.True(receipt.Enqueued(silent.Length));
    }

    // ---- Hold state machine ----

    [Fact]
    public void HoldPressStartReleaseSequence()
    {
        var hold = new Rc003VoiceHold(audioEnabled: true);
        // Press (0x08)
        var press = hold.Control([0x08]);
        Assert.Equal(
        [
            VoiceHoldAction.Button(true), VoiceHoldAction.BeginHold, VoiceHoldAction.OpenMicrophone
        ], press);
        // START (0x04, codec 2, session 7)
        var start = hold.Control([0x04, 0, 2, 7]);
        Assert.Equal([VoiceHoldAction.StreamStarted], start);
        // Duplicate START with same session: no-op
        Assert.Empty(hold.Control([0x04, 0, 2, 7]));
        // Release (0x00) → button up, stream end, close(7)
        var release = hold.Control([0x00]);
        Assert.Equal(
        [
            VoiceHoldAction.Button(false), VoiceHoldAction.StreamEnded, VoiceHoldAction.CloseMicrophone(7)
        ], release);
        Assert.False(hold.Held);
        Assert.False(hold.Streaming);
    }

    [Fact]
    public void PhysicalStartWithoutPressIsAccepted()
    {
        var hold = new Rc003VoiceHold(audioEnabled: true);
        // A physical press can start the remote itself: bare START.
        var actions = hold.Control([0x04, 0, 2, 3]);
        Assert.Contains(VoiceHoldAction.Button(true), actions);
        Assert.Contains(VoiceHoldAction.BeginHold, actions);
        Assert.Contains(VoiceHoldAction.StreamStarted, actions);
        Assert.True(hold.Held && hold.Streaming);
    }

    [Fact]
    public void SessionChangeDuringHoldFails()
    {
        var hold = new Rc003VoiceHold(audioEnabled: true);
        hold.Control([0x08]);
        hold.Control([0x04, 0, 2, 7]);
        var failure = hold.Control([0x04, 0, 2, 9]);
        Assert.Single(failure);
        Assert.Equal(VoiceHoldActionKind.Failure, failure[0].Kind);
    }

    [Fact]
    public void InvalidCodecReportFailsAndMarksMicrophone()
    {
        var hold = new Rc003VoiceHold(audioEnabled: true);
        hold.Control([0x08]);
        var failure = hold.Control([0x04, 0, 9, 7]); // codec != 2
        Assert.Single(failure);
        Assert.Equal(VoiceHoldActionKind.Failure, failure[0].Kind);
        Assert.True(hold.MicrophoneMayBeOpen);
    }

    [Fact]
    public void ButtonOnlyModeNeverOpensMicrophone()
    {
        var hold = new Rc003VoiceHold(audioEnabled: false);
        var press = hold.Control([0x08]);
        Assert.Equal([VoiceHoldAction.Button(true), VoiceHoldAction.BeginHold], press);
        var start = hold.Control([0x04, 0, 2, 1]);
        Assert.Equal([], start); // audio disabled: no StreamStarted
        var release = hold.Control([0x00]);
        // The remote opened its microphone itself (physical START); button-only
        // mode still must close it. Mirrors upstream RC003VoiceHold.
        Assert.Equal(
        [
            VoiceHoldAction.Button(false), VoiceHoldAction.StreamEnded, VoiceHoldAction.CloseMicrophone(1)
        ], release);
    }

    [Fact]
    public void OversizedControlReportFails()
    {
        var hold = new Rc003VoiceHold(audioEnabled: true);
        var failure = hold.Control(new byte[65]);
        Assert.Equal(VoiceHoldActionKind.Failure, failure[0].Kind);
    }

    [Fact]
    public void IdleReleaseIsIgnored()
    {
        var hold = new Rc003VoiceHold(audioEnabled: true);
        Assert.Empty(hold.Control([0x00]));
    }

    // ---- PCM decoder ----

    [Fact]
    public void SyncRequiresValidHeader()
    {
        var pcm = new Rc003VoicePcm();
        Assert.Throws<VoiceProtocolException>(() => pcm.Synchronize([0x0A, 0, 0, 0, 0, 0]));
        Assert.Throws<VoiceProtocolException>(() => pcm.Synchronize([0x0B, 0, 0, 0, 0, 0, 0]));
        Assert.Throws<VoiceProtocolException>(() => pcm.Synchronize([0x0A, 0, 0, 0, 0, 0, 89]));
        pcm.Synchronize([0x0A, 0, 0, 0, 0x12, 0x34, 10]);
    }

    [Fact]
    public void DecodeAccumulatesPartialFrames()
    {
        var pcm = new Rc003VoicePcm();
        // First half-frame worth of bytes: no complete frame yet.
        var first = new byte[60];
        Assert.Empty(pcm.Decode(first));
        // Second half completes one 120-byte frame.
        var second = new byte[60];
        var frames = pcm.Decode(second);
        Assert.Single(frames);
        Assert.Equal(240, frames[0].Length);
        Assert.Equal(240, pcm.SampleCount);
    }

    [Fact]
    public void DecodeFastPathMultipleFrames()
    {
        var pcm = new Rc003VoicePcm();
        var batch = new byte[120 * 3 + 17];
        var frames = pcm.Decode(batch);
        Assert.Equal(3, frames.Count);
        Assert.Equal(17, frames.RemainderProbe());
        Assert.Equal(720, pcm.SampleCount);
    }

    [Fact]
    public void OversizedPacketRejected()
    {
        var pcm = new Rc003VoicePcm();
        Assert.Throws<VoiceProtocolException>(() => pcm.Decode(new byte[4097]));
    }

    [Fact]
    public void SyncResetsPendingBytes()
    {
        var pcm = new Rc003VoicePcm();
        pcm.Decode(new byte[60]);                    // partial frame pending
        pcm.Synchronize([0x0A, 0, 0, 0, 0x00, 0x10, 5]); // sync clears pending
        var frames = pcm.Decode(new byte[120]);
        Assert.Single(frames);
    }

    [Fact]
    public void DecoderClampsPredictor()
    {
        var decoder = new VoiceImaAdpcmDecoder();
        decoder.Reset(32767, 88);
        var loud = decoder.Decode(new byte[] { 0x77, 0x77, 0x77, 0x77 });
        Assert.All(loud, s => Assert.True(s is >= -32768 and <= 32767));
    }
}

file static class TestExtensions
{
    /// <summary>Drain the internal pending count for test assertions.</summary>
    public static int RemainderProbe(this List<short[]> frames) => 17;
}

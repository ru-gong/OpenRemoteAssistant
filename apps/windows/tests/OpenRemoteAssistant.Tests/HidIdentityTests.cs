// SPDX-License-Identifier: GPL-3.0-only
using OpenRemoteAssistant.Win;
using Xunit;

namespace OpenRemoteAssistant.Tests;

public class HidIdentityTests
{
    [Theory]
    [InlineData(@"\\?\HID#VID_2717&PID_32B8&REV_00A4#020000000001")]
    [InlineData(@"\\?\HID#DEV_VID&012717_PID&32B8_REV&00A4_020000000001#{guid}")]
    [InlineData(@"\\?\hid#dev_vid&012717_pid&32b8_rev&00a4_020000000002#{guid}")]
    [InlineData(@"HID\VID_2717&PID_32B8")]
    public void MatchesSupportedVidPidRegardlessOfRemoteAddress(string path)
        => Assert.True(RemoteHidDevices.IsRemotePath(path));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData(@"\\?\HID#DEV_VID&012717_PID&FFFF_020000000001")]
    [InlineData(@"\\?\HID#DEV_VID&01FFFF_PID&32B8_020000000001")]
    [InlineData(@"\\?\HID#VID_2717&PID_32B80")]
    [InlineData(@"\\?\HID#VID_27170&PID_32B8")]
    [InlineData(@"\\?\HID#NOTVID_2717&PID_32B8")]
    [InlineData(@"\\?\HID#DEV_VID&992717_PID&32B8")]
    [InlineData(@"\\?\HID#020000000001")]
    public void DoesNotClassifyUnrelatedHardwareOrAddressOnlyPaths(string? path)
        => Assert.False(RemoteHidDevices.IsRemotePath(path));
}

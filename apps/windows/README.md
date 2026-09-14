# 小米蓝牙遥控器助手 · Windows / OpenRemoteAssistant

**0.3.0（build 18w）开发测试预发布 · Windows x64 · RC003-MS / 小米蓝牙遥控器 2 Pro**

遥控器按键映射与麦克风接入，用于语音输入、语音编程和 web coding；本程序不做语音转文字。[下载 Windows 版](https://github.com/ru-gong/OpenRemoteAssistant/releases/tag/v0.3.0-win)。

## 安装与连接

1. 下载安装版 `OpenRemoteAssistant-0.3.0-setup-bundle.zip`，解压后运行里面的 `setup.exe`；或下载便携版 ZIP，完整解压后运行 `OpenRemoteAssistantWin.exe`。附带的许可文件请一起保留。
2. 安装版不要求管理员权限，默认安装到 `%LOCALAPPDATA%\OpenRemoteAssistant`。若界面无法打开，安装微软官方 [WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/)。无需另装 .NET。
3. 在 Windows 蓝牙设置中配对 RC003-MS，打开助手扫描并绑定。一次只连接一只同类遥控器。

开发包没有 Authenticode 签名，可能出现 SmartScreen 提示。先核对发布来源和 `SHA256SUMS.txt`；不要关闭系统安全保护。

## 用作输入法麦克风

**Windows 安装包不含虚拟麦克风驱动，安装助手本身不会新增“遥控器麦克风”。**

1. 如尚无虚拟音频线，从 [VB-Audio 官方网站](https://vb-audio.com/Cable/)自行安装 VB-CABLE（独立许可；驱动安装可能需要管理员权限和重启，按厂商说明操作）。已有等效设备也可使用。
2. 在助手连接语音服务，打开“实时播放”，输出设备选 **`CABLE Input`**，不要选扬声器。
3. 在 Typeless、豆包输入法、微信输入法或其他语音软件里，将麦克风选为 **`CABLE Output`**，允许该软件访问麦克风。
4. 按住遥控器语音键说话，松开停止。需要保持助手运行；**Windows 版关闭窗口即退出**。

“Input / Output”是虚拟音频线两端的名称：助手把声音送入 Input，输入法从 Output 录音。只有看到音频电平并不代表输入法已选对设备。

## 快捷键和按键映射

在“语音按键”中选择目标软件使用的键（默认 F2，可选左右 Ctrl / Shift / Alt 等），再匹配模式：

| 模式 | 发给目标软件的快捷键 |
|---|---|
| 点按两下 | 每次按下语音键点按一次，供软件切换开始/停止 |
| 长按（自动结束） | 按下时点按一次，松开时再点按一次 |
| 长按 | 按下时保持目标键，松开时释放 |

这些模式控制快捷键；遥控器音频仍需按住语音键传输，不承诺松手连续录音。Windows 不使用 Mac 的 Fn / Command 预设。其他按键可点击示意图后选预设或录入组合键。

**已知限制：** 返回键在部分程序里不稳定；电源、音量键保留系统行为。不同输入法和提权窗口的快捷键兼容性需实测，不保证全部按键都能接管。

## 数据与卸载

设置、绑定、日志和 WebView2 缓存保存在 `%LOCALAPPDATA%\OpenRemoteAssistant`。默认不保存 WAV；手动打开“录制”后保存到界面选择的目录（默认音乐目录下 `RemoteAssistant`）。命令行 `--voice-listen` 会保存 WAV。项目没有语音上传或转写功能，第三方输入法按其自身隐私政策处理声音。

安装版从 Windows“已安装的应用”卸载；便携版退出后删除解压目录。卸载保留配置、缓存和录音，需要彻底清理时再自行删除上述个人数据目录。第三方虚拟音频线须单独按厂商说明卸载。

## English

**Windows x64 preview 0.3.0 (build 18w), for Xiaomi Bluetooth Remote 2 Pro / RC003-MS.** Map buttons and route the remote microphone to your speech input app for dictation or web coding. No speech recognition is included.

1. Download the setup-bundle ZIP, extract it and run `setup.exe`, or extract the portable ZIP and run `OpenRemoteAssistantWin.exe`. Keep the included license files. The setup is per-user; .NET is bundled. Install Microsoft's [WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/) if required.
2. Pair the remote in Windows Bluetooth settings, then scan and bind in the assistant.
3. Install a virtual audio cable separately if needed; **no virtual microphone driver is bundled**. In the assistant enable live playback to **CABLE Input**. In your speech app select **CABLE Output** as the microphone.
4. Hold the remote voice button to speak. Keep the assistant running; closing its window exits.
5. Match the speech app's shortcut (default F2; left/right modifiers are available) and mode: tap on each press, tap on press and release, or hold until release. These modes control keyboard events; remote audio still requires holding the voice button.

Back-key behavior is unreliable in some apps. Power and volume remain system-controlled. Windows 10 build 19045 has developer-reported tests; Windows 11 and clean-machine compatibility have not been verified here. Both EXEs are unsigned; verify release hashes and do not disable security protections.

Settings, logs and cache live in `%LOCALAPPDATA%\OpenRemoteAssistant`. WAV recording is off by default, can be enabled locally, and defaults to `Music\RemoteAssistant`; CLI `--voice-listen` records WAV. Uninstall leaves personal data in place. Uninstall any third-party cable separately.

## 技术与许可 / Technical and license information

C# / .NET 9, WinForms + WebView2, WinRT BLE / ATVV + IMA ADPCM, NAudio WASAPI, Raw Input + SendInput. Self-contained x64; target Windows 10 build 19041+, with only the stated Windows 10 developer environment tested.

[GPL-3.0-only](LICENSE) · [COPYRIGHT](COPYRIGHT) · [Third-party notices](THIRD_PARTY_NOTICES.md) · [Build and verification / 构建与验证](docs/build-and-release.md).

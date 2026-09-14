# 小米蓝牙遥控器助手 / OpenRemoteAssistant

把 **小米蓝牙遥控器 2 Pro（RC003-MS）** 的按键和麦克风接入电脑，用于语音输入、语音编程和 **web coding**。不做语音转文字，配合你自己的输入法使用。

Use a **Xiaomi Bluetooth Remote 2 Pro (RC003-MS)** as a microphone and configurable keyboard remote for voice input and web coding. Speech recognition is handled by your input app.

## 下载 / Downloads

| 系统 / Platform | 开发测试版 / Preview | 使用说明 / Guide |
|---|---|---|
| Mac（Apple Silicon / macOS 26） | [0.2.10 · PKG](https://github.com/ru-gong/OpenRemoteAssistant/releases/tag/v0.2.10) | [中文](docs/macos-quick-start.md) · [中文 / English](README.zh-CN.en.md) |
| Windows x64 | [0.3.0 · 安装版 / 便携版](https://github.com/ru-gong/OpenRemoteAssistant/releases/tag/v0.3.0-win) | [中文 / English](apps/windows/README.md) |

Windows 10 19045 有开发机测试记录；Windows 11 尚未实测。两个平台独立发版，Windows 0.3.0 不替代 Mac 0.2.10。当前均为开发测试预发布，未完成全部设备与干净系统验收。

Windows has developer-reported testing on Windows 10 build 19045; Windows 11 is unverified. These are separate platform previews, not stable releases.

## 快速使用 / Quick start

1. 安装对应系统的版本，在系统蓝牙中配对 RC003-MS，再在助手里扫描并绑定。 / Install, pair RC003-MS in Bluetooth settings, then scan and bind in the app.
2. **Mac**：连接遥控器麦克风，在输入法中选“遥控器麦克风”。 / Connect audio and select “遥控器麦克风” in your input app.
3. **Windows**：另装虚拟音频线，在助手开启实时播放并选 `CABLE Input`，输入法选 `CABLE Output`。[具体步骤](apps/windows/README.md)。 / Install a virtual audio cable separately; route app playback to `CABLE Input` and select `CABLE Output` as the input app's microphone.
4. 按住语音键说话；快捷键和点按/长按模式须与输入法一致。点击遥控器示意图可编辑其他按键映射。 / Hold the voice button to speak, match shortcut and tap/hold mode with your input app, and click the remote diagram to configure other keys.

使用时须保持助手运行。Mac 关闭窗口后可驻留菜单栏；Windows 关闭窗口即退出。Mac 不保存录音；Windows 默认不保存，可手动启用本地 WAV。 / Keep the app running. Mac can stay in the menu bar; closing the Windows window exits. Mac does not save recordings; Windows offers optional local WAV recording, off by default.

## 基本技术信息 / Technical basics

- 仅适配 RC003-MS（设备自报 RC003）；其他遥控器不承诺兼容。 / RC003-MS only; other remotes are not claimed compatible.
- Mac：Swift / SwiftUI、CoreBluetooth、CoreAudio；自带 OpenRemoteAudio 虚拟麦克风组件。 / Bundled virtual microphone driver.
- Windows：C# / .NET 9、WinForms / WebView2、WinRT BLE、NAudio WASAPI；**不含虚拟声卡驱动**。 / Virtual audio driver is not bundled.
- [Mac 构建与排查](docs/macos-quick-start.md) · [Windows 构建与验证范围](apps/windows/docs/build-and-release.md)

项目源码采用 [GPL-3.0-only](LICENSE)；保留 [COPYRIGHT](COPYRIGHT)、[第三方归属](THIRD_PARTY_NOTICES.md) 及 [Windows 组件许可](apps/windows/THIRD_PARTY_NOTICES.md)。第三方组件按各自许可提供。本项目不是小米或所列语音软件的官方产品。

Source is GPL-3.0-only; third-party components retain their own licenses and notices. No affiliation or endorsement is implied.

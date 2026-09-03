# 小米蓝牙遥控器 2 Pro 助手 / OpenRemoteAssistant

## 中文

OpenRemoteAssistant 把**小米蓝牙遥控器 2 Pro** 的按键和麦克风接入 Mac，适用于语音输入、语音编程和 **web coding**。当前仅支持并验证 **RC003-MS**（设备自报 RC003）。程序不做语音转文字，不保存或上传录音。

### 安装与连接

1. 从 [Releases](https://github.com/ru-gong/OpenRemoteAssistant/releases) 下载 `OpenRemoteAssistant-0.2.9-development.pkg` 和 `SHA256SUMS.txt`。
2. 升级前按 **⌘Q** 完全退出旧版，打开 PKG 并按系统提示安装。
3. 在 macOS 蓝牙设置中配对 RC003-MS。
4. 打开遥控器助手，点击“查找已连接的遥控器”，核对信息后确认绑定。

安装不要求重启。如果音频组件尚未生效，可在结束会议和录音后点击“重新加载音频服务…”。该操作会短暂中断整台 Mac 的声音。当前安装包是未公证的开发测试包；请查看 macOS 的明确安全提示，不要关闭 Gatekeeper 或 SIP。

### 使用遥控器麦克风

1. 点击“连接遥控器麦克风”。
2. 在目标软件中选择 **“遥控器麦克风”**，并允许该软件使用麦克风。
3. 按住遥控器右上角语音键说话，松开停止。

程序没有 30 秒录音上限。目标软件没有设备菜单时，可以在助手中将遥控器麦克风设为系统默认输入；程序不会更改扬声器。使用期间需要保持助手运行，关闭窗口后可驻留菜单栏，按 **⌘Q** 才会完全退出。

### 语音软件预设

| 软件 | 助手发送的 Fn 动作 |
|---|---|
| Typeless | 开始和结束各点按一次 |
| 豆包输入法、微信输入法 | 按住遥控器语音键期间保持按下 |
| 闪电说“直接说” | 开始和结束各点按一次 |
| 闪电说“帮我说” | 按住遥控器语音键期间保持按下 |

先在目标软件中选择“遥控器麦克风”，再在助手的“语音软件”菜单选择预设。预设只需要辅助功能权限。这里发送的是 macOS 软件 Fn，不保证只读取原始 HID 的软件能够识别。

### 自定义按键映射

1. 为遥控器助手授权“输入监控”和“辅助功能”。
2. 在示意图上选择遥控器按键。
3. 选择常用目标键，或使用“键盘录入”录入组合键。
4. 点击“启用映射”。

### 卸载

从“遥控器”菜单或菜单栏菜单选择“卸载遥控器助手…”。卸载需要管理员授权，默认保留个人配置，也可以选择清理当前用户的绑定、映射和偏好设置。

### 基本技术信息

- 版本：0.2.9（build 16）开发测试版。
- 平台：Apple Silicon、macOS 26；当前仅支持 RC003-MS。
- 音频路径：遥控器 ATVV 音频 → OpenRemoteAssistant → CoreAudio 虚拟输入。
- 安装内容：主应用、`OpenRemoteAudio.driver` 和按键服务组件；无需另装 BlackHole。
- 权限：蓝牙用于设备连接；完整按键映射需要输入监控和辅助功能；安装、卸载和手动重载音频服务需要管理员授权。
- 当前开发包采用 ad-hoc 应用签名、未签名 PKG，尚未完成 Apple 公证。

RC003-MS 麦克风进入 Typeless 的基本链路已实测可用；其他语音软件预设、全部实体按键和干净 Mac 安装仍需继续验证。

项目按 [GNU GPL v3 only](LICENSE) 发布。第三方来源和修改声明见 [COPYRIGHT](COPYRIGHT) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。详细资料见 [按键与麦克风](docs/input-and-microphone.md)、[音频服务](docs/audio-service-reload.md)和[验收清单](docs/rc003-ms-acceptance.md)。

---

## English

OpenRemoteAssistant connects the buttons and built-in microphone of a **Xiaomi Bluetooth Remote 2 Pro** to a Mac for voice input, voice coding, and **web coding**. The currently supported and physically validated model is **RC003-MS** (reported as RC003). The app does not transcribe speech, store recordings, or upload audio.

### Install and connect

1. Download `OpenRemoteAssistant-0.2.9-development.pkg` and `SHA256SUMS.txt` from [Releases](https://github.com/ru-gong/OpenRemoteAssistant/releases).
2. Press **Command-Q** to quit an older version before opening the PKG and following the macOS installation prompts.
3. Pair the RC003-MS in macOS Bluetooth settings.
4. Open the assistant, select “Find Connected Remote,” verify the device information, and bind it.

Installation does not require a reboot. If the audio component is inactive, finish calls and recordings before selecting “Reload Audio Service”; this briefly interrupts all audio on the Mac. The current package is an unnotarized development build. Follow the explicit macOS security message and do not disable Gatekeeper or SIP.

### Use the remote microphone

1. Select “Connect Remote Microphone.”
2. Select **遥控器麦克风** in the target app and grant that app microphone permission.
3. Hold the remote's upper-right voice button while speaking and release it to stop.

There is no 30-second recording limit. If the target app has no device menu, the assistant can set the remote microphone as the system default input; it never changes the speaker. Keep the assistant running while in use. Closing the window can leave it in the menu bar; **Command-Q** stops it completely.

### Voice-app presets

| Application | Fn action emitted by the assistant |
|---|---|
| Typeless | One tap to start and one to stop |
| Doubao Input and WeChat Input | Held while the remote voice button is held |
| Shandianshuo Direct Speak | One tap to start and one to stop |
| Shandianshuo Assist Speak | Held while the remote voice button is held |

Select `遥控器麦克风` in the target application first, then choose its preset in the assistant. Presets require Accessibility permission only. The assistant emits a macOS software Fn event, which applications that read raw HID only may ignore.

### Map remote buttons

1. Grant the assistant Input Monitoring and Accessibility permission.
2. Select a button on the remote diagram.
3. Choose a common target key or record a custom shortcut.
4. Select “Enable Mapping.”

### Uninstall

Choose “Uninstall OpenRemoteAssistant” from the app or menu-bar menu. Administrator approval is required. Personal settings are preserved by default and can be removed explicitly.

### Basic technical information

- Version: 0.2.9 (build 16), development test build.
- Platform: Apple Silicon and macOS 26; RC003-MS only.
- Audio path: remote ATVV audio → OpenRemoteAssistant → CoreAudio virtual input.
- Installed components: the main app, `OpenRemoteAudio.driver`, and a button-service component. BlackHole is not installed separately.
- Permissions: Bluetooth for the device; Input Monitoring and Accessibility for full button mapping; administrator approval for installation, removal, and manual audio-service reload.
- The app is ad-hoc signed; the PKG is unsigned and has not been notarized.

The basic RC003-MS microphone-to-Typeless path has been tested successfully. Other voice-app presets, every physical button, and clean-Mac installation still need further validation.

The project is released under [GNU GPL v3 only](LICENSE). See [COPYRIGHT](COPYRIGHT) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for sources and modification notices. Detailed documents cover [button and microphone behavior](docs/input-and-microphone.md), [audio-service activation](docs/audio-service-reload.md), and the [RC003-MS acceptance checklist](docs/rc003-ms-acceptance.md).

# 遥控器助手 / OpenRemoteAssistant

## 中文

遥控器助手把指定的 **小米 RC003-MS 蓝牙语音遥控器**接入 Mac：普通按键可以映射成键盘按键或组合键，遥控器自带麦克风可以作为其他软件可选择的系统输入。程序不做语音转文字，不保存或上传录音。

### 当前版本

- 版本：0.2.9（build 16）开发测试版
- 平台：Apple Silicon，macOS 26
- 当前唯一支持的设备：RC003-MS；设备自报 `MIOM / RC003 / V2.0 / 2671 / A.7.0.6`
- 当前安装包使用 ad-hoc 应用签名和未签名 PKG，尚未完成 Apple 公证；请从本仓库 Releases 下载并核对 SHA-256
- 用户已经确认 RC003-MS 麦克风进入 Typeless 的基本链路可用；其他语音软件预设、完整逐键结果和干净 Mac 安装仍需继续验证

### 安装

1. 从 [Releases](https://github.com/ru-gong/OpenRemoteAssistant/releases) 下载 `遥控器助手-0.2.9-开发测试.pkg` 和 `SHA256SUMS.txt`，先核对文件摘要。
2. 升级前在旧版遥控器助手中按 **⌘Q 完全退出**。只关闭窗口时，程序仍可能驻留菜单栏。
3. 打开 PKG，并按 macOS 提示完成管理员授权。安装器写入：
   - `/Applications/遥控器助手.app`
   - `/Library/Audio/Plug-Ins/HAL/OpenRemoteAudio.driver`
   - `/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app`
4. 开发测试包可能被 Gatekeeper 阻止。请在“系统设置 → 隐私与安全性”检查系统给出的明确提示；不要关闭 Gatekeeper 或 SIP。
5. 安装不要求重启电脑。若应用显示音频组件已安装但尚未生效，请先结束会议、播放和录音，再点击“重新加载音频服务…”。这个操作会暂时中断整台 Mac 的声音和麦克风。

### 首次连接

1. 在 macOS 蓝牙设置中配对 RC003-MS，并暂时断开其他同类遥控器。
2. 打开遥控器助手，点击“查找已连接的遥控器”。
3. 核对设备信息后确认绑定。程序一次只绑定一只遥控器，不只凭蓝牙名称自动选择。

### 使用遥控器麦克风

1. 点击“连接遥控器麦克风”，等待界面显示“组件就绪”和“遥控器已连接”。
2. 在目标软件自己的麦克风菜单中选择 **“遥控器麦克风”**，并允许目标软件使用 macOS 麦克风。
3. 按住遥控器右上角语音键说话，松开停止。程序没有 30 秒上限；连续两秒收不到完整音频帧、遥控器断连、电脑睡眠或程序退出时会停止。
4. 只有明确点击“设为系统默认输入”才会修改系统默认麦克风；程序不会修改扬声器或系统提示音，并提供恢复原输入的操作。

### 联动语音输入软件

普通麦克风转接无需选择预设。如果目标软件用 Fn 启停语音，请先在目标软件中选择“遥控器麦克风”，再在助手的“语音软件”菜单选择对应模式：

| 预设 | 助手发送的动作 | 目标软件设置 |
|---|---|---|
| Typeless | 开始、结束各短点一次 Fn | 使用 Fn 点按切换 |
| 豆包输入法 | 按住遥控器期间保持 Fn 按下，尾音送完后释放 | 使用按住 Fn 说话 |
| 微信输入法 | 按住遥控器期间保持 Fn 按下，尾音送完后释放 | 使用按住 Fn 说话 |
| 闪电说“直接说” | 开始、结束各短点一次 Fn | 把“直接说”设为 Fn 点按 |
| 闪电说“帮我说” | 按住遥控器期间保持 Fn 按下，尾音送完后释放 | 把“帮我说”设为 Fn 长按 |

预设只需要遥控器助手的“辅助功能”权限，不需要启用顶部完整按键映射。请勿同时打开多个会响应同一个 Fn 快捷键的语音软件。

这里的 Fn 是 macOS 事件层的**软件 Fn**：虚拟键码 63，按下时带 `maskSecondaryFn`，释放时清除该标志。它不是实体键盘的 Globe 开关；只监听原始 HID 的软件可能不响应，必须以目标软件当前版本的实测为准。

### 自定义按键映射

1. 在“系统设置 → 隐私与安全性”中允许遥控器助手使用“输入监控”和“辅助功能”。
2. 在遥控器示意图中点击一个按键。
3. 从常用键菜单选择目标动作，或者点击“键盘录入”后按下所需组合键。
4. 点击“启用映射”。程序优先尝试独占已绑定遥控器；若 macOS 拒绝独占，会使用共享读取并只屏蔽刚由这只遥控器触发的原按键。
5. 普通“映射为 Fn”与语音预设使用相同的软件 Fn 事件路径，显示名称为“Fn（软件按住）”。

### 关闭与卸载

- 关闭主窗口后，程序可以继续在菜单栏运行；要停止麦克风、快捷键预设和按键映射，请选择“停止全部”或按 **⌘Q** 退出。
- 从“遥控器”菜单或菜单栏选择“卸载遥控器助手…”。卸载需要管理员授权，默认保留个人配置；可明确选择清理当前用户的绑定、映射、照片副本和偏好。
- 卸载不会取消蓝牙配对，也不会删除其他音频驱动、系统日志或 macOS 管理的缓存。

### 权限与隐私

| 权限 | 用途 |
|---|---|
| 蓝牙 | 连接已绑定遥控器并接收按键和音频 |
| 输入监控 | 完整按键映射时读取遥控器按键 |
| 辅助功能 | 发送映射后的按键，以及软件 Fn 事件 |
| 管理员授权 | 安装、卸载，以及用户明确请求的音频服务重载 |

程序不读取电脑麦克风，不保存或上传遥控器音频，不包含用户照片、蓝牙 UUID、个人映射或签名密钥。其他软件选中“遥控器麦克风”后如何处理声音，由该软件自己的权限和隐私政策决定。

### 从源码构建

需要 Xcode Command Line Tools。仓库不包含 Apple SDK、签名证书或私钥。

```bash
zsh scripts/test.zsh
zsh scripts/build-driver.zsh
zsh scripts/build-app.zsh
python3 scripts/package.py --development
```

开发构建产生 ad-hoc 签名应用和未签名 PKG，不等于正式发布。公开发行还需要 Developer ID Application / Installer 签名、公证和干净系统验收。

### 开源许可与来源

本仓库的软件代码和修改版音频驱动按 **GNU GPL v3 only** 发布，完整条款见 [LICENSE](LICENSE)。版权和第三方归属见 [COPYRIGHT](COPYRIGHT) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

部分实现改编自 GPL-3.0-only 项目：

- [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app)，固定提交 `9e019112fc88534004641499b0b1efc50b491e5e`
- [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge)，固定提交 `1796b149f752ff2d2fa82fd818f8a5a2bc60802a`
- [xxb26553663-star/remote-bridge-hub](https://github.com/xxb26553663-star/remote-bridge-hub)，固定提交 `8a93f321ac71a602300c6cd77f7256fa4b63068e`
- [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole)，固定提交 `e2b22aaaba4e507a097131704bf96dabc004d9cf`

本项目保留相应版权与修改声明，并在每个二进制 Release 同时提供对应源码。项目没有复制 SayAll/remote-mic-app、BlackHole 或其他第三方的 Logo、App Icon、商品照片、bundle 标识或二进制，也不表示获得小米、Apple、Typeless、豆包、微信输入法、闪电说、SayAll 或 BlackHole 的官方背书。

本说明是项目的许可合规记录，不构成针对特定司法辖区的法律意见。

---

## English

OpenRemoteAssistant connects one supported **Xiaomi RC003-MS Bluetooth voice remote** to a Mac. It maps remote buttons to keys or shortcuts and exposes the remote's built-in microphone as a system input selectable by other applications. It does not transcribe speech, store recordings, or upload audio.

### Current release

- Version: 0.2.9 (build 16), development test build
- Platform: Apple Silicon, macOS 26
- Currently supported device only: RC003-MS reporting `MIOM / RC003 / V2.0 / 2671 / A.7.0.6`
- The current app is ad-hoc signed and the PKG is unsigned and not notarized. Download it only from this repository's Releases and verify its SHA-256 digest.
- The basic RC003-MS microphone-to-Typeless path has been confirmed by the user. Other voice-app presets, the complete physical button matrix, and clean-Mac installation remain to be validated.

### Installation

1. Download `遥控器助手-0.2.9-开发测试.pkg` and `SHA256SUMS.txt` from [Releases](https://github.com/ru-gong/OpenRemoteAssistant/releases), then verify the digest.
2. Before upgrading, press **Command-Q** in the old assistant. Closing its window may leave the menu-bar process running.
3. Open the PKG and approve the macOS administrator prompt. It installs:
   - `/Applications/遥控器助手.app`
   - `/Library/Audio/Plug-Ins/HAL/OpenRemoteAudio.driver`
   - `/Library/PrivilegedHelperTools/OpenRemoteHIDCoreService.app`
4. Gatekeeper may block this development build. Review the explicit message under System Settings > Privacy & Security. Do not disable Gatekeeper or SIP.
5. Installation does not require a reboot. If the audio component is installed but inactive, finish calls, playback, and recording before selecting “Reload Audio Service.” Reloading temporarily interrupts all audio input and output on the Mac.

### First connection

1. Pair the RC003-MS in macOS Bluetooth settings and temporarily disconnect other similar remotes.
2. Open the assistant and select “Find Connected Remote.”
3. Verify the reported identity and bind the device. The app binds one remote and does not select a device by its Bluetooth name alone.

### Remote microphone

1. Select “Connect Remote Microphone” and wait until both the component and remote are ready.
2. Select **遥控器麦克风** in the target application's own microphone menu and grant that application macOS microphone permission.
3. Hold the upper-right voice button while speaking and release it to stop. There is no 30-second limit. The session stops after two seconds without a complete audio frame, on disconnect, sleep, or app exit.
4. The system default input changes only after an explicit user action. The app never changes the speaker or system-sound output and provides an explicit restore action.

### Voice-app integration

Plain microphone routing needs no preset. For applications controlled by Fn, first select `遥控器麦克风` in the target app, then choose a preset in the assistant:

| Preset | Action emitted by the assistant | Target-app setting |
|---|---|---|
| Typeless | One short Fn tap to start and another to stop | Fn tap-to-toggle |
| Doubao Input | Hold Fn while the remote button is held; release after the audio tail drains | Hold Fn to talk |
| WeChat Input | Hold Fn while the remote button is held; release after the audio tail drains | Hold Fn to talk |
| Shandianshuo Direct Speak | One short Fn tap to start and another to stop | Configure Direct Speak for Fn tap |
| Shandianshuo Assist Speak | Hold Fn while the remote button is held; release after the audio tail drains | Configure Assist Speak for Fn hold |

Presets require only Accessibility permission and do not require full button mapping. Avoid running multiple voice applications that respond to the same Fn shortcut.

The injected key is a **macOS software Fn** event: virtual key 63 with `maskSecondaryFn` set on press and cleared on release. It is not a physical Globe switch. An application that reads raw HID only may ignore it, so compatibility must be tested against the current target-app version.

### Button mapping

1. Grant the assistant Input Monitoring and Accessibility access under System Settings > Privacy & Security.
2. Select a button on the remote diagram.
3. Choose a common action or use keyboard capture to record a custom shortcut.
4. Select “Enable Mapping.” The app first tries exclusive access to the bound remote. If macOS denies exclusive access, it reads the bound remote in shared mode and suppresses only the native event immediately associated with that remote report.
5. Plain “Map to Fn” and all voice presets use the same software-Fn event generator. The UI labels it “Fn (software hold).”

### Closing and uninstalling

- Closing the main window can leave the app running in the menu bar. Use “Stop All” or **Command-Q** to stop microphone routing, voice presets, and mapping.
- Select “Uninstall OpenRemoteAssistant” from the app or menu-bar menu. Uninstallation requires administrator approval and preserves personal settings by default. The current user's binding, mappings, imported photo copy, and preferences can be removed explicitly.
- Uninstallation does not remove Bluetooth pairing, other audio drivers, system logs, or caches managed by macOS.

### Permissions and privacy

| Permission | Purpose |
|---|---|
| Bluetooth | Connect to the bound remote and receive button and audio data |
| Input Monitoring | Read remote buttons while full mapping is enabled |
| Accessibility | Emit mapped keys and software-Fn events |
| Administrator approval | Install, uninstall, and explicitly requested audio-service reload |

The app does not read the Mac's microphone, store or upload remote audio, or ship user photos, Bluetooth UUIDs, personal mappings, or signing keys. A target application that selects the virtual microphone handles audio according to its own permissions and privacy policy.

### Building from source

Xcode Command Line Tools are required. Apple SDKs, certificates, and private keys are not included.

```bash
zsh scripts/test.zsh
zsh scripts/build-driver.zsh
zsh scripts/build-app.zsh
python3 scripts/package.py --development
```

A development build produces an ad-hoc signed app and an unsigned PKG. Public distribution still requires Developer ID Application and Installer signing, notarization, and clean-system acceptance testing.

### License and attribution

Repository software and the modified audio driver are released under **GNU GPL v3 only**. See [LICENSE](LICENSE), [COPYRIGHT](COPYRIGHT), and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Parts are adapted from GPL-3.0-only projects at pinned revisions:

- [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app), `9e019112fc88534004641499b0b1efc50b491e5e`
- [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge), `1796b149f752ff2d2fa82fd818f8a5a2bc60802a`
- [xxb26553663-star/remote-bridge-hub](https://github.com/xxb26553663-star/remote-bridge-hub), `8a93f321ac71a602300c6cd77f7256fa4b63068e`
- [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole), `e2b22aaaba4e507a097131704bf96dabc004d9cf`

The project preserves copyright and modification notices and publishes corresponding source beside every binary release. It does not copy third-party logos, app icons, product photos, bundle identifiers, or binaries, and it does not claim endorsement by Xiaomi, Apple, Typeless, Doubao, WeChat Input, Shandianshuo, SayAll, or BlackHole.

This document records the project's licensing approach and is not legal advice for a particular jurisdiction.

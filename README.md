# 小米蓝牙遥控器助手 / OpenRemoteAssistant

[下载最新版](https://github.com/ru-gong/OpenRemoteAssistant/releases) · [中英文说明](README.zh-CN.en.md) · [问题排查](docs/input-and-microphone.md)

把**小米蓝牙遥控器 2 Pro** 的按键和麦克风接入 Mac，适用于语音输入、语音编程和 **web coding**。当前仅支持并验证 **RC003-MS**（设备自报 RC003）。

## 主要功能

- 将遥控器按键映射为键盘按键、组合键或媒体键。
- 将遥控器自带麦克风显示为 macOS 输入设备“遥控器麦克风”。
- 支持 Typeless、豆包输入法、微信输入法和闪电说的 Fn 点按/长按预设。
- 不做语音转文字，不保存或上传录音。

## 快速开始

### 1. 安装

1. 从 [Releases](https://github.com/ru-gong/OpenRemoteAssistant/releases) 下载 `OpenRemoteAssistant-0.2.9-development.pkg` 和 `SHA256SUMS.txt`。
2. 升级前按 **⌘Q** 完全退出旧版，然后打开 PKG 并按系统提示安装。
3. 安装不要求重启。如果音频组件尚未生效，可在结束会议、播放和录音后点击“重新加载音频服务…”。该操作会短暂中断整台 Mac 的声音。

当前安装包是未公证的开发测试包，可能被 Gatekeeper 提示。请在“系统设置 → 隐私与安全性”查看系统提示，不要关闭 Gatekeeper 或 SIP。

### 2. 连接遥控器

1. 在 macOS 蓝牙设置中配对 RC003-MS。
2. 打开遥控器助手，点击“查找已连接的遥控器”。
3. 核对设备信息并确认绑定。一次只连接一只同类遥控器。

### 3. 使用遥控器麦克风

1. 点击“连接遥控器麦克风”。
2. 在 Typeless、输入法或其他目标软件中选择 **“遥控器麦克风”**。
3. 按住遥控器右上角语音键说话，松开停止。

程序没有 30 秒录音上限。目标软件如果没有麦克风选择菜单，可在助手中将它设为系统默认输入；程序不会更改扬声器。使用期间需要保持程序运行，关闭窗口后可以继续驻留菜单栏，按 **⌘Q** 才会完全退出并停止接入。

### 4. 配置语音软件快捷键

先在目标软件中选择“遥控器麦克风”，再在助手的“语音软件”菜单选择预设：

| 软件 | 预设方式 |
|---|---|
| Typeless | 开始和结束各点按一次 Fn |
| 豆包输入法、微信输入法 | 按住语音键期间保持 Fn 按下 |
| 闪电说“直接说” | 开始和结束各点按一次 Fn |
| 闪电说“帮我说” | 按住语音键期间保持 Fn 按下 |

这些预设只需要“辅助功能”权限，不需要启用完整按键映射。软件 Fn 是 macOS 事件层的 Fn，并非实体 Globe 键；兼容性以目标软件当前版本为准。

### 5. 自定义按键映射

1. 在“系统设置 → 隐私与安全性”中允许遥控器助手使用“输入监控”和“辅助功能”。
2. 点击示意图上的遥控器按键。
3. 选择常用目标键，或点击“键盘录入”录入组合键。
4. 点击“启用映射”。

## 卸载

在应用的“遥控器”菜单或菜单栏菜单中选择“卸载遥控器助手…”。卸载需要管理员授权，默认保留个人配置，也可以选择删除当前用户的绑定、映射和偏好设置。蓝牙配对和 macOS 管理的系统日志不会被删除。

## 基本技术信息

- 版本：0.2.9（build 16）开发测试版。
- 平台：Apple Silicon、macOS 26；当前仅支持 RC003-MS。
- 音频路径：遥控器 ATVV 音频 → OpenRemoteAssistant → CoreAudio 虚拟输入。
- 安装内容：主应用、`OpenRemoteAudio.driver` 和按键服务组件；无需另装 BlackHole。
- 权限：蓝牙用于连接遥控器；完整按键映射需要输入监控和辅助功能；安装、卸载及手动重载音频服务需要管理员授权。
- 源码构建：依次运行 `zsh scripts/test.zsh`、`zsh scripts/build-driver.zsh`、`zsh scripts/build-app.zsh` 和 `python3 scripts/package.py --development`。

当前开发包采用 ad-hoc 应用签名、未签名 PKG，尚未完成 Apple 公证。RC003-MS 麦克风进入 Typeless 的基本链路已实测可用；其他语音软件预设、全部实体按键和干净 Mac 安装仍需继续验证。

## 开源许可

项目按 [GNU GPL v3 only](LICENSE) 发布。第三方来源、固定版本及修改声明见 [COPYRIGHT](COPYRIGHT) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。项目不代表小米、Apple 或所列语音软件的官方版本或背书。

更详细的技术与验收资料：

- [按键接管与麦克风连接](docs/input-and-microphone.md)
- [音频服务激活与恢复](docs/audio-service-reload.md)
- [RC003-MS 验收清单](docs/rc003-ms-acceptance.md)

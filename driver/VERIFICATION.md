# 本地驱动验证记录

2026-09-02；OpenRemoteAudio 0.1.1（build 2）。仅构建和测试进程内的驱动接口，无系统安装或系统音频 I/O。

- `zsh product/scripts/build-driver.zsh`：退出 0。Apple clang 21.0.0，macOS SDK 26.5，arm64 bundle，最低系统目标 13.0。当前构建未使用生产身份。
- 默认 ad-hoc 签名；`codesign --verify --deep --strict` 通过。
- `plutil -lint`、脚本 `zsh -n` 通过；只导出 `_OpenRemoteAudio_Create`。
- 依赖仅 CoreFoundation、CoreAudio、Accelerate 和 libSystem，没有外部第三方二进制依赖。
- 实际 CFPlugIn 工厂和假 HAL host 测试 **898 项通过**：中文设备名、UID、插件身份、公开输入 USB-compatible/隐藏输出 Virtual transport、可见状态、方向、流及控制 owner、三档采样率、无效 UID 参数拒绝、transport 只读与短缓冲拒绝、默认设备资格，以及 8 次模拟 hold 中 96 次有界合成 PCM 镜像和缺数据静音。
- 检查 driver bundle 的每个文件：没有照片、音频、官方 `.pkg`、上游图标；没有 `/Users/` 绝对用户路径。
- 原始上游 C 和 LICENSE 的 SHA-256 与固定记录一致，没有修改。

产物：`build/OpenRemoteAudio.driver`。每次构建完成后，以同一次生成的
`build/build-manifest.json` 中 bundle 文件哈希为准；bundle 资源或签名身份变化都会改变签名后的可执行文件哈希，因此本文不写死某次临时构建值。

未验证：安装后 HAL 装载、系统设置呈现、AudioQueue 到隐藏输出的实际传输、真实遥控器音频与第三方应用接收、其他 macOS 版本。离线测试的 StartIO/DoIOOperation 只操作测试进程中的内存缓冲区，不是系统采音或播放。

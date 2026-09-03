# OpenRemoteAudio 本地驱动

从固定 GPLv3 源码构建的独立虚拟音频驱动，未使用官方已编译安装包或品牌图像。

| 属性 | 值 |
| --- | --- |
| Bundle | `OpenRemoteAudio.driver` |
| Bundle ID | `org.rc001remote.audio` |
| 可见输入 | `遥控器麦克风`；UID `OpenRemoteAudio_UID`；2 入 / 0 出；报告 USB transport 兼容标识 |
| 隐藏输出 | `遥控器麦克风（内部输出）`；UID `OpenRemoteAudio_2_UID`；0 入 / 2 出；Virtual transport |
| Manufacturer | `OpenRemote contributors` |
| 音频格式 | 原生双声道 Float32 PCM；16、44.1、48 kHz，共享采样率 |
| 当前本地构建目标 | arm64，macOS 13.0+ deployment target；实际系统兼容性需另验 |

应用应通过 `kAudioHardwarePropertyTranslateUIDToDevice` 查找隐藏输出，并校验
设备 UID、所属 plugin 的 bundle ID、manufacturer、端点各自的 transport/alive 和流方向。
不得退回系统默认输出。可见输入允许用户主动选为系统默认麦克风；驱动本身不设置
系统默认，隐藏输出不具备默认播放或系统音效输出资格。

USB transport 只是公开输入的兼容元数据，用于让会排除普通 Virtual 设备的目标软件
列出该麦克风；它不表示电脑连接了实体 USB 设备，也不改变共享内存回环。隐藏输出
继续报告 Virtual，只供应用按精确 UID 写入。该思路经审阅
[HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app) 后独立适配；本项目保留
自己的分离端点、名称和标识，完整来源见 `NOTICE.md`。

从项目根目录运行：

```sh
zsh product/scripts/build-driver.zsh
```

脚本默认离线编译、ad-hoc 签名、加载本地产物做内存测试，只写 `driver/build/`。
不会复制到 `/Library/Audio/Plug-Ins/HAL`，不会执行 sudo、重启音频服务、录音或公证。
输出为 `product/driver/build/OpenRemoteAudio.driver`，附
`build-manifest.json` 和 `offline-tests.log`。

只有明确设置 `OPENREMOTE_APPLICATION_IDENTITY` 才使用指定生产身份及时间戳服务；本次
未使用该选项。生产签名不等于公证，也不代表已经获准公开分发。

`Tests/DriverOfflineTests.c` 用 `CFPlugIn` 加载本地 bundle，向接口提供假 HAL host，
验证真实工厂、元数据、重复启动/停止、跨环形缓冲区边界的合成 PCM 和缺数据静音。
测试中的 StartIO/DoIOOperation 是直接调用当前测试进程中的驱动函数，不是启动
macOS 音频设备。不能用这些结果代替安装后的系统设备和接收软件验收。

源码、修改和许可见 `upstream/manifest.json`、`CHANGES.md`、`NOTICE.md`、`LICENSE`
及未经改动的 `upstream/LICENSE`。公开发布前须提供与二进制相同版本的完整对应源码。

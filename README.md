# 库仔音乐 (Flutter)

一款支持 **QQ音乐 / 网易云音乐 / 酷狗音乐** 三大平台聚合搜索与播放的 Flutter 音乐播放器。

> 当前版本：**v3.0.0**（`3.0.0+3000`），手机原生框架内置业务包 **r000004**。

Android/iOS 手机入口已改为固定原生框架与签名远程业务包：打开应用和回到前台自动检查更新，页面及五个音源适配可独立发布；网络故障继续使用本地版本，首次离线启动也可用。发布入口、网络代理、渠道矩阵与验证记录见 [远程框架说明](docs/remote_runtime.md)。桌面端继续使用原有 Flutter 页面。

> 📌 **项目来源**：本项目基于 [ChKSz](https://linux.do/u/chksz) 作者的 API 项目对接开发，感谢作者的无私分享。API 文档：https://api.chksz.com/ · 社区：[LINUX DO](https://linux.do/)

## ✨ 功能特性

### 搜索与播放
- **三平台聚合搜索**：同时搜索 QQ / 网易云 / 酷狗，Tab 切换查看结果
- **目录修复可远程发布**：手机目录协议与解析由服务器维护，服务器出口受限时由设备传输受限公共目录请求；封面使用平台 HTTPS 地址。桌面端保留直连与兼容兜底。
- **高品质播放**：无损 / Hi-Res / 母带等音质可选，按平台自定义音质等级
- **多播放源**：QQ / 网易云 / 酷狗可分别选择自动备用、ChKSz、QingMusic、HYWmusic、星海或 GDStudio；自动模式按固定分组并行竞速、失败分组回退并有界降音质
- **备用源配置**：手机设置页可选择音源、音质、自动参与接口和个人凭据，测试解析响应；接口 URL 与签名协议由服务器维护。桌面端保留原备用源接口配置页。
- **音源协议更新**：QingMusic 参照 [上游说明与最新 v1.4.1 包](https://github.com/kejichangqing/QingMusic) 接入客户端签名，三平台 MP3 前缀读取通过实测；HYW 公益版网易云可用，QQ 实验线本次读取超时，酷狗未开放。星海网易云/酷狗可用，QQ 需要个人授权；ChKSz 需要个人 API Key。GDStudio 为 QQ/酷狗严格匹配网易云原唱及版本。自动模式排除实验线路，并保留有界回退。
- **音源分析记录**：`docs/playback_sources_analysis.md` 逐一记录 `tmp/yinyuan` 脚本的请求方式、鉴权、音质回退和接入边界
- **MV 播放**：内置 ExoPlayer 与 libmpv 双内核，默认自动回退，也可在设置中指定内核
- **歌词同步**：支持可靠时间轴逐字高亮，不可靠时间轴自动回退整行强调；支持查找匹配版本以及可记忆的字号、行间距调节
- **歌单导入**：支持 **QQ音乐 + 网易云** 双平台，粘贴歌单链接或 ID 即可导入（自动提取 ID）

### 播放体验
- **播放队列**：队列管理，顺序 / 单曲循环 / 随机播放模式
- **当前歌曲断点续播**：暂停、停止、退出应用或切换用户后，继续当前播放会话时恢复进度；异常退出后恢复最近一次定期保存的位置。搜索、歌单、历史记录、队列重新选歌及循环重播均从头开始。
- **迷你播放器**：底部悬浮迷你播放条，随时控制播放
- **沉浸式 UI**：基于专辑封面主色调的渐变背景，Material Design 3 风格
- **深色模式**：跟随系统 / 浅色 / 深色三档切换，全局持久化
- **全面屏适配**：刘海屏 / 挖孔屏边缘到边（edge-to-edge）显示

### 系统级能力
- **系统媒体通知**：播放时通知栏 / 锁屏显示媒体控制胶囊（MediaSession）
- **系统悬浮胶囊**：Android 系统级悬浮窗（跨 App 常驻），支持拖动、点击回 App、播放/暂停控制

### 备份与还原
- 统一备份收藏歌曲、收藏歌单元数据和 API Key，兼容旧版歌曲备份。
- 支持系统文件导入导出、WebDAV 网络备份，以及不依赖文件管理器的手机局域网传输。
- WebDAV 默认使用独立账号和 HTTPS 证书指纹校验；请在应用内填写独立 WebDAV 密码，切勿使用服务器 root 密码。
- 局域网传输使用随机地址令牌、6 位 PIN、5 MB 大小限制和 10 分钟自动失效。

## 🧱 项目结构

```
lib/
├── main.dart                    # 应用入口 + 底部导航 + 系统初始化
├── models/
│   ├── song.dart                # 数据模型（歌曲、歌单、歌词等）
│   └── playback_source_config.dart # 备用源入口、启停状态和默认配置
├── services/
│   ├── api_service.dart         # 手机远程解析、桌面直连与原有能力
│   ├── runtime_bundle_store.dart # 签名业务包、原子安装、离线恢复与回滚
│   ├── runtime_http_client.dart # 固定 HTTPS、证书校验、目录补偿和代理
│   ├── native_runtime_bridge.dart # 播放、数据和系统能力的受限桥接
│   ├── backup_service.dart      # 收藏 + API Key 统一备份协调
│   ├── webdav_backup_service.dart # WebDAV 传输与证书指纹校验
│   ├── lan_backup_service.dart  # 临时局域网手机传输
│   ├── update_service.dart      # 更新模块（当前未启用）
│   └── floating_capsule_service.dart  # 系统悬浮胶囊通道封装
├── providers/
│   ├── player_provider.dart     # 播放器状态管理（Provider）
│   └── theme_controller.dart    # 主题模式状态管理
├── screens/
│   ├── remote_runtime_screen.dart # Android/iOS 远程业务入口
│   ├── search_screen.dart       # 原有 Flutter 搜索页
│   ├── player_screen.dart       # 全屏播放器页
│   ├── video_player_screen.dart # 应用内 ExoPlayer / MPV 双内核 MV 播放页
│   ├── playlist_screen.dart     # 歌单页
│   ├── backup_restore_screen.dart # 文件 / WebDAV / 局域网备份页
│   ├── settings_screen.dart     # 设置页
│   └── playback_source_config_screen.dart # 备用源接口配置页
├── widgets/
│   ├── song_tile.dart           # 歌曲列表项
│   ├── mini_player.dart         # 底部迷你播放器
│   ├── smart_cover.dart         # 智能封面（失败自动走代理）
│   └── playlist_import_dialog.dart # 歌单导入弹窗（QQ/网易云）
├── theme/
│   └── app_theme.dart           # 亮/暗双主题 + 动态颜色
└── utils/
    ├── lyric_parser.dart        # LRC 歌词解析
    ├── color_extractor.dart     # 封面主色调提取
    └── system_ui.dart           # 系统状态栏样式控制

android/app/src/main/kotlin/com/example/music_player_app/
└── FloatCapsuleManager.kt       # Android 原生系统悬浮窗（TYPE_APPLICATION_OVERLAY）

remote_app/                     # 可独立发布的业务页面和交互
server/runtime/                 # HTTPS 更新服务、目录和音源适配
assets/runtime/                 # 首次离线使用的完整签名业务包
tools/deploy_runtime.ps1        # 本机签署与远程发布入口
```

## 🚀 快速开始

### 前置条件

- Flutter SDK >= 3.38.4（Dart >= 3.11.0；发布脚本固定使用 Flutter 3.41.6）
- Android Studio（构建 Android 端）

### 安装与运行

```bash
# 1. 克隆仓库
git clone <repo-url>
cd music_player_app

# 2. 安装依赖
flutter pub get

# 3. 运行（连接模拟器或真机）
flutter run
```

### 构建发布

```bash
# Android APK（release）
# 先将 android/key.properties.example 复制为 android/key.properties，
# 填写持久化 release keystore 信息；须与已发布 APK 使用同一证书，后续版本继续复用。
flutter pub get --offline
flutter build apk --release --split-per-abi --no-pub
```

修改远程页面或服务端音源后，在当前发布电脑运行 `./tools/deploy_runtime.ps1 -Version 5`（编号须递增，当前是 4），无需重新编译 APK。新增系统能力、修改固定原生逻辑或更换发布身份仍需要发布框架；iOS 签名有效期由自己的分发证书决定。

2026/11/20 远程框架完成 295 项相关 Flutter 回归、38 项框架定向复验和三种尺寸的真实页面检查，并验证真实业务包升级、离线缓存和回滚。已生成三个 ABI 的 3.0.0 测试签名 APK，签名、ABI 与内置业务资产核验通过。产物、失败渠道与网络条件见 [远程框架说明](docs/remote_runtime.md)。

已有 GitHub Actions 双端 Release 工作流已同步框架资产与产物校验；iOS 沿用未签名 IPA 流程，安装前自行签名。当前本轮改动尚未推送或触发 CI，**未做 iOS 编译验证**。

2026/11/18 音源修复已通过 230 项相关服务、播放器与横屏测试，并生成三种 ABI 的 2.9.17 测试签名 APK，签名和 ABI 核验均通过。
2026/11/19 新增逐源渠道核验：QingMusic 三平台可用，星海网易云/酷狗可用，HYW 公益版网易云可用、QQ 本次未读通、酷狗未开放；GDStudio 的 QQ/酷狗受网易云匹配曲库限制，ChKSz 和星海 QQ 需个人凭据后再验证。
本轮完成 129 组默认配置记录，其中高音质抽测 36/36 读取成功；普通测试默认跳过这些手动联网测试。完整渠道矩阵和实际 FLAC 位深/采样率见分析记录第 10 节。
产物路径、SHA-256、实际构建命令与真机验证边界见 [音源修复验证记录](docs/playback_sources_analysis.md)。正式发行继续复用原发布证书。

> 手机默认连接固定更新服务器，设置页可配置本机实际可用的 HTTP 代理；工作电脑的 `127.0.0.1:10808` 不能直接作为其他手机的代理配置。桌面端原有目录直连失败时仍可使用兼容线路。

## 🛠 技术栈

| 类别 | 技术 |
|------|------|
| UI 框架 | Flutter 原生能力 + Android/iOS WebView 签名业务页面 |
| 音频播放 | just_audio + just_audio_background（系统媒体通知） |
| MV 播放 | video_player（Media3 ExoPlayer）+ media_kit（libmpv） |
| 状态管理 | Provider |
| 网络 | dio / http |
| 图片 | cached_network_image + palette_generator（封面主色） |
| 存储 | shared_preferences + flutter_secure_storage |
| 更新验证 | cryptography Ed25519 + SHA-256 + 固定 TLS 证书 |
| 权限 | permission_handler（通知 / 悬浮窗） |

## ⚠️ 免责声明

本项目仅供学习交流使用，不提供任何音乐内容服务。所有音乐版权归原作者所有，请支持正版音乐。

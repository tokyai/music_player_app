# 库仔音乐 (Flutter)

一款支持 **QQ音乐 / 网易云音乐 / 酷狗音乐** 三大平台聚合搜索与播放的 Flutter 音乐播放器。

> 当前版本：**v2.9.4**（`2.9.4+2904`）

> 📌 **项目来源**：本项目基于 [ChKSz](https://linux.do/u/chksz) 作者的 API 项目对接开发，感谢作者的无私分享。API 文档：https://api.chksz.com/ · 社区：[LINUX DO](https://linux.do/)

## ✨ 功能特性

### 搜索与播放
- **三平台聚合搜索**：同时搜索 QQ / 网易云 / 酷狗，Tab 切换查看结果
- **直连优先**：搜索、推荐、歌单、歌词、MV 与封面优先调用平台公开接口，旧反代仅作失败兜底
- **高品质播放**：无损 / Hi-Res / 母带等音质可选，按平台自定义音质等级
- **多播放源**：QQ / 网易云 / 酷狗可分别选择 ChKSz 或 QingMusic 解析，手动切换后持久记忆
- **MV 播放**：内置 ExoPlayer 与 libmpv 双内核，默认自动回退，也可在设置中指定内核
- **歌词同步**：LRC 歌词逐行高亮滚动，支持查找匹配版本以及可记忆的字号、行间距调节
- **歌单导入**：支持 **QQ音乐 + 网易云** 双平台，粘贴歌单链接或 ID 即可导入（自动提取 ID）

### 播放体验
- **播放队列**：队列管理，顺序 / 单曲循环 / 随机播放模式
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
│   └── song.dart                # 数据模型（歌曲、歌单、歌词等）
├── services/
│   ├── api_service.dart         # 三平台目录直连 + 播放解析封装
│   ├── backup_service.dart      # 收藏 + API Key 统一备份协调
│   ├── webdav_backup_service.dart # WebDAV 传输与证书指纹校验
│   ├── lan_backup_service.dart  # 临时局域网手机传输
│   ├── update_service.dart      # 更新模块（当前未启用）
│   └── floating_capsule_service.dart  # 系统悬浮胶囊通道封装
├── providers/
│   ├── player_provider.dart     # 播放器状态管理（Provider）
│   └── theme_controller.dart    # 主题模式状态管理
├── screens/
│   ├── search_screen.dart       # 搜索页（三平台 Tab）
│   ├── player_screen.dart       # 全屏播放器页
│   ├── video_player_screen.dart # 应用内 ExoPlayer / MPV 双内核 MV 播放页
│   ├── playlist_screen.dart     # 歌单页
│   ├── backup_restore_screen.dart # 文件 / WebDAV / 局域网备份页
│   └── settings_screen.dart     # 设置页
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
flutter build apk --release
```

> 注意：除用户选择的播放解析源外，平台请求和封面均默认直连；只有直连失败时才使用 `http://161.118.252.183` 的兼容线路。

## 🛠 技术栈

| 类别 | 技术 |
|------|------|
| UI 框架 | Flutter / Material 3 |
| 音频播放 | just_audio + just_audio_background（系统媒体通知） |
| MV 播放 | video_player（Media3 ExoPlayer）+ media_kit（libmpv） |
| 状态管理 | Provider |
| 网络 | dio / http |
| 图片 | cached_network_image + palette_generator（封面主色） |
| 存储 | shared_preferences |
| 权限 | permission_handler（通知 / 悬浮窗） |

## ⚠️ 免责声明

本项目仅供学习交流使用，不提供任何音乐内容服务。所有音乐版权归原作者所有，请支持正版音乐。

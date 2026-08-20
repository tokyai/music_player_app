# 项目开发提示

## 横屏兼容要求

后续新增功能、调整现有功能，或从上游版本整合功能时，必须同时完成横屏适配。横屏布局不能只复用纵向页面的显示结果，而要确保主要操作入口、状态反馈和返回路径在横屏下仍然可见且可操作。

每次功能改动至少检查一个窄横屏尺寸（约 `640x360`）和一个宽横屏尺寸（约 `1280x800`），并为受影响的横屏分支补充 Flutter Widget 测试；涉及歌曲列表、播放器或收藏功能时，要验证收藏、播放、队列等操作没有因布局分支被隐藏。

## Android 分平台打包缓存复用

执行 Android 分 ABI 打包时，必须优先复用 `build_c/media_kit_libs_android_video/v1.1.7/` 中已经下载好的 4 个插件缓存，避免重复下载及网络失败：

- `default-arm64-v8a.jar`：MD5 `83df25b61193af8fa815e373143ac9af`
- `default-armeabi-v7a.jar`：MD5 `22e21526fefc0a2b8f17adbec9f57590`
- `default-x86_64.jar`：MD5 `6fa26bf0459b11f1c0b0dbc29e5b940d`
- `default-x86.jar`：MD5 `0d742b756dc9d1fcd84ea271d8b68f32`

在新建的干净工作树中构建时，先将这 4 个 JAR 复制到目标工作树的相同相对路径，并使用 `Get-FileHash -Algorithm MD5` 校验完整性。不得在构建前删除上述缓存；确需清理时，必须先备份并在构建前恢复。

依赖和打包依次使用 `flutter pub get --offline` 与 `flutter build apk --release --split-per-abi --no-pub`。项目构建输出已重定向到 `build_c`；若 Flutter 误报找不到 APK，应先检查 `build_c/app/outputs/flutter-apk/`，不要因此重新下载插件。

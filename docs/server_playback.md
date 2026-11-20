# 统一音源解析服务

作者：SHIXIAOYANG，2026/11/21。

现有 Flutter 页面、播放队列、缓存、下载、歌词及系统媒体控制留在客户端。QQ、网易云、酷狗的音源接入、签名、鉴权、同曲匹配、竞速和降档在服务器执行。搜索、歌单和歌词继续使用已有直连流程。

客户端启动后后台检查音源能力版本，失败继续使用已验证列表，不阻止打开界面或播放本地音频。服务端代码发布后，下一次解析直接使用新代码，不需要下载或执行 Dart/JavaScript。新增兼容统一结果协议的音源，也不需要新增客户端枚举或解析分支。

## 文件与执行入口

| 文件 | 操作 | 用途 |
| --- | --- | --- |
| `lib/models/song.dart` | 修改 | 稳定字符串音源身份、解析结果有效期 |
| `lib/models/remote_playback.dart` | 新增 | 有界音源能力和动态凭据定义 |
| `lib/models/playback_source_config.dart` | 修改 | 通用启停、个人凭据及历史配置兼容 |
| `lib/services/playback_resolver_service.dart` | 新增 | HTTPS 请求、结果校验及取消 |
| `lib/services/api_service.dart` | 修改 | 统一解析入口和有效能力过滤 |
| `lib/providers/player_provider.dart` | 修改 | 启动检查、离线列表、偏好、URL 有效期与失败源排除 |
| `lib/screens/playback_source_config_screen.dart`、`settings_screen.dart` | 修改 | 动态音源与凭据设置，保留 API Key 扫码输入 |
| `server/playback/sources.mjs`、`network.mjs`、`server.mjs` | 新增 | 解析协议、固定上游和独立服务 |
| `server/playback/front_proxy.mjs` | 新增 | 共用可直连 HTTPS 入口、原站透传与证书续期 |
| `tools/deploy_playback.ps1` | 新增 | 定向验证、发布、健康检查和失败恢复 |
| 相关 Dart 和 Node 测试 | 新增/修改 | 动态源、历史凭据、取消、失败、缓存、横屏及低资源回归 |
| `pubspec.yaml` | 修改 | 客户端版本 `3.0.1+3001`，高于已测试的远程 UI 版本 |

播放入口为 `PlayerProvider._resolveSongDetail → ApiService.resolvePlayback → /api/resolve → sources.resolvePlayback`。服务器返回音频地址及请求头，客户端校验后交给 `just_audio`；音频从原音源直接读取，不经过本服务器转发。

现有本地音源协议函数保留用于历史协议回归。生产构造默认走服务器，不在服务器失败时调用这些旧解析函数；`useRemotePlayback: false` 仅在旧协议测试中显式使用。

## 部署与直连入口

公网入口：`https://137.175.62.3:8443/music-player-api/`。

| 接口 | 含义 |
| --- | --- |
| `GET /health` | 服务健康与协议版本 |
| `GET /api/sources` | 能力版本、音源、平台和用户凭据字段 |
| `POST /api/resolve` | 请求解析或排除失败音源后重新解析 |

`9443` 在本机直连超时，代理可达；因此将新 API 接入已确认可直连的 `8443`。前置容器 `kuzai-music-front` 使用原站公开可信的 IP 证书，音乐前缀转发至 `127.0.0.1:9443`，其他路由及 WebSocket 转发至原站 `127.0.0.1:8444`。原 `juhe-hybrid.service` 只调整监听地址，证书续期、80 端口验证和业务参数保留。

客户端正常校验证书，不设置跳过验证的回调。前置容器只读挂载整个证书目录，每分钟检测续期并更新 TLS 上下文；无效的新证书不会替换现有身份。两条本机 HTTPS 链路也检查证书及 IP 身份。

服务目录为 `/opt/kuzai-music-api`；旧远程 UI 容器及 `/opt/kuzai-music-runtime` 已删除。服务器登录凭据、发布私钥和个人音源凭据不进入源码、客户端或发布归档。`server.env` 只放服务端协议参数，可选公共默认配置在服务器维护。

发布服务端修改：

```powershell
.\tools\deploy_playback.ps1
```

脚本复用已安装的 Node、Docker 镜像和受保护 SSH 助手。旧助手的临时副本只增加新目录归档上传权限，原助手及凭据不修改。先在本机和隔离容器中验证，再保存上一版代码及原站监听配置、切换两个专用容器；API 与原站 TLS 健康检查通过后才报告成功。失败时执行本轮代码和监听配置恢复。原站首次接入前配置保存在服务目录的 `juhe-hybrid.original.service`，不要在清理新入口时遗漏恢复。

## 新增或更新音源

1. 在 `sources.mjs` 的 `sources` 增加稳定 `id`、名称、平台、分组和凭据字段。`group` 决定自动优先级，每批最多四源；实验线路不参与自动模式。
2. 在同文件的 `handlers` 增加协议处理，映射统一音质并返回 `resolved(...)` 的结果。
3. 新域名在 `network.mjs` 的固定上游白名单中登记；不要允许客户端下发任意 URL。
4. 增加相应协议、错误和取消测试，然后运行发布脚本。App 再次打开或在音源配置页刷新后即可发现新源；已有源协议修复在下次解析时生效。

能力最多 32 源、每源 16 个通用凭据字段。个人凭据按音源 ID 隔离，旧个人 API Key、HYW/星海卡密继续兼容；随 APK 发布的 HYW 公益默认卡密不发送，避免覆盖以后服务端更新的公共配置。删除的源不发送凭据或停用标识，但保留历史偏好供恢复。新平台、原生解码器或新交互能力仍需要相应客户端能力支持。

## 验证与调试

```powershell
# 解析协议、前置透传、真实 TLS、续期及低资源压力测试。
node --test server/playback/playback.test.mjs server/playback/front_proxy.test.mjs

# 动态源、凭据、URL有效期和生命周期。
flutter test --no-pub test/services/remote_playback_test.dart test/remote_playback_provider_test.dart test/audio_settings_persistence_test.dart

# 两种横屏、旋转、播放/收藏/队列及设置。
flutter test --no-pub test/remote_playback_landscape_test.dart test/playback_source_api_key_test.dart test/landscape_layout_test.dart

# 明确禁用代理并正常校验证书。
curl.exe --noproxy "*" --connect-timeout 5 --max-time 8 https://137.175.62.3:8443/music-player-api/health
```

服务端同时最多 8 个解析任务，不排队；最多 32 连接，单源 JSON 硬上限 512 KiB、取票 64 KiB、单次解析最多 19 秒和四档音质。客户端校验协议、URL、音频格式、请求头和有效期；切歌、退出或配置变化会取消旧请求。设备和服务端均不长期保存完整上游响应。

原 `8 × 4 × 5 MiB` 允许输入的压力场景 RSS 曾达到 481 MiB，超过容器限额。改为 512 KiB 并限定 Node old-space 96 MiB 后，同并发最大响应场景本机实测 RSS 113 MiB；加入子进程压力回归。生产解析容器限额 192 MiB。

调试优先在 `ApiService.resolvePlayback` 看稳定音源 ID、排除列表和代次；在 `PlayerProvider._freshPlayUrl` 看 URL 有效期与实际源；服务端在 `resolvePlayback`、`raceSources` 看分组、音质和失败分类。前置网络问题检查 `createFrontProxy`、两容器状态、原站健康接口及证书有效期。不要记录凭据、签名或临时音频 URL。

本机未连接 Android 设备，未做真机声音播放、完整音频解码或 iOS 原生验证。联网范围、最终回归和测试签名 APK 信息记录在本轮交付结果中；取得短段音频不等同于完整解码或目标音质已经验证。

## 本轮结果

- 258 项相关 Flutter 回归全部通过；包括实际 Widget HTTP 生命周期、200 次请求后的取消记录归零、客户端并发限制、旧个人凭据保留和两个横屏分支。
- 38 项 Node 测试全部通过，无跳过；包括真实 HTTPS/IP 身份、证书替换、WebSocket、超大请求及低资源压力场景。发布隔离容器缺少 OpenSSL 可执行程序，预发布跳过该项本机证书生成测试；实际两个 TLS 健康接口仍完整验证。
- 修改文件分析无 error/warning，存量 style/deprecation 的 info 保留。`git diff --check` 通过；`pubspec.lock` 未改变，无新增依赖。
- `curl --noproxy "*"` 及应用实际 `PlaybackResolverService` 均成功直连新入口；实际客户端取得五个源和 QQ 自动解析结果，完成后活动请求数为 0。原站七个路径的状态码及响应摘要与切换前相同。
- 三平台“海阔天空 / BEYOND”逐源标准档直连复验 18 组；12 组读到有效音频前缀（MP3/FLAC），包含三平台自动模式。其余为 ChKSz 个人 API Key、星海 QQ 个人授权、HYW 酷狗未开放及 HYW QQ 超时。临时报告不保存播放 URL 或凭据。
- Android Release 的 R8 与 Lint 检查通过，最终离线 `assembleRelease` 为 `BUILD SUCCESSFUL in 58s`，850 个任务中 817 个复用。标准 Flutter 入口因已有 JBR 缺少 `jlink` 失败，复用已安装 JBR 25 运行检查、完整 JDK 17 编译的现有定向工具链完成；四个媒体插件缓存 MD5 保持一致。

构建顺序为 `flutter pub get --offline`、`flutter build apk --release --split-per-abi --no-pub`，再按项目已有工具链执行离线 Gradle `assembleRelease`。本机调用前两条命令使用已安装 SDK 的 `dart.exe flutter_tools.snapshot --suppress-analytics --no-version-check`；定向命令见音源修复记录第 9 节，所有带点或逗号的 `-P...` 参数在 PowerShell 中使用字符串数组传入，并设置现有 `ANDROID_HOME`、`JAVA_HOME`。

产物为测试签名 `3.0.1`，复用此前本机 2.9.17/3.0.0 测试证书，SHA-256 为 `2E679F1D49E99D31E178B67B816100758C080CF76CB319C2CA05B5932573517D`。三包的签名、ABI 和版本已通过 `apksigner verify --verbose --print-certs`、`aapt2 dump badging` 核验，临时 `android/key.properties` 已清除。正式发行仍需自己的原发布证书。

| ABI | 版本码 | 测试安装包 |
| --- | --- | --- |
| arm64-v8a | 5001 | [ARM64](../build_c/releases/server-playback-3.0.1/kuzi-music-3.0.1-arm64-v8a-test-signed.apk) |
| armeabi-v7a | 4001 | [32 位 ARM](../build_c/releases/server-playback-3.0.1/kuzi-music-3.0.1-armeabi-v7a-test-signed.apk) |
| x86_64 | 7001 | [x86_64](../build_c/releases/server-playback-3.0.1/kuzi-music-3.0.1-x86_64-test-signed.apk) |

摘要与包信息保存在同目录的 `SHA256SUMS`、`apk-verification.json`。执行 `adb devices` 没有连接设备，因此真机及 iOS 边界仍如上所述。

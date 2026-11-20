# 远程业务框架使用与验证

作者：SHIXIAOYANG，2026/11/20。

Android 和 iOS 共用固定 Flutter 框架，页面从已签名的业务包加载，QQ、网易云、酷狗目录及五个音源适配在服务端维护。打开应用和回到前台都会检查业务更新；下载失败时继续使用本机已验证的版本，第一次离线启动使用安装包内置版本。

本轮框架版本为 **3.0.0+3000**，框架能力版本为 **1**，内置及线上页面为 **r000004**。

## 1. 更新范围

| 修改内容 | 修改位置 | 是否需要重新安装 |
| --- | --- | --- |
| 发现、搜索、播放器、歌词、音乐库、备份、设置、AI 页面及交互 | remote_app | 发布业务包即可 |
| QingMusic、星海、HYW、GDStudio、ChKSz 的接口、认证、音质与自动回退 | server/runtime/sources.mjs | 发布服务端修改即可 |
| QQ、网易云、酷狗目录、歌单、歌词与 MV 请求及解析 | server/runtime/catalog.mjs | 发布服务端修改即可 |
| 同一平台新增解析音源、音质、凭据输入 | 服务端能力数据和 remote_app | 已有桥接协议可承载时发布即可 |
| 播放器内核、系统媒体通知、权限、文件通道、语音 SDK、桥接能力 | lib、android、ios | 需要发布新的原生框架 |
| B站的既有查询与解析、原生 AI/语音执行器内部逻辑 | 既有原生服务 | 当前仍随原生框架发布 |
| TLS 固定指纹或发布公钥更换、iOS 签名过期 | 框架配置或分发签名 | 需要更新框架或重新签名 |

iOS 按已确认的自用或内部签名 IPA 场景设计。业务包不会替换原生二进制，也不能延长 IPA 签名有效期。

## 2. 文件清单与入口

| 文件或目录 | 类型 | 作用 |
| --- | --- | --- |
| lib/main.dart | 修改 | 手机进入 RemoteRuntimeScreen，悬浮胶囊回到远程播放器 |
| lib/screens/remote_runtime_screen.dart | 新增 | WebView、握手、页面代次、更新切换、返回和生命周期 |
| lib/services/runtime_config.dart、runtime_http_client.dart | 新增 | 固定部署身份、证书校验、受限传输与网络代理 |
| lib/services/runtime_release.dart、runtime_bundle_store.dart | 新增 | Ed25519 验签、文件校验、原子安装、离线恢复和回滚 |
| lib/services/native_runtime_bridge.dart、native_runtime_library.dart、native_runtime_assistant.dart、runtime_bridge_protocol.dart | 新增 | 调用既有播放、数据、系统和 AI 能力，并校验输入 |
| lib/services/runtime_preferences.dart、runtime_backup.dart | 新增 | 当前用户业务状态、系统安全存储和备份扩展 |
| lib/widgets/runtime_status_view.dart | 新增 | 原生启动与错误页，横屏保留恢复入口 |
| lib/services/api_service.dart、lib/providers/player_provider.dart、lib/models/song.dart | 修改 | 手机解析走服务端；真实源 ID 与音质不依赖原生枚举 |
| lib/providers/user_controller.dart | 修改 | 删除用户时清理新增安全凭据 |
| remote_app | 新增 | 随业务包发布的页面、样式和交互 |
| server/runtime | 新增 | 独立 HTTPS 服务、音源、目录补偿、验签及有界清理 |
| tools/build_runtime_release.mjs、tools/deploy_runtime.ps1 | 新增 | 本机签署、上传、验签和切换发布 |
| .github/workflows/mobile_release.yml | 修改 | 双端编译、业务资产校验、APK 校验及未签名 IPA 发布 |
| assets/runtime | 新增 | 首次离线启动所需的完整签名业务包 |
| test/runtime_*、test/manual_source_audit/runtime_server_audit_test.dart、tools/test_runtime_ui.mjs | 新增 | 回归、异常、横屏、页面与实际网络验证 |
| pubspec.yaml、pubspec.lock | 修改 | 版本及已批准的两个精确依赖 |

执行从 `MusicPlayerApp → RemoteRuntimeScreen._initialize` 进入：初始化原生会话、验证本地业务包、加载本地入口。页面调用 `KuzaiHost.connect` 后发送 ready，框架开始检查服务端清单。新包验证通过后保留页面状态并切换；播放会话由原生持有，页面更新不会重建播放器。

业务页面不能直接访问任意原生方法。桥接只开放明确列出的播放、队列、收藏、库、备份、设置、AI、视频和目录接口。

## 3. 发布下一版

在当前工作电脑和项目根目录修改 remote_app 或 server/runtime 后执行：

```powershell
# 编号必须递增，当前线上是 4。
.\tools\deploy_runtime.ps1 -Version 5
```

脚本使用本机已安装的 Node 和已有 SSH 凭据助手，完成以下步骤：

1. 把 remote_app 打成完整业务包，使用本机 Ed25519 私钥签署原始清单字节。
2. 上传业务包、服务端代码和发布公钥，先在服务器校验签名及包摘要。
3. 原子替换清单，只重启 kuzai-music-runtime。
4. 保留最近五版服务端业务包，清理本轮暂存目录和旧发布归档。

发布会短暂重启独立服务；已经解析的原生播放与本地缓存仍可使用。页面更新会等待当前桥接操作结束，备份传输、模态确认和未保存的密码输入会延迟切换。

发布失败时不要复用已写入的版本编号。需要回退页面内容时，用已知可用的 remote_app 内容发布一个更大的编号；客户端不会重新安装已经回滚的坏版本。只有编译原生框架时才需要把本次完整 manifest.json 和 bundle.json 复制到 assets/runtime。

## 4. 部署与网络

| 项目 | 当前值 |
| --- | --- |
| 更新地址 | https://137.175.62.3:9443/ |
| HTTPS 健康检查 | /health |
| 清单 | /manifest.json |
| 发布包 | /releases/r000004/bundle.json |
| 服务目录 | /opt/kuzai-music-runtime |
| 容器 | kuzai-music-runtime |
| 容器内 HTTPS | 8443，宿主机映射 9443 |
| 运行环境 | 已缓存的 Node 24.21.0，非 root 用户 |

9443 与 SSH 管理端口是不同用途。当前电脑的直连链路无法访问 9443，经现有 HTTP 代理可以完成证书校验和联网验证。手机默认直连；需要代理时在 **设置 → 更新服务器网络** 填写设备上实际可用的 HTTP 代理主机和端口。首次打开没有网络也可以使用内置页面进入设置。

本次使用的 `127.0.0.1:10808` 是工作电脑的代理，不是手机通用配置。代理只改变固定更新服务的连接路由，证书校验保持开启。公共目录补偿始终沿用设备的直连出口。

服务器出口无法返回正常 QQ/网易云目录时，服务端下发一次性的公共目录请求计划；设备传输后回传结果，解析仍由服务端负责。原生只允许 music.163.com、y.qq.com、kugou.com 及其子域、80/443、GET/POST 和限定请求头，不转发 Cookie 或 Authorization，不跟随重定向。单次目录响应上限 512 KB，最多三步；计划最多保留 16 个、45 秒后失效，失败或取消也消费编号。

## 5. 数据与发布身份

收藏、历史、队列、下载、用户数据和业务设置仍保存在本机。个人音源凭据保存在系统安全存储中，普通状态消息不包含密钥。普通和完整备份包含相应用户的业务状态与凭据；恢复前校验，扩展写入或原备份恢复失败时回退扩展状态。

发布私钥和 SSH 登录凭据不在项目、APK、业务包或服务器公共资源中。当前本机私钥位于：

```text
E:\work\tools\music-player-repair\remote-runtime-keys\publisher-private.pem
```

保留这份私钥和本机凭据助手，换电脑发布时需要迁移或重新配置。服务器只有发布公钥。发布公钥为：

```text
ms6EKQj4Rd9CuRDUVvjGrToKNHHT80yog/tMtqw+Pb8=
```

当前固定 TLS 证书 SHA-256：

```text
A00512C4A3D90BFC8D3540C7CAD547FDC060D9E24321A634C06627BD093FDAAF
```

更新只接受固定服务器且不跟随重定向；先验证发布者签名，再校验包摘要、大小、路径、文件数量及实际文件。设备只保留当前和上一版本。下载、切换或页面启动失败不会覆盖已有有效用户数据。

## 6. 当前渠道

本轮固定歌曲是三平台的“海阔天空 / BEYOND”，标准档为 QQ/酷狗 320k、网易云 exhigh。这里的“读取成功”指取得并识别 4096 字节音频前缀，未代表目标音质或完整原生解码已经验证。

| 音源 | QQ | 网易云 | 酷狗 |
| --- | --- | --- | --- |
| QingMusic | 读取成功；曾出现 HTTP 525，复测恢复 | 读取成功 | 读取成功 |
| 星海 | 需要个人授权卡密 | 读取成功 | 读取成功 |
| HYW 公益版 | 地址读取超时，实验线路 | 读取成功 | 公益版未开放 |
| GDStudio | 原唱元数据匹配网易云后读取成功 | 读取成功 | 原唱元数据匹配网易云后读取成功 |
| ChKSz | 需要个人 API Key | 需要个人 API Key | 需要个人 API Key |
| 自动备用 | 读取成功，支持排除读不通的实际源 | 读取成功 | 读取成功 |

自动模式依据服务端渠道表排除实验线路；HYW QQ 保留手动测试入口。授权线路仍需用户拥有有效配置，热更新不能代替上游授权。

三平台歌曲搜索、发现页、歌词、歌单搜索和两页歌单打开都取得过成功结果；最新复验中 QQ 目录出现状态 2001，定向复验的兼容请求仍超时。QQ 首屏搜索、推荐和歌单已补回项目原有兼容兜底，但不能据此宣称当前网络始终可用；兼容搜索后续页未确认，不会重复首屏充当分页。MV 三平台均取得过地址，QQ 也有状态 2001 的样本。MV 地址核验未包含真机视频解码。

完整原始记录见 [本轮联网报告](../tmp/hot_runtime_20261119/runtime-server-audit.json) 与 [QQ 目录定向复验](../tmp/hot_runtime_20261119/runtime-qq-catalog-recheck.json)。之前 129 组渠道及高音质结果保留在 [音源分析第 10 节](playback_sources_analysis.md#10-20261119-逐源渠道与音质实测)。

## 7. 验证与调试

本轮 295 项相关 Flutter 回归通过，补充内置资产验签后框架定向测试 38 项通过；用户切换和退出后的悬浮胶囊迟到回调另行复验 3 项通过。Node 服务端 21 项测试通过。联网审计包含真实 TLS/发布签名、离线缓存、r000003 → r000004 升级与回滚、目录和逐源状态；外部源失败会写入报告，不把“审计脚本通过”当作所有渠道可用。

```powershell
# 新框架定向回归：拒绝篡改、过大响应、取消、迟到结果、重复检查和备份写入失败。
flutter test --no-pub test/runtime_bundle_store_test.dart test/runtime_http_client_test.dart test/runtime_api_service_test.dart test/runtime_status_landscape_test.dart test/runtime_backup_test.dart

# 服务端协议、安全边界、取消、渠道和有界回退。
$env:OPENSSL_TEST_BINARY='C:\Program Files\Git\usr\bin\openssl.exe'
node --test server/runtime/runtime.test.mjs

# 本机已有 Chrome：真实点击与 640x360、1280x800、390x844 布局。
node tools/test_runtime_ui.mjs

# 明确开启才联网；代理参数使用工作电脑已配置的实际地址。
flutter test --no-pub --dart-define=RUN_RUNTIME_AUDIT=true --dart-define=RUNTIME_AUDIT_HTTP_PROXY=127.0.0.1:10808 test/manual_source_audit/runtime_server_audit_test.dart --reporter expanded
```

联网输入、渠道读取状态和失败原因写入 tmp/hot_runtime_20261119/runtime-server-audit.json，不保存播放地址、签名头或个人凭据。普通测试默认跳过联网审计。

| 断点 | 优先观察 |
| --- | --- |
| RemoteRuntimeScreen._initialize / _load / _applyCandidate | _generation、_ready、_loading、_applying、_candidate、_pageCancel |
| RuntimeBundleStore._check / _install / rollback | release.version、minimumFramework、pointer.maxVersion、current、previous |
| RuntimeHttpClient._catalogRequest / _publicCatalog | 地址是否通过边界校验、响应大小、取消信号，不记录请求凭据 |
| ApiService._remotePlayback / PlayerProvider.refreshRemotePlaybackSettings | selected、selectedQuality、providerId、失败源与缓存音质身份 |
| server/runtime/sources.mjs 的 resolvePlayback / raceSources | groups、excluded、effectiveQuality、attempted、failures |
| RuntimeBackup.restore | targets、previous、扩展写入是否成功及原恢复是否开始 |

已覆盖取消、重复操作、损坏包、缓存恢复、超大内容、迟到歌单、桥接发送失败和两个横屏尺寸；资源清理还经过代码审阅。**未做 Android 真机声音/完整解码、真实系统 WebView 生命周期及 iOS 原生验证**，本机没有连接设备、Mac 或 Xcode。

## 8. GitHub Actions 打包

沿用项目已有的 **Android 和 iOS Release** 手动工作流：在仓库 Actions 中选择该工作流与包含本轮改动的分支，点击 Run workflow。版本与基础版本码读取 pubspec.yaml；release_tag 留空时使用 v3.0.0。只有新框架发布需要此工作流，远程页面与音源修复使用第 3 节的独立发布入口。

本次同步内容：两端严格恢复 pubspec.lock，构建前验证内置业务包；Android 清理旧 APK 输出后构建，并核验签名、ABI、版本和实际打包资产；iOS 验证 Runner 可执行文件与完整业务资产，再打成未签名 IPA。两端上传各自 SHA256SUMS 文件，全部成功后沿用原流程发布 GitHub Release。

没有增加第三方 Action，继续使用已有 Flutter 3.41.6、Java 21 和插件缓存配置。Android CI 仍为每次生成的临时测试证书；iOS CI 输出 **未签名 IPA**，安装前使用自己的自用或内部签名方式。Release 说明保留这两项签名状态。

已完成 YAML 解析与 17 段 Bash 语法检查，并在本机通过实际 APK 产物校验。**尚未推送本轮修改或触发 GitHub Actions，因此未做 CI 的 iOS 编译验证**。

## 9. 本机 Android 产物

项目要求的 flutter pub get --offline 已通过。首次标准 Flutter 构建因 Google 引擎依赖地址连接重置失败；使用已有代理恢复 Gradle 元数据后，以本机 JBR 25 运行 Gradle/Lint、完整 JDK 17 编译，完成 release 构建。最终离线复验 `BUILD SUCCESSFUL in 51s`，890 个任务中 55 个执行、835 个复用，R8 与 Lint 均通过，四个 media-kit 缓存 MD5 保持一致。

三个 APK 的签名、ABI、版本和内置 r000004 资源均通过核验。最低 Android API 24、目标 API 34，包名 com.example.music_player_app，证书 SHA-256 为 `2E679F1D49E99D31E178B67B816100758C080CF76CB319C2CA05B5932573517D`。这些是测试签名产物，正式框架发行继续使用自己的固定发行证书。

| APK | 版本码 | 大小（字节） | SHA-256 |
| --- | --- | --- | --- |
| [arm64-v8a](../build_c/releases/runtime-3.0.0/kuzi-music-3.0.0-3000-android-arm64-v8a-test-signed.apk) | 5000 | 32,676,591 | `4FB3C1846AAC9537F13081C9CB85A00B54279CF4F69B0DB84DC410150BE81F99` |
| [armeabi-v7a](../build_c/releases/runtime-3.0.0/kuzi-music-3.0.0-3000-android-armeabi-v7a-test-signed.apk) | 4000 | 31,225,577 | `D005002CD8E38159C2B2973264662791B1CC76667F676071779F56DD745F935A` |
| [x86_64](../build_c/releases/runtime-3.0.0/kuzi-music-3.0.0-3000-android-x86_64-test-signed.apk) | 7000 | 34,850,052 | `D50A7E568E139F7ADE33BA2B443EB513007E98446D2A138E65FEF81AB8BE7A29` |

日志和机器可读结果分别位于 tmp/hot_runtime_20261119/apk-build-toolchain-console.txt 与 apk-verification.json。历史 2.9.17 产物已按原摘要保存到 build_c/releases/source-repair-2.9.17，避免新构建覆盖历史记录。未连接 Android 设备，**未做真机声音与完整解码验证**。

## 10. 本地 Mac 构建备用步骤

iOS 项目与当前 webview_flutter_wkwebview 3.25.1 均声明最低 iOS 13，使用 WKWebView，保持背景音频和横竖屏配置。这里只确认了依赖源码与 Dart 实现，未完成 Swift/CocoaPods 编译。

在已配置 Flutter 3.41.6、Xcode、CocoaPods 的 Mac 上，使用自己的开发团队、设备登记和 provisioning profile：

```bash
# 先恢复锁定依赖，再在 Xcode 的 Runner 中配置内部签名。
flutter pub get
open ios/Runner.xcworkspace

# 使用当前框架与内置完整签名业务包构建内部 IPA。
flutter build ipa --release --no-pub
```

签名 IPA 后在真实 iPhone/iPad 核验：离线首次打开、后台音频、打开时升级、失败回滚、切换用户、退出、播放器释放、窄横屏收藏/播放/队列和文件导入。当前 **未生成或签名 IPA**。

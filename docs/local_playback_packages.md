# 本地音源解析包

作者：SHIXIAOYANG，2026/11/21。

3.0.2 将音乐解析移回设备。服务器只分发签名的音源解析包；App 启动和回到前台时后台检查更新，有更高版本才下载、验签、试启动和激活。没有更新或更新接口断网、超时、包损坏时，继续使用当前本地包。首次安装也带有完整内置包。

缓存命中时播放器直接读取本地音频。没有歌曲缓存时，本地脚本请求各音源上游，取得音频地址后由播放器直接读取音频。这仍需要访问音源及音频网络；更新服务器不参与解析，也不验证每次播放。

## 变更清单

| 文件 | 操作 | 用途 |
| --- | --- | --- |
| `pubspec.yaml`、`pubspec.lock` | 修改 | 3.0.2，获批的 flutter_js 0.8.7 / cryptography 2.9.0 及资产登记 |
| `assets/playback_sources/manifest.json`、`bundle.json` | 新增 | 签名内置版本 1，首次离线启动可用 |
| `playback_package/sources.js`、`sources.test.mjs` | 新增 | 便携五源协议、动态能力和协议回归 |
| `lib/models/playback_package.dart` | 新增 | 清单验签、版本、摘要、能力与包上限 |
| `lib/services/playback_package_store.dart` | 新增 | 本地加载、独立后台更新、原子激活、坏包回退及取消 |
| `lib/services/playback_script_runtime.dart`、`playback_script_worker.dart`、`playback_script_host.dart` | 新增 | 短生命周期隔离运行、原生预算与受限上游桥接 |
| `lib/services/playback_resolver_service.dart` | 修改 | 捕获本地包解析、校验结果、故障回退，移除远程解析请求 |
| `lib/services/api_service.dart` | 修改 | 本地默认入口、原生不可用时预置五源兜底、包能力通知 |
| `lib/providers/player_provider.dart`、`lib/main.dart` | 修改 | 本地能力读取、启动/回前台后台更新、生命周期保护 |
| `lib/screens/playback_source_config_screen.dart` | 修改 | 本地包版本和继续使用本地版本的状态说明 |
| `server/playback/server.mjs`、`front_proxy.mjs` | 修改 | 固定静态更新路由、文件和响应体上限 |
| `tools/build_playback_package.mjs`、`install_playback_package.mjs`、`publish_playback_package.ps1` | 新增 | 签署、验证、原子发布及有界版本保留 |
| `tools/deploy_playback.ps1` | 修改 | 发布静态入口前执行本地与隔离容器的文件边界测试 |
| 相关 `test/` 与 Node 测试 | 新增/修改 | 离线、挂起、切包、回退、取消、资源、缓存和横屏回归 |
| `README.md`、`GLOSSARY.md` 与本文 | 修改/新增 | 使用方式、术语及验证限制 |

## 执行入口

播放：`PlayerProvider._resolveSongDetail → ApiService.resolvePlayback → PlaybackResolverService.resolve → PlaybackScriptRuntime.resolve`。解析捕获不可变包快照，后台切换只影响后续操作。结果按实际使用的包检查音源及平台，校验地址、格式、请求头和有效期后交给原播放器。

更新：`PlayerProvider.refreshPlaybackSources → ApiService.checkPlaybackPackageUpdate → PlaybackPackageStore.checkUpdate`。本地列表读取结束后以 `unawaited` 检查更新，播放流程不等待这条网络链。更新文件先写暂存目录，最后原子切换当前指针；故障回退只切本地包，并同步恢复音源列表，不清空队列、歌曲缓存或个人凭据。

## 平台与资源限制

Android 使用固定 QuickJS AAR 的官方内存与中断 API。在任何包代码执行前，运行 50ms 无限循环中断自检与受限内存分配自检；不满足保护要求时返回 `ENGINE_UNAVAILABLE` 并使用现有编译内置五源。每条解析使用独立 isolate，完成前释放原生 VM、回调、计时器、订阅与 HTTP 任务。

Windows 固定 DLL 和 Apple JavaScriptCore 缺少当前所需的原生内存保护，当前使用编译内置五源，无法应用动态脚本修复或新增源。Android 真机原生自检与发声尚未验证；不能将 Node 协议测试或静态 ELF 符号检查当作真机验证。

包 ≤1MiB、清单 ≤64KiB、能力 ≤32 源、每源 ≤16 凭据字段。原生 JS 内存预算 16MiB，每次执行/Promise job 有 CPU 预算；同时最多 4 个解析任务，每操作最多 4 个上游请求、8 个延时与32个 scope，操作总时限20秒，单响应 ≤512KiB。初始化阶段不允许创建网络或延时任务。

仅签名包声明的 HTTP(S) origins 可用于上游请求，禁止重定向、任意 Host、无效请求头和超大正文。Ed25519 验签覆盖原始清单字节，清单再绑定完整包 SHA-256 和长度；发布私钥、SSH 凭据不进入 APK 或归档。关闭、用户切换、取消和迟到响应不能激活包或发布已失效的播放结果。

库默认的对象转换可能把巨大稀疏数组展开到Dart，默认Promise异常跟踪也会转换任意异常值。运行时因此捕获并隐藏唯一原生桥接入口，执行与能力读取只允许固定结果或有界JSON文本，原生任务泵仅读取整数状态。包应通过 `KuzaiHost` 请求上游，保持内建函数和可信桥接完整。

## 更新服务与发布

公网地址：`https://137.175.62.3:8443/music-player-api/updates/`。

| 请求 | 内容 |
| --- | --- |
| `GET manifest.json` | 不缓存的签名版本清单 |
| `GET packages/pNNNNNN.json` | 对应不可变解析包，可缓存 |

共用现有公开可信 IP 证书，9443 仅监听本机，原站仍由8443前置代理透传。旧远程 UI 目录和容器已删除。旧 `/api/sources`、`/api/resolve` 暂时供3.0.1客户端继续使用，3.0.2代码没有调用这两个接口。

新增或修复音源时修改 `playback_package/sources.js` 的定义、处理函数和上游列表，并增加相应测试。兼容现有三平台和结果/Host协议的音源，只需发布递增版本包；新增原生功能或平台仍需要客户端升级。个人授权继续按音源 ID 保存。

```powershell
# 输出到明确暂存目录，版本必须大于已发布版本。
node tools/build_playback_package.mjs tmp/local-package-release 2

# 验证、上传及原子发布；首次安装静态路由需先运行deploy_playback.ps1。
.\tools\publish_playback_package.ps1 -PackageDirectory tmp/local-package-release
```

发布保持清单最后切换，仅保留当前及上一包。不要同版本覆盖已有包；回退修复应发布更高版本。App 磁盘不可写时保留原有效包或内置包，并在后续正常检查重试。

## 验证方法与断点

```powershell
node --test playback_package/sources.test.mjs server/playback/playback.test.mjs server/playback/front_proxy.test.mjs server/playback/package_updates.test.mjs
flutter test --no-pub test/services/playback_package_store_test.dart test/services/playback_script_runtime_test.dart test/services/remote_playback_test.dart test/local_parser_offline_test.dart
flutter test --no-pub test/remote_playback_provider_test.dart test/audio_settings_persistence_test.dart test/remote_playback_landscape_test.dart test/playback_source_api_key_test.dart test/landscape_layout_test.dart
curl.exe --noproxy "*" --connect-timeout 5 --max-time 10 https://137.175.62.3:8443/music-player-api/updates/manifest.json
```

构造更新接口 SocketException 或永不完成的响应，本地解析与本地音源列表应在1秒内完成；切换版本时，旧进行中请求仍返回旧包结果；新包执行故障后列表和解析都恢复旧版本；close后活动任务与计时器归零。横屏检查640x360与1280x800及旋转，保留收藏、播放、队列与返回操作。

优先断点：`PlaybackPackageStore._checkUpdate/_commit/_rollback` 观察版本、当前指针和错误；`PlaybackResolverService.resolve` 观察 `usedPackage`、结果音源及取消信号；`ApiService._syncLocalPlaybackCatalog` 观察回退后的能力与代次；`_NativeBudget.verifyGuards` 观察设备中断/内存检查；Host `_request` 检查域名、活动任务和响应大小。

Android 构建先 `flutter pub get --offline`，再 `flutter build apk --release --split-per-abi --no-pub`，复用四个 media-kit JAR。既有 JBR 缺少jlink时使用项目已有Java17定向Gradle脚本。测试签名APK只用于同证书测试安装，正式发行需原发布证书。

## 验证结果

- 最终14文件 Flutter 定向回归 **280项通过**，包括签名、离线/永远挂起更新、回退列表、并发/取消、关闭、缓存、凭据、两种横屏及旋转。运行时25项含6项真实生产桥接的Node探针，测试巨大稀疏数组、异常、能力、消息边界及内置包兼容。
- 本机 Node 全组 **78项：76通过、0失败、2跳过**。两个Windows文件符号链接权限用例在服务器Linux隔离测试均通过；预发布容器 **59项：58通过、1跳过**，唯一跳过为镜像缺少OpenSSL的临时证书生成测试，实际API和原站TLS健康检查通过。
- 修改的生产Dart文件分析无error/warning，API存量及常量风格info保留。PowerShell AST、远程发布脚本 `bash -n`、Node语法与 `git diff --check` 通过。没有commit或push。
- 更新服务已部署，版本1已签署发布。禁用代理的 `curl.exe --noproxy "*"` 下载清单及包，验签、长度34017字节及SHA-256与内置包一致。原站七个路径的状态/摘要和七个业务容器ID均与部署前相同；旧远程UI服务目录不存在。
- 内置签名脚本通过受控Node Host直连验证三平台“海阔天空”自动标准档，三个样本均取得音频地址及有效MP3前缀，待处理scope归零，更新服务器请求为0。这只验证协议与短段音频，没有验证Android原生运行或完整解码。
- Android最终离线 `assembleRelease` **BUILD SUCCESSFUL in 1m22s**，889任务。标准Flutter入口遇到已有JBR缺jlink，复用完整JDK17定向构建；局部明确flutter_js的Java8目标，四个media-kit缓存MD5一致。构建前后14个生产输入摘要一致。
- 三包通过 `apksigner verify --verbose --print-certs`、`aapt2 dump badging`、内置包摘要和实际ELF符号核验，含内存、栈、中断、Promise tracker及任务泵导出。临时 `android/key.properties` 已删除。

| ABI | 版本码 | 测试安装包 |
| --- | --- | --- |
| arm64-v8a | 5002 | [ARM64](../build_c/releases/local-playback-3.0.2/kuzi-music-3.0.2-arm64-v8a-test-signed.apk) |
| armeabi-v7a | 4002 | [32位ARM](../build_c/releases/local-playback-3.0.2/kuzi-music-3.0.2-armeabi-v7a-test-signed.apk) |
| x86_64 | 7002 | [x86_64](../build_c/releases/local-playback-3.0.2/kuzi-music-3.0.2-x86_64-test-signed.apk) |

三包复用本机历史测试证书，SHA-256为 `2E679F1D49E99D31E178B67B816100758C080CF76CB319C2CA05B5932573517D`，可覆盖同证书测试版；未知正式发行证书，正式发行需要原证书重新签名。

包SHA-256与详细验证字段见同目录 `SHA256SUMS`、`apk-verification.json`。日志为 `tmp/local-parser-final-regression.log`、`tmp/local-package-node-final.log`、`tmp/local-package-server-deploy.log`、`tmp/local-package-publish.log`、`tmp/local-playback-build/build-final.log`。

未经验证项：本机 `adb devices` 无连接，未做Android设备上的原生CPU/内存自检、实际音频解码与发声；未做iOS原生构建。Windows/Apple当前使用编译五源，动态脚本更新仅适用于具备原生安全预算的Android环境。

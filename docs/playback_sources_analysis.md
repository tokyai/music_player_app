# 播放音源分析与接入边界

本文记录 `tmp/yinyuan` 中音源脚本的静态分析结果，以及 APP 当前采用的
播放解析契约。脚本只作为分析依据，APP 不会在运行时执行这些 JavaScript；
运行时请求由 Dart 服务按明确的 HTTP 契约发出。

## 1. 脚本清单

目录内共有 8 个音源文件，其中独家 V5 的两个文件内容相同，实际为 7 份独立音源；
另有一个 `_probe.js` 分析工具。确认脚本来源不等于确认其中所有后端当前可用。

| 文件 | 主要平台 | 请求/鉴权特征 | 音质与回退特征 | APP 状态 |
| --- | --- | --- | --- | --- |
| `独家音源V5.js` | 多平台（脚本内动态决定） | 高度混淆；内置 `SERVER_SCRIPT_CONFIG`、API Key、签名盐和指纹；包含 AES/MD5 逻辑 | 后端路由和字段需要运行时解混淆才能稳定确认 | 未直接接入 |
| `lx-music-source-v5.js` | 与上一文件相同 | 与 `独家音源V5.js` SHA-256 相同，是重复副本 | 同上 | 未重复接入 |
| `屿溪-终章.js` | 多平台，含咪咕 | 高度混淆；文件注释明确要求私下获取接口并加密 URL | 支持多档母带/咪咕 24-bit，但接口地址被隐藏 | 未接入 |
| `墨澜音乐源v2.3.0.js` | 网易云、QQ、酷我、酷狗、咪咕 | 多个第三方后端；支持 Cookie；网易 EAPI AES；含 MD5/SHA-256、动态请求参数 | 按平台和 Cookie 动态声明音质；有多级平台/API 回退 | 未整体接入 |
| `HYWmusic_beta_公益测试.js` | 网易云、QQ、酷狗、酷我、咪咕 | `GET /api/music/url`；`X-Card-Key` 和 query `key`；固定公益服务地址 | 每平台声明独立音质列表；返回 `code=200` 与 URL | 已接入 |
| `K×H测试 v1.7.17.js` | 网易云、QQ、酷我、酷狗、咪咕 | 多组 API；部分端点带 Cookie/Key；含 AES/编码恢复逻辑 | 音质降级链逐档尝试；同组 API 并行竞速 | 未接入 |
| `lx-玉宁熙V1.2.2.js` | 多平台 | 关键 URL、Key、参数经混淆/加密；依赖发行版或用户 API Key | 有平台专属音质和降级逻辑，但端点不稳定 | 未接入 |
| `xinghai-music-sourcev2.3.13.js` | 网易云、QQ、酷狗、酷我、咪咕 | `GET /lx/api/`；动态 Base64 `X-Token`；`X-Client`；可先请求公网 IP；可选酷我解密代理 | 网易/QQ/酷狗可到高音质；GD Hi-Res 失败时降 FLAC | 已接入（当前 APP 三平台子集） |
| `_probe.js` | 不是音源 | 本地静态探针，替换 `lx.request`，只记录 URL/方法/头/体，不联网 | 用于复现初始化声明和请求契约 | 仅分析工具 |

说明：上述“未接入”不是遗漏。它们要么依赖无法在 APP 配置页安全表达的签名/加密协议，
要么包含私有凭据、私有服务或无界并发回退。直接搬入会增加请求放大、凭据泄露和维护风险。

## 2. 已确认的接口方式

### HYWmusic

- 当前依据为 [官方发布库 v1.1.0](https://github.com/Macrohard0001/HYWmusic_source/releases/tag/v1.1.0)，已经使用该公开发行版的更新公益配置。
- 入口：`GET {API_BASE}/api/music/url`。
- 主要参数：`source`、`platform`、`songId`、`songmid`、`quality`；酷狗额外传
  `hash`/`mainHash`；有元数据时传歌曲名、歌手、专辑、专辑 ID 和时长。
- 鉴权：同时支持 query `key` 和请求头 `X-Card-Key`；中文卡密只放入已编码的 query，ASCII 卡密同时发送请求头。所有卡密都拒绝换行和控制字符。
- 播放和探测沿用发布脚本的 `lx-music-request/1.0.0` 回退 User-Agent。
- 响应：`code=200` 时从 `url`/`data` 提取播放地址。
- 当前公益版支持 QQ、网易云，最高声明 `flac24bit`，高档音质映射到该值；公益版暂停酷狗支持，会在请求前明确报告。不使用公益预置配置的独立服务和用户卡密保留原有音质及酷狗解析契约。

### 星海

- 当前依据：官方发布页的 [v3.2.20 脚本](https://zrcdy.dpdns.org/lx/xinghai-music-sourcev3.2.20.js)，发布于 2026-11-17。
- 默认入口：`GET https://yy1.zddyr.top/lx/api/`，参数为 `source`、`songmid`、`quality`。
- QQ/网易云补充传歌曲元数据；酷狗传 `hash`、`mainHash` 和可用的 `albumId`。
- 令牌必须由同目录 `GET token.php?device_id=...` 签发；服务端自 2026-11 起拒绝旧的本地 Base64 Token。
- 请求头为 `X-Token`、`X-Client`、`User-Agent`；填写授权卡密时附加 `X-License`。
- 官方脚本明确规定 QQ 等认证线路需要有效授权卡密；未填卡密与服务拒绝授权分别报告，授权失败不会刷新令牌或重复降音质请求。
- 令牌请求只保留一个进行中的请求，最多等待 3 秒、响应最多 64 KB，成功结果缓存 4 分钟。
  切歌取消旧歌曲的等待；改配置和关闭服务会取消底层请求，迟到结果不能覆盖新配置。
- 服务明确返回 `tk_mismatch`、`untrusted-token` 或 `tk_error` 时，只刷新并重试一次。
- 配置页移除了旧的 IP 查询输入项；旧备份的 `xinghaiIpUrl` 字段仍可读取，解析流程不再调用它。
- APP 当前支持三平台子集；返回的已知加密音频会拒绝进入原生播放器，并由自动模式继续降低音质。

### GDStudio

- 入口：`GET {URL}/api.php`，参数为 `types=url`、`source`、`id`、`br`。
- [公开接口说明](https://music-api.gdstudio.xyz/api.php) 当前仅开放网易云、Joox 和 B站，QQ/酷狗不能直接传自己的 ID。
- 网易云沿用原 ID；QQ/酷狗先通过 `types=search&source=netease` 搜索，最多检查 20 条结果，复用既有同曲匹配器。
  匹配分数至少 90，要求曲名和歌手同时命中；已有时长时排除相差超过 10 秒的版本。缺少时长的返回结果依赖曲名和歌手核对。
- 一次播放解析最多缓存一个匹配 ID 和四个已尝试码率，降音质时复用；解析结束、切歌、改配置和关闭服务时释放。原平台的搜索结果、队列和收藏身份保持不变。
- 网易云附加 `use_xbridge3`、`loader_name`、`need_sec_link`、`sec_link_scene`、`theme`。
- 码率映射：`128k -> 128`、`320k -> 320`、`flac -> 740`、`hires -> 999`。
- `999` 请求在可通过降档恢复的错误下只回退一次 `740`；外层不会重复已经尝试的码率。沿用官方脚本的有界降档行为，503/504 不等同于所有音质停服；网络、鉴权和取消错误不做音质重试。

### ChKSz 与 QingMusic

- ChKSz 默认直连 `https://api.chksz.com`，沿用三平台接口及原 API Key；Key 为空时自动模式跳过该源。
- QingMusic 参考 [README](https://github.com/kejichangqing/QingMusic) 的 [当前配置](https://13413.kstore.vip/QingMusic/music.json)
  和 [v1.4.1 最新包](https://github.com/kejichangqing/QingMusic/releases/tag/v1.4.1)。README 明确说明不再提供内置音源，支持导入自行收集的配置。
- 已静态核对最新包的 Hermes v96 业务字节码及 Android 清单，客户端参数为 `qingmusic-android`、版本 `1.4.1`、版本码 `25`、包名 `com.qingmusic.changqing`。清单及业务包均校验 ZIP 大小和 CRC，没有安装或执行第三方 APK。
- `buildMusicGatewayAuthHeaders` 将客户端 ID、毫秒时间戳、16 字节随机 nonce、请求方法、URL 路径和请求体 SHA-256 用换行拼接，再计算 HMAC-SHA256，输出十六进制 `X-Qing-Sign`。query 不参与路径签名。
- 包内 `/v1/gateway/ticket` 会签发匿名短期票据；本次已核对取票成功，并实测仅使用每次请求的签名即可解析网易云、QQ、酷狗。当前接入使用已验证的请求签名，每个 API 实例只保存一个匿名设备标识。
- 签名只发送到两个已确认的官方 HTTPS `resolve-url` 入口；自定义 URL 继续原来的 JSON POST 契约，不附带官方认证头。签名算法复用已有 `crypto` 依赖，固定参数摘要通过独立 Node 实现交叉验证。
- 网易云 Hi-Res、高清环绕、超清母带以及 QQ 母带参数与当前配置对齐。认证失效会明确提示更新音源；已声明的加密流（含 CENC）会在进入原生播放器前拒绝，并由自动模式继续降档。

## 3. 与 APP 现有解析方式的差异

| 维度 | 原有 APP | 当前备用源实现 |
| --- | --- | --- |
| 选择 | 默认单一 ChKSz/QingMusic 分支 | 每个平台可手动选源或选择自动备用 |
| 回退 | 失败后按旧分支兜底 | 主组（ChKSz/QingMusic/HYW/星海）并行竞速；主组全失败后进入 GDStudio；音质失败后最多尝试无损、320k、标准档；明确停服、卡密过期或网络不可达时，本次解析不再重复请求该源 |
| 并发 | 个别旧路径可能重复请求 | 自动播放主组最多 4 源并行竞速；落选请求会中止底层 HTTP，单次 HTTP 总时限 7 秒，自动解析总时限 20 秒，手动解析总时限 14 秒 |
| 输入 | 主要使用平台 ID | 备用源额外传歌曲名、歌手、专辑、专辑 ID、时长及酷狗 hash |
| 响应校验 | 主要检查 HTTP/业务码 | 限制 JSON 响应最大 5 MB，并拒绝空或非 HTTP(S) 播放地址 |
| 生命周期 | 旧请求由播放请求序号隔离 | 每次切源前检查取消；Provider/API close 后拒绝延迟解析 |
| 配置 | API Key 单独配置 | URL、启停、Card Key、X-Client、设备 ID 可编辑并持久化 |

## 4. APP 中的配置与回退

配置入口：`设置 → 播放与音质 → 备用源接口配置`。

ChKSz 的 API Key 在该页 ChKSz 项下的“API 配置”中独立保存，保留手机扫码输入及获取说明；
已有密钥沿用原存储，不受“恢复 JS 默认值”影响。

自动模式只会使用配置页勾选的接口（ChKSz 还要求已填写 API Key）。配置页提供单源和批量
连接、鉴权和响应速度探测；HTTP 200 中的明确业务错误也会显示为失败，网络可达但业务失败以橙色显示。
探测不保证某首歌曲一定有可播放地址。批量探测最多同时运行 3 个请求，播放竞速最多同时运行主组的 4 个请求。
没有 API Key 的 ChKSz 不会发送探测请求。关闭页面时取消正在进行的探测，并停止派发后续请求。
编辑配置会清除旧的探测结果，测试期间锁定输入，避免显示与当前字段不一致的响应状态。

可编辑字段：

- 各源启用状态；
- ChKSz 基础 URL、API Key；
- QingMusic `resolve-url` 地址；
- HYW 基础 URL、Card Key；
- 星海聚合 URL、X-Client、设备 ID、授权卡密；
- GDStudio `api.php` 地址。

页面显示的默认值来自 `PlaybackSourceConfig.defaults()`，对应脚本中已确认的预置值；
“恢复 JS 默认值”只恢复编辑草稿，必须点击保存才会写入配置。

配置存储键为 `playback_source_config_v1`，播放器备份 JSON 同时包含
`playbackSourceConfig`。没有该字段的旧备份保持当前备用源配置；导入前会校验 URL、长度和字段类型，
不会用无效配置覆盖当前有效值。

读取已保存设置和旧备份时，仅将随应用发布的旧 ChKSz 中转地址、星海域名、旧版 X-Client 和旧 IP 默认值迁移到当前默认值。
自定义入口、启停状态、API Key、Card Key 和设备 ID继续保留；新增 `xinghaiLicenseKey` 字段接受可选的单行 ASCII 值并参与备份校验。
HYW 仅在地址与旧公益预置匹配时迁移旧公益卡密，保留用户的独立服务和个人卡密；不会改变原有启停状态。

## 5. 后续新增音源时的接入检查

1. 先静态核对初始化声明、HTTP 方法、URL、请求头、请求体和响应形状。必须动态分析时使用隔离的离线桩；现有 `_probe.js` 暴露了 Node `require`，不是安全沙箱，不能直接执行来源不明脚本。
2. 将每个必填凭据定义成配置字段，并设置长度/协议校验；不要把运行时密钥硬编码到 Dart 请求日志。
3. 为平台 ID、音质映射、空 URL、HTTP 错误和响应体大小增加单元测试。
4. 将新源加入自动链前，确定单次超时、最大尝试次数和取消检查点；禁止无界并发竞速。
5. 同步更新横屏配置页和 `640x360`、`1280x800` Widget 测试。

## 6. 安全与可用性备注

- `tmp/yinyuan` 中的 API Key、Card Key、签名盐和 Cookie 只能视为公开脚本内容，不能当作长期秘密。
- 默认值中仍有脚本原本的 HTTP 地址；生产环境应优先改成 HTTPS 或自有可信中转。
- 第三方服务可能随时变更、限流或失效；自动模式会继续尝试下一个已启用源，并在全部失败时给出统一错误。
- APP 正式范围保持 QQ、网易云、酷狗。酷我、咪咕以及需要私有解密代理的分支留在分析文档中，待有明确稳定契约后再单独评审接入。

## 7. 本次复核的验证边界

- 自动竞速和配置探测分别覆盖取消、迟到响应、超大响应、持续慢速回包、最高档降级和重复触发。
- 自动模式拿到 URL 后如果播放器加载或播放中途失败，会废弃当前 URL，排除已失败源并重新走同音质竞速；最多恢复 3 次，之后才显示错误，不会自动跳到下一首。
- 播放页歌词工具栏的“音源”按钮可以只为当前歌曲临时指定一个已启用源，切换会绕过本地缓存且不写入平台默认设置；临时结果也不会写入长期音频缓存或复用 URL 缓存。换歌、同曲下一次播放恢复原平台设置。
- 配置拒绝请求头换行/非 ASCII 值、内嵌账号密码和 fragment URL；基础 URL 的路径前缀和 query 参数会被保留。
- Widget 回归覆盖 `640x360`、`1280x800`、手机竖屏及旋转过程。迷你播放器加载中保留切歌按钮，极窄歌曲行保留收藏与入队操作。
- 测试使用受控 HTTP 响应验证协议和异常路径，不代表所有第三方服务在线，亦不替代车机真机的解码、网络和声音播放验证。

## 8. 2026/11/18 初次复核结果（后续修复见第 9 节）

作者：SHIXIAOYANG。

| 音源 | 实测结果 | 当前处理 |
| --- | --- | --- |
| ChKSz | 旧中转连接超时；官方 HTTPS 地址返回有效的 API Key 鉴权错误 | 更新默认值并迁移旧默认地址；使用用户原有有效 API Key |
| QingMusic | 原入口和备用域名均要求 App 签名及票据；取票接口无签名时返回 401 | 明确升级/授权要求；独立授权解析接口仍可配置；官方网关尚需合法授权方式 |
| HYWmusic | 原公益 Card Key 返回 HTTP 401，消息为“卡密已过期” | 明确提示更新 Card Key，并避免将 HTTP 200 业务错误误报为正常 |
| 星海 | 旧域名 DNS 失败；新域名成功签发 `xh3.` 令牌，网易云与酷狗返回 MP3 地址 | 更新域名并采用服务器令牌；QQ 上游暂时返回 401，继续走备用源 |
| GDStudio | 网易云解析有效；QQ、酷狗直接请求返回“不支持 source” | 网易云直取，QQ/酷狗按元数据匹配网易云备用歌曲 |

已对 GD 网易云、星海网易云和星海酷狗的播放地址请求 512 字节：三者均返回 HTTP 206；文件头分别为 FLAC `fLaC` 和 MP3 `ID3`。
本次只分析最新 APK 中的业务包，分段下载后校验 ZIP 目录大小及 CRC，未安装或运行第三方 APK。

执行入口为 `PlayerProvider._resolveSongDetail → ApiService.resolvePlayback`；主流程为选择启用源、按组竞速、识别源级故障、按有界音质回退。
GD 的跨平台匹配位于 `_gdStudioMatchedId`；星海取票位于 `_requestXinghaiToken`，失效刷新位于 `_xinghaiNeedsTokenRefresh`。

断点建议：

- `ApiService._requestXinghaiToken`：观察请求地址、业务码及令牌是否存在；不要记录令牌或授权卡密。
- `ApiService._gdStudioMatchedId`：观察候选歌曲元数据、`match` 和 `_gdMatchedId`，核对是否为同一首歌曲。
- `ApiService.resolvePlayback`：观察 `candidateQuality`、`unavailableSources` 和最终 `detail.playbackSource`。

回归测试项包括默认配置迁移、授权卡密校验/持久化、服务器令牌复用与刷新上限、64 KB 响应限制、取消及迟到响应、HTTP 200 业务错误、加密音频降级、同曲匹配和 `640x360` / `1280x800` 配置页旋转及退出。

本次变更清单：

| 文件 | 操作 | 说明 |
| --- | --- | --- |
| `lib/services/api_service.dart` | 修改 | 星海服务器令牌、GD 同曲匹配、源级错误跳过、业务错误探测及加密音频拦截 |
| `lib/models/playback_source_config.dart` | 修改 | 更新预置地址、迁移旧默认值、增加星海授权卡密及探测业务错误状态 |
| `lib/screens/playback_source_config_screen.dart` | 修改 | 星海卡密输入、授权反馈，移除已不再使用的 IP 查询输入并保留旧配置数据 |
| `lib/screens/settings_screen.dart` | 修改 | 更新各源的实际接入方式说明 |
| `test/models/song_test.dart` | 修改 | 默认值迁移、自定义配置保留及授权卡密校验 |
| `test/services/api_service_test.dart` | 修改 | 更新 GD 网易云备用请求契约 |
| `test/services/playback_resilience_test.dart` | 修改 | 更新星海取令牌及异常回退夹具 |
| `test/services/playback_source_repair_test.dart` | 新增 | 令牌复用/刷新/取消、业务错误、加密音频和同曲匹配回归 |
| `test/landscape_layout_test.dart` | 修改 | 卡密与业务错误反馈的横屏旋转、页面退出及迟到响应回归 |
| `README.md`、本文 | 修改 | 更新音源状态、接入依据及验证记录 |

验证环境为获准安装的 Flutter **3.41.6** / Dart **3.11.4**。现有锁定依赖已恢复，没有修改 `pubspec.yaml` 或 `pubspec.lock`，没有新增项目依赖。

下列命令在项目根目录运行；本机通过 SDK 内的 `dart.exe flutter_tools.snapshot --suppress-analytics --no-version-check` 调用相同 Flutter 命令，避开 Windows 启动批处理的问题。

```powershell
# 服务、模型和协议：64 项全部通过。
flutter test --no-pub test/models/song_test.dart test/services/api_service_test.dart test/services/playback_resilience_test.dart test/services/playback_source_repair_test.dart

# 播放器、横屏、配置、备份和有界 HTTP：149 项全部通过。
flutter test --no-pub test/landscape_layout_test.dart test/playback_source_api_key_test.dart test/player_source_recovery_test.dart test/player_queue_entrypoints_test.dart test/services/backup_service_test.dart test/services/bounded_http_response_test.dart

# 修改文件的静态检查：退出码 0，无 error/warning，29 条存量 info。
flutter analyze --no-pub --no-fatal-infos lib/services/api_service.dart lib/models/playback_source_config.dart lib/screens/playback_source_config_screen.dart lib/screens/settings_screen.dart test/models/song_test.dart test/services/api_service_test.dart test/services/playback_resilience_test.dart test/services/playback_source_repair_test.dart test/landscape_layout_test.dart

# 本次临时真实网络验证：4 项全部通过，不加入日常离线测试。
flutter test --no-pub tmp/source_repair_20261118/live_source_smoke_test.dart
```

受控测试覆盖错误、取消、重复触发和超大响应；横屏测试同时核对卡密保存、授权失败反馈、收藏、播放和队列操作。
真实网络样本使用 Beyond《海阔天空》的曲名、歌手、专辑和时长，依次核对星海网易云/酷狗，以及 GDStudio 为 QQ/酷狗匹配网易云的解析流程。
四个样本均返回非空播放 URL，使用其播放请求头并携带 `Range: bytes=0-511` 后得到 HTTP 206、512 字节及 MP3 `ID3` 文件头。
这验证了解析和音频读取；未做 Android APK 构建或真机声音/完整音频解码验证，剩余步骤是在目标设备安装项目构建并播放、切歌及旋转。

测试 JSON 报告保存在 `tmp/source_repair_20261118/` 的 `service-tests.json`、`widget-player-tests.json` 和 `live-source-tests.json`。
`pubspec.lock` 的 SHA-256 保持为 `98370FB81E9E31578C5F4666145A1D66A60FC9DF1F9277ED736D883B979E6ED8`。

不确定项：QingMusic 官方网关仍缺少可授权的第三方签名/票据接入方式；HYW 原公益卡密已过期，需有效新卡密；ChKSz 未提供有效 API Key 的实播样本；星海 QQ 上游本次仍返回 401。
GD 跨平台匹配仅在能确认曲名、歌手及已有时长相符时使用备用歌曲；第三方在线状态和完整音频可播放性仍以目标设备实播为准。

## 9. 2026/11/18 剩余限制修复

本节汇总当前修复与最终验证结果；第 8 节保留初次复核时的历史状态。作者：SHIXIAOYANG。

QingMusic 最新包的授权由客户端请求签名和可选匿名票据组成，不需要把个人 API Key 填入 QingMusic 配置页。
已经确认官方网关的签名解析返回 HTTP 201、`code=0`；项目实际 `ApiService` 对网易云、QQ、酷狗的解析和 512 字节 MP3 读取均通过。
HYW 更新公益卡密后网易云解析及 MP3 读取通过；QQ 曾返回有效播放地址，但直接读取出现超时，本轮系统代理复验又在解析阶段返回 HTTP 500，尚未验证 QQ 的完整读取链路。
GDStudio 的 QQ/酷狗同曲匹配均已取得 MP3；本次也观察到间歇性 503，保留官方支持的有界音质回退。

本轮变更：

| 文件 | 操作 | 说明 |
| --- | --- | --- |
| `lib/services/qing_gateway_auth.dart` | 新增 | 最新包签名、匿名设备标识、官方入口限制及请求头校验 |
| `lib/services/api_service.dart` | 修改 | 接入签名、更新 HYW 公益协议与 User-Agent、细分授权失败、拦截 CENC、避免 GD 重复码率请求 |
| `lib/models/playback_source_config.dart` | 修改 | 仅迁移旧公益卡密，保留个人配置，支持 HYW Unicode query 卡密 |
| `lib/screens/playback_source_config_screen.dart`、`lib/screens/settings_screen.dart` | 修改 | 显示当前源状态及 QQ 卡密要求 |
| `test/services/qing_gateway_auth_test.dart` | 新增 | 独立固定签名样例、路径/请求体绑定、可信入口和非法请求头回归 |
| `test/services/playback_source_repair_test.dart`、`test/models/song_test.dart`、`test/landscape_layout_test.dart` | 修改 | 公益配置迁移、授权反馈、Unicode 卡密、CENC、GD 码率复用和横屏回归 |
| `README.md`、本文 | 修改 | 更新当前授权方式和验证记录 |

执行入口仍为 `PlayerProvider._resolveSongDetail → ApiService.resolvePlayback`。QingMusic 的签名经 `_qingAuthHeaders → QingGatewayAuth.headersFor` 附加到 JSON POST；
HYW 使用 `_hywPlaybackQuality` 和 `_ensureHywPlatformSupported`；GD 每轮最多保留四个已尝试码率，初始化、取消、结束或改配置后清除。

定向服务测试 **81 项**、最终播放器和 Widget 回归 **149 项**全部通过，共 **230 项**。包含固定时间戳与 nonce 的独立 HMAC 样例、取消和迟到响应、重复操作、响应大小限制、加密流拦截，以及 `640x360` / `1280x800` 的配置保存、旋转、收藏、播放和队列操作。修改文件静态检查无 error/warning，29 条存量 info。复验命令：

```powershell
flutter test --no-pub test/models/song_test.dart test/services/api_service_test.dart test/services/playback_resilience_test.dart test/services/playback_source_repair_test.dart test/services/qing_gateway_auth_test.dart
flutter test --no-pub test/landscape_layout_test.dart test/playback_source_api_key_test.dart test/player_source_recovery_test.dart test/player_queue_entrypoints_test.dart test/services/backup_service_test.dart test/services/bounded_http_response_test.dart
$env:SOURCE_REPAIR_USE_PROXY = '1' # 本机复验临时使用已有系统代理。
flutter test --no-pub tmp/source_repair_remaining_20261118/live_sources_test.dart
```

真实网络验证以来源对应的平台 ID 为输入，GD 额外使用 Beyond《海阔天空》元数据进行同曲匹配。
期望得到非空 URL，读取 `Range: bytes=0-511` 后得到 HTTP 206、512 字节及有效音频文件头；测试始终有 1 KB 读取上限和资源清理。
本机通过系统代理联网；临时脚本的 `SOURCE_REPAIR_USE_PROXY=1` 仅用于复核这一环境因素，不更改应用网络配置。

最终真实网络复验为 **8/9 通过**。所有通过样本均得到 HTTP 206、512 字节和 MP3 `ID3` 文件头：

| 音源 | 平台 | 样本数 | 结果 |
| --- | --- | --- | --- |
| QingMusic | 网易云、QQ、酷狗 | 3 | 解析及音频读取通过 |
| HYWmusic | 网易云 | 1 | 解析及音频读取通过 |
| 星海 | 网易云、酷狗 | 2 | 解析及音频读取通过 |
| GDStudio | QQ、酷狗 | 2 | 同曲匹配及音频读取通过 |
| HYWmusic | QQ | 1 | 解析返回 HTTP 500；保留服务侧可用性限制 |

JSON 报告位于 `tmp/source_repair_remaining_20261118/`：`service-tests.json`、`widget-player-final-tests.json` 和 `live-proxy-tests.json`。联网测试的退出码为 1，对应上述 HYW QQ 样本；受控服务与 Widget 测试退出码均为 0。

断点建议：

- `QingGatewayAuth.headersFor`：观察路径、时间戳、nonce、`bodyHash` 和签名是否存在，不记录客户端参数或用户凭据。
- `ApiService.hywMusic`：观察标准化音质、HTTP 状态及配置是否属于公益预置。
- `ApiService.gdStudioMusic`：观察 `bitrate`、`_gdAttemptedBitrates` 和取消状态，确认降档未重复发送。

已获准安装 JDK 17、Android SDK 和 NDK；官方工具包均通过摘要校验，四个 media-kit JAR 均通过项目规定的 MD5 校验。
现有依赖通过 `flutter pub get --offline --enforce-lockfile` 恢复，锁文件 SHA-256 与第 8 节一致。Android release 分 ABI 构建沿用项目 CI 的临时测试签名流程。

Android 构建已完成。首次 `flutter build apk --release --split-per-abi --no-pub` 在 JDK 17 下遇到现有 Android Lint 的 `List.removeLast()` 运行时错误；本机 IntelliJ IDEA 的 JBR 25 可运行该检查，但不包含 `jlink`。
最终复用 JBR 25 运行 Gradle/Lint，用已安装的完整 JDK 17 作为 Java 编译工具链。临时初始化脚本为 `tmp/source_repair_remaining_20261118/source-repair-java17.init.gradle`，只匹配当前 Android 工程。
根据 Flutter SDK 实际后端参数执行完整 `assembleRelease`，退出码 0，`BUILD SUCCESSFUL in 1m 4s`，850 个任务中 129 个执行、721 个复用缓存。`app:lintVitalAnalyzeRelease`、`lintVitalReportRelease` 和 `lintVitalRelease` 均通过。

本机的实际恢复构建命令如下；重复构建前须先按 README 配置相应签名证书：

```powershell
$env:JAVA_HOME = 'D:\Program Files\JetBrains\IntelliJ IDEA 2026.2.4\jbr'
Push-Location android
& "$env:JAVA_HOME\bin\java.exe" -cp gradle/wrapper/gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain `
  --init-script ../tmp/source_repair_remaining_20261118/source-repair-java17.init.gradle `
  -Porg.gradle.java.installations.paths=E:/work/tools/music-player-repair/java17/jdk-17.0.21+9 `
  -Porg.gradle.java.installations.auto-download=false `
  -Ptarget-platform=android-arm,android-arm64,android-x64 -Ptarget=lib/main.dart `
  -Pbase-application-name=android.app.Application -Pdart-obfuscation=false `
  -Ptrack-widget-creation=false -Ptree-shake-icons=true -Psplit-per-abi=true assembleRelease
Pop-Location
```

构建日志为 `apk-build-toolchain-console.txt`；签名、ABI 和 SHA-256 汇总为 `apk-verification.json`，均位于上述临时报告目录。没有新增安装 JDK 21，也没有修改项目框架版本。
三份产物通过 Android build-tools 37 的 `apksigner verify --verbose --print-certs` 和 `aapt2 dump badging`；APK v2 签名证书与本次测试 keystore 一致。
版本名 `2.9.17`，最低 Android API 24，目标 API 34，包名 `com.example.music_player_app`。分 ABI 版本码沿用 Flutter 的既有偏移规则。

| APK（测试签名） | 版本码 | 大小（字节） | SHA-256 |
| --- | --- | --- | --- |
| [arm64-v8a](../build_c/app/outputs/flutter-apk/app-arm64-v8a-release.apk) | 4917 | 33,701,795 | `1B659BA0061CCC97A67A42EED0F476B22B40D14F550559381DE103D6605C0A8D` |
| [armeabi-v7a](../build_c/app/outputs/flutter-apk/app-armeabi-v7a-release.apk) | 3917 | 32,340,881 | `3BF3B74B75A3CF69B6F4891EFED1F8688909AF9A6F6F027CBFDA11C42B0F0A37` |
| [x86_64](../build_c/app/outputs/flutter-apk/app-x86_64-release.apk) | 6917 | 35,894,692 | `C6416813871A6AF3455919D3FD62A9B03DCAE5BA1DAD4172C87E37B16BCC8547` |

本次临时 `android/key.properties` 在验证完成后清除，测试 keystore 保留在本机工具目录。正式发行须使用原发布证书；以上产物用于测试验证。

剩余不确定项：HYW QQ 本次返回 HTTP 500，HYW 公益版暂停酷狗；ChKSz 的有效个人 API Key 和星海 QQ 的个人授权卡密不在公开发行脚本中，相关默认字段为空。
`adb devices` 未发现连接设备，**未做真机声音播放和完整音频解码验证**。剩余步骤是在目标测试设备安装对应 ABI 的测试 APK，实际播放三平台歌曲、切歌、切源和旋转；第三方在线状态仍以该设备实测为准。

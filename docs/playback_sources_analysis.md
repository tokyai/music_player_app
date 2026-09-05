# 播放音源分析与接入边界

本文记录 `tmp/yinyuan` 中音源脚本的静态分析结果，以及 APP 当前采用的
播放解析契约。脚本只作为分析依据，APP 不会在运行时执行这些 JavaScript；
运行时请求由 Dart 服务按明确的 HTTP 契约发出。

## 1. 脚本清单

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

- 入口：`GET {API_BASE}/api/music/url`。
- 主要参数：`source`、`platform`、`songId`、`songmid`、`quality`；酷狗额外传
  `hash`/`mainHash`；有元数据时传歌曲名、歌手、专辑、专辑 ID 和时长。
- 鉴权：同时支持 query `key` 和请求头 `X-Card-Key`。
- 响应：`code=200` 时从 `url`/`data` 提取播放地址。
- APP 当前只映射 QQ、网易云、酷狗；酷我和咪咕不在正式产品范围内。

### 星海

- 入口：`GET {URL}/lx/api/`，参数为 `source`、`songmid`、`quality`。
- QQ/网易云补充传歌曲元数据；酷狗传 `hash`、`mainHash` 和可用的 `albumId`。
- 请求头：`X-Token`、`X-Client`、`User-Agent`。Token 是包含设备 ID、IP、时间戳和随机数的
  Base64 JSON，缓存 5 分钟。
- IP 查询是单飞请求，超时或失败时使用 `0.0.0.0`，不会阻塞后续解析。
- 脚本中的酷我加密解密代理和 ChKSz 私有分支没有接入，因为 APP 不支持酷我，且需要额外私有服务。

### GDStudio

- 入口：`GET {URL}/api.php`，参数为 `types=url`、`source`、`id`、`br`。
- 网易云附加 `use_xbridge3`、`loader_name`、`need_sec_link`、`sec_link_scene`、`theme`。
- 码率映射：`128k -> 128`、`320k -> 320`、`flac -> 740`、`hires -> 999`。
- 网易云 Hi-Res 请求失败时只再尝试一次 `740`，避免无界重试。

### 现有 ChKSz 与 QingMusic

- ChKSz 沿用 APP 原有三平台接口和 API Key；Key 为空时自动模式跳过该源。
- QingMusic 使用 APP 已有的统一 JSON POST 契约，并保留服务返回的播放请求头。

## 3. 与 APP 现有解析方式的差异

| 维度 | 原有 APP | 当前备用源实现 |
| --- | --- | --- |
| 选择 | 默认单一 ChKSz/QingMusic 分支 | 每个平台可手动选源或选择自动备用 |
| 回退 | 失败后按旧分支兜底 | 主组（ChKSz/QingMusic/HYW/星海）并行竞速；主组全失败后进入 GDStudio；每档失败最多自动降 3 档 |
| 并发 | 个别旧路径可能重复请求 | 自动播放主组最多 4 源并行竞速；落选请求可取消，单源解析超时约 7 秒 |
| 输入 | 主要使用平台 ID | 备用源额外传歌曲名、歌手、专辑、专辑 ID、时长及酷狗 hash |
| 响应校验 | 主要检查 HTTP/业务码 | 限制 JSON 响应最大 5 MB，并拒绝空或非 HTTP(S) 播放地址 |
| 生命周期 | 旧请求由播放请求序号隔离 | 每次切源前检查取消；Provider/API close 后拒绝延迟解析 |
| 配置 | API Key 单独配置 | URL、启停、Card Key、X-Client、设备 ID 可编辑并持久化 |

## 4. APP 中的配置与回退

配置入口：`设置 → 播放与音质 → 备用源接口配置`。

自动模式只会使用配置页勾选的接口（ChKSz 还要求已填写 API Key）。配置页提供单源和批量
连通性/响应速度探测；探测结果只表示端点是否返回 HTTP 响应，不代表某首歌曲一定有版权或
可播放地址。批量探测最多同时运行 3 个请求，播放竞速最多同时运行主组的 4 个请求。

可编辑字段：

- 各源启用状态；
- ChKSz 基础 URL；
- QingMusic `resolve-url` 地址；
- HYW 基础 URL、Card Key；
- 星海聚合 URL、公网 IP 查询 URL、X-Client、设备 ID；
- GDStudio `api.php` 地址。

页面显示的默认值来自 `PlaybackSourceConfig.defaults()`，对应脚本中已确认的预置值；
“恢复 JS 默认值”只恢复编辑草稿，必须点击保存才会写入配置。

配置存储键为 `playback_source_config_v1`，播放器备份 JSON 同时包含
`playbackSourceConfig`。没有该字段的旧备份仍按默认配置恢复；导入前会校验 URL、长度和字段类型，
不会用无效配置覆盖当前有效值。

## 5. 后续新增音源时的接入检查

1. 先用 `_probe.js` 或等价的离线桩确认初始化声明、HTTP 方法、URL、请求头、请求体和响应形状。
2. 将每个必填凭据定义成配置字段，并设置长度/协议校验；不要把运行时密钥硬编码到 Dart 请求日志。
3. 为平台 ID、音质映射、空 URL、HTTP 错误和响应体大小增加单元测试。
4. 将新源加入自动链前，确定单次超时、最大尝试次数和取消检查点；禁止无界并发竞速。
5. 同步更新横屏配置页和 `640x360`、`1280x800` Widget 测试。

## 6. 安全与可用性备注

- `tmp/yinyuan` 中的 API Key、Card Key、签名盐和 Cookie 只能视为公开脚本内容，不能当作长期秘密。
- 默认值中仍有脚本原本的 HTTP 地址；生产环境应优先改成 HTTPS 或自有可信中转。
- 第三方服务可能随时变更、限流或失效；自动模式会继续尝试下一个已启用源，并在全部失败时给出统一错误。
- APP 正式范围保持 QQ、网易云、酷狗。酷我、咪咕以及需要私有解密代理的分支留在分析文档中，待有明确稳定契约后再单独评审接入。

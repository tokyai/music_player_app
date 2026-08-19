# 库仔音乐账号服务

该目录包含账号 API、自动同步 API、PostgreSQL schema 和同源管理后台。管理后台由账号服务直接托管在 `/`，API 位于 `/api`。

## 启动

生产环境应在服务前配置 HTTPS 反向代理，容器默认只监听宿主机 `127.0.0.1:8787`。

```powershell
$env:POSTGRES_PASSWORD = '替换为强随机密码'
docker compose up -d --build
```

首次启动后，在容器中创建管理员：

```powershell
docker compose exec account-server node src/create-admin.mjs admin '至少10位的管理员密码'
```

然后打开 `https://你的域名/`。Flutter 登录页的服务器地址填写 `https://你的域名/api`；也可在构建或运行时使用：

```powershell
flutter run --dart-define=ACCOUNT_API_BASE_URL=https://你的域名/api
```

## 数据边界

云同步包含收藏歌曲、收藏歌单、播放历史、搜索历史和个性化设置。不上传 API Key、B站 Cookie、WebDAV 凭据、缓存文件、临时播放地址和悬浮窗权限。

用户状态为 `pending / active / disabled / deleted`。禁用或删除用户会立即撤销其所有会话；客户端下一次访问账号或同步接口时收到 `USER_DISABLED` 或登录过期响应。

## 数据库升级

全新数据库会由 compose 自动执行 `sql/001_schema.sql`。已有数据库应按编号手动执行尚未应用的 SQL，并在执行前备份：

```powershell
psql $env:DATABASE_URL -f sql/001_schema.sql
```

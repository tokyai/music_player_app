param(
    [string]$CredentialHelper = 'E:\work\tools\music-player-repair\runtime-ssh\ssh-readonly.ps1'
)

# 验证并发布独立音源服务，不编译客户端。SHIXIAOYANG，2026/11/20。
$ErrorActionPreference = 'Stop'
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$powershellPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $CredentialHelper -PathType Leaf)) {
    throw '未找到已有 SSH 凭据助手，请指定 CredentialHelper 路径'
}

function Invoke-PlaybackRemote {
    <# 使用已有受保护凭据执行脚本；Base64传输避免SSH助手丢失引号。 #>
    param([string]$Script)
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    $remoteCommand = 'printf %s ' + $encodedScript + ' | base64 -d | bash'
    & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $CredentialHelper -RemoteCommand $remoteCommand
    if ($LASTEXITCODE -ne 0) { throw '音源服务器发布步骤失败' }
}

Push-Location $workspaceRoot
try {
    # 先运行协议与异常回归，失败时不上传或重启线上服务。
    node --test server/playback/playback.test.mjs server/playback/front_proxy.test.mjs server/playback/package_updates.test.mjs
    if ($LASTEXITCODE -ne 0) { throw '音源服务测试失败，已停止发布' }
    $publishDirectory = Join-Path $workspaceRoot 'tmp/playback-publish'
    [IO.Directory]::CreateDirectory($publishDirectory) | Out-Null
    $archivePath = Join-Path $publishDirectory 'server.tar'
    & 'C:\Windows\System32\tar.exe' -cf $archivePath -C $workspaceRoot server/playback tools/install_playback_package.mjs tools/build_playback_package.mjs playback_package/sources.js
    if ($LASTEXITCODE -ne 0) { throw '服务端归档失败' }
    # 旧助手的上传范围限定为已废弃的目录；临时副本只授权新服务的归档路径。
    # 凭据仍从原目录解密，不复制密码、密钥或修改原助手。
    $helperText = [IO.File]::ReadAllText($CredentialHelper)
    $originalRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($CredentialHelper)).Replace("'", "''")
    $scopedHelper = Join-Path $publishDirectory 'ssh-helper.ps1'
    $helperText = $helperText.Replace('$taskRoot = $PSScriptRoot', ('$taskRoot = ' + "'$originalRoot'"))
    $helperText = $helperText.Replace('^/opt/kuzai-music-runtime/[a-zA-Z0-9_./-]+$', '^/opt/kuzai-music-api/[a-zA-Z0-9_-]+\.tar$')
    [IO.File]::WriteAllText($scopedHelper, $helperText, [Text.UTF8Encoding]::new($true))
    & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $scopedHelper -Action upload -LocalPath $archivePath -RemotePath /opt/kuzai-music-api/server.tar
    if ($LASTEXITCODE -ne 0) { throw '服务端上传失败' }

    # 仅替换本项目代码，复用已有镜像和TLS身份；服务器凭据文件不进入归档。
    Invoke-PlaybackRemote @'
set -eu
root=/opt/kuzai-music-api
test ! -L "$root"
test "$(readlink -f -- "$root")" = /opt/kuzai-music-api
test -f "$root/tls/server.key"
test -f "$root/tls/server.crt"
test -f "$root/server.env"
unit=/etc/systemd/system/juhe-hybrid.service
site_certs=/var/lib/juhe-hybrid/certs
test -f "$unit"
test ! -L "$unit"
test -r "$site_certs/fullchain.pem"
test -r "$site_certs/key.pem"
stage=$(mktemp -d "$root/staging.XXXXXX")
unit_snapshot=$(mktemp "$root/unit.XXXXXX")
cp -p "$unit" "$unit_snapshot"
front_existed=0
if docker inspect kuzai-music-front >/dev/null 2>&1; then front_existed=1; fi
deployment_started=0
code_replaced=0

# 停止的名字只来自本项目固定容器，防止重启共享应用。
stop_container() {
  case "$1" in kuzai-music-api|kuzai-music-front) ;; *) return 1 ;; esac
  if docker inspect "$1" >/dev/null 2>&1; then
    docker stop --timeout 25 "$1" >/dev/null
    docker rm "$1" >/dev/null
  fi
}
launch_api() {
  docker run -d --pull=never --name kuzai-music-api --restart unless-stopped --read-only --cap-drop=ALL --security-opt=no-new-privileges --memory=192m --cpus=1 --pids-limit=64 --user 1000:1000 --network host -e PORT=9443 -e LISTEN_HOST=127.0.0.1 -v "$root:/runtime:ro" --env-file "$root/server.env" node:24.21.0-bookworm-slim node --max-old-space-size=96 /runtime/server/playback/server.mjs >/dev/null
}
launch_front() {
  site_user=$(stat -c '%u:%g' "$site_certs")
  docker run -d --pull=never --name kuzai-music-front --restart unless-stopped --read-only --cap-drop=ALL --security-opt=no-new-privileges --memory=192m --cpus=1 --pids-limit=64 --user "$site_user" --network host -e PORT=8443 -e FRONT_TLS_CERT=/site-certs/fullchain.pem -e FRONT_TLS_KEY=/site-certs/key.pem -e MUSIC_API_CA=/runtime/tls/server.crt -v "$root:/runtime:ro" -v "$site_certs:/site-certs:ro" node:24.21.0-bookworm-slim node --max-old-space-size=64 /runtime/server/playback/front_proxy.mjs >/dev/null
}
# 发布失败时恢复本轮代码和原入口；首次接入失败也会把8443还给原站。
finish() {
  result=$?
  trap - EXIT
  if test "$result" -ne 0 && test "$deployment_started" = 1; then
    set +e
    stop_container kuzai-music-front
    stop_container kuzai-music-api
    if test "$code_replaced" = 1 && test -d "$root/previous-server"; then
      rm -rf --one-file-system -- "$root/server"
      mv "$root/previous-server" "$root/server"
    fi
    cp -p "$unit_snapshot" "$unit"
    systemctl daemon-reload
    systemctl restart juhe-hybrid.service
    launch_api
    if test "$front_existed" = 1; then launch_front; fi
    printf '发布失败，已执行原入口和代码恢复\n' >&2
  fi
  rm -rf --one-file-system -- "$stage"
  rm -f -- "$unit_snapshot" "$root/server.tar"
  exit "$result"
}
trap finish EXIT
tar -xf "$root/server.tar" -C "$stage"
# 文件发布测试仅在有上限的临时文件系统写入，线上目录保持只读。
docker run --rm --pull=never --network=none --read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m --cap-drop=ALL -v "$stage:/runtime:ro" node:24.21.0-bookworm-slim node --test /runtime/server/playback/playback.test.mjs /runtime/server/playback/front_proxy.test.mjs /runtime/server/playback/package_updates.test.mjs
test "$(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' kuzai-music-api)" = "$root"
if test "$front_existed" = 1; then
  test "$(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' kuzai-music-front)" = "$(printf '%s\n%s' "$root" "$site_certs")"
fi
deployment_started=1
stop_container kuzai-music-front
stop_container kuzai-music-api
if test -d "$root/server"; then
  rm -rf --one-file-system -- "$root/previous-server"
  mv "$root/server" "$root/previous-server"
fi
mv "$stage/server" "$root/server"
code_replaced=1
chown 1000:1000 "$root/tls/server.key"
chmod 600 "$root/tls/server.key" "$root/server.env"
if test ! -f "$root/juhe-hybrid.original.service"; then cp -p "$unit" "$root/juhe-hybrid.original.service"; fi
# 只改原站监听地址，保留原证书续期、80端口校验和全部参数。
python3 - "$unit" <<'PY'
import pathlib
import sys
unit = pathlib.Path(sys.argv[1])
text = unit.read_text(encoding="utf-8")
if text.count("-listen :8443") == 1:
    text = text.replace("-listen :8443", "-listen 127.0.0.1:8444")
    temporary = unit.with_suffix(".service.next")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(unit)
elif "-listen 127.0.0.1:8444" not in text:
    sys.exit("原站监听配置不符合已核对的部署结构")
PY
systemctl daemon-reload
systemctl restart juhe-hybrid.service
launch_api
launch_front
# 用正常证书验证检测API和原站两个入口，成功后才报告发布完成。
healthy=0
for attempt in 1 2 3 4 5 6 7 8; do
  if docker exec kuzai-music-front node -e 'const https=require("node:https"),tls=require("node:tls");Promise.all(["/music-player-api/health","/api/health"].map(path=>new Promise(resolve=>{const r=https.get({hostname:"127.0.0.1",port:8443,path,checkServerIdentity:(_host,cert)=>tls.checkServerIdentity("137.175.62.3",cert)},response=>{response.resume();resolve(response.statusCode===200);});r.setTimeout(3000,()=>r.destroy());r.on("error",()=>resolve(false));}))).then(results=>{process.exitCode=results.every(Boolean)?0:1;});'; then healthy=1; break; fi
  sleep 1
done
test "$healthy" = 1
printf 'API和原站TLS健康检查通过\n'
'@
    Write-Output '更新静态入口已发布并通过健康验证，解析包通过独立发布脚本更新'
} finally {
    Pop-Location
}

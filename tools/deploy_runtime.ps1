param(
    [Parameter(Mandatory=$true)][ValidateRange(1,999999999)][int]$Version,
    [string]$PrivateKeyFile='E:\work\tools\music-player-repair\remote-runtime-keys\publisher-private.pem',
    [string]$CredentialHelper='E:\work\tools\music-player-repair\runtime-ssh\ssh-readonly.ps1'
)

# 发布界面和服务器代码，不需要编译 APK。SHIXIAOYANG，2026/11/19。
$ErrorActionPreference='Stop'
$workspaceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseId='r'+$Version.ToString().PadLeft(6,'0')
$publishDirectory=Join-Path $workspaceRoot ('tmp/runtime-publish-'+$releaseId)
$archive=Join-Path $workspaceRoot ('tmp/deploy-'+$releaseId+'.tar')
$powershell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if(-not (Test-Path -LiteralPath $PrivateKeyFile -PathType Leaf)){throw '没有找到本机发布私钥'}
if(-not (Test-Path -LiteralPath $CredentialHelper -PathType Leaf)){throw '没有找到已有 SSH 凭据助手，请按远程框架文档配置'}

function Invoke-RuntimeCommand {
    param([string]$Command)
    # SSH 助手只从系统保护的凭据读取，不将登录密码放到命令行。
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $CredentialHelper -RemoteCommand $Command
    if($LASTEXITCODE -ne 0){throw '服务器发布步骤失败，旧安装包和本地业务缓存仍可使用'}
}

Push-Location $workspaceRoot
try {
    # 先签署一个全新的递增业务版本，生成内容完整的发布目录。
    node tools/build_runtime_release.mjs remote_app $publishDirectory $PrivateKeyFile $Version
    if($LASTEXITCODE -ne 0){throw '业务包构建或签名失败'}
    node -e 'const fs=require("fs"),crypto=require("crypto");const key=crypto.createPublicKey(fs.readFileSync(process.argv[1]));fs.writeFileSync(process.argv[2],key.export({type:"spki",format:"pem"}));' $PrivateKeyFile (Join-Path $publishDirectory 'publisher-public.pem')
    if($LASTEXITCODE -ne 0){throw '发布公钥生成失败'}

    # 只打包服务代码、公钥和业务包，私钥及 SSH 凭据始终不进入归档。
    & 'C:\Windows\System32\tar.exe' -cf $archive -C $workspaceRoot server -C $publishDirectory manifest.json releases publisher-public.pem
    if($LASTEXITCODE -ne 0){throw '发布归档失败'}
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $CredentialHelper -Action upload -LocalPath $archive -RemotePath ('/opt/kuzai-music-runtime/deploy-'+$releaseId+'.tar')
    if($LASTEXITCODE -ne 0){throw '发布上传失败'}

    # 先部署新资源并验证签名，再原子替换清单；只重启本项目的独立服务。
    $command='set -eu; root=/opt/kuzai-music-runtime; mkdir -p $root/staging/'+$releaseId+'; tar -xf $root/deploy-'+$releaseId+'.tar -C $root/staging/'+$releaseId+'; test ! -e $root/releases/'+$releaseId+'; cp -a $root/staging/'+$releaseId+'/releases/'+$releaseId+' $root/releases/; cp $root/staging/'+$releaseId+'/manifest.json $root/manifest.next.json; cp $root/staging/'+$releaseId+'/server/runtime/*.mjs $root/server/runtime/; docker run --rm --pull=never --network=none --read-only --cap-drop=ALL -v $root:/runtime:ro node:24.21.0-bookworm-slim node /runtime/server/runtime/verify_release.mjs /runtime; mv $root/manifest.next.json $root/manifest.json; docker restart --timeout=25 kuzai-music-runtime; docker run --rm --pull=never --network=none --cap-drop=ALL -v $root:/runtime:rw node:24.21.0-bookworm-slim node /runtime/server/runtime/prune_releases.mjs /runtime '+$Version
    Invoke-RuntimeCommand $command
    Write-Output ('已发布 '+$releaseId+'，应用下次打开时自动检查')
} finally {
    Pop-Location
}

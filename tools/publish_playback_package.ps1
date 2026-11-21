param(
    [ValidateRange(0, 999999999)][int]$Version = 0,
    [string]$PackageDirectory = '',
    [string]$PrivateKeyFile = 'E:\work\tools\music-player-repair\remote-runtime-keys\publisher-private.pem',
    [string]$CredentialHelper = 'E:\work\tools\music-player-repair\runtime-ssh\ssh-readonly.ps1'
)

# 只发布本地解析更新包，不编译APK或重启解析服务。SHIXIAOYANG，2026/11/21。
$ErrorActionPreference = 'Stop'
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$powershellPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $CredentialHelper -PathType Leaf)) { throw '未找到已有受保护 SSH 凭据助手' }
if ([string]::IsNullOrWhiteSpace($PackageDirectory) -and $Version -lt 1) { throw '请指定 PackageDirectory，或用 Version 生成递增的新包' }

function Invoke-PackageRemote {
    <# 用受保护凭据执行已确定的发布脚本，保留引号且不传输私钥。 #>
    param([string]$Script)
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    $remoteCommand = 'printf %s ' + $encodedScript + ' | base64 -d | bash'
    & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $CredentialHelper -RemoteCommand $remoteCommand
    if ($LASTEXITCODE -ne 0) { throw '解析更新包发布步骤失败，请核对已发布版本及服务器日志' }
}

Push-Location $workspaceRoot
try {
    # 在上传前完成源码协议、静态路由及原子发布异常回归。
    node --test playback_package/sources.test.mjs server/playback/package_updates.test.mjs
    if ($LASTEXITCODE -ne 0) { throw '解析更新包测试失败，停止发布' }
    if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
        $PackageDirectory = Join-Path $workspaceRoot ('tmp/local-package-publish-' + $Version)
        node tools/build_playback_package.mjs $PackageDirectory $Version $PrivateKeyFile | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '未能用已有私钥生成解析包' }
    }
    if (-not [IO.Path]::IsPathRooted($PackageDirectory)) {
        $PackageDirectory = Join-Path $workspaceRoot $PackageDirectory
    }
    $PackageDirectory = [IO.Path]::GetFullPath($PackageDirectory)
    $verifiedText = node tools/install_playback_package.mjs --verify $PackageDirectory
    if ($LASTEXITCODE -ne 0) { throw '解析包签名、路径或内容核对失败' }
    $verified = $verifiedText | ConvertFrom-Json
    if ($Version -gt 0 -and $Version -ne $verified.packageVersion) { throw '指定版本与已签清单版本不一致' }
    $Version = [int]$verified.packageVersion
    $packagePath = [string]$verified.packagePath
    if ($packagePath -notmatch '^packages/p[0-9]{6,9}\.json$') { throw '已签包路径不符合发布结构' }

    # 只归档三份明确文件，不包含凭据、其他目录或符号链接。
    $publishRoot = Join-Path $workspaceRoot 'tmp/local-package-transfer'
    [IO.Directory]::CreateDirectory($publishRoot) | Out-Null
    $archive = Join-Path $publishRoot ('source-package-' + $Version + '.tar')
    $archiveFiles = @((Join-Path $PackageDirectory 'manifest.json'), (Join-Path $PackageDirectory $packagePath), (Join-Path $workspaceRoot 'tools/install_playback_package.mjs'))
    foreach ($filePath in $archiveFiles) {
        $fileInfo = Get-Item -LiteralPath $filePath
        if ($fileInfo.PSIsContainer -or ($fileInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '发布文件不能是目录或符号链接' }
    }
    & 'C:\Windows\System32\tar.exe' -cf $archive -C $PackageDirectory manifest.json $packagePath -C $workspaceRoot tools/install_playback_package.mjs
    if ($LASTEXITCODE -ne 0) { throw '解析包归档失败' }

    # 临时上传助手仅允许新服务目录中的tar文件，原凭据和助手保持原样。
    $helperText = [IO.File]::ReadAllText($CredentialHelper)
    $originalRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($CredentialHelper)).Replace("'", "''")
    $helperText = $helperText.Replace('$taskRoot = $PSScriptRoot', ('$taskRoot = ' + "'$originalRoot'"))
    $helperText = $helperText.Replace('^/opt/kuzai-music-runtime/[a-zA-Z0-9_./-]+$', '^/opt/kuzai-music-api/[a-zA-Z0-9_-]+\.tar$')
    $scopedHelper = Join-Path $publishRoot 'ssh-helper.ps1'
    [IO.File]::WriteAllText($scopedHelper, $helperText, [Text.UTF8Encoding]::new($true))
    $remoteArchive = '/opt/kuzai-music-api/source-package-' + $Version + '.tar'
    & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $scopedHelper -Action upload -LocalPath $archive -RemotePath $remoteArchive
    if ($LASTEXITCODE -ne 0) { throw '更新包上传失败' }

    # 安装器持有目录锁，包与上一版备份准备好后才原子切换manifest。
    $remoteScript = @'
set -eu
root=/opt/kuzai-music-api
version=__VERSION__
package=__PACKAGE_PATH__
archive="$root/source-package-$version.tar"
test ! -L "$root"
test "$(readlink -f -- "$root")" = /opt/kuzai-music-api
test ! -L "$archive"
test ! -L "$root/updates"
test "$(tar -tf "$archive")" = "$(printf 'manifest.json\n%s\ntools/install_playback_package.mjs' "$package")"
tar -tvf "$archive" | awk 'substr($1,1,1)!="-" { invalid=1 } END { exit invalid }'
stage=$(mktemp -d "$root/package-stage.XXXXXX")
case "$stage" in "$root"/package-stage.*) ;; *) exit 1 ;; esac
cleanup() {
  rm -rf --one-file-system -- "$stage"
  rm -f -- "$archive"
}
trap cleanup EXIT
tar -xf "$archive" -C "$stage"
mkdir -p "$root/updates"
docker run --rm --pull=never --network=none --read-only --cap-drop=ALL --security-opt=no-new-privileges --memory=128m --pids-limit=64 -v "$stage:/staging:ro" -v "$root/updates:/published:rw" node:24.21.0-bookworm-slim node /staging/tools/install_playback_package.mjs /staging /published
printf '已验签更新包发布成功，manifest最后切换，保留当前和上一包\n'
'@
    $remoteScript = $remoteScript.Replace('__VERSION__', $Version.ToString()).Replace('__PACKAGE_PATH__', $packagePath)
    Invoke-PackageRemote $remoteScript
    Write-Output ('本地解析更新包已发布：版本 ' + $Version + '；App下次检查更新后使用，无需重装')
} finally {
    Pop-Location
}

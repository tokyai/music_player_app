#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$project_dir"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: IPA 构建必须在 macOS 上执行。" >&2
  exit 1
fi

for command_name in flutter xcodebuild pod; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: 缺少命令 $command_name，请先安装并配置 Flutter、Xcode 和 CocoaPods。" >&2
    exit 1
  fi
done

bundle_id="${IOS_BUNDLE_ID:-}"
team_id="${IOS_TEAM_ID:-}"
export_method="${IOS_EXPORT_METHOD:-app-store}"

if [[ -z "$bundle_id" ]]; then
  read -r -p "iOS Bundle ID（例如 com.example.kuzaiMusic）: " bundle_id
fi
if [[ -z "$team_id" ]]; then
  read -r -p "Apple Developer Team ID（10 位）: " team_id
fi

if [[ ! "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "ERROR: Bundle ID 格式无效: $bundle_id" >&2
  exit 1
fi
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ERROR: Team ID 必须是 10 位大写字母或数字。" >&2
  exit 1
fi
case "$export_method" in
  app-store|ad-hoc|development|enterprise) ;;
  *)
    echo "ERROR: IOS_EXPORT_METHOD 必须是 app-store、ad-hoc、development 或 enterprise。" >&2
    exit 1
    ;;
esac

signing_config="ios/Flutter/Signing.xcconfig"
printf 'IOS_BUNDLE_IDENTIFIER = %s\nIOS_DEVELOPMENT_TEAM = %s\n' \
  "$bundle_id" "$team_id" > "$signing_config"

echo "使用 Bundle ID: $bundle_id"
echo "使用 Team ID: $team_id"
echo "导出方式: $export_method"

flutter pub get
flutter build ipa --release --export-method="$export_method"

echo "IPA 输出目录: $project_dir/build/ios/ipa"

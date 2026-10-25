#!/usr/bin/env bash
# 在有 Xcode 的 Mac 上一键出 IPA（无需打开 Xcode）
#   用法：  ./scripts/make_ipa.sh            # 未签名 IPA，之后用 Sideloadly/爱思助手 自签
#           ./scripts/make_ipa.sh --sign     # 用本机钥匙串里的证书 + 描述文件签名
#
# 需要：Xcode、XcodeGen（brew install xcodegen）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="HongGuoFree"
PROJECT="HongGuoFree.xcodeproj"
BUILD_DIR="build"
APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/$SCHEME.app"
SIGN=false
for arg in "$@"; do
  case "$arg" in
    --sign) SIGN=true ;;
    *) echo "未知参数：$arg"; exit 1 ;;
  esac
done

command -v xcodegen >/dev/null 2>&1 || { echo "请先安装 XcodeGen：brew install xcodegen"; exit 1; }

echo "==> 生成 Xcode 工程"
xcodegen generate --spec project.yml

echo "==> 编译 Release（arm64 / iphoneos）"
mkdir -p "$BUILD_DIR"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  build | tee "$BUILD_DIR/xcodebuild.log"

[ -d "$APP_PATH" ] || { echo "编译产物不存在：$APP_PATH"; exit 1; }

if $SIGN; then
  echo "==> 签名（使用钥匙串里的第一个 iPhone 证书）"
  IDENTITY="$(security find-identity -v -p codesigning | head -1 | sed -E 's/.*"(.*)"/\1/')"
  [ -n "$IDENTITY" ] || { echo "钥匙串里没有可用的代码签名证书"; exit 1; }
  echo "    证书：$IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  OUT="HongGuoFree-signed.ipa"
else
  OUT="HongGuoFree-unsigned.ipa"
  rm -rf "$APP_PATH/_CodeSignature" || true
fi

echo "==> 打包 IPA"
rm -rf "$BUILD_DIR/Payload"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP_PATH" "$BUILD_DIR/Payload/"
(cd "$BUILD_DIR" && /usr/bin/zip -qry "$ROOT/$OUT" Payload)
rm -rf "$BUILD_DIR/Payload"

echo
echo "完成：$ROOT/$OUT"
echo "安装方式："
if $SIGN; then
  echo "  - 已签名：用 Apple Configurator / Xcode Devices / 爱思助手 直接装到手机"
else
  echo "  - 未签名：用 Sideloadly 或 爱思助手 导入你自己的 p12 + mobileprovision 自签后安装"
  echo "  - 也可以把 $OUT 拖进 AltStore / SideStore 安装"
fi

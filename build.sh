#!/bin/bash
# VoiceOn をビルドして .app バンドルを生成するスクリプト
set -euo pipefail

cd "$(dirname "$0")"
BUILD_DIR=".build/release"

# 安定した自己署名ID（再ビルドしてもアクセシビリティ等の権限が維持される）。
# 未導入なら ad-hoc 署名(-)にフォールバック。
SIGN_ID="VoiceOn Local Signing"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "（警告）署名ID「$SIGN_ID」が無いため ad-hoc 署名にフォールバックします"
    SIGN_ID="-"
fi

echo "==> swift build (release)"
swift build -c release

NAME="VoiceOn"
BUNDLE_ID="com.nakai.voiceon"
APP="$NAME.app"

echo "==> $APP を作成"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$NAME" "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>音声入力のためにマイクを使用します。</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>音声をテキストに変換するために音声認識を使用します。</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1
echo "    -> $(pwd)/$APP"
echo ""
echo "起動: open \"$APP\""

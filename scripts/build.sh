#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/check.sh
APP="$PWD/dist/キロクル.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Minutes "$APP/Contents/MacOS/Minutes"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Minutes</string>
<key>CFBundleIdentifier</key><string>io.github.nutcase.kirokuru</string>
<key>CFBundleName</key><string>キロクル</string>
<key>CFBundleDisplayName</key><string>キロクル</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSMicrophoneUsageDescription</key><string>会議中のあなたの声を録音します。</string>
<key>NSAudioCaptureUsageDescription</key><string>会議アプリなどのMac音声を録音します。</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Ad-hoc signing (the default) changes the signature on every build, so macOS drops the screen and
# audio recording permission. Set KIROKURU_SIGN_IDENTITY to a code-signing certificate name to keep it.
codesign --force --sign "${KIROKURU_SIGN_IDENTITY:--}" "$APP"
printf '%s\n' "$APP"

#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/check.sh
APP="$PWD/dist/ギジログ.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Gijilog "$APP/Contents/MacOS/Gijilog"
# The MCP bridge AI apps run (see MCPServer.swift); it is signed before the app that contains it.
cp .build/release/gijilog-mcp "$APP/Contents/MacOS/gijilog-mcp"
# Package the chosen artwork at every standard macOS icon size, including Retina variants. At 16 and 32 pixels
# the artwork shrunk turns to blur, so those use versions drawn for the pixel grid (scripts/small-icons.swift).
iconset_dir="$PWD/.build/AppIcon.iconset"
mkdir -p "$iconset_dir"
for icon_size in 16 32 128 256 512; do
  for icon_scale in 1 2; do
    icon_pixels=$((icon_size * icon_scale))
    icon_suffix=""
    if (( icon_scale == 2 )); then icon_suffix="@2x"; fi
    icon_source=Resources/AppIcon.png
    if (( icon_pixels <= 32 )); then icon_source="Resources/AppIcon-${icon_pixels}.png"; fi
    sips -z "$icon_pixels" "$icon_pixels" "$icon_source" \
      --out "$iconset_dir/icon_${icon_size}x${icon_size}${icon_suffix}.png" >/dev/null
  done
done
iconutil --convert icns "$iconset_dir" --output "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Gijilog</string>
<key>CFBundleIdentifier</key><string>io.github.nutcase.gijilog</string>
<key>CFBundleName</key><string>ギジログ</string>
<key>CFBundleDisplayName</key><string>ギジログ</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleDevelopmentRegion</key><string>ja</string>
<key>CFBundleLocalizations</key><array><string>ja</string></array>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSMicrophoneUsageDescription</key><string>会議中のあなたの声を録音します。</string>
<key>NSAudioCaptureUsageDescription</key><string>会議アプリなどのMac音声を録音します。</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Ad-hoc signing (the default) changes the signature on every build, so macOS drops the screen and
# audio recording permission. Set GIJILOG_SIGN_IDENTITY to a code-signing certificate name to keep it.
codesign --force --sign "${GIJILOG_SIGN_IDENTITY:--}" "$APP/Contents/MacOS/gijilog-mcp"
codesign --force --sign "${GIJILOG_SIGN_IDENTITY:--}" "$APP"
printf '%s\n' "$APP"

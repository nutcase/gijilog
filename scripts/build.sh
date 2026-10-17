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
# macOS 26 and later draw an Icon Composer icon (Resources/AppIcon.icon) at every size, without the plate and
# blur they give the icns above. It needs Xcode's actool; without Xcode the icns is the icon everywhere.
actool="$(xcrun --find actool 2>/dev/null || true)"
if [[ -z "$actool" && -x /Applications/Xcode.app/Contents/Developer/usr/bin/actool ]]; then
  actool=/Applications/Xcode.app/Contents/Developer/usr/bin/actool
fi
rm -f "$APP/Contents/Resources/Assets.car"
if [[ -n "$actool" ]]; then
  assets_dir="$PWD/.build/AppIconAssets"
  rm -rf "$assets_dir" && mkdir -p "$assets_dir"
  "$actool" "$PWD/Resources/AppIcon.icon" --compile "$assets_dir" --platform macosx --minimum-deployment-target 15.0 \
    --app-icon AppIcon --output-partial-info-plist "$assets_dir/partial.plist" >/dev/null
  cp "$assets_dir/Assets.car" "$APP/Contents/Resources/Assets.car"
else
  print 'Xcode の actool がないため、アイコンは icns だけで作ります。'
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Gijilog</string>
<key>CFBundleIdentifier</key><string>io.github.nutcase.gijilog</string>
<key>CFBundleName</key><string>ギジログ</string>
<key>CFBundleDisplayName</key><string>ギジログ</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
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
# Ad-hoc signing changes the signature on every build, so macOS drops the audio recording permission and asks
# again before the app reads its key from the keychain. A self-signed code-signing certificate named ギジログ
# (see README) keeps both, and is used when it is in the keychain; GIJILOG_SIGN_IDENTITY names another. It is
# chosen by its SHA-1, so another certificate with a similar name cannot make the choice ambiguous.
sign_name="${GIJILOG_SIGN_IDENTITY:-ギジログ}"
identity="$(security find-certificate -c "$sign_name" -Z 2>/dev/null | awk '/SHA-1/ { print $3; exit }')"
if [[ -z "$identity" ]]; then
  print "署名用の証明書「$sign_name」がないため、ad-hoc で署名します（録音の許可が外れることがあります）。"
  identity="-"
fi
codesign --force --sign "$identity" "$APP/Contents/MacOS/gijilog-mcp"
codesign --force --sign "$identity" "$APP"
# macOS keeps showing an app's earlier icon until the app's folder changes: mark it changed and register it again.
touch "$APP" "$APP/Contents"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" \
  >/dev/null 2>&1 || true
printf '%s\n' "$APP"

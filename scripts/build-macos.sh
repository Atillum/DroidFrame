#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"; cd "$repo"
app="$repo/dist/DroidFrame.app"; contents="$app/Contents"; resources="$contents/Resources"
mkdir -p "$contents/MacOS" "$resources/scrcpy" "$repo/.build"
archive="$repo/.build/scrcpy-macos-aarch64-v5.0.1.tar.gz"
curl --retry 3 -fsSL https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-macos-aarch64-v5.0.1.tar.gz -o "$archive"
echo "33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b  $archive" | shasum -a 256 -c -
tar -xzf "$archive" --strip-components=1 -C "$resources/scrcpy"
swiftc -parse-as-library -target arm64-apple-macos13.0 macos/DroidFrame.swift macos/MP4Finalize.swift macos/VideoCompression.swift -framework AppKit -framework AVFoundation -module-cache-path .build/swift-cache -o "$contents/MacOS/DroidFrame"
clang -fobjc-arc -mmacosx-version-min=13.0 -dynamiclib -framework Cocoa -framework QuartzCore macos/DroidFrameToolbar.m -Wl,-install_name,@rpath/DroidFrameToolbar.dylib -o "$resources/DroidFrameToolbar.dylib"
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DroidFrame</string>
<key>CFBundleIdentifier</key><string>io.github.atillum.droidframe</string>
<key>CFBundleName</key><string>DroidFrame</string>
<key>CFBundleDisplayName</key><string>DroidFrame</string>
<key>CFBundleShortVersionString</key><string>1.6.0</string>
<key>CFBundleVersion</key><string>16</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
icon=$(find "$resources/scrcpy" -name 'scrcpy.png' | head -1)
if [ -n "$icon" ]; then
  mkdir -p .build/AppIcon.iconset
  for size in 16 32 64 128 256 512; do sips -z "$size" "$size" "$icon" --out ".build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null; done
  for size in 16 32 128 256 512; do double=$((size*2)); sips -z "$double" "$double" "$icon" --out ".build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null; done
  iconutil -c icns .build/AppIcon.iconset -o "$resources/AppIcon.icns"
fi
cp LICENSE THIRD-PARTY.md "$resources/"
if [ "${SKIP_FFMPEG:-0}" != 1 ]; then bash scripts/build-ffmpeg.sh macos "$resources/ffmpeg"; fi
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

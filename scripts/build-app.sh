#!/bin/bash
set -euo pipefail
if [[ "$#" -gt 1 ]]; then
  printf '%s\n' 'Usage: build-app.sh ["/absolute/path/Wallpaper Rotation.app"]' >&2
  exit 2
fi
task_root="$(cd "$(dirname "$0")/.." && pwd)"
output_path="${1:-$task_root/build/Wallpaper Rotation.app}"
case "$output_path" in /*) ;; *) output_path="$PWD/$output_path" ;; esac
if [[ "$output_path" != *.app ]]; then
  printf '%s\n' 'The output path must end in .app.' >&2
  exit 2
fi
cd "$task_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$task_root/.build/clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$task_root/.build/swift-cache}"
swift build --disable-sandbox --cache-path "$task_root/.build/spm-cache" -debug-info-format none --configuration release --product WallpaperRotation
swift build --disable-sandbox --cache-path "$task_root/.build/spm-cache" -debug-info-format none --configuration release --product WallpaperDiagnostics
binary_path="$(swift build --disable-sandbox --cache-path "$task_root/.build/spm-cache" --configuration release --show-bin-path)"
mkdir -p "$output_path/Contents/MacOS" "$output_path/Contents/Resources"
install -m 755 "$binary_path/WallpaperRotation" "$output_path/Contents/MacOS/WallpaperRotation"
install -m 755 "$binary_path/WallpaperDiagnostics" "$output_path/Contents/MacOS/WallpaperDiagnostics"
cat > "$output_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.muffinsmith.WallpaperRotation</string>
<key>CFBundleName</key><string>Wallpaper Rotation</string>
<key>CFBundleDisplayName</key><string>Wallpaper Rotation</string>
<key>CFBundleExecutable</key><string>WallpaperRotation</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.2</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocationUsageDescription</key><string>Use this Mac’s location to calculate sunrise and sunset for wallpaper rotation. The saved location stays on this Mac.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Use this Mac’s location to calculate sunrise and sunset for wallpaper rotation. The saved location stays on this Mac.</string>
</dict></plist>
PLIST
plutil -lint "$output_path/Contents/Info.plist"
signer="${SIGNING_IDENTITY:--}"
codesign --force --sign "$signer" "$output_path/Contents/MacOS/WallpaperDiagnostics"
codesign --force --sign "$signer" "$output_path"
codesign --verify --strict --verbose=2 "$output_path"
printf '%s\n' "$output_path"

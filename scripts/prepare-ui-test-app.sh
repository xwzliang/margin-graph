#!/bin/bash
set -euo pipefail

# Build a discoverable macOS app for native computer-use tools.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
swift build --product MarginGraphApp
bin_dir="$(swift build --show-bin-path)"
app_dir="$repo_root/.build/UITesting/MarginGraph.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/MarginGraphApp" "$app_dir/Contents/MacOS/MarginGraphApp"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MarginGraphApp</string>
<key>CFBundleIdentifier</key><string>local.margingraph.ui-test</string>
<key>CFBundleName</key><string>MarginGraph</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf '%s\n' "$app_dir"

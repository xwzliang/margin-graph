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
plist_file="$(mktemp)"
trap 'rm -f "$plist_file"' EXIT
cat > "$plist_file" <<'PLIST'
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
if ! cmp -s "$plist_file" "$app_dir/Contents/Info.plist"; then
    cp "$plist_file" "$app_dir/Contents/Info.plist"
fi

# A certificate-backed identity gives rebuilt code a stable designated requirement.
# Do not use an identifier-only ad hoc requirement: it is not bound to a signer.
signing_identity="${MARGINGRAPH_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning | awk '/"Apple Development:|"Developer ID Application:/ { print $2; exit }')"
fi
if [[ -n "$signing_identity" ]]; then
    codesign --force --sign "$signing_identity" --timestamp=none "$app_dir"
    codesign --verify --strict "$app_dir"
else
    # Seal the bundle consistently even without a certificate. This identity is
    # build-specific, so it cannot retain privacy approvals across code changes.
    codesign --force --sign - "$app_dir"
    codesign --verify --strict "$app_dir"
    printf '%s\n' 'No code-signing identity found. macOS file-access approvals may recur after rebuilds.' >&2
    printf '%s\n' 'Install an Apple Development identity or set MARGINGRAPH_SIGNING_IDENTITY to an existing signing certificate.' >&2
fi
printf '%s\n' "$app_dir"

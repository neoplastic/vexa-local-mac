#!/usr/bin/env bash
# Builds "Vexa Local.app" into app/build/. Needs Xcode (or the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"

# Use Xcode's Swift, not whatever `swift` is first on PATH.
SWIFT=(xcrun swift)
"${SWIFT[@]}" build -c release --arch arm64
BIN="$("${SWIFT[@]}" build -c release --arch arm64 --show-bin-path)"

APP="build/Vexa Local.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VexaLocal" "$APP/Contents/MacOS/VexaLocal"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Vexa Local</string>
    <key>CFBundleDisplayName</key><string>Vexa Local</string>
    <key>CFBundleIdentifier</key><string>io.github.vexa-local-mac</string>
    <key>CFBundleExecutable</key><string>VexaLocal</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Vexa Local records your microphone when you use Record, and transcribes it on this Mac with Whisper.</string>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# Signing. An ad-hoc signature ("-") changes with every build, so macOS treats each build
# as a new app and asks again for Microphone and Screen & System Audio Recording.
# A stable identity keeps those permissions across rebuilds: set VEXA_SIGN_IDENTITY, or
# create a self-signed code-signing certificate named "Vexa Local Dev" in Keychain Access
# (Certificate Assistant > Create a Certificate…, type: Code Signing).
IDENTITY="${VEXA_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"Vexa Local Dev"'; then
    IDENTITY="Vexa Local Dev"
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
[[ -n "$IDENTITY" ]] && echo "Signed with: $IDENTITY" || echo "Signed ad-hoc (permissions are asked again after each rebuild)."
echo "Built: $(pwd)/$APP"

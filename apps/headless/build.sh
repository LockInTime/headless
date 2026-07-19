#!/bin/zsh
# Builds Headless.app and its agent CLI. No Xcode project or third-party packages.
set -euo pipefail
cd "${0:a:h}"

for tool in swift swiftc iconutil codesign; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "headless build: missing $tool. Install Xcode Command Line Tools with: xcode-select --install" >&2
    exit 69
  fi
done

APP="Headless.app"
ARCH="$(uname -m)"
ICON="build/Headless.icns"
VERSION="${HEADLESS_VERSION:-1.0.0}"
mkdir -p build/module-cache build/swiftpm-module-cache build/bin

# Select an SDK the installed Swift compiler can read. Apple occasionally ships
# a Command Line Tools compiler update before changing the default SDK symlink.
SDK_ARGS=()
if [[ -z "${SDKROOT:-}" ]]; then
  COMPATIBLE_SDK=""
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk(NOn); do
    if swiftc -module-cache-path build/module-cache -sdk "$sdk" \
        -target "$ARCH-apple-macos13.0" -typecheck \
        Sources/HeadlessProtocol/Protocol.swift >/dev/null 2>&1; then
      export SDKROOT="$sdk"
      SDK_ARGS=(--sdk "$sdk")
      COMPATIBLE_SDK="$sdk"
      break
    fi
  done
  if [[ -z "$COMPATIBLE_SDK" ]]; then
    echo "headless build: no macOS SDK compatible with the installed Swift compiler was found." >&2
    echo "Update Xcode Command Line Tools, then retry." >&2
    exit 69
  fi
fi
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/swiftpm-module-cache"

if [[ ! -f "$ICON" ]]; then
  echo "▸ rendering icon"
  rm -rf build/AppIcon.iconset
  mkdir -p build
  swift tools/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o "$ICON"
fi

echo "▸ compiling ($ARCH)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SWIFT_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/headless-build.XXXXXX")"
trap 'rm -rf "$SWIFT_SCRATCH"' EXIT
BIN_PATH="$(swift build "${SDK_ARGS[@]}" -c release --scratch-path "$SWIFT_SCRATCH" --show-bin-path)"
swift build "${SDK_ARGS[@]}" -c release --product headless-host --scratch-path "$SWIFT_SCRATCH"
swift build "${SDK_ARGS[@]}" -c release --product headless --scratch-path "$SWIFT_SCRATCH"
swift build "${SDK_ARGS[@]}" -c release --product headless-mcp --scratch-path "$SWIFT_SCRATCH"
cp "$BIN_PATH/headless-host" "$APP/Contents/MacOS/Headless"
mkdir -p "$APP/Contents/Resources/bin"
cp "$BIN_PATH/headless" "$APP/Contents/Resources/bin/headless"
cp "$BIN_PATH/headless" build/bin/headless
cp "$BIN_PATH/headless-mcp" "$APP/Contents/Resources/bin/headless-mcp"
cp "$BIN_PATH/headless-mcp" build/bin/headless-mcp

cp "$ICON" "$APP/Contents/Resources/Headless.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Headless</string>
  <key>CFBundleDisplayName</key><string>Headless</string>
  <key>CFBundleExecutable</key><string>Headless</string>
  <key>CFBundleIdentifier</key><string>com.headless.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>Headless</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
    <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
  </dict>
  <key>NSHumanReadableCopyright</key><string>headless — the browser that isn’t there</string>
</dict>
</plist>
PLIST

# Passkeys require Apple's restricted web-browser.public-key-credential
# entitlement backed by a provisioning profile; macOS SIGKILLs ad-hoc builds
# that claim it. Default: ad-hoc, no entitlement (app hides WebAuthn so sites
# offer fallback sign-in). Once Apple grants the capability to your App ID:
#   PROVISIONING_PROFILE=headless.provisionprofile \
#   CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./build.sh
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  fi
  codesign --force --sign "$CODESIGN_IDENTITY" "$APP/Contents/Resources/bin/headless"
  codesign --force --sign "$CODESIGN_IDENTITY" "$APP/Contents/Resources/bin/headless-mcp"
  codesign --force --sign "$CODESIGN_IDENTITY" --entitlements headless.entitlements "$APP"
  echo "▸ signed as $CODESIGN_IDENTITY with passkey entitlement"
else
  codesign --force --sign - "$APP/Contents/Resources/bin/headless" 2>/dev/null
  codesign --force --sign - "$APP/Contents/Resources/bin/headless-mcp" 2>/dev/null
  codesign --force --sign - "$APP" 2>/dev/null
fi
SIZE=$(du -sh "$APP" | cut -f1)
echo "✓ built $APP ($SIZE)"
echo "  try:  open $APP"
echo "  agent CLI:  ./$APP/Contents/Resources/bin/headless help"

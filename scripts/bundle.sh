#!/bin/sh
# Build a release .app bundle: icon, Info.plist, code signature.
# Output: build/Token Budget.app
#
# Signing: uses the first "Apple Development" or "Developer ID Application"
# identity in your keychain, or SIGN_IDENTITY if set. A real identity keeps
# the signature stable across rebuilds, so the Keychain stops asking for
# permission after each build. Falls back to ad-hoc ("-") if none exists.
set -eu
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c release
APP="build/Token Budget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeBudgetRings "$APP/Contents/MacOS/TokenBudget"
# SwiftPM records SDK 14 in the binary, which gets the older, opaque panel
# material on macOS 26+. Stamp the real SDK so it matches the other widgets.
vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace -output "$APP/Contents/MacOS/TokenBudget" "$APP/Contents/MacOS/TokenBudget"

# Icon: compile the Icon Composer document (Resources/AppIcon.icon).
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$PWD/build/icon.plist" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.domkits.claude-budget-rings</string>
  <key>CFBundleName</key><string>Token Budget</string>
  <key>CFBundleDisplayName</key><string>Token Budget</string>
  <key>CFBundleExecutable</key><string>TokenBudget</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) IDST UK</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -E '"(Developer ID Application|Apple Development):' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)}"
IDENTITY="${IDENTITY:--}"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION build $BUILD_NUMBER), signed with: $IDENTITY"

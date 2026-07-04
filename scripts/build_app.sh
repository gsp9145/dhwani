#!/bin/bash
# Builds Dhwani.app into dist/ with an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/Dhwani.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Dhwani "$APP/Contents/MacOS/Dhwani"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc
# signing ("-") changes identity every build and macOS forgets the grant.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Dhwani Dev"; then
  codesign --force --sign "Dhwani Dev" "$APP"
  echo "signed with Dhwani Dev (stable identity — permissions survive rebuilds)"
else
  codesign --force --sign - "$APP"
  echo "signed ad-hoc — re-grant Accessibility after each rebuild (see README)"
fi

# Install to /Applications (needed for Launch at Login; keeps one canonical copy)
rm -rf /Applications/Dhwani.app
cp -R "$APP" /Applications/Dhwani.app

echo "✅ Built $APP and installed /Applications/Dhwani.app"
echo "   Launch with: open /Applications/Dhwani.app"

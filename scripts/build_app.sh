#!/bin/bash
# Builds FreeFlow.app into dist/ with an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/FreeFlow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FreeFlow "$APP/Contents/MacOS/FreeFlow"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc
# signing ("-") changes identity every build and macOS forgets the grant.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "FreeFlow Dev"; then
  codesign --force --sign "FreeFlow Dev" "$APP"
  echo "signed with FreeFlow Dev (stable identity — permissions survive rebuilds)"
else
  codesign --force --sign - "$APP"
  echo "signed ad-hoc — re-grant Accessibility after each rebuild (see README)"
fi

echo "✅ Built $APP"
echo "   Launch with: open $APP"

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

codesign --force --sign - "$APP"

echo "✅ Built $APP"
echo "   Launch with: open $APP"

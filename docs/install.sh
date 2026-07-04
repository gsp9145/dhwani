#!/bin/bash
# Dhwani installer — https://github.com/gsp9145/dhwani
# Downloads the latest release and installs it to /Applications.
# curl-fetched files carry no quarantine flag, so the app opens without
# Gatekeeper friction; we also clear the attribute defensively.
set -euo pipefail

REPO="gsp9145/dhwani"
APP="/Applications/Dhwani.app"

echo ""
echo "  Dhwani (ध्वनि) — fully-local voice dictation for macOS"
echo ""

if [ "$(uname -m)" != "arm64" ]; then
  echo "❌ Dhwani requires an Apple Silicon Mac."
  exit 1
fi

osver="$(sw_vers -productVersion)"
if [ "${osver%%.*}" -lt 26 ]; then
  echo "❌ Dhwani requires macOS 26 (Tahoe) or later — you're on $osver."
  echo "   It's built on Apple's on-device SpeechAnalyzer engine, new in macOS 26."
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "→ Downloading the latest release…"
curl -fsSL -o "$tmp/Dhwani.zip" "https://github.com/$REPO/releases/latest/download/Dhwani.zip"

echo "→ Installing to /Applications…"
pkill -x Dhwani 2>/dev/null || true
ditto -xk "$tmp/Dhwani.zip" "$tmp/extract"
rm -rf "$APP"
mv "$tmp/extract/Dhwani.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

open "$APP"

cat <<'EOF'

✅ Dhwani is installed and running — look for the waveform icon in your menu bar.

One-time setup:
  1. Grant Accessibility when the app asks
     (System Settings → Privacy & Security → Accessibility → enable Dhwani)
  2. Approve the microphone on your first dictation
  3. If pressing Fn opens the emoji picker, set
     System Settings → Keyboard → "Press 🌐 key to" → Do Nothing

Then: hold Fn and talk · release to insert · double-tap Fn for hands-free · Esc cancels.

Everything runs on your Mac. No cloud, no account, no telemetry.
Source & issues: https://github.com/gsp9145/dhwani
EOF

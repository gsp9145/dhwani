# Dhwani 🎙️

**ध्वनि — "sound." Open-source, fully-local voice dictation for macOS — a Wispr Flow alternative with zero subscription.**

Hold a key. Talk. Release. Your words appear in whatever app you're typing in — Slack, Mail, VS Code, your browser, anywhere. Everything runs on your Mac: Apple's on-device speech models do the transcription and (optionally) Apple's on-device LLM polishes the text. **No cloud. No audio ever leaves your machine. No $20/month.**

## How it works

```
hold Fn ──► mic capture (AVAudioEngine)
                │  streaming buffers
                ▼
        SpeechAnalyzer / SpeechTranscriber        ← Apple on-device ASR (macOS 26)
                │  live partial transcript in HUD
release Fn ──► finalize
                │
                ▼
        AI Polish (optional, FoundationModels)    ← on-device LLM: fillers out, punctuation fixed
                │
                ▼
        Paste into frontmost app (⌘V simulation, clipboard restored)
                │
                ▼
        History: SQLite stats + daily markdown files in ~/Documents/Dhwani
```

## Features

- **Push-to-talk dictation** — hold `Fn` (or Right ⌘ / Right ⌥ / F1), speak, release. Esc cancels.
- **Hands-free mode** — double-tap the dictation key to lock recording (waveform turns red); tap once to stop and insert. 20-minute cap.
- **Live transcript HUD** — Wispr-style pill at the bottom of the screen shows words as you say them.
- **Works in every app** — inserts via paste simulation (with clipboard save/restore) or keystroke typing.
- **AI Polish** (toggle) — on-device LLM removes "um/uh", applies self-corrections ("scratch that…"), fixes punctuation.
- **Transcript repository** — every dictation appended to `~/Documents/Dhwani/YYYY-MM-DD.md`, so nothing is ever lost; copy anything back anytime.
- **Daily activity stats** — words + notes today and all-time, in the menu bar.
- **Recent transcripts menu** — click any recent dictation to copy it.
- **Private by construction** — on-device ASR + on-device LLM. The binary makes zero network calls (the OS downloads Apple's speech model once, via Apple).

## Requirements

- macOS 26 (Tahoe) or later — Dhwani uses Apple's `SpeechAnalyzer` API introduced in macOS 26
- Apple Silicon recommended
- Xcode Command Line Tools to build (`xcode-select --install`)

## Install

**One command** (Apple Silicon, macOS 26+):

```bash
curl -fsSL https://gsp9145.github.io/dhwani/install.sh | bash
```

Or download the zip from [Releases](https://github.com/gsp9145/dhwani/releases/latest) — browser downloads are quarantined, so the first launch needs System Settings → Privacy & Security → **Open Anyway** (the build isn't notarized yet).

## Build & run

```bash
./scripts/build_app.sh
open dist/Dhwani.app
```

Optionally move `dist/Dhwani.app` into `/Applications` (required for "Launch at Login").

## First-run setup

1. **Accessibility** permission — lets Dhwani see the dictation key globally and paste for you. System Settings → Privacy & Security → Accessibility → enable Dhwani.
2. **Microphone** permission — approve the prompt.
3. **Globe key** — if pressing `Fn` opens the emoji picker, set System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing** (or use the "Fix 🌐 Key Setting" button in Dhwani's setup dialog).
4. First launch downloads Apple's on-device speech model (~a few hundred MB, one time).

> **Note on rebuilds:** without a signing identity the app is ad-hoc signed, and macOS forgets the Accessibility grant on every rebuild (remove and re-add the app in System Settings). Create a local self-signed certificate named **"Dhwani Dev"** (Keychain Access → Certificate Assistant → Create a Certificate → type: Code Signing) and the build script picks it up automatically — grants then survive rebuilds. For public distribution, use a paid Developer ID.

## Why not just use Wispr Flow?

Wispr Flow is excellent — but it's $15–20/month, and your audio is processed in their cloud. Dhwani gives you the core experience (push-to-talk, formatted text, any app, history) for free, offline, and auditable. If you dictate all day and want their tone-matching, per-app formatting, and 100+ language cloud models, pay them. If you want fast private dictation that's yours forever, build this.

## Roadmap

- [x] Hands-free toggle mode (double-tap to lock recording)
- [ ] Personal dictionary (custom vocabulary via `AnalysisContext.contextualStrings`)
- [ ] Per-app formatting profiles (code-friendly in terminals/IDEs)
- [ ] Command mode ("select last paragraph, make it formal")
- [ ] whisper.cpp / Parakeet engine option for pre-macOS-26 Macs
- [ ] History browser window with search
- [ ] Menu bar waveform animation + custom app icon
- [ ] Signed + notarized releases

## License

MIT — see [LICENSE](LICENSE).

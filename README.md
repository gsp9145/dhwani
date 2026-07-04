# FreeFlow 🎙️

**Open-source, fully-local voice dictation for macOS — a Wispr Flow alternative with zero subscription.**

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
        History: SQLite stats + daily markdown files in ~/Documents/FreeFlow
```

## Features

- **Push-to-talk dictation** — hold `Fn` (or Right ⌘ / Right ⌥ / F1), speak, release. Esc cancels.
- **Live transcript HUD** — Wispr-style pill at the bottom of the screen shows words as you say them.
- **Works in every app** — inserts via paste simulation (with clipboard save/restore) or keystroke typing.
- **AI Polish** (toggle) — on-device LLM removes "um/uh", applies self-corrections ("scratch that…"), fixes punctuation.
- **Transcript repository** — every dictation appended to `~/Documents/FreeFlow/YYYY-MM-DD.md`, so nothing is ever lost; copy anything back anytime.
- **Daily activity stats** — words + notes today and all-time, in the menu bar.
- **Recent transcripts menu** — click any recent dictation to copy it.
- **Private by construction** — on-device ASR + on-device LLM. The binary makes zero network calls (the OS downloads Apple's speech model once, via Apple).

## Requirements

- macOS 26 (Tahoe) or later — FreeFlow uses Apple's `SpeechAnalyzer` API introduced in macOS 26
- Apple Silicon recommended
- Xcode Command Line Tools to build (`xcode-select --install`)

## Build & run

```bash
./scripts/build_app.sh
open dist/FreeFlow.app
```

Optionally move `dist/FreeFlow.app` into `/Applications` (required for "Launch at Login").

## First-run setup

1. **Accessibility** permission — lets FreeFlow see the dictation key globally and paste for you. System Settings → Privacy & Security → Accessibility → enable FreeFlow.
2. **Microphone** permission — approve the prompt.
3. **Globe key** — if pressing `Fn` opens the emoji picker, set System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing** (or use the "Fix 🌐 Key Setting" button in FreeFlow's setup dialog).
4. First launch downloads Apple's on-device speech model (~a few hundred MB, one time).

> **Note on rebuilds:** the app is ad-hoc signed. After rebuilding you may need to re-grant Accessibility (remove and re-add the app in System Settings). For distribution, sign with a Developer ID.

## Why not just use Wispr Flow?

Wispr Flow is excellent — but it's $15–20/month, and your audio is processed in their cloud. FreeFlow gives you the core experience (push-to-talk, formatted text, any app, history) for free, offline, and auditable. If you dictate all day and want their tone-matching, per-app formatting, and 100+ language cloud models, pay them. If you want fast private dictation that's yours forever, build this.

## Roadmap

- [ ] Hands-free toggle mode (double-tap to lock recording)
- [ ] Personal dictionary (custom vocabulary via `AnalysisContext.contextualStrings`)
- [ ] Per-app formatting profiles (code-friendly in terminals/IDEs)
- [ ] Command mode ("select last paragraph, make it formal")
- [ ] whisper.cpp / Parakeet engine option for pre-macOS-26 Macs
- [ ] History browser window with search
- [ ] Menu bar waveform animation + custom app icon
- [ ] Signed + notarized releases

## License

MIT — see [LICENSE](LICENSE).

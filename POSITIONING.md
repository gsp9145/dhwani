# Dhwani — Positioning & Honest Comparison Notes

Internal reference for writing posts, website copy, and comparison content.
The discipline: every claim here survives a harsh, well-informed reader.
Written 2026-07-06.

---

## The steelman AGAINST Dhwani (know it before anyone says it)

- macOS **already ships dictation**: press the dictation key, free, on-device,
  made by Apple, works in every text field — and on macOS 26 it runs on
  substantially the same speech stack Dhwani calls.
- Apple Intelligence **already ships Writing Tools** that can proofread and
  rewrite text system-wide.
- Harshest framing: *Dhwani is a wrapper around capabilities Apple gives away.*
- For a casual user who dictates twice a week, the honest advice is:
  **don't install Dhwani — use the built-in.** Never pretend otherwise.

## What survives the critique (the real value)

1. **The pipeline exists nowhere else — and pipelines are products.**
   Apple gives ingredients, not the meal. Built-in dictation types words
   verbatim (fillers, false starts and all). Writing Tools cleanup is manual:
   select → menu → Proofread → accept. Nobody at Apple ships
   *hold key → speak → cleaned text lands → archived* as one gesture.
   Chaining ASR → LLM → paste → history into one muscle-memory motion IS the
   product. Wispr built a business on exactly this "thinness" — against the
   same free built-in competitor.

2. **The interaction model is genuinely different.**
   Built-in dictation is a *mode*: toggle in, watch it type, toggle out, clean
   up its mess. Push-to-talk is a walkie-talkie: no mode, no cleanup, no
   cognitive residue. Heavy dictators pay $15/month primarily for this feel —
   revealed preference, not opinion.

3. **Memory.** Apple dictation remembers nothing. Dhwani keeps every
   dictation in searchable daily markdown + a stats database (words, apps,
   trends). For someone who dictates their thinking all day, the archive
   quietly becomes the most valuable feature — a journal you didn't have to keep.

4. **Control Apple doesn't expose to end users.** Vocabulary biasing
   (`AnalysisContext.contextualStrings` — fixes names like Gaurang/Abhinav),
   replacement rules, per-app stats, per-app tone (roadmap). These APIs exist
   but no built-in setting reaches them.

## Where Wispr Flow honestly beats both Apple and us

- Cloud models **trained specifically on messy dictation** — disfluent,
  accented, real speech. Better raw accuracy on hard speech than Apple's
  general-purpose model, therefore better than us.
- **Context awareness**: reads the screen so names/jargon in view get spelled
  correctly; biases the ASR itself.
- **Auto-learning**: learns your corrections without being told.
- **Tone matching** per app category; 100+ languages; Windows + iOS.
- People paying $180/year are buying the last ~15% of accuracy plus
  zero-thought formatting. Do not claim quality parity.

**Our counter is structural, not qualitative:** $0 · offline · private ·
yours. Wispr cannot occupy that position at any price — their architecture
requires your audio on their servers (their own security FAQ:
"transcription always happens in the cloud").

## The honest market

People who dictate heavily enough that the built-in annoys them, but won't
send their voice to a cloud or pay a subscription. That is the Wispr
demographic minus the payment — narrow and real. Existence proof the gap is
worth occupying: Wispr grew huge *despite* free built-in dictation on every
device they run on.

**Standing risk:** Apple could absorb this category any year — they own every
primitive we use. That is precisely why free + open source is the right
posture: we surf Apple's improvements. A paid closed product in this spot
would be standing on a trapdoor.

---

## Messaging: claims that survive vs claims to avoid

**Use (survives scrutiny):**
- "If you dictate all day, this is the loop Apple never built — free, and
  your voice never leaves your Mac."
- "Hold a key. Speak. Clean text lands where you were typing — and it's
  archived forever, locally."
- "Dictation makes zero network calls. Not a promise — auditable, open-source fact."
- "Wispr Flow is excellent. It's also $180/year and your audio is processed
  on their servers. Pick your trade."
- "The dictation app your security team will approve." (teams/compliance angle)

**Avoid (dies under a harsh reader):**
- "Better than Apple's dictation" (unqualified — for casual use it isn't needed)
- "As accurate as Wispr Flow" (their dictation-tuned cloud models are ahead on messy speech)
- "Zero network calls" (unqualified — the auto-updater makes a version check; say "dictation makes zero network calls")
- Anything implying Apple endorsement, or hiding the macOS 26 / Apple Silicon requirement

## One-line answers to predictable questions

- *"Why not just use macOS dictation?"* → It types your "um"s, forgets
  everything, and makes cleanup your job. Dhwani is one gesture:
  speak → clean → pasted → archived.
- *"Why not just pay for Wispr?"* → If you want cloud tone-matching and 100+
  languages, do. If you want fast private dictation that's yours forever, don't.
- *"What's the catch?"* → No servers, no costs to recover, MIT license.
  The models are Apple's, running on the Mac you already own.
- *"Why macOS 26 only?"* → Apple's on-device streaming speech engine ships
  there. Older Apple Silicon support (bundled open model) is on the roadmap.

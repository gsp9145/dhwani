# On-Device Model Research — Capabilities & Product Map

Empirical findings from live testing on macOS 26.2 / Apple Silicon, 2026-07-08.
Companion to [POSITIONING.md](POSITIONING.md). Everything below was measured,
not assumed.

## The model

Apple FoundationModels (`SystemLanguageModel.default`):
- ~3B-parameter instruction-tuned on-device LLM, 4,096-token context (TN3193)
- 0.4–0.8 s responses for short tasks (greedy decoding), ~2.5 s for long input
- **15 languages**: da, de, en, es, fr, it, ja, ko, nb, nl, pt, sv, tr, vi, zh —
  **no Hindi**; Hindi/Hinglish input throws `unsupportedLanguageOrLocale`
- Unused API surface: `@Generable` constrained structured output (typed schema —
  the model cannot go off-script), `streamResponse`, `UseCase.contentTagging`
  (specialized tagging variant), `Guardrails.permissiveContentTransformations`,
  custom fine-tuned **Adapters** (loadable weights — future moat)

## Capability scorecard (live probes)

| Capability | Verdict | Notes |
|---|---|---|
| Dictation titles | ✅ excellent, 0.4 s | titled a messy real ramble accurately |
| Action-item extraction | ✅ good | correct items; chatty preamble → fix with @Generable |
| Spoken enumeration → bullets | ✅ good | "first… second… third" → list |
| Tone shift casual→formal | ✅ good, 0.6 s | Wispr "tones" replicable |
| Deletion-only cleanup | ✅ shipped (v0.3.2) | the only safe *inline* use |
| Voice command interpretation | ❌ failed | hallucinated content; Command Mode not viable with this model |
| Translation (en↔hi) | ❌ not shippable | broken Hindi out; fake content on Hindi in |
| Hindi / Hinglish input | ❌ hard API rejection | polish fails safe → raw is used |

## Speech engines & languages (the expansion path)

- **SpeechTranscriber** (current): 30 locales, best quality —
  en ×8 (incl. en-IN), de ×3, es ×4, fr ×4, it ×2, ja, ko, pt ×2, zh ×3, yue
- **DictationTranscriber** (same framework, on-device, free): **54 locales
  including hi-IN (Hindi)** — plus ar, ru, th, id, uk, pl, he, el, cs, hu, ro,
  sk, hr, ca, fi, ms, nl, da, nb, sv, tr, vi…
- Strategy: flagship engine when the locale is supported, DictationTranscriber
  fallback for the long tail. Zero bundled models; Apple manages assets for both.
- AI Polish availability is per-language (LLM's 15); auto-disable elsewhere.

## Ranked build list (value × safety to product quality)

1. **Languages** — engine fallback + Settings picker. Unlocks Hindi + 23 more
   locales. No risk to existing English quality. Biggest market delta (India).
2. **@Generable polish** — constrained output makes the chatbot failure mode
   structurally impossible; also kills "Sure, here's…" preambles.
3. **Auto-titles + topic tags for history** (contentTagging) — searchable
   archive; background-only, can never corrupt an insertion.
4. **On-demand transforms** (Wispr Opt+1 style): formal/casual/bullets applied
   after insertion, user-invoked, previewable. The safe home for rewriting.
5. **List auto-formatting** in polish (opt-in).
6. **Skip**: Command Mode (model can't), translation (quality), long-form
   summarization inline (the rewriting trap).

## Design law learned the hard way

Use the LLM for **metadata and opt-in transforms** where mistakes are visible
and reversible. Never inline where it can silently replace the user's words.
Inline = deletion-only, guard-enforced (your words, your order, or raw wins).

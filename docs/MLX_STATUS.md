# MLX pipeline — implementation status and gaps

Companion to `MULTI_FORMAT_AND_MLX.md`. That document is the design;
this one tracks what is actually built versus what remains, so the next
person picking up the work knows exactly where to start.

Last reviewed: 2026-05-19.

## Summary

The MLX universal-fallback parser is **scaffolded end-to-end but does
not run**. The orchestration, prompt, JSON contract, mapping, settings
surface, and differential-validation harness are in place. The actual
model inference call is a stub that throws `MLXError.modelNotInstalled`,
and `mlx-swift` is not vendored. No PDF currently reaches a working MLX
path in production.

## What is implemented

| Area | File | State |
|------|------|-------|
| Parser shell conforming to `ThreadParsing` | `src/ThreadTidy/Parser/MLXThreadParser.swift` | Done |
| System prompt + JSON schema | `MLXThreadParser.swift` (`systemPrompt`) | Done |
| Response JSON parser with preamble strip + retry-aware errors | `MLXThreadParser.parseJSON` | Done |
| `Payload` → `Thread` mapping | `MLXThreadParser.mapToThread` | Done (plain text only) |
| Sync façade over async impl | `MLXThreadParser.parse(lines:)` | Done |
| Pipeline wiring (heuristic → MLX fallback) | `src/ThreadTidy/Parser/Pipeline.swift:93` | Done |
| Settings surface for preferred model | `src/ThreadTidy/Parser/Settings.swift` | Done |
| `ModelStore` API surface (`isInstalled`, paths) | `src/ThreadTidy/Parser/ModelStore.swift` | Done |
| Differential validator (heuristic vs MLX `Thread` diff) | `src/ThreadTidy/Parser/DifferentialValidator.swift` (434 lines) | Substantially done |
| Diff journal for surfacing disagreements | `src/ThreadTidy/Parser/DiffJournal.swift` | Done |
| Error taxonomy | `MLXError` in `MLXThreadParser.swift` | Done |

## What is missing

### 1. `mlx-swift` is not vendored

- `Package.swift` contains no MLX dependency.
- No `Vendor/MLX` or equivalent in the tree.
- Until this lands, none of the runtime hooks below can be filled in.

### 2. `runGeneration(prompt:)` is a stub

`MLXThreadParser.swift:174-176` throws `.modelNotInstalled` unconditionally.

The real implementation per the in-file comment:

> Build MLXLM tokenizer + KV cache, sample greedy with `max_tokens=8192`,
> `temperature=0.0`, return decoded string.

This is the single biggest blocker. Once `mlx-swift` is vendored, this
function is the only place that needs the inference glue — every other
piece of the pipeline already calls it correctly.

### 3. `ModelStore.install` is a stub

`ModelStore.swift:50` — comment says it "will land with the MLX vendor
commit (spec 05)". Needs:

- HuggingFace download of quantized weights to `modelStore.path(for:)`
- Progress reporting to the Settings UI
- SHA / size verification
- Atomic move into place on success
- Cleanup on cancellation or failure

### 4. Style preservation through the MLX path

`MLXThreadParser.mapToThread` (line 143-146) currently produces plain
`StyledLine` entries with no bold / italic / underline / hyperlink
runs. The follow-up noted in-file:

> Replay `[StyledRun]` onto `m.body` via longest-common-subsequence to
> preserve bold/italic.

Until this is done, any PDF cleaned through MLX loses inline formatting
that the heuristic Gmail path preserves. For court-facing output this
is a regression and must be done before the MLX path is enabled by
default for any format.

### 5. Long-thread chunker

The design spec describes splitting threads at safe boundaries so each
chunk fits in the model's context window. No chunker exists in the
parser today. For a small-context quantized model (e.g. 4k–8k tokens)
this is required for any realistic multi-message thread.

Needed:
- Boundary detector (between messages, never mid-body)
- Per-chunk generation
- Reconciliation of chunk outputs into a single `Thread`
- Token-budget accounting against the chosen model

### 6. Apple Mail has no working path

`Pipeline.swift:211` returns `nil` for Apple Mail with the comment
"Deferred — MLX handles it." Since MLX does not actually run, Apple
Mail PDFs currently fail with no parser available. Either:

- Ship a heuristic Apple Mail parser, **or**
- Wait until items 1–3 are done so the MLX fallback genuinely covers it.

### 7. Generation timeout / cancellation

`MLXError.generationTimeout` exists but nothing produces it. Once
`runGeneration` is real, it needs:

- A configurable timeout
- Cooperative cancellation (so the UI can abort)
- Backpressure when the user drops a second PDF mid-inference

### 8. Two-pass retry on malformed JSON

`parseJSON` already accepts a `retry` flag and tags failures by attempt
number, but the caller (`parseAsync`) never retries. The intended
behaviour per the error taxonomy is: on first JSON failure, re-prompt
with a "your previous output was not valid JSON, retry" suffix. That
retry loop is not wired up.

### 9. Settings UI for model install / progress

`SettingsSheet.swift` exists but does not yet surface install progress,
disk-space estimate, or model-switching while a parse is in flight.
Depends on item 3.

### 10. Tests

`src/ThreadTidy/Tests/threadtidy-test/diff.swift` exists for the
differential validator. There are no tests for:

- `MLXThreadParser.buildPrompt` shape
- `parseJSON` happy path and the various malformed cases
- `mapToThread` (especially empty `cc` / `bcc`, single-message threads,
  date range formatting)
- Pipeline fallback ordering (heuristic-success vs heuristic-fail vs
  unknown-format)

These can all be written today — they don't depend on MLX being real.

## Rough completion estimate

| Layer | % done |
|-------|--------|
| Orchestration + plumbing | ~80% |
| Actual MLX inference | 0% |
| Model install / download | ~10% (API surface only) |
| Style preservation through MLX path | 0% |
| Long-thread chunker | 0% |
| Tests | ~10% |

## Suggested order of work to make the MLX path real

1. Vendor `mlx-swift` and add it to `Package.swift`.
2. Implement `runGeneration` against a small known-good model end-to-end
   (no chunking yet, single short thread).
3. Implement `ModelStore.install` with HuggingFace download + progress.
4. Wire the two-pass JSON retry in `parseAsync`.
5. Add timeout + cancellation to `runGeneration`.
6. Add unit tests around prompt, JSON parsing, and mapping.
7. Implement the styled-run LCS replay so MLX output preserves bold /
   italic / hyperlinks.
8. Implement the long-thread chunker and reconciliation.
9. Either ship the Apple Mail heuristic or flip Apple Mail to the now-real
   MLX path.
10. Surface install progress and model switching in `SettingsSheet`.

## Out of scope here

- Choice of base model (covered in `MULTI_FORMAT_AND_MLX.md`).
- Per-format heuristic parsers other than Gmail/Outlook (covered there).
- The integrity checker (already format-agnostic).

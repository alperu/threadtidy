# Multi-format support + local-AI (MLX) parsing — detailed spec

Status: planning / partially deferred. The current shipping pipeline
targets Gmail "Print all" PDFs and still has open issues (paragraph
wrapping inside long bullets, sub-heading bold detection, etc.). This
document is the full design we resume from when the Gmail path
stabilises.

The spec covers four bodies of work:

1. **Format detection** — a single dispatcher that picks a parser per PDF.
2. **Per-format heuristic parsers** — Outlook, Apple Mail, ProtonMail,
   Yahoo, on top of the existing Gmail parser.
3. **MLX universal fallback** — a local instruction-tuned model used
   when no heuristic matches, when one fails, or when the user opts in.
4. **Differential validation harness** — runs heuristic and MLX on the
   same input, diffs the resulting `Thread`s, and surfaces disagreement
   as integrity warnings. This is the mechanism that catches parser
   regressions in production without manual review.

---

## 1. Reference samples in repo

Drop reference PDFs into `resource/dirtyPdf/` and add their format
signature to the table below as new ones land. The detector keys off
the signature column.

| File | Format | Format signature (in chrome) |
|------|--------|------------------------------|
| `GmailPrint.pdf` | Gmail web "Print all" | `mail.google.com/...` footer; `MM/DD/YY, h:mm AM Gmail – <subject>` page header |
| `dirtyOutlook.pdf` | Outlook web (`outlook.live.com`) | `outlook.live.com/...` footer; `MM/DD/YY, h:mm AM Mail – <name> – Outlook` header; `Outlook` logo + text top-left |
| (future) `dirtyAppleMail.pdf` | Apple Mail print | usually no footer URL; `<sender> – <subject>` in chrome; vertical-bar reply quotes; sometimes `Page N of M` |
| (future) `dirtyProton.pdf` | ProtonMail print | `mail.proton.me/...` footer |
| (future) `dirtyYahoo.pdf` | Yahoo Mail print | `mail.yahoo.com/...` footer; `Yahoo Mail - <subject>` chrome |

`script/test.sh` will be extended to iterate every file in
`resource/dirtyPdf/` and run both heuristic + MLX paths, producing a
diff report (see §6).

---

## 2. Format diff matrix

| | Gmail | Outlook | Apple Mail | ProtonMail | Yahoo |
|---|---|---|---|---|---|
| Subject location | page chrome | body, above header block | chrome | body | chrome |
| Header layout | one line `<Name> <email>     <date>` then `To:` then `Cc:` | 4 stacked rows `From / Date / To / Cc` (label ‒ value) | similar to Outlook stacked but `Subject` is part of the block | label-value, often colored | similar to Gmail one-line |
| Date format | `Wed, Apr 29, 2026 at 8:12 AM` | `Thu 4/30/2026 8:38 AM` | `On April 30, 2026 at 8:38:00 AM PDT` | ISO-ish `2026-04-30 08:38 UTC` | `Wednesday, April 30, 2026, 08:38 AM PDT` |
| Bullet glyph | vector disc (CGPDFScanner detects) | vector disc | unicode `•` | unicode `•` | unicode `•` |
| Quote markers | `[Quoted text hidden]` + `On … wrote:` + `From:/Sent:/To:/Subject:` | `On … wrote:` + `From:/Sent:/To:/Subject:` (no `[Quoted text hidden]`) | indented + vertical bar; `On … wrote:` | `> ` quote markers | `On … wrote:` + `>` markers |
| Indent bar (graphic) | none | yes | yes | none | none |
| Footer URL | `mail.google.com` | `outlook.live.com` / `outlook.office.com` | none reliable | `mail.proton.me` | `mail.yahoo.com` |

Reusable, format-agnostic pieces of the existing pipeline:

- `BulletDetector` (CGPDFScanner) — graphical disc → `isBullet`.
- `PDFTextExtractor` styled-run extraction.
- Page-chrome regex filter — needs new patterns added per format.
- Body reflow / paragraph heuristics in `ThreadParser`.
- Forwarded-tail strip.
- `IntegrityChecker` — generic, just consumes a `Thread`.

---

## 3. Architecture

```
              Raw PDF
                 │
                 ▼
       PDFTextExtractor
       (styled runs + lines + bullet glyphs)
                 │
                 ▼
         FormatDetector ────────────────┐
                 │                      │
   ┌────┬────┬───┴────┬────┬─────┐      │
   ▼    ▼    ▼        ▼    ▼     ▼      ▼
 Gmail Outlook AppleMail Proton Yahoo  Unknown
   │    │    │        │    │     │
   └────┴────┴────┬───┴────┴─────┘
                  │ heuristic Thread
                  ▼
          DifferentialValidator ◄───── MLXThreadParser
                  │                      (Llama-3.2-1B, local)
                  ▼
     Thread + IntegrityReport
                  │
                  ▼
            TPPDFRenderer
```

`FormatDetector.detect(rawText:firstPageRuns:) -> Format` returns
`{ .gmail, .outlook, .appleMail, .protonMail, .yahoo, .unknown }`
based on:

1. Footer URL regex match on the bottom 5% of page 1.
2. Top-band logo/title regex on the top 10% of page 1.
3. Date-format probe on the first detected header line.
4. Bullet glyph type (vector vs unicode) as a tiebreaker.

When two formats both match (e.g. Outlook web vs Outlook desktop), the
detector returns the higher-confidence match; ties fall through to
`.unknown` and route to the MLX parser.

---

## 4. Phase 1 — Outlook heuristic

Estimated: 1 day.

### 4.1 New files

- `Parser/FormatDetector.swift`
- `Parser/OutlookThreadParser.swift` (or extend `ThreadParser` with a
  format-strategy enum — TBD when implementing).

### 4.2 Outlook header regex

```swift
// 4-row stacked block. Each row begins with a label, then whitespace,
// then the value. Labels are localized in the wild — start with
// English only and add localizations as samples arrive.
let outlookFromRow   = #"^From\s+(?<name>.+?)\s+<(?<email>[^>]+)>\s*$"#
let outlookDateRow   = #"^(Sent|Date)\s+(?<date>.+)$"#
let outlookToRow     = #"^To\s+(?<to>.+)$"#
let outlookCcRow     = #"^Cc\s+(?<cc>.+)$"#

// Subject is the first bold line above the From row. If no bold line
// is found, fall back to the page-chrome subject.
```

### 4.3 Date parsing

`DateFormatter` chain attempted in order:

1. `EEE M/d/yyyy h:mm a` (Outlook web)
2. `M/d/yyyy h:mm a` (Outlook desktop without weekday)
3. fall through to `String` (preserve verbatim)

The `Email.date` field stores the verbatim string for display; a
parsed `Date` is used only for sort/normalisation.

### 4.4 Chrome filtering

Extend `chromeLineRegexes` in `PDFTextExtractor`:

```swift
#"^\d{1,2}/\d{1,2}/\d{2,4},\s*\d{1,2}:\d{2}\s*(AM|PM)\s+Mail\s+-\s+.+\s+-\s+Outlook$"#,
#"outlook\.(live|office)\.com/.*"#,
#"^Page\s+\d+\s+of\s+\d+$"#,  // Apple Mail style; harmless for Outlook
```

### 4.5 Wiring

`Pipeline.run` (new file or in app entry) becomes:

```swift
let raw = PDFTextExtractor.extract(url)
let format = FormatDetector.detect(raw)
let parser: ThreadParsing = {
  switch format {
    case .gmail:     return GmailThreadParser()
    case .outlook:   return OutlookThreadParser()
    case .appleMail: return AppleMailThreadParser()  // phase 1b
    case .protonMail, .yahoo, .unknown:
                     return MLXThreadParser()        // phase 2
  }
}()
let thread = try parser.parse(raw)
```

### 4.6 Phase 1 tests

- Add `dirtyOutlook.pdf` smoke test to `script/test.sh`.
- Snapshot the rendered output PDF text into a golden under
  `src/ThreadTidy/Tests/Goldens/dirtyOutlook.txt` and diff in CI.

---

## 5. Phase 2 — MLX universal fallback

Estimated: 3–4 days.

Why AI fallback: parsing is brittle across email-client quirks
(line-wrap, signature variations, weird Unicode, mixed languages). A
small instruction-tuned model handles them robustly with no per-format
engineering. Local execution keeps court-confidential documents off
the cloud.

### 5.1 Dependencies

```swift
.package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.0"),
.package(url: "https://github.com/ml-explore/mlx-swift-examples",
         from: "2.21.0"),
```

`MLXLMCommon` and `LLMEval` modules in `mlx-swift-examples` handle
tokenization, KV-cache, and streaming generation. Vendor both repos
under `src/libs/` for offline / reproducible builds (same pattern as
TPPDF and PDFium).

### 5.2 Model choice

| Model | Disk (4-bit) | Inference on M2 (28-msg thread) | Accuracy |
|-------|--------------|----------------------------------|----------|
| `mlx-community/Llama-3.2-1B-Instruct-4bit` | ~700 MB | 5–10 s | acceptable for clean threads |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | ~2.0 GB | 15–30 s | noticeably better on edge cases |
| `mlx-community/Phi-3.5-mini-instruct-4bit` | ~2.2 GB | 20–35 s | strong JSON output, slower |

Default: Llama-3.2-1B. 3B opt-in for ≥16 GB RAM users via Settings.

### 5.3 Distribution

1. **Bundled** — ship inside .app (~1 GB app size). Zero first-run
   latency. Simplest UX. Easiest notarization.
2. **First-run download** — fetch from HuggingFace, cache to
   `~/Library/Application Support/ThreadTidy/models/`. Smaller initial
   download. Adds HF dependency.

Recommend (2) with a "download now" button shown the first time the
user drops a non-Gmail PDF, plus a Settings panel to pre-warm.

### 5.4 Prompt

```
System: You are an email-thread extractor. Output ONLY valid JSON
matching the schema below — no prose, no Markdown, no commentary. Do
not summarize, paraphrase, or alter body content. Preserve every
character of each email body verbatim.

Schema:
{
  "subject": "<thread subject>",
  "messages": [
    {
      "from_name":  "<sender display name>",
      "from_email": "<sender email>",
      "date":       "<verbatim date string>",
      "to":         "<verbatim To header value>",
      "cc":         "<verbatim Cc header value, or empty>",
      "bcc":        "<verbatim Bcc header value, or empty>",
      "body":       "<verbatim author text only — no signatures
                     collapsed, no quotes, no forwarded blocks>"
    }
  ]
}

Strip:
- page-header banners (timestamps, app name, footer URLs)
- "[Quoted text hidden]" markers
- duplicated forwarded blocks: any line of the form
  "On <date> <name> <email> wrote:" plus everything after, OR a block
  starting with "From:" "Sent:" "To:" "Subject:" rows

Output JSON only.

User: <raw text from PDFKit, chunk-by-chunk if >6k tokens>
```

### 5.5 Chunking long threads

For threads >~6k tokens of input, split at heuristically-detected
message boundaries (Gmail header regex hit, Outlook From-row hit,
`On … wrote:` boundary) and run the model per-message, then concat.
If no boundary is detectable, sliding-window with 512-token overlap
and de-dupe by `from_email + date` key.

### 5.6 Validation pipeline

```
[input PDF]
    │
    ▼ extract raw text + styled runs
    │
    ▼ MLX generate response (max_tokens ≈ 8192, temperature 0.0)
    │
    ├── parse as JSON
    │     │ success ─→ map to Thread → DifferentialValidator
    │     └ failure ─→ retry once with corrective prompt
    │                  │ success ─→ Thread → DifferentialValidator
    │                  └ failure ─→ fall back to heuristic, mark
    │                              integrity report severity = warning
```

### 5.7 Style preservation

The MLX model returns plain text. Bold/italic/underline/links live in
`PDFTextExtractor`'s `StyledRun` stream, not in the AI output.
Reconciliation: after MLX returns the cleaned `body` for a message,
walk the original `[StyledRun]` for that message's region and replay
the styling onto matching substrings of the cleaned text using
longest-common-subsequence alignment. Fall back to plain text if the
alignment is ambiguous (>10% characters unmatched).

---

## 6. Differential validation harness (algorithm vs AI)

This is the mechanism the user explicitly asked for: every time we
parse a Gmail / Outlook / etc. PDF with a heuristic parser, we *also*
run the MLX parser on the same raw text and compare the two
`Thread`s. Disagreement is a strong signal that the heuristic has a
bug (or that the AI has hallucinated — both are useful to surface).

### 6.1 Modes

`Settings.differentialMode`:

- `off` — heuristic only (default in production once stable).
- `sample` — run differential on every Nth file (N = 10) and log
  disagreements. Cost-bounded; safe to leave on.
- `always` — run differential on every file. Used during development
  and on CI golden corpus.
- `ai-only` — bypass heuristic; for debugging the model.

### 6.2 New module: `Parser/DifferentialValidator.swift`

```swift
public struct ThreadDiff {
    public var messageCountDelta: Int       // mlx.count - heur.count
    public var perMessageDiffs: [MessageDiff]
    public var subjectMismatch: Bool
    public var severity: IntegritySeverity
    public var humanSummary: String         // for IntegrityReport
}

public struct MessageDiff {
    public var index: Int
    public var fromMatches: Bool
    public var dateMatches: Bool
    public var toMatches: Bool
    public var ccMatches: Bool
    public var bodyEditDistance: Double     // 0.0 == identical, 1.0 == disjoint
    public var bodyMissingFromHeuristic: [String]   // lines AI saw, parser dropped
    public var bodyAddedByHeuristic:    [String]    // lines parser kept that AI removed
    public var notes: [String]
}

public enum DifferentialValidator {
    public static func diff(heuristic: Thread, ai: Thread) -> ThreadDiff
}
```

### 6.3 Comparison rules

**Subject** — case-insensitive, whitespace-collapsed equality. RE: /
FW: prefix differences are normalised away.

**Message count** — exact match required. Off-by-one is the most
common heuristic bug (forwarded tail mis-stripped, header mis-detected
as body) so this is a high-signal check.

**Per-message alignment** — pair messages by:
1. exact `(from_email, date)` match if both sides parsed those fields,
2. else fall back to `from_email` + position-in-thread,
3. else position-in-thread only.
Unpaired messages count as a count-delta diff.

**`from_name` / `from_email`** — case-insensitive equality after
trimming. `<a@b.com>` vs `a@b.com` normalised away.

**`date`** — parse both via `DateFormatter` chain and compare to
within 1 minute. If parsing fails on either side, fall back to
verbatim string equality after whitespace collapse.

**`to` / `cc` / `bcc`** — parse into address sets, compare set
equality. Display-name differences are ignored (only emails compared).

**`body`** — the most expensive comparison.
1. Strip both bodies of all whitespace runs → single space.
2. Compute Jaro-Winkler similarity (cheap, good for human prose).
3. If similarity < 0.95, run a line-level LCS to produce
   `bodyMissingFromHeuristic` / `bodyAddedByHeuristic` lists for the
   integrity report.
4. Bullet markers (`•`, `-`, `*`) are normalised before comparison;
   they're a frequent false-positive source.

### 6.4 Severity ladder

| Disagreement | Severity |
|---|---|
| message-count mismatch | error |
| any `from_email` mismatch | error |
| any date mismatch >1 min | warning |
| any `to` set mismatch | warning |
| body Jaro-Winkler 0.85–0.95 | warning |
| body Jaro-Winkler <0.85 | error |
| subject mismatch (after normalisation) | warning |

The validator's overall severity is the max of all per-field severities.

### 6.5 IntegrityReport surface

`IntegrityReport.summary` gains a "differential" line. UI shows a
badge per message:

- **green** — heuristic and AI agree.
- **amber** — disagreement, severity=warning. User can click to view a
  side-by-side diff.
- **red** — severity=error. The renderer falls back to whichever side
  the user trusts more, configurable; default is **AI** for unknown
  formats and **heuristic** for known formats.

### 6.6 Disagreement journal

Every disagreement (in `sample` or `always` mode) is appended to
`~/Library/Application Support/ThreadTidy/diff-log.jsonl`. Each line:

```jsonc
{
  "ts": "2026-05-02T14:30:11Z",
  "source_sha256": "<hex>",
  "format": "outlook",
  "severity": "warning",
  "diff": { /* serialized ThreadDiff */ },
  "raw_text_excerpt_first_1k": "<string>"
}
```

This becomes the regression corpus: when we fix a parser bug, we add
the offending excerpt to `src/ThreadTidy/Tests/Corpus/` and ensure
both parsers agree on it going forward.

### 6.7 CLI subcommand

`threadtidy diff <file.pdf>` — runs both parsers, prints the
`ThreadDiff` as colourised text. Used during development for quick
inspection without firing up the GUI.

`threadtidy diff --corpus resource/dirtyPdf/` — batch over a folder,
prints a Markdown report:

```
# Differential report — 2026-05-02

| File | Format | Msgs (heur/ai) | Subject | Worst body sim | Severity |
|------|--------|----------------|---------|----------------|----------|
| GmailPrint.pdf  | gmail   | 28/28 | match | 0.99 | ok |
| dirtyOutlook.pdf| outlook | 12/13 | match | 0.91 | warning |
```

This report is the dashboard we use to decide when a heuristic parser
is "production-ready" for a given format.

### 6.8 CI gate

`script/test.sh` runs `threadtidy diff --corpus resource/dirtyPdf/`
and fails the build if any file's severity is `error`. `warning` is
informational only — flaky-test territory if gated.

### 6.9 Cost

MLX inference is the bottleneck (~5–10 s per thread on M2). In
`sample` mode at N=10 the amortised cost is sub-second per file. In
`always` mode the user sees a "running differential check…" spinner;
acceptable for the courtroom-prep workflow where each file is opened
deliberately, not in batch.

---

## 7. Acceptance criteria

### Phase 1 (Outlook heuristic)

- `dirtyOutlook.pdf` parses end-to-end without manual correction.
- Output PDF passes the existing renderer golden-text check.
- `threadtidy diff dirtyOutlook.pdf` reports severity ≤ warning when
  Phase 2 lands.

### Phase 2 (MLX fallback)

- Llama-3.2-1B parses the Gmail reference PDF and matches the
  heuristic parser's `Thread` to within 1 message (no missed/added
  messages).
- Llama-3.2-1B parses `dirtyOutlook.pdf` correctly without any
  Outlook-specific code paths.
- Inference latency on M2 ≤ 15 s for 28-message thread.
- Falls back to heuristic on JSON-parse failure without crashing.
- Integrity report surfaces "AI-parsed" vs "heuristic-parsed" badge.

### Phase 3 (Differential)

- `DifferentialValidator.diff` is unit-tested on hand-crafted
  `Thread` pairs covering each severity rung.
- `threadtidy diff --corpus resource/dirtyPdf/` runs in CI and gates
  on `error`-level disagreements.
- Disagreement journal accumulates ≥ 50 real-world entries within
  first month of dogfooding (sample mode).

---

## 8. Open questions

1. Keep heuristic Gmail parser as the fast path even after MLX lands?
   (Probably yes — sub-second vs 10s.)
2. Force-select an engine in settings, or always auto-detect? (Probably
   both — auto by default, manual override.)
3. Model bundled vs downloaded? (Probably downloaded with progress UI.)
4. Cache parsed `Thread` on disk keyed by source PDF SHA-256 so
   reprocessing is instant?
5. Per-message AI confidence scores? (Llama doesn't expose
   well-calibrated logprobs in MLX-Swift today; revisit.)
6. When heuristic and AI disagree at `error` severity and we can't
   tell which is right, do we ask the user to choose, or pick a
   default and surface a banner?

## 9. Known unknowns

- MLX Swift on macOS 13 vs 14+ — minimum-OS implications.
- Quantized 1B model accuracy on multi-page non-English email threads.
- App-Store reviewer reaction to a downloaded ML model.
- Code-signing impact of vendoring MLX (it bundles native blobs).
- Jaro-Winkler tuning thresholds (0.85 / 0.95) — pulled from prior
  art, may need recalibration once the corpus exists.

---

## 10. File / module summary

New files:

- `src/ThreadTidy/Parser/FormatDetector.swift`
- `src/ThreadTidy/Parser/OutlookThreadParser.swift`
- `src/ThreadTidy/Parser/AppleMailThreadParser.swift` (Phase 1b)
- `src/ThreadTidy/Parser/MLXThreadParser.swift` (Phase 2)
- `src/ThreadTidy/Parser/DifferentialValidator.swift` (Phase 3)
- `src/ThreadTidy/Parser/Pipeline.swift` (orchestrator)
- `src/ThreadTidy/Tests/Corpus/` (regression excerpts)

Modified files:

- `Parser/ThreadParser.swift` → split Gmail-specific bits behind a
  `ThreadParsing` protocol so other formats slot in.
- `Parser/Models.swift` → add `Thread.format: Format`,
  `Thread.parsedBy: ParserKind`.
- `Parser/IntegrityChecker.swift` → consume `ThreadDiff` and fold
  differential warnings/errors into the existing report.
- `Renderer/TPPDFRenderer.swift` → render the parsed-by badge if
  enabled in Settings.
- `script/test.sh` → run differential corpus check.

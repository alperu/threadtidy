# ThreadTidy

ThreadTidy is a native macOS app that turns a noisy Gmail "Print all"
PDF into a clean, court-ready threaded PDF. Drag the dirty PDF onto the
drop zone and ThreadTidy rebuilds the conversation as a tidy document:
a title page with a numbered **Index of Communications**, then one clean
entry per message — each on its own page with a **clickable navigation
strip** (`1 2 [3] 4 5`) so a reviewer can jump straight to any message
and back to the index. It preserves **every word the senders wrote** — To, Cc,
Bcc, timestamps, signatures, attachment listings, and inline styling
(bold, italic, underline, hyperlinks). It strips **only** print chrome:
page headers and footers, the Gmail logo, `[Quoted text hidden]`
markers, and the duplicated forwarded/re-quoted message blocks that
Gmail repeats inside every reply. ThreadTidy runs **fully offline** —
no network access, no telemetry, nothing leaves your Mac.

## Why this exists

Gmail's "Print all" export is unusable for court filings. A
conversation that is really a 14-page exchange balloons to 19 pages of
header banners, repeated quoted text, and Gmail UI chrome. Reviewers
then have to wade through duplicated forwards and `[Quoted text hidden]`
placeholders to follow who said what, when.

ThreadTidy produces a tidy version of the same thread — a clear title,
a date range, a numbered timeline, and one clean entry per message —
**without altering a single word of the underlying email content**. The
result reads like the conversation actually happened, in order, once.

## What the cleaned thread looks like

The pages below are a **synthetic illustration** — fictional names and
content, not a screenshot and not a real email. They show the two kinds
of page ThreadTidy produces: a title page with a numbered **Index of
Communications**, and one page per message. In the produced PDF **every
ordinal is a live link** — click a number to jump to that message, click
**Index** to jump back — so a court reader can navigate a long thread
without scrolling.

**Page 1 — Index of Communications** (one numbered row per message):

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                        │
│                  Re: Project Falcon — kickoff schedule                 │
│                    Apr 28, 2026  –  Apr 30, 2026                        │
│                                                                        │
│   Index of Communications                                              │
│     1.  Apr 28, 2026  8:12 AM   Jane Doe    → John Smith   Re: Falcon… │
│     2.  Apr 29, 2026  9:03 AM   John Smith  → Jane Doe     Re: Falcon… │
│     3.  Apr 30, 2026  8:38 AM   Jane Doe    → John Smith   Re: Falcon… │
│     4.  Apr 30, 2026 10:15 AM   John Smith  → Jane Doe     Re: Falcon… │
│     5.  Apr 30, 2026  4:47 PM   Jane Doe    → John Smith   Re: Falcon… │
│                                                                        │
│           (each row number links to that message's page)               │
│                                                                        │
└──────────────────────────────────────────────────────────────────────┘
```

**A message page** — note the navigation strip across the top: every
ordinal `1 2 3 4 5` is listed, the current one **bold and bracketed**,
with a jump-back link to the Index:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ↩ Index      1   2  [3]  4   5              Message 3 of 5             │
│  ────────────────────────────────────────────────────────────────────│
│   3.                                                                   │
│   From:     Jane Doe <jane.doe@example.com>                            │
│   To:       John Smith <john.smith@example.com>                        │
│   Cc:       Team List <team@example.com>                               │
│   Date:     Wed, Apr 30, 2026 at 8:38 AM                               │
│   Subject:  Re: Project Falcon — kickoff schedule                      │
│                                                                        │
│   Hi John,                                                             │
│                                                                        │
│   Confirming the kickoff for next Tuesday. The agenda is attached —    │
│   please review the **budget section** before we meet. The vendor      │
│   quote is _provisional_ and the signed SOW is at                      │
│   https://example.com/sow.                                             │
│                                                                        │
│   Thanks,                                                              │
│   Jane                                                                 │
│                                                                        │
│   Attachments:                                                         │
│     • Falcon-Agenda.pdf      (84 KB)                                   │
│     • Budget-Q2.xlsx         (212 KB)                                  │
└──────────────────────────────────────────────────────────────────────┘
```

In the real output `**budget section**` renders as actual bold text,
`_provisional_` as italic, and the URL as a live hyperlink — the ASCII
markers above only stand in for styling the page here cannot show. Each
message keeps its full stacked header (Cc and Bcc rows appear only when
present), and the `1 2 [3] 4 5` strip plus every Index row number are
clickable cross-references in the produced PDF.

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 15+ command-line tools (Swift toolchain) for building from source
- Apple Silicon recommended — the experimental MLX path is Metal-based
- Network access on the **first** build only, so SwiftPM can fetch the
  ML packages (a few hundred MB); subsequent builds are offline

## Quick start / Building

There is one canonical build command:

```sh
./script/build-app.sh
```

This produces a ready-to-run `ThreadTidy.app`. The convenience symlink
`build/ThreadTidy.app` always points at the most recent build, which
lives in its own versioned folder under `build/builds/` (e.g.
`build/builds/v0.1.0-7/ThreadTidy.app`) so older builds stick around
for side-by-side comparison.

What the script does, in order:

1. Bumps the monotonic build number in `build/version/BUILD_NUMBER` and
   stamps it into `Info.plist` as `CFBundleVersion`.
2. Builds the `ThreadTidy` SwiftPM product in Release.
3. Compiles `mlx.metallib` from MLX's vendored Metal kernels.
4. Assembles a `.app` bundle (`Contents/MacOS`, `Contents/Resources`,
   `Contents/Frameworks`), bundling `libpdfium.dylib` and the metallib,
   patching `@rpath` so the bundled dylib resolves.
5. Ad-hoc signs the app so it launches on the local Mac.

Flags:

- `--no-bump` — build without incrementing the build number.
- `--print` — print the current build number and exit.
- `--regen-icon` — regenerate `AppIcon.icns`.
- `--dist` — also produce a distributable `ThreadTidy.zip` (strips the
  quarantine attribute; recipients still right-click → Open since it is
  not notarized).
- `--notarize` — sign with a Developer ID, submit to Apple's notary
  service, staple the ticket, and produce a signed zip that launches
  cleanly on any Mac (implies `--dist`).

> **First build:** SwiftPM fetches `mlx-swift`,
> `mlx-swift-examples`, and `swift-transformers` over the network
> (a few hundred MB). TPPDF and libpdfium are already vendored in the
> repo, so only the ML packages are downloaded, and only once.

## Using the app

1. Launch `ThreadTidy.app` (e.g. `open build/ThreadTidy.app`).
2. Drag a Gmail "Print all" PDF onto the dashed drop zone.
3. ThreadTidy cleans the thread and saves the result to `~/Downloads`.
4. You can also drag the cleaned PDF straight out of the window into
   Finder, Mail, or any drop target.

A cleaned copy is also kept in `$TMPDIR` while the app is running, so
you can drag it out repeatedly without re-processing.

## Multi-format & on-device LLM (experimental / roadmap)

The **Gmail "Print all" pipeline is the fully-working, supported path**.
Beyond it, the repo contains scaffolding for broader format coverage:

- **Heuristic parsers for other clients** — Outlook and Apple Mail
  parsers are partially implemented. Outlook's print layout differs
  structurally from Gmail (only the most recent message has a stacked
  header; older messages are inlined as `On … wrote:` / `From: / Sent:
  / To: / Subject:` blocks), and the dispatcher detects format per PDF.
- **On-device MLX universal fallback** — a local, instruction-tuned LLM
  intended to parse any email PDF when no heuristic matches. The
  orchestration, prompt, JSON contract, `Thread` mapping, settings
  surface, and a differential-validation harness (heuristic vs. MLX) are
  in place, **but the actual model inference call is currently a stub**
  and there is no working MLX path in production yet.

This is honest, in-progress work — treat it as a roadmap, not a
feature. For the full design and a precise status breakdown, see:

- `docs/MULTI_FORMAT_AND_MLX.md` — the multi-format + MLX design spec.
- `docs/MLX_STATUS.md` — what is built vs. what remains.

## What it does NOT do

- It does **not** summarize, redact, or otherwise alter email body text.
  Every word the senders wrote is preserved verbatim.
- It does **not** extract inline body images. In v1 they appear as
  `[image]` placeholders (attachment images included); full image
  round-tripping is on the roadmap.
- It does **not** phone home or require any network access at runtime.
  (Only the first source build touches the network, to fetch
  dependencies.)

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Drop zone rejects the file | Not a PDF, or the sandbox blocked the read | Drop a `.pdf`; check Console for sandbox denials |
| Empty output PDF | Source PDF is image-only (scanned) | Run OCR first (Preview → Export → PDF with OCR) |
| Wrong message boundaries | Source isn't a Gmail "Print all" export | Confirm the source PDF has `https://mail.google.com/...` footers on every page |
| Style not preserved | Source PDF used embedded fonts without bold/italic variants | Inherent limitation; output falls back to upright text for that run |

To sign and notarize a build for distribution to other Macs, run
`./script/build-app.sh --notarize`; tagged releases are built and
signed automatically via GitHub Actions. See
`docs/SIGNING_AND_NOTARIZATION.md` for credential setup.

## Folder layout

```
ThreadTidy/
├── README.md                       # this file
├── LICENSE                         # Polyform Noncommercial 1.0.0
├── docs/
│   ├── MULTI_FORMAT_AND_MLX.md     # multi-format + MLX design spec
│   ├── MLX_STATUS.md               # MLX implementation status
│   └── SIGNING_AND_NOTARIZATION.md # signing / notarization setup
├── src/
│   ├── ThreadTidy/                 # Swift sources (App, Parser, Renderer, Resources)
│   └── libs/
│       ├── TPPDF/                  # vendored PDF rendering library
│       └── pdfium-mac/             # vendored libpdfium
├── script/
│   └── build-app.sh                # canonical build script
└── build/
    └── version/
        └── BUILD_NUMBER            # monotonic build counter (tracked in git)
```

## License

ThreadTidy is licensed under the **Polyform Noncommercial License
1.0.0** — free to use, modify, and share for any **noncommercial**
purpose. See the [LICENSE](LICENSE) file for the full terms. ThreadTidy
ships as part of the soundsuite package.

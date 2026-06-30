# ThreadTidy — Design Report

## 1. What we're building

A self-contained macOS application that:

1. Opens to a single window with a drop zone and an app icon.
2. Accepts a Gmail "Print all" PDF (a `dirtyGmailPrintPdf`) by drag-and-drop.
3. Produces `clean_email_thread.pdf` written into a temporary folder inside the app's container.
4. Surfaces the produced PDF as a draggable item — the user drags it out of the window into Finder, Mail, or any drop target, exactly like dragging an attachment out of an email.
5. Ships as a proper `.app` bundle: signed, with `Info.plist`, an icon set, and no external runtime dependencies.

## 2. Reference samples (in `resource/`)

| File | Pages | Size | Role |
|------|-------|------|------|
| `resource/dirtyPdf/GmailPrint.pdf` | 19 | 798 KB | Input: Gmail "Print all messages" output |
| `resource/cleanPdf/clean_email_thread.pdf` | 14 | 45 KB | Target output style |

The dirty PDF includes Gmail page chrome on every page (`MM/DD/YY, H:MM AM   Gmail – <subject>` at the top, the long Gmail thread URL and `N/Total` at the bottom), the Gmail logo and account name on page 1, repeated `[Quoted text hidden]` markers, duplicated forwarded `From:/Sent:/To:/Cc:/Subject:` blocks (Gmail re-quotes the prior thread inside every reply), `[CAUTION EXTERNAL]` security banners, and signature blocks with image logos.

The clean PDF strips page chrome and the Gmail logo, deduplicates the quoted reply chain so each message appears exactly once, numbers each message (`1.`, `2.`, …), and uses a clean header for every message: `Date / From / To / Cc`. Email addresses are rendered as live blue links.

## 3. Hard constraint (from user, added during design)

> "It should not delete or alter any text within the emails. It shall keep the CC BCC time all that is important. Keep text styling like bold underline italic etc."

This rules out the otherwise tempting "trim signatures / drop disclaimers / drop attachment listings" heuristic. Inside each unique email body, every character the sender wrote is preserved. The cleaning pass is therefore narrower than the reference clean PDF suggests, and is limited to:

| Allowed to strip | Reason |
|---|---|
| Top-of-page `MM/DD/YY, H:MM AM   Gmail – <subject>` band | Gmail print chrome, not part of any email |
| Bottom-of-page `https://mail.google.com/...   N/Total` band | Gmail print chrome |
| The Gmail logo + account label on page 1 | Gmail print chrome |
| The bold subject + `N messages` block above the first message | Gmail print chrome (we render our own title from the subject) |
| `[Quoted text hidden]` placeholders | Gmail UI artifact, not author text |
| The repeated forwarded block under each reply (`From: / Sent: / To: / Cc: / Subject:` followed by the prior message's body) | Pure duplication of a message that already appears earlier as its own thread entry; deduplicating preserves all unique author text |

Everything else — `[CAUTION EXTERNAL]` banners, confidentiality notices, attachment file listings, signature images and addresses, blue-on-white styled blocks — is part of the email as the sender sent it and is preserved verbatim with its original styling.

## 4. Language and library choice

**Recommended stack: Swift 5.9+ / SwiftUI / PDFKit / WebKit (WKWebView), built with Xcode for macOS 13+.**

| Concern | Choice | Why |
|---|---|---|
| App framework | SwiftUI (with one AppKit bridge for drag) | Native window, drop zone, icon, menu bar all come for free. Smallest possible bundle. |
| PDF reading | `PDFKit` (`PDFDocument`, `PDFPage.attributedString`) | Apple framework; gives us per-page `NSAttributedString` including font names — we can detect `*-Bold`, `*-Italic`, italic/oblique traits, underline attributes, and link annotations directly. No third-party parser. |
| Layout & styling | HTML + CSS template rendered in `WKWebView` | Reproducing the clean PDF's layout (numbered messages, indented header rows, link styling, page numbers) is far easier in HTML than in Core Text. WKWebView's `createPDF(configuration:)` (macOS 11+) renders to PDF with selectable text and live links. |
| Icon | `.icns` generated from a single source PNG via `iconutil` | Standard macOS icon pipeline. |
| Drag in | SwiftUI `.onDrop(of: [.pdf, .fileURL], …)` | Native. |
| Drag out | SwiftUI `.onDrag { NSItemProvider(contentsOf: tmpURL) }` (with file representation) | Lets Finder/Mail receive the produced PDF as a real file. |
| Temp file location | `FileManager.default.temporaryDirectory.appendingPathComponent("clean_email_thread.pdf")` | Inside the app's container; cleaned up by the OS, but persists for the session so the user can drag it out repeatedly. |

### Alternatives considered

| Stack | Verdict |
|---|---|
| Python + PyMuPDF + ReportLab + py2app | Best parser ergonomics, but bundles a Python runtime (~30 MB), drag-out is awkward (needs PyObjC), and signing/notarizing a py2app build is fragile. Not "self-contained Mac application" feeling. |
| Electron + pdf.js | Heavyweight, non-native drag, no benefit for this workload. Rejected. |
| Swift + Anthropic API (Claude) for parsing | Gives perfect message segmentation and de-duplication trivially, but breaks "self-contained" (needs network + API key). Worth keeping in mind as an optional power mode. |
| Pure Core Text rendering instead of HTML | Possible, but every layout tweak (page numbering, indented "From: Name <email>" rows where only the email is a link, top title) becomes 30+ lines of `CTFramesetter` work that 5 lines of HTML+CSS solve. |

## 5. Parsing pipeline

```
PDF file
  │
  ▼
[PDFKit] PDFDocument → for each page: NSAttributedString + link annotations + page bbox
  │
  ▼
[Chrome stripper] discard runs whose y-position is in the top-30pt or bottom-30pt band;
                  discard the page-1 Gmail logo region; discard the "N messages" preamble
  │
  ▼
[Tokenizer] flatten into a stream of {text, bold, italic, underline, link?, lineBreak?}
            tokens that preserves original styling
  │
  ▼
[Segmenter] walk the token stream; a new email starts at a line matching:
              <Display Name> <email@host>     <Day, Mon DD, YYYY at H:MM AM/PM>
            (the timestamp is right-aligned on the same visual line in the source PDF;
            in extracted text it ends the line). Followed by `To:` and optional `Cc:`/`Bcc:`.
  │
  ▼
[Body collector] for each message, capture all tokens until the next message header,
                 then trim trailing artifacts: lines exactly equal to "[Quoted text hidden]";
                 a contiguous tail block beginning with bold "From:" + "Sent:" + "To:"
                 + "Subject:" (the forwarded duplicate). Nothing inside the body is altered.
  │
  ▼
[Dedup pass] (cheap sanity check) verify every author message kept appears once;
             the forwarded-tail strip in the previous step is what actually deduplicates
  │
  ▼
[Model] Thread { subject, dateRange, messages: [Email{ from, fromEmail, to, cc, bcc, date, bodyHTML }] }
  │
  ▼
[HTML renderer] Mustache-ish template → styled HTML string
  │
  ▼
[WKWebView] loadHTMLString → createPDF → /tmp/clean_email_thread.pdf
```

### Why detecting message boundaries is reliable here

In a Gmail "Print all" PDF every message starts with the same shape: a single line containing the sender's display name, their email in angle brackets, and a right-aligned timestamp matching the regex `^\w{3},\s\w{3}\s\d{1,2},\s\d{4}\sat\s\d{1,2}:\d{2}\s(AM|PM)$`. The line that follows always begins with `To:`. False positives inside bodies are extremely unlikely because the timestamp form is specific.

### Why the forwarded-block strip preserves all author text

Gmail's print view duplicates content: when Jane replies to Mary, the printed PDF shows Jane's reply followed by `From: Mary ... Sent: ... Subject: ...` followed by Mary's full prior message. But Mary's prior message also appears earlier in the same PDF as its own top-level entry. Stripping the forwarded tail therefore removes only duplicate copies; every author's text appears once.

## 6. Style preservation

`PDFPage.attributedString` exposes:

- `NSFontAttributeName` — we read the PostScript font name; suffixes `-Bold`, `-BoldOblique`, the `NSFontDescriptor.SymbolicTraits.traitBold` and `.traitItalic` traits map to `<strong>` / `<em>`.
- `NSUnderlineStyleAttributeName` — when present and non-zero → `<u>`.
- `NSLinkAttributeName` and the page's `PDFAnnotation` of type `link` with a `URL` action — map to `<a href="…">`.
- Color: blue runs (the Gmail-printed `mailto:` style) are preserved by wrapping in `<a href="mailto:…">` so the link survives in the output PDF too.

Output HTML uses semantic tags only — no inline styles for bold/italic/underline — so the visual style follows the CSS in `template.html` and the result is also accessible.

## 7. Drag-in / drag-out behavior

**Drag in.** The drop view declares `[.pdf, .fileURL]` as accepted UTIs. On drop we resolve the file URL, kick off the pipeline on a background queue, and on completion replace the drop-zone view with a thumbnail of the cleaned PDF.

**Drag out.** The thumbnail view sets `.onDrag { NSItemProvider(object: cleanedURL as NSURL) }`. macOS treats this as a real file promise, so dropping it in Finder copies the PDF, dropping it in Mail attaches it. The temp file lives at `NSTemporaryDirectory()/clean_email_thread.pdf` and is rewritten on each new drop. We do not delete it — the OS reaps the temp directory.

## 8. App bundle layout

```
ThreadTidy.app/
└── Contents/
    ├── Info.plist                 # bundle id, doc types (.pdf), min macOS, hi-res capable
    ├── MacOS/ThreadTidy        # the binary
    ├── Resources/
    │   ├── AppIcon.icns           # generated from src/.../Resources/Icon.png via iconutil
    │   ├── template.html          # output HTML template
    │   └── style.css              # output styling
    └── _CodeSignature/            # populated at signing time
```

Build command:

```sh
xcodebuild -project src/ThreadTidy.xcodeproj \
           -scheme ThreadTidy \
           -configuration Release \
           -derivedDataPath build
```

Signing/notarizing for distribution outside the App Store:

```sh
codesign --deep --force --options runtime \
         --sign "Developer ID Application: <Your Name>" \
         build/Build/Products/Release/ThreadTidy.app
xcrun notarytool submit ThreadTidy.zip --keychain-profile <profile> --wait
xcrun stapler staple ThreadTidy.app
```

## 9. Source layout (in `src/`)

```
src/
└── ThreadTidy/
    ├── App/
    │   ├── ThreadTidyApp.swift     # @main, single window, fixed size
    │   └── ContentView.swift          # drop zone + result view
    ├── Parser/
    │   ├── Models.swift               # Thread, Email, StyledRun, Link
    │   ├── PDFTextExtractor.swift     # PDFKit → styled token stream, page-band stripping
    │   └── ThreadParser.swift         # tokens → Thread (segmentation, dedup)
    ├── Renderer/
    │   ├── HTMLRenderer.swift         # Thread → HTML string
    │   └── PDFExporter.swift          # WKWebView.createPDF → file URL
    ├── Resources/
    │   ├── template.html
    │   ├── style.css
    │   ├── Info.plist
    │   └── Assets.xcassets/AppIcon.appiconset/  (icon PNGs go here)
    └── Package.swift                  # alternate `swift build` path for headless testing
```

## 10. Open questions / known gaps

- **Inline images in bodies** (e.g., a company logo embedded in a sender's signature). PDFKit gives us no clean way to round-trip an embedded raster image into the output HTML without rasterizing the page. Practical answer: these are rendered as a small `[image]` placeholder in v1, with an issue logged to extract them via `PDFPage.thumbnail(of:for:)` clipped to the image bounding box and embed as base64 PNG in v2. Document this limitation in the README so users aren't surprised.
- **Tables and bullet lists.** Gmail prints `<ol>` / `<ul>` as text with leading numbers / bullets. We preserve them as text — visually identical, semantics lost. Acceptable for v1.
- **CJK / RTL text.** PDFKit handles extraction; the HTML template uses `lang="auto"` — should work but untested.
- **Very large threads (>500 messages).** WKWebView pagination handles this fine but tested up to 19 pages only.

## 11. Build-out task list

1. Generate Xcode project skeleton with App + parser + renderer targets.
2. Implement `PDFTextExtractor` — page-band chrome stripping is the trickiest piece; test against `resource/dirtyPdf/GmailPrint.pdf`.
3. Implement `ThreadParser` — message segmentation regex, forwarded-tail stripping, `[Quoted text hidden]` removal.
4. Implement `HTMLRenderer` + `PDFExporter` — produce output close to `resource/cleanPdf/clean_email_thread.pdf` byte-for-byte readable equivalence.
5. Implement drop-in / drag-out UI in `ContentView`.
6. Make app icon (`Icon.png` 1024×1024) and run `iconutil` to produce `AppIcon.icns`.
7. Add `Info.plist` with `CFBundleDocumentTypes` for PDF, `LSMinimumSystemVersion` 13.0, `NSHighResolutionCapable` true.
8. Sign with Developer ID, notarize, staple.
9. Smoke test against the reference dirty PDF and at least 3 other Gmail print exports of varying length.

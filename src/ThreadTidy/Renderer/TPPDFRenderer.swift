import Foundation
import AppKit
import TPPDF

// New PDF renderer built on TPPDF (techprimate/TPPDF, vendored at
// src/libs/TPPDF). Replaces the WKWebView + CGContext slicing path
// that was struggling with reliable Letter pagination.
//
// Pipeline:
//   Thread → TPPDFRenderer → PDFDocument (TPPDF) → PDF on disk
//
// TPPDF handles:
//   - US Letter page format with proper margins
//   - Automatic line wrapping and page-breaks based on content height
//   - Per-page margins and pagination
//
// We handle:
//   - "Each email starts on a new page" via document.createNewPage()
//     between sections.
//   - Mapping our StyledRun model to NSAttributedString with the
//     correct font traits (bold/italic/underline) and mailto: links so
//     TPPDF preserves clickable hyperlinks.
public final class TPPDFRenderer {

    public init() {}

    public enum RenderError: Error, LocalizedError {
        case writeFailed(String)
        public var errorDescription: String? {
            switch self {
            case .writeFailed(let m): return "PDF write failed: \(m)"
            }
        }
    }

    // Typography constants. Times New Roman with size hierarchy.
    private static let bodyFontSize: CGFloat = 12
    private static let metaFontSize: CGFloat = 11
    private static let metaLabelFontSize: CGFloat = 11
    private static let emailHeadFontSize: CGFloat = 18
    private static let threadTitleFontSize: CGFloat = 26

    private static let serifFamily = "Times New Roman"
    private static let linkColor = NSColor(calibratedRed: 0.043, green: 0.239, blue: 0.569, alpha: 1.0)

    // Optional engine-provenance footer. When non-nil, every page
    // gets a small italic line under the body explaining whether the
    // thread was parsed by heuristic, AI, or both. Toggled via
    // Settings.renderEngineFooter and surfaced for chain-of-custody
    // documents.
    public var engineFooter: String?

    public func render(thread: Thread, to url: URL) throws {
        let document = PDFDocument(format: .usLetter)

        // Inset content uniformly. TPPDF uses page-relative margins
        // applied to every page automatically.
        document.layout.margin = .init(top: 36, left: 36, bottom: 36, right: 36)

        // ---- Page 1: Thread title + Index of Communications ----
        // (combined onto a single landing page so the court reader's
        // very first view shows the table of contents.)
        addThreadHeader(thread: thread, to: document)
        document.add(space: 18)
        addIndexPage(thread: thread, to: document)
        document.createNewPage()

        // ---- Each email on its own page, with strip indicator (Option D) ----
        for (idx, email) in thread.messages.enumerated() {
            addStripIndicator(currentIndex: email.index,
                              total: thread.messages.count,
                              to: document)
            addEmail(email, to: document)
            if idx < thread.messages.count - 1 {
                document.createNewPage()
            }
        }

        // Optional engine-provenance footer at the end of the
        // document. Italic, small, low-emphasis — courtroom readers
        // can ignore it; auditors can confirm chain-of-custody.
        if let line = engineFooter, !line.isEmpty {
            document.add(space: 12)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attr = NSAttributedString(
                string: line,
                attributes: [
                    .font: serifFont(size: 8, italic: true),
                    .foregroundColor: NSColor.darkGray,
                    .paragraphStyle: para,
                ]
            )
            document.add(attributedText: attr)
        }

        // ---- Generate ----
        let generator = PDFGenerator(document: document)
        try? FileManager.default.removeItem(at: url)
        do {
            try generator.generate(to: url)
        } catch {
            throw RenderError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Thread header

    private func addThreadHeader(thread: Thread, to document: PDFDocument) {
        // "Email Thread:" label on its own line, subject below on its
        // own line — easier to scan and avoids long-subject wrap.
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: serifFont(size: Self.threadTitleFontSize, bold: true),
            .foregroundColor: NSColor.black,
        ]
        document.add(attributedText: NSAttributedString(
            string: "Email Thread:",
            attributes: labelAttrs
        ))
        document.add(space: 6)
        let subjectAttrs: [NSAttributedString.Key: Any] = [
            .font: serifFont(size: Self.threadTitleFontSize, bold: true),
            .foregroundColor: NSColor.black,
        ]
        document.add(attributedText: NSAttributedString(
            string: thread.subject,
            attributes: subjectAttrs
        ))
        document.add(space: 14)

        if !thread.dateRange.isEmpty {
            let dr = NSMutableAttributedString()
            dr.append(NSAttributedString(string: "Date Range: ", attributes: [
                .font: serifFont(size: Self.metaFontSize, bold: true),
                .foregroundColor: NSColor.black,
            ]))
            dr.append(NSAttributedString(string: thread.dateRange, attributes: [
                .font: serifFont(size: Self.metaFontSize, bold: false),
                .foregroundColor: NSColor.black,
            ]))
            document.add(attributedText: dr)
            document.add(space: 6)
        }

        let summary = NSAttributedString(string: "\(thread.messages.count) messages", attributes: [
            .font: serifFont(size: Self.metaFontSize, bold: false, italic: true),
            .foregroundColor: NSColor.darkGray,
        ])
        document.add(attributedText: summary)
    }

    // MARK: - Index of Communications (Option A)

    // A single page giving the court reader a chronological table of
    // every message in the thread: ordinal, date+time, from, to (first
    // recipient only to keep the column narrow), and a short snippet.
    private func addIndexPage(thread: Thread, to document: PDFDocument) {
        let title = NSAttributedString(string: "Index of Communications", attributes: [
            .font: serifFont(size: 18, bold: true),
            .foregroundColor: NSColor.black,
        ])
        document.add(attributedText: title)
        document.add(space: 6)
        let subtitle = NSAttributedString(
            string: "\(thread.messages.count) messages, \(thread.dateRange)",
            attributes: [
                .font: serifFont(size: 10, bold: false, italic: true),
                .foregroundColor: NSColor.darkGray,
            ]
        )
        document.add(attributedText: subtitle)
        document.add(space: 12)

        let table = PDFTable(rows: thread.messages.count + 1, columns: 5)
        table.widths = [0.06, 0.20, 0.22, 0.20, 0.32]
        table.margin = 0
        table.padding = 4
        table.showHeadersOnEveryPage = true

        table.content = [
            [
                "No.".asTableContent,
                "Date / Time".asTableContent,
                "From".asTableContent,
                "To".asTableContent,
                "Snippet".asTableContent,
            ]
        ] + thread.messages.map { m -> [PDFTableContent?] in
            [
                "\(m.index)".asTableContent,
                shortDate(m.date).asTableContent,
                shortName(m.fromName).asTableContent,
                shortRecipients(m.to).asTableContent,
                snippet(m.bodyLines, maxChars: 90).asTableContent,
            ]
        }

        // Court-document styling: Times New Roman everywhere, no fill
        // colors, thin black borders, no decorative tint. The default
        // PDFTableStyleDefaults.simple uses Helvetica-style fonts and
        // tinted bands; we override every relevant style explicitly so
        // nothing falls through to the framework defaults.
        let courtBorder = PDFLineStyle(type: .full, color: NSColor.black, width: 0.4)
        let courtBorders = PDFTableCellBorders(
            left: courtBorder, top: courtBorder, right: courtBorder, bottom: courtBorder
        )
        let style = PDFTableStyle(
            rowHeaderCount: 0,
            columnHeaderCount: 1,
            footerCount: 0,
            outline: courtBorder,
            rowHeaderStyle: PDFTableCellStyle(),
            columnHeaderStyle: PDFTableCellStyle(
                colors: (fill: .clear, text: .black),
                borders: courtBorders,
                font: serifFont(size: 9, bold: true)
            ),
            footerStyle: PDFTableCellStyle(),
            contentStyle: PDFTableCellStyle(
                colors: (fill: .clear, text: .black),
                borders: courtBorders,
                font: serifFont(size: 9, bold: false)
            ),
            alternatingContentStyle: nil
        )
        table.style = style
        table.rows.allRowsAlignment = [.center, .left, .left, .left, .left]

        // Set the document's default font BEFORE the table so that any
        // table cell that falls back to inherited typography also picks
        // up Times New Roman, not the system Helvetica default.
        document.set(font: serifFont(size: 9, bold: false))
        document.set(textColor: NSColor.black)

        document.add(table: table)
    }

    // MARK: - Strip indicator (Option D)

    // A compact "you are here" line above each email. Renders all
    // message ordinals; the current one is shown bold + bracketed.
    // Format: "1 · 2 · 3 · [6] · 7 · 8 · … · 28"
    private func addStripIndicator(currentIndex: Int, total: Int, to document: PDFDocument) {
        let s = NSMutableAttributedString()
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: serifFont(size: 8, bold: false),
            .foregroundColor: NSColor(white: 0.55, alpha: 1.0),
        ]
        let indexAttrs: [NSAttributedString.Key: Any] = [
            .font: serifFont(size: 8, bold: true),
            .foregroundColor: NSColor(white: 0.35, alpha: 1.0),
        ]
        let currentAttrs: [NSAttributedString.Key: Any] = [
            .font: serifFont(size: 9, bold: true),
            .foregroundColor: NSColor.black,
        ]
        // "Index" jump-back at the head of the strip.
        s.append(NSAttributedString(string: "Index", attributes: indexAttrs))
        s.append(NSAttributedString(string: " · ", attributes: baseAttrs))
        for i in 1...total {
            if i > 1 {
                s.append(NSAttributedString(string: " · ", attributes: baseAttrs))
            }
            if i == currentIndex {
                s.append(NSAttributedString(string: "[\(i)]", attributes: currentAttrs))
            } else {
                s.append(NSAttributedString(string: "\(i)", attributes: baseAttrs))
            }
        }
        s.append(NSAttributedString(string: "    Message \(currentIndex) of \(total)", attributes: [
            .font: serifFont(size: 8, bold: false, italic: true),
            .foregroundColor: NSColor.darkGray,
        ]))
        document.add(attributedText: s)
        document.add(space: 4)
        // Thin rule separating the navigation strip from the email
        // content below it.
        document.addLineSeparator(style: PDFLineStyle(
            type: .full,
            color: NSColor(white: 0.6, alpha: 1.0),
            width: 0.4
        ))
        document.add(space: 8)
    }

    // MARK: - Index helpers

    // Shorten a Gmail-style "Wed, Apr 29, 2026 at 8:12 AM" to
    // "Apr 29 · 8:12 AM" for the index column.
    private func shortDate(_ raw: String) -> String {
        let inDF = DateFormatter()
        inDF.locale = Locale(identifier: "en_US_POSIX")
        inDF.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        let outDF = DateFormatter()
        outDF.locale = Locale(identifier: "en_US_POSIX")
        outDF.dateFormat = "MMM d · h:mm a"
        if let d = inDF.date(from: raw) { return outDF.string(from: d) }
        return raw
    }

    // First name + last initial, e.g. "Mary Johnson" → "Mary J."
    private func shortName(_ name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0]) \(parts.last!.prefix(1))."
        }
        return name
    }

    // Show only the first recipient name/email; "+N" for the rest.
    private func shortRecipients(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        let parts = trimmed.split(separator: ",")
        guard let first = parts.first else { return trimmed }
        let firstName: String = {
            let s = String(first).trimmingCharacters(in: .whitespaces)
            // Strip "<email>" tail to keep just the name.
            if let lt = s.firstIndex(of: "<") {
                return String(s[s.startIndex..<lt]).trimmingCharacters(in: .whitespaces)
            }
            return s
        }()
        let extra = parts.count - 1
        return extra > 0 ? "\(firstName) +\(extra)" : firstName
    }

    // First N characters of the body, single line, ellipsised.
    private func snippet(_ lines: [StyledLine], maxChars: Int) -> String {
        let text = lines.map(\.plain).joined(separator: " ")
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if collapsed.count <= maxChars { return collapsed }
        let cut = collapsed.index(collapsed.startIndex, offsetBy: maxChars)
        return String(collapsed[..<cut]) + "…"
    }

    // MARK: - Per-email rendering

    private func addEmail(_ e: Email, to document: PDFDocument) {
        // Email heading: "N. SenderName"
        let head = NSAttributedString(
            string: "\(e.index). \(e.fromName)",
            attributes: [
                .font: serifFont(size: Self.emailHeadFontSize, bold: true),
                .foregroundColor: NSColor.black,
            ]
        )
        document.add(attributedText: head)
        document.add(space: 8)

        // Metadata block: Date / From / To / Cc / Bcc.
        addMetaRow(label: "Date:", value: e.date, isLink: false, into: document)
        addMetaRow(label: "From:", value: e.fromEmail, isLink: true, into: document)
        addMetaRow(label: "To:", value: e.to, isLink: false, into: document)
        if let cc = e.cc, !cc.isEmpty {
            addMetaRow(label: "Cc:", value: cc, isLink: false, into: document)
        }
        if let bcc = e.bcc, !bcc.isEmpty {
            addMetaRow(label: "Bcc:", value: bcc, isLink: false, into: document)
        }

        // Separator line under the metadata block.
        document.add(space: 6)
        document.addLineSeparator(style: PDFLineStyle(type: .full, color: .gray, width: 0.5))
        document.add(space: 10)

        // Group body lines into blocks: paragraphs and lists.
        // Lists are runs of consecutive lines that all match an ordered
        // ("1. ", "2. ", …) or unordered ("- ", "• ", "* ") marker.
        let blocks = groupBlocks(e.bodyLines)
        for block in blocks {
            switch block {
            case .paragraph(let lines):
                emitParagraph(lines: lines, into: document)
            case .orderedList(let items):
                emitList(items: items, ordered: true, into: document)
            case .unorderedList(let items):
                emitList(items: items, ordered: false, into: document)
            case .attachments(let count, let items):
                emitAttachments(count: count, items: items, into: document)
            }
        }
    }

    private func emitAttachments(count: Int, items: [StyledLine], into document: PDFDocument) {
        // Heading.
        let heading = NSAttributedString(
            string: "Attachments (\(count))",
            attributes: [
                .font: serifFont(size: Self.metaLabelFontSize, bold: true),
                .foregroundColor: NSColor.black,
            ]
        )
        document.add(attributedText: heading)
        document.add(space: 4)

        // Each attachment row: "📎 <filename> (<size>)" if we can parse
        // out a size, otherwise just the verbatim line.
        let bodyFont = serifFont(size: Self.bodyFontSize, bold: false)
        let rowAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.black,
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: serifFont(size: Self.bodyFontSize, bold: true),
            .foregroundColor: NSColor.black,
        ]

        // Pair lines: a filename line followed by a size-only line
        // (e.g. "408K" / "1.2MB" / "63K") becomes a single rendered row.
        let sizeRegex = try! NSRegularExpression(pattern: #"^\s*\d+(?:\.\d+)?\s*[KMG]B?\s*$"#)
        var i = 0
        while i < items.count {
            let name = items[i].plain.trimmingCharacters(in: .whitespaces)
            var size = ""
            if i + 1 < items.count {
                let next = items[i + 1].plain.trimmingCharacters(in: .whitespaces)
                let ns = next as NSString
                if sizeRegex.firstMatch(in: next, range: NSRange(location: 0, length: ns.length)) != nil {
                    size = next
                    i += 1
                }
            }
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: "Attachment: ", attributes: labelAttrs))
            s.append(NSAttributedString(string: name, attributes: rowAttrs))
            if !size.isEmpty {
                s.append(NSAttributedString(string: "  (\(size))", attributes: rowAttrs))
            }
            document.add(attributedText: s)
            document.add(space: 2)
            i += 1
        }
        document.add(space: 6)
    }

    // MARK: - List grouping

    private enum BodyBlock {
        case paragraph([StyledLine])
        case orderedList([StyledLine])     // each StyledLine is one item
                                           // with the leading marker stripped
        case unorderedList([StyledLine])
        // Attachment block: a "N attachments" intro line followed by
        // file rows. Items can be a filename, a filename+size on one
        // line, or filename and size on consecutive lines.
        case attachments(count: Int, items: [StyledLine])
    }

    private static let attachmentCountRegex = try! NSRegularExpression(
        pattern: #"^\s*(\d+)\s+attachments?\s*$"#,
        options: [.caseInsensitive]
    )
    // A line that's purely a filename ending in a common attachment
    // extension. Used for the "no intro line" detection path: if a
    // tail of body lines is filename + size, treat as attachments.
    private static let filenameRegex = try! NSRegularExpression(
        pattern: #"^.+\.(?:pdf|docx?|xlsx?|pptx?|png|jpe?g|gif|zip|txt|csv|rtf|heic)\s*$"#,
        options: [.caseInsensitive]
    )
    // Size-only line: "408K", "1.2 MB", "63KB", etc.
    private static let attachmentSizeRegex = try! NSRegularExpression(
        pattern: #"^\s*\d+(?:\.\d+)?\s*[KMG]B?\s*$"#,
        options: [.caseInsensitive]
    )

    private static let orderedItemRegex = try! NSRegularExpression(
        pattern: #"^\s*(\d+)[\.\)]\s+(.+)$"#
    )
    private static let unorderedItemRegex = try! NSRegularExpression(
        pattern: "^\\s*[-\u{2022}*]\\s+(.+)$"
    )

    // Sentence-terminating punctuation (used by the paragraph-break
    // heuristic when PDFKit collapses blank lines).
    private static let sentenceEnders: Set<Character> = [".", "!", "?", ":"]

    private func groupBlocks(_ lines: [StyledLine]) -> [BodyBlock] {
        var blocks: [BodyBlock] = []
        var paragraph: [StyledLine] = []
        var ordered: [StyledLine] = []
        var unordered: [StyledLine] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph))
                paragraph = []
            }
        }
        func flushOrdered() {
            if !ordered.isEmpty {
                blocks.append(.orderedList(ordered))
                ordered = []
            }
        }
        func flushUnordered() {
            if !unordered.isEmpty {
                blocks.append(.unorderedList(unordered))
                unordered = []
            }
        }
        func flushAll() { flushParagraph(); flushOrdered(); flushUnordered() }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.plain.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushAll()
                i += 1
                continue
            }
            // "N attachments" → consume this line plus all following
            // non-empty lines as the attachment list.
            let ns = trimmed as NSString
            if let m = Self.attachmentCountRegex.firstMatch(
                in: trimmed,
                range: NSRange(location: 0, length: ns.length)
            ), m.numberOfRanges >= 2 {
                flushAll()
                let count = Int(ns.substring(with: m.range(at: 1))) ?? 0
                var items: [StyledLine] = []
                var j = i + 1
                while j < lines.count {
                    let t = lines[j].plain.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    items.append(lines[j])
                    j += 1
                }
                blocks.append(.attachments(count: count, items: items))
                i = j
                continue
            }
            // Implicit attachment: a filename-shaped line followed by
            // a size-only line (e.g. "Brief.pdf" / "1048K"). Some
            // emails include attachments without the "N attachments"
            // intro Gmail uses.
            if Self.filenameRegex.firstMatch(
                in: trimmed,
                range: NSRange(location: 0, length: ns.length)
            ) != nil
                && i + 1 < lines.count
                && Self.attachmentSizeRegex.firstMatch(
                    in: lines[i + 1].plain.trimmingCharacters(in: .whitespaces),
                    range: NSRange(
                        location: 0,
                        length: (lines[i + 1].plain.trimmingCharacters(in: .whitespaces) as NSString).length
                    )
                ) != nil
            {
                flushAll()
                var items: [StyledLine] = [line, lines[i + 1]]
                var j = i + 2
                // Pull additional filename+size pairs that immediately follow.
                while j + 1 < lines.count {
                    let f = lines[j].plain.trimmingCharacters(in: .whitespaces)
                    let s = lines[j + 1].plain.trimmingCharacters(in: .whitespaces)
                    let fNS = f as NSString, sNS = s as NSString
                    let isFile = Self.filenameRegex.firstMatch(
                        in: f, range: NSRange(location: 0, length: fNS.length)
                    ) != nil
                    let isSize = Self.attachmentSizeRegex.firstMatch(
                        in: s, range: NSRange(location: 0, length: sNS.length)
                    ) != nil
                    if isFile && isSize {
                        items.append(lines[j])
                        items.append(lines[j + 1])
                        j += 2
                    } else { break }
                }
                let count = items.count / 2
                blocks.append(.attachments(count: count, items: items))
                i = j
                continue
            }
            // Native vector bullet detected on this line by CGPDFScanner.
            // The bullet circle only appears on the FIRST visual line
            // of an item; if the item wraps in source, the next lines
            // have no bullet flag but DO sit at the same indent. Merge
            // them into a single StyledLine so the rendered bullet
            // shows the full item text.
            if line.isBullet {
                flushParagraph(); flushOrdered()
                var mergedRuns = line.runs
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    let nextTrim = next.plain.trimmingCharacters(in: .whitespaces)
                    if nextTrim.isEmpty { break }
                    if next.isBullet { break }              // start of next bullet
                    if next.indent + 4 < line.indent { break } // outdented = back to body
                    // Continuation line: append with a joining space.
                    mergedRuns.append(StyledRun(text: " "))
                    mergedRuns.append(contentsOf: next.runs)
                    j += 1
                }
                let merged = StyledLine(
                    runs: mergedRuns,
                    indent: line.indent,
                    isBullet: true
                )
                unordered.append(merged)
                i = j
                continue
            }
            if let stripped = stripOrderedMarker(line) {
                flushParagraph(); flushUnordered()
                ordered.append(stripped)
                i += 1
                continue
            }
            if let stripped = stripUnorderedMarker(line) {
                flushParagraph(); flushOrdered()
                unordered.append(stripped)
                i += 1
                continue
            }
            flushOrdered(); flushUnordered()

            if let prev = paragraph.last,
               looksLikeParagraphBreak(after: prev, before: line) {
                flushParagraph()
            }
            paragraph.append(line)
            i += 1
        }
        flushAll()
        return blocks
    }

    private func looksLikeParagraphBreak(after prev: StyledLine, before next: StyledLine) -> Bool {
        let prevText = prev.plain.trimmingCharacters(in: .whitespaces)
        let nextText = next.plain.trimmingCharacters(in: .whitespaces)
        guard !prevText.isEmpty, !nextText.isEmpty else { return false }

        let prevLast = prevText.last!
        let firstCh = nextText.first!

        // Greeting / closing pattern: a SHORT line ending in comma is
        // almost always its own paragraph in email prose
        // ("Good morning Ms. Johnson," / "Ms. Brown," / "Respectfully,").
        // Wrapped body lines are typically 80–120 chars; salutations are
        // under ~50.
        let prevLooksLikeSalutation =
            prevText.count <= 50 && (prevLast == "," || prevLast == ":")

        // Strong sentence-end signal.
        let endsSentence = Self.sentenceEnders.contains(prevLast)
        // Implicit list-item terminators: a line ending with ')' (e.g.
        // a parenthetical filing date) or ';' (semicolon-separated
        // items) followed by a capital-start line is almost always a
        // separate Gmail bullet item without an explicit marker.
        let endsListItem = (prevLast == ")" || prevLast == ";")
        let nextStartsParagraph =
            firstCh.isUppercase ||
            firstCh == "\"" || firstCh == "'" ||
            firstCh == "“" || firstCh == "‘" ||
            firstCh == "(" || firstCh == "[" ||
            firstCh.isNumber  // numbered list item or "1." style start

        // Avoid splitting on common abbreviations.
        let lastToken = prevText.split(separator: " ").last.map(String.init) ?? ""
        let abbrevs: Set<String> = ["Mr.", "Mrs.", "Ms.", "Dr.", "St.", "Jr.", "Sr."]
        if abbrevs.contains(lastToken) { return false }

        if prevLooksLikeSalutation { return true }
        if endsListItem && nextStartsParagraph { return true }
        // Closer/salutation pattern on NEXT: a SHORT comma-/colon-
        // ending line ("Thank you,", "Respectfully,", "Sincerely,",
        // "Ms. Brown,") deserves to start its own paragraph even when
        // the previous body line is long.
        let nextLast = nextText.last!
        if (nextLast == "," || nextLast == ":") && nextText.count <= 50 {
            return true
        }
        // Sentence-boundary rule: only fire for SHORT prev lines.
        // Long prev lines that happen to end mid-paragraph at a period
        // (e.g. "...will be assigned for your hearing.") are false
        // positives that produce stair-step body text. Short closer
        // lines like "Thank you." / "Respectfully." stay handled.
        if endsSentence && nextStartsParagraph && prevText.count <= 30 {
            return true
        }
        return false
    }

    // Strips a "N. " or "N) " prefix from the FIRST run that contains it,
    // preserving styling of the remainder.
    private func stripOrderedMarker(_ line: StyledLine) -> StyledLine? {
        let plain = line.plain
        let ns = plain as NSString
        guard let m = Self.orderedItemRegex.firstMatch(
            in: plain, range: NSRange(location: 0, length: ns.length)
        ), m.numberOfRanges >= 3 else { return nil }
        let bodyRange = m.range(at: 2)
        return cropLine(line, fromCharOffset: bodyRange.location)
    }

    private func stripUnorderedMarker(_ line: StyledLine) -> StyledLine? {
        let plain = line.plain
        let ns = plain as NSString
        guard let m = Self.unorderedItemRegex.firstMatch(
            in: plain, range: NSRange(location: 0, length: ns.length)
        ), m.numberOfRanges >= 2 else { return nil }
        let bodyRange = m.range(at: 1)
        return cropLine(line, fromCharOffset: bodyRange.location)
    }

    // Returns a new StyledLine starting at the given character offset of
    // the original's combined plain text. Run boundaries are honored so
    // styling within the kept region is preserved.
    private func cropLine(_ line: StyledLine, fromCharOffset offset: Int) -> StyledLine {
        var consumed = 0
        var keep: [StyledRun] = []
        for run in line.runs {
            let runLen = (run.text as NSString).length
            let runEnd = consumed + runLen
            if runEnd <= offset {
                consumed = runEnd
                continue
            }
            if consumed < offset {
                let dropChars = offset - consumed
                let s = (run.text as NSString)
                let kept = s.substring(from: dropChars)
                if !kept.isEmpty {
                    keep.append(StyledRun(
                        text: kept,
                        bold: run.bold, italic: run.italic, underline: run.underline,
                        link: run.link
                    ))
                }
            } else {
                keep.append(run)
            }
            consumed = runEnd
        }
        return StyledLine(runs: keep)
    }

    // MARK: - Block emission

    private func emitParagraph(lines: [StyledLine], into document: PDFDocument) {
        // Join lines with a SPACE so Gmail's visual wrap breaks
        // (e.g. "interpreter had been" / "secured for today") flow back
        // into a single sentence that TPPDF re-wraps to the new column
        // width. Real paragraph boundaries are signaled by blank
        // StyledLines between groups, which the caller has already
        // split on — so within emitParagraph we have exactly one
        // logical paragraph to emit.
        //
        // Exception: when most runs in this paragraph use a smaller
        // font than the body (typical of signatures, firm-info blocks,
        // confidentiality disclaimers), preserve each source line as
        // its own hard break rather than joining. This keeps addresses,
        // phone numbers, and "PHONE | FIND US | WEBSITE" rows on
        // separate lines like the original.
        let preformatted = looksPreformatted(lines)
        let paragraph = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            if i > 0 {
                paragraph.append(NSAttributedString(string: preformatted ? "\n" : " "))
            }
            paragraph.append(attributedString(for: line.trimmedEdges()))
        }
        if paragraph.length > 0 {
            // Heuristic: a paragraph that opens with a short Title-Case
            // phrase ending in ":" (e.g. "Regarding reset dates:",
            // "Note:", "Important:") gets that prefix bolded as an
            // inline lead-in. Gmail's print pipeline often strips this
            // styling from the body even though the original composer
            // showed it bold. Generic — does not depend on any specific
            // word.
            applyLeadInBold(to: paragraph)
            let indentPt = lines.first?.indent ?? 0
            applyParagraphIndent(indentPt, to: paragraph)
            applyDocumentIndent(indentPt, in: document)
            document.add(attributedText: paragraph)
            document.add(space: 10)
            applyDocumentIndent(0, in: document)
        }
    }

    private static let leadInRegex = try! NSRegularExpression(
        // Capital letter + 1..55 chars not containing ":" or newline +
        // ending in a letter, then ":", then space (so we don't catch
        // URLs like "https://" or times like "8:12 AM").
        pattern: #"^([A-Z][^:\n]{0,55}[a-zA-Z])(:)\s"#
    )

    private func applyLeadInBold(to s: NSMutableAttributedString) {
        let plain = s.string
        let ns = plain as NSString
        let scan = NSRange(location: 0, length: min(60, ns.length))
        guard let m = Self.leadInRegex.firstMatch(in: plain, range: scan),
              m.numberOfRanges >= 3 else { return }
        // Bold the phrase + the colon (not the trailing space).
        let prefixRange = NSRange(
            location: 0,
            length: m.range(at: 2).location + 1
        )
        s.enumerateAttribute(.font, in: prefixRange, options: []) { value, range, _ in
            guard let f = value as? NSFont else { return }
            let traits = f.fontDescriptor.symbolicTraits
            if traits.contains(.bold) { return }   // already bold, don't double
            let boldDesc = f.fontDescriptor.withSymbolicTraits(
                traits.union(.bold)
            )
            let bold = NSFont(descriptor: boldDesc, size: f.pointSize) ?? f
            s.removeAttribute(.font, range: range)
            s.addAttribute(.font, value: bold, range: range)
        }
    }

    // Heuristic: a paragraph "looks preformatted" (signature / address
    // block / disclaimer) if MOST of its non-empty character mass is
    // typeset at a font size smaller than the body default. We weight
    // by character count so a short-but-large opening line doesn't
    // outvote a long disclaimer.
    private func looksPreformatted(_ lines: [StyledLine]) -> Bool {
        // Two ways a paragraph qualifies as "preformatted" (each
        // line on its own row, no space-join):
        //
        // 1. Small-font signal: most chars are < 9pt (Gmail's
        //    signature/disclaimer typeface is ~7.5–8pt; body is 9.75).
        //
        // 2. Short-line signal: the paragraph has 3+ lines AND ALL
        //    non-empty lines are short (≤ 40 chars). This catches
        //    signature blocks like:
        //       Mary Johnson
        //       Office Manager
        //       Acme Corporation
        //       123 Main St
        //       Springfield, IL 62701
        //       (555) 123-4567
        //    where each line is under 40 chars and shouldn't be
        //    space-joined into a runaway paragraph.

        // Small-font check.
        var smallChars = 0
        var totalChars = 0
        for line in lines {
            for r in line.runs where !r.text.isEmpty {
                let n = r.text.count
                totalChars += n
                if r.fontSize > 0 && r.fontSize < 9.0 {
                    smallChars += n
                }
            }
        }
        if totalChars > 0 && Double(smallChars) / Double(totalChars) >= 0.5 {
            return true
        }

        // Short-line block check. A paragraph behaves as preformatted
        // (each line preserved) when it has 3+ lines AND a majority
        // (≥60%) are short (≤45 chars). This catches signature blocks
        // where most lines are name/address/phone but one line is
        // longer (e.g. "Anna Brown | Attorney at Law and Family
        // Law Mediator"), without false-positives on body prose.
        let nonEmpty = lines.filter {
            !$0.plain.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if nonEmpty.count >= 3 {
            let shortCount = nonEmpty.filter {
                $0.plain.trimmingCharacters(in: .whitespaces).count <= 45
            }.count
            let ratio = Double(shortCount) / Double(nonEmpty.count)
            if ratio >= 0.6 { return true }
        }

        return false
    }

    // Applies a head indent on the attributed string via NSParagraphStyle.
    // TPPDF's text rendering may or may not honor this depending on
    // version; we ALSO call document.set(indent:) as a belt-and-braces
    // measure (see applyDocumentIndent).
    private func applyParagraphIndent(_ pt: CGFloat, to s: NSMutableAttributedString) {
        guard pt > 0.5 else { return }
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = pt
        style.headIndent = pt
        s.addAttribute(
            .paragraphStyle, value: style,
            range: NSRange(location: 0, length: s.length)
        )
    }

    // TPPDF respects document.set(indent:left:) as a layout offset
    // applied to subsequent content. We toggle it before/after each
    // indented paragraph so the indent doesn't leak into siblings.
    private func applyDocumentIndent(_ pt: CGFloat, in document: PDFDocument) {
        document.set(indent: pt, left: true)
    }

    private func emitList(items: [StyledLine], ordered: Bool, into document: PDFDocument) {
        // We intentionally do NOT use TPPDF's PDFList here: PDFListItem's
        // `content` is plain String, so any bold/italic/underline runs
        // inside an item would be flattened. Instead, render each item
        // as its own styled paragraph prefixed with a bullet ("• ") or
        // number ("1. ") so NSAttributedString styling on the body of
        // the item is preserved. We pad the left side via an indent so
        // wrapped lines visually align under the first character of
        // the item content (hanging indent).
        let bodyFont = serifFont(size: Self.bodyFontSize, bold: false)
        let bulletAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.black,
        ]
        for (idx, line) in items.enumerated() {
            let prefix = ordered ? "\(idx + 1).  " : "•  "
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: prefix, attributes: bulletAttrs))
            s.append(attributedString(for: line.trimmedEdges()))
            // Apply the item's own indent (sub-bullets in source PDF
            // get a deeper indent here automatically).
            let indentPt = line.indent + 18  // base list indent of 18pt
            applyParagraphIndent(indentPt, to: s)
            applyDocumentIndent(indentPt, in: document)
            document.add(attributedText: s)
            document.add(space: 3)
        }
        applyDocumentIndent(0, in: document)
        document.add(space: 6)
    }

    // MARK: - Meta row

    // A single Date/From/To/Cc/Bcc row. We render the label and value
    // inline as one attributed string so TPPDF wraps the value
    // naturally without splitting at column boundaries.
    private func addMetaRow(label: String, value: String, isLink: Bool, into document: PDFDocument) {
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: label + " ", attributes: [
            .font: serifFont(size: Self.metaLabelFontSize, bold: true),
            .foregroundColor: NSColor.black,
        ]))
        if isLink, let url = URL(string: "mailto:\(value)") {
            line.append(NSAttributedString(string: value, attributes: [
                .font: serifFont(size: Self.metaFontSize, bold: false),
                .foregroundColor: Self.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .link: url,
            ]))
        } else {
            line.append(linkifyValue(value, font: serifFont(size: Self.metaFontSize, bold: false)))
        }
        document.add(attributedText: line)
    }

    // Converts a header value with email-address tokens into a styled
    // attributed string where each address becomes a mailto link.
    private func linkifyValue(_ text: String, font: NSFont) -> NSAttributedString {
        let pattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.black,
            ])
        }
        let result = NSMutableAttributedString()
        let ns = text as NSString
        var cursor = 0
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.black,
        ]
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                let lit = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                result.append(NSAttributedString(string: lit, attributes: baseAttrs))
            }
            let addr = ns.substring(with: m.range)
            var linkAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: Self.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            if let url = URL(string: "mailto:\(addr)") { linkAttrs[.link] = url }
            result.append(NSAttributedString(string: addr, attributes: linkAttrs))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            let tail = ns.substring(from: cursor)
            result.append(NSAttributedString(string: tail, attributes: baseAttrs))
        }
        return result
    }

    // MARK: - StyledRun → NSAttributedString

    // Heuristic: a single-line paragraph that's short and ends with ":"
    // is almost always a sub-heading (e.g. "In Cause No. ... (Main Case):").
    // Gmail's print pipeline strips the bold from such lines even when
    // the original Gmail composer displayed them bold; we restore the
    // visual hierarchy by force-bolding when the structural cue is clear.
    private func looksLikeSubHeading(_ line: StyledLine) -> Bool {
        let t = line.plain.trimmingCharacters(in: .whitespaces)
        guard t.count > 0, t.count <= 80 else { return false }
        guard t.hasSuffix(":") else { return false }
        guard let first = t.first, first.isUppercase else { return false }
        // Reject if any run is already bold (then we don't need to add it).
        if line.runs.contains(where: { $0.bold }) { return false }
        return true
    }

    private func attributedString(for line: StyledLine) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let forceBold = looksLikeSubHeading(line)
        for r in line.runs {
            // Use the source's per-run font size after PDFiumExtractor
            // has normalized it (dominant body size mapped to 12pt).
            // Clamp to a generous range so emphasized headings up to
            // 18pt render at their true size, but oddly tiny or huge
            // values fall back to the body default.
            let runSize: CGFloat = {
                let s = r.fontSize
                if s >= 6 && s <= 24 { return s }
                return Self.bodyFontSize
            }()
            let font = serifFont(size: runSize, bold: r.bold || forceBold, italic: r.italic)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black,
            ]
            if r.underline {
                // Body underline is drawn manually as a thin (~0.4pt) line
                // by PDFUnderlineAnnotator post-render — Core Text's
                // intrinsic underline thickness is too heavy at body size
                // and can't be overridden via public macOS APIs. We omit
                // the .underlineStyle attribute here so TPPDF doesn't draw
                // the thick stock underline.
            }
            if let link = r.link {
                attrs[.link] = link
                attrs[.foregroundColor] = Self.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            s.append(NSAttributedString(string: r.text, attributes: attrs))
        }
        return s
    }

    // MARK: - Font factory

    private func serifFont(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let descriptor = NSFontDescriptor(
            fontAttributes: [.family: Self.serifFamily]
        )
        var traits = NSFontDescriptor.SymbolicTraits()
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let traited = descriptor.withSymbolicTraits(traits)
        if let f = NSFont(descriptor: traited, size: size) { return f }
        // Fallback to system Times if Times New Roman descriptor fails.
        if bold && italic { return NSFont(name: "Times-BoldItalic", size: size) ?? .systemFont(ofSize: size) }
        if bold            { return NSFont(name: "Times-Bold", size: size)       ?? .boldSystemFont(ofSize: size) }
        if italic          { return NSFont(name: "Times-Italic", size: size)     ?? .systemFont(ofSize: size) }
        return NSFont(name: "Times-Roman", size: size) ?? .systemFont(ofSize: size)
    }
}

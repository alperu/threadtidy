import SwiftUI
import UniformTypeIdentifiers
import AppKit
import PDFKit
import ThreadTidyKit

// Disambiguate from Foundation.Thread (NSThread).
typealias EmailThread = ThreadTidyKit.Thread

struct ContentView: View {
    @State private var state: ProcessingState = .idle
    @State private var hovering: Bool = false
    @State private var showSettings: Bool = false
    @State private var settings: ThreadTidyKit.Settings = ThreadTidyKit.Settings.load()
    @State private var modelInstalled: Bool = false

    enum ProcessingState {
        case idle
        case processing(sourceName: String)
        case ready(originalURL: URL,
                   cleanedURL: URL,
                   sourceName: String,
                   report: IntegrityReport,
                   thread: EmailThread)
        case failed(message: String)
    }

    var body: some View {
        ZStack {
            backgroundGradient
            VStack(spacing: 0) {
                topBar
                Divider()
                content
            }
        }
        .frame(minWidth: minWidth, minHeight: minHeight)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(settings: $settings)
        }
        .onAppear { refreshModelStatus() }
        .onChange(of: showSettings) { _ in refreshModelStatus() }
        .onChange(of: settings.preferredAIModel) { _ in refreshModelStatus() }
    }

    // Persistent top bar — visible in every state so Settings and
    // the model-status chip are always reachable, even before a PDF
    // has been dropped or while one is being processed.
    private var topBar: some View {
        HStack(spacing: 10) {
            Text("ThreadTidy")
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Spacer()
            modelStatusChip
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .help("ThreadTidy settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
    }

    @ViewBuilder
    private var modelStatusChip: some View {
        let runtime = ModelStore.isRuntimeAvailable
        let (icon, color, label): (String, Color, String) = {
            if !modelInstalled {
                return ("icloud.and.arrow.down", .secondary,
                        "Model not downloaded")
            }
            if !runtime {
                return ("exclamationmark.triangle.fill", .orange,
                        "Weights ready · runtime not bundled")
            }
            return ("checkmark.seal.fill", .green, "Model ready")
        }()
        let tip: String = {
            if case .processing = state {
                return "\(label) — current PDF is being cleaned with the heuristic parser."
            }
            return label
        }()
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .processing = state {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
            .overlay(
                Capsule().strokeBorder(color.opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private func refreshModelStatus() {
        modelInstalled = ModelStore.default.isInstalled(settings.preferredAIModel)
    }

    // The compact landing view fits 480×360, but the comparison page
    // needs room for two PDFs side by side. Resize the window's
    // minimums based on state so SwiftUI grows the window when the
    // user lands on the comparison view.
    private var minWidth: CGFloat {
        if case .ready = state { return 1100 }
        return 480
    }
    private var minHeight: CGFloat {
        if case .ready = state { return 720 }
        return 360
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(nsColor: .windowBackgroundColor),
                     Color(nsColor: .controlBackgroundColor)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            dropZone.padding(40)
        case .processing(let name):
            processingView(name: name).padding(40)
        case .ready(let originalURL, let cleanedURL, let name, let report, let thread):
            comparisonView(
                originalURL: originalURL, cleanedURL: cleanedURL,
                sourceName: name, report: report, thread: thread
            )
        case .failed(let message):
            failureView(message: message).padding(40)
        }
    }

    // MARK: - Drop zone (idle state)

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.below.ecg")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a Gmail print PDF here")
                .font(.title2)
            Text("It will be cleaned into a tidy email thread PDF.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    hovering ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
        )
        .onDrop(of: [.fileURL, .pdf], isTargeted: $hovering) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Processing

    private func processingView(name: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Cleaning \(name)…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ready (side-by-side comparison)

    private func comparisonView(
        originalURL: URL, cleanedURL: URL,
        sourceName: String, report: IntegrityReport, thread: EmailThread
    ) -> some View {
        VStack(spacing: 0) {
            // Top action bar
            HStack(spacing: 12) {
                Button {
                    state = .idle
                } label: {
                    Label("Process another", systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)

                Spacer()

                VStack(spacing: 4) {
                    integrityBanner(report: report)
                    if let diff = report.differential {
                        diffStrip(diff: diff)
                    }
                }
                .frame(maxWidth: 480)

                Spacer()

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([cleanedURL])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                // Drag-out so users can drop the cleaned PDF onto Mail,
                // a chat window, etc. without going through Finder.
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                    )
                    .help("Drag this to share the cleaned PDF")
                    .onDrag {
                        NSItemProvider(contentsOf: cleanedURL) ?? NSItemProvider()
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Side-by-side viewers
            GeometryReader { geo in
                HStack(spacing: 1) {
                    pdfPane(
                        title: "Original — \(sourceName)",
                        subtitle: "Gmail print, with chrome",
                        leftURL: originalURL,
                        rightURL: cleanedURL,
                        pickLeft: true,
                        thread: thread,
                        accent: .secondary
                    )
                    .frame(width: (geo.size.width - 1) / 2)

                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 1)

                    pdfPane(
                        title: "Cleaned — \(cleanedURL.lastPathComponent)",
                        subtitle: "Saved to Downloads",
                        leftURL: originalURL,
                        rightURL: cleanedURL,
                        pickLeft: false,
                        thread: thread,
                        accent: .accentColor
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pdfPane(
        title: String, subtitle: String,
        leftURL: URL, rightURL: URL, pickLeft: Bool,
        thread: EmailThread, accent: Color
    ) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(accent.opacity(0.08))

            Divider()

            SyncedPDFPair(
                leftURL: leftURL, rightURL: rightURL,
                thread: thread, pickLeft: pickLeft
            )
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func parsedByLabel(_ kind: ParserKind, diff: ThreadDiff?) -> String {
        switch kind {
        case .heuristic: return "heuristic"
        case .ai:        return "AI"
        case .both:
            if let d = diff, d.severity == .ok {
                return "both ✓"
            } else if diff != nil {
                return "both ⚠"
            } else {
                return "both"
            }
        }
    }

    // Per-message differential dots. One dot per message; click opens
    // a popover with field-level diff. Color: green=ok, amber=warning,
    // red=error per the validator's per-message severity.
    @ViewBuilder
    private func diffStrip(diff: ThreadDiff) -> some View {
        HStack(spacing: 4) {
            ForEach(diff.perMessageDiffs, id: \.index) { md in
                DiffDot(messageDiff: md)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func integrityBanner(report: IntegrityReport) -> some View {
        let (icon, color): (String, Color) = {
            switch report.severity {
            case .ok: return ("checkmark.seal.fill", .green)
            case .warning: return ("exclamationmark.triangle.fill", .orange)
            case .error: return ("xmark.octagon.fill", .red)
            }
        }()
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(report.summary)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
            if let parsedBy = report.parsedBy {
                Text(parsedByLabel(parsedBy, diff: report.differential))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.12))
                    )
                    .help(report.differential?.humanSummary ?? "")
            }
            if !report.errors.isEmpty || !report.warnings.isEmpty {
                Spacer(minLength: 8)
                Text("\(report.errors.count + report.warnings.count) note(s)")
                    .font(.caption)
                    .foregroundStyle(color)
                    .help(
                        (report.errors + report.warnings).joined(separator: "\n")
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Failure

    private func failureView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Could not clean PDF")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Try again") { state = .idle }
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else {
            NSLog("[ThreadTidy] drop: no provider")
            return false
        }
        let types = provider.registeredTypeIdentifiers
        NSLog("[ThreadTidy] drop: receiving provider %@", "\(types)")

        // Some sources (Finder file drags, Mail attachments) expose
        // only the content type identifier (e.g. "com.adobe.pdf") and
        // not "public.file-url". loadObject(ofClass: URL.self) only
        // works when the provider advertises the URL class, which
        // those sources don't do. Use loadFileRepresentation, which
        // works on any file-backed provider, and immediately COPY
        // the temp URL to a stable cache location since the temp
        // file is deleted when the closure returns.
        let typeID: String = {
            if types.contains("com.adobe.pdf") { return "com.adobe.pdf" }
            if types.contains("public.file-url") { return "public.file-url" }
            return types.first ?? "com.adobe.pdf"
        }()

        // Use loadInPlaceFileRepresentation so we can capture the
        // CANONICAL URL of the dropped file (not a system-staged copy).
        // For Finder drags of local PDFs the OS returns inPlace=true
        // and the real file:// URL. We still must copy to a stable
        // cache before the closure returns because (a) in-place access
        // requires us to hold a security-scope at read time and we
        // don't keep one across queues, and (b) Mail-attachment style
        // sources return inPlace=false and a soon-to-be-deleted temp.
        // originalLocation is what `.sameAsSource` uses for the output
        // path; when nil, the resolver falls back to Downloads.
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeID) {
            sourceURL, inPlace, error in
            if let error = error {
                NSLog("[ThreadTidy] drop: loadInPlaceFileRepresentation error %@", "\(error)")
                DispatchQueue.main.async {
                    state = .failed(message: error.localizedDescription)
                }
                return
            }
            guard let tempURL = sourceURL else {
                NSLog("[ThreadTidy] drop: sourceURL was nil")
                return
            }
            let originalLocation: URL? = inPlace ? tempURL : nil
            NSLog("[ThreadTidy] drop: inPlace=%d url=%@",
                  inPlace ? 1 : 0, tempURL.path)
            // Copy out of the system-managed slot before this closure
            // returns. We keep the original filename so the comparison
            // view's title still reads naturally. If the URL is in-place,
            // request a security scope around the read just in case the
            // OS wants one (no-op for unsandboxed apps reading their
            // own files, but harmless and forward-compatible).
            let needsScope = inPlace
            let didScope = needsScope ? tempURL.startAccessingSecurityScopedResource() : false
            defer { if didScope { tempURL.stopAccessingSecurityScopedResource() } }
            let stableURL: URL
            do {
                let cacheDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ThreadTidy-input", isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: cacheDir, withIntermediateDirectories: true
                )
                let dest = cacheDir.appendingPathComponent(
                    "\(UUID().uuidString)-\(tempURL.lastPathComponent)"
                )
                try FileManager.default.copyItem(at: tempURL, to: dest)
                stableURL = dest
            } catch {
                NSLog("[ThreadTidy] drop: copy failed %@", "\(error)")
                DispatchQueue.main.async {
                    state = .failed(message: "Couldn't read dropped file: \(error.localizedDescription)")
                }
                return
            }

            NSLog("[ThreadTidy] processing %@", stableURL.path)
            DispatchQueue.main.async {
                state = .processing(sourceName: stableURL.lastPathComponent)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Pipeline.run(
                        input: stableURL,
                        originalLocation: originalLocation
                    )
                    NSLog("[ThreadTidy] wrote %@", result.url.path)
                    DispatchQueue.main.async {
                        state = .ready(
                            originalURL: stableURL,
                            cleanedURL: result.url,
                            sourceName: stableURL.lastPathComponent,
                            report: result.report,
                            thread: result.thread
                        )
                    }
                } catch {
                    NSLog("[ThreadTidy] pipeline failed: %@", "\(error)")
                    DispatchQueue.main.async {
                        state = .failed(message: error.localizedDescription)
                    }
                }
            }
        }
        return true
    }
}

// MARK: - PDFKit wrapper with anchor-based synced scrolling

// PDFView subclass that forwards click events to a closure after
// the standard text-selection behavior runs. We use mouseUp (rather
// than mouseDown) so dragging-to-select still works normally — the
// click handler only fires on a clean tap. The closure receives the
// click point in PAGE-LOCAL PDF coords (bottom-up) so the coordinator
// can compute its absolute document Y without re-doing the convert.
final class ClickAwarePDFView: PDFView {
    var onClick: ((PDFPage, NSPoint) -> Void)?
    private var dragOriginInWindow: NSPoint?

    override func mouseDown(with event: NSEvent) {
        dragOriginInWindow = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if let origin = dragOriginInWindow {
            let dx = event.locationInWindow.x - origin.x
            let dy = event.locationInWindow.y - origin.y
            if (dx * dx + dy * dy) > 16 {
                dragOriginInWindow = nil
                return
            }
        }
        dragOriginInWindow = nil
        let pt = convert(event.locationInWindow, from: nil)
        if let page = page(for: pt, nearest: true) {
            let pageCoord = convert(pt, to: page)
            onClick?(page, pageCoord)
        }
    }
}

// Per-document layout helper. Caches each page's height so we can
// translate freely between (pageIdx, pdfY) — what PDFKit speaks — and
// "absolute top-down Y" — a single scalar that increases as you
// scroll. We need that scalar so the synchronizer can do continuous,
// fraction-based interpolation across the whole document instead of
// jumping page-by-page.
struct DocMetrics {
    let pageHeights: [CGFloat]    // page i's media-box height
    let cumulativeY: [CGFloat]    // top-down Y where page i begins
    let totalHeight: CGFloat

    init(doc: PDFDocument) {
        var heights: [CGFloat] = []
        var cum: [CGFloat] = []
        var running: CGFloat = 0
        for i in 0..<doc.pageCount {
            cum.append(running)
            let h = doc.page(at: i)?.bounds(for: .mediaBox).height ?? 0
            heights.append(h)
            running += h
        }
        pageHeights = heights
        cumulativeY = cum
        totalHeight = max(running, 1)
    }

    // PDF coords are bottom-up: pdfY=0 is the page's bottom edge.
    // Top-down absoluteY: 0 = top of page 0, growing downward.
    func absoluteY(pageIdx: Int, pdfY: CGFloat) -> CGFloat {
        guard pageIdx >= 0, pageIdx < pageHeights.count else { return 0 }
        let h = pageHeights[pageIdx]
        return cumulativeY[pageIdx] + (h - pdfY)
    }

    func locate(absoluteY: CGFloat) -> (pageIdx: Int, pdfY: CGFloat) {
        if pageHeights.isEmpty { return (0, 0) }
        var y = max(0, absoluteY)
        for i in 0..<pageHeights.count {
            let h = pageHeights[i]
            if y < h {
                return (i, h - y)
            }
            y -= h
        }
        return (pageHeights.count - 1, 0)   // past end → bottom of last page
    }
}

// One matched (left, right) anchor — content that exists in both
// PDFs at known absolute-Y positions. Sorted lists of these drive
// the piecewise-linear scroll mapping.
struct AnchorPair {
    let leftAbsY: CGFloat
    let rightAbsY: CGFloat
}

// Synchronizes two PDF viewers using a piecewise-linear mapping
// derived from anchor pairs. Anchors come from text that's verbatim
// in BOTH PDFs:
//   1. Each email's date string (one anchor per email)
//   2. Each email's first long body line (a mid-email anchor)
//
// On any click or scroll in one pane, we compute the source position's
// absolute Y, find the bracketing anchor pair, linearly interpolate
// to get the destination Y, convert that back to (page, pdfY), and
// call go(to: PDFDestination) on the partner. A debounced
// suppress-feedback flag keeps the partner's resulting bounds-change
// from bouncing back.
final class SyncCoordinator: NSObject {
    weak var leftView: PDFView?
    weak var rightView: PDFView?

    private var leftMetrics: DocMetrics?
    private var rightMetrics: DocMetrics?
    // Two views over the same anchor data — sorted by left and right
    // respectively — so lookup from either side is O(log n).
    private var pairsByLeft: [AnchorPair] = []
    private var pairsByRight: [AnchorPair] = []

    private var suppressFeedback = false
    private var resetWork: DispatchWorkItem?

    func attach(left: PDFView, right: PDFView, thread: EmailThread) {
        self.leftView = left
        self.rightView = right
        guard let leftDoc = left.document, let rightDoc = right.document else { return }
        let lm = DocMetrics(doc: leftDoc)
        let rm = DocMetrics(doc: rightDoc)
        self.leftMetrics = lm
        self.rightMetrics = rm
        let pairs = Self.collectAnchors(
            thread: thread, leftDoc: leftDoc, rightDoc: rightDoc,
            leftMetrics: lm, rightMetrics: rm
        )
        self.pairsByLeft = pairs.sorted { $0.leftAbsY < $1.leftAbsY }
        self.pairsByRight = pairs.sorted { $0.rightAbsY < $1.rightAbsY }

        // Listen to scrolls on the embedded NSScrollView clip view.
        if let clip = Self.firstScrollView(in: left)?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(leftScrolled(_:)),
                name: NSView.boundsDidChangeNotification, object: clip
            )
        }
        if let clip = Self.firstScrollView(in: right)?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(rightScrolled(_:)),
                name: NSView.boundsDidChangeNotification, object: clip
            )
        }

        // Listen to clicks: clicking on a line in either pane jumps
        // the partner to the matching content (not just the email's
        // first page).
        (left as? ClickAwarePDFView)?.onClick = { [weak self] page, pt in
            self?.handleClick(view: left, page: page, pdfPoint: pt)
        }
        (right as? ClickAwarePDFView)?.onClick = { [weak self] page, pt in
            self?.handleClick(view: right, page: page, pdfPoint: pt)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func leftScrolled(_ note: Notification) {
        if suppressFeedback { return }
        if let leftView, let absY = viewportTopAbsY(view: leftView, isLeft: true) {
            align(srcAbsY: absY, fromLeft: true)
        }
    }
    @objc private func rightScrolled(_ note: Notification) {
        if suppressFeedback { return }
        if let rightView, let absY = viewportTopAbsY(view: rightView, isLeft: false) {
            align(srcAbsY: absY, fromLeft: false)
        }
    }

    private func handleClick(view: PDFView, page: PDFPage, pdfPoint: NSPoint) {
        let isLeft = view === leftView
        guard let metrics = isLeft ? leftMetrics : rightMetrics,
              let doc = view.document
        else { return }
        let pageIdx = doc.index(for: page)
        let absY = metrics.absoluteY(pageIdx: pageIdx, pdfY: pdfPoint.y)
        align(srcAbsY: absY, fromLeft: isLeft)
    }

    // Computes the absolute Y at the TOP of the viewport. We sample
    // the visible rect's top edge (handling flipped/non-flipped views)
    // rather than relying on PDFView.currentPage, which only reports
    // the dominant page — too coarse for fraction-based alignment.
    private func viewportTopAbsY(view: PDFView, isLeft: Bool) -> CGFloat? {
        guard let metrics = isLeft ? leftMetrics : rightMetrics,
              let doc = view.document
        else { return nil }
        let vr = view.visibleRect
        let topY = view.isFlipped ? vr.minY : vr.maxY
        let topPoint = NSPoint(x: vr.midX, y: topY)
        guard let p = view.page(for: topPoint, nearest: true) else { return nil }
        let pdfPt = view.convert(topPoint, to: p)
        let pageIdx = doc.index(for: p)
        return metrics.absoluteY(pageIdx: pageIdx, pdfY: pdfPt.y)
    }

    // Translate a source Y to the partner's Y via piecewise-linear
    // interpolation between adjacent anchor pairs.
    private func translate(srcAbsY: CGFloat, fromLeft: Bool) -> CGFloat? {
        let pairs = fromLeft ? pairsByLeft : pairsByRight
        guard !pairs.isEmpty else { return nil }
        let getSrc: (AnchorPair) -> CGFloat = fromLeft ? \.leftAbsY : \.rightAbsY
        let getDst: (AnchorPair) -> CGFloat = fromLeft ? \.rightAbsY : \.leftAbsY

        // Before first anchor → use the slope of the first segment
        // (or 1.0 if only one anchor) to extrapolate, then clamp at
        // the destination's first anchor so we never scroll above it.
        if srcAbsY <= getSrc(pairs[0]) {
            if pairs.count >= 2 {
                let slope = (getDst(pairs[1]) - getDst(pairs[0])) /
                            max(1, getSrc(pairs[1]) - getSrc(pairs[0]))
                return max(0, getDst(pairs[0]) + (srcAbsY - getSrc(pairs[0])) * slope)
            }
            return getDst(pairs[0])
        }
        // After last anchor → similar.
        if srcAbsY >= getSrc(pairs.last!) {
            if pairs.count >= 2 {
                let n = pairs.count
                let slope = (getDst(pairs[n - 1]) - getDst(pairs[n - 2])) /
                            max(1, getSrc(pairs[n - 1]) - getSrc(pairs[n - 2]))
                return getDst(pairs[n - 1]) + (srcAbsY - getSrc(pairs[n - 1])) * slope
            }
            return getDst(pairs.last!)
        }
        // Binary search for the bracket.
        var lo = 0, hi = pairs.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if getSrc(pairs[mid]) <= srcAbsY { lo = mid } else { hi = mid }
        }
        let a = pairs[lo], b = pairs[hi]
        let span = max(1, getSrc(b) - getSrc(a))
        let f = (srcAbsY - getSrc(a)) / span
        return getDst(a) + f * (getDst(b) - getDst(a))
    }

    private func align(srcAbsY: CGFloat, fromLeft: Bool) {
        guard let leftView, let rightView else { return }
        let dstView = fromLeft ? rightView : leftView
        guard let dstDoc = dstView.document,
              let dstMetrics = fromLeft ? rightMetrics : leftMetrics,
              let dstAbsY = translate(srcAbsY: srcAbsY, fromLeft: fromLeft)
        else { return }
        // Skip if we're already within ~6pt — avoids scroll jitter
        // when SwiftUI re-renders or the partner already arrived.
        if let currentTop = viewportTopAbsY(view: dstView, isLeft: !fromLeft),
           abs(currentTop - dstAbsY) < 6 { return }
        let (pageIdx, pdfY) = dstMetrics.locate(absoluteY: dstAbsY)
        guard let dstPage = dstDoc.page(at: pageIdx) else { return }

        suppressFeedback = true
        resetWork?.cancel()
        let dest = PDFDestination(page: dstPage, at: NSPoint(x: 0, y: pdfY))
        dstView.go(to: dest)
        // Hold the suppression briefly so the partner's resulting
        // bounds-change cascade doesn't echo back as a fresh sync
        // request. ~150ms covers PDFView's animation tail.
        let work = DispatchWorkItem { [weak self] in self?.suppressFeedback = false }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - Anchor collection

    // For each email collect:
    //   • a START anchor — uses the date string in the original
    //     (Gmail print PDF) and the "N. SenderName" heading in the
    //     cleaned PDF. We CAN'T reuse the date in the cleaned doc:
    //     the Index of Communications table on page 0 lists each
    //     email's date verbatim, so PDFKit's findString returns the
    //     index entry first and email 1's anchor lands on the title
    //     page instead of its actual heading. The "N. SenderName"
    //     heading format is only emitted on the email's heading page
    //     by TPPDFRenderer, never in the index, so it's a clean hit.
    //   • a first-body-line anchor (mid-email — improves intra-email
    //     fraction accuracy when emails span multiple pages)
    //
    // The CALLER guarantees leftDoc = original (Gmail print) and
    // rightDoc = cleaned (our output) by always passing originalURL
    // as leftURL when constructing SyncedPDFPair.
    static func collectAnchors(
        thread: EmailThread,
        leftDoc: PDFDocument, rightDoc: PDFDocument,
        leftMetrics: DocMetrics, rightMetrics: DocMetrics
    ) -> [AnchorPair] {
        var pairs: [AnchorPair] = []

        var leftStart: [Int: (pageIdx: Int, absY: CGFloat)] = [:]
        var rightStart: [Int: (pageIdx: Int, absY: CGFloat)] = [:]

        for m in thread.messages {
            // Original: date string — unique, no competing matches.
            let dateNeedle = m.date.trimmingCharacters(in: CharacterSet.whitespaces)
            if dateNeedle.count >= 8,
               let h = firstHit(in: leftDoc, text: dateNeedle, metrics: leftMetrics) {
                leftStart[m.index] = h
            }

            // Cleaned: "N. SenderName" heading. If that doesn't match
            // (e.g. the parser captured a slightly different name),
            // fall back to the date but skip ALL pages that contain
            // the index, by requiring the match be at or after email
            // 1's actual heading page.
            let headingNeedle = "\(m.index). \(m.fromName)"
                .trimmingCharacters(in: CharacterSet.whitespaces)
            if let h = firstHit(in: rightDoc, text: headingNeedle, metrics: rightMetrics) {
                rightStart[m.index] = h
            } else if dateNeedle.count >= 8 {
                // Fall back: find FIRST heading-style match for any
                // message to learn where the index ends, then require
                // date matches to be at-or-after that page.
                let firstEmailPage: Int = {
                    for mm in thread.messages {
                        let n = "\(mm.index). \(mm.fromName)"
                        if let h = firstHit(in: rightDoc, text: n, metrics: rightMetrics) {
                            return h.pageIdx
                        }
                    }
                    return 0
                }()
                if let h = firstHit(
                    in: rightDoc, text: dateNeedle, metrics: rightMetrics,
                    pageRange: firstEmailPage..<rightDoc.pageCount
                ) {
                    rightStart[m.index] = h
                }
            }
        }
        for m in thread.messages {
            if let l = leftStart[m.index], let r = rightStart[m.index] {
                pairs.append(AnchorPair(leftAbsY: l.absY, rightAbsY: r.absY))
            }
        }

        // Body-line anchors. The first body line that's at least 25
        // chars (skipping greetings like "Hi," or "Good morning,")
        // tends to be unique enough to find correctly within the
        // bounded page range. We use up to 60 chars so PDFKit's
        // findString matches a substring that sits on one rendered
        // line (avoiding cross-line wrap mismatches).
        for m in thread.messages {
            guard let leftS = leftStart[m.index],
                  let rightS = rightStart[m.index]
            else { continue }
            // End-page derivation: next email's start page, or doc end.
            // Clamp so it's always strictly greater than the start —
            // emails that share a page with the next one (very short
            // replies) would otherwise build an empty/inverted Range.
            let leftEndRaw = thread.messages
                .first { $0.index > m.index && leftStart[$0.index] != nil }
                .flatMap { leftStart[$0.index]?.pageIdx } ?? leftDoc.pageCount
            let rightEndRaw = thread.messages
                .first { $0.index > m.index && rightStart[$0.index] != nil }
                .flatMap { rightStart[$0.index]?.pageIdx } ?? rightDoc.pageCount
            let leftEndPage = max(leftS.pageIdx + 1, leftEndRaw)
            let rightEndPage = max(rightS.pageIdx + 1, rightEndRaw)

            for line in m.bodyLines {
                let plain = line.plain.trimmingCharacters(in: CharacterSet.whitespaces)
                if plain.count < 25 { continue }
                let needle = String(plain.prefix(60))
                guard let l = firstHit(
                    in: leftDoc, text: needle, metrics: leftMetrics,
                    pageRange: leftS.pageIdx..<leftEndPage
                ) else { continue }
                guard let r = firstHit(
                    in: rightDoc, text: needle, metrics: rightMetrics,
                    pageRange: rightS.pageIdx..<rightEndPage
                ) else { continue }
                pairs.append(AnchorPair(leftAbsY: l.absY, rightAbsY: r.absY))
                break   // one body anchor per email is plenty
            }
        }
        return pairs
    }

    private static func firstHit(
        in doc: PDFDocument, text: String, metrics: DocMetrics,
        pageRange: Range<Int>? = nil
    ) -> (pageIdx: Int, absY: CGFloat)? {
        for sel in doc.findString(text, withOptions: .literal) {
            guard let p = sel.pages.first else { continue }
            let idx = doc.index(for: p)
            if let r = pageRange, !r.contains(idx) { continue }
            let bounds = sel.bounds(for: p)
            if bounds.isNull { continue }
            // Top of the matched text in PDF coords (bottom-up): maxY.
            return (idx, metrics.absoluteY(pageIdx: idx, pdfY: bounds.maxY))
        }
        return nil
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView { return s }
        for sub in view.subviews {
            if let s = firstScrollView(in: sub) { return s }
        }
        return nil
    }
}

struct SyncedPDFPair: NSViewRepresentable {
    let leftURL: URL
    let rightURL: URL
    let thread: EmailThread
    let pickLeft: Bool   // if true makeNSView returns the left pane

    func makeCoordinator() -> SyncCoordinator { SyncCoordinator() }

    // Each call to makeNSView builds ONE PDFView. The two panes share
    // a SwiftUI EnvironmentObject-equivalent — we use the same
    // coordinator instance via the .coordinator() trick: both panes
    // reference a shared coordinator stashed on a singleton dict
    // keyed by URL pair, so attach() can be called once both views
    // exist.
    func makeNSView(context: Context) -> PDFView {
        let v = ClickAwarePDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.displaysPageBreaks = true
        v.backgroundColor = NSColor.controlBackgroundColor
        v.document = PDFDocument(url: pickLeft ? leftURL : rightURL)
        SyncedPair.shared.register(
            url: pickLeft ? leftURL : rightURL,
            view: v,
            leftURL: leftURL, rightURL: rightURL, thread: thread
        )
        return v
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}
}

// Module-level registry that pairs the two SwiftUI-built PDFViews so
// the SyncCoordinator can attach once both are created. Keyed by the
// (leftURL, rightURL) tuple so re-renders or multiple comparison
// sessions don't crosstalk.
final class SyncedPair {
    static let shared = SyncedPair()
    private var pending: [String: (left: PDFView?, right: PDFView?, thread: EmailThread, coord: SyncCoordinator)] = [:]

    func register(url: URL, view: PDFView, leftURL: URL, rightURL: URL, thread: EmailThread) {
        let key = "\(leftURL.absoluteString)|\(rightURL.absoluteString)"
        var entry = pending[key] ?? (
            left: PDFView?.none, right: PDFView?.none,
            thread: thread, coord: SyncCoordinator()
        )
        if url == leftURL { entry.left = view }
        if url == rightURL { entry.right = view }
        pending[key] = entry
        if let l = entry.left, let r = entry.right {
            // Defer attach to next runloop tick so PDFView's enclosing
            // scrollView/contentView is fully wired up.
            DispatchQueue.main.async {
                entry.coord.attach(left: l, right: r, thread: thread)
            }
        }
    }
}

// Top-level coordinator: input PDF → cleaned PDF on disk + integrity report.
enum Pipeline {
    struct Result {
        let url: URL
        let report: IntegrityReport
        let thread: EmailThread
    }

    static func run(input: URL, originalLocation: URL? = nil) throws -> Result {
        // PDFium is the primary extractor — it surfaces embedded font
        // weights and italics that PDFKit normalizes away. Falls back
        // to the PDFKit-based extractor if PDFium can't be loaded.
        let tokens: [StyledLine]
        do {
            tokens = try PDFiumExtractor().extract(from: input)
        } catch {
            tokens = try PDFTextExtractor().extract(from: input)
        }
        // Format-aware dispatch via ThreadTidyKit.Pipeline. Loads the
        // user's persisted Settings so engine + differential mode are
        // respected here. Falls back to the legacy Gmail parser if
        // dispatch fails (unknown format, etc.) — guarantees current
        // GUI behaviour for known-good inputs.
        let settings = ThreadTidyKit.Settings.load()
        let parsedBy: ParserKind
        let differential: ThreadDiff?
        let thread: EmailThread
        do {
            let out = try ThreadTidyKit.Pipeline.run(
                input: ThreadTidyKit.Pipeline.Input(url: input, settings: settings),
                prelinedLines: tokens
            )
            thread = out.thread
            parsedBy = out.parsedBy
            differential = out.diff
        } catch {
            thread = ThreadParser().parse(tokens: tokens)
            parsedBy = .heuristic
            differential = nil
        }
        let filename = Filenames.makeOutputName(thread: thread)
        // Output location is user-configurable in Settings →
        // "Output destination". Defaults to ~/Downloads; falls back to
        // the temp dir if the chosen directory can't be resolved.
        let outDir = settings.outputDestination.resolve(
            for: input, originalLocation: originalLocation
        )
        let outURL = Filenames.uniqueURL(in: outDir, filename: filename)
        let renderer = TPPDFRenderer()
        if settings.renderEngineFooter {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate]
            renderer.engineFooter = "Parsed by ThreadTidy on \(f.string(from: Date())) — engine: \(parsedBy.rawValue)"
        }
        try renderer.render(thread: thread, to: outURL)
        // Draw thin (~0.4pt) underlines under flagged runs. Must run
        // BEFORE PDFNavigationAnnotator so the latter's link annotations
        // sit on top of (not behind) any overlapping underline lines.
        PDFUnderlineAnnotator.annotate(url: outURL, thread: thread)
        // Add clickable jump-targets for the index + strip indicators
        // and stamp a per-thread UID into PDF metadata.
        PDFNavigationAnnotator.annotate(url: outURL, thread: thread)
        let report = IntegrityChecker().check(
            sourceLines: tokens,
            thread: thread,
            parsedBy: parsedBy,
            differential: differential
        )
        return Result(url: outURL, report: report, thread: thread)
    }
}

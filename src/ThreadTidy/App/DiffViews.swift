import SwiftUI
import ThreadTidyKit

// One coloured dot per message in the differential strip. Clicking
// opens a popover showing the per-field diff so the user can audit
// disagreements between heuristic and AI parses.
struct DiffDot: View {
    let messageDiff: MessageDiff
    @State private var showPopover = false

    var body: some View {
        Button(action: { showPopover = true }) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            DiffPopover(messageDiff: messageDiff)
        }
    }

    private var color: Color {
        if messageDiff.notes.contains(where: { $0.hasPrefix("unpaired") }) { return .red }
        if !messageDiff.fromMatches { return .red }
        if messageDiff.bodySimilarity < 0.85 { return .red }
        if !messageDiff.dateMatches { return .orange }
        if !messageDiff.toMatches { return .orange }
        if messageDiff.bodySimilarity < 0.95 { return .orange }
        return .green
    }

    private var tooltip: String {
        if messageDiff.notes.contains(where: { $0.hasPrefix("unpaired") }) {
            return "Message \(messageDiff.index): unpaired between heuristic and AI"
        }
        return String(
            format: "Message %d — body sim %.2f%@",
            messageDiff.index,
            messageDiff.bodySimilarity,
            (messageDiff.fromMatches && messageDiff.dateMatches
                && messageDiff.toMatches && messageDiff.ccMatches)
                ? "" : " (header diffs)"
        )
    }
}

// Field-level diff for one message. Shown when the user clicks a
// DiffDot. Read-only for now; "Use heuristic / Use AI" overrides
// (spec 09) are deferred — they require re-rendering the output PDF
// with one message swapped, which is a follow-up.
struct DiffPopover: View {
    let messageDiff: MessageDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message \(messageDiff.index)")
                .font(.headline)
            Divider()
            HStack {
                Label(
                    "Sender: \(messageDiff.fromMatches ? "match" : "mismatch")",
                    systemImage: messageDiff.fromMatches ? "checkmark.circle" : "xmark.octagon"
                )
                .foregroundStyle(messageDiff.fromMatches ? .green : .red)
            }
            HStack {
                Label(
                    "Date: \(messageDiff.dateMatches ? "match" : "mismatch")",
                    systemImage: messageDiff.dateMatches ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(messageDiff.dateMatches ? .green : .orange)
            }
            HStack {
                Label(
                    "To: \(messageDiff.toMatches ? "match" : "mismatch")",
                    systemImage: messageDiff.toMatches ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(messageDiff.toMatches ? .green : .orange)
            }
            HStack {
                Label(
                    "Cc: \(messageDiff.ccMatches ? "match" : "mismatch")",
                    systemImage: messageDiff.ccMatches ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(messageDiff.ccMatches ? .green : .orange)
            }
            HStack {
                Image(systemName: "text.alignleft")
                Text(String(format: "Body similarity: %.2f", messageDiff.bodySimilarity))
                    .foregroundStyle(messageDiff.bodySimilarity >= 0.95
                        ? .green : (messageDiff.bodySimilarity >= 0.85 ? .orange : .red))
            }
            if !messageDiff.notes.isEmpty {
                Divider()
                Text("Notes")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                ForEach(messageDiff.notes, id: \.self) { n in
                    Text(n).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !messageDiff.bodyMissingFromHeuristic.isEmpty {
                Divider()
                Text("Lines AI saw but heuristic dropped")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(messageDiff.bodyMissingFromHeuristic.prefix(20), id: \.self) { line in
                            Text("+ \(line)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            if !messageDiff.bodyAddedByHeuristic.isEmpty {
                Divider()
                Text("Lines heuristic kept that AI dropped")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(messageDiff.bodyAddedByHeuristic.prefix(20), id: \.self) { line in
                            Text("- \(line)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(14)
        .frame(width: 420)
    }
}

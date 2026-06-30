import Foundation
import ThreadTidyKit

// Self-contained unit test for OutlookThreadParser. Invoked via:
//
//   threadtidy-test outlook-test
//
// Exercises a synthetic three-message Outlook web print thread that
// reproduces the boundary the real `dirtyOutlook.pdf` exposed:
//
//   "On Thu, Apr 30, 2026 at 7:37AM Jane Doe <…> wrote:"
//                                         ^^ no space before AM
//
// With the pre-fix `replyBoundaryParts` regex the non-greedy `(.+?)`
// captures only "Thu," as the date, leaving the rest of the date
// glued onto the name. The post-fix regex anchors the date capture
// through the time component so name and date split correctly.
//
// Also covers a Gmail-style spaced variant ("7:37 AM") and the
// "From:/Sent:/To:/Subject:" forwarded block to guard against
// regressing the other branch of the parser.

func runOutlookUnitTest() -> Int32 {
    let lines: [StyledLine] = [
        line("Outlook"),
        line(""),
        line("Re: Test email hotmail print", bold: true),
        line("From Jane Doe <jane.doe@example.com>"),
        line("Date Thu 4/30/2026 8:38 AM"),
        line("To Jane Doe <jane.doe.alt@example.com>"),
        line("Cc john.smith@example.com <john.smith@example.com>"),
        line(""),
        line("Good morning,"),
        line("Your case is on the Unassigned docket today."),
        line(""),
        // The failing boundary: AM glued to the time, no comma before name.
        line("On Thu, Apr 30, 2026 at 7:37AM Jane Doe <jane.doe.alt@example.com> wrote:"),
        line("Dear Parties,"),
        line("Unfortunately, I am not available the week of May 11th."),
        line(""),
        // Forwarded-style boundary leading into the oldest message.
        line("From: Jane Doe <jane.doe@example.com>"),
        line("Sent: Thursday, April 30, 2026 8:36 AM"),
        line("To: Jane Doe <jane.doe.alt@example.com>"),
        line("Subject: Test email hotmail print"),
        line(""),
        line("Dear Ms. Johnson and Ms. Brown,"),
        line("I would prefer to proceed today."),
    ]

    let parser = OutlookThreadParser()
    let thread: ThreadTidyKit.Thread
    do {
        thread = try parser.parse(lines: lines)
    } catch {
        print("FAIL: parser threw \(error.localizedDescription)")
        return 1
    }

    var failures: [String] = []
    func check(_ ok: Bool, _ desc: String) {
        if ok { print("  ✓ \(desc)") }
        else { print("  ✗ \(desc)"); failures.append(desc) }
    }

    check(thread.subject == "Re: Test email hotmail print",
          "subject pulled from preamble (got '\(thread.subject)')")
    check(thread.messages.count == 3,
          "three messages parsed (got \(thread.messages.count))")

    if thread.messages.count >= 1 {
        let m0 = thread.messages[0]
        check(m0.fromName == "Jane Doe",
              "msg #1 fromName from stacked header (got '\(m0.fromName)')")
        check(m0.fromEmail == "jane.doe@example.com",
              "msg #1 fromEmail from stacked header (got '\(m0.fromEmail)')")
        check(m0.date == "Thu 4/30/2026 8:38 AM",
              "msg #1 date verbatim from header (got '\(m0.date)')")
        check(m0.to.contains("jane.doe.alt@example.com"),
              "msg #1 To: captured (got '\(m0.to)')")
        check(m0.cc?.contains("john.smith@example.com") == true,
              "msg #1 Cc: captured (got '\(m0.cc ?? "nil")')")
        let body = m0.bodyLines.map(\.plain).joined(separator: " ")
        check(body.contains("Good morning"),
              "msg #1 body preserves author prose")
        check(!body.contains("Dear Parties"),
              "msg #1 body stops at inline reply boundary")
    }

    if thread.messages.count >= 2 {
        let m1 = thread.messages[1]
        // The regression assertion: with the broken regex, fromName
        // was "Apr 30, 2026 at 7:37AM Jane Doe" and date was
        // "Thu,". After the fix, name is just the display name and
        // date spans through the time.
        check(m1.fromName == "Jane Doe",
              "msg #2 fromName from inline reply boundary (got '\(m1.fromName)')")
        check(m1.fromEmail == "jane.doe.alt@example.com",
              "msg #2 fromEmail from inline reply boundary (got '\(m1.fromEmail)')")
        check(m1.date.contains("Apr 30, 2026") && m1.date.contains("7:37"),
              "msg #2 date spans through time (got '\(m1.date)')")
        let body = m1.bodyLines.map(\.plain).joined(separator: " ")
        check(body.contains("Dear Parties"),
              "msg #2 body has author prose")
        check(!body.contains("Dear Ms. Johnson"),
              "msg #2 body stops at forwarded boundary")
    }

    if thread.messages.count >= 3 {
        let m2 = thread.messages[2]
        check(m2.fromName == "Jane Doe",
              "msg #3 fromName from forwarded block (got '\(m2.fromName)')")
        check(m2.fromEmail == "jane.doe@example.com",
              "msg #3 fromEmail from forwarded block (got '\(m2.fromEmail)')")
        check(m2.date.contains("April 30, 2026"),
              "msg #3 date from Sent: row (got '\(m2.date)')")
        check(m2.to.contains("jane.doe.alt@example.com"),
              "msg #3 To: from forwarded block (got '\(m2.to)')")
        let body = m2.bodyLines.map(\.plain).joined(separator: " ")
        check(body.contains("Dear Ms. Johnson"),
              "msg #3 body has author prose")
    }

    // Spaced-AM variant — guard against regressing the Gmail-style
    // form that already worked. Same line, just with a space.
    let spacedLines: [StyledLine] = [
        line("Outlook"),
        line(""),
        line("Re: Spaced AM test", bold: true),
        line("From Jane Doe <jane.doe@example.com>"),
        line("Date Thu 4/30/2026 8:38 AM"),
        line("To Jane Doe <jane.doe.alt@example.com>"),
        line(""),
        line("Top message."),
        line("On Thu, Apr 30, 2026 at 7:37 AM Jane Doe <jane.doe.alt@example.com> wrote:"),
        line("Older message."),
    ]
    let spaced: ThreadTidyKit.Thread
    do {
        spaced = try parser.parse(lines: spacedLines)
    } catch {
        print("FAIL: spaced variant threw \(error.localizedDescription)")
        return 1
    }
    check(spaced.messages.count == 2,
          "spaced-AM variant: two messages (got \(spaced.messages.count))")
    if spaced.messages.count >= 2 {
        let m = spaced.messages[1]
        check(m.fromName == "Jane Doe",
              "spaced-AM variant: name parsed (got '\(m.fromName)')")
        check(m.date.contains("Apr 30, 2026") && m.date.contains("7:37"),
              "spaced-AM variant: date spans through time (got '\(m.date)')")
    }

    if failures.isEmpty {
        print("\nOutlook unit test: PASS.")
        return 0
    }
    print("\nOutlook unit test: \(failures.count) failure(s).")
    return 1
}

private func line(_ s: String, bold: Bool = false) -> StyledLine {
    StyledLine(
        runs: [StyledRun(text: s, bold: bold)],
        indent: 0,
        isBullet: false
    )
}

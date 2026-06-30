import Foundation
import ThreadTidyKit

// Self-contained unit test for AppleMailThreadParser. Invoked via:
//
//   threadtidy-test applemail-test
//
// Constructs a synthetic [StyledLine] mimicking a two-message Apple
// Mail print thread, runs the heuristic parser, and asserts the
// recovered Thread has the expected shape. No PDF on disk required —
// PDFTextExtractor's output is what AppleMailThreadParser consumes, so
// feeding it the same StyledLine sequence directly is faithful to the
// production path.

func runAppleMailUnitTest() -> Int32 {
    let lines: [StyledLine] = [
        line("Jane Doe – Test thread", bold: true),
        line(""),
        line("From: Bob Reply <bob@example.com>"),
        line("Subject: Re: Test thread"),
        line("Date: On April 30, 2026 at 8:38:00 AM PDT"),
        line("To: Jane <jane.doe@example.com>"),
        line(""),
        line("Thanks for the update — sounds good."),
        line("Talk soon,"),
        line("Bob"),
        line(""),
        line("On April 30, 2026, at 7:37 AM, Jane Doe <jane.doe@example.com> wrote:"),
        line(""),
        line("Hi Bob,"),
        line("Sending the docket schedule for tomorrow."),
        line("Jane"),
        line("Page 1 of 1"),
    ]

    let parser = AppleMailThreadParser()
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

    check(thread.subject == "Re: Test thread",
          "subject pulled from Subject: row (got '\(thread.subject)')")
    check(thread.messages.count == 2,
          "two messages parsed (got \(thread.messages.count))")

    if thread.messages.count >= 1 {
        let m0 = thread.messages[0]
        check(m0.fromName == "Bob Reply",
              "msg #1 fromName = 'Bob Reply' (got '\(m0.fromName)')")
        check(m0.fromEmail == "bob@example.com",
              "msg #1 fromEmail = 'bob@example.com' (got '\(m0.fromEmail)')")
        check(m0.date.contains("April 30, 2026"),
              "msg #1 date preserves verbatim string (got '\(m0.date)')")
        check(m0.to.contains("jane.doe@example.com"),
              "msg #1 To: captured (got '\(m0.to)')")
        let body = m0.bodyLines.map(\.plain).joined(separator: " ")
        check(body.contains("Thanks for the update"),
              "msg #1 body preserves author prose")
        check(!body.contains("Hi Bob,"),
              "msg #1 body stops at inline reply boundary")
    }

    if thread.messages.count >= 2 {
        let m1 = thread.messages[1]
        check(m1.fromName == "Jane Doe",
              "msg #2 fromName from inline boundary (got '\(m1.fromName)')")
        check(m1.fromEmail == "jane.doe@example.com",
              "msg #2 fromEmail from inline boundary (got '\(m1.fromEmail)')")
        check(m1.date.contains("April 30, 2026"),
              "msg #2 date from inline boundary (got '\(m1.date)')")
        let body = m1.bodyLines.map(\.plain).joined(separator: " ")
        check(body.contains("Hi Bob"),
              "msg #2 body has author prose")
        check(body.contains("docket schedule"),
              "msg #2 body preserves multi-line content")
    }

    check(!thread.dateRange.isEmpty, "dateRange populated")

    if failures.isEmpty {
        print("\nAppleMail unit test: PASS (\(thread.messages.count) messages).")
        return 0
    }
    print("\nAppleMail unit test: \(failures.count) failure(s).")
    return 1
}

private func line(_ s: String, bold: Bool = false) -> StyledLine {
    StyledLine(
        runs: [StyledRun(text: s, bold: bold)],
        indent: 0,
        isBullet: false
    )
}

import Foundation
import ThreadTidyKit

// Self-contained unit tests for MLXThreadParser. Invoked via:
//
//   threadtidy-test mlx-test
//
// Covers:
//   * buildPrompt shape (system prompt + raw thread included)
//   * parseJSON: happy path, preamble-strip, no-braces error, decode
//     error, and correct `attempt` numbers
//   * mapToThread: empty cc/bcc handling
//   * dateRange: single-message vs multi-message rendering
//
// No real MLX inference is performed — runGeneration is a stub that
// throws .modelNotInstalled. These tests target the deterministic
// pipeline pieces that don't depend on a loaded model.

private struct TestCase {
    let name: String
    let run: () -> Bool
}

private var failures: [String] = []
private func check(_ ok: Bool, _ desc: String) -> Bool {
    if ok { print("  ✓ \(desc)") }
    else  { print("  ✗ \(desc)"); failures.append(desc) }
    return ok
}

func runMLXUnitTests() -> Int32 {
    failures = []
    print("MLX unit tests:")
    testBuildPromptShape()
    testParseJSONHappy()
    testParseJSONPreambleStrip()
    testParseJSONNoBraces()
    testParseJSONDecodeError()
    testParseJSONRetryAttemptNumber()
    testMapToThreadEmptyCcBcc()
    testDateRangeSingle()
    testDateRangeMulti()
    testTokenBudgetExists()
    testIsMessageBoundary()
    testNormalizeSenderFieldsBracketedInName()
    testNormalizeSenderFieldsDuplicatedBrackets()
    testNormalizeSenderFieldsBareEmailTail()
    testNormalizeSenderFieldsBracketedEmail()
    testNormalizeSenderFieldsAlreadyClean()
    testNormalizeSenderFieldsLiftsEmailWhenEmpty()
    testEnforceBoundariesSplitsInlineReply()
    testEnforceBoundariesSplitsStackedForwarded()
    testEnforceBoundariesNoOpWhenClean()
    testEnforceBoundariesBackfillsTo()

    if failures.isEmpty {
        print("\nMLX unit tests: PASS")
        return 0
    }
    print("\nMLX unit tests: \(failures.count) failure(s).")
    return 1
}

// MARK: - buildPrompt

private func testBuildPromptShape() {
    let parser = MLXThreadParser()
    let raw = "Alice <alice@example.com> Wed, Apr 29, 2026 at 11:17 AM\nHello"
    let prompt = parser.buildPrompt(raw: raw)
    _ = check(prompt.contains(raw), "buildPrompt embeds raw thread verbatim")
    _ = check(prompt.contains("Output ONLY valid JSON"),
              "buildPrompt includes system prompt directive")
    _ = check(prompt.contains("\"subject\""),
              "buildPrompt includes schema field reference")
}

// MARK: - parseJSON

private let goodJSON = """
{
  "subject": "Hello",
  "messages": [
    {
      "from_name": "Alice",
      "from_email": "alice@example.com",
      "date": "Wed, Apr 29, 2026 at 11:17 AM",
      "to": "bob@example.com",
      "cc": "",
      "bcc": "",
      "body": "Hi Bob,\\nThanks."
    }
  ]
}
"""

private func testParseJSONHappy() {
    let parser = MLXThreadParser()
    do {
        let p = try parser.parseJSON(goodJSON, retry: false, raw: "")
        _ = check(p.subject == "Hello", "parseJSON happy: subject decoded")
        _ = check(p.messages.count == 1, "parseJSON happy: one message")
        _ = check(p.messages.first?.from_email == "alice@example.com",
                  "parseJSON happy: from_email decoded")
    } catch {
        _ = check(false, "parseJSON happy: did not throw — \(error)")
    }
}

private func testParseJSONPreambleStrip() {
    let parser = MLXThreadParser()
    let withPreamble = "Sure, here is the JSON:\n\n" + goodJSON + "\n\n(end)"
    do {
        let p = try parser.parseJSON(withPreamble, retry: false, raw: "")
        _ = check(p.subject == "Hello",
                  "parseJSON strips non-JSON preamble + trailing prose")
    } catch {
        _ = check(false, "parseJSON preamble-strip threw: \(error)")
    }
}

private func testParseJSONNoBraces() {
    let parser = MLXThreadParser()
    do {
        _ = try parser.parseJSON("totally not json", retry: false, raw: "")
        _ = check(false, "parseJSON no-braces: should have thrown")
    } catch let MLXError.jsonParseFailure(reason, attempt) {
        _ = check(attempt == 1,
                  "parseJSON no-braces: attempt = 1 (got \(attempt))")
        _ = check(reason.contains("no JSON object"),
                  "parseJSON no-braces: reason mentions 'no JSON object' (got '\(reason)')")
    } catch {
        _ = check(false, "parseJSON no-braces: wrong error — \(error)")
    }
}

private func testParseJSONDecodeError() {
    let parser = MLXThreadParser()
    // Valid braces, missing required field "messages".
    let bad = #"{"subject": "x"}"#
    do {
        _ = try parser.parseJSON(bad, retry: false, raw: "")
        _ = check(false, "parseJSON decode-error: should have thrown")
    } catch let MLXError.jsonParseFailure(reason, attempt) {
        _ = check(attempt == 1, "parseJSON decode-error: attempt = 1")
        _ = check(reason.hasPrefix("decode:"),
                  "parseJSON decode-error: reason starts 'decode:' (got '\(reason)')")
    } catch {
        _ = check(false, "parseJSON decode-error: wrong error — \(error)")
    }
}

private func testParseJSONRetryAttemptNumber() {
    let parser = MLXThreadParser()
    do {
        _ = try parser.parseJSON("nope", retry: true, raw: "")
        _ = check(false, "parseJSON retry: should have thrown")
    } catch let MLXError.jsonParseFailure(_, attempt) {
        _ = check(attempt == 2, "parseJSON retry: attempt = 2 (got \(attempt))")
    } catch {
        _ = check(false, "parseJSON retry: wrong error — \(error)")
    }
}

// MARK: - mapToThread

private func testMapToThreadEmptyCcBcc() {
    let parser = MLXThreadParser()
    let p = MLXThreadParser.Payload(
        subject: "S",
        messages: [
            MLXThreadParser.Payload.Message(
                from_name: "A", from_email: "a@x", date: "D1",
                to: "b@x", cc: nil, bcc: nil, body: "hi"
            )
        ]
    )
    let thread = parser.mapToThread(p, sourceLines: [])
    _ = check(thread.subject == "S", "mapToThread: subject copied")
    _ = check(thread.messages.count == 1, "mapToThread: messages copied")
    let m = thread.messages[0]
    _ = check(m.cc == nil, "mapToThread: nil cc preserved")
    _ = check(m.bcc == nil, "mapToThread: nil bcc preserved")
    _ = check(m.bodyLines.map(\.plain).joined() == "hi",
              "mapToThread: body text preserved")
}

// MARK: - dateRange

private func testDateRangeSingle() {
    let parser = MLXThreadParser()
    let p = MLXThreadParser.Payload(
        subject: "S",
        messages: [
            MLXThreadParser.Payload.Message(
                from_name: "A", from_email: "a@x",
                date: "Wed, Apr 29, 2026 at 11:17 AM",
                to: "b@x", cc: nil, bcc: nil, body: "hi"
            )
        ]
    )
    let t = parser.mapToThread(p, sourceLines: [])
    _ = check(t.dateRange == "Wed, Apr 29, 2026 at 11:17 AM",
              "dateRange single: equals lone message date (got '\(t.dateRange)')")
}

private func testDateRangeMulti() {
    let parser = MLXThreadParser()
    let p = MLXThreadParser.Payload(
        subject: "S",
        messages: [
            MLXThreadParser.Payload.Message(
                from_name: "A", from_email: "a@x", date: "DATE1",
                to: "b@x", cc: nil, bcc: nil, body: "first"
            ),
            MLXThreadParser.Payload.Message(
                from_name: "B", from_email: "b@x", date: "DATE2",
                to: "a@x", cc: nil, bcc: nil, body: "second"
            )
        ]
    )
    let t = parser.mapToThread(p, sourceLines: [])
    _ = check(t.dateRange.contains("DATE1") && t.dateRange.contains("DATE2"),
              "dateRange multi: contains both endpoints (got '\(t.dateRange)')")
}

// MARK: - tokenBudget

private func testTokenBudgetExists() {
    _ = check(AIModel.llama1B.tokenBudget == 4096,
              "tokenBudget: llama1B = 4096 (got \(AIModel.llama1B.tokenBudget))")
    _ = check(AIModel.llama3B.tokenBudget > 0,
              "tokenBudget: llama3B > 0")
    _ = check(AIModel.phi35Mini.tokenBudget > 0,
              "tokenBudget: phi35Mini > 0")
}

// MARK: - isMessageBoundary

private func testIsMessageBoundary() {
    let header = StyledLine(runs: [StyledRun(
        text: "Alice Reply <alice@example.com>     Wed, Apr 29, 2026 at 11:17 AM"
    )])
    _ = check(MLXThreadParser.isMessageBoundary(header),
              "isMessageBoundary: gmail-style header matched")

    let quote = StyledLine(runs: [StyledRun(
        text: "On Wed, Apr 29, 2026 at 11:17 AM Alice <alice@example.com> wrote:"
    )])
    _ = check(MLXThreadParser.isMessageBoundary(quote),
              "isMessageBoundary: reply-quote header matched")

    let body = StyledLine(runs: [StyledRun(text: "Hello world.")])
    _ = check(!MLXThreadParser.isMessageBoundary(body),
              "isMessageBoundary: plain body line not matched")
}

// MARK: - normalizeSenderFields
//
// The quantized AI parser sometimes ignores the schema and packs the
// whole "Name <email>" header into from_name (or wraps from_email in
// angle brackets). normalizeSenderFields cleans these up so the
// renderer's heading line doesn't end up with a duplicated address.

private func testNormalizeSenderFieldsBracketedInName() {
    let (name, email) = MLXThreadParser.normalizeSenderFields(
        fromName: "Sarah Lee <sarah.lee@example.com>",
        fromEmail: "sarah.lee@example.com"
    )
    _ = check(name == "Sarah Lee", "bracketed-in-name: name cleaned")
    _ = check(email == "sarah.lee@example.com", "bracketed-in-name: email preserved")
}

private func testNormalizeSenderFieldsDuplicatedBrackets() {
    // The exact pattern from the diff journal that motivated this fix.
    let (name, email) = MLXThreadParser.normalizeSenderFields(
        fromName: "Sarah Lee<sarah.lee@example.com>",
        fromEmail: "sarah.lee@example.com"
    )
    _ = check(name == "Sarah Lee", "no-space-bracket: name cleaned")
    _ = check(email == "sarah.lee@example.com", "no-space-bracket: email preserved")
}

private func testNormalizeSenderFieldsBareEmailTail() {
    let (name, email) = MLXThreadParser.normalizeSenderFields(
        fromName: "Jane Doe jane.doe@example.com",
        fromEmail: "jane.doe@example.com"
    )
    _ = check(name == "Jane Doe", "bare-email-tail: name cleaned")
    _ = check(email == "jane.doe@example.com", "bare-email-tail: email preserved")
}

private func testNormalizeSenderFieldsBracketedEmail() {
    let (name, email) = MLXThreadParser.normalizeSenderFields(
        fromName: "Sarah Lee",
        fromEmail: "<sarah.lee@example.com>"
    )
    _ = check(name == "Sarah Lee", "bracketed-email: name preserved")
    _ = check(email == "sarah.lee@example.com", "bracketed-email: brackets stripped")
}

private func testNormalizeSenderFieldsAlreadyClean() {
    let (name, email) = MLXThreadParser.normalizeSenderFields(
        fromName: "Sarah Lee",
        fromEmail: "sarah.lee@example.com"
    )
    _ = check(name == "Sarah Lee", "already-clean: name unchanged")
    _ = check(email == "sarah.lee@example.com", "already-clean: email unchanged")
}

private func testNormalizeSenderFieldsLiftsEmailWhenEmpty() {
    // Court requirement: the email address must survive. If the model
    // dumped everything into from_name and left from_email blank, lift
    // the address out rather than dropping it.
    let (name, email) = MLXThreadParser.normalizeSenderFields(
        fromName: "Sarah Lee <sarah.lee@example.com>",
        fromEmail: ""
    )
    _ = check(name == "Sarah Lee", "lift-when-empty: name cleaned")
    _ = check(email == "sarah.lee@example.com", "lift-when-empty: email lifted from name")
}

// MARK: - enforceBoundariesPostHoc
//
// The quantized model sometimes buries a whole reply inside the
// preceding message's body. These tests cover the post-hoc splitter
// that catches that and re-splits at the embedded boundary.

private func makeMsg(
    from: String = "Newest Sender", email: String = "newest@example.com",
    date: String = "Date 1", to: String = "to@example.com", body: String
) -> MLXThreadParser.Payload.Message {
    MLXThreadParser.Payload.Message(
        from_name: from, from_email: email, date: date,
        to: to, cc: nil, bcc: nil, body: body
    )
}

private func testEnforceBoundariesSplitsInlineReply() {
    // One message whose body contains a full inline reply preface.
    // After enforcement, it must split into two messages.
    let buried = """
    Good morning,
    Your case is on the docket today.
    Thanks
    On Thu, Apr 30, 2026 at 7:37AM Jane Doe <jane.doe.alt@example.com> wrote:
    Older reply content here.
    Second line of the older reply.
    """
    let p = MLXThreadParser.Payload(
        subject: "Re: Test",
        messages: [makeMsg(body: buried)]
    )
    let out = MLXThreadParser.enforceBoundariesPostHoc(p)
    _ = check(out.messages.count == 2,
              "inline-reply split: 1 msg becomes 2 (got \(out.messages.count))")
    if out.messages.count == 2 {
        _ = check(out.messages[1].from_name == "Jane Doe",
                  "inline-reply split: second msg from_name extracted")
        _ = check(out.messages[1].from_email == "jane.doe.alt@example.com",
                  "inline-reply split: second msg from_email extracted")
        _ = check(out.messages[1].date.contains("7:37"),
                  "inline-reply split: second msg date captured through time")
        _ = check(out.messages[1].body.contains("Older reply content"),
                  "inline-reply split: second msg body starts after preface")
        _ = check(!out.messages[0].body.contains("Older reply"),
                  "inline-reply split: first msg body ends before preface")
    }
}

private func testEnforceBoundariesSplitsStackedForwarded() {
    let buried = """
    Body of the top message.
    More body.
    From: Older Sender <older@example.com>
    Sent: Thursday, April 30, 2026 8:36 AM
    To: Newest Sender <newest@example.com>
    Subject: Re: Test
    Older message body line 1.
    Older message body line 2.
    """
    let p = MLXThreadParser.Payload(
        subject: "Re: Test",
        messages: [makeMsg(body: buried)]
    )
    let out = MLXThreadParser.enforceBoundariesPostHoc(p)
    _ = check(out.messages.count == 2,
              "stacked-fwd split: 1 msg becomes 2 (got \(out.messages.count))")
    if out.messages.count == 2 {
        _ = check(out.messages[1].from_name == "Older Sender",
                  "stacked-fwd split: from_name extracted")
        _ = check(out.messages[1].from_email == "older@example.com",
                  "stacked-fwd split: from_email extracted")
        _ = check(out.messages[1].date.contains("April 30, 2026"),
                  "stacked-fwd split: date from Sent: row")
        _ = check(out.messages[1].to.contains("newest@example.com"),
                  "stacked-fwd split: to from To: row")
        _ = check(out.messages[1].body.contains("Older message body line 1"),
                  "stacked-fwd split: body starts after Subject row")
        _ = check(!out.messages[0].body.contains("Older message body"),
                  "stacked-fwd split: first msg body ends before header block")
    }
}

private func testEnforceBoundariesNoOpWhenClean() {
    // A clean payload with no embedded boundaries should pass through
    // untouched (apart from the to-backfill, which only runs on
    // messages with empty to).
    let p = MLXThreadParser.Payload(
        subject: "Hello",
        messages: [
            makeMsg(from: "A", email: "a@x.com", to: "b@x.com",
                    body: "Hi B.\nHope you're well."),
            makeMsg(from: "B", email: "b@x.com", to: "a@x.com",
                    body: "Hi A.\nDoing well."),
        ]
    )
    let out = MLXThreadParser.enforceBoundariesPostHoc(p)
    _ = check(out.messages.count == 2, "no-op: count preserved")
    _ = check(out.messages[0].body == "Hi B.\nHope you're well.",
              "no-op: msg #1 body preserved")
    _ = check(out.messages[1].to == "a@x.com", "no-op: msg #2 to preserved")
}

private func testEnforceBoundariesBackfillsTo() {
    // A 2-message payload where the second message has an empty to —
    // expect the backfill to derive it from the first sender.
    let p = MLXThreadParser.Payload(
        subject: "Hello",
        messages: [
            makeMsg(from: "Newest", email: "newest@x.com",
                    to: "older@x.com", body: "Reply body."),
            makeMsg(from: "Older", email: "older@x.com",
                    to: "", body: "Original message body."),
        ]
    )
    let out = MLXThreadParser.enforceBoundariesPostHoc(p)
    _ = check(out.messages.count == 2, "backfill: count preserved")
    _ = check(out.messages[1].to == "Newest <newest@x.com>",
              "backfill: to derived from previous sender")
}

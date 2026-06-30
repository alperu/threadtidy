#!/usr/bin/env bash
# Test the ThreadTidy pipeline end-to-end against a given input PDF.
#
# Usage:
#   ./script/test.sh                           # uses the bundled reference PDF
#   ./script/test.sh path/to/some.pdf          # uses your own input
#   ./script/test.sh path/to/in.pdf out.pdf    # also specifies output path
#
# What it does:
#   1. Builds the threadtidy-test executable via SwiftPM (one-time, cached).
#   2. Runs the executable against the input PDF.
#   3. The executable extracts → parses → renders → writes a clean PDF, then
#      asserts: output exists, parses, has pages, has zero Gmail chrome,
#      preserves author phrases, preserves bold/link styling, retains To/Cc.
#   4. Prints PASS / FAIL and exits with the appropriate code.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$ROOT/src/ThreadTidy"
DEFAULT_INPUT="$ROOT/resource/dirtyPdf/GmailPrint.pdf"

INPUT="${1:-$DEFAULT_INPUT}"
OUTPUT="${2:-$ROOT/build/test_output.pdf}"

# No sample PDF ships with the repo. If the caller didn't pass an input
# and the (historical) default isn't present, fail with a friendly hint
# rather than the obscure "file not found" below.
if [[ -z "${1:-}" && ! -f "$DEFAULT_INPUT" ]]; then
    echo "error: no input PDF given and no sample PDF present; pass a Gmail 'Print all' PDF: ./script/test.sh path/to/input.pdf" >&2
    exit 2
fi

if [[ ! -f "$INPUT" ]]; then
    echo "error: input PDF not found: $INPUT" >&2
    exit 2
fi

mkdir -p "$ROOT/build"

echo "==> Building threadtidy-test (Release)…"
( cd "$PKG_DIR" && swift build -c release --product threadtidy-test )

BIN="$PKG_DIR/.build/release/threadtidy-test"
if [[ ! -x "$BIN" ]]; then
    echo "error: built binary missing at $BIN" >&2
    exit 1
fi

echo
echo "==> Running pipeline test"
echo "    input:  $INPUT"
echo "    output: $OUTPUT"
echo

PIPELINE_RC=0
if "$BIN" "$INPUT" "$OUTPUT"; then
    echo
    echo "PASS — cleaned PDF at: $OUTPUT"
else
    PIPELINE_RC=$?
    echo
    echo "FAIL (exit $PIPELINE_RC) — see assertions above."
fi

# MLX synthetic unit tests — no PDF, no real inference. Exercises
# the prompt builder, JSON parser, body-style replay, chunker, and
# dateRange logic that don't depend on a loaded model.
echo
echo "==> MLX unit tests"
if "$BIN" mlx-test; then
    echo "PASS — MLX unit tests"
else
    rc=$?
    echo "FAIL — MLX unit tests regressed (exit $rc)"
    exit "$rc"
fi

# Settings unit tests — Codable + outputDestination resolver.
echo
echo "==> Settings unit tests"
if "$BIN" settings-test; then
    echo "PASS — Settings unit tests"
else
    rc=$?
    echo "FAIL — Settings unit tests (exit $rc)"
    exit "$rc"
fi

# AppleMail heuristic unit test — synthetic StyledLine stream for a
# two-message Apple Mail print thread. No PDF on disk required.
echo
echo "==> AppleMail heuristic unit test"
if "$BIN" applemail-test; then
    echo "PASS — AppleMail synthetic parse"
else
    rc=$?
    echo "FAIL — AppleMail unit test (exit $rc)"
    exit "$rc"
fi

# Outlook heuristic unit test — synthetic StyledLine stream covering
# the 7:37AM inline reply-boundary regression and the forwarded
# From:/Sent:/To:/Subject: block.
echo
echo "==> Outlook heuristic unit test"
if "$BIN" outlook-test; then
    echo "PASS — Outlook synthetic parse"
else
    rc=$?
    echo "FAIL — Outlook unit test (exit $rc)"
    exit "$rc"
fi

# Differential self-diff smoke test: heuristic vs itself must yield
# severity=ok, body sim 1.0 — sanity-checks DifferentialValidator.
echo
echo "==> Differential self-diff (sanity)"
if "$BIN" diff --self-diff "$INPUT"; then
    echo "PASS — self-diff identity"
else
    rc=$?
    echo "FAIL — self-diff regressed (exit $rc)"
    exit "$rc"
fi

# Corpus differential gate. Fails CI on any error-severity disagreement.
# AI side will be ai-skipped until MLX vendoring lands; that is a
# warning, not an error, so the gate stays green.
CORPUS_DIR="$ROOT/resource/dirtyPdf"
if [[ -d "$CORPUS_DIR" ]]; then
    echo
    echo "==> Differential corpus gate ($CORPUS_DIR)"
    if "$BIN" diff --corpus "$CORPUS_DIR" --quiet; then
        echo "PASS — no error-severity disagreements"
    else
        rc=$?
        echo "FAIL — error-severity disagreement in corpus (exit $rc)"
        echo "       run: $BIN diff --corpus $CORPUS_DIR  for details"
        exit "$rc"
    fi
else
    # No sample corpus ships with the repo. Skip the gate cleanly rather
    # than crash — supply your own dir of dirty PDFs to exercise it.
    echo
    echo "==> Differential corpus gate — skipped (no corpus dir at $CORPUS_DIR)"
fi

exit "$PIPELINE_RC"

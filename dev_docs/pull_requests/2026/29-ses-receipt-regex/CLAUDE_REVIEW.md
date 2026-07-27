# Code Review: PR #29 — Fix SES-over-SMTP receipt matching (gen_smtp strips the '250 ' prefix)

**Reviewed:** 2026-07-27
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/29
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 7897f3c065aa8f81d3132d54420287804ea81963
**Merge SHA:** f8758182c0b3826b7aa82d615a8eec92e1efb3ee
**Status:** Merged

## Summary

A one-regex fix in `DeliveryWorker.extract_message_id/1`. The Amazon SES
pattern added in PR #27 was anchored on a literal `250` that never appears in
the string this function receives:

```elixir
- ~r/^250[- ][\d.]*\s*Ok:?\s+<?([^>\s\r\n]+)>?\s*$/im
+ ~r/^(?:[\d.]+\s+)?Ok:?\s+<?([^>\s\r\n]+)>?\s*$/im
```

The two tests for the SES form are rewritten to use the receipt as it
actually arrives, and a variant with angle brackets plus an enhanced status
code is added.

## Verification

The claim is that `gen_smtp` removes the leading `"250 "` before returning
the receipt, so the pattern could never match a real SES send. Confirmed
against the vendored source rather than the PR description:

* `deps/gen_smtp/src/gen_smtp_client.erl:502` — `{ok, <<"250 ", Receipt/binary>>} -> Receipt`.
  The prefix is consumed by the binary match; only what follows is returned.
* `deps/swoosh/lib/swoosh/adapters/smtp.ex:61` —
  `receipt when is_binary(receipt) -> {:ok, receipt}`. Swoosh passes that
  same stripped binary straight through, and it reaches
  `extract_message_id/1` unmodified.

So the diagnosis is right, and the consequence is right too: SES-over-SMTP
message ids were being silently dropped (`extract_message_id/1` degrades to
`nil`, so the delivery row simply stored no provider message id — no error,
no log).

Checked the new pattern for regressions against the other MTA forms, since
this is the third of three regexes tried in order:

| Receipt reaching the function | Matched by | Result |
|---|---|---|
| `2.0.0 Ok: queued as 4Xf3k2` (Postfix) | regex 1 (`queued as`) | `4Xf3k2` — unchanged |
| `OK id=1a2b3c-000abc-XY` (Exim) | regex 2 (`id=`) | unchanged |
| `250 OK id=1a2b3c-000abc-XY` (raw line, if ever passed) | regex 2 | unchanged |
| `Ok 01000191abcdef-1234-5678\r\n` (SES, as delivered) | regex 3 | **now matches** |
| `Ok <01000191abcdef-1234-5678>\r\n` | regex 3 | matches, brackets stripped |
| `2.0.0 Ok 0100019...` (relay keeping the status code) | regex 3 | matches |
| `250 Ok 0100019...` (the old, unstripped form) | regex 3 | still matches — `250` satisfies `[\d.]+` |

The optional `(?:[\d.]+\s+)?` prefix is what keeps the last row working, so
the change is strictly a widening: everything the old pattern could match, it
still matches. `[^>\s\r\n]+` continues to exclude `>` so the optional closing
bracket isn't swallowed into the capture, and `\s*$` under `/m` absorbs the
trailing `\r\n`.

## Issues Found

None. The fix is correct, minimal, and the tests assert the real input shape
rather than the assumed one.

## Note on PR #27

The broken pattern came from PR #27, which I reviewed and approved. That
review verified the regex against the receipt strings quoted in the RFC/MTA
documentation — the wire format — and never checked what `gen_smtp` hands
back after parsing. Three regexes were checked for *shape* and none for
*provenance*. The lesson generalises past this one line: a pattern matching
data from a library should be verified against what that library returns, not
against what the protocol puts on the wire. The comment this PR leaves in
place — quoting the exact `gen_smtp` clause that does the stripping — is the
right defence against the next person making the same assumption.

## What Was Done Well

* **The root cause is named precisely, with the upstream code quoted inline**
  in the comment, so the next reader doesn't have to re-derive why the
  receipts arrive prefix-less.
* **The old test was fixed, not just supplemented.** The previous SES test
  asserted on `"250 Ok <id>"` — a string that never occurs — and would have
  gone on passing forever while production dropped every SES id. Replacing it
  removes the false assurance instead of leaving it alongside the new case.
* **Backwards compatibility is deliberate, not accidental.** The optional
  status-code group means a receipt that *does* still carry `250` keeps
  working, so the fix can't regress an MTA nobody tested against.

## Verdict

**Approved.** Correct diagnosis, verified against the vendored `gen_smtp` and
`swoosh` sources; strictly widens the matched set; tests now assert the real
input. No changes required.

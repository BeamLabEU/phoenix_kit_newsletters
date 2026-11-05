# Code Review: PR #42 — Make the address verification engine a host-configured contract

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/42
**Author:** Tymofii Shapovalov
**Status:** Merged (1b34b53)

## Summary

Publishes the `VerificationEngine` behaviour, removes the default engine and the
test dependency on an engine package, and adds optional `settings_path/0`. Codex's
review and follow-up are in this directory; this one covers the page as it stands
now, including 04abb08, which moved the batch start into `start_async/3`.

## Verification performed

- **Contract against its users.** All 14 `@callback`s are in the README table and
  implemented by `FakeVerificationEngine`, and the bridge calls every one except
  `verify/2`, which only marks a module as an engine. `@optional_callbacks` matches
  the callbacks the moduledoc lists as optional.
- **Degradation.** Every bridge call is gated by `available?/0` and
  `function_exported?/3`, and `call/4` rescues raises and catches exits, so a
  missing callback or a broken engine gives a neutral value. Addresses are masked
  in log lines and error tuples.
- **`settings_path/0`.** The regex rejects `//`, `/\`, control characters and
  white space. `/..//host` passes, but a browser resolves it as a path on this
  host, so it stays same-site.
- **Lifecycle.** A second start is refused while `starting`. `track_batch/2`
  subscribes before re-reading, so a batch that ends in between is not missed. A
  delayed active snapshot cannot reopen a finished batch, and a terminal message
  that arrives after the re-read is ignored rather than applied twice.
- **Mount.** No audience or batch reads; those are in `handle_params/3`.

## Findings

### BUG - MEDIUM — A late batch start was shown against the wrong audience — FIXED

The audience picker stays live while the engine stores a batch, which takes seconds
for a large audience. `handle_async/3` assigned whatever batch came back, so an
operator who started audience A and moved to audience B ended up with A's progress
on B's page, B's own batch replaced, and the start button disabled, until the next
audience change or a reload. No data was affected, but the page reported another
audience's run as this one's.

Not from this PR's diff: it arrived with 04abb08. It is recorded here because this
is the page the contract drives.

`start_batch/1` now records the audience in `:starting_audience`, and
`follow_started_batch/2` tracks the batch only if that is still the audience on
screen. Otherwise the flash still says it started, and `load_batch/1` finds the
batch again when the operator returns. The new test failed before the fix with the
batch assigned to the second audience.

### NITPICK — `gettext.extract --check-up-to-date` was failing on `main` — FIXED

FOLLOW_UP.md records it passing, but later commits moved lines, so it exits 1.
Only `#:` references had drifted, with no message added or changed. `mix precommit`
does not run this check, which is why nothing caught it. Refreshed; the gate itself
was left as it is.

## Validation

The fixes from this review pass, checked together on the final tree:

- `mix precommit`: passed (compile with warnings as errors, unused-lock check, Hex
  audit, format, strict Credo, Dialyzer with its two existing ignored warnings).
- `mix test`: 726 tests, 0 failures, integration tests included, on a scratch
  database. The baseline before any change was 721 tests, 0 failures.
- `mix gettext.extract --check-up-to-date`: passed.

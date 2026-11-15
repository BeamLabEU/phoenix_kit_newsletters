# Release review — 2026-11-15

**Reviewer:** Codex.
**Scope:** Changes since `0.8.0` through `c63c10d`, including the role audience,
consent, provider-event locking, crash masking and URL-state changes.
Dependencies resolved to core 3.6.0, CRM 0.19.0 and templates 0.2.5.

## Release state

`mix.exs` already declares 0.9.0. Hex and GitHub both report that version as
published on 2026-11-15; tag `0.9.0` points to `cf6c712`. The subsequent URL-state
commit and this review's fixes require a later release. This review does not
change versions, published release notes or tags.

## Findings fixed

### BUG - HIGH — Role unsubscribe left other accounts at the same inbox sendable

The preceding fix propagated CRM global consent to every account sharing the
address, but `record_opt_out/1`, used by role unsubscribe tokens, still marked
only its own account. With a personal account and a managed organization sharing
an inbox, the next role broadcast selected the other account and mailed the same
inbox again. The worker's final recipient check also allowed that account.

Role unsubscribe now applies the account opt-out writer to every account with
the same delivery address, using the existing account resolver. It uses a
managed organization's contact address and compares case-insensitively; it
does not require a linked CRM contact. Existing linked-contact propagation and
custom-field merge behavior remain in place.

The regression was reproduced before the fix. It checks both accounts' stored
consent, their eligibility immediately before delivery, the next audience, and
an unrelated account that must remain eligible.

### BUG - HIGH — Crash stacktrace arguments exposed email contents

`perform/1` masked exception messages but re-raised with the original stacktrace.
A stack frame containing function arguments can hold a whole `Swoosh.Email`, so
Oban's formatted exception could still expose the recipient, message body and
unsubscribe token. A provider with a harmless exception message and an email
argument reproduced the leak.

Worker crash traces now replace argument lists with their arities before
re-raising. Function names and source locations remain available. Existing
message masking, retry behavior and final-attempt recording are preserved.
The regression formats the resulting exception as a logger would and checks
that neither the address nor the token appears, while the provider's function
and error message remain visible and an early attempt stays pending.

### BUG - MEDIUM — CRM ordering test failed for UUIDs generated in one millisecond

The full baseline suite failed its stable-order assertion because the test
assumed two UUIDv7s always sort in creation order. Their random suffixes can
reverse that order within a millisecond; the resolver's explicit UUID ordering
was correct.

The test now assigns two explicit UUIDv7s in reverse insertion order and asserts
the resolver returns UUID order. It no longer depends on timing or randomness.

## Validation

- Baseline: 1,128 tests, one failure (the ordering test above).
- Focused recipient, CRM, worker and role-unsubscribe suites: 206 tests passed.
- Full suite after fixes: 1,130 tests, zero failures, with database integration
  tests enabled.
- `mix format` and `mix precommit` passed, including warnings-as-errors compile,
  unused-lock check, Hex audit, strict Credo and Dialyzer. Dialyzer used the
  existing Gettext/Expo generated-code exclusions; no exclusions were added.
- Core's UrlState, PageSize, pagination and Roles implementations are unchanged
  between the local `v3.5.0` and `v3.6.0` tags. The existing copied confirmation
  rule matches core 3.6's implementation; the dependency floor stays 3.5.0.
- No migrations or dependency changes.

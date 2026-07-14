# PR #15: Phase 1 "Sending Foundation" — Send Settings (SendProfile) and per-profile delivery

**Author**: @timujinne
**Reviewer**: GLM-5.2, 4 rounds × 2 independent agents (reviewer + component-architect)
**Status**: ✅ Reviewed, fixes applied
**Date**: 2026-07-14

## Goal

Integrations hold connection keys and nothing else. Everything about *how* a
campaign is sent — which account, at what rate, with which signature and reply-to —
belongs to the newsletters module. That is a **Send Profile**.

Several profiles may point at the **same** integration: one Brevo connection can
back a slow, signed newsletter profile and a fast transactional one. Profiles are
what a broadcast selects; the integration is only where the keys live.

- `SendProfile` schema + context (53f4f8c), Send Settings admin (de923f9).
- `DeliveryWorker` resolves the profile and sends through its integration (603ee80).
- Markdown rendering moved off the retired `earmark` to `MDEx` (589391e, after
  d9b468f restored a dependency an upstream commit had dropped while `content.ex`
  still called `Earmark.as_html`).

## Verified correct (no action needed)

Checked against the running Hydra Force dev app, not only against the tests:

- **Profiles that share an integration stay independent.** Two profiles created on
  the same Brevo SMTP connection — one slow and signed (60/hour, 5s pause), one
  fast and plain (5000/hour, no pause) — and a broadcast pinned to either resolves
  to exactly that profile. Rate, signature and reply-to live on the profile; keys
  live on the integration.
- **`enabled` is a real kill-switch.** A broadcast pinned to a disabled profile does
  not send from it — it falls through to the default, so an operator can stop a
  sender whose `from_email` got blacklisted without deleting the profile.
- **A disabled profile can never be the default.** `is_default: true` with
  `enabled: false` → `get_default_send_profile/0` returns `nil`; re-enable the same
  row and it is returned. The filter really is `enabled`.
- **Only one default can exist**, and the database enforces it, not just the UI —
  the partial unique index `idx_nl_send_profiles_default` rejects a second one.
- **Permanent failures cancel; transient ones retry.** `blocked`, `deleted`,
  `not_configured`, `invalid_smtp_port` and `unsupported_provider` → `{:cancel, _}`;
  `timeout`, `econnrefused` and unrecognised reasons → retried.

## BUG - HIGH (found and fixed): blocked recipients inflated the bounce count threefold and burned every retry

`DeliveryWorker` treated *every* delivery failure the same way. A recipient who was
blocked or deleted is not a failure to retry — but the worker returned `{:error, _}`,
so Oban retried it **3 times**, and each attempt incremented `bounced_count`. One
blocked address therefore recorded **three bounces** against a campaign that had
never bounced, and burned its retry budget doing it.

`permanent_failure?/1` now recognises blocked and deleted recipients and returns
`{:cancel, reason}`, which Oban does not retry. `record_permanent_failure/2` records
the outcome without ever touching `bounced_count`, and `"blocked"` joins
`@valid_statuses` on `Delivery` so the state is representable (c03b554).

## BUG - MEDIUM (found and fixed): the `enabled` toggle did nothing, and could not be switched off anyway

Two bugs stacked on top of each other:

1. **The flag was decorative.** `DeliveryWorker` resolved a profile without ever
   checking `enabled`, so disabling one changed nothing — the campaign kept sending
   through it.
2. **It could not be unchecked.** The editor used a raw `<input type="checkbox">`
   with no hidden `false` companion, so an unchecked box submits *nothing* and the
   changeset never saw `false`. Even after fixing (1), an operator could not have
   used it.

`resolve_send_profile/1` now honours the flag (c03b554), and the editor uses the
canonical `<.checkbox>` / `<.textarea>` components, which carry the hidden input
(e8c67d5).

## BUG - MEDIUM (found and fixed): `SendProfile` would have broken every prefixed install

The schema omitted `use PhoenixKit.SchemaPrefix`, so it hard-coded the default
prefix and would have looked for its table in the wrong schema on any multi-tenant
or low-privilege install. Caught by the conformance test upstream added while this
PR was in review — a good argument for merging `main` in before shipping (470bee5).

## Scoped back deliberately

The blocklist check was first wired to `RateLimiter.check_limits/1`, which also
enforces un-gated global caps (10k/hour). That would have throttled **all**
application mail and capped bulk broadcasts — a limit nobody asked for, arriving as
a side effect. Narrowed to `check_blocklist/1`; deliberate send pacing is Phase 5's
job, where it can be configured per profile.

## Gate

Full suite green, including the module's first test infrastructure
(`test/support/data_case.ex`, `test_repo.ex`, a real `test_helper.exs`) — the
delivery worker had no way to be tested before this PR.

The bounce-count and retry behaviour is pinned by `delivery_worker_test.exs`; the
resolution, kill-switch and failure-classification behaviour above was re-checked
live. Real sends go out through both a Brevo SMTP integration and SES.

# Code Review: PR #34 — Standardize AGENTS.md onto the shared module skeleton

**Reviewed:** 2026-10-21
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/34
**Author:** Max Don
**Status:** Merged (1e4d628)

## Summary

Rewrites AGENTS.md, makes `CLAUDE.md` a symlink to it, fixes the README's Oban
queue name, drops the never-read `newsletters_rate_limit`, and — the only code
change — makes `DeliveryWorker` stop sending for a cancelled broadcast: an
allow-list guard (`status == "sending"`) right after `get_broadcast/1`, repeated
immediately before `send_email/7`.

## Verification performed

- **The allow-list matches every real caller.** `Broadcaster.do_send/1` writes
  `"sending"` before enqueuing, and `retry_send/1` in the details page goes
  through `Broadcaster.send/1` (which re-flips to `"sending"`) after re-reading
  the row, so a retried broadcast is sendable again.
- **No stall path for a healthy send.** `maybe_finalize_broadcast/1` and the
  repair sweep move `"sending"` to `"sent"` only when no delivery is
  `"pending"`; a transient failure keeps `"pending"`, so a retrying job always
  runs under `"sending"`.
- **Skip is inert.** Both guards return `:ok` with no delivery-row write, so a
  cancelled send neither retries, bumps `bounced_count`, nor clears the last
  non-terminal delivery.
- `mix test`: delivery worker tests (including the unexpected-status case) pass.

## Findings

No bugs found.

### 1. NITPICK — a scheduled broadcast whose jobs start early would be skipped

A job reaching `perform/1` while the broadcast is still `"scheduled"` would be
dropped silently (logged at info, no retry). That cannot happen today because
`send/1` flips to `"sending"` before enqueuing; it is noted because it is the
cost of the fail-closed direction and AGENTS.md already records the trade-off.
No change.

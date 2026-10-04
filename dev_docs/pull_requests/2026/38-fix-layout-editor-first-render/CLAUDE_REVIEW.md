# Code Review: PR #38 — Fix layout editor crashing on first render

**Reviewed:** 2026-10-04
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/38
**Author:** Tymofii Shapovalov
**Status:** Merged (8de2a93)

## Summary

`LayoutEditor` assigned the record it edits under `:layout`. A dead render
merges the socket's assigns into `Phoenix.Controller.render/3`'s assigns,
which reads `:layout` as the page layout, so `/layouts/new` and
`/layouts/:id/edit` raised a `CaseClauseError` on first load. The assign is
now `:edited_layout`. The PR also adds a dead-render test (a never-listening
endpoint and router under `test/support/`) that GETs every admin LiveView.

## Verification performed

- **Fix is complete.** `rg` for `assigns.layout`, `assign(:layout`, `@layout`
  and `:layout` across `lib/` and `test/`: no remaining use of the reserved key.
  The `.heex` templates only use `layout` as a block variable or in ids.
- **Other reserved keys.** No LiveView assigns `:flash`, `:conn`,
  `:live_action`, `:inner_content` or `:root_layout`.
- **Test stand-ins.** `DeadRenderHooks` assigns only what a host's `on_mount`
  provides (`url_path`, scope, user, locale), never anything the LiveViews set
  themselves, so it cannot mask the bug it guards against.

## Findings

### 1. IMPROVEMENT - MEDIUM — `PreferenceCenterLive` was not covered by the dead-render test

The convention added in AGENTS.md is "add a route there for every new
LiveView", and the test's moduledoc says "every admin LiveView". The one
public LiveView, `PreferenceCenterLive`, mounted in its own `live_session` in
`Web.Routes`, had no route in `DeadRenderRouter`, so it was exposed to the same
class of first-load crash with nothing to catch it.

**Fixed:** added the route to `DeadRenderRouter` and two dead-render tests
(an invalid token renders; no token and no login redirects to log-in).
AGENTS.md now says "every LiveView".

### 2. NITPICK — query string in the `get/2` path is not seen by the LiveView

While writing the tests, `get(conn, "/newsletters/preferences?token=bogus")`
reached `handle_params/3` without the `token` param (it took the no-login
branch), whereas `get(conn, path, %{"token" => "bogus"})` worked. Not a
product bug (browsers send the query string normally); the new test uses the
params form. Not investigated further.

## Not changed

- The `:layout` risk is only guarded by a test, not by a compile-time check.
  A credo/grep rule would be over-engineering for one reserved key; the
  AGENTS.md note and the dead-render test cover it.

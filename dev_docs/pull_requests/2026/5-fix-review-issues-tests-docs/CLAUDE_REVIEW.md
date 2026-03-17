# Code Review: PR #5 — Fix code review issues and improve tests/docs

**Reviewed:** 2026-03-17
**Reviewer:** Claude (claude-opus-4-6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/5
**Author:** Tim (timujinne)
**Head SHA:** 3afd4934e713cd3be4262f2e9649397d3bb41ceb
**Status:** Merged

## Summary

Two commits addressing remaining code review items: a bug fix for the unsubscribe controller, version/0 override, improved test resilience, new unit tests for Broadcaster and UnsubscribeController, and README documentation updates.

### Commits

1. **e0d3360** — Add fallback clause to `UnsubscribeController` for missing token
2. **3afd493** — Fix medium/low priority issues from code review (version/0, fragile tests, new tests, README)

## Issues Found

### 1. [QUALITY - MEDIUM] Test directory doesn't match renamed namespace — FIXED

**Files:**
- `test/phoenix_kit/modules/newsletters/broadcaster_test.exs`
- `test/phoenix_kit/modules/newsletters/web/unsubscribe_controller_test.exs`

The namespace was renamed from `PhoenixKit.Modules.Newsletters` to `PhoenixKit.Newsletters` in commit 171726c (just before this PR). The new test files are placed under `test/phoenix_kit/modules/newsletters/` instead of `test/phoenix_kit/newsletters/`, creating a mismatch between test directory structure and source namespace.

**Fix:** Move test files to `test/phoenix_kit/newsletters/` to match the source layout.

**Resolution:** Moved both test files to `test/phoenix_kit/newsletters/`. Updated broadcaster test module name to `PhoenixKit.Newsletters.BroadcasterTest`. Removed empty `test/phoenix_kit/modules/` directory tree. Also fixed a pre-existing bug where `function_exported?` returned false because `Code.ensure_loaded?` wasn't called first — consolidated the controller's module structure tests into a single test that loads the module before checking exports.

**Confidence:** 95/100

---

### 2. [QUALITY - MEDIUM] Content rendering logic misplaced in Broadcaster — FIXED

**File:** `lib/phoenix_kit/newsletters/broadcaster.ex`

The `strip_html/1` function and `Earmark.as_html` markdown rendering are content concerns, not broadcast orchestration concerns. Additionally, `Earmark.as_html` was duplicated across 3 files with inconsistent error handling:

| Location | Error handling |
|---|---|
| `broadcaster.ex` | Returns HTML on both ok/error |
| `newsletters.ex` | Returns `{:ok, html}` / `{:error, errors}` |
| `broadcast_editor.ex` | Returns HTML on ok, `""` on error |

**Resolution:** Extracted `PhoenixKit.Newsletters.Content` module with three public functions:
- `render_markdown/1` — always returns HTML string (used by Broadcaster, BroadcastEditor)
- `render_markdown_strict/1` — returns `{:ok, html}` / `{:error, errors}` (used by context's `render_broadcast_html/1`)
- `strip_html/1` — HTML to plain text conversion

All three callers updated. `Earmark` is now called in exactly one module. Dedicated `content_test.exs` covers all functions plus the full markdown-to-text pipeline. Broadcaster tests trimmed to only test Broadcaster's own logic (send guards, module structure).

**Confidence:** 90/100

---

### 3. [QUALITY - LOW] Duplicate test case — OPEN

**File:** `test/phoenix_kit_newsletters_test.exs`

`"returns a list of Tab structs"` and `"admin_tabs returns a non-empty list"` are identical — both assert `[_ | _] = Newsletters.admin_tabs()`.

**Fix:** Remove one of the duplicates.

**Confidence:** 99/100

---

### 4. [QUALITY - LOW] Token tests test Phoenix.Token, not the controller — OPEN

**File:** `test/phoenix_kit/newsletters/web/unsubscribe_controller_test.exs` lines 22–73

The `"token verification"` describe block tests `Phoenix.Token.verify/4` and `Phoenix.Token.sign/3` directly with a standalone key base. These tests verify Phoenix library behavior, not controller behavior. They won't catch regressions in how the controller uses tokens (e.g., wrong salt, wrong max_age, missing endpoint config).

**Fix:** Consider integration tests that call the controller actions with `Plug.Test.conn/3` or `Phoenix.ConnTest`, verifying the actual redirect/flash behavior for valid, invalid, and missing tokens.

**Confidence:** 85/100

---

### 5. [QUALITY - LOW] Controller changed from `use PhoenixKitWeb, :controller` to `use Phoenix.Controller` directly — OPEN

**File:** `lib/phoenix_kit/newsletters/web/unsubscribe_controller.ex` lines 4–5

```elixir
# Before:
use PhoenixKitWeb, :controller

# After:
use Phoenix.Controller, formats: [:html]
import Plug.Conn
```

This bypasses any shared controller setup (error handling, common plugs, imports) that `PhoenixKitWeb` may provide. This may be intentional to reduce coupling to the host app, but should be verified.

**Confidence:** 70/100

---

## What Was Done Well

- **Fallback clause** — Clean, correct fix for the `FunctionClauseError` on tokenless requests. The flash message and redirect are appropriate.
- **`version/0` override** — `unquote(Mix.Project.config()[:version])` is the idiomatic compile-time approach. Removes the stale `"0.0.0"` default.
- **Test resilience** — Replacing hardcoded counts (`== 9`) and values (`== "0.0.0"`) with pattern matching and regex is a good improvement.
- **README** — Practical documentation for installation, Oban setup, and auto-discovery.

## Verdict

**Approved with suggestions** — The functional changes (fallback clause, version fix, README) are correct and valuable. Medium issues (test directory mismatch, content rendering misplaced in Broadcaster) have been fixed in a follow-up. Three low-priority items remain open for future cleanup.

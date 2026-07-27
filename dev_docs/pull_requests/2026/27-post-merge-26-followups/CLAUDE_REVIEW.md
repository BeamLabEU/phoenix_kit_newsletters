# Code Review: PR #27 — Post-merge #26 follow-ups: subscribable picker, stranded selection, receipt variants, single-pass substitution

**Reviewed:** 2026-07-25
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/27
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 8a80214d3d0efc7c80b38943d09773235fe25deb
**Status:** Merged

## Summary

Four independent post-merge follow-ups to PR #26:

1. **Subscribable picker** — `CRMSource.list_lists/0` now passes
   `subscribable: true` alongside `status: "active"`, so operational CRM
   segments (suppliers, imports) stop being offered as broadcast targets.
2. **Stranded selection** — the broadcast editor keeps a currently-selected
   list visible as a disabled `<option selected>` when that list has fallen
   out of the picker's options (archived, or `subscribable` turned off after
   the broadcast picked it).
3. **Receipt variants** — `DeliveryWorker.extract_message_id/1` recognises
   Exim (`id=<id>`) and Amazon SES SMTP (`250 Ok <MessageID>`) receipts in
   addition to the Postfix-family `queued as` form.
4. **Single-pass substitution** — `substitute_variables/2` swapped a per-key
   `Enum.reduce` + `String.replace` for one `Regex.replace` pass, closing the
   re-substitution hole where a variable *value* containing a literal
   `{{other_key}}` got expanded by a later key's pass.

All four fixes are correct in substance. The problems found are one gate
failure and two quality issues, all fixed here.

## Issues Found

### 1. [BUG - HIGH] Merged code fails the project's own quality gate (`mix credo --strict`) — FIXED

**File:** `lib/phoenix_kit/newsletters/workers/delivery_worker.ex` lines 363–369
**Confidence:** 100/100

The new `extract_message_id/1` chained the three receipt regexes through a
`with` whose every clause pattern is `nil` and whose `do` block is also `nil`:

```elixir
with nil <- run_receipt(regex_a, result),
     nil <- run_receipt(regex_b, result),
     nil <- run_receipt(regex_c, result) do
  nil
end
```

This is *functionally* correct (a non-`nil` result falls out of the `with` as
the unmatched value; all-`nil` returns the `do` block's `nil`), and the added
tests pass. But `Credo.Check.Refactor.RedundantWithClauseResult` flags the last
clause as redundant, so `mix credo --strict` — and therefore `mix precommit`,
the gate AGENTS.md requires green before release — **failed on merged `main`**.
Confirmed by running it: `found 1 refactoring opportunity`.

Beyond the gate, the construct reads as an error-handling pipeline when it is
really "first regex that matches wins", which is what obscured the redundancy
in the first place.

**Fix applied:** replaced with an explicit ordered list + `Enum.find_value/2`,
which states the intent directly and returns `nil` on no match by definition.
`mix credo --strict` is now clean. The ordering comment and all four
`extract_message_id/1` tests are unchanged and still pass.

### 2. [BUG - MEDIUM] Editor issues two identical `get_list/1` queries per keystroke — FIXED

**File:** `lib/phoenix_kit/newsletters/web/broadcast_editor.ex` lines 290–293 (as merged)
**Confidence:** 95/100

`assign_preflight/1`'s `crm_list` clause called `CRMSource.get_list/1` twice
with the same uuid — once inside `crm_list_archived?/1` and again inside the
new `stranded_crm_list/2`:

```elixir
|> assign(:crm_list_archived?, crm_list_archived?(crm_list_uuid))   # get_list/1
|> assign(:stranded_crm_list, stranded_crm_list(crm_list_uuid, ...)) # get_list/1 again
```

The whole broadcast form carries `phx-change="validate"`
(`broadcast_editor.html.heex:12`), and `handle_event("validate", …)` ends in
`assign_preflight/1`. So every keystroke in the Subject field already cost one
preflight aggregate + one `get_list`; this PR made it one preflight + **two**
`get_list` round trips. Not a correctness bug, but a per-keystroke DB cost the
PR added for nothing, on the hot path of the editor.

**Fix applied:** resolve the list once in the clause and feed both consumers
from it. `crm_list_archived?/1` (a uuid → bool wrapper around a fetch) became
`archived?/1` (a list → bool pure predicate), and `stranded_crm_list/2` now
takes the already-fetched list, with a `nil` clause for a uuid that resolves to
nothing. Behaviour is identical in every case, including the "uuid no longer
resolves" one (`archived? == false`, `stranded == nil`), which the new tests
pin down.

### 3. [IMPROVEMENT - MEDIUM] `list_lists/0` and `list_subscribable_lists/0` became byte-identical duplicates — FIXED

**File:** `lib/phoenix_kit/newsletters/crm_source.ex` lines 54–60 and 344–350 (as merged)
**Confidence:** 100/100

After this PR both functions had exactly the same body:

```elixir
soft_call(@lists_mod, :list_lists, [[status: "active", subscribable: true]])
```

Two copies of one filter rule, in one module, ~290 lines apart, with different
docstrings and *different callers* (the broadcast editor vs. the preference
center) — the classic "two lists that must stay in sync" setup. The next change
to what counts as an offerable list will be made in one and missed in the
other, and the two test blocks (`list_lists/0 — picker offers only subscribable
lists` and `list_subscribable_lists/0 only returns active lists with
subscribable: true`) would both still pass while the behaviours diverged.

**Fix applied:** `list_lists/0` now delegates to `list_subscribable_lists/0`.
Both public names and both docstrings are kept — the two call sites are
genuinely different domains and renaming them is out of scope for a review —
but there is now a single query to change.

### 4. [OBSERVATION] The disabled stranded `<option>` preserves the selection by *not* being submitted

**File:** `lib/phoenix_kit/newsletters/web/broadcast_editor.html.heex` lines 71–78
**Confidence:** 90/100

Worth recording because the mechanism is not the obvious one. Per the HTML
form-data-set algorithm, a `<select>` contributes an entry only for options
whose selectedness is true **and whose disabledness is false** — so the
stranded `<option selected disabled>` is *never submitted at all*.

The fix still works, via the other path: `crm_list_uuid` is then absent from
`params`, `resolve_crm_list_uuid/3`'s `params["crm_list_uuid"] || assigns.crm_list_uuid`
falls through to the assign, and the value is preserved. Contrast the bug
being fixed: with no stranded option the browser selects the placeholder,
submits `crm_list_uuid=""`, and `"" || assigns…` keeps `""` (empty string is
truthy in Elixir) — the silent reset. Both the diagnosis and the fix are right;
only the stated causal chain in the code comment is slightly off, and the
comment doesn't actually claim the option is submitted, so it is left as-is.

### 5. [OBSERVATION] An unresolved `unsubscribe_url` still substitutes to `""` — pre-existing, not fixed

**File:** `lib/phoenix_kit/newsletters/workers/delivery_worker.ex` lines 210–227, 268
**Confidence:** 85/100

`maybe_put_preferences_url/2` deliberately *omits* `preferences_url` when it
resolves to `""`, with a well-argued comment: an empty value dropped into
`<a href="{{preferences_url}}">` yields a link to the site root — "quietly
broken", worse than a visible literal `{{preferences_url}}`.

The identical hazard applies to `unsubscribe_url`, which `build_unsubscribe_url/2`
returns as `""` whenever the CRM membership no longer resolves — and it is put
into the variables map unconditionally, so the footer unsubscribe link silently
becomes a link to the site root. For an unsubscribe link specifically that is a
compliance concern, not just a cosmetic one.

**Deliberately not fixed here.** It predates this PR (it is #26-era code), and
the fix is a live-send behaviour change — either omitting the key (leaving a
visible `{{unsubscribe_url}}` in a real recipient's email) or suppressing the
whole footer — which wants a product decision, not a review-time edit. Recorded
so the asymmetry is on file.

### 6. [OBSERVATION] A non-subscribable list stays sendable; only archived is gated

**File:** `lib/phoenix_kit/newsletters/web/broadcast_editor.ex` lines 410–414
**Confidence:** 95/100

`recipient_source_missing?/1` gates Send now/Schedule on
`crm_list_archived?`, not on subscribable. So a broadcast already pointing at
an active-but-non-subscribable list is stranded in the picker yet still sends.
This matches the docstring's stated intent verbatim ("The flag only gates NEW
selection here: an existing broadcast … still resolves … for display and
sending"), so it is intended, not a defect. Flagged only because the "no longer
selectable" label could read to an operator as "and therefore won't send".

## Verification Notes

- **`subscribable:` is a real option.** Confirmed against the dependency, not
  the PR description: `deps/phoenix_kit_crm/lib/phoenix_kit_crm/lists.ex:110`
  pipes through `maybe_filter_subscribable/2` (line 757), documented at line
  104. A silently-ignored option would have made fix #1 a no-op.
- **`get_list/1` cannot crash on a malformed uuid.** `PhoenixKitCRM.Lists.get_list/1`
  casts first and returns `nil` on `:error`, so `stranded_crm_list/2` inherits
  no `Ecto.Query.CastError` risk from a hand-edited param.
- **`assign_preflight/1` never runs before `:crm_lists` is assigned.** Both
  `handle_params` clauses assign `crm_lists` earlier in the same pipeline, and
  `mount/3` seeds it to `[]` without calling `assign_preflight/1` — so
  `socket.assigns.crm_lists` in the new stranded lookup can't `KeyError`.
- **The `\w+` narrowing in `substitute_variables/2` drops nothing.** Every key
  `build_variables/2` can produce (`name`, `email`, `unsubscribe_url`,
  `preferences_url`) is `\w`-only, and `Regex.replace/4` with a function
  replacement inserts the value verbatim (no backreference re-processing), so
  the substitution is genuinely single-pass.
- **The re-substitution bug the PR claims to fix was real.** Erlang orders
  small-map iteration by term order, so `"name"` was reduced before
  `"unsubscribe_url"` — a username of `{{unsubscribe_url}}` really did get
  expanded by the later pass.
- **Receipt regex ordering is sound.** `queued as` is tried before `\bid=`, so a
  Postfix receipt can't be mis-parsed by the Exim pattern; `\bid=`'s word
  boundary correctly refuses to match inside `msgid=`.
- **Gettext is complete.** The one new msgid
  (`"%{name} (no longer selectable)"`) is present and translated in `en`, `et`
  and `ru`; the rest of the 151-line `.po`/`.pot` churn is reference-comment
  renumbering.

## Gate Result

Run after the fixes above, on the full `mix precommit` set:

| Step | Result |
|---|---|
| `mix format` | clean |
| `mix compile --warnings-as-errors` | clean |
| `mix credo --strict` | **no issues** (was 1 before fix #1) |
| `mix dialyzer` | passed (2 errors, 2 skipped — pre-existing ignore file) |
| `mix test` | 100 tests, 0 failures |

`mix test` reports 173 excluded: this environment has no Postgres, so every
`DataCase` test is skipped, per the package's documented standalone-testing
stance. The four new editor tests below are in that excluded set and need a DB
run to execute.

## Tests Added

`test/phoenix_kit/newsletters/web/broadcast_editor_test.exs` — new describe
block `"stranded CRM selection"`, four cases pinning down every branch of the
refactored `assign_preflight/1` clause:

- a non-subscribable selection absent from the options → stranded, not archived
- a selection present in the options → not stranded
- an archived selection → stranded **and** `crm_list_archived?`
  (the case where the two derived assigns must disagree with each other, which
  is exactly what the single-fetch refactor could have broken)
- a uuid resolving to nothing → neither stranded nor archived

## What Was Done Well

- **Every fix ships with a test that would have caught its bug**, including the
  adversarial one (`a variable VALUE containing another {{tag}}`) rather than
  only the happy path.
- **The stranded-option fix addresses the right failure.** Silently resetting
  `crm_list_uuid` on save because the browser fell back to the placeholder is
  precisely the kind of data loss an operator never notices; catching it as a
  consequence of the subscribable filter — in the same PR that introduced the
  filter — is good discipline.
- **The subscribable filter is correctly scoped to selection only.** Routing
  display and sending through `get_list/1` means the change can't retroactively
  break broadcasts that already target such a list.
- **Comments explain the non-obvious.** The map-iteration-order reasoning behind
  the substitution bug, and the MTA-by-MTA receipt catalogue, are the kind of
  context that stops the next person from "simplifying" the fix back into the
  bug.

## Verdict

**Approved with fixes.** The four functional changes are correct and
well-tested. One gate failure (credo, issue #1) meant merged `main` could not
have passed `mix precommit` as required before a release; one avoidable
per-keystroke duplicate query (#2) and one sync-hazard duplication (#3) were
introduced alongside. All three are fixed here, with four tests added covering
the refactored branch. Full gate is green.

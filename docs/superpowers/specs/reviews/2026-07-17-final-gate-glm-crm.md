I now have everything needed. Final verification confirms: `members_by_email`'s only caller (`preview_rows`) never reads `:contact` (so its preload is dead weight); `list_by_email`'s only production caller is the comparison drill-down (so the dropped preload is safe); and the import path honors the "no `connect_user`" Locked decision. 

One process note to surface: **HEAD advanced to a 5th delta commit (`ababa87`) mid-review** — it was not in the task's 4-commit list nor my initial log. I reviewed it as part of HEAD.

---

## Stage 1: Spec Compliance (delta `11fb259..HEAD`, i.e. the 4 named commits + `ababa87`)

**Are the two MINORs from my consolidated review fixed?** Yes — correctly, and one was over-delivered:
- **Counter drift** → `5a89551` added the `was_subscribed?` guard, then **`ababa87` hardened it to an atomic `update_all`** (`lists.ex:369-385` `remove_member_row/2`: WHERE `status=="subscribed"` → bump; fallthrough WHERE `status!="removed"` → pending, no bump; else `:already_removed`). Race-safe (two-tab TOCTOU closed). This is exactly the fix, done better than I asked.
- **Missing broadcasts** → `5a89551` added `broadcast_on_ok(:contact_opt_out/:contact_opt_in, &contact_payload/1)` (`lists.ex:478-499`). Correct, matches the `list_created`/`list_updated` pipe style.

**Intent per commit — all met:**
- `e608692` (batch preview): `members_by_email/2` one-query map (`lists.ex:310-319`); `preview_row/2` classifies against it (`import.ex:310-316`); arity-2 `upload_errors` fix via `all_upload_errors/1` (`list_import_live.ex:433-438`). ✓
- `5a89551` (counter guard + broadcasts): as above. ✓
- `e5272d0` (overlap dedup + preload drop): `wanted = list_uuids |> Enum.uniq() |> length()` (`lists.ex:454`); `IN ^list_uuids` with dups is semantically dedup'd, `count(distinct)` vs distinct `wanted` — correct. `list_by_email/1` preload dropped; verified only caller is `comparison_live.ex:48` (renders name/email/inserted_at). ✓
- `9ff1496` (auto_upload + done?-gate): `auto_upload: true` (`list_import_live.ex:46`); Preview `disabled={entries==[] or not Enum.all?(entries, & &1.done?)}` (`:244-247`). ✓
- `ababa87` (TOCTOU + core pin): atomic remove/reactivate; `Postgrex.Error` rescue restores `:email_already_in_list` (`lists.ex:222-228`); spec narrowing + dead-code removal in `list_members_live.ex:133`; mix.exs comment-only. ✓

**Adversarial checks:**
- **citext case alignment (batched map)** — SOUND. `distinct_emails` normalizes (`import.ex:139-145`), `members_by_email` queries `email in ^emails` (citext = case-insensitive `IN`) and builds downcased keys (`lists.ex:318`); `process_row` downcases the per-row email via `normalize_email` *before* calling the resolver (`import.ex:276,286`), so lookup key ↔ map key align. The citext partial unique index prevents case-variant dup keys. No drift.
- **telemetry self()-filter under async** — SOUND. Verified from Ecto source: the `:log` callback that fires `:telemetry.execute` (`ecto_sql/lib/ecto/adapters/sql.ex:1315`) runs in the **caller process** of `DBConnection.execute/4` (`db_connection.ex:876` → `run/3` `fun.(conn)` `:995` → `log/4`), which for `preview_rows` is the test process. Event name `[:phoenix_kit_crm, :test, :repo, :query]` matches `telemetry_prefix` (`supervisor.ex:55-59`). Counts ~2 real queries, asserts `<= 3`, would catch a per-row regression (300). **Not a tautology.**
- **broadcast payload shape** — SAFE. `contact_payload` (`lists.ex:655`) lacks `list_uuid`, but `list_members_live.ex:147` has a catch-all `handle_info(_msg, socket)`; `lists_live.ex:64` matches any payload. No subscriber crashes.

**Spec Verdict: PASS**

---

## Stage 2: Code Quality

### MAJOR — `preview_upload` has no server-side guard; crashes on a not-done entry via direct event injection
**File**: `lib/phoenix_kit_crm/web/list_import_live.ex:59-69` (handler), `:244-247` (the client-side-only gate)
**Problem**: The `done?`-gating added in `9ff1496` lives only on the button's `disabled=` attribute — client-side. The handler calls `consume_uploaded_entries/3` (`:60`) with no `entry.done?` check and no rescue. Phoenix raises `ArgumentError` ("cannot consume uploaded files when entries are still in progress") when any entry is not done (`deps/phoenix_live_view/lib/phoenix_live_view/upload.ex:248-249`). With `auto_upload: true` there is now a real window (file picked → upload completes) where a directly-injected `phx-submit="preview_upload"` event terminates the LiveView process. Pre-`auto_upload` this window did not exist (entries were never in-progress at submit), so **this is a regression introduced by `9ff1496`**. The `[]` clause (`:66`) only fires when there are *no* entries at all — it does not cover the in-progress case.
**Exploitability (be honest)**: low — the disabled button + HTML form-submission semantics block *all* normal browser interaction; triggering it requires a crafted WS frame on the user's own authenticated session; recoverable; preview is read-only (no data loss). But the principle stands: the client-side disable is not a server-side guard.
**Suggestion**: guard server-side before consuming, e.g. wrap the consume or check `Enum.all?(socket.assigns.uploads.file.entries, & &1.done?)`, returning the existing "Choose a file first" flash otherwise (or `rescue ArgumentError`).
**Rationale**: defense-in-depth + the documented Phoenix `auto_upload` gotcha; one-line fix.

### MINOR — `lists_live` reloads the whole lists index on every directory-wide contact opt-out/opt-in
**File**: `lib/phoenix_kit_crm/web/lists_live.ex:64`; payload `lib/phoenix_kit_crm/lists.ex:655`
**Problem**: `:contact_opt_out`/`:contact_opt_in` are contact-level (don't change any list's `subscriber_count`) but ride the `crm:lists` topic; `lists_live`'s `handle_info({:crm, _event, _payload}, socket)` reloads on every such event — a wasted query per consent change, amplified in a future bulk preference-center flow.
**Suggestion**: tighten the clause to the list-scoped events (`:list_created|:list_updated|:member_added|:member_removed|:list_recounted`) and ignore `:contact_opt_*`.
**Rationale**: keeps the index responsive and avoids coupling it to unrelated contact mutations.

### NITPICK — `members_by_email/2` preloads `:contact` its only caller never reads
**File**: `lib/phoenix_kit_crm/lists.ex:317`; caller `lib/phoenix_kit_crm/lists/import.ex:129,310-316`
**Problem**: `preview_row/2` only pattern-matches `%{status: "removed"}` / `%{}` — never `member.contact`. The preload is a second query scaling with collision count, partially undercutting the batching win for large previews (the `<= 3` test even leaves headroom for it).
**Suggestion**: drop `|> repo().preload(:contact)` here (its docstring's "same as `get_member_by_email/2`" parity argument doesn't hold — *that* function's callers use `:contact`, this one's don't), or keep the preload only if a future caller needs it.
**Rationale**: the whole point of `e608692` is a cheap dry-run; don't pay for data that's discarded.

**Observations (no action):**
- **Process**: HEAD advanced to `ababa87` (5th delta commit) during this review — beyond the task's listed 4. Reviewed as part of HEAD; it's sound and supersedes `5a89551`'s non-atomic counter guard with the atomic `remove_member_row`.
- **AI-attribution sweep (`main..HEAD`)**: clean — no `Claude`/`Anthropic`/`Generated with`/`Co-Authored-By` markers in any commit body (consistent with your "omit the Generated-with line" preference).
- **`mix.lock` final state**: unchanged across the entire branch; `mix.exs` delta is comment-only; `phoenix_kit` pin `~> 1.7 and >= 1.7.189` ↔ lock `1.7.192` is consistent.
- **Plan Locked decisions vs HEAD**: no contradictions — import creates new contacts (no merge), per-row contact+membership transaction, unsubscribed holds the slot, contact-level opt-out/consent, **no `connect_user`/`find_or_create_user_by_email` in the import path** (`import.ex` routes through `Contacts.create_contact/1`), counter+PubSub net-new, V152-core dependency honestly documented in the new comment.

**Quality Summary:** 0 critical, 1 major, 1 minor, 1 nitpick
**Quality Verdict:** Needs Work (one cheap guard)

---

## Overall Verdict: FAIL

One blocking item, otherwise the delta is PASS-quality and correctly resolves both prior MINORs (counter drift even hardened to atomic in `ababa87`):

1. **`list_import_live.ex:59` — add a server-side `done?` guard (or `rescue`) before `consume_uploaded_entries`** so a directly-injected `preview_upload` during the auto-upload window can't crash the LiveView. One line.

Then optionally: narrow `lists_live.ex:64` to list-scoped events, and drop the unused `:contact` preload in `members_by_email/2` (`lists.ex:317`). Nothing else blocks ship.

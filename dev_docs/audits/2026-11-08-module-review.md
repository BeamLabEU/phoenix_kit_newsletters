# Module review — 2026-11-08

**Reviewer:** Claude (claude-opus-5-5). It read the send pipeline, rendering and the
migration chain itself, and had two independent read-only reviews done: one of
how the web layer uses core's components, and one hunting bugs in the web layer.
**Baseline:** `7dfbc8e` (0.7.1; core 3.4.0, CRM 0.19.0, templates 0.2.4). The
scope was the last two weeks of history, `5cbbc99..7dfbc8e`.

Both earlier reviews (`2026-11-05-module-audit.md`, `2026-11-06-module-review.md`)
were read first, and nothing in their "Left open" lists is repeated here. Every
finding below was checked against the code, and for core components against core's
`v2.65.0` tag, the module's floor, before anything was changed.

## Bugs

### 1. BUG - HIGH — A send profile's signature broke the text part's unsubscribe link — FIXED

`build_profile_email/5` appended `signature_text` straight onto the finished text
part. Since 0.7.1 that part ends with the unsubscribe address, so every profile with
a signature sent `…?token=XYZBest, Acme`: a dead link for anyone reading the text
part, the very reader the line was added for. The HTML signature went after
`</html>`, outside the layout's card and under the unsubscribe line.

The signature is now part of the body, `Render.html/4` and `text/3`'s `:signature`
option: inside the layout's `{{{content}}}`, above the unsubscribe line, on lines of
its own in the text, and filled in by the same substitution pass. The worker resolves
the profile once per job, before rendering. The editor preview shows it too.

### 2. BUG - MEDIUM — Send now on `/new` could mail the audience twice — FIXED

The send ran inside the click's event. Resolving and enqueueing a large audience can
take longer than the 30 seconds LiveView's client waits for an answer, after which it
reloads the page. On `/new` that was an empty form, with the first send still going in
the old process, and a second Send now made and sent a second broadcast.

The event now saves the draft, answers, and patches the page to `/edit/:id`; the send
runs from `handle_info({:send_now, _})` after the answer, with the buttons disabled
(`@sending`). A reload reopens the same draft, and its row lock refuses a second send.
A refused send leaves the page on the draft's own address, so a reconnect no longer
inserts a second row either. Send now also clears a schedule time the draft kept, and
a new broadcast records its author (`created_by_user_uuid` was never set).

### 3. BUG - MEDIUM — A reconnect lost the layout editor's other tabs — FIXED

Only the open tab's fields were inputs. A remount reads the layout from the database
and form recovery replays the form, so an unsaved edit on any other language tab went
back to the stored text, its badge vanished, and Save wrote the old text. Every other
tab's text is now a hidden `all[field][key]` input; the server takes only text, under
a key some tab owns.

### 4. BUG - MEDIUM — A reconnect dropped a broadcast's attachments — FIXED

Attachments lived only in assigns. After a reconnect a new broadcast had none, and
Send now mailed everyone without the files. They are hidden inputs now, behind an
`attachments_sent` marker so a form without them changes nothing; only well-formed
uuids, at most ten.

### 5. BUG - MEDIUM — The preference page wrote consent from the tab's copy of the contact — FIXED

CRM judges an opt-out or opt-in on the struct it is given and writes the consent log
from it. After an opt-out from an email link, "Unsubscribe from all" on a tab opened
earlier replaced the log entry and the first opt-out's time. Every write now re-reads
the contact. A toggle keeps the direction the visitor clicked, and a list already that
way (`:already_member`, `:not_member`) is no longer an error. With no contact the
events answer instead of crashing.

### 6. BUG - MEDIUM — A crafted Retry started a draft — FIXED

`retry_send` re-read the row but sent whatever it was, and `Broadcaster.send/1` also
starts drafts and scheduled broadcasts. A crafted `show_confirm` with
`action=retry_send` sent one at once from the details page, and the CRM permission was
checked on the page's copy. Retry now requires the fresh row to be `failed` and checks
permissions on it. A confirmed action is cleared once it has run.

### 7. BUG - MEDIUM — The details page's message panel closed on every patch — FIXED

A hand-written `<details>`: morphdom removed the client-set `open` on Refresh or after
a confirm. Core's `accordion` marks it client-owned.

### 8. BUG - MEDIUM — No notifications bell on any Newsletters page — FIXED

No admin template passed `socket` (the bell is a nested LiveView) or `current_locale`
to `app_layout`. All six do now, as `assigns[:socket]` so hand-built test renders work.

## Core components

Checked against `v2.65.0`, the floor; none needed a newer core.

| Page | Was | Now |
|---|---|---|
| Details | hand-made `modal modal-open` (no Esc, backdrop, focus trap) | `confirm_modal` |
| Details | duplicated `md:hidden` card list | card-capable `table_default` with `card_fields` |
| Details | `<details>` | `accordion` |
| List | `phx-click` rows, server `push_navigate` | `row_link`: a real link, middle-click and keyboard work |
| List | create button in `:toolbar_actions` | `:toolbar_primary`, as the guide says |
| List, layouts, verification | raw status `<select>` | `select` |
| Layouts | raw `<table>`, inline action buttons, hand-made toolbar | `table_default` toolbar slots, `table_row_menu`, `status_badge` |
| Editor | raw subject input, selects, role checkboxes | `input`, `select`, `checkbox`; the stranded CRM list is a disabled option |
| Editor | source radios `class="hidden"`, out of keyboard reach | radios drawn as buttons, as on the verification page |
| Layout editor | raw inputs, textareas and footer | `input`/`textarea` with `hint` (`aria-describedby`), `form_actions` |

The broadcast badge colours lived in two LiveViews and are now
`StatusLabel.broadcast_badge_class/1`. The dead `@saving` assign went: it was set and
cleared inside one event, so no render ever saw it. Admin URLs in the broadcast
LiveViews go through `Paths`.

Considered and left as they are: `StatCard` (gradient tiles, value before title, no
`patch`), core's `email_status_badge` (other colours, English labels), core's pager on
the verification page (see below), and the preview's language picker (daisyUI's inline
label, which core's `select` does not draw).

## Smaller fixes

- "(1 addresses)" on the verification page: two `ngettext`s, translated.
- A crafted `status[]=` on the broadcast and layout filters, and `fields=x` /
  `name[a]=b` in the layout editor, crashed the visitor's LiveView. Ignored now.
- On the unsubscribe page, "OR" no longer follows a finished result.
- The throttle log prints `0.28s`, not `0.2777777777777778s`.
- `Broadcast.changeset/2` turns a missing author into an error rather than a raise.

## Verification

- `mix precommit` passes. `mix test`: 1091 tests, 0 failures, none excluded (1067 at
  the baseline). `mix gettext.extract --check-up-to-date` is clean; et and ru have no
  empty, fuzzy or binding-mismatched entries.
- **Mutation check:** each of these, undone, fails its test: the text signature, the
  re-read contact, the other tabs' hidden inputs, Retry's `failed` gate, the form's
  attachments, and the patch to `/edit`.
- Once, the layouts render test failed while the layouts page was being converted; it
  did not recur in seven runs of the file and the suite.

## Behaviour that changed

- A profile signature is inside the layout, above the unsubscribe line, and its
  placeholders are filled in.
- Send now moves `/new` to `/edit/:id` before it sends, and clears a kept schedule time.
- New broadcasts record their author.
- Retry on the details page sends only a broadcast that is still `failed`.
- The layout list's actions are in a ⋮ menu, and its rows' Edit is a link there.
- The editor's subject, CRM list and layout fields are core's, labelled above the field.

## Left open

- **Retry and Resend still run inside the click's event.** A large audience can outlast
  the client's 30 s timeout there too, and the page reloads. The row lock and the
  status check make a second click refuse, so it is a worse experience, not a second
  send. The editor's two-step pattern would fix it.
- **Core's link-mode pager prints "« Prev" / "Next »" in English** at every tag,
  including `v3.4.0` (`pagination.ex`, the `build_url` branch), on the broadcast list
  and the deliveries. The fix is two `gettext` calls in core. The verification page
  keeps its own translated pager for that reason.
- **Times ignore the site's date format.** `Web.Timezone` formats with `strftime`. Core
  has no absolute-time component; its `format_date_with_cached_settings/2` helpers would
  change what every site sees, so it is a decision, not a fix.
- **The preference page's list toggle is still a raw `toggle`.** Core's `checkbox`
  variant puts it left of the text; on a public page that is a design call.
- `pagination_bar` and `PageSize` exist only on core's main after `v3.4.0`.
- `AGENTS.md` is 32,745 bytes, just under its 32 KiB limit.
- The new Estonian and Russian strings, like the last review's, have had no native review.

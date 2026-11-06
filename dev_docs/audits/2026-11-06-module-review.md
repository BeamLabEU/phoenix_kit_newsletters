# Module review — 2026-11-06

**Reviewer:** Claude (claude-opus-5-5), with four independent read-only reviews: the
send pipeline, the public surface and verification, the admin pages, and the data
layer with rendering and packaging.
**Baseline:** `36998c6` (core 3.4.0, CRM 0.19.0, templates 0.2.4).

The earlier audit, `2026-11-05-module-audit.md`, concentrated on the send pipeline
and rendering. This one read everything, and most of what it found was somewhere
that audit did not look: the public pages, the emailed links and the editor.

Every finding fixed here was checked against the code first, because a reviewer's
mistakes read exactly like its findings. None of those turned out to be wrong.

## Dependencies

`mix.lock` was already at the latest versions on Hex: core 3.4.0, CRM 0.19.0,
templates 0.2.4. `ueberauth` 0.11 is held back by core. Nothing in core 3.3 or 3.4
changes this module's contract, and the suite passed on them unchanged.

The floors for `phoenix_kit_templates` (`~> 0.2.4`) and test-only `phoenix_kit_crm`
(`~> 0.19`) moved up to what is tested. Core's stays at `>= 2.65.0`: every API these
fixes call was checked at that tag.

## Critical

### 1. BUG - CRITICAL — Tokens used an endpoint no host starts — FIXED

`PhoenixKit.Config.get(:endpoint, PhoenixKitWeb.Endpoint)` falls back to a module
that ships in core and that nothing starts in a host. `Phoenix.Token` asks it for a
secret, which is an `:ets.lookup` on a table that does not exist, so it raises. Core
fixed the same mistake in `sessions.ex`.

On a host with no `:endpoint` key, every delivery to a recipient with a link crashed,
and every unsubscribe and token preference page was a 500. `langust` and `woodmatrix`
both set only `parent_module`. The suite could not see it, because `config/test.exs`
sets a raw secret.

`UnsubscribeToken.endpoint/0` now tries the explicit key, then
`Config.get_parent_endpoint/0`. A test removes the key and proves the old fallback
raises.

### 2. BUG - CRITICAL — A pasted body never reached the server — FIXED

The textarea sat in the form as `editor_content`, and nothing read it. The body
changed only on `keyup`, so a mouse paste, a drag or a reconnect left the server's
copy behind. Send now then mailed the whole audience an empty message, or the old body
on `/edit`, with nothing to warn the operator: Ctrl+V works, because it fires `keyup`.

`validate` and submit now read the form, and Send now and Schedule refuse a blank body.

## High

### 3. BUG - HIGH — Emailed links 404 on a multilingual site — FIXED

`Routes.url/1` adds a locale segment, and the public routes exist at the root only.
Unsubscribe links, the one-click URL, the preferences link and the confirm form's action
all pointed at nothing. The preferences login redirect hardcoded `/phoenix_kit/...`,
which doubled the prefix everywhere.

`Paths` builds public URLs with `locale: :none`. A test turns languages on and checks
each one against a router built from `Web.Routes.generate/1`. Core's sidebar does
localize a dashboard tab, so preferences gained a `/:locale/` route as well.

### 4. BUG - HIGH — Unsubscribe links died after 7 days — FIXED

Mail is read later than that, and a mail client's one-click POST still got its 200, so
it reported success while the mail kept coming. Unsubscribe tokens no longer expire:
they can only reduce what someone receives. Preference tokens, which can resubscribe,
last 30 days instead of 7. `max_age` is checked at verify time, so this reaches mail
already sent.

### 5. BUG - HIGH — An unconfirmed account could take someone's contact — FIXED

Registration logs in before confirmation, and the preference page linked any account
to the single unlinked contact holding its address. Registering with someone else's
address gave control of their subscriptions, including resubscribing them.
Only a confirmed address links now. The write also moved off the plain GET: a comment
said `handle_params/3` avoided it, but that runs on the GET too.

### 6. BUG - HIGH — "Unsubscribed from all" covered one row — FIXED

An import always creates a new contact, so one person can be several rows, and each
list's send reads its own row. An opt-out now reaches every contact at the address and
the account holding it. Resubscribing reverses all of that, which also fixes a role
opt-out that could never be undone while the page said "Welcome back".

### 7. BUG - HIGH — A reconnect wrote one language's text over another — FIXED

The form did not say which tab it held, so form recovery replayed the open tab's text
onto the first tab, and Save stored it there. The form now carries the language.

### 8. BUG - HIGH — `pk_link` with `Paths` doubled the prefix — FIXED

Run against the real function: `/phoenix_kit/phoenix_kit/admin/newsletters/layouts/new`,
on default settings. Four links, including New layout and every row's Edit.

### 9. BUG - HIGH — Schedule accepted a past time — FIXED

A wrong year meant an immediate send to everyone under "Broadcast saved as Scheduled".
It is refused now, and the preview shows the date, where it showed only the time.

### 10. IMPROVEMENT - HIGH — A scheduled broadcast was a dead end — FIXED

A typo in Friday's newsletter left only Cancel, which is final and did not say so, and
the details page never showed the body. There is now a row-judged **Back to draft**,
the dialog says what cancelling means, and the page shows the message.

### 11. IMPROVEMENT - HIGH — Database work on every keystroke — FIXED

Each Subject keystroke loaded every user in the selected roles. Subject is debounced,
the preflight runs only when the audience changes, and the details page counts roles
instead of loading users to get one integer.

## Medium

| # | Finding | Fix |
|---|---|---|
| 12 | A send to nobody ended `sent` with no retry | `Broadcaster.send/1` refuses it; a tick marks it `failed` |
| 13 | Pages over tied timestamps repeated or skipped rows | `uuid` as a tie-break, on both lists |
| 14 | Sent, Delivered and Opened meant different things on the list and details | Cumulative on both; details counts rows; Pending tile added |
| 15 | Retry and Resend offered where the backend always refuses | One `can_start` assign, the same checks as the click |
| 16 | Save draft dropped a typed time; Manage layouts lost unsaved work | Draft keeps the time; link opens a new tab |
| 17 | "1 members", raw statuses in translated flashes, English starter HTML | `ngettext`, `Web.StatusLabel`, `gettext` |
| 18 | Results redirected to `/`, which may not exist under a prefix | Rendered on the page; a public page never redirects home |
| 19 | One-click GET was a public 500 on `?token[a]=b` and `?token=%5C` | Guarded and encoded |
| 20 | A crafted `crm_list_uuid` could target an operational segment | Only offered lists, or the draft's own |
| 21 | Opt-out overwrote other custom fields under a race | `merge_user_custom_fields/3` |
| 22 | Late provider events walked a status backwards | `Delivery.next_status/2`, timestamps still kept |
| 23 | Two accounts sharing a delivery address got two copies | Deduplicated by address too |
| 24 | A stray `source_type` raised on every tick | Refused as an empty audience, so it fails once |
| 25 | `{{name}}` printed a CRM recipient's address | Contact's name; a user's full name |
| 26 | `{{subject}}` stayed literal in the text part | Bound there too |
| 27 | Recipient placeholders stayed literal in a host's footer file | Passed through core's `:branding` |
| 28 | Any rate above one per second collapsed to one per second | Fractional interval |
| 29 | Three membership lookups per CRM delivery | One, plus a status-only recheck |
| 30 | Task lists lost their checked state | `tasklist` off, so `[x]` survives as text |
| 31 | Permission labels could not be translated | `gettext_backend:` and `gettext_noop` |
| 32 | No `oban_queues/0` or `reserved_route_prefixes/0` | Both declared; core's fallback says modules should |
| 33 | README's install steps never created the tables | Steps added; Emails explained |
| 34 | `?status[]=x` raised on the list | Only a real status is used |

## Verification

- **Against the real thing where reading was not enough:** `Routes.path/1` run twice for
  #8; multilingual mode switched on for #3, with each link checked against a router built
  from `Web.Routes.generate/1`; `Phoenix.Token` raising on core's unstarted endpoint for #1.
- **Mutation check:** 53 changes, each undoing one fix, all caught in the end. The first
  pass let 3 through, and each exposed a test that proved less than it looked: nothing
  checked the unsubscribe page reaching the account, a branding test passed because the
  default colour equals the site's, and a status test sent nothing at all, because the
  dead-render endpoint ignores query strings.
- **Tests caught a bug in these fixes:** a `not` on a nil scope would have been a 500 for
  every logged-out visitor to the preference page.
- **Real connections:** the race harness from the resend work, rerun on the final code:
  sweep against a 3,000-row resend, concurrent resends, a whole resend on 8 workers, resends
  hammered while workers finish, and 50,000 rows reopened in 2.4 s.

## Behaviour that changed

- Unsubscribe links no longer expire, and preference links last 30 days.
- An opt-out from everything covers every contact at the address and the account holding it.
- An unconfirmed account sees a message on the preference page instead of its subscriptions.
- A send to nobody, or with a blank body, is refused. A scheduled one ends `failed`, where it
  used to end `sent`.
- A past schedule time is refused, and a scheduled broadcast can go back to draft.
- `{{name}}` is a person's name, no longer their address or login.
- The details page's Sent, Delivered and Opened are cumulative.
- Unsubscribe results render on the page, with no redirect to `/`.
- A list the picker does not offer can no longer be chosen, except the one a draft already has.
- A profile's rate above one per second is honoured.

## Left open

These need a decision or a change elsewhere, so nothing was done.

- **`phoenix_kit_emails` counts every event.** It increments after every provider event,
  so a recipient opening a mail five times adds five to `opened_count`, and the list can
  show Opened above Sent. The row can no longer walk backwards, but only that package can
  stop the count: it has to increment only when a row moved.
- **A broadcast with no layout has no visible unsubscribe link** unless its author wrote
  one. `List-Unsubscribe` is set, but core's footer has no link in the body, which matters
  for CAN-SPAM. Appending one is a product decision.
- **Disabling the module does not stop a running send**, and it removes the page with
  Cancel on it. Whether it should stop is a product decision.
- **A base-key user can change mail about to go out** by editing the layout of a scheduled
  or running broadcast, and can browse the whole Storage library through the attachment
  picker. Both are permission design.
- **A re-import after an opt-out** creates a new contact that is not opted out. Reading the
  opt-out by address at send time would cover it, at the cost of a query per delivery on an
  unindexed column; the CRM's import is the better place.
- **Opting out one of two accounts that share an address** leaves the other subscribed.
  Deduplication picks one of them, so a later send can still reach that inbox.
- **An `exit` in the after-send hook retries a send the provider took**, because core guards
  the hook with `rescue` only. The fix belongs in core.
- **Core's floor stays at 2.65.0.** Raising it would remove the `delivery_email` guard.
- The new Estonian and Russian strings have had no native review.

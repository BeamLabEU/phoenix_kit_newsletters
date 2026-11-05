# Module audit — 2026-11-05

**Reviewer:** Claude (claude-opus-5-5), with two independent read-only audits of
the sending pipeline and of rendering/admin UI.
**Baseline:** `c9ce938`, plus the V3 reorder and unsubscribe translation.

Every finding below has been fixed; **Resolution** at the end says how, what was
measured, and what was left. Findings keep their original text as a record of what
was found. Migrations, verification and the unsubscribe pages were reviewed
separately and are not repeated here.

**Evidence** says how each finding was checked:

- **Reproduced:** run against the real code and a real database, with the result
  shown. For #1 the interleaving was stepped by hand, not raced.
- **Read:** traced through the code, including core and CRM, but not executed.

## High priority

### 1. BUG - CRITICAL — A broadcast can end `sent` with nobody mailed

**Reproduced.** `do_send/1` commits `status: "sending"`, then resolves recipients,
then inserts deliveries and jobs in a later transaction. The sweep marks any
`sending` broadcast with no pending delivery as `sent`, and core runs it every
minute. A tick landing in that gap, or anything raising in the transaction, loses
the broadcast:

```
repair_stuck_sending_broadcasts() -> 1
broadcast                         -> "sent"
DeliveryWorker.perform            -> :ok, 0 mails, delivery still "pending"
Broadcaster.send (retry)          -> {:error, {:invalid_status, "sent"}}
```

No error is shown and it cannot be retried. The window grows with audience size,
since it spans recipient resolution and every insert.

**Fix:** resolve recipients first, then flip the status inside the enqueue
transaction, so status and rows appear together and a crash restores the old
status. Do it with #4's compare-and-swap. Give the transaction an explicit
`timeout:`, because the 15 s default caps the whole transaction.

### 2. BUG - HIGH — Opt-outs after enqueue are not honoured at send time

**Reproduced** for a contact-level opt-out and a deactivated user; each still got
the mail. The worker never rechecks eligibility, and a throttled broadcast runs for
hours or days after enqueue. A deleted contact also gets the mail, with no
List-Unsubscribe header and an empty link (`{"", nil}`, read). This one has legal
weight.

**Fix:** recheck beside the existing status guard and record `blocked` with no
counter, so the broadcast still finalizes. Decision needed:
`delivery_worker_test.exs:612,708` pin "no member still sends". Separately,
`sendable_query/1` has no contact-status filter, so trashed contacts stay sendable
(read); AGENTS.md's filter does not exclude them, so whether it should is yours to
decide.

### 3. BUG - HIGH — Placeholders in Markdown links are dead in every email

**Reproduced.** comrak percent-encodes braces in link targets, so substitution never
sees them:

```
[Unsubscribe]({{unsubscribe_url}})  ->  <a href="%7B%7Bunsubscribe_url%7D%7D">
![x]({{logo_url}})                  ->  <img src="%7B%7Blogo_url%7D%7D">
```

Plain text (`Hello {{name}}`) is fine, and so is a raw `<a href="{{...}}">`, which is
all the tests use. The body is Markdown, so this is the natural way to write an
unsubscribe link. `List-Unsubscribe` headers are unaffected.

**Fix:** after sanitizing, restore `%7B%7B...%7D%7D` in `href`/`src` to `{{...}}`.
Test through `render_markdown |> Render.html`.

### 4. BUG - HIGH — The editor rewrites and revives broadcasts that are not drafts

**Reproduced.** Only the Edit link checks for `draft`:

```
Save draft on sending/scheduled/sent/cancelled -> {"draft", "EDITED"}
Send now on sent                               -> "sending", subject "AGAIN"
stale tab, Send now on cancelled               -> "sending"
```

Save draft needs only the base key, so it is a cancel without `newsletters.send`,
and it rewrites sent history. Workers then skip, and pending rows have no jobs left,
because a later send's `on_conflict: :nothing` drops them. `retry_send` already
reloads the row for this reason; the editor does not.

Cancel has the same gap (read): it writes from the stale struct, so a late click
turns `sent` into `cancelled`, and a crafted `show_confirm` works on any status.
`scheduled` has **no** Cancel button, so hand-typing `/edit` is the only way to stop
one today.

**Fix:** redirect from `/edit` unless `draft`; re-read in both save paths; make the
flip to `sending` conditional on the database status (with #1); re-read in Cancel,
allow only `scheduled`/`sending`, and show the button for both. Add the scheduled
Cancel in the same change, or that escape hatch disappears.

### 5. BUG - HIGH — Attachments are invisible to core's orphan check

**Confirmed absent; the deletion itself was not run.** `file_references/0` does not
exist here (`function_exported?` is false) and `storage.ex` never mentions
newsletters, although the `mix.exs` comment says the module implements it. "Delete
all orphaned" or `mix phoenix_kit.cleanup_orphaned_files` can trash an attached
file, and the worker then warns and sends the mail without it.

**Fix:** implement the callback over `attachments`. Note core's rule: supplying a
list takes over the tables this module owns.

### 6. BUG - HIGH — Core's fixed ids strand a broadcast in `sending`

**Reproduced** with two `.invalid` users in one audience:

```
d1 -> {"sent", "no-deliverable-recipients"}
d2 -> {"pending", nil}, job returned :ok
broadcast -> "sending" for good; sweep repairs 0
```

Core answers suppressed mail with a constant id, `message_id` is unique across all
broadcasts, and `perform/1` drops the failed result. Production needs managed
organizations or service users in the audience. Dev hits it on every delivery after
the first, with the Local adapter and mailbox off. The first row also claims `sent`
for mail nobody received.

**Fix:** treat `suppressed: true` as no id and record `blocked`. In `perform/1`,
handle `{:error, _}` by retrying the write with `message_id: nil`, never by retrying
the job, which would re-send.

## Medium priority

| # | Finding | Evidence | Fix |
|---|---|---|---|
| 7 | `guard_unsent/1` blocks only `"sent"`, so a job re-run on a `delivered`, `opened` or `bounced` row re-sends and regresses it. Needs a crash racing the ack | Reproduced | Proceed only on `"pending"` |
| 8 | A raise on the last attempt, or a job discarded or cancelled, leaves the delivery `pending` and the broadcast stuck | Read | `rescue` in `perform/1`, record the terminal failure, reraise |
| 9 | About 36 s between first and last attempt (no `backoff/1`), so a short provider outage fails everyone reached, with no resend path. `permanent_failure?/1` also misses 8 reasons core documents, so bad SMTP config counts every recipient as a bounce | Read | `backoff/1` in minutes; add the clauses |
| 10 | The finalize check scans every pending delivery in the database, once per delivery, under the broadcast row lock: O(N²). A cancelled broadcast's pending rows raise the cost forever | Read, not measured | Scope to `^broadcast_uuid` with `not exists` |
| 11 | Role sends use `.email`, not core's `User.delivery_email/1`, so a managed organization's real `contact_email` never gets mail, while preflight counts it as sendable | Read | Resolve through `delivery_email/1`; reject `.invalid` in `sendable?/2` |
| 12 | `phoenix_kit_emails` calls `increment_broadcast_counter/2`, which does not exist, so the call is skipped and `delivered_count`/`opened_count` stay 0 on the index. With the queue on, a queue ref is stored as `message_id`, so provider ids never match | Read | Add the function; pass `skip_queue: true` |
| 13 | The text part leaks entities (`AT&amp;T`, `1 &lt; 2`) and drops every link URL, including unsubscribe | Reproduced | `text (url)` before stripping; decode entities |
| 14 | `{{site_name}}` in a subject pattern reaches the Subject header literally, and body chrome variables resolve only on the layout path | Reproduced (subject) | Bind them everywhere, or document layout-only |
| 15 | Silent 50-row caps: older broadcasts are unreachable, and details shows 50 deliveries beside "5000 recipients" | Read | Paging, or a filter and a "showing 50 of N" notice |
| 16 | A failed Send now keeps the new draft out of assigns, so each retry inserts another, and drafts have no delete UI | Reproduced: 3 clicks, 3 drafts | `assign(:broadcast, broadcast)` in that branch |
| 17 | The validation flash is raw: `%{count}` uninterpolated, atom field names, English under every locale | Read | Reuse LayoutEditor's `translate_error/1` |

## Small

- **Stale docs:** README says PhoenixKit `~> 2.52` and "2 tables" that core still
  creates; the `mix.exs` comment claims `file_references/0`; `newsletters.ex:5` says
  "newsletter list management".
- **README removal SQL omits `phoenix_kit_newsletters_layouts`,** so a manual
  uninstall leaves it behind.
- **Crafted input only:** `/broadcasts/garbage` raises `CastError`, and a non-UUID
  `role_uuids[]` saves, then crashes that broadcast's pages.
- **SMTP error text can carry recipient addresses** into logs and `delivery.error`.
  AGENTS.md requires masking only for verification.

## Checked and not a problem

- **`required_modules/0` returning `["emails"]`:** a log line and a badge only, and
  it blocks nothing. It also has a point, since that package feeds delivered, opened
  and bounced back. Without it, sending works but those stats stay still.
- **The `:warn` deprecation in test output:** `ecto_sql` logging V3's `RAISE WARNING`.
- **Sound, from the audits:** token salts and claims, substitution escaping,
  sanitizer on both body paths, sandboxed previews, permission checks before saving,
  throttle arithmetic, `on_conflict` idempotency, `AttachmentCache`, Oban args.

## Suggested order

1. **#1 with #4:** they share the send transaction and the compare-and-swap.
2. **#2, #6, #7, #8:** one pass through the worker's guards and failure handling.
3. **#3, #5:** independent, small and high value.
4. **#9 to #17** as appetite allows.

## Resolution

All fixed in the order above. The two product decisions: a recipient who is no longer
eligible at send time is recorded as `blocked`, and trashed contacts are excluded.

| # | Fix |
|---|---|
| 1 | Recipients resolve first, then one transaction locks the row, flips it and inserts every delivery and job, with an explicit timeout. A raise restores the old status. The scheduled tick rescues per broadcast, so a send that now fails cleanly cannot stop the ones due after it |
| 2 | `guard_recipient_sendable/2`, last before the provider call, asks the same query that resolved the audience (`sendable_recipient?/2`). Trashed contacts are out of `sendable_query/1` and counted as unsendable in preflight |
| 3 | `Content` restores whole placeholders in `href`/`src` after sanitizing, including inside a longer address |
| 4 | `update_draft/2` and `Broadcaster.send/1` lock and judge the row; `cancel_broadcast/1` is one conditional UPDATE; `/edit` redirects unless draft; `scheduled` has a Cancel button |
| 5 | `file_references/0` over `attachments`, expanded as core does for its JSONB lists |
| 6 | `suppressed: true` records `blocked` with no id. A rejected id is dropped and only the write retried. Nothing after provider acceptance can fail the job (`record_accepted/3`) |
| 7 | `guard_unsent/1` proceeds only on `pending` |
| 8 | A raise on the last attempt records `failed` with no counter, then re-raises. The sweep fails `pending` rows of a broadcast with no incomplete job left, which covers a killed node and a job cancelled by hand, and heals broadcasts already stranded by #6 |
| 9 | `backoff/1`: 5 then 30 minutes. The 8 documented permanent reasons added, plus `:delivery_not_found` |
| 10 | The finish check asks about its own broadcast with `not exists` |
| 11 | Role sends go through `delivery_address/1`; `.invalid` counts as no address; the details page shows the same address. Guarded, because `User.delivery_email/1` only exists from core 3.3 and the floor is 2.65 |
| 12 | `increment_broadcast_counter/2` added, and `skip_queue: true` on both send paths. **Worse than filed:** the queue re-sends through the default integration, so a queued mail also left its send profile |
| 13 | `strip_html/1` keeps link addresses and decodes entities in one pass |
| 14 | `Render.site_variables/0`, bound in the worker and both previews; `{{subject}}` works in a body without a layout |
| 15 | Paging on the broadcast list and the deliveries list (`Web.Paging`, core's components) |
| 16 | The refused draft stays in assigns |
| 17 | `Web.FormErrors`, shared with the layout editor: field labels, bindings filled in, Ecto's messages translated |
| Small | README and moduledoc corrected, including two stale claims not listed above (core's V135 creating the tables, the table count); layouts added to the removal SQL; `CastError` and crafted `role_uuids[]` handled; addresses masked in logs, `delivery.error` and Oban's errors |

### Verification

**#1 in a real race.** Real pooled connections, no sandbox, the sweep in a tight loop
against a 3,000-recipient send, on the old commit and on this code:

| | Old | New |
|---|---|---|
| Sweep racing a send, 5 runs | 5 lost: `sent`, 3,000 stranded, retry refused, send reported `:ok` | 5 intact: `sending`, 3,000 pending, 3,000 jobs |
| 4 concurrent sends of one draft, 3 runs | all 4 reported success | 1 succeeded, 3 refused, no duplicate jobs |
| 400 sends on 8 workers, sweep running | finished | finished: `sent`, 400 counted, 0 pending, sweep repaired 0 |

**#10 measured** with an active 50,000-recipient send beside a cancelled broadcast's
100,000 `pending` rows, median of 7:

| Point in the send | Old | New |
|---|---|---|
| All pending | 30.3 ms | 1.1 ms |
| 11,111 pending | 29.0 ms | 1.2 ms |
| Last delivery | 28.5 ms | 2.2 ms |

**Mutation check.** Each fix was reverted in turn to see whether a test noticed: 22
mutations, all caught in the end. The first pass exposed two real gaps, now covered by
end-to-end tests: nothing proved the worker passes the site's variables (#14), and
`skip_queue` was tested on the legacy path only, not the send-profile path where
queueing does the harm.

### Behaviour that changed

- A `scheduled` broadcast can no longer be edited, only cancelled, and a cancelled one
  cannot be brought back. There was no Edit link for it before; only a hand-typed URL.
- Leaving the audience's role after enqueue now blocks the mail, like leaving a list.
  So does uninstalling CRM mid-send, since consent can no longer be read.
- A broadcast with a failing recipient now stays `sending` for up to about 35 minutes
  while retries run, rather than about 36 seconds.
- A misconfigured connection now records `failed` with no bounce, for every recipient.

### Left open

- **No resend after a bad connection.** Permanent failures fail each recipient quickly
  and the broadcast ends `sent`, so an operator who fixes the connection cannot resend.
  This predates the audit, and it is the most useful next step.
- **The finish check still walks the broadcast's index near the end** of a send: cheap,
  as measured, but not constant. A `(broadcast_uuid, status)` index would remove that,
  and needs a V4 migration.
- **A job lost early is picked up late:** the sweep judges a broadcast only once none of
  its jobs can run, so a throttled send settles that row when its queue drains.
- **`delivery.error` shows raw terms** such as `{:blocked, :no_longer_sendable}`.
- **A placeholder in a broadcast's own subject goes out literally.** `Render` documents
  that as intended, and only a layout's subject pattern is substituted. Worth a decision.
- **A trashed contact linked to a core user does not stop role mail** to that user:
  the decision was read as being about CRM recipients, and the account is still active.
- The new Estonian and Russian strings have had no native review.

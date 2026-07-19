# FINAL-GATE Review — Block 2 of 3: emails + newsletters module deltas

Both ranges independently verified against core HEAD (`/app`, branch `feature/email-send-profiles-core`, `@version "1.7.196"`, latest published tag `v1.7.193`). No file writes performed.

---

## Repo 1: `phoenix_kit_emails` — range `bd8981b~1..HEAD`

### Stage 1: Spec Compliance

**[671b4dd verified] Gettext backend fix — PASS.**
Both sections declare the module backend:
- `lib/phoenix_kit/modules/emails/web/settings_sections/amazon_ses_sqs.ex:13` — `use Gettext, backend: PhoenixKit.Modules.Emails.Gettext`
- `lib/phoenix_kit/modules/emails/web/settings_sections/email_tracking.ex:12` — same

Backend exists at `lib/phoenix_kit/modules/emails/gettext.ex`. Pattern matches every other emails LiveView (queue/details/blocklist/emails/metrics/templates/template_editor/email_tracking — 9 modules, all identical line). Strings resolve: spot-checked `"SQS polling enabled"`→ et `"SQS küsitlus lubatud"` / ru `"Опрос SQS включён"`; `"Email body saving enabled"`, `"S3 archival enabled"` all present in both `priv/gettext/{et,ru}/LC_MESSAGES/default.po`. README URL repointed at `README.md:136`.

**[A5 convergence] PASS.**
- `settings_tabs` → `[]` (`emails.ex:918`); old `admin_settings_emails` tab deleted.
- Monolith deleted: `web/settings.ex` (-1063) + `settings.html.heex` (-1071).
- New `email_settings_sections/0` (`emails.ex:924`) contributes two section maps with keys `id`/`title`/`permission`/`component` — **exact match** for core's `email_settings_section` type (`/app/lib/phoenix_kit/module.ex:417-426`) and core's render site (`phoenix_kit_web/live/settings/email_sending.html.heex:181-185` reads `.title`/`.component`/`.id`; `email_sending.ex:203` filters on `.permission`).
- `paths.ex:15`, `metrics.html.heex:20,25,32`, error string `emails.ex:370` all repointed to `/admin/settings/email-sending`.

**[Residual refs] PASS.** Zero references to deleted `Emails.Web.Settings` module or old route `/admin/settings/emails` in code, tests, or docs (grep across `lib test docs README.md CHANGELOG.md`).

**[handle_event parity] PASS.** Old monolith had 20 `handle_event`s; the two sections carry 17 (8 SES/SQS + 9 tracking). The 3 absent are intentional and leave **zero orphaned references** in the new HEEX:
- `save_sender_settings` → sender identity moved to core (per `emails.ex:922` comment); no `<form phx-submit="save_sender_settings">` remains.
- `set_compress_days_focused` / `set_compress_days_changed` → old UI-state stubs (`settings.ex@bd8981b~1:366-380` just set assigns); new compress input (`email_tracking.html.heex:133`) uses a simpler `phx-blur="update_compress_days"`.

**[A5 micro-fixes] PASS.** Every `<.checkbox>` carries `name=` (b13ba21); forms have stable `id="aws-integration-picker-form"`/`"aws-settings-form"` (13c5cf4); no raw `<select>` survives (812d473).

**Spec Verdict: PASS**

### Stage 2: Code Quality

**NITPICK: `Paths.settings/0` is now an uncalled duplicate of a hardcoded path.**
**File**: `lib/phoenix_kit/modules/emails/paths.ex:15`
**Problem**: After convergence no internal caller invokes `Paths.settings/0` (grep `lib`/`test` empty). `metrics.html.heex:20,25,32` hardcodes `Routes.path("/admin/settings/email-sending")` instead. Two sources of truth for the same URL; the helper and the literals can drift.
**Suggestion**: Either have `metrics.html.heex` call `Paths.settings/0`, or drop the function if it isn't intended as public API.

**MINOR (pre-existing, not a regression): email_tracking section has no test file.**
**File**: `test/phoenix_kit/modules/emails/web/settings_sections/` (only `amazon_ses_sqs_test.exs`).
**Problem**: The renamed `settings_test.exs → amazon_ses_sqs_test.exs` (63% similarity) preserved the *one* describe block the old file had (`select_aws_integration`). The old file never tested the 9 tracking handlers either, so **no coverage was lost** — but those 9 handlers (`toggle_email_save_body`, `run_cleanup_now`, `run_s3_archival_now`, etc.) remain untested on HEAD.
**Rationale**: Flaging for awareness, not as a blocker — parity is maintained.

**MINOR (doc, pre-existing): CHANGELOG not updated for the restructuring.**
**File**: `CHANGELOG.md:11`
**Problem**: The `0.1.10` entry describes the now-**deleted** monolith ("breadcrumb reads 'Settings / Emails'"). No entry was added for the A5 convergence in this range. The CHANGELOG is untouched by `bd8981b~1..HEAD`. Historical entries are fine, but the deleted-UI reference with no compensating entry is slightly misleading.

**Quality Summary:** 0 critical, 0 major, 2 minor, 1 nitpick
**Quality Verdict: Ship**

---

## Repo 2: `phoenix_kit_newsletters` — commit `634b39c`

### Stage 1: Spec Compliance

**[Residual refs] PASS.** Zero references to deleted `Newsletters.SendProfile` / `Newsletters.ProviderOptions` / `Web.SendProfile(s)` anywhere in `lib test config` (the `PhoenixKit.Email.*` core aliases are correctly *kept*; only the local-module refs were checked and absent).

**[Re-point against core HEAD API] PASS.** Every core seam called by the package exists in core HEAD:
- `broadcast.ex:50` → `belongs_to(:send_profile, PhoenixKit.Email.SendProfile, foreign_key: :send_profile_uuid)` ✓
- `delivery_worker.ex:31-33` aliases `PhoenixKit.Email.{ProviderOptions,SendProfile,SendProfiles}` ✓
- `SendProfiles.get_send_profile/1`, `get_default_send_profile/0` — exist (`/app/lib/phoenix_kit/email/send_profiles.ex:20,39`) ✓
- `ProviderOptions.to_provider_options/2` — called with 2 args at `delivery_worker.ex:269`, matches core's `def to_provider_options(provider_kind, advanced)` (`provider_options.ex:142`) ✓
- `PhoenixKit.Mailer.deliver_via_integration(profile.integration_uuid)` via pipe → `deliver_via_integration(email, integration_uuid, opts \\ [])` (`/app/lib/phoenix_kit/mailer.ex:334`) ✓
- All `SendProfile` fields read (`provider_kind`, `from_name`, `from_email`, `reply_to`, `signature_html`, `signature_text`, `integration_uuid`, `enabled`, `advanced`) exist (`/app/lib/phoenix_kit/email/send_profile.ex:27-38`) ✓
- `resolve_send_profile/1` is `def`/`@doc false` (`delivery_worker.ex:196`) — correctly callable from `broadcaster.ex:74` ✓

**[hex-pin comment honest] PASS.** `mix.exs:57-63` claims core migration V151 + `PhoenixKit.Email.SendProfile` are unreleased as of 2026-07-15, requiring core built from `feature/email-send-profiles-core`. Verified against core:
- `PhoenixKit.Email.SendProfile` + `migrations/postgres/v151.ex`: **NOT in published `v1.7.193`** (cat-file -e fails); only in unreleased HEAD (`1.7.196`).
- Floor `~> 1.7 and >= 1.7.190` + "bump to exact hex version once core cuts a release containing V151" caveat is accurately disclosed.

**Spec Verdict: PASS**

### Stage 2: Code Quality

No issues. `resolve_send_profile/1` logic is sound and well-commented: a disabled/deleted pinned profile falls through to the default, then to the legacy single-Mailer path — an operator kill-switch never silently sends from a switched-off sender (`delivery_worker.ex:200-213`). Provider-specific `advanced` options correctly flow through `put_provider_options/2` to `Swoosh.Email.put_provider_option/3`.

**Quality Summary:** 0 critical, 0 major, 0 minor, 0 nitpick
**Quality Verdict: Ship**

---

## Cross-cutting (both ranges)

**(c) Section/page contract vs core HEAD — consistent.** Emails section maps shape = core's `email_settings_section` type exactly; core renders `.title`/`.component`/`.id` and filters `.permission`. Newsletters worker calls all resolve.

**(d) Release-coupling statements — truthful in both repos.** emails (`mix.exs:52`) needs the A4 seam (`email_settings_sections`) — verified unreleased (not in `v1.7.193`, seam commit `c746fa3a` in no tag). newsletters (`mix.exs:57`) needs V151 — verified unreleased. Each package's comment correctly identifies only what *it* needs. Named branch `feature/email-send-profiles-core` matches core's actual current branch.

**(e) AI attribution sweep — clean.** No `Claude`/`Anthropic`/`Generated with`/`Co-Authored-By: Claude`/`🤖` in either range's commit messages or added code lines.

---

## Overall Verdict: **PASS** (both repos)

| Repo | Spec | Quality | Verdict |
|------|------|---------|---------|
| `phoenix_kit_emails` | PASS | Ship (2 minor, 1 nitpick) | **PASS** |
| `phoenix_kit_newsletters` | PASS | Ship | **PASS** |

No blockers. The only actionable item is the NITPICK (`Paths.settings/0` vs hardcoded path in `metrics.html.heex`) — optional cleanup. The two MINOR observations (email_tracking test coverage, CHANGELOG) are pre-existing and out of the diff's regression scope. The GLM A5 gettext-backend regression is confirmed fixed on HEAD.

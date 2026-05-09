# PR #12 Review — Add per-module Gettext backend for sidebar tab labels

**Reviewer:** Claude
**Date:** 2026-05-09
**Author:** @timujinne (Tymofii Shapovalov)
**Status:** Merged (2026-05-09)
**Verdict:** Approve with follow-ups

> **Post-merge update (2026-05-09):** follow-ups #1 and #3 below applied in this repo. Issue #2 verified against `phoenix_kit` 1.7.106 in `mix.lock` — the "silently dropped" claim is correct (`build_tab_struct` reads named keys via `get_attr/2`, unknown attrs ignored). See [Resolution](#resolution) at the bottom.

---

## Summary

Introduces `PhoenixKit.Newsletters.Gettext` — a module-owned `Gettext.Backend` — and threads `gettext_backend: PhoenixKit.Newsletters.Gettext` through all 9 `Tab.new!/1` registrations in `lib/phoenix_kit/newsletters/newsletters.ex`. Ships `en` / `ru` / `et` catalogues under `priv/gettext/<locale>/LC_MESSAGES/default.po` plus a manually-maintained `default.pot`. Adds `priv` to `mix.exs` `package files:` so the catalogues actually reach Hex. Adds a 4-test smoke suite gated by a runtime feature-detection check in `test_helper.exs` so CI stays green against the currently-published `phoenix_kit` 1.7.105 (which lacks the consumer-side `localized_label/1` API).

This is the pilot for the per-module i18n pattern that will be rolled out across every UI-bearing `phoenix_kit_<x>` package.

---

## Elixir / OTP Lens

Reviewed against the elixir-thinking skill's iron law and idioms.

- **No new processes.** `Gettext.Backend` is a compile-time module-polymorphism construct (behavior + macros), not a process. Locale state lives in the *caller's* process dictionary keyed by backend module — that's stock Gettext, not a homegrown global. Iron law respected.
- **Module organization, not runtime organization.** The new module exists to own a translation catalogue, which is data + lookup functions. Correct shape.
- **Behavior over protocol.** `use Gettext.Backend` plugs into a behavior. Appropriate — pattern matching wouldn't suffice (catalogues are dynamic data), and protocols would be overkill.
- **Error handling.** `test_helper.exs` uses `Code.ensure_loaded?/1` and `function_exported?/3` for capability detection — explicit, not exception-driven control flow. Good.

No anti-patterns spotted on the runtime side.

---

## What Works Well

1. **Forward-compatible rollout.** Shipping the consumer-side wiring (`gettext_backend:` on every tab, full `.po` catalogues, the test suite) *before* the dependent `phoenix_kit` PR #522 lands in a Hex release is the right ordering. The `package files:` fix (catching that `priv/` was missing from the Hex bundle) is exactly the kind of regression a manually maintained `files:` allowlist invites — good catch pre-merge.

2. **Test gating via capability detection.** `function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1)` in `test_helper.exs` is the right shape. It is *runtime feature detection*, not version-string comparison, so the moment the consumer's lockfile resolves to a `phoenix_kit` release that ships the API, the suite flips from "excluded" to "running" with no follow-up edit. The `@moduletag :requires_phoenix_kit_i18n_api` makes the gate explicit at the test side, not just buried in the helper.

3. **`.pot` header documents the manual-maintenance contract.** The header note explaining that `mix gettext.extract` will *not* pick up these msgids (because they live as plain strings in `Tab.new!(label: ...)` rather than in a `dgettext` macro call) is essential context. Without it, the next contributor will run `mix gettext.extract` and watch the `.pot` get clobbered.

4. **Locale isolation in tests.** The `setup` block snapshots `Gettext.get_locale/1` and restores it via `on_exit` — correct hygiene, prevents cross-test bleed even with `async: false`.

5. **Translations are tab-domain idiomatic.** Russian "Рассылки" / "Выпуски" and Estonian "Uudiskirjad" / "Saadetised" are the conventional terms for newsletter mailings vs. individual sends; not literal translations of "Broadcasts". Reasonable editorial choice.

6. **Graceful degradation on the data path.** Even if the runtime claim about `Tab.new!` silently dropping the unknown `gettext_backend:` field on old `phoenix_kit` turns out to be wrong (see Risks below), the *worst* case is sidebar labels rendered as raw English msgids — no functional regression to broadcasts/lists/subscribers themselves.

---

## Issues and Observations

### 1. `async: false` on the i18n test module

`test/phoenix_kit/newsletters/i18n_test.exs:15` declares `use ExUnit.Case, async: false`.

`Gettext.put_locale(backend, locale)` stores the locale in the **calling process's** process dictionary, keyed by backend module — it is *already* per-process. The `setup` block's snapshot/restore is belt-and-braces but not actually load-bearing across concurrent tests, because tests in different processes can't see each other's locale puts.

The elixir-thinking skill calls this out explicitly: `async: false` means coupled to global state, and Gettext locale isn't global state. Recommend flipping to `async: true`.

**Severity:** minor — costs parallelism on a 4-test file, won't matter in practice. Worth fixing for the pattern-template value of this PR (it'll be copy-pasted into Emails, CRM, Billing, etc.).

### 2. The "silently dropped" claim depends on `Tab.new!`'s implementation

The PR description states:

> Currently published (1.7.105) | raw English (graceful — `gettext_backend:` field silently dropped by `Tab.new`) | excluded

This is true if `Tab.new!` calls `struct/2` (drops unknown keys with a warning). It is **false** if it calls `struct!/2` (raises `KeyError` on unknown keys). I can't verify against `phoenix_kit` 1.7.105 from this repo. If `struct!/2` is the path, the claim "graceful degradation on old `phoenix_kit`" is wrong, and the moment a consumer locks to 1.7.105 their newsletters tabs won't register at all.

**Action item:** confirm by either (a) booting a test app against `phoenix_kit` 1.7.105 with this branch and checking the sidebar renders, or (b) reading `PhoenixKit.Dashboard.Tab.new!/1` in the dependency. If it's `struct!/2`, this PR can't ship until PR #522 (or a successor that adds the field to the struct) is in a Hex release. Worth verifying *before* the next module's PR copies this pattern.

### 3. No drift guard between admin_tabs labels and the `.pot`

If a future contributor adds a 10th `Tab.new!` with a new label string, three things must happen in lockstep: (a) the msgid lands in `default.pot`, (b) every locale's `default.po` gets the entry via `mix gettext.merge`, (c) translators fill them in. Step (a) is easy to forget given the manual-maintenance contract.

The smoke test won't catch a drift: a missing msgid just falls back to the raw English string, which is the exact same string the current ru/et test would *not* be asserting against (the tests only check the parent `:admin_newsletters` tab, not all 9). So drift is silent.

**Cheap mitigation:** extend the wiring test to assert *every* tab's label has at least one non-identity translation in ru or et. Fails loudly when a new tab is added without a translation, points the contributor at exactly the right files.

```elixir
test "every tab label has a non-en translation" do
  Gettext.put_locale(NewslettersGettext, "ru")

  for tab <- Newsletters.admin_tabs() do
    translated = Tab.localized_label(tab)
    assert translated != tab.label,
           "Tab #{inspect(tab.id)} label #{inspect(tab.label)} has no ru translation"
  end
end
```

Skip if the team prefers to catch drift at translator-handoff time instead — but the test is one screen of code and runs in milliseconds.

### 4. Smoke test only exercises the parent tab

The 3 locale-specific tests all pull `Enum.find(..., &(&1.id == :admin_newsletters))` and check one msgid (`"Newsletters"`). It validates the *wiring* but not the catalogue completeness for the other 8 msgids. Issue #3's mitigation would solve this too.

### 5. Minor: pattern-match-friendly test style

Per the elixir-thinking skill's "Prefer pattern matching over imperative assertions": the wiring assertion in the `for` loop uses `==`. For string equality on a known value, `==` is fine; not worth changing. Mentioning only because the skill flags this and a reviewer auto-loading the same skill might flag it too — and it's not a real defect here.

---

## Risks

- **Forward-compat trapdoor (#2).** The whole "graceful on old `phoenix_kit`" story rests on `Tab.new!`'s tolerance for unknown keys. Worth a 30-second verification.
- **Catalogue drift (#3).** Manual `.pot` maintenance + no drift test = silent fallback to English when contributors forget. Mitigation is cheap.
- **`{:gettext, "~> 1.0"}` is now a hard dep.** Consumers that pin an older `gettext` will get a resolver conflict. Gettext 1.0 ships with reasonably modern Elixir, so unlikely to bite, but flag if you've seen consumers pinning `~> 0.20`.

---

## Verdict

**Approve.** The architecture is sound, the rollout sequencing is conservative, and the test-gating strategy lets this ship ahead of `phoenix_kit` PR #522 without breaking CI. The issues raised are small enough not to block the merge — but **before applying this same pattern to Emails / CRM / Billing / etc.**, validate the `Tab.new!` "silently dropped" claim (#2) and consider adding the drift-guard test (#3) into the template. This PR is going to be copy-pasted six more times; tighten it once here and every downstream PR gets the benefit.

### Suggested follow-ups (non-blocking)

- [x] Verify `PhoenixKit.Dashboard.Tab.new!/1` tolerates unknown keys on older `phoenix_kit`.
- [x] Flip `async: false` → `async: true` in `i18n_test.exs`.
- [x] Add a "every tab label has a non-en translation" drift test.
- [x] Remove the `function_exported?` gate from `test_helper.exs` now that `phoenix_kit` 1.7.106 with the API is published. Constraint stays `~> 1.7`; consumers are expected to keep `phoenix_kit` up-to-date.

---

## Resolution

Applied in this repo, post-merge:

| # | Status | Files |
|---|--------|-------|
| #1 `async: false` → `async: true` | done | `test/phoenix_kit/newsletters/i18n_test.exs:15` |
| #2 verify `Tab.new!` graceful drop | verified | `deps/phoenix_kit/lib/phoenix_kit/dashboard/tab.ex:238-279` — `build_tab_struct` reads named keys via `get_attr/2`. Unknown attrs are simply not read. ✓ Old phoenix_kit (without `gettext_backend` in struct definition) would not crash, just ignore the field. |
| #3 drift-guard test | done | `test/phoenix_kit/newsletters/i18n_test.exs:45-57` — iterates every tab, asserts ru translation differs from msgid. |
| #4 remove gate | done | `test/test_helper.exs` simplified to one line; `@moduletag :requires_phoenix_kit_i18n_api` removed from `i18n_test.exs`. `mix.exs` constraint stays `~> 1.7` (deliberate — `~> 1.7.106` would cap upper bound at `< 1.8.0` and block future minors; consumers are expected to upgrade `phoenix_kit` to a release ≥ 1.7.106 themselves). |

Verification:

```
$ mix test
47 tests, 0 failures (2.5s async)
```

If a consumer's lockfile resolves `phoenix_kit` to a release < 1.7.106, the i18n tests will raise `UndefinedFunctionError` on `Tab.localized_label/1` — that's the intended signal to run `mix deps.update phoenix_kit`.

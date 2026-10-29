# PR #42 — Host-configured verification engine

Reviewed by Codex on 2026-10-29.
Author: Tymofii Shapovalov.
PR: https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/42
Merged commit: `1b34b53`; review baseline: `bf006e2`.

## Findings

### BUG - MEDIUM — An open page can start a disabled engine

The start event trusts the `:ready` assign captured at mount. An operator
can switch the engine off while the page is open, and the page still calls
`start_batch/4`. The behaviour does not require the engine to repeat this
check. Removing the configured engine also leaves the page showing stale
readiness after a failed start.

The event now rechecks availability and enabled state before resolving the
audience or starting work. It updates the engine assign and shows the
existing disabled/unavailable message. A regression test changes the engine
configuration after visiting the page and checks that no batch call occurs.

### BUG - MEDIUM — Delayed progress can reopen a terminal batch

The new contract explicitly allows out-of-order worker messages. The page
only rejected a lower processed count, so a delayed `running` snapshot with
an equal count could overwrite `done` or `cancelled`. It hid completion and
disabled the start button; after the runner timer stopped, the page could
remain stuck in that state.

Once the current batch is terminal, further snapshots for that UUID are
ignored. Regression coverage checks both terminal states against delayed
active snapshots with equal and greater counts. New batches have distinct
UUIDs and still follow the existing subscription path.

### IMPROVEMENT - MEDIUM — Pure bridge coverage requires PostgreSQL

`EmailVerificationTest` uses `DataCase`, which tags every test as
`:integration`, although all its engines are local scripted modules and
none of its assertions need a database. Thus the configuration, optional
callback, failure and settings-path coverage disappears without PostgreSQL.

It now uses `ExUnit.Case` with `async: false`, retaining isolation for the
application configuration it changes. All 27 bridge tests pass with
integration tests excluded.

## Other checks

Checked the callback signatures against an existing engine implementation,
the fake's behaviour declaration, optional callback fallbacks, safe settings
paths, address masking, and unavailable/disabled dead rendering. No required
callback, dependency on an engine package, or default engine was introduced.
The referenced `elixir:*` thinking skills are not installed in this workspace;
the review followed the repository conventions directly.

The lifecycle issues above predate extraction of the behaviour; they were
found by checking the page against the contract #42 now publishes.

Validation and resolution are recorded in [FOLLOW_UP.md](FOLLOW_UP.md).

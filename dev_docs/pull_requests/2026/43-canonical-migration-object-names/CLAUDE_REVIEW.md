# Code Review: PR #43 — Rename the objects a pre-rename host kept under old names (chain V3)

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/43
**Author:** Tymofii Shapovalov
**Status:** Merged (bf006e2); not in any release tag yet

## Summary

V3 renames primary keys, foreign keys and indexes a pre-rename host kept under
their `mailing` names, so core's name-keyed manifest stops reporting them missing.
It creates, drops and rewrites nothing. Codex's review and follow-up are in this
directory, and its two primary-key findings are fixed; this review looked for
anything further.

## Verification performed

- **The rename list matches V1.** `@v3_indexes` and `@v3_fks` agree with V1's and
  V2's guard calls entry by entry, and `migrations_test.exs` pins them against the
  manifest.
- **The catalog queries hold on real types.** `varchar_ops` is a non-default
  opclass, but an index on a `varchar` column gets `text_ops`, so the
  `NOT opc.opcdefault` check does not reject the real `status` and `message_id`
  indexes. `migrations_legacy_names_test.exs` renames them in real DDL.
- **Namespaces.** A primary-key rename checks the relation and the constraint
  namespace, an index rename the relation namespace, and a foreign-key rename its
  table's constraints, which is where each name has to be unique.
- **Quoting.** The old name goes through `format(%I)`; `RAISE` placeholder counts
  match their arguments; a name containing `%` is an argument, not a format.
- **`SET lock_timeout`** is rolled back with the transaction when the migration
  fails, and `RESET` runs when it succeeds. Neither path leaks it into a pooled
  connection.
- **No manifest change needed.** V3 changes names to what the manifest already
  says, and `chain_hash/0` fingerprints objects, not migration files.

## Findings

One defect beyond the ones Codex found.

### BUG - MEDIUM — V3 and the delivery worker locked in opposite orders — FIXED

V3 took ACCESS EXCLUSIVE on broadcasts first and deliveries second.
`update_delivery_result/5` writes the delivery first and bumps the broadcast's
counter second, in one transaction. On a renamed host during a send, each could
hold what the other wanted. When the worker is the one Postgres aborts, the status
write rolls back after the provider accepted the mail, the delivery stays
`pending`, and the retry sends it again.

First filed as unreproduced and left to the quiet-window note. It has since been
reproduced with the real emitted V3 SQL against a session running the worker's
statements, on legacy-named tables:

| Order | Runs | Result |
|---|---|---|
| Broadcasts first (as merged) | 3 of 3 | `deadlock detected`; the **worker** was aborted, the delivery stayed `pending` |
| Deliveries first (fixed) | 3 of 3 | Both committed; `sent`, counter 1, all six keys renamed |

The worker lost every time, because it was the last to start waiting and so the
one whose deadlock check found the cycle.

V3 now renames every deliveries key before any broadcasts key. Swapping only the
primary keys would not do: each rename is conditional, so a host with a canonical
deliveries primary key but legacy foreign keys would still lock broadcasts first.
`migrations_test.exs` states the invariant as well as pinning the list, and the
moduledoc and AGENTS.md record the reason. V3 had not shipped, so reordering it
changes no host.

Remaining, and documented in the moduledoc: a host crossing V2 in the same
migration has already locked broadcasts, because V2 re-points its foreign key, so
this order only helps from V2 onwards. The quiet-window advice stays for that
case. `repair_stuck_sending_broadcasts/0` locks broadcasts first too, but it is a
single read-mostly statement whose failure costs one retried tick, not a duplicate.

## Validation

- Migration tests with real DDL: 75 tests, 0 failures, nothing excluded.
- Reversing `@v3_key_order` fails both the pin and the invariant test.
- `mix precommit`: passed. `mix test`: 741 tests, 0 failures, integration tests
  included, on a clean scratch database, with this and the unsubscribe work together.

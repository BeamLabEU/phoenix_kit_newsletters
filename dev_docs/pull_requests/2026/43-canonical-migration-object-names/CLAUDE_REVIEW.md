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

No defects beyond the ones Codex found.

### IMPROVEMENT - MEDIUM — V3 and the delivery worker lock in opposite orders — NOT FIXED

V3 renames the broadcasts primary key first and the deliveries one second, taking
ACCESS EXCLUSIVE in that order. `update_delivery_result/5` writes the delivery
first and then bumps the broadcast's counter, in one transaction. On a renamed
host, during a send, each can hold what the other wants, and Postgres aborts one.

If the migration loses, it fails with nothing changed and can be rerun. If the
worker loses, the status write rolls back after the provider accepted the mail, so
the delivery stays `pending` and the retry can send it again.

This comes from reading the two code paths; it has not been reproduced. It needs a
host that actually has names to rename (otherwise V3 takes no such lock) and a
broadcast sending at that moment, which the moduledoc and README already say to
avoid ("update in a quiet window"). So it was left as documented.

If that note is not enough, renaming the deliveries objects first would match the
worker's order and should remove this cycle (untested). That means changing the
statement order and its pin, which is cheap only until V3 ships.

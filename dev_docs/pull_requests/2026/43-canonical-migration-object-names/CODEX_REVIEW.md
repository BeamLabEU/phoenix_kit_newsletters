# PR #43 — Canonical migration object names

Reviewed by Codex on 2026-10-29.
Author: Tymofii Shapovalov.
PR: https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/43
Merged commit and review baseline: `bf006e2`.

## Findings

### BUG - MEDIUM — A primary-key name collision can abort V3

`rename_pkey/3` checks the relation namespace for the destination name,
because renaming a primary key also renames its index. A CHECK or foreign-key
constraint on the same table can hold that name without a relation of the
same name. The check misses it and `RENAME CONSTRAINT` fails with PostgreSQL
`42710`, aborting the upgrade instead of warning and preserving the objects.

The destination check now consults both the relation namespace and the
table's constraint namespace. A real-DDL regression creates a CHECK with the
canonical primary-key name and verifies that V3 warns, retains the original
primary key and reaches marker 3.

### BUG - MEDIUM — A different primary key gets the manifest's name

V3 identifies a primary key solely by table and constraint type. The manifest
also requires its column list to be exactly `[uuid]`. A host's composite
primary key therefore gets renamed to a canonical name despite having a
different shape, contrary to the conservative matching used for indexes and
foreign keys.

The candidate query now compares the complete `conkey` to the UUID column.
A regression replaces the deliveries primary key with `(uuid,
broadcast_uuid)` and verifies that it keeps its name. The existing manifest
conformance assertion now checks this part of the primary-key match.

### IMPROVEMENT - MEDIUM — Invalid-index coverage needs superuser access

The invalid-index test writes directly to `pg_index`. The baseline suite
failed with PostgreSQL `42501` under the ordinary database owner used here.

The fixture now produces an invalid unique index by attempting a concurrent
build over duplicate message IDs. PostgreSQL leaves that failed build in
the catalog. The fixture removes the test rows and the test verifies that
V3 leaves the invalid index unchanged. Creation runs outside the sandbox
transaction in a separate schema; the test's migration still rolls back.
No system-catalog writes or elevated privileges are required.

## Scope

V3 is not contained in a release tag at review time. Only its candidate and
collision checks changed; the published V1/V2 statement snapshots, manifest,
version number, object shapes and rollback policy are unchanged. Existing
rename/idempotence/OID-preservation and repair integration tests still apply.

The referenced `elixir:*` thinking skills are unavailable in this workspace;
catalog matching was checked against core's actual repair probe/differ and
this package's manifest.

Validation and resolution are recorded in [FOLLOW_UP.md](FOLLOW_UP.md).

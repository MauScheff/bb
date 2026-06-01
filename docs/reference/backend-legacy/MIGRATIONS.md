# Migrations

Operator and implementation guide for Turbo backend schema changes. Use it when changing any Unison type stored in Cloud, any `OrderedTable` key/value type, table name, or storage projection.

## Why this matters

Unison Cloud stores typed values directly. UCM `update` changes local code, not already-written Cloud rows. A locally valid type edit can make production rows unreadable after deploy; the usual cause is schema drift, not database corruption.

Official background:

- Unison Cloud schema migration FAQ: https://www.unison.cloud/docs/storage-schema-management/
- OrderedTable schema modeling tutorial: https://www.unison.cloud/docs/tutorials/schema-modeling/

## Rule

Never change a persisted Unison type silently. Every persisted type change requires one decision:

- `preserve`: keep existing production data and migrate it
- `reset`: intentionally delete or abandon the affected data
- `revert`: restore the type shape that can still read the current data

Updating `turbo.schemaDrift.expectedHashes` only approves that a shape changed. It is not a migration by itself.

## Schema Changes

- adding, removing, reordering, or changing fields in a type stored as an `OrderedTable` value
- changing variants of a stored sum type
- changing key types for an `OrderedTable`
- renaming or replacing a table
- changing secondary projection rows
- changing nested persisted types used inside a stored record
- changing serialization-sensitive wrapper types around IDs, statuses, or payloads

Runtime-only tables that store live refs or websockets are different. They are not ordinary portable durable values, and they are intentionally excluded from `turbo.schemaDrift`.

## Pre-change checklist

Before editing persisted type:

1. Find all table definitions that store it.
2. Find every route/store function that reads or writes those tables.
3. Find secondary projections and reset/dev-cleanup paths.
4. Decide whether current production data must be preserved.
5. If preservation matters, define the old and new representations explicitly instead of updating the old type in place.

Prefer versioned persisted types/table names when a type may evolve:

```unison
type turbo.db.v1.UserRow = UserRow Text Text
type turbo.db.v2.UserRow = UserRow Text Text Text

turbo.store.users.tables.byIdV1 db =
  OrderedTable.named db "turboUsersById_v1" Universal.ordering

turbo.store.users.tables.byIdV2 db =
  OrderedTable.named db "turboUsersById_v2" Universal.ordering
```

Do not write mixed versions of a value type into the same typed table.

## Offline migration shape

The supported simple migration shape is offline:

1. Stop or undeploy services that read/write the affected database.
2. Add a new table name for the new shape.
3. Stream rows from the old table with `OrderedTable.toStream`.
4. Convert old rows into the new value type.
5. Write converted rows into the new table with `OrderedTable.write`.
6. Deploy code that reads the new table.
7. Keep cleanup explicit: delete old rows by streaming keys and calling `OrderedTable.delete`, or reset the whole database with `Database.delete` only when that is the intended blast radius.

Unison Cloud does not currently support a general zero-downtime typed schema migration path. For Turbo, plan schema changes as explicit maintenance or dev-only resets unless we have designed a narrower online protocol for that specific table.

## Turbo deploy guard

Turbo has a lightweight drift guard in the Unison codebase:

- `turbo.schemaDrift.currentHashes`
- `turbo.schemaDrift.expectedHashes`
- `turbo.schemaDrift.currentDeserializeChecks`
- `turbo.schemaDrift.check`
- `turbo.schemaDrift.tests.persistedValueShapesAreStable`

`just deploy` depends on `just backend-schema-drift-test`, which runs:

```bash
direnv exec . ucm run bb/main:.turbo.schemaDrift.check
```

If this fails:

1. Do not bypass deploy protection.
2. Inspect which stored value hash changed.
3. Decide `preserve`, `reset`, or `revert`.
4. Implement and prove the migration/reset path.
5. Update `turbo.schemaDrift.expectedHashes` only in the same reviewed change that documents the decision.

When adding a new persisted value type, add a representative fixture to `turbo.schemaDrift` and include it in the expected hash and deserialize checks.

## Emergency recovery

If production is already wedged because deployed code cannot deserialize old rows:

1. Re-deploy code that restores the old readable type shape, if possible.
2. Use that code to migrate, export, or intentionally delete the affected rows.
3. Deploy the new schema only after the data path is clean.
4. Rotate or delete the whole environment/database only when the data is disposable or the narrower recovery path is impossible.

Environment/database rotation fixes availability by abandoning the unreadable data. It does not explain or repair the schema drift, so it should leave behind a follow-up to add a fixture, migration, or reset path.

Before rotating because the hosted backend "feels flaky", distinguish schema/storage failure from transport or simulator-lane instability:

- run a raw hosted probe such as `just route-probe` or `just backend-stability-probe`
- if those probes fail across the same hosted base URL, environment rotation may be a reasonable disposable-env recovery
- if raw hosted probes pass but hosted simulator scenarios are timing out with `NSURLErrorDomain -1001/-1005`, treat that as app/transport/test-lane instability, not proof of schema drift

Never make environment/database rotation an automatic production response. It is an operator decision for disposable environments, staging/dev recovery, or an explicitly approved emergency action.

## Definition of done

A backend schema change is not done until:

- table names/types are versioned or intentionally unchanged
- migrations or resets are explicit
- dev reset/cleanup paths are updated
- `turbo.schemaDrift` fixtures and expected hashes reflect the approved persisted shapes
- `turbo.schemaDrift.tests.persistedValueShapesAreStable` passes
- `turbo.schemaDrift.check` passes
- affected route/probe/scenario tests pass
- the deploy notes say whether the change was `preserve`, `reset`, or `revert`

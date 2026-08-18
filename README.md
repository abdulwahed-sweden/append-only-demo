# Your audit log is a table your application can edit.

An amount is posted. Someone corrects it. The correction is applied in place, the
original value is gone, and the audit log that was supposed to record what happened
can be rewritten by the same database user that wrote the entry.

Nobody can prove what the record said yesterday.

**This is a synthetic demonstration of a general data-integrity failure class**, not
anyone's production system and not a copy of one. Made-up ledger, made-up entry, two
schemas in one throwaway database.

## Run it

```sh
./demo.sh              # the failure and the repair, side by side
./test.sh              # the rule, asserted — 8 of 8 pass
./test.sh --no-guard   # the same schema without the two grants — stops at the first failure
```

Needs a Postgres. The scripts use a local one if they find it, honour `DATABASE_URL`
if you set one, and otherwise start one in Docker (`docker-compose.yml` included).
With a Postgres already running it takes about a second.

## What you just saw

**The ordinary design** (`broken` schema). One database user with full rights over
everything, which is how nearly every deployment is configured. A correction is an
`UPDATE`. The previous amount is not stored anywhere, so it is not recoverable — and
the audit log is just another table that same user can `UPDATE` and `DELETE`. The demo
erases it in one statement.

**The same ledger, append-only** (`safe` schema). A correction inserts version 2 with a
reason. Version 1 is still there, still saying 480.00, still naming who recorded it.
The application reads `entries_current`, which is the newest version of each entry.

Then the demo tries to rewrite version 1 as the application, and Postgres refuses:

```
UPDATE safe.entries SET amount = 0  ->  permission denied for table entries
DELETE FROM safe.entries            ->  permission denied for table entries
```

## The repair

Two lines, in [`schema.sql`](schema.sql):

```sql
GRANT SELECT, INSERT ON safe.entries TO app_user;
REVOKE UPDATE, DELETE, TRUNCATE ON safe.entries FROM app_user;
```

Not a convention, not a code review item, not an ORM setting. The role the application
connects as does not hold the right to rewrite a recorded entry, so a bug, a bad deploy
or a careless console session cannot do it either.

`./test.sh --no-guard` grants those two rights back and changes nothing else — same
schema, same versioning, same application code. Two assertions immediately fail. That is
what tells you where the rule actually lives.

## The trap

The table **owner** is not subject to its own grants. Assertion 7 proves it: connected as
the owner, the same `UPDATE` succeeds. Everything above is undone by a deployment that
connects to Postgres as the user that owns the tables — which is the default in most
setups, and the reason people believe they have this protection when they do not.

## Checking your own system

The obvious check is to read `information_schema.role_table_grants` filtered on
`grantee = current_user`. Assertion 8 shows why that is not enough: a privilege inherited
through a group role — or granted to `PUBLIC` — does not appear there, so the query reports
clean while the role can still write. Ask for the effective permission instead, on a
schema-qualified table:

```sql
SELECT has_table_privilege(current_user, 'public.your_table', 'UPDATE') AS can_update,
       has_table_privilege(current_user, 'public.your_table', 'DELETE') AS can_delete,
       pg_get_userbyid(relowner)                AS table_owner,
       current_user,
       pg_get_userbyid(relowner) = current_user AS i_am_the_owner
FROM pg_class WHERE oid = 'public.your_table'::regclass;
```

A check that wrongly reports clean is worse than no check.

## The rule the tests enforce

> A recorded entry can be superseded. It cannot be changed or removed.

## Scope

Synthetic data, plain SQL, no application framework. The stack changes; the shape does not
— any system that keeps a ledger, a consent record, a price history or an audit trail has
this decision to make, and usually made it by accident.

I have built this properly in a production system on Rust and PostgreSQL, where the
append-only guarantee had to survive corrections, withdrawals, and a merge of two records
into one. That system is private and none of its code appears here. This repository is an
independent reconstruction of the failure, written to be read in a few minutes.

---

If you cannot prove what one of your records said last month, that is worth fixing before
someone asks.
**Abdulwahed Mansour** · abdulwahed.sweden@gmail.com

-- The rule, asserted. Run against a database freshly loaded from
-- schema.sql. Any failure raises and stops the script with a non-zero
-- exit code; a clean run prints one line per assertion.

\set QUIET on
SET client_min_messages TO notice;
\set VERBOSITY terse

-- 1 -------------------------------------------------------------------
-- The ordinary design loses the original value. This is the failure.
DO $$
DECLARE original numeric;
BEGIN
    SET ROLE app_user;
    SELECT amount INTO original FROM broken.entries WHERE reference = 'E-1041';
    UPDATE broken.entries SET amount = 4800.00 WHERE reference = 'E-1041';
    IF EXISTS (SELECT 1 FROM broken.entries WHERE amount = original) THEN
        RAISE EXCEPTION 'FAIL: the old value survived, so this is not the ordinary design';
    END IF;
    RAISE NOTICE 'PASS  in-place update destroys the original value (480.00 is unrecoverable)';
END
$$;

-- 2 -------------------------------------------------------------------
-- And the audit log is writable by the role it is supposed to watch.
DO $$
DECLARE removed int;
BEGIN
    SET ROLE app_user;
    INSERT INTO broken.audit_log (actor, note) VALUES (current_user, 'corrected E-1041');
    DELETE FROM broken.audit_log;
    GET DIAGNOSTICS removed = ROW_COUNT;
    IF removed = 0 THEN
        RAISE EXCEPTION 'FAIL: expected the app role to be able to erase its own audit log';
    END IF;
    RAISE NOTICE 'PASS  the app role can erase its own audit log (% row(s))', removed;
END
$$;

-- 3 -------------------------------------------------------------------
-- Append-only: the application cannot update a recorded entry.
DO $$
BEGIN
    SET ROLE app_user;
    UPDATE safe.entries SET amount = 0 WHERE version = 1;
    RAISE EXCEPTION 'FAIL: the app role updated a recorded entry';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS  UPDATE on a recorded entry is refused by Postgres';
END
$$;

-- 4 -------------------------------------------------------------------
DO $$
BEGIN
    SET ROLE app_user;
    DELETE FROM safe.entries WHERE version = 1;
    RAISE EXCEPTION 'FAIL: the app role deleted a recorded entry';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS  DELETE on a recorded entry is refused by Postgres';
END
$$;

-- 5 -------------------------------------------------------------------
-- A correction is still possible. It becomes a new version, and the
-- first version is untouched.
DO $$
DECLARE v1 numeric; v2 numeric; head numeric;
BEGIN
    SET ROLE app_user;
    INSERT INTO safe.entries (series_id, version, reference, amount, status, reason)
    SELECT series_id, version + 1, reference, 4800.00, 'amended', 'keying error'
    FROM safe.entries_current WHERE reference = 'E-1041';

    SELECT amount INTO v1   FROM safe.entries WHERE version = 1;
    SELECT amount INTO v2   FROM safe.entries WHERE version = 2;
    SELECT amount INTO head FROM safe.entries_current WHERE reference = 'E-1041';

    IF v1 <> 480.00 THEN
        RAISE EXCEPTION 'FAIL: version 1 changed, it now reads %', v1;
    END IF;
    IF v2 <> 4800.00 OR head <> 4800.00 THEN
        RAISE EXCEPTION 'FAIL: the correction did not become the current version';
    END IF;
    RAISE NOTICE 'PASS  a correction inserts version 2; version 1 still reads 480.00';
END
$$;

-- 6 -------------------------------------------------------------------
-- A correction without a reason is refused by the schema, not by a form.
DO $$
BEGIN
    SET ROLE app_user;
    INSERT INTO safe.entries (series_id, version, reference, amount, status)
    VALUES ('11111111-1111-1111-1111-111111111111', 3, 'E-1041', 99.00, 'amended');
    RAISE EXCEPTION 'FAIL: a correction was accepted with no reason';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS  a correction with no reason is refused by the schema';
END
$$;

-- 7 -------------------------------------------------------------------
-- The trap. The table owner is not subject to its own grants, so the
-- deployment must not connect as the owner. Asserted, because it is the
-- thing most likely to be got wrong.
DO $$
DECLARE touched int;
BEGIN
    RESET ROLE;
    UPDATE safe.entries SET amount = amount WHERE version = 1;   -- value unchanged
    GET DIAGNOSTICS touched = ROW_COUNT;
    IF touched = 0 THEN
        RAISE EXCEPTION 'FAIL: expected the owner to be able to write';
    END IF;
    RAISE NOTICE 'PASS  the table owner CAN still write — never deploy as the owner';
END
$$;

-- 8 -------------------------------------------------------------------
-- The check most people run is not the check they need.
--
-- A privilege inherited through a group role does not appear in
-- information_schema when you filter on grantee = current_user. Neither
-- does one granted to PUBLIC. The query reports "clean" and the role can
-- still write, which is worse than not having checked at all.
DO $$
DECLARE naive TEXT; effective BOOLEAN;
BEGIN
    CREATE ROLE demo_ledger_writers NOLOGIN;
    GRANT UPDATE ON safe.entries TO demo_ledger_writers;
    GRANT demo_ledger_writers TO app_user;

    SET ROLE app_user;
    SELECT coalesce(string_agg(privilege_type, ','), '(nothing)') INTO naive
      FROM information_schema.role_table_grants
     WHERE grantee = current_user
       AND table_schema = 'safe' AND table_name = 'entries';
    effective := has_table_privilege(current_user, 'safe.entries', 'UPDATE');
    RESET ROLE;

    REVOKE UPDATE ON safe.entries FROM demo_ledger_writers;
    REVOKE demo_ledger_writers FROM app_user;
    DROP ROLE demo_ledger_writers;

    IF position('UPDATE' in naive) > 0 THEN
        RAISE EXCEPTION 'FAIL: the naive grants query was expected to miss the inherited privilege';
    END IF;
    IF NOT effective THEN
        RAISE EXCEPTION 'FAIL: the effective check missed an inherited UPDATE privilege';
    END IF;
    RAISE NOTICE 'PASS  an inherited UPDATE is invisible to the naive grants query (it reports %) and caught by has_table_privilege', naive;
END
$$;

RESET ROLE;
\echo
\echo '8 of 8 assertions passed.'

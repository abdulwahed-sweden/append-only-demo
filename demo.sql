\pset border 2
\pset footer off
\set QUIET on
SET client_min_messages TO notice;

\echo
\echo '=============================================================='
\echo ' 1. THE ORDINARY DESIGN   —  connected as the application role'
\echo '=============================================================='
\echo
SET ROLE app_user;

\echo '-- Entry E-1041 as it was posted:'
SELECT reference, amount, posted_at FROM broken.entries;

\echo '-- Someone corrects it. One statement, and it is applied in place.'
UPDATE broken.entries SET amount = 4800.00, updated_at = now() WHERE reference = 'E-1041';
INSERT INTO broken.audit_log (actor, note) VALUES (current_user, 'corrected E-1041');

SELECT reference, amount, updated_at FROM broken.entries;

\echo '-- The 480.00 is gone. Nothing in this database remembers it.'
\echo '-- There is an audit log, though:'
SELECT actor, note FROM broken.audit_log;

\echo '-- Written by the same role that wrote the entry. So:'
UPDATE broken.audit_log SET note = 'routine check';
DELETE FROM broken.audit_log;

\echo '-- rows left in the audit log:'
SELECT count(*) AS audit_rows FROM broken.audit_log;
\echo '-- The trail is not evidence. It is just another table the app can edit.'
\echo

\echo '=============================================================='
\echo ' 2. THE SAME LEDGER, APPEND-ONLY  —  same application role'
\echo '=============================================================='
\echo
\echo '-- Entry E-1041 as it was posted:'
SELECT version, amount, status, reason FROM safe.entries ORDER BY version;

\echo '-- The same correction. It cannot overwrite, so it inserts version 2.'
INSERT INTO safe.entries (series_id, version, reference, amount, status, reason)
SELECT series_id, version + 1, reference, 4800.00, 'amended', 'keying error, agreed with finance'
FROM safe.entries_current WHERE reference = 'E-1041';

SELECT version, amount, status, reason, recorded_by FROM safe.entries ORDER BY version;

\echo '-- What the application reads is the newest version:'
SELECT version, amount FROM safe.entries_current;

\echo '-- And the original still says exactly what it said when it was signed.'
\echo
\echo '-- Now try to rewrite it, as the application:'
CREATE FUNCTION pg_temp.try_update() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    UPDATE safe.entries SET amount = 0 WHERE version = 1;
    RETURN 'SUCCEEDED — the grant is wrong';
EXCEPTION WHEN insufficient_privilege THEN
    RETURN SQLERRM;
END
$$;

CREATE FUNCTION pg_temp.try_delete() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM safe.entries WHERE version = 1;
    RETURN 'SUCCEEDED — the grant is wrong';
EXCEPTION WHEN insufficient_privilege THEN
    RETURN SQLERRM;
END
$$;

SELECT pg_temp.try_update() AS "UPDATE safe.entries SET amount = 0",
       pg_temp.try_delete() AS "DELETE FROM safe.entries";

\echo
\echo '=============================================================='
\echo ' 3. THE TRAP'
\echo '=============================================================='
\echo
RESET ROLE;
\echo '-- The table OWNER is not subject to its own grants. Same statement,'
\echo '-- connected as the owner (rolled back immediately):'
BEGIN;
UPDATE safe.entries SET amount = 0 WHERE version = 1;
SELECT version, amount FROM safe.entries ORDER BY version;
ROLLBACK;
\echo '-- So none of this holds if the deployment connects as the table owner.'
\echo '-- That is the part people get wrong.'
\echo

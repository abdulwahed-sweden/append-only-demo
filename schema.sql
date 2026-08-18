-- Two designs for the same ledger, side by side in one database.
--
--   broken.*  the ordinary design: the application owns the row and
--             updates it in place, and writes an audit log it also owns.
--   safe.*    corrections are new versions, and the database itself
--             refuses to let the application rewrite what is already there.
--
-- Re-running this file resets both.

DROP SCHEMA IF EXISTS broken CASCADE;
DROP SCHEMA IF EXISTS safe   CASCADE;

-- The role the application connects as. It owns nothing.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
        CREATE ROLE app_user NOLOGIN;
    END IF;
END
$$;

CREATE SCHEMA broken;
CREATE SCHEMA safe;
GRANT USAGE ON SCHEMA broken, safe TO app_user;

-- ---- The ordinary design ---------------------------------------------

CREATE TABLE broken.entries (
    id         BIGSERIAL PRIMARY KEY,
    reference  TEXT NOT NULL,
    amount     NUMERIC(12,2) NOT NULL,
    posted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ
);

-- The audit log everyone has. Written by the application, and owned by
-- the same role that writes the rows it is supposed to be watching.
CREATE TABLE broken.audit_log (
    id    BIGSERIAL PRIMARY KEY,
    at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor TEXT NOT NULL,
    note  TEXT NOT NULL
);

-- Full rights on both. This is the normal setup, not a strawman: one
-- database user, granted everything, used by the whole application.
GRANT SELECT, INSERT, UPDATE, DELETE ON broken.entries, broken.audit_log TO app_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA broken TO app_user;

INSERT INTO broken.entries (reference, amount) VALUES ('E-1041', 480.00);

-- ---- The same ledger, append-only ------------------------------------

CREATE TABLE safe.entries (
    id          BIGSERIAL PRIMARY KEY,
    -- The entry. Every version of it shares this id.
    series_id   UUID NOT NULL,
    -- Which version this row is. Corrections insert version + 1.
    version     BIGINT NOT NULL,
    reference   TEXT NOT NULL,
    amount      NUMERIC(12,2) NOT NULL,
    status      TEXT NOT NULL DEFAULT 'active'
                CHECK (status IN ('active', 'amended', 'withdrawn')),
    -- A correction says why. Written once, with the version it belongs to.
    reason      TEXT,
    recorded_by TEXT NOT NULL DEFAULT current_user,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT entries_one_row_per_version UNIQUE (series_id, version),
    CONSTRAINT entries_correction_has_a_reason CHECK (version = 1 OR reason IS NOT NULL)
);

-- What the application reads: the newest version of each entry.
CREATE VIEW safe.entries_current AS
SELECT DISTINCT ON (series_id) *
FROM safe.entries
ORDER BY series_id, version DESC;

-- ---- The enforcement -------------------------------------------------
--
-- Two lines. Not a convention, not a code review item: the role the
-- application connects as is not granted UPDATE or DELETE, so a bug, a
-- bad deploy or a careless console session cannot rewrite an entry.
GRANT SELECT, INSERT ON safe.entries TO app_user;
REVOKE UPDATE, DELETE, TRUNCATE ON safe.entries FROM app_user;

GRANT SELECT ON safe.entries_current TO app_user;
GRANT USAGE, SELECT ON SEQUENCE safe.entries_id_seq TO app_user;

INSERT INTO safe.entries (series_id, version, reference, amount)
VALUES ('11111111-1111-1111-1111-111111111111', 1, 'E-1041', 480.00);

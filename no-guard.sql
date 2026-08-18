-- Hand the application role back the two grants, and nothing else changes:
-- same schema, same versioning, same application code path.
--
-- Run the suite against this and assertions 3 and 4 fail. That is the
-- point: the rule is held by the grant, not by the table design and not
-- by the application's good intentions.
GRANT UPDATE, DELETE ON safe.entries TO app_user;

-- Manual capacity refresh trigger (request table + least-privilege button role).
--
-- Additive and idempotent. Apply ONCE per site through the change-managed DB path:
--     pwsh ./scripts/apply-manual-trigger.ps1 ...
-- Never fold this into the daily collector job.
--
-- Requirements:
--   * PostgreSQL 13+ (gen_random_uuid() is core; on PG12 or older run
--     CREATE EXTENSION IF NOT EXISTS pgcrypto; first).
--   * Applied by a role with CREATEROLE (or superuser) because it creates the
--     grafana_trigger login role.
--   * psql variable grafana_trigger_pw must be set (the wrapper does this from
--     <deployment_path>/secrets/grafana_trigger_pw.txt).
--
-- Schema: default search_path, same as db/init_timescale.sql (public).

\if :{?grafana_trigger_pw}
\else
DO $$ BEGIN
    RAISE EXCEPTION 'Missing psql variable grafana_trigger_pw. Run this file through scripts/apply-manual-trigger.ps1.';
END $$;
\endif

-- Plain control table, deliberately NOT a hypertable: a handful of rows, no time-series reads.
CREATE TABLE IF NOT EXISTS capacity_run_requests (
    request_id        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    requested_at_utc  timestamptz NOT NULL DEFAULT now(),
    requested_by      text,
    vcenter_name      text,
    note              text,
    status            text        NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','claimed','done','failed','superseded')),
    claimed_at_utc    timestamptz,
    completed_at_utc  timestamptz,
    run_id            text
);

COMMENT ON TABLE capacity_run_requests IS
    'On-demand capacity collection requests. Written by the Grafana button role (grafana_trigger, column-scoped INSERT only), consumed by scripts/capacity-request-watcher.ps1 running as vmware_collector.';

CREATE INDEX IF NOT EXISTS ix_run_requests_pending
    ON capacity_run_requests (requested_at_utc)
    WHERE status = 'pending';

-- 1) Button role: column-scoped INSERT on ONE table, nothing else.
--    Created only if absent, so re-running the migration never rotates the password.
--    To rotate: ALTER ROLE grafana_trigger PASSWORD '<new>'; and update the Grafana datasource.
SELECT format('CREATE ROLE grafana_trigger LOGIN PASSWORD %L', :'grafana_trigger_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_trigger')
\gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO grafana_trigger', current_database())
\gexec

GRANT USAGE ON SCHEMA public TO grafana_trigger;
GRANT INSERT (requested_by, vcenter_name, note) ON capacity_run_requests TO grafana_trigger;
-- Deliberately NO select/update/delete, NO other tables, NO sequence grants.
-- request_id/status/timestamps are filled by column DEFAULTs, which need no privilege.

-- 2) Watcher: the existing collector DB user claims and completes requests.
GRANT SELECT, UPDATE ON capacity_run_requests TO vmware_collector;

-- 3) Status panel read path: the existing Grafana read datasource also connects as
--    vmware_collector, so the SELECT granted in (2) already covers it. No extra role.
--    If a dedicated read-only role is introduced later, grant it SELECT on this table.

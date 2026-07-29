-- Rollback for db/add_manual_trigger.sql. Kept OUT of the forward migration on purpose.
--
--     pwsh ./scripts/apply-manual-trigger.ps1 -SqlFile ./db/rollback_manual_trigger.sql ...
--       (omit -TriggerPasswordFile; the teardown needs no password)
--
-- Order matters: disable + remove the systemd timer/service and revert the dashboard
-- JSON first, otherwise the watcher will error on a missing table.
--
-- Touches nothing created by db/init_timescale.sql.

DROP TABLE IF EXISTS capacity_run_requests;   -- drops the partial index and its grants too

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_trigger') THEN
        EXECUTE 'DROP OWNED BY grafana_trigger';   -- clears grants in this database
        EXECUTE 'DROP ROLE grafana_trigger';
    END IF;
END $$;

-- If DROP ROLE fails, grafana_trigger still holds privileges in another database in this
-- cluster: run DROP OWNED BY grafana_trigger; there as well, then DROP ROLE.
-- Finally delete <deployment_path>/secrets/grafana_trigger_pw.txt and the Grafana
-- write-scoped datasource.

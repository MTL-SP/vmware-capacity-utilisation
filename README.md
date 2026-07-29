# VMware Capacity Collector to PostgreSQL + TimescaleDB

This project collects VMware capacity metrics from vCenter and stores daily snapshots in PostgreSQL + TimescaleDB for Grafana dashboards and trends.

## 1. What this includes
- Collector script: `capacityutilization.ps1`
- DB schema and Timescale policies: `db/init_timescale.sql`
- One-time DB initializer wrapper: `scripts/init-db.ps1`
- On-demand refresh button (optional, see section 13):
  - Migration: `db/add_manual_trigger.sql`, teardown: `db/rollback_manual_trigger.sql`
  - Apply wrapper: `scripts/apply-manual-trigger.ps1`
  - Watcher: `scripts/capacity-request-watcher.ps1` + units in `deploy/`

## 2. Metrics collected
- Per host CPU and RAM capacity/allocation
- Per cluster CPU and RAM summary
- Per cluster HA-adjusted capacity (when supported by HA policy)
- Datastore capacity and usage

Each row includes:
- `snapshot_ts_utc`
- `run_id`
- `vcenter_name`
- `script_version`

## 3. Prerequisites

### 3.1 PowerShell + VMware modules
- PowerShell 7+
- One of:
  - `VMware.PowerCLI`
  - `VCF.PowerCLI`

### 3.2 PostgreSQL + TimescaleDB
- PostgreSQL server running
- TimescaleDB extension installed on that PostgreSQL instance
- `psql` CLI available in PATH on the machine running scripts

### 3.3 Access and accounts
- vCenter read-only service account
- PostgreSQL user with privileges to:
  - Create extension (or extension pre-created by DBA)
  - Create tables/indexes
  - Insert/update data in created tables

## 4. Step-by-step DB setup

### 4.1 Create database (example)
Run as PostgreSQL admin:

```sql
CREATE DATABASE vmware_capacity;
```

### 4.2 Create app user (example)
Run as PostgreSQL admin:

```sql
CREATE USER vmware_collector WITH PASSWORD 'replace_me';
GRANT ALL PRIVILEGES ON DATABASE vmware_capacity TO vmware_collector;
```

If your org restricts `ALL PRIVILEGES`, grant only required permissions.

### 4.3 Enable TimescaleDB extension
Connect to target DB and run:

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
```

If extension creation is restricted, ask DBA to enable it once.

### 4.4 Create secret file for DB password
Create a local file that contains only the DB password.

Linux example:
```bash
mkdir -p /opt/vmware-capacity/secrets
printf '%s' 'replace_me' > /opt/vmware-capacity/secrets/pg_password.txt
chmod 600 /opt/vmware-capacity/secrets/pg_password.txt
```

### 4.5 Initialize schema/tables/hypertables/policies
Run once:

```bash
pwsh ./scripts/init-db.ps1 \
  -PGHost <db-host> \
  -PGPort 5432 \
  -PGDatabase vmware_capacity \
  -PGUsername vmware_collector \
  -PGPasswordFile /opt/vmware-capacity/secrets/pg_password.txt
```

This executes `db/init_timescale.sql` and creates:
- `capacity_collection_runs`
- `host_capacity_metrics`
- `cluster_capacity_metrics`
- `cluster_ha_capacity_metrics`
- `datastore_capacity_metrics`
- Hypertables, indexes, retention, and compression policies

## 5. vCenter secret setup

Create secret file for vCenter password (value only, no extra text/newline preferred):

Linux example:
```bash
printf '%s' 'vc_password_here' > /opt/vmware-capacity/secrets/vc_password.txt
chmod 600 /opt/vmware-capacity/secrets/vc_password.txt
```

## 6. Create collector config file

Copy `collector-config.sample.psd1` to your deployment path and update values:

```bash
cp ./collector-config.sample.psd1 /opt/vmware-capacity/collector-config.psd1
```

Keep passwords only in secret files and set those file paths in config.

## 7. Run the collector manually

```bash
pwsh ./capacityutilization.ps1 -ConfigFile /opt/vmware-capacity/collector-config.psd1
```

Override any config value via CLI when needed (CLI wins):

```bash
pwsh ./capacityutilization.ps1 \
  -ConfigFile /opt/vmware-capacity/collector-config.psd1 \
  -VCenterName <friendly-vcenter-name> \
  -RunId <id>
```

Optional:
- Add `-ShowConsoleSummary` if you want table output in logs.
- Add `-RunId <id>` to control idempotency per run.
- Add `-BatchingThresholdRows <n>` to set when advisory batching warning appears (default `10000`).

## 8. Validate data landed in DB

```sql
SELECT run_id, status, started_at_utc, completed_at_utc, host_rows, cluster_rows, cluster_ha_rows, datastore_rows
FROM capacity_collection_runs
ORDER BY started_at_utc DESC
LIMIT 10;
```

```sql
SELECT count(*) FROM host_capacity_metrics;
SELECT count(*) FROM cluster_capacity_metrics;
SELECT count(*) FROM cluster_ha_capacity_metrics;
SELECT count(*) FROM datastore_capacity_metrics;
```

## 8. Schedule daily run (cron example)

```cron
0 1 * * * /usr/bin/pwsh /opt/vmware-capacity/capacityutilization.ps1 -ConfigFile /opt/vmware-capacity/collector-config.psd1 >> /var/log/vmware-capacity.log 2>&1
```

Use your preferred scheduler if not using cron.

## 9. Parameter precedence and rules

- If both `-ConfigFile` and CLI values are provided, CLI values override config values.
- Required values must be provided either by config or CLI:
  - `VCServer`
  - `VCUsername`
  - `VCPasswordFile`
  - `PGHost`
  - `PGPort`
  - `PGDatabase`
  - `PGUsername`
  - `PGPasswordFile`
- `VCenterName` is optional and defaults to `VCServer`.

## 10. Grafana setup

### 9.1 Add datasource
- Type: PostgreSQL
- Host/DB/User/password: your DB values
- SSL mode as required by your environment

### 9.2 Recommended first panels
- Cluster CPU used % over time (`cluster_capacity_metrics.cpu_used_pct`)
- Cluster RAM used % over time (`cluster_capacity_metrics.ram_used_pct`)
- HA headroom over time:
  - `cluster_ha_capacity_metrics.available_vcpu_after_ha`
  - `cluster_ha_capacity_metrics.available_ram_after_ha`
- Datastore used % over time (`datastore_capacity_metrics.used_pct`)

### 9.3 Timezone
- Data is stored in UTC (`snapshot_ts_utc`)
- Set Grafana dashboard timezone to `Asia/Kuala_Lumpur` (UTC+8)

## 11. Operational notes
- `scripts/init-db.ps1` is one-time or change-managed, not daily.
- Daily jobs should run only `capacityutilization.ps1`.
- Secret files must remain restricted (`600`).
- If run fails, check `capacity_collection_runs.status` and `error_message`.
- Collector logs per-phase timing with `[Timing] ...` lines for trend tracking.
- Collector logs row totals with `[Rows] ...` and warns with `[Advice] ...` when row count reaches `BatchingThresholdRows`.

## 12. Deployment paths per site

Everything below is parameterised by `<deployment_path>`; nothing bakes a path in.

| Site | `<deployment_path>` |
|------|---------------------|
| Site A | `/var/www/vmware-capacity` |
| Site B | `/opt/vmware-capacity` |

Both sites: Ubuntu 24.04, systemd + `pwsh`, with the collector, PostgreSQL and Grafana 12.2.0
on the same server. Config and secrets live in `<deployment_path>/secrets/` at `chmod 600`.

## 13. On-demand capacity refresh button (optional feature)

### 13.1 What it does

Engineers about to rebalance VMs by hand (vMotion) need a fresh snapshot without SSHing to
the collector host. The dashboard gets a **Run capacity collection now** button:

1. The button inserts a `pending` row into `capacity_run_requests` through a second,
   write-scoped Grafana datasource.
2. `scripts/capacity-request-watcher.ps1`, fired by a systemd timer every ~30s on the
   collector host, claims the row and runs the existing `capacityutilization.ps1` with
   `-RunId <request_id>`.
3. The **Latest Manual Refresh Request** panel shows `pending -> claimed -> done`, after
   which the existing panels show the fresh snapshot.

The button triggers a **read-only collection only**. No vMotion, no rebalancing, no
privileged vCenter change - those stay manual human steps.

### 13.2 New DB objects, roles and grants

`db/add_manual_trigger.sql` (additive, idempotent, re-runnable, touches nothing created by
`db/init_timescale.sql`):

- `capacity_run_requests` - a plain table, **deliberately not a hypertable**: a control
  table of a few rows, not time-series. `request_id uuid PRIMARY KEY DEFAULT
  gen_random_uuid()` (core in PG13+; on PG12 or older run
  `CREATE EXTENSION IF NOT EXISTS pgcrypto;` first).
- `ix_run_requests_pending` - partial index on the pending queue.
- Role `grafana_trigger` - `CONNECT`, `USAGE ON SCHEMA public`, and
  `INSERT (requested_by, vcenter_name, note)` on that one table. **Nothing else**: no
  `SELECT`, `UPDATE`, `DELETE`, no other table, no sequence. `request_id`, `status` and the
  timestamps come from column defaults, which need no privilege.
- `GRANT SELECT, UPDATE ON capacity_run_requests TO vmware_collector` - the watcher claims
  and completes rows. The existing Grafana read datasource also connects as
  `vmware_collector`, so the status panel is covered by the same `SELECT`; no new read role.

Not created here: the `grafana_trigger` password. Generate it per site, store it at
`<deployment_path>/secrets/grafana_trigger_pw.txt` (`chmod 600`), and enter the same value
into that site's write-scoped Grafana datasource (Grafana encrypts it at rest).

### 13.3 Apply the migration (one-time, change-managed)

Run through the existing one-time DB-apply path - **not** from the daily job. The migration
creates a login role, so run it as a role with `CREATEROLE` or as the DB superuser
(`postgres`); `vmware_collector` alone is usually not enough.

```bash
DEPLOY_PATH=/opt/vmware-capacity           # Site A: /var/www/vmware-capacity

# 1. Generate and store the button role password
openssl rand -base64 32 | tr -d '\n=' > "$DEPLOY_PATH/secrets/grafana_trigger_pw.txt"
chmod 600 "$DEPLOY_PATH/secrets/grafana_trigger_pw.txt"

# 2. Apply the migration
pwsh "$DEPLOY_PATH/scripts/apply-manual-trigger.ps1" \
  -PGHost localhost \
  -PGPort 5432 \
  -PGDatabase vmware_capacity \
  -PGUsername postgres \
  -PGPasswordFile "$DEPLOY_PATH/secrets/pg_admin_password.txt" \
  -TriggerPasswordFile "$DEPLOY_PATH/secrets/grafana_trigger_pw.txt"
```

The wrapper hands the password to `psql` through a private temp file rather than `-v` on the
command line, so it never appears in the process list. It rejects passwords containing `'`
or `\`. Re-running the migration is safe and never rotates an existing password - to rotate,
run `ALTER ROLE grafana_trigger PASSWORD '<new>';` and update the Grafana datasource.

On PostgreSQL 15+ (Ubuntu 24.04 ships 16) the `public` schema no longer grants `CREATE` to
`PUBLIC`, so `grafana_trigger` cannot create objects of its own. On PG14 or older, confirm
the collector role owns the schema and then run `REVOKE CREATE ON SCHEMA public FROM PUBLIC;`.

### 13.4 Add config keys

Add to the collector config `.psd1` at `<deployment_path>/secrets/` (see
`collector-config.sample.psd1`) - all optional, defaults shown:

- `MinIntervalMinutes = 2` - debounce: skip a request if a run already succeeded that recently.
- `InFlightTimeoutMinutes = 120` - how long a `running` run blocks manual runs before it is
  treated as stale, so a crashed collector cannot wedge the watcher permanently.
- `CollectorScript` - defaults to `capacityutilization.ps1` beside the `scripts/` folder.

### 13.5 Install the watcher (per site)

```bash
DEPLOY_PATH=/opt/vmware-capacity           # Site A: /var/www/vmware-capacity

# Per-site paths: the only file that differs between sites
sudo install -m 644 "$DEPLOY_PATH/deploy/vmware-capacity-watcher.env.sample" \
  /etc/default/vmware-capacity-watcher
sudo sed -i "s#^DEPLOY_PATH=.*#DEPLOY_PATH=$DEPLOY_PATH#" /etc/default/vmware-capacity-watcher
sudo sed -i "s#^CONFIG_FILE=.*#CONFIG_FILE=$DEPLOY_PATH/secrets/collector-config.psd1#" \
  /etc/default/vmware-capacity-watcher

# Units are identical on both sites
sudo install -m 644 "$DEPLOY_PATH/deploy/vmware-capacity-watcher.service" \
  "$DEPLOY_PATH/deploy/vmware-capacity-watcher.timer" /etc/systemd/system/

# Set User= to the account that runs the daily cron job, then enable the timer
sudo systemctl edit vmware-capacity-watcher.service   # [Service] User=<that account>
sudo systemctl daemon-reload
sudo systemctl enable --now vmware-capacity-watcher.timer

systemctl list-timers vmware-capacity-watcher.timer
journalctl -u vmware-capacity-watcher.service -f
```

`Type=oneshot` + `OnUnitActiveSec=30` means systemd never starts a tick while the previous
one is still running; `flock -n /run/lock/vmware-capacity-watcher.lock` in `ExecStart` covers
a stray manual invocation on top of that. The watcher makes **outbound localhost Postgres
connections only** - it opens no port and runs no service of its own.

Run one tick by hand while testing:

```bash
sudo systemctl start vmware-capacity-watcher.service
# or, without systemd:
pwsh "$DEPLOY_PATH/scripts/capacity-request-watcher.ps1" \
  -ConfigFile "$DEPLOY_PATH/secrets/collector-config.psd1"
```

`-SelfTest` runs the debounce-decision assertions and exits without touching the DB.

### 13.6 Grafana changes (per site)

1. **Add the write-scoped datasource** (do not touch the existing read datasource):
   - Type PostgreSQL, name e.g. `capacity-trigger`
   - Host `localhost:5432`, database `vmware_capacity`
   - User `grafana_trigger`, password from
     `<deployment_path>/secrets/grafana_trigger_pw.txt`
   - Restrict its permissions to the engineers who may trigger a run.
2. **Allow the action to POST to Grafana's own query API.** Grafana rejects same-origin
   action requests unless the path is allow-listed, so add to `grafana.ini` and restart
   Grafana:

   ```ini
   [security]
   actions_allow_post_url = /api/ds/query
   ```

3. **Import `grafana/vmware-capacity-cluster-quickview.json`** and map both datasource
   inputs: `DS_GRAFANA-POSTGRESQL-DATASOURCE` -> existing read datasource,
   `DS_CAPACITY_TRIGGER` -> the new write-scoped datasource. Both are import-time
   `__inputs` placeholders, so each site resolves its own UIDs - no UID is hardcoded.
4. Users need **Edit permission on this dashboard**; Grafana gates canvas actions on
   `canEditDashboard()`, so Viewer-only users see no button action.

Dashboard changes in that file, everything else preserved (panels, `$cluster` variable,
tags, timezone, layout):

- second `__inputs` entry `DS_CAPACITY_TRIGGER`
- `__requires` / `pluginVersion` moved from `12.4.0` to `12.2.0`, plus a `canvas` panel entry
- new row "Manual Capacity Refresh" with the canvas button panel and the status table;
  existing panels shifted down 6 grid rows
- dashboard refresh `5m` -> `30s` with a `10s` option, so the status transition is visible
  (revert `refresh` to `5m` if the extra polling is unwanted)

### 13.7 Which button mechanism shipped, and why

**Shipped: a native Canvas panel element with a `fetch` action** POSTing to Grafana's own
`/api/ds/query` against the write-scoped datasource, which executes the `INSERT`. No backend
service, no new port, same-origin so no CORS.

Verified against the Grafana 12.2.0 source before choosing it:

- The Canvas **Button** *element* (`config.api`) has **no confirmation option** in 12.2.0
  (`public/app/features/canvas/elements/button.tsx` calls `callApi` immediately), and §4.3
  requires a confirmation. So the button is a canvas **rectangle** element carrying an
  `action` instead: `CanvasElementOptions.actions` exists in 12.2.0, and an action with
  `oneClick: true` plus a `confirmation` string makes a click open Grafana's `ConfirmModal`
  before firing (`public/app/features/canvas/runtime/element.tsx`).
- Actions are sent with `getBackendSrv().fetch` (session cookie, Grafana's own CSRF
  handling) and carry `X-Grafana-Action: 1`. Grafana's `validate_action_url` middleware
  rejects such requests unless the path matches `security.actions_allow_post_url` - hence
  step 2 in section 13.6. Symptom if that line is missing: `405 Method Not Allowed`.
- Canvas resolves element actions only when the panel has data frames
  (`frames = scene?.data?.series`), so the canvas panel carries a trivial `SELECT 1 AS ok;`
  query on the read datasource.

Not verified here: no Grafana 12.2.0 instance was available in this working copy, so the
click has not been exercised against a live server. Run the section 13.8 functional tests at
first install; if the row does not appear, the fallback below is the documented alternative.

Because `grafana_trigger` has no `SELECT` privilege, the `INSERT` cannot use `RETURNING`, so
Grafana gets an empty result back. An empty-result or error toast may appear even though the
row was inserted - the status panel is the source of truth.

**Fallback if the action does not insert a row: the Business Forms panel**
(`volkovlabs-form-panel`) with a **Data Source** request pointed at the write-scoped
datasource running the same `INSERT` on submit. Two notes if you go there: that plugin is now
in best-effort maintenance (supply-chain consideration), and its officially documented
Postgres-write path uses a Node.js API server, which we deliberately do **not** use because
it would reintroduce a service on the collector host and violate the no-inbound-port
constraint.

**Not implemented on purpose:** any standalone HTTP/API service on the collector host.

### 13.8 Acceptance tests

Functional (`psql` as `vmware_collector`):

```sql
-- After clicking the button and confirming: exactly one new pending row, correct login
SELECT request_id, requested_by, status, requested_at_utc
FROM capacity_run_requests ORDER BY requested_at_utc DESC LIMIT 5;
```

```bash
# Watch the claim + launch + result
journalctl -u vmware-capacity-watcher.service -f
# expect: [Watcher] ... Claimed request <uuid> ... Launching ... -RunId <uuid> ... Request <uuid> done
```

```sql
-- Row completed, run and request share one id, and a fresh snapshot landed
SELECT r.status AS request_status, r.completed_at_utc, r.run_id,
       c.status AS run_status, c.host_rows, c.cluster_rows, c.datastore_rows
FROM capacity_run_requests r
JOIN capacity_collection_runs c ON c.run_id = r.run_id
ORDER BY r.requested_at_utc DESC LIMIT 1;
```

- **Two rapid clicks:** click twice, then confirm one row is `claimed`/`done` and the extra
  is `superseded` (note says `superseded by request <uuid>`), and that only one
  `capacity_collection_runs` row was created. Overlapping ticks are covered by
  `FOR UPDATE SKIP LOCKED`, the `flock`, and the in-flight guard.
- **Forced failure:** temporarily point `VCServer` at an unreachable host in a copy of the
  config, run one tick with `-ConfigFile <that copy>`, and confirm the request goes to
  `failed` and the status panel turns red.

Security (the ISO-facing tests), connecting as the button role:

```bash
PGPASSWORD=$(cat "$DEPLOY_PATH/secrets/grafana_trigger_pw.txt") \
  psql -h localhost -U grafana_trigger -d vmware_capacity
```

```sql
-- allowed
INSERT INTO capacity_run_requests (requested_by, note) VALUES ('test', 'privilege test');
-- all of these must fail with "permission denied"
SELECT * FROM capacity_run_requests;
INSERT INTO capacity_run_requests (requested_by, status) VALUES ('test', 'done');
INSERT INTO capacity_run_requests (request_id, requested_by) VALUES (gen_random_uuid(), 'test');
INSERT INTO capacity_run_requests (requested_by, run_id) VALUES ('test', 'x');
INSERT INTO capacity_run_requests (requested_by, claimed_at_utc) VALUES ('test', now());
UPDATE capacity_run_requests SET status = 'done';
DELETE FROM capacity_run_requests;
SELECT * FROM capacity_collection_runs;
SELECT * FROM host_capacity_metrics;
INSERT INTO capacity_run_requests (requested_by, note)
  VALUES ('test', 'rt') RETURNING request_id;   -- denied: RETURNING needs SELECT
```

```bash
# No new inbound listener attributable to this feature (compare before/after install)
ss -ltn
# No secrets in the dashboard JSON or in git history
grep -riE 'password|secret' grafana/vmware-capacity-cluster-quickview.json
git log -p --all -- grafana/ db/ scripts/ deploy/ | grep -iE 'password *=|BEGIN .*PRIVATE KEY'
```

### 13.9 Security rationale (maps to the ISMS constraints)

| Constraint | How it is met |
|---|---|
| No new inbound port on the collector host | The watcher only makes outbound connections to local Postgres, polled by a systemd timer. No listener, no API service. Prove with `ss -ltn`. |
| Least privilege at the DB layer | `grafana_trigger` has column-scoped `INSERT` on three columns of one table and nothing else. Tested in 13.8. |
| Existing read datasource and daily cron untouched | The read datasource keeps its own `__inputs` placeholder; the daily cron entry is unchanged. The migration and the watcher install are separate one-time actions. |
| No secrets in dashboard JSON or git | The dashboard holds only the `INSERT` statement and datasource *placeholders*. Credentials live in the Grafana datasource config and in `chmod 600` secret files. |
| Idempotent, additive SQL | `CREATE TABLE/INDEX IF NOT EXISTS`, role guarded by `pg_roles`, repeatable `GRANT`s. No existing object is altered or dropped. |
| Concurrency-safe | `FOR UPDATE SKIP LOCKED` claim, duplicate pendings marked `superseded`, `MinIntervalMinutes` debounce, in-flight `running` guard, `Type=oneshot` + `flock`. |
| Audit trail | Every request row keeps who asked, when, its status, and the `run_id`. Watcher logs each claim, launch and result to the journal; the collector logs as before. |

Residual risk to note in the change record: `${__user.login}` is interpolated into the
`INSERT` literal in the dashboard JSON. A login containing a quote could alter that
statement, but the blast radius is bounded by the role, which can only insert into three
columns of this one table.

### 13.10 Operational notes and rollback

Where to look when a manual run misbehaves:

```sql
SELECT request_id, requested_by, status, requested_at_utc, claimed_at_utc,
       completed_at_utc, run_id, note
FROM capacity_run_requests ORDER BY requested_at_utc DESC LIMIT 20;

SELECT run_id, status, started_at_utc, completed_at_utc, error_message
FROM capacity_collection_runs ORDER BY started_at_utc DESC LIMIT 20;
```

- Status stays `pending` -> watcher not running: `systemctl list-timers`,
  `journalctl -u vmware-capacity-watcher.service`.
- Status `failed` -> read `capacity_collection_runs.error_message` for that `run_id`.
- Status `superseded` -> duplicate click, or the debounce/in-flight guard declined it; the
  `note` column says which.
- Nothing happens on click -> check `actions_allow_post_url`, that the user has Edit
  permission on the dashboard, and the browser network tab for a `405` on `/api/ds/query`.

Rollback, in this order:

```bash
sudo systemctl disable --now vmware-capacity-watcher.timer
sudo systemctl stop vmware-capacity-watcher.service
sudo rm -f /etc/systemd/system/vmware-capacity-watcher.{service,timer} \
           /etc/default/vmware-capacity-watcher
sudo systemctl daemon-reload
```

Then in Grafana: re-import the previous dashboard JSON (`git checkout <prev> --
grafana/vmware-capacity-cluster-quickview.json`) and delete the `capacity-trigger`
datasource. Then drop the DB objects:

```bash
pwsh "$DEPLOY_PATH/scripts/apply-manual-trigger.ps1" \
  -PGHost localhost -PGPort 5432 -PGDatabase vmware_capacity \
  -PGUsername postgres -PGPasswordFile "$DEPLOY_PATH/secrets/pg_admin_password.txt" \
  -SqlFile "$DEPLOY_PATH/db/rollback_manual_trigger.sql"
```

Finally delete `<deployment_path>/secrets/grafana_trigger_pw.txt` and remove the
`actions_allow_post_url` line from `grafana.ini`. Nothing created by
`db/init_timescale.sql`, the daily cron job, or the read datasource is affected at any step.

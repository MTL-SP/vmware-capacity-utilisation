# Deployment runbook: on-demand capacity refresh button — Site A

Concrete, copy-pasteable steps for **Site A only**. Every path and account below was verified
against the live host, so there are no placeholders to substitute. For the parameterised
version (and the rationale behind each control) see [OPTIONAL-FEATURE.md](../OPTIONAL-FEATURE.md).

Run everything as `root` unless a command says otherwise.

## Site A facts this runbook assumes

| Item | Value |
|---|---|
| Deployment path | `/var/www/vmware-capacity` |
| Collector config | `/var/www/vmware-capacity/collector-config.psd1` (deployment root, **not** `secrets/`) |
| Secrets directory | `/var/www/vmware-capacity/secrets/` (`pg_password.txt`, `vc_password.txt`, both `600`) |
| Daily job | root crontab, `0 13 * * *`, logging to `/var/log/vmware-capacity.log` |
| Watcher runs as | `root` — same account as the daily job |
| OS / stack | Ubuntu 24.04, systemd + `pwsh`, collector + PostgreSQL + Grafana 12.2.0 co-located |
| DB owner | `postgres`; `vmware_collector` has **no** `CREATEROLE` |

That last row is why the migration is applied as the `postgres` OS user over the Unix socket
(peer auth, no password needed) rather than through `scripts/apply-manual-trigger.ps1`. The
wrapper needs a DB login that can `CREATE ROLE` and `GRANT USAGE ON SCHEMA public`; no such
password file exists on this host, and creating one just to run a migration is worse than
using peer auth once.

---

## Phase 0 — Pre-flight

```bash
cd /var/www/vmware-capacity && git pull

psql --version && pwsh --version
sudo -u postgres psql -Atc "show server_version;"          # must be 13 or newer
sudo crontab -l | grep -c capacityutilization              # must print 1
sudo -u postgres test -r /var/www/vmware-capacity/db/add_manual_trigger.sql && echo "sql readable by postgres"
```

Capture the listener baseline — this is the ISO evidence that no inbound port is opened:

```bash
ss -ltn > /root/listeners-before-manual-trigger.txt
```

**Stop if** `server_version` is below 13 (`gen_random_uuid()` would be missing — enable
`pgcrypto` first), the cron count is not 1, or the SQL file is not readable by `postgres`.

---

## Phase 1 — Database migration (one-time, change-managed)

### 1.1 Generate the button role password

```bash
umask 077
openssl rand -base64 32 | tr -d '\n=' > /var/www/vmware-capacity/secrets/grafana_trigger_pw.txt
chmod 600 /var/www/vmware-capacity/secrets/grafana_trigger_pw.txt
ls -l /var/www/vmware-capacity/secrets/grafana_trigger_pw.txt
```

Base64 output contains no quote or backslash, so it is safe to pass through `psql`'s `\set`
and into the Grafana datasource field unescaped.

### 1.2 Apply the migration as the postgres OS user

Root builds a small script that sets the password variable and includes the migration, then
feeds it to `psql` **on stdin**. Root can read the secret; `psql` runs as `postgres`. The
password never appears in `ps`, and the secret file stays `600` root-only.

```bash
umask 077
{ printf "\\set grafana_trigger_pw '"
  tr -d '\n' < /var/www/vmware-capacity/secrets/grafana_trigger_pw.txt
  printf "'\n\\i /var/www/vmware-capacity/db/add_manual_trigger.sql\n"
} > /root/mt-apply.sql

sudo -u postgres psql -v ON_ERROR_STOP=1 -d vmware_capacity < /root/mt-apply.sql

shred -u /root/mt-apply.sql
```

Do **not** "simplify" the redirect to `-f /root/mt-apply.sql`: `psql` opens `-f` files itself,
as `postgres`, and cannot read anything under `/root`. The stdin redirect is opened by root's
shell, which is the whole point.

Expected output: `CREATE ROLE`, `CREATE TABLE`, `COMMENT`, `CREATE INDEX`, several `GRANT`
lines, exit status 0. Re-running the file is safe and will not rotate the password.

### 1.3 Verify the objects and the grants

```bash
sudo -u postgres psql -d vmware_capacity -c "\d capacity_run_requests" -c "\dp capacity_run_requests"
```

`grafana_trigger` must appear as exactly `grafana_trigger=a*/...` on
`requested_by`, `vcenter_name`, `note` — **column-scoped INSERT and nothing else**.
`vmware_collector` must have `SELECT` and `UPDATE` on the table.

### 1.4 Least-privilege tests (ISO evidence — do them now)

```bash
PGPASSWORD=$(cat /var/www/vmware-capacity/secrets/grafana_trigger_pw.txt) \
  psql -h localhost -U grafana_trigger -d vmware_capacity
```

```sql
-- must SUCCEED
INSERT INTO capacity_run_requests (requested_by, note) VALUES ('privtest', 'privilege test');

-- every one of these must fail with "permission denied"
SELECT * FROM capacity_run_requests;
INSERT INTO capacity_run_requests (requested_by, status) VALUES ('privtest', 'done');
INSERT INTO capacity_run_requests (request_id, requested_by) VALUES (gen_random_uuid(), 'privtest');
INSERT INTO capacity_run_requests (requested_by, run_id) VALUES ('privtest', 'x');
INSERT INTO capacity_run_requests (requested_by, claimed_at_utc) VALUES ('privtest', now());
UPDATE capacity_run_requests SET status = 'done';
DELETE FROM capacity_run_requests;
SELECT * FROM capacity_collection_runs;
SELECT * FROM host_capacity_metrics;
INSERT INTO capacity_run_requests (requested_by, note) VALUES ('privtest', 'rt') RETURNING request_id;
```

Save that transcript for the change record. The row you just inserted is a real `pending`
request — the watcher will pick it up and run a collection as soon as Phase 3 is live. That is
a useful first end-to-end test, so leave it.

---

## Phase 2 — Collector config keys

Edit `/var/www/vmware-capacity/collector-config.psd1` and add, inside the existing `@{ ... }`:

```powershell
    MinIntervalMinutes = 2
    InFlightTimeoutMinutes = 120
    CollectorScript = "/var/www/vmware-capacity/capacityutilization.ps1"
```

All three are optional and these are the defaults; setting them explicitly documents intent.
Confirm the file still parses — the daily job depends on it:

```bash
pwsh -NoLogo -Command "Import-PowerShellDataFile -LiteralPath '/var/www/vmware-capacity/collector-config.psd1' | Format-List"
```

---

## Phase 3 — Watcher and timer

### 3.1 Per-site environment file

The sample ships with `/opt` defaults, so both lines need changing on Site A:

```bash
install -m 644 /var/www/vmware-capacity/deploy/vmware-capacity-watcher.env.sample \
  /etc/default/vmware-capacity-watcher
sed -i 's#^DEPLOY_PATH=.*#DEPLOY_PATH=/var/www/vmware-capacity#' /etc/default/vmware-capacity-watcher
sed -i 's#^CONFIG_FILE=.*#CONFIG_FILE=/var/www/vmware-capacity/collector-config.psd1#' \
  /etc/default/vmware-capacity-watcher
cat /etc/default/vmware-capacity-watcher
```

### 3.2 Units, plus the `User=root` override

```bash
install -m 644 /var/www/vmware-capacity/deploy/vmware-capacity-watcher.service \
  /var/www/vmware-capacity/deploy/vmware-capacity-watcher.timer /etc/systemd/system/

systemctl edit vmware-capacity-watcher.service
```

Put exactly this in the drop-in editor, save, exit:

```ini
[Service]
User=root
```

```bash
systemctl daemon-reload
systemctl cat vmware-capacity-watcher.service | grep -E '^User=|^ExecStart='
```

The shipped unit says `User=vmware-capacity`; the drop-in must win, so the last `User=` printed
has to be `root`. `User=` is the only thing the drop-in needs — the unit already gives `pwsh` a
writable `HOME` on `/run`, which it requires under `ProtectHome=true`. Site A has no dedicated service account today — the watcher deliberately
matches the daily job. Moving both to a non-root account is a sensible follow-up change, not
part of this one.

### 3.3 First tick by hand

The `pending` row from Phase 1.4 is waiting, so this tick should claim it and run a full
collection (a few minutes, same as the daily job):

```bash
systemctl start vmware-capacity-watcher.service
journalctl -u vmware-capacity-watcher.service -n 50 --no-pager
```

Expect: `Claimed request <uuid>` → `Launching ... -RunId <uuid>` → `Request <uuid> done`.

```sql
-- as postgres or vmware_collector
SELECT r.status, r.requested_by, r.completed_at_utc, r.run_id, c.status AS run_status,
       c.host_rows, c.cluster_rows, c.datastore_rows
FROM capacity_run_requests r
LEFT JOIN capacity_collection_runs c ON c.run_id = r.run_id
ORDER BY r.requested_at_utc DESC LIMIT 3;
```

### 3.4 Enable the timer

```bash
systemctl enable --now vmware-capacity-watcher.timer
systemctl list-timers vmware-capacity-watcher.timer
```

Confirm nothing new is listening:

```bash
ss -ltn | diff /root/listeners-before-manual-trigger.txt - && echo "no new listener"
```

`Type=oneshot` plus `OnUnitActiveSec=60` means systemd never overlaps ticks;
`flock -n /run/lock/vmware-capacity-watcher.lock` covers a manual run landing on a timer tick.

---

## Phase 4 — Grafana

### 4.1 Write-scoped datasource

New datasource, **do not touch the existing read datasource**:

- Type: PostgreSQL, name: `capacity-trigger`
- Host: `localhost:5432`, Database: `vmware_capacity`
- User: `grafana_trigger`, Password: contents of `secrets/grafana_trigger_pw.txt`
- TLS/SSL: whatever the existing read datasource uses
- Save & test, then restrict its permissions to the engineers allowed to trigger runs

### 4.2 Allow the action to POST to Grafana's own query API — mandatory

Grafana rejects same-origin action requests unless the path is allow-listed, so the button
fails with `405 Method Not Allowed` without this. Edit `/etc/grafana/grafana.ini`:

```ini
[security]
actions_allow_post_url = /api/ds/query
```

```bash
systemctl restart grafana-server
systemctl is-active grafana-server
```

If the `[security]` section already sets `actions_allow_post_url`, append to it
comma-separated rather than replacing it.

### 4.3 Import the dashboard

Import `grafana/vmware-capacity-cluster-quickview.json` (Dashboards → New → Import) and map
**both** datasource inputs:

- `DS_GRAFANA-POSTGRESQL-DATASOURCE` → the existing read datasource
- `DS_CAPACITY_TRIGGER` → `capacity-trigger`

Importing over the existing dashboard keeps its UID (`vmware-capacity-cluster-quickview`).

### 4.4 Dashboard permissions

Grafana gates canvas actions on `canEditDashboard()`, so give the engineers who need the
button **Edit** permission on this dashboard or its folder. Viewer-only users see the panel
but get no action.

---

## Phase 5 — Acceptance tests

Use `https://dashboard.nimbus.my` for all of these. The button does not work when Grafana is
browsed on the server IP over VPN - see the troubleshooting table.

1. **Single click.** Click the green **Run capacity collection now** element, then the action in
   the tooltip, then confirm. A new `pending` row appears with `requested_by` = your Grafana
   login. Watch the status panel go `pending → claimed → done` within roughly a minute plus
   collection time. **Verified 2026-07-29.**

   ```bash
   journalctl -u vmware-capacity-watcher.service -f
   ```

2. **Two rapid clicks.** Confirm twice in quick succession. Exactly one row runs; the other
   ends as `superseded` with `superseded by request <uuid>` in its `note`, and only one new
   `capacity_collection_runs` row exists.

3. **Debounce.** Click again immediately after a successful run. The row should end
   `superseded` with `not launched: a collection succeeded within the last 2 minute(s)`.

4. **Forced failure.** Confirm a broken collector lands the request as `failed` rather than
   leaving it stuck at `claimed`. Two things will make this test lie to you: the enabled timer
   will claim the row with the good config and succeed, and the `MinIntervalMinutes` debounce
   will supersede anything queued within 2 minutes of test 2/3's successful run.

   ```bash
   DEPLOY=/var/www/vmware-capacity

   # Needs to read > 2 minutes before you continue
   sudo -u postgres psql -d vmware_capacity -At -c \
     "select now() - max(completed_at_utc) from capacity_collection_runs where status='success';"

   systemctl stop vmware-capacity-watcher.timer

   umask 077
   cp "$DEPLOY/collector-config.psd1" /root/cfg-fail-test.psd1
   sed -i 's#^\s*VCServer\s*=.*#    VCServer = "vcenter-does-not-exist.invalid"#' /root/cfg-fail-test.psd1

   PGPASSWORD=$(cat "$DEPLOY/secrets/grafana_trigger_pw.txt") \
     psql -h localhost -U grafana_trigger -d vmware_capacity \
     -c "INSERT INTO capacity_run_requests (requested_by, note) VALUES ('failtest','forced failure test');"

   pwsh "$DEPLOY/scripts/capacity-request-watcher.ps1" -ConfigFile /root/cfg-fail-test.psd1
   echo "watcher exit=$?"      # 1 is correct - a failed collection is a failed tick

   shred -u /root/cfg-fail-test.psd1
   systemctl start vmware-capacity-watcher.timer
   ```

   Only `VCServer` changes, so the copy's DB and secret paths stay valid and the watcher can
   still record the outcome. `.invalid` is reserved and never resolves, so the connect fails
   immediately - though PowerCLI still takes ~30s to import first. Expect the request at
   `failed`, the matching `capacity_collection_runs` row at `failed` with `error_message` set,
   and a red status panel.

5. **No secrets committed.**

   ```bash
   grep -riE 'password|secret' /var/www/vmware-capacity/grafana/vmware-capacity-cluster-quickview.json
   git -C /var/www/vmware-capacity status --short   # secrets/ is gitignored
   ```

6. **Daily job unchanged.** `sudo crontab -l` still shows the single `0 13 * * *` entry, and
   the next nightly run lands normally.

Step 1 was the only part of this feature never exercised against a live Grafana 12.2.0
instance during development; everything else was verified against the upstream 12.2.0 source.
It passed on 2026-07-29, so the mechanism is now proven end to end on this host.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| The element drags instead of clicking, no action menu appears | Inline editing is on for that panel. Edit panel -> Canvas -> Inline editing -> off |
| CORS error in the browser console plus `401` on `/api/ds/query` | Grafana is being browsed on the server IP over VPN instead of `https://dashboard.nimbus.my`. The action builds its own request, so a mismatched origin sends no session cookie. Other panels still work on that origin, which makes it look like a button fault |
| Nothing happens on click, `405` on `/api/ds/query` in the browser network tab | Phase 4.2 not applied or Grafana not restarted |
| `400` on `/api/ds/query` with `status_source=downstream` and nothing in the Postgres log | The SQL never reached Postgres. Check the request payload in the browser network tab: a `${DS_CAPACITY_TRIGGER}` placeholder left un-substituted means the datasource input was not mapped at import |
| No action offered on click at all | User lacks Edit permission on the dashboard (Phase 4.4) |
| Error or empty-result toast after confirming | Expected: `grafana_trigger` has no `SELECT`, so the `INSERT` cannot use `RETURNING` and Grafana gets an empty frame. The status panel is the source of truth |
| Row stays `pending` | Timer not running: `systemctl list-timers`, `journalctl -u vmware-capacity-watcher.service` |
| Row goes `failed` | `SELECT error_message FROM capacity_collection_runs WHERE run_id = '<uuid>';` |
| Row goes `superseded` unexpectedly | Duplicate click, the `MinIntervalMinutes` debounce, or an in-flight `running` run. The `note` column says which |
| Every request `superseded` with "already running" | A crashed collector left `status = 'running'`. `InFlightTimeoutMinutes` (120) clears it automatically; to unblock sooner, fix that row's status |
| `psql: permission denied` reading the migration during Phase 1.2 | You used `-f` instead of the stdin redirect — see the note in 1.2 |
| Service exits 134 with `TypeInitializationException ... Read-only file system : '/root/.cache'` | `ProtectHome=true` leaves `pwsh` no writable `$HOME`. The shipped unit now sets `RuntimeDirectory` + `Environment=HOME=/run/vmware-capacity-watcher`; if your installed copy predates that, re-install the unit from `deploy/` or add those lines to the drop-in |

Day-to-day queries:

```sql
SELECT request_id, requested_by, status, requested_at_utc, claimed_at_utc,
       completed_at_utc, run_id, note
FROM capacity_run_requests ORDER BY requested_at_utc DESC LIMIT 20;

SELECT run_id, status, started_at_utc, completed_at_utc, error_message
FROM capacity_collection_runs ORDER BY started_at_utc DESC LIMIT 20;
```

---

## Rollback (Site A paths)

In this order — the watcher errors if the table disappears first.

```bash
systemctl disable --now vmware-capacity-watcher.timer
systemctl stop vmware-capacity-watcher.service
rm -rf /etc/systemd/system/vmware-capacity-watcher.service.d
rm -f /etc/systemd/system/vmware-capacity-watcher.service \
      /etc/systemd/system/vmware-capacity-watcher.timer \
      /etc/default/vmware-capacity-watcher
systemctl daemon-reload
```

In Grafana: re-import the previous dashboard JSON, delete the `capacity-trigger` datasource,
remove the `actions_allow_post_url` line from `/etc/grafana/grafana.ini`, restart
`grafana-server`.

Then drop the DB objects and the secret:

```bash
sudo -u postgres psql -v ON_ERROR_STOP=1 -d vmware_capacity \
  < /var/www/vmware-capacity/db/rollback_manual_trigger.sql
shred -u /var/www/vmware-capacity/secrets/grafana_trigger_pw.txt
```

Nothing created by `db/init_timescale.sql`, the daily cron job, or the read datasource is
touched at any step.

---

## Change-record checklist

- [ ] Phase 0 pre-flight output captured, including `/root/listeners-before-manual-trigger.txt`
- [ ] Migration applied, exit 0, `\dp capacity_run_requests` output attached
- [ ] Least-privilege test transcript attached (Phase 1.4)
- [ ] Config keys added, config still parses
- [ ] Timer enabled, `User=root` confirmed via `systemctl cat`
- [ ] `ss -ltn` diff shows no new listener
- [ ] Grafana datasource added, `actions_allow_post_url` set, dashboard imported with both inputs mapped
- [ ] Acceptance tests 1–6 passed
- [ ] Rollback steps reviewed and understood by the on-call engineer

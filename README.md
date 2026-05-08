# VMware Capacity Collector to PostgreSQL + TimescaleDB

This project collects VMware capacity metrics from vCenter and stores daily snapshots in PostgreSQL + TimescaleDB for Grafana dashboards and trends.

## 1. What this includes
- Collector script: `capacityutilization.ps1`
- DB schema and Timescale policies: `db/init_timescale.sql`
- One-time DB initializer wrapper: `scripts/init-db.ps1`
- Planning/implementation notes: `plan.md`

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

## 6. Run the collector manually

```bash
pwsh ./capacityutilization.ps1 \
  -VCServer <vcenter-fqdn-or-ip> \
  -VCUsername <vc-readonly-user> \
  -VCPasswordFile /opt/vmware-capacity/secrets/vc_password.txt \
  -PGHost <db-host> \
  -PGPort 5432 \
  -PGDatabase vmware_capacity \
  -PGUsername vmware_collector \
  -PGPasswordFile /opt/vmware-capacity/secrets/pg_password.txt \
  -VCenterName <friendly-vcenter-name>
```

Optional:
- Add `-ShowConsoleSummary` if you want table output in logs.
- Add `-RunId <id>` to control idempotency per run.

## 7. Validate data landed in DB

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
0 1 * * * /usr/bin/pwsh /opt/vmware-capacity/capacityutilization.ps1 -VCServer <vcenter> -VCUsername <user> -VCPasswordFile /opt/vmware-capacity/secrets/vc_password.txt -PGHost <db-host> -PGPort 5432 -PGDatabase vmware_capacity -PGUsername vmware_collector -PGPasswordFile /opt/vmware-capacity/secrets/pg_password.txt -VCenterName <name> >> /var/log/vmware-capacity.log 2>&1
```

Use your preferred scheduler if not using cron.

## 9. Grafana setup

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

## 10. Operational notes
- `scripts/init-db.ps1` is one-time or change-managed, not daily.
- Daily jobs should run only `capacityutilization.ps1`.
- Secret files must remain restricted (`600`).
- If run fails, check `capacity_collection_runs.status` and `error_message`.

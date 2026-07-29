# VMware Capacity Collector — Support Team Reference Guide

A companion handout to the training deck (`slides.md`). Keep this as your reference for
**using, managing, and troubleshooting** the daily VMware capacity pipeline and its Grafana dashboards.

> **Scope:** operating and troubleshooting the system. You don't need to edit the script's code —
> this guide covers running it, reading its output, using the dashboards, and fixing common failures.

---

## Table of contents

1. [Objective](#1-objective)
2. [Technology stack](#2-technology-stack)
3. [How it fits together](#3-how-it-fits-together)
4. [One-time setup (reference)](#4-one-time-setup-reference)
5. [Daily use](#5-daily-use)
6. [Reading the logs](#6-reading-the-logs)
7. [Understanding the numbers](#7-understanding-the-numbers)
8. [The Grafana dashboards](#8-the-grafana-dashboards)
9. [Troubleshooting](#9-troubleshooting)
10. [Maintenance](#10-maintenance)
11. [Quick reference (cheat sheet)](#11-quick-reference-cheat-sheet)
12. [Glossary](#12-glossary)

---

## 1. Objective

vCenter shows capacity **at this moment**, but not **how it's changing over time**. This system:

- Takes a **daily snapshot** of VMware capacity (hosts, clusters, datastores).
- Stores every snapshot in a database so we keep **history**.
- Charts that history in **Grafana** to spot trends — *"is this cluster filling up, and when will it run out?"*

**What it collects each run:**

| Group | Examples |
|-------|----------|
| Per host | CPU cores, usable vCPU, RAM, allocation, used % |
| Per cluster | Totals, utilization %, DRS/HA flags |
| Cluster HA-adjusted | Headroom remaining if a host fails (only when HA policy supports it) |
| Datastore | Capacity, used, free, used % |

**Why support cares:** capacity planning, incident context ("was it already full last week?"),
management reporting, and — because it's scheduled — your role is mostly **monitoring and troubleshooting**.

---

## 2. Technology stack

| Technology | What it is | Its role here |
|-----------|-----------|---------------|
| **PowerShell 7** | Microsoft's modern cross-platform scripting shell | Runs the collector script (`capacityutilization.ps1`) |
| **VMware PowerCLI** | A PowerShell module of VMware commands | Logs into vCenter (read-only) and reads host/cluster/datastore data |
| **PostgreSQL** | Open-source SQL database | Stores every snapshot in tables |
| **TimescaleDB** | Time-series extension for PostgreSQL | Optimizes time queries; auto-handles retention & compression |
| **Grafana** | Dashboard / visualization tool | Reads PostgreSQL and draws the charts |
| **psql** | PostgreSQL command-line client | How the script writes data into the database |

**One-line intros:**

- **PowerShell / PowerCLI** — think of PowerCLI as "the vCenter API, in PowerShell." The script calls
  commands like `Connect-VIServer`, `Get-Cluster`, `Get-VMHost`, `Get-Datastore`.
- **PostgreSQL** — data lives in tables (rows & columns); we read it with SQL `SELECT` queries.
- **TimescaleDB** — turns tables into **hypertables** so time-range queries are fast, and runs two
  housekeeping jobs automatically: **retention** (delete data older than 24 months) and
  **compression** (compress data older than 30 days).
- **Grafana** — read-only display. It never changes the data.
- **psql** — must be installed and **on the PATH** of the machine running the collector.

---

## 3. How it fits together

```
   ┌──────────┐   PowerCLI    ┌────────────────────────┐    psql     ┌──────────────────────┐    SQL    ┌─────────┐
   │ vCenter  │ ────────────▶ │ capacityutilization.ps1│ ─────────▶ │ PostgreSQL +          │ ◀──────── │ Grafana │
   │ (source) │   read-only   │  (daily collector)     │   INSERT   │ TimescaleDB (storage) │   read    │ (charts)│
   └──────────┘               └────────────────────────┘            └──────────────────────┘           └─────────┘
```

**Key concept: one run = one snapshot = one `run_id`.** Everything written by a single execution shares
that ID, and the run's outcome is recorded in the audit table.

### Project files

| File | Purpose | How often touched |
|------|---------|-------------------|
| `capacityutilization.ps1` | The collector — runs every day | Every run |
| `collector-config.psd1` | Connection settings + secret-file paths | When connection details change |
| `db/init_timescale.sql` | Database schema, hypertables, retention/compression policies | One-time / rare |
| `scripts/init-db.ps1` | One-time wrapper that applies the SQL | One-time / rare |
| secret files (`vc_password.txt`, `pg_password.txt`) | vCenter & DB passwords (value only) | On password rotation |
| `grafana/vmware-capacity-overview.json` | Main dashboard | One-time import |
| `grafana/vmware-capacity-overview-repeated.json` | Multi-select comparison dashboard | One-time import |

### Database tables

| Table | Contents |
|-------|----------|
| `capacity_collection_runs` | **Audit log** — one row per run: status, timestamps, row counts, error message |
| `host_capacity_metrics` | Per-host CPU/RAM metrics per snapshot |
| `cluster_capacity_metrics` | Per-cluster totals & utilization per snapshot |
| `cluster_ha_capacity_metrics` | HA-adjusted headroom (only for clusters with a supported HA policy) |
| `datastore_capacity_metrics` | Per-datastore capacity & usage per snapshot |

> **`capacity_collection_runs` is the table you'll check most** — it's how you know last night's run worked.

---

## 4. One-time setup (reference)

The test/production environment is **already set up**. You normally won't run these steps, but you
should understand them. (Linux paths shown; on Windows use Task Scheduler and Windows paths.)

1. **Create database & user** (PostgreSQL admin):
   ```sql
   CREATE DATABASE vmware_capacity;
   CREATE USER vmware_collector WITH PASSWORD 'replace_me';
   GRANT ALL PRIVILEGES ON DATABASE vmware_capacity TO vmware_collector;
   ```
2. **Enable TimescaleDB** (connected to the target DB):
   ```sql
   CREATE EXTENSION IF NOT EXISTS timescaledb;
   ```
3. **Create secret files** (value only, strict permissions):

   **Linux:**
   ```bash
   printf '%s' 'pg_password'  > /opt/vmware-capacity/secrets/pg_password.txt
   printf '%s' 'vc_password'  > /opt/vmware-capacity/secrets/vc_password.txt
   chmod 600 /opt/vmware-capacity/secrets/*.txt
   ```

   **Windows (PowerShell):**
   ```powershell
   New-Item -ItemType Directory -Force C:\vmware-capacity\secrets
   Set-Content -NoNewline C:\vmware-capacity\secrets\pg_password.txt 'pg_password'
   Set-Content -NoNewline C:\vmware-capacity\secrets\vc_password.txt 'vc_password'
   # then restrict the folder to the run account with icacls
   ```
4. **Initialize the schema** (creates tables, hypertables, indexes, policies — safe to re-run):
   ```bash
   pwsh ./scripts/init-db.ps1 \
     -PGHost <db-host> -PGPort 5432 \
     -PGDatabase vmware_capacity \
     -PGUsername vmware_collector \
     -PGPasswordFile /opt/vmware-capacity/secrets/pg_password.txt
   ```
5. **Create the config file** — copy the sample and fill it in:
   ```bash
   cp ./collector-config.sample.psd1 /opt/vmware-capacity/collector-config.psd1
   ```
   ```powershell
   @{
       VCServer       = "vcenter.example.local"
       VCUsername     = "svc-vcenter-readonly"
       VCPasswordFile = "/opt/vmware-capacity/secrets/vc_password.txt"
       PGHost         = "db.example.local"
       PGPort         = 5432
       PGDatabase     = "vmware_capacity"
       PGUsername     = "vmware_collector"
       PGPasswordFile = "/opt/vmware-capacity/secrets/pg_password.txt"
       VCenterName    = "Production-vCenter"   # optional friendly name (defaults to VCServer)
       BatchingThresholdRows = 10000           # advisory warning threshold
   }
   ```
6. **Schedule the daily run** — cron (Linux) or Task Scheduler (Windows). See [Maintenance](#10-maintenance).
7. **Import the Grafana dashboards** (the two JSON files) and point them at the PostgreSQL datasource.

> `init-db.ps1` is **change-managed**, not a daily task. The daily job runs only `capacityutilization.ps1`.

---

## 5. Daily use

Normal runs happen on the schedule. To run one **manually**:

```bash
pwsh ./capacityutilization.ps1 -ConfigFile /opt/vmware-capacity/collector-config.psd1
```

### Useful options

| Option | Effect |
|--------|--------|
| `-ShowConsoleSummary` | Prints the capacity tables to the console (useful for demos / spot checks) |
| `-RunId <id>` | Reuse an ID; re-running with the same ID will **not** create duplicate rows |
| `-VCenterName <name>` | Override the friendly name shown in the data |
| `-BatchingThresholdRows <n>` | Sets when the "large run" advisory appears (default `10000`) |
| `-ConfigFile <path>` | Path to the `.psd1` config |

> **Precedence:** any value passed on the command line **overrides** the config file.
> Required settings (`VCServer`, `VCUsername`, `VCPasswordFile`, `PGHost`, `PGPort`, `PGDatabase`,
> `PGUsername`, `PGPasswordFile`) must come from **either** the config or the CLI.

### What happens during a run

1. Loads & validates configuration.
2. Marks a new run as **`running`** in `capacity_collection_runs`.
3. Connects to vCenter (read-only) and walks clusters → hosts → datastores.
4. Computes all capacity metrics in memory.
5. Writes **everything in one database transaction**.
6. Marks the run **`success`** (with row counts) or **`failed`** (with a sanitized error message).

> Because it's one transaction, you never get a half-written snapshot.

### Morning check — did last night's run work?

```sql
SELECT run_id, status, started_at_utc, completed_at_utc,
       host_rows, cluster_rows, cluster_ha_rows, datastore_rows
FROM capacity_collection_runs
ORDER BY started_at_utc DESC
LIMIT 10;
```

- `status = 'success'` → healthy.
- `status = 'failed'` → read `error_message`.
- `status = 'running'` on an old row → the run died mid-way; check the log file.

### "Is there data?" sanity check

```sql
SELECT count(*) FROM host_capacity_metrics;
SELECT count(*) FROM cluster_capacity_metrics;
SELECT count(*) FROM cluster_ha_capacity_metrics;
SELECT count(*) FROM datastore_capacity_metrics;
```

> A count of **0** in `cluster_ha_capacity_metrics` is **normal** if no cluster uses HA Admission
> Control with a "host failures tolerated" policy. It is **not** a failure.

---

## 6. Reading the logs

The collector prints structured, greppable markers:

```
[Run]    Started Local: 2026-06-09T01:00:00+08:00
[Timing] Config + validation: 0.3s
[Timing] vCenter connect: 3.4s
[Timing] Metric collection: 41.2s
[Timing] DB writes + finalize: 2.1s
[Timing] Total runtime: 48.9s
[Rows]   host=120, cluster=8, cluster_ha=5, datastore=22, total=155
[Advice] Total rows (12000) reached threshold (10000). Consider batched inserts or COPY staging...
```

| Marker | Meaning | Watch for |
|--------|---------|-----------|
| `[Run]` | Start time in server local timezone | Did it run at the expected time? |
| `[Timing]` | Duration of each phase | A phase trending much slower than usual |
| `[Rows]` | How many rows were written per group | A sudden drop to 0 (collection problem) |
| `[Advice]` | Heads-up that the run is getting large | Performance — flag to the engineering owner |

> Where the log lives depends on the schedule setup (e.g. `>> /var/log/vmware-capacity.log` in cron).

---

## 7. Understanding the numbers

The values are **usable capacity**, not raw hardware totals — so they may look lower than vCenter's
headline numbers. That's by design. The rules:

- **Reserved per host:** 4 physical cores and 16 GB RAM are held back (overhead/headroom).
- **CPU overcommit:** uses the cluster's DRS `MaxVcpusPerCore` setting when present; otherwise **1:1**.
- **Excluded from counts:** hosts in maintenance mode or powered off, and `vCLS` system VMs.
- **HA-adjusted:** subtracts the capacity of the largest host(s) that could fail, per the cluster's
  "host failures tolerated" level — showing headroom if a failover happened.

### Status thresholds

Each host/cluster/datastore gets a status from its used %:

| Used % | Status |
|--------|--------|
| ≥ 100% | **Overallocated** |
| ≥ 90% | **Critical** |
| ≥ 75% | **Warning** |
| < 75% | **Healthy** |

These thresholds also drive the colour cues in Grafana.

---

## 8. The Grafana dashboards

> **Live test-lab dashboard:** `http://LAB_GRAFANA_URL/d/cap0v/vmware-capacity-overview?orgId=1&from=now-30d&to=now&timezone=Asia%2FKuala_Lumpur&refresh=5m`
> Opens the Overview board for the last 30 days, refreshing every 5 min. Pick vCenter,
> cluster, host and datastore from the dropdowns once it loads.
> Substitute `LAB_GRAFANA_URL` with your lab Grafana host:port - it is deliberately not
> stored in this repo - and be on the lab network/VPN to reach it.

Two dashboards read live from PostgreSQL:

| Dashboard | Use for |
|-----------|---------|
| **VMware Capacity Overview** | Day-to-day: select one vCenter / cluster / host / datastore and drill in |
| **VMware Capacity Overview (Repeated Panels)** | Compare **many** clusters/hosts/datastores side by side |

### Panels on the Overview dashboard

- **Overview vCPU Capacity / vCPU Used** and **Memory Capacity / Memory Used** — current totals (Stat panels)
- **Overview vCPU Trend** / **Overview Memory Trend** — usage over time (the key planning views)
- **Cluster Utilization %** and **Cluster Capacity vs Used** — for the selected cluster
- **Host Utilization %** and **Host Capacity vs Used** — for the selected host
- **Datastore Summary (Latest)** — table of all datastores with status
- **Datastore Used % Trend** — for the selected datastore

### Dropdown filters (template variables)

| Dropdown | Selects | Notes |
|----------|---------|-------|
| **vCenter** | Which vCenter | Choose this first |
| **Cluster** | Cluster within the chosen vCenter | List updates after vCenter is picked |
| **Host** | Host within the chosen cluster | List updates after cluster is picked |
| **Datastore** | Datastore within the chosen vCenter | |

These **cascade** — pick vCenter → cluster → host. Use the **time range** control (top-right) to move
between "last 24h" and "last 90 days," etc.

### Timezone

- Data is stored in **UTC** (`snapshot_ts_utc`).
- Dashboards are set to display **Asia/Kuala_Lumpur (UTC+8)**.

> If a timestamp looks 8 hours off, check the dashboard timezone — the stored data is intentionally UTC.

---

## 9. Troubleshooting

### Always start here

```sql
SELECT status, error_message, started_at_utc, completed_at_utc
FROM capacity_collection_runs
ORDER BY started_at_utc DESC LIMIT 5;
```

- `failed` → the `error_message` points to the category (below).
- `running` but hours old → the process died; check the log file. Safe to re-run.
- **No new row at all** → the **scheduler** didn't fire (cron / Task Scheduler) — check that first.

### Common failures and fixes

| Symptom (log / `error_message`) | Likely cause | What to do |
|---------------------------------|--------------|------------|
| `Secret file not found: …` | Secret path wrong or file moved/renamed | Check `VCPasswordFile` / `PGPasswordFile` paths in the config |
| `PowerCLI module is not installed.` | PowerCLI missing on the host | Install `VMware.PowerCLI` or `VCF.PowerCLI` |
| vCenter login / `Connect-VIServer` failure | Bad service-account creds, or vCenter unreachable | Verify the account & network path to vCenter |
| `Missing required setting: X …` | A required value is blank | Fill `X` in the config or pass `-X` on the CLI |
| `psql command failed with exit code …` | DB unreachable, wrong DB creds, or `psql` not on PATH | Test DB connectivity; confirm `psql` is installed/on PATH |
| Run stuck on `running` | Process killed mid-run | Re-run; the transaction guarantees no partial data |
| Dashboard shows "No data" | Time range too narrow, or datasource misconfigured | Widen the time range; check Grafana's PostgreSQL datasource |
| Timestamps look 8h off | Timezone display | Confirm dashboard timezone = `Asia/Kuala_Lumpur` |
| `cluster_ha` rows = 0 | No HA "host failures tolerated" policy | Expected behaviour — not an error |

### Re-running safely

- A failed/partial run leaves **no half-written data** (single transaction).
- To retry: run the collector again — it gets a fresh `run_id`.
- To reprocess a **specific** snapshot without duplicates: re-run with the **same** `-RunId`
  (composite primary keys + `ON CONFLICT DO NOTHING` block duplicates).

> Rule of thumb: when in doubt, re-run. It's idempotent.

---

## 10. Maintenance

| Task | When | How |
|------|------|-----|
| Check the daily run | Every morning | Query `capacity_collection_runs` |
| Rotate a password | On credential change | Overwrite the secret `.txt` file (value only), keep `chmod 600`, then run once by hand |
| Change the schedule | As needed | Edit the cron entry / Task Scheduler task |
| Update connection details | On infra change | Edit `collector-config.psd1` |
| Data retention / disk | Automatic | TimescaleDB deletes data >24 months and compresses data >30 days |

### Rotating a password

```bash
printf '%s' 'new_password_here' > /opt/vmware-capacity/secrets/vc_password.txt
chmod 600 /opt/vmware-capacity/secrets/vc_password.txt
```

Then run the collector once manually to confirm authentication still works.
**Never** put passwords directly in `collector-config.psd1`.

### The scheduled job

This is what makes the collector run *daily*. Point your scheduler at `capacityutilization.ps1` —
the one-time `init-db.ps1` is **never** scheduled.

**Linux (cron — runs 01:00 daily, logs to a file):**
```cron
# m h dom mon dow   command
0 1 * * * /usr/bin/pwsh /opt/vmware-capacity/capacityutilization.ps1 \
  -ConfigFile /opt/vmware-capacity/collector-config.psd1 \
  >> /var/log/vmware-capacity.log 2>&1
```

**Windows (Task Scheduler — register a daily task):**
```powershell
$action = New-ScheduledTaskAction -Execute "pwsh.exe" `
  -Argument "-File C:\vmware-capacity\capacityutilization.ps1 -ConfigFile C:\vmware-capacity\collector-config.psd1"
$trigger = New-ScheduledTaskTrigger -Daily -At 1:00AM
Register-ScheduledTask -TaskName "VMware Capacity Collector" `
  -Action $action -Trigger $trigger -RunLevel Highest -User "SYSTEM"
```

> If the morning check shows no new run row, suspect the scheduler first.

### Health checklist

- [ ] A new `success` row appears each morning
- [ ] Row counts look normal (no unexplained drop to 0)
- [ ] `[Timing] Total runtime` isn't trending sharply upward
- [ ] Dashboards show fresh data for "last 24h"
- [ ] Secret files intact, permissions `600`
- [ ] No unexplained `failed` runs

---

## 11. Quick reference (cheat sheet)

**Run manually**
```bash
pwsh ./capacityutilization.ps1 -ConfigFile /opt/vmware-capacity/collector-config.psd1 -ShowConsoleSummary
```

**Did it work? (run this every morning)**
```sql
SELECT run_id, status, started_at_utc, host_rows, cluster_rows, cluster_ha_rows, datastore_rows
FROM capacity_collection_runs ORDER BY started_at_utc DESC LIMIT 10;
```

**Why did it fail?**
```sql
SELECT status, error_message, started_at_utc
FROM capacity_collection_runs WHERE status = 'failed'
ORDER BY started_at_utc DESC LIMIT 5;
```

**Status thresholds:** ≥100 Overallocated · ≥90 Critical · ≥75 Warning · <75 Healthy
**Timezone:** stored UTC, displayed Asia/Kuala_Lumpur (UTC+8)
**Retention:** 24 months · **Compression:** >30 days · **Both automatic**
**Re-running is always safe** (transactional + idempotent).

---

## 12. Glossary

| Term | Meaning |
|------|---------|
| **vCenter** | VMware's central management server; the data source |
| **Cluster** | A group of hosts managed together (DRS/HA) |
| **Host (compute)** | A physical ESXi server running VMs |
| **Datastore** | Storage where VM files live |
| **DRS** | Distributed Resource Scheduler — balances VMs across hosts |
| **HA** | High Availability — restarts VMs elsewhere if a host fails |
| **Admission Control** | HA setting that reserves capacity for failover |
| **Overcommit** | Allocating more vCPU than physical cores (ratio from `MaxVcpusPerCore`) |
| **vCLS** | vSphere Cluster Services system VMs (excluded from counts) |
| **Snapshot (here)** | One full set of capacity readings from a single run |
| **run_id** | Unique ID tying together all rows from one execution |
| **Hypertable** | A TimescaleDB table optimized for time-stamped data |
| **Retention policy** | Auto-deletes data older than a set age (24 months) |
| **Compression policy** | Auto-compresses data older than a set age (30 days) |
| **Idempotent** | Re-running produces no duplicates / no harm |
| **psql** | PostgreSQL command-line client |
| **PowerCLI** | VMware's PowerShell module |

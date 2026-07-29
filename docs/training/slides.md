---
marp: true
theme: default
paginate: true
size: 16:9
header: 'VMware Capacity Collector — Support Team Training'
footer: 'Internal use only'
---

<!-- _class: lead -->
<!-- _paginate: false -->

# VMware Capacity Collector
## End-to-End Training for the Support Team

How to **use**, **manage**, and **maintain** the daily capacity pipeline and Grafana dashboards.

*Presenter:* ____________  ·  *Date:* ____________

---

# Agenda

1. **Objective** — what problem this solves
2. **The tech stack** — what each piece does
3. **How it fits together** — the architecture
4. **Setup** — one-time install (reference)
5. **Daily use** — running & checking a collection
6. **Reading the logs** — Timing / Rows / Advice
7. **The dashboards** — how to read them
8. **Troubleshooting** — the failures you'll actually see
9. **Maintenance** — secrets, schedule, health checks
10. **Live demo** + Q&A

---

<!-- _class: lead -->

# 1. Objective

---

# What this system does

- vCenter shows capacity **right now** — but not **trends over time**.
- This system takes a **daily snapshot** of capacity and stores it in a database.
- Grafana then shows **trends**: *"Is this cluster filling up? When will it run out?"*

**Goal:** turn point-in-time vCenter numbers into a historical record we can chart and act on.

It collects, per run:
- **Per host** — CPU & RAM capacity vs. allocation
- **Per cluster** — totals & utilization %
- **Cluster HA-adjusted** — headroom if a host fails
- **Datastore** — capacity & usage

---

# Why it matters to support

- **Capacity planning** — see a cluster trending toward full *before* it's full.
- **Incident context** — "was this datastore already 95% last week?"
- **Reporting** — historical % usage for management.
- **No manual work** — it runs itself on a schedule; you mostly **monitor & troubleshoot**.

Your job after this training: keep the daily job healthy and help people read the dashboards.

---

<!-- _class: lead -->

# 2. The Tech Stack

---

# The five technologies

| Tech | What it is | Role here |
|------|-----------|-----------|
| **PowerShell 7** | Scripting language | Runs the collector script |
| **VMware PowerCLI** | PowerShell module for VMware | Talks to vCenter, reads the numbers |
| **PostgreSQL** | Relational database | Stores every snapshot |
| **TimescaleDB** | Time-series add-on for Postgres | Makes time queries fast + auto-cleanup |
| **Grafana** | Dashboard tool | Charts the data for humans |
| **psql** | Postgres command-line client | How the script writes to the DB |

---

# Brief intro — PowerShell & PowerCLI

**PowerShell 7**
- Microsoft's modern, cross-platform scripting shell.
- Our collector is one `.ps1` script.

**VMware PowerCLI**
- A set of PowerShell commands (e.g. `Connect-VIServer`, `Get-Cluster`, `Get-VMHost`).
- The script uses it to **log in to vCenter read-only** and pull host/cluster/datastore data.
- Either `VMware.PowerCLI` **or** `VCF.PowerCLI` must be installed.

> Think of PowerCLI as "the API into vCenter, in PowerShell form."

---

# Brief intro — PostgreSQL & TimescaleDB

**PostgreSQL**
- A widely-used open-source SQL database. Data lives in **tables** (rows & columns).

**TimescaleDB**
- An extension that turns normal tables into **hypertables** optimized for time-stamped data.
- Gives us two automatic housekeeping jobs:
  - **Retention** — data older than **24 months** is auto-deleted.
  - **Compression** — data older than **30 days** is auto-compressed to save space.

> We don't manage these by hand — they run inside the database.

---

# Brief intro — Grafana & psql

**Grafana**
- A dashboard/visualization tool. It **reads** from PostgreSQL and draws charts.
- Grafana never changes the data — it's read-only display.

**psql**
- The official PostgreSQL command-line client.
- The collector script shells out to `psql` to run its `INSERT` statements.
- Must be **on the PATH** of the machine running the script.

---

<!-- _class: lead -->

# 3. How It Fits Together

---

# The architecture

```
   ┌──────────┐   PowerCLI    ┌───────────────────────┐    psql     ┌──────────────────────┐    SQL    ┌─────────┐
   │ vCenter  │ ────────────▶ │ capacityutilization.ps1│ ─────────▶ │ PostgreSQL +          │ ◀──────── │ Grafana │
   │ (source) │   read-only   │  (daily collector)     │   INSERT   │ TimescaleDB (storage) │   read    │ (charts)│
   └──────────┘               └───────────────────────┘            └──────────────────────┘           └─────────┘
        ▲                              │
        │  service account             │  runs on a schedule (cron / Task Scheduler)
        └──────────────────────────────┘
```

**One run = one snapshot = one `run_id`.** Everything from a single execution is tied to that ID.

---

# The files in the project

| File | What it's for | How often touched |
|------|---------------|-------------------|
| `capacityutilization.ps1` | The collector (runs daily) | Every run |
| `collector-config.psd1` | Connection settings + secret paths | When something changes |
| `db/init_timescale.sql` | Database schema & policies | One-time / rare |
| `scripts/init-db.ps1` | One-time DB setup runner | One-time / rare |
| secret files (`*.txt`) | vCenter & DB passwords | On password change |
| `grafana/*.json` | Dashboard definitions | One-time import |

---

# The database tables

| Table | What's in it |
|-------|--------------|
| `capacity_collection_runs` | **Audit log** — one row per run, with status & row counts |
| `host_capacity_metrics` | Per-host CPU/RAM per snapshot |
| `cluster_capacity_metrics` | Per-cluster totals per snapshot |
| `cluster_ha_capacity_metrics` | HA-adjusted headroom (only when HA policy supports it) |
| `datastore_capacity_metrics` | Per-datastore capacity & usage |

> **`capacity_collection_runs` is your best friend** — it tells you if last night's run worked.

---

<!-- _class: lead -->

# 4. Setup (One-Time Reference)

You won't do this daily — but you should know it exists.

---

# Setup at a glance

The environment is **already set up and running** (we'll use it in the demo). The one-time steps were:

1. **Create the database** and an app user in PostgreSQL.
2. **Enable TimescaleDB**: `CREATE EXTENSION timescaledb;`
3. **Create secret files** — one for the vCenter password, one for the DB password (`chmod 600`).
4. **Initialize the schema** — run `scripts/init-db.ps1` once (creates tables, hypertables, policies).
5. **Create the config file** — copy `collector-config.sample.psd1`, fill in connection details.
6. **Schedule the daily run** — cron (Linux) or Task Scheduler (Windows).
7. **Import the Grafana dashboards** and point them at the PostgreSQL datasource.

---

# Setup — initialize the database (once)

```bash
pwsh ./scripts/init-db.ps1 \
  -PGHost <db-host> -PGPort 5432 \
  -PGDatabase vmware_capacity \
  -PGUsername vmware_collector \
  -PGPasswordFile /opt/vmware-capacity/secrets/pg_password.txt
```

Creates: the 5 tables, hypertables, indexes, **24-month retention** and **30-day compression** policies.

> Safe to re-run — everything uses `IF NOT EXISTS`. But it's **change-managed**, not a daily task.

---

# Setup — the config file

`collector-config.psd1` holds connection info — **passwords stay in separate secret files**.

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

    VCenterName    = "Production-vCenter"   # optional friendly name
    BatchingThresholdRows = 10000           # advisory warning threshold
}
```

---

<!-- _class: lead -->

# 5. Daily Use

---

# Running a collection manually

Normal runs happen on a schedule. To run one by hand:

```bash
pwsh ./capacityutilization.ps1 -ConfigFile /opt/vmware-capacity/collector-config.psd1
```

Useful options:

| Option | What it does |
|--------|-------------|
| `-ShowConsoleSummary` | Print the capacity tables to the screen (great for demos) |
| `-RunId <id>` | Reuse an ID — re-running with the same ID **won't duplicate** data |
| `-VCenterName <name>` | Override the friendly name |
| `-BatchingThresholdRows <n>` | When to show the "large run" advisory |

> CLI values **override** the config file.

---

# What happens during a run

1. Loads config, validates required settings.
2. Marks a new run as **`running`** in `capacity_collection_runs`.
3. Connects to vCenter (read-only).
4. Walks every cluster → hosts → datastores, computing capacity.
5. Writes **all rows in one transaction**.
6. Marks the run **`success`** with row counts — or **`failed`** with an error message.

> Either the whole run lands, or it's marked failed. No half-written snapshots.

---

# Checking that a run succeeded

The first thing to check every morning — query the audit table:

```sql
SELECT run_id, status, started_at_utc, completed_at_utc,
       host_rows, cluster_rows, cluster_ha_rows, datastore_rows
FROM capacity_collection_runs
ORDER BY started_at_utc DESC
LIMIT 10;
```

- `status = 'success'` → all good.
- `status = 'failed'` → read the `error_message` column.
- `status = 'running'` (and old) → the run died mid-way; check logs.

---

# A quick "is there data?" sanity check

```sql
SELECT count(*) FROM host_capacity_metrics;
SELECT count(*) FROM cluster_capacity_metrics;
SELECT count(*) FROM cluster_ha_capacity_metrics;
SELECT count(*) FROM datastore_capacity_metrics;
```

> `cluster_ha_capacity_metrics` can legitimately be **0** — HA rows only appear when a cluster
> uses HA Admission Control with a "host failures tolerated" policy. **Not a bug.**

---

<!-- _class: lead -->

# 6. Reading the Logs

---

# The three log markers

The collector prints structured, greppable lines:

```
[Run]    Started Local: 2026-06-09T01:00:00+08:00
[Timing] vCenter connect: 3.4s
[Timing] Metric collection: 41.2s
[Timing] Total runtime: 48.9s
[Rows]   host=120, cluster=8, cluster_ha=5, datastore=22, total=155
[Advice] Total rows (12000) reached threshold (10000). Consider batched inserts...
```

| Marker | Meaning |
|--------|---------|
| `[Run]` | When the run started (server local time) |
| `[Timing]` | How long each phase took — watch for slow trends |
| `[Rows]` | How much data was written |
| `[Advice]` | Heads-up that the run is getting large (performance) |

---

# Capacity status thresholds

Every host/cluster/datastore gets a **status** based on used %:

| Used % | Status | Colour cue |
|--------|--------|-----------|
| ≥ 100% | **Overallocated** | 🔴 |
| ≥ 90% | **Critical** | 🟠 |
| ≥ 75% | **Warning** | 🟡 |
| < 75% | **Healthy** | 🟢 |

> These same thresholds drive the colours you'll see in Grafana.

---

# How capacity is calculated (the gist)

So you can answer "why is this number lower than vCenter shows?":

- **Reserved per host:** 4 physical cores + 16 GB RAM are held back (overhead/headroom).
- **CPU overcommit:** uses the cluster's DRS `MaxVcpusPerCore` if set, else **1:1**.
- **Excluded:** hosts in maintenance / powered-off, and `vCLS` system VMs.
- **HA-adjusted:** subtracts the capacity of the largest host(s) that could fail.

> The numbers are **usable capacity**, not raw hardware totals — by design.

---

<!-- _class: lead -->

# 7. The Dashboards

---

# Two dashboards

| Dashboard | Use it for |
|-----------|-----------|
| **VMware Capacity Overview** | Day-to-day: pick one vCenter/cluster/host/datastore and drill in |
| **VMware Capacity Overview (Repeated Panels)** | Compare **many** clusters/hosts/datastores side by side |

Both read live from PostgreSQL — no extra steps.

**Live test-lab board:** `http://LAB_GRAFANA_URL/d/cap0v/vmware-capacity-overview?orgId=1&from=now-30d&to=now&timezone=Asia%2FKuala_Lumpur&refresh=5m` — *substitute your lab Grafana host:port; needs lab network/VPN.*

---

# Overview dashboard — what's on it

- **Overview vCPU / Memory Capacity & Used** — current totals (Stat panels)
- **Overview vCPU / Memory Trend** — usage over time (the key planning view)
- **Cluster Utilization %** & **Capacity vs Used** — for the selected cluster
- **Host Utilization %** & **Capacity vs Used** — for the selected host
- **Datastore Summary (Latest)** — table of all datastores
- **Datastore Used % Trend** — for the selected datastore

---

# Using the dropdown filters

Top of the dashboard has **template variables** (dropdowns):

| Dropdown | Picks |
|----------|-------|
| **vCenter** | Which vCenter to view |
| **Cluster** | Cluster within that vCenter |
| **Host** | Host within that cluster |
| **Datastore** | Datastore within that vCenter |

> They **cascade**: choose a vCenter first, then the cluster list updates, then hosts.
> Use the **time range** (top-right) to zoom from "last 24h" to "last 90 days".

---

# Timezone note (important!)

- Data is stored in **UTC** (`snapshot_ts_utc`).
- Grafana dashboards are set to display **Asia/Kuala_Lumpur (UTC+8)**.

> If a timestamp looks "8 hours off," check the dashboard timezone setting first —
> the data isn't wrong, it's stored in UTC on purpose.

---

<!-- _class: lead -->

# 8. Troubleshooting

The failures you'll actually see — and what to do.

---

# Troubleshooting flow

**Step 1 — always start here:**

```sql
SELECT status, error_message, started_at_utc, completed_at_utc
FROM capacity_collection_runs
ORDER BY started_at_utc DESC LIMIT 5;
```

- `failed` → the `error_message` tells you the category.
- `running` but hours old → process died; check the run log file.
- No new row at all → the **scheduler** didn't fire (cron/Task Scheduler).

---

# Common failures & fixes (1/2)

| Symptom in `error_message` / log | Likely cause | Fix |
|----------------------------------|--------------|-----|
| `Secret file not found` | Wrong path / file moved | Check `*PasswordFile` paths in config |
| `PowerCLI module is not installed` | Module missing on host | Install `VMware.PowerCLI` or `VCF.PowerCLI` |
| `Connect-VIServer` / login failed | Bad vCenter creds or vCenter down | Verify service account & vCenter reachable |
| `Missing required setting: X` | Config value blank | Fill `X` in config or pass via CLI |

---

# Common failures & fixes (2/2)

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `psql command failed` | DB unreachable / wrong creds / `psql` not on PATH | Test connectivity; confirm `psql` installed |
| Run stuck on `running` | Process killed mid-run | Safe to re-run; transaction means no partial data |
| Dashboard empty | No data for time range, or wrong datasource | Widen time range; check Grafana datasource |
| Timestamps "8h off" | Timezone display | Confirm dashboard TZ = `Asia/Kuala_Lumpur` |

---

# Re-running safely

- A failed or partial run leaves **no half-written data** (one transaction).
- To retry: just run the collector again — it generates a fresh `run_id`.
- To **reprocess a specific snapshot** without duplicates: re-run with the **same** `-RunId`
  (composite keys + `ON CONFLICT DO NOTHING` prevent duplicates).

> When in doubt: re-run. It's safe and idempotent.

---

<!-- _class: lead -->

# 9. Maintenance

---

# Routine maintenance tasks

| Task | When | How |
|------|------|-----|
| **Check daily run** | Every morning | Query `capacity_collection_runs` |
| **Rotate secrets** | On password change | Update the secret `.txt` file (value only) |
| **Change schedule** | As needed | Edit cron / Task Scheduler entry |
| **Update config** | Connection changes | Edit `collector-config.psd1` |
| **Disk/retention** | Automatic | Timescale auto-deletes >24mo, compresses >30d |

> Retention & compression are **hands-off** — the database manages them.

---

# Rotating a password (example)

vCenter or DB password changed? Update only the secret file — **never** put passwords in the config.

**Linux:**
```bash
printf '%s' 'new_password_here' > /opt/vmware-capacity/secrets/vc_password.txt
chmod 600 /opt/vmware-capacity/secrets/vc_password.txt
```

**Windows (PowerShell):**
```powershell
Set-Content -NoNewline C:\vmware-capacity\secrets\vc_password.txt 'new_password_here'
```

Then run the collector once by hand to confirm it still authenticates.

> Secret files must stay readable only by the run account (`600` / restricted ACL).

---

# The scheduled job — Linux (cron)

What makes it *daily*. Point the scheduler at `capacityutilization.ps1` — never at `init-db.ps1`.

Runs 1 AM daily, logs to a file:

```cron
# m h dom mon dow   command
0 1 * * * /usr/bin/pwsh /opt/vmware-capacity/capacityutilization.ps1 \
  -ConfigFile /opt/vmware-capacity/collector-config.psd1 \
  >> /var/log/vmware-capacity.log 2>&1
```

> If a morning check shows **no new run row**, suspect the scheduler first.

---

# The scheduled job — Windows (Task Scheduler)

Register an equivalent daily task in PowerShell:

```powershell
$action = New-ScheduledTaskAction -Execute "pwsh.exe" `
  -Argument "-File C:\vmware-capacity\capacityutilization.ps1 -ConfigFile C:\vmware-capacity\collector-config.psd1"
$trigger = New-ScheduledTaskTrigger -Daily -At 1:00AM
Register-ScheduledTask -TaskName "VMware Capacity Collector" `
  -Action $action -Trigger $trigger -RunLevel Highest -User "SYSTEM"
```

> Same idea as cron: `pwsh.exe` runs the collector once a day with the config file.

---

# Health checklist (pin this)

✅ A new `success` row appears each morning
✅ Row counts look normal (no sudden drop to 0)
✅ `[Timing] Total runtime` isn't trending way up
✅ Dashboards show fresh data for "last 24h"
✅ Secret files intact with `600` permissions
✅ No `failed` runs unexplained

---

<!-- _class: lead -->

# 10. Live Demo

---

# Demo walkthrough

We'll use the **already-running test environment**:

1. **Run the collector** with `-ShowConsoleSummary` and watch the `[Timing]` / `[Rows]` lines.
2. **Query `capacity_collection_runs`** — see the new `success` row.
3. **Open the Overview dashboard** — pick a vCenter → cluster → host.
4. **Read a trend panel** — point out a cluster's usage over time.
5. **Read a status colour** — tie it back to the 75/90/100 thresholds.
6. *(Optional)* **Simulate a failure** — bad password → show `failed` + `error_message`.

---

<!-- _class: lead -->

# Q&A

---

# Key takeaways

- It's a **daily snapshot pipeline**: vCenter → PowerShell → PostgreSQL/Timescale → Grafana.
- **`capacity_collection_runs` is your morning check** — `success` = healthy.
- Numbers are **usable capacity** (reservations + exclusions), not raw totals.
- Statuses follow **75 / 90 / 100%** thresholds.
- Re-running is **always safe** (transactional + idempotent).
- Retention/compression are **automatic**.

**Full details:** see the companion `TRAINING.md` reference.

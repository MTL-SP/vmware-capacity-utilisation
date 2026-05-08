CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE IF NOT EXISTS capacity_collection_runs (
    run_id TEXT PRIMARY KEY,
    vcenter_name TEXT NOT NULL,
    started_at_utc TIMESTAMPTZ NOT NULL,
    completed_at_utc TIMESTAMPTZ,
    snapshot_ts_utc TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL,
    script_version TEXT NOT NULL,
    host_rows INT DEFAULT 0,
    cluster_rows INT DEFAULT 0,
    cluster_ha_rows INT DEFAULT 0,
    datastore_rows INT DEFAULT 0,
    error_message TEXT
);

CREATE TABLE IF NOT EXISTS host_capacity_metrics (
    snapshot_ts_utc TIMESTAMPTZ NOT NULL,
    run_id TEXT NOT NULL,
    vcenter_name TEXT NOT NULL,
    script_version TEXT NOT NULL,
    cluster_name TEXT NOT NULL,
    compute_name TEXT NOT NULL,
    sockets INT,
    cores_per_socket INT,
    physical_cores INT,
    reserved_cores INT,
    usable_cpu_cores INT,
    overcommit_ratio TEXT,
    allowed_vcpu NUMERIC,
    allocated_vcpu NUMERIC,
    available_vcpu NUMERIC,
    cpu_used_pct NUMERIC,
    cpu_status TEXT,
    total_ram_gb NUMERIC,
    reserved_ram_gb NUMERIC,
    usable_ram_gb NUMERIC,
    allocated_ram_gb NUMERIC,
    available_ram_gb NUMERIC,
    ram_used_pct NUMERIC,
    ram_status TEXT,
    powered_on_vm_count INT,
    PRIMARY KEY (snapshot_ts_utc, run_id, cluster_name, compute_name)
);

CREATE TABLE IF NOT EXISTS cluster_capacity_metrics (
    snapshot_ts_utc TIMESTAMPTZ NOT NULL,
    run_id TEXT NOT NULL,
    vcenter_name TEXT NOT NULL,
    script_version TEXT NOT NULL,
    cluster_name TEXT NOT NULL,
    drs_enabled BOOLEAN,
    ha_enabled BOOLEAN,
    admission_control_enabled BOOLEAN,
    compute_count INT,
    total_allowed_vcpu NUMERIC,
    total_allocated_vcpu NUMERIC,
    total_available_vcpu NUMERIC,
    cpu_used_pct NUMERIC,
    total_usable_ram_gb NUMERIC,
    total_allocated_ram_gb NUMERIC,
    total_available_ram_gb NUMERIC,
    ram_used_pct NUMERIC,
    PRIMARY KEY (snapshot_ts_utc, run_id, cluster_name)
);

CREATE TABLE IF NOT EXISTS cluster_ha_capacity_metrics (
    snapshot_ts_utc TIMESTAMPTZ NOT NULL,
    run_id TEXT NOT NULL,
    vcenter_name TEXT NOT NULL,
    script_version TEXT NOT NULL,
    cluster_name TEXT NOT NULL,
    drs_enabled BOOLEAN,
    ha_enabled BOOLEAN,
    admission_control_enabled BOOLEAN,
    host_failures_tolerated INT,
    total_allowed_vcpu NUMERIC,
    ha_reserved_vcpu NUMERIC,
    effective_vcpu NUMERIC,
    allocated_vcpu NUMERIC,
    available_vcpu_after_ha NUMERIC,
    cpu_used_pct_after_ha NUMERIC,
    total_usable_ram_gb NUMERIC,
    ha_reserved_ram_gb NUMERIC,
    effective_ram_gb NUMERIC,
    allocated_ram_gb NUMERIC,
    available_ram_after_ha NUMERIC,
    ram_used_pct_after_ha NUMERIC,
    PRIMARY KEY (snapshot_ts_utc, run_id, cluster_name)
);

CREATE TABLE IF NOT EXISTS datastore_capacity_metrics (
    snapshot_ts_utc TIMESTAMPTZ NOT NULL,
    run_id TEXT NOT NULL,
    vcenter_name TEXT NOT NULL,
    script_version TEXT NOT NULL,
    datastore_id TEXT NOT NULL,
    datastore_name TEXT NOT NULL,
    type TEXT,
    capacity_tb NUMERIC,
    used_tb NUMERIC,
    free_tb NUMERIC,
    used_pct NUMERIC,
    status TEXT,
    PRIMARY KEY (snapshot_ts_utc, run_id, datastore_id)
);

SELECT create_hypertable('host_capacity_metrics', 'snapshot_ts_utc', if_not_exists => TRUE);
SELECT create_hypertable('cluster_capacity_metrics', 'snapshot_ts_utc', if_not_exists => TRUE);
SELECT create_hypertable('cluster_ha_capacity_metrics', 'snapshot_ts_utc', if_not_exists => TRUE);
SELECT create_hypertable('datastore_capacity_metrics', 'snapshot_ts_utc', if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS idx_host_cluster_compute_ts
ON host_capacity_metrics (cluster_name, compute_name, snapshot_ts_utc DESC);

CREATE INDEX IF NOT EXISTS idx_cluster_name_ts
ON cluster_capacity_metrics (cluster_name, snapshot_ts_utc DESC);

CREATE INDEX IF NOT EXISTS idx_cluster_ha_name_ts
ON cluster_ha_capacity_metrics (cluster_name, snapshot_ts_utc DESC);

CREATE INDEX IF NOT EXISTS idx_datastore_name_id_ts
ON datastore_capacity_metrics (datastore_name, datastore_id, snapshot_ts_utc DESC);

ALTER TABLE host_capacity_metrics SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'cluster_name,compute_name'
);
ALTER TABLE cluster_capacity_metrics SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'cluster_name'
);
ALTER TABLE cluster_ha_capacity_metrics SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'cluster_name'
);
ALTER TABLE datastore_capacity_metrics SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'datastore_id,datastore_name'
);

SELECT add_retention_policy('host_capacity_metrics', INTERVAL '24 months', if_not_exists => TRUE);
SELECT add_retention_policy('cluster_capacity_metrics', INTERVAL '24 months', if_not_exists => TRUE);
SELECT add_retention_policy('cluster_ha_capacity_metrics', INTERVAL '24 months', if_not_exists => TRUE);
SELECT add_retention_policy('datastore_capacity_metrics', INTERVAL '24 months', if_not_exists => TRUE);

SELECT add_compression_policy('host_capacity_metrics', INTERVAL '30 days', if_not_exists => TRUE);
SELECT add_compression_policy('cluster_capacity_metrics', INTERVAL '30 days', if_not_exists => TRUE);
SELECT add_compression_policy('cluster_ha_capacity_metrics', INTERVAL '30 days', if_not_exists => TRUE);
SELECT add_compression_policy('datastore_capacity_metrics', INTERVAL '30 days', if_not_exists => TRUE);

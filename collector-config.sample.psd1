@{
    VCServer = "vcenter.example.local"
    VCUsername = "svc-vcenter-readonly"
    VCPasswordFile = "/opt/vmware-capacity/secrets/vc_password.txt"

    PGHost = "db.example.local"
    PGPort = 5432
    PGDatabase = "vmware_capacity"
    PGUsername = "vmware_collector"
    PGPasswordFile = "/opt/vmware-capacity/secrets/pg_password.txt"

    # Optional. Defaults to VCServer if omitted.
    VCenterName = "Production-vCenter"

    # Optional advisory threshold for future DB batching/COPY migration.
    # If total rows collected in a run >= this value, the script logs a warning.
    BatchingThresholdRows = 10000

    # Optional. Used only by scripts/capacity-request-watcher.ps1 (manual refresh button).
    # MinIntervalMinutes: skip a manual request if a run already succeeded this recently.
    # InFlightTimeoutMinutes: how long a 'running' run blocks new manual runs before it is
    #   treated as stale (guards against a crashed collector wedging the watcher).
    # CollectorScript: defaults to capacityutilization.ps1 next to the scripts/ folder.
    MinIntervalMinutes = 2
    InFlightTimeoutMinutes = 120
    CollectorScript = "/opt/vmware-capacity/capacityutilization.ps1"
}

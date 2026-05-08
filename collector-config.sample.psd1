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
}

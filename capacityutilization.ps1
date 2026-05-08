param(
    [string]$ConfigFile = "",
    [string]$VCServer = "",
    [string]$VCUsername = "",
    [string]$VCPasswordFile,
    [string]$PGHost = "",
    [Nullable[int]]$PGPort = $null,
    [string]$PGDatabase = "",
    [string]$PGUsername = "",
    [string]$PGPasswordFile,
    [string]$VCenterName = "",
    [string]$RunId = "",
    [string]$ScriptVersion = "2.0.0",
    [switch]$ShowConsoleSummary
)

$ErrorActionPreference = "Stop"

$ReservedPhysicalCoresPerHost = 4
$ReservedRAMGBPerHost = 16

function Read-SecretFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Secret file not found: $Path"
    }

    return (Get-Content -LiteralPath $Path -Raw).Trim()
}

function Resolve-ConfigValue {
    param(
        [hashtable]$Config,
        [string]$Key,
        $CurrentValue
    )

    if ($null -ne $CurrentValue) {
        if ($CurrentValue -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
                return $CurrentValue
            }
        }
        else {
            return $CurrentValue
        }
    }

    if ($Config -and $Config.ContainsKey($Key)) {
        return $Config[$Key]
    }

    return $CurrentValue
}

function Validate-RequiredValue {
    param(
        [string]$Name,
        $Value
    )

    if ($null -eq $Value) {
        throw "Missing required setting: $Name. Provide it via -$Name or ConfigFile."
    }

    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        throw "Missing required setting: $Name. Provide it via -$Name or ConfigFile."
    }
}

function ConvertTo-PgValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return "NULL"
    }

    if ($Value -is [bool]) {
        if ($Value) { return "TRUE" } else { return "FALSE" }
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [datetime]) {
        return "'" + $Value.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ssK") + "'"
    }

    $Escaped = $Value.ToString().Replace("'", "''")
    return "'$Escaped'"
}

function Invoke-Psql {
    param(
        [string]$Sql,
        [string]$Password
    )

    $sqlFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $sqlFile -Value $Sql -NoNewline
        $env:PGPASSWORD = $Password
        & psql `
            -h $PGHost `
            -p $PGPort `
            -U $PGUsername `
            -d $PGDatabase `
            -v ON_ERROR_STOP=1 `
            -f $sqlFile | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "psql command failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Remove-Item -LiteralPath $sqlFile -Force -ErrorAction SilentlyContinue
        $env:PGPASSWORD = $null
    }
}

function Get-UsageStatus {
    param([double]$UsedPct)

    if ($UsedPct -ge 100) { return "Overallocated" }
    elseif ($UsedPct -ge 90) { return "Critical" }
    elseif ($UsedPct -ge 75) { return "Warning" }
    else { return "Healthy" }
}

function Get-HAInfo {
    param($ClusterView)

    $haEnabled = $false
    $admissionEnabled = $false
    $hostFailuresTolerated = $null
    $policyType = "Unknown"

    if ($ClusterView.ConfigurationEx -and $ClusterView.ConfigurationEx.DasConfig) {
        $das = $ClusterView.ConfigurationEx.DasConfig
        $haEnabled = [bool]$das.Enabled
        $admissionEnabled = [bool]$das.AdmissionControlEnabled
        if ($das.AdmissionControlPolicy) {
            $policyType = $das.AdmissionControlPolicy.GetType().Name
            if ($das.AdmissionControlPolicy.PSObject.Properties["FailoverLevel"]) {
                $hostFailuresTolerated = [int]$das.AdmissionControlPolicy.FailoverLevel
            }
        }
    }

    [pscustomobject]@{
        HAEnabled               = $haEnabled
        AdmissionControlEnabled = $admissionEnabled
        PolicyType              = $policyType
        HostFailuresTolerated   = $hostFailuresTolerated
    }
}

function Build-InsertSql {
    param(
        [string]$TableName,
        [string[]]$Columns,
        [array]$Rows
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        return ""
    }

    $valueRows = foreach ($row in $Rows) {
        $vals = foreach ($col in $Columns) {
            ConvertTo-PgValue -Value $row.$col
        }
        "(" + ($vals -join ", ") + ")"
    }

    return "INSERT INTO $TableName (" + ($Columns -join ", ") + ") VALUES " + ($valueRows -join ",`n") + " ON CONFLICT DO NOTHING;"
}

$viServer = $null
$pgPassword = $null
$status = "failed"
$errorMessage = $null
$hostResults = @()
$clusterResults = @()
$clusterHAResults = @()
$datastoreResults = @()

try {
    $collectorConfig = $null
    if (-not [string]::IsNullOrWhiteSpace($ConfigFile)) {
        if (-not (Test-Path -LiteralPath $ConfigFile)) {
            throw "Config file not found: $ConfigFile"
        }

        $resolvedConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path
        $collectorConfig = Import-PowerShellDataFile -LiteralPath $resolvedConfigFile
    }

    $VCServer = Resolve-ConfigValue -Config $collectorConfig -Key "VCServer" -CurrentValue $VCServer
    $VCUsername = Resolve-ConfigValue -Config $collectorConfig -Key "VCUsername" -CurrentValue $VCUsername
    $VCPasswordFile = Resolve-ConfigValue -Config $collectorConfig -Key "VCPasswordFile" -CurrentValue $VCPasswordFile
    $PGHost = Resolve-ConfigValue -Config $collectorConfig -Key "PGHost" -CurrentValue $PGHost
    $PGPort = Resolve-ConfigValue -Config $collectorConfig -Key "PGPort" -CurrentValue $PGPort
    $PGDatabase = Resolve-ConfigValue -Config $collectorConfig -Key "PGDatabase" -CurrentValue $PGDatabase
    $PGUsername = Resolve-ConfigValue -Config $collectorConfig -Key "PGUsername" -CurrentValue $PGUsername
    $PGPasswordFile = Resolve-ConfigValue -Config $collectorConfig -Key "PGPasswordFile" -CurrentValue $PGPasswordFile
    $VCenterName = Resolve-ConfigValue -Config $collectorConfig -Key "VCenterName" -CurrentValue $VCenterName

    Validate-RequiredValue -Name "VCServer" -Value $VCServer
    Validate-RequiredValue -Name "VCUsername" -Value $VCUsername
    Validate-RequiredValue -Name "VCPasswordFile" -Value $VCPasswordFile
    Validate-RequiredValue -Name "PGHost" -Value $PGHost
    Validate-RequiredValue -Name "PGPort" -Value $PGPort
    Validate-RequiredValue -Name "PGDatabase" -Value $PGDatabase
    Validate-RequiredValue -Name "PGUsername" -Value $PGUsername
    Validate-RequiredValue -Name "PGPasswordFile" -Value $PGPasswordFile
    $PGPort = [int]$PGPort

    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI) -and -not (Get-Module -ListAvailable -Name VCF.PowerCLI)) {
        throw "PowerCLI module is not installed."
    }

    if (Get-Module -ListAvailable -Name VCF.PowerCLI) {
        Import-Module VCF.PowerCLI | Out-Null
    }
    else {
        Import-Module VMware.PowerCLI | Out-Null
    }

    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

    if ($global:DefaultVIServers) {
        Disconnect-VIServer -Server $global:DefaultVIServers -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }

    $vcPassword = Read-SecretFile -Path $VCPasswordFile
    $vcSecurePassword = ConvertTo-SecureString $vcPassword -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($VCUsername, $vcSecurePassword)

    $pgPassword = Read-SecretFile -Path $PGPasswordFile

    if ([string]::IsNullOrWhiteSpace($VCenterName)) {
        $VCenterName = $VCServer
    }
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [guid]::NewGuid().ToString()
    }
    $snapshotTsUtc = (Get-Date).ToUniversalTime()
    $startedAtUtc = (Get-Date).ToUniversalTime()

    $beginRunSql = @"
INSERT INTO capacity_collection_runs (run_id, vcenter_name, started_at_utc, snapshot_ts_utc, status, script_version)
VALUES ($(ConvertTo-PgValue $RunId), $(ConvertTo-PgValue $VCenterName), $(ConvertTo-PgValue $startedAtUtc), $(ConvertTo-PgValue $snapshotTsUtc), 'running', $(ConvertTo-PgValue $ScriptVersion))
ON CONFLICT (run_id) DO UPDATE
SET vcenter_name = EXCLUDED.vcenter_name,
    started_at_utc = EXCLUDED.started_at_utc,
    snapshot_ts_utc = EXCLUDED.snapshot_ts_utc,
    status = EXCLUDED.status,
    script_version = EXCLUDED.script_version,
    completed_at_utc = NULL,
    error_message = NULL;
"@
    Invoke-Psql -Sql $beginRunSql -Password $pgPassword

    $viServer = Connect-VIServer -Server $VCServer -Credential $credential
    Write-Host "`nConnected successfully to vCenter: $VCServer" -ForegroundColor Green

    $seenDatastoreIds = @{}
    $clusters = Get-Cluster -Server $viServer | Sort-Object Name

    foreach ($cluster in $clusters) {
        $clusterView = Get-View -Server $viServer -Id $cluster.Id
        $haInfo = Get-HAInfo -ClusterView $clusterView

        $cpuOvercommitRatio = 1
        if ($cluster.DrsEnabled -and $clusterView.ConfigurationEx.DrsConfig.Option) {
            $perCoreOpt = $clusterView.ConfigurationEx.DrsConfig.Option |
                Where-Object { $_.Key.ToString().Trim() -eq "MaxVcpusPerCore" } |
                Select-Object -First 1
            if ($perCoreOpt -and $perCoreOpt.Value -match '^\d+$') {
                $cpuOvercommitRatio = [int]$perCoreOpt.Value
            }
        }

        $validHosts = Get-VMHost -Server $viServer -Location $cluster -ErrorAction SilentlyContinue | Where-Object {
            $_.ConnectionState -eq "Connected" -and
            $_.PowerState -eq "PoweredOn" -and
            $_.ExtensionData.Runtime.InMaintenanceMode -eq $false
        }

        if (@($validHosts).Count -lt 1) { continue }

        foreach ($vmHostObj in $validHosts) {
            $hostView = Get-View -Server $viServer -Id $vmHostObj.Id

            $totalCpuCores = [int]$hostView.Hardware.CpuInfo.NumCpuCores
            $cpuPackages = [int]$hostView.Hardware.CpuInfo.NumCpuPackages
            $coresPerSocket = if ($cpuPackages -gt 0) { [int]($totalCpuCores / $cpuPackages) } else { 0 }
            $totalRAMGB = [math]::Round(($hostView.Hardware.MemorySize / 1GB), 2)

            $reservedCores = [Math]::Min($ReservedPhysicalCoresPerHost, $totalCpuCores)
            $usableCpuCores = [Math]::Max(($totalCpuCores - $reservedCores), 0)
            $allowedvCPU = [math]::Round(($usableCpuCores * $cpuOvercommitRatio), 2)

            $reservedRAMGB = [Math]::Min($ReservedRAMGBPerHost, $totalRAMGB)
            $usableRAMGB = [math]::Round(([Math]::Max(($totalRAMGB - $reservedRAMGB), 0)), 2)

            $poweredOnVMs = Get-VM -Server $viServer -Location $vmHostObj -ErrorAction SilentlyContinue | Where-Object {
                $_.PowerState -eq "PoweredOn" -and $_.Name -notmatch '^vCLS'
            }

            $allocatedvCPU = ($poweredOnVMs | Measure-Object -Property NumCpu -Sum).Sum
            if (-not $allocatedvCPU) { $allocatedvCPU = 0 }

            $allocatedRAMGB = ($poweredOnVMs | Measure-Object -Property MemoryGB -Sum).Sum
            if (-not $allocatedRAMGB) { $allocatedRAMGB = 0 }
            $allocatedRAMGB = [math]::Round($allocatedRAMGB, 2)

            $availablevCPU = [math]::Round(($allowedvCPU - $allocatedvCPU), 2)
            $availableRAMGB = [math]::Round(($usableRAMGB - $allocatedRAMGB), 2)

            $CPUUsedPct = if ($allowedvCPU -gt 0) { [math]::Round((($allocatedvCPU / $allowedvCPU) * 100), 2) } else { 0 }
            $RAMUsedPct = if ($usableRAMGB -gt 0) { [math]::Round((($allocatedRAMGB / $usableRAMGB) * 100), 2) } else { 0 }

            $hostResults += [pscustomobject]@{
                snapshot_ts_utc   = $snapshotTsUtc
                run_id            = $RunId
                vcenter_name      = $VCenterName
                script_version    = $ScriptVersion
                cluster_name      = $cluster.Name
                compute_name      = $vmHostObj.Name
                sockets           = $cpuPackages
                cores_per_socket  = $coresPerSocket
                physical_cores    = $totalCpuCores
                reserved_cores    = $reservedCores
                usable_cpu_cores  = $usableCpuCores
                overcommit_ratio  = "$cpuOvercommitRatio`:1"
                allowed_vcpu      = $allowedvCPU
                allocated_vcpu    = $allocatedvCPU
                available_vcpu    = $availablevCPU
                cpu_used_pct      = $CPUUsedPct
                cpu_status        = Get-UsageStatus $CPUUsedPct
                total_ram_gb      = $totalRAMGB
                reserved_ram_gb   = $reservedRAMGB
                usable_ram_gb     = $usableRAMGB
                allocated_ram_gb  = $allocatedRAMGB
                available_ram_gb  = $availableRAMGB
                ram_used_pct      = $RAMUsedPct
                ram_status        = Get-UsageStatus $RAMUsedPct
                powered_on_vm_count = @($poweredOnVMs).Count
            }
        }

        $clusterHosts = $hostResults | Where-Object { $_.cluster_name -eq $cluster.Name }
        $totalAllowedvCPU = [math]::Round((($clusterHosts | Measure-Object -Property allowed_vcpu -Sum).Sum), 2)
        $totalAllocatedvCPU = [math]::Round((($clusterHosts | Measure-Object -Property allocated_vcpu -Sum).Sum), 2)
        $totalAvailablevCPU = [math]::Round(($totalAllowedvCPU - $totalAllocatedvCPU), 2)
        $totalUsableRAMGB = [math]::Round((($clusterHosts | Measure-Object -Property usable_ram_gb -Sum).Sum), 2)
        $totalAllocatedRAMGB = [math]::Round((($clusterHosts | Measure-Object -Property allocated_ram_gb -Sum).Sum), 2)
        $totalAvailableRAMGB = [math]::Round(($totalUsableRAMGB - $totalAllocatedRAMGB), 2)

        $clusterResults += [pscustomobject]@{
            snapshot_ts_utc            = $snapshotTsUtc
            run_id                     = $RunId
            vcenter_name               = $VCenterName
            script_version             = $ScriptVersion
            cluster_name               = $cluster.Name
            drs_enabled                = $cluster.DrsEnabled
            ha_enabled                 = $haInfo.HAEnabled
            admission_control_enabled  = $haInfo.AdmissionControlEnabled
            compute_count              = @($clusterHosts).Count
            total_allowed_vcpu         = $totalAllowedvCPU
            total_allocated_vcpu       = $totalAllocatedvCPU
            total_available_vcpu       = $totalAvailablevCPU
            cpu_used_pct               = if ($totalAllowedvCPU -gt 0) { [math]::Round((($totalAllocatedvCPU / $totalAllowedvCPU) * 100), 2) } else { 0 }
            total_usable_ram_gb        = $totalUsableRAMGB
            total_allocated_ram_gb     = $totalAllocatedRAMGB
            total_available_ram_gb     = $totalAvailableRAMGB
            ram_used_pct               = if ($totalUsableRAMGB -gt 0) { [math]::Round((($totalAllocatedRAMGB / $totalUsableRAMGB) * 100), 2) } else { 0 }
        }

        if ($haInfo.HAEnabled -and $haInfo.AdmissionControlEnabled -and $haInfo.HostFailuresTolerated -ge 1) {
            $minHostvCPU = ($clusterHosts | Measure-Object -Property allowed_vcpu -Minimum).Minimum
            $minHostRAM = ($clusterHosts | Measure-Object -Property usable_ram_gb -Minimum).Minimum

            $haReservedvCPU = [math]::Round(($minHostvCPU * $haInfo.HostFailuresTolerated), 2)
            $haReservedRAMGB = [math]::Round(($minHostRAM * $haInfo.HostFailuresTolerated), 2)
            $effectivevCPU = [math]::Round(([Math]::Max(($totalAllowedvCPU - $haReservedvCPU), 0)), 2)
            $effectiveRAMGB = [math]::Round(([Math]::Max(($totalUsableRAMGB - $haReservedRAMGB), 0)), 2)

            $availablevCPUAfterHA = [math]::Round(($effectivevCPU - $totalAllocatedvCPU), 2)
            $availableRAMAfterHA = [math]::Round(($effectiveRAMGB - $totalAllocatedRAMGB), 2)

            $clusterHAResults += [pscustomobject]@{
                snapshot_ts_utc             = $snapshotTsUtc
                run_id                      = $RunId
                vcenter_name                = $VCenterName
                script_version              = $ScriptVersion
                cluster_name                = $cluster.Name
                drs_enabled                 = $cluster.DrsEnabled
                ha_enabled                  = $haInfo.HAEnabled
                admission_control_enabled   = $haInfo.AdmissionControlEnabled
                host_failures_tolerated     = $haInfo.HostFailuresTolerated
                total_allowed_vcpu          = $totalAllowedvCPU
                ha_reserved_vcpu            = $haReservedvCPU
                effective_vcpu              = $effectivevCPU
                allocated_vcpu              = $totalAllocatedvCPU
                available_vcpu_after_ha     = $availablevCPUAfterHA
                cpu_used_pct_after_ha       = if ($effectivevCPU -gt 0) { [math]::Round((($totalAllocatedvCPU / $effectivevCPU) * 100), 2) } else { 0 }
                total_usable_ram_gb         = $totalUsableRAMGB
                ha_reserved_ram_gb          = $haReservedRAMGB
                effective_ram_gb            = $effectiveRAMGB
                allocated_ram_gb            = $totalAllocatedRAMGB
                available_ram_after_ha      = $availableRAMAfterHA
                ram_used_pct_after_ha       = if ($effectiveRAMGB -gt 0) { [math]::Round((($totalAllocatedRAMGB / $effectiveRAMGB) * 100), 2) } else { 0 }
            }
        }

        $clusterDatastores = $validHosts | Get-Datastore -ErrorAction SilentlyContinue | Sort-Object Id -Unique
        foreach ($datastore in $clusterDatastores) {
            if ($seenDatastoreIds.ContainsKey($datastore.Id)) { continue }
            $seenDatastoreIds[$datastore.Id] = $true

            $capacityTB = [math]::Round(($datastore.CapacityGB / 1024), 2)
            $freeTB = [math]::Round(($datastore.FreeSpaceGB / 1024), 2)
            $usedTB = [math]::Round(($capacityTB - $freeTB), 2)
            $usedPct = if ($capacityTB -gt 0) { [math]::Round((($usedTB / $capacityTB) * 100), 2) } else { 0 }

            $datastoreResults += [pscustomobject]@{
                snapshot_ts_utc = $snapshotTsUtc
                run_id          = $RunId
                vcenter_name    = $VCenterName
                script_version  = $ScriptVersion
                datastore_id    = $datastore.Id
                datastore_name  = $datastore.Name
                type            = $datastore.Type
                capacity_tb     = $capacityTB
                used_tb         = $usedTB
                free_tb         = $freeTB
                used_pct        = $usedPct
                status          = Get-UsageStatus $usedPct
            }
        }
    }

    $hostCols = @(
        "snapshot_ts_utc","run_id","vcenter_name","script_version","cluster_name","compute_name","sockets",
        "cores_per_socket","physical_cores","reserved_cores","usable_cpu_cores","overcommit_ratio","allowed_vcpu",
        "allocated_vcpu","available_vcpu","cpu_used_pct","cpu_status","total_ram_gb","reserved_ram_gb","usable_ram_gb",
        "allocated_ram_gb","available_ram_gb","ram_used_pct","ram_status","powered_on_vm_count"
    )
    $clusterCols = @(
        "snapshot_ts_utc","run_id","vcenter_name","script_version","cluster_name","drs_enabled","ha_enabled",
        "admission_control_enabled","compute_count","total_allowed_vcpu","total_allocated_vcpu","total_available_vcpu",
        "cpu_used_pct","total_usable_ram_gb","total_allocated_ram_gb","total_available_ram_gb","ram_used_pct"
    )
    $clusterHACols = @(
        "snapshot_ts_utc","run_id","vcenter_name","script_version","cluster_name","drs_enabled","ha_enabled",
        "admission_control_enabled","host_failures_tolerated","total_allowed_vcpu","ha_reserved_vcpu","effective_vcpu",
        "allocated_vcpu","available_vcpu_after_ha","cpu_used_pct_after_ha","total_usable_ram_gb","ha_reserved_ram_gb",
        "effective_ram_gb","allocated_ram_gb","available_ram_after_ha","ram_used_pct_after_ha"
    )
    $datastoreCols = @(
        "snapshot_ts_utc","run_id","vcenter_name","script_version","datastore_id","datastore_name","type",
        "capacity_tb","used_tb","free_tb","used_pct","status"
    )

    $insertSqlParts = @()
    $hostInsert = Build-InsertSql -TableName "host_capacity_metrics" -Columns $hostCols -Rows $hostResults
    if ($hostInsert) { $insertSqlParts += $hostInsert }
    $clusterInsert = Build-InsertSql -TableName "cluster_capacity_metrics" -Columns $clusterCols -Rows $clusterResults
    if ($clusterInsert) { $insertSqlParts += $clusterInsert }
    $clusterHAInsert = Build-InsertSql -TableName "cluster_ha_capacity_metrics" -Columns $clusterHACols -Rows $clusterHAResults
    if ($clusterHAInsert) { $insertSqlParts += $clusterHAInsert }
    $datastoreInsert = Build-InsertSql -TableName "datastore_capacity_metrics" -Columns $datastoreCols -Rows $datastoreResults
    if ($datastoreInsert) { $insertSqlParts += $datastoreInsert }

    $completedAtUtc = (Get-Date).ToUniversalTime()
    $status = "success"
    $updateRunSql = @"
UPDATE capacity_collection_runs
SET completed_at_utc = $(ConvertTo-PgValue $completedAtUtc),
    status = 'success',
    host_rows = $($hostResults.Count),
    cluster_rows = $($clusterResults.Count),
    cluster_ha_rows = $($clusterHAResults.Count),
    datastore_rows = $($datastoreResults.Count),
    error_message = NULL
WHERE run_id = $(ConvertTo-PgValue $RunId);
"@

    $txSql = "BEGIN;`n" + ($insertSqlParts -join "`n") + "`n" + $updateRunSql + "`nCOMMIT;"
    Invoke-Psql -Sql $txSql -Password $pgPassword

    if ($ShowConsoleSummary) {
        Write-Host "`n======================== Per Compute CPU Summary ========================" -ForegroundColor Green
        $hostResults | Sort-Object cluster_name, compute_name | Format-Table `
            cluster_name, compute_name, physical_cores, reserved_cores, usable_cpu_cores, overcommit_ratio, `
            allowed_vcpu, allocated_vcpu, available_vcpu, cpu_used_pct, cpu_status, powered_on_vm_count -AutoSize

        Write-Host "`n======================== Per Compute RAM Summary ========================" -ForegroundColor Green
        $hostResults | Sort-Object cluster_name, compute_name | Format-Table `
            cluster_name, compute_name, total_ram_gb, reserved_ram_gb, usable_ram_gb, `
            allocated_ram_gb, available_ram_gb, ram_used_pct, ram_status, powered_on_vm_count -AutoSize

        Write-Host "`n======================== Cluster CPU Summary ========================" -ForegroundColor Green
        $clusterResults | Sort-Object cluster_name | Format-Table `
            cluster_name, drs_enabled, ha_enabled, admission_control_enabled, compute_count, `
            total_allowed_vcpu, total_allocated_vcpu, total_available_vcpu, cpu_used_pct -AutoSize

        Write-Host "`n======================== Cluster RAM Summary ========================" -ForegroundColor Green
        $clusterResults | Sort-Object cluster_name | Format-Table `
            cluster_name, drs_enabled, ha_enabled, admission_control_enabled, compute_count, `
            total_usable_ram_gb, total_allocated_ram_gb, total_available_ram_gb, ram_used_pct -AutoSize

        if ($clusterHAResults.Count -gt 0) {
            Write-Host "`n======================== Cluster CPU Summary with HA ========================" -ForegroundColor Green
            $clusterHAResults | Sort-Object cluster_name | Format-Table `
                cluster_name, drs_enabled, ha_enabled, admission_control_enabled, host_failures_tolerated, `
                total_allowed_vcpu, ha_reserved_vcpu, effective_vcpu, allocated_vcpu, available_vcpu_after_ha, cpu_used_pct_after_ha -AutoSize

            Write-Host "`n======================== Cluster RAM Summary with HA ========================" -ForegroundColor Green
            $clusterHAResults | Sort-Object cluster_name | Format-Table `
                cluster_name, drs_enabled, ha_enabled, admission_control_enabled, host_failures_tolerated, `
                total_usable_ram_gb, ha_reserved_ram_gb, effective_ram_gb, allocated_ram_gb, available_ram_after_ha, ram_used_pct_after_ha -AutoSize
        }
        else {
            Write-Host "`nNo cluster found with HA Admission Control using 'Host Failures Cluster Tolerates' policy." -ForegroundColor Yellow
        }

        Write-Host "`n======================== Datastore Summary ========================" -ForegroundColor Green
        $datastoreResults | Sort-Object datastore_name | Format-Table `
            datastore_id, datastore_name, type, capacity_tb, used_tb, free_tb, used_pct, status -AutoSize
    }
}
catch {
    $safeMessage = $_.Exception.Message
    $errorMessage = $safeMessage.Replace("'", "")
    Write-Host "`nFailed while processing capacity data." -ForegroundColor Red
    Write-Host "Error: $safeMessage" -ForegroundColor Red

    if (-not [string]::IsNullOrWhiteSpace($RunId) -and -not [string]::IsNullOrWhiteSpace($pgPassword)) {
        try {
            $failedAt = (Get-Date).ToUniversalTime()
            $failureSql = @"
UPDATE capacity_collection_runs
SET completed_at_utc = $(ConvertTo-PgValue $failedAt),
    status = 'failed',
    host_rows = $($hostResults.Count),
    cluster_rows = $($clusterResults.Count),
    cluster_ha_rows = $($clusterHAResults.Count),
    datastore_rows = $($datastoreResults.Count),
    error_message = $(ConvertTo-PgValue $errorMessage)
WHERE run_id = $(ConvertTo-PgValue $RunId);
"@
            Invoke-Psql -Sql $failureSql -Password $pgPassword
        }
        catch {
            Write-Host "Failed to update run status in database." -ForegroundColor Red
        }
    }

    exit 1
}
finally {
    if ($viServer) {
        Disconnect-VIServer -Server $viServer -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
}

<#
One tick of the manual capacity-refresh watcher.

Claims the oldest pending row in capacity_run_requests, runs the existing collector for it,
then marks the row done/failed. Outbound Postgres connection only - no listener, no API.
Driven by deploy/vmware-capacity-watcher.timer (~30s). See README section 13.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,
    [string]$CollectorScript = "",
    [Nullable[int]]$MinIntervalMinutes = $null,
    [Nullable[int]]$InFlightTimeoutMinutes = $null,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

function Read-SecretFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Secret file not found: $Path"
    }

    return (Get-Content -LiteralPath $Path -Raw).Trim()
}

function Write-WatcherLog {
    param(
        [string]$Message,
        [string]$Color = "Cyan"
    )

    Write-Host ("[Watcher] {0} {1}" -f (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK"), $Message) -ForegroundColor $Color
}

function Get-SkipReason {
    param(
        [int]$RecentSuccessCount,
        [int]$InFlightCount,
        [int]$MinIntervalMinutes
    )

    if ($InFlightCount -gt 0) {
        return "a collection is already running"
    }
    if ($RecentSuccessCount -gt 0) {
        return "a collection succeeded within the last $MinIntervalMinutes minute(s)"
    }

    return ""
}

if ($SelfTest) {
    # Smallest check that fails if the debounce ordering breaks.
    if ((Get-SkipReason -RecentSuccessCount 0 -InFlightCount 0 -MinIntervalMinutes 2) -ne "") { throw "SelfTest: idle state must not skip" }
    if ((Get-SkipReason -RecentSuccessCount 0 -InFlightCount 1 -MinIntervalMinutes 2) -notlike "*already running*") { throw "SelfTest: in-flight run must skip" }
    if ((Get-SkipReason -RecentSuccessCount 1 -InFlightCount 0 -MinIntervalMinutes 2) -notlike "*within the last 2*") { throw "SelfTest: debounce window must skip" }
    if ((Get-SkipReason -RecentSuccessCount 1 -InFlightCount 1 -MinIntervalMinutes 2) -notlike "*already running*") { throw "SelfTest: in-flight takes precedence" }
    Write-Host "SelfTest passed." -ForegroundColor Green
    exit 0
}

# Populated from the collector config below; Invoke-PsqlRows reads them from script scope,
# same as Invoke-Psql in capacityutilization.ps1.
$PGHost = ""
$PGPort = 0
$PGDatabase = ""
$PGUsername = ""
$pgPassword = $null

function Invoke-PsqlRows {
    param([string]$Sql)

    $sqlFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $sqlFile -Value $Sql -NoNewline
        $env:PGPASSWORD = $pgPassword
        $rows = & psql `
            -h $PGHost `
            -p $PGPort `
            -U $PGUsername `
            -d $PGDatabase `
            -v ON_ERROR_STOP=1 `
            -At -F '|' `
            -f $sqlFile
        if ($LASTEXITCODE -ne 0) {
            throw "psql command failed with exit code $LASTEXITCODE"
        }
        return @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    finally {
        Remove-Item -LiteralPath $sqlFile -Force -ErrorAction SilentlyContinue
        $env:PGPASSWORD = $null
    }
}

$requestId = $null

try {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw "Config file not found: $ConfigFile"
    }
    $resolvedConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path
    $config = Import-PowerShellDataFile -LiteralPath $resolvedConfigFile

    foreach ($key in @("PGHost", "PGPort", "PGDatabase", "PGUsername", "PGPasswordFile")) {
        if (-not $config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$config[$key])) {
            throw "Missing required setting in ${resolvedConfigFile}: $key"
        }
    }

    $PGHost = $config.PGHost
    $PGPort = [int]$config.PGPort
    $PGDatabase = $config.PGDatabase
    $PGUsername = $config.PGUsername
    $pgPassword = Read-SecretFile -Path $config.PGPasswordFile

    if ($null -eq $MinIntervalMinutes) {
        $MinIntervalMinutes = if ($config.ContainsKey("MinIntervalMinutes")) { [int]$config.MinIntervalMinutes } else { 2 }
    }
    if ($null -eq $InFlightTimeoutMinutes) {
        $InFlightTimeoutMinutes = if ($config.ContainsKey("InFlightTimeoutMinutes")) { [int]$config.InFlightTimeoutMinutes } else { 120 }
    }
    $MinIntervalMinutes = [int]$MinIntervalMinutes
    $InFlightTimeoutMinutes = [int]$InFlightTimeoutMinutes

    if ([string]::IsNullOrWhiteSpace($CollectorScript)) {
        $CollectorScript = if ($config.ContainsKey("CollectorScript")) {
            $config.CollectorScript
        }
        else {
            Join-Path -Path $PSScriptRoot -ChildPath "..\capacityutilization.ps1"
        }
    }
    if (-not (Test-Path -LiteralPath $CollectorScript)) {
        throw "Collector script not found: $CollectorScript"
    }
    $CollectorScript = (Resolve-Path -LiteralPath $CollectorScript).Path

    # 1. Atomically claim the oldest pending request.
    $claimSql = @"
UPDATE capacity_run_requests
SET status = 'claimed', claimed_at_utc = now()
WHERE request_id = (
    SELECT request_id FROM capacity_run_requests
    WHERE status = 'pending'
    ORDER BY requested_at_utc
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
RETURNING request_id::text, coalesce(requested_by, '');
"@
    $claimed = Invoke-PsqlRows -Sql $claimSql

    # 2. Nothing pending: exit quietly (this is the common case, every ~30s).
    if ($claimed.Count -eq 0) {
        exit 0
    }

    $fields = $claimed[0].Split('|')
    $requestId = $fields[0]
    $requestedBy = if ($fields.Count -gt 1) { $fields[1] } else { "" }

    # request_id is the only request-row value interpolated into later SQL, so it is
    # validated here. requested_by/vcenter_name/note are attacker-controllable text from
    # the button role and are never interpolated.
    if ($requestId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "Claimed request_id is not a uuid: $requestId"
    }
    Write-WatcherLog ("Claimed request {0} (requested_by={1})" -f $requestId, $requestedBy)

    # 3. Collapse duplicates, then debounce.
    $supersedeSql = @"
UPDATE capacity_run_requests
SET status = 'superseded',
    completed_at_utc = now(),
    note = concat_ws(' | ', note, 'superseded by request $requestId')
WHERE status = 'pending'
RETURNING request_id::text;
"@
    $superseded = Invoke-PsqlRows -Sql $supersedeSql
    if ($superseded.Count -gt 0) {
        Write-WatcherLog ("Superseded {0} duplicate pending request(s)" -f $superseded.Count)
    }

    $guardSql = @"
SELECT
    (SELECT count(*) FROM capacity_collection_runs
     WHERE status = 'success' AND completed_at_utc > now() - interval '$MinIntervalMinutes minutes'),
    (SELECT count(*) FROM capacity_collection_runs
     WHERE status = 'running' AND started_at_utc > now() - interval '$InFlightTimeoutMinutes minutes');
"@
    $guard = (Invoke-PsqlRows -Sql $guardSql)[0].Split('|')
    $skipReason = Get-SkipReason -RecentSuccessCount ([int]$guard[0]) -InFlightCount ([int]$guard[1]) -MinIntervalMinutes $MinIntervalMinutes

    if ($skipReason) {
        Write-WatcherLog ("Skipping request {0}: {1}" -f $requestId, $skipReason) "Yellow"
        Invoke-PsqlRows -Sql @"
UPDATE capacity_run_requests
SET status = 'superseded',
    completed_at_utc = now(),
    note = concat_ws(' | ', note, 'not launched: $skipReason')
WHERE request_id = '$requestId';
"@ | Out-Null
        exit 0
    }

    # 4. Run the existing collector. Global refresh, so no -VCenterName is passed.
    Write-WatcherLog ("Launching {0} -RunId {1}" -f $CollectorScript, $requestId)
    & pwsh -NoLogo -NonInteractive -File $CollectorScript -ConfigFile $resolvedConfigFile -RunId $requestId
    $collectorExit = $LASTEXITCODE
    Write-WatcherLog ("Collector exited with code {0}" -f $collectorExit)

    # 5. Read the authoritative outcome back from capacity_collection_runs.
    $runRows = Invoke-PsqlRows -Sql "SELECT status FROM capacity_collection_runs WHERE run_id = '$requestId';"
    $runStatus = if ($runRows.Count -gt 0) { $runRows[0].Trim() } else { "" }

    $finalStatus = if ($runStatus -eq "success" -and $collectorExit -eq 0) { "done" } else { "failed" }
    $finalNote = if ($runStatus) { "collector status=$runStatus exit=$collectorExit" } else { "no capacity_collection_runs row; collector exit=$collectorExit" }

    Invoke-PsqlRows -Sql @"
UPDATE capacity_run_requests
SET status = '$finalStatus',
    completed_at_utc = now(),
    run_id = '$requestId',
    note = concat_ws(' | ', note, '$finalNote')
WHERE request_id = '$requestId';
"@ | Out-Null

    if ($finalStatus -eq "done") {
        Write-WatcherLog ("Request {0} done" -f $requestId) "Green"
    }
    else {
        Write-WatcherLog ("Request {0} failed ({1}). See capacity_collection_runs.error_message." -f $requestId, $finalNote) "Red"
        exit 1
    }
}
catch {
    Write-WatcherLog ("Tick failed: {0}" -f $_.Exception.Message) "Red"

    # A claimed row must never be left stuck in 'claimed'.
    if ($requestId -and $pgPassword) {
        try {
            Invoke-PsqlRows -Sql @"
UPDATE capacity_run_requests
SET status = 'failed', completed_at_utc = now()
WHERE request_id = '$requestId' AND status = 'claimed';
"@ | Out-Null
        }
        catch {
            Write-WatcherLog "Could not mark the claimed request as failed." "Red"
        }
    }

    exit 1
}

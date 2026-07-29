param(
    [Parameter(Mandatory = $true)]
    [string]$PGHost,
    [Parameter(Mandatory = $true)]
    [int]$PGPort,
    [Parameter(Mandatory = $true)]
    [string]$PGDatabase,
    [Parameter(Mandatory = $true)]
    [string]$PGUsername,
    [Parameter(Mandatory = $true)]
    [string]$PGPasswordFile,
    [string]$TriggerPasswordFile = "",
    [string]$SqlFile = ""
)

$ErrorActionPreference = "Stop"

function Read-SecretFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Secret file not found: $Path"
    }

    return (Get-Content -LiteralPath $Path -Raw).Trim()
}

$preludeFile = $null

try {
    if ([string]::IsNullOrWhiteSpace($SqlFile)) {
        $SqlFile = Join-Path -Path $PSScriptRoot -ChildPath "..\db\add_manual_trigger.sql"
    }

    $resolvedSqlFile = (Resolve-Path -LiteralPath $SqlFile).Path
    $pgPassword = Read-SecretFile -Path $PGPasswordFile

    # The grafana_trigger password is handed to psql through a 600 temp file rather than
    # -v on the command line, which would expose it in the process list.
    if (-not [string]::IsNullOrWhiteSpace($TriggerPasswordFile)) {
        $triggerPassword = Read-SecretFile -Path $TriggerPasswordFile
        if ($triggerPassword -match "['\\]") {
            throw "grafana_trigger password must not contain a single quote or backslash: $TriggerPasswordFile"
        }

        $preludeFile = [System.IO.Path]::GetTempFileName()
        Set-Content -LiteralPath $preludeFile -Value "\set grafana_trigger_pw '$triggerPassword'`n\i $($resolvedSqlFile.Replace('\', '/'))" -NoNewline
        $psqlInput = $preludeFile
    }
    else {
        $psqlInput = $resolvedSqlFile
    }

    $env:PGPASSWORD = $pgPassword
    & psql `
        -h $PGHost `
        -p $PGPort `
        -U $PGUsername `
        -d $PGDatabase `
        -v ON_ERROR_STOP=1 `
        -f $psqlInput

    if ($LASTEXITCODE -ne 0) {
        throw "Manual-trigger migration failed with exit code $LASTEXITCODE"
    }

    Write-Host "Manual-trigger migration completed successfully." -ForegroundColor Green
}
catch {
    Write-Host "Manual-trigger migration failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($preludeFile) {
        Remove-Item -LiteralPath $preludeFile -Force -ErrorAction SilentlyContinue
    }
    $env:PGPASSWORD = $null
}

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

try {
    if ([string]::IsNullOrWhiteSpace($SqlFile)) {
        $SqlFile = Join-Path -Path $PSScriptRoot -ChildPath "..\db\init_timescale.sql"
    }

    $resolvedSqlFile = (Resolve-Path -LiteralPath $SqlFile).Path
    $pgPassword = Read-SecretFile -Path $PGPasswordFile

    $env:PGPASSWORD = $pgPassword
    & psql `
        -h $PGHost `
        -p $PGPort `
        -U $PGUsername `
        -d $PGDatabase `
        -v ON_ERROR_STOP=1 `
        -f $resolvedSqlFile

    if ($LASTEXITCODE -ne 0) {
        throw "Database initialization failed with exit code $LASTEXITCODE"
    }

    Write-Host "Database initialization completed successfully." -ForegroundColor Green
}
catch {
    Write-Host "Database initialization failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    $env:PGPASSWORD = $null
}

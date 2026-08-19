[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('staging','production')][string]$Environment = 'production',
    [string]$ConfigurationPath = (Join-Path $PSScriptRoot 'config\deployment.env'),
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\ElderPath.Deployment.psm1') -Force
$configuration = ConvertFrom-EPEnvFile -Path $ConfigurationPath
[void](Assert-EPConfiguration -Configuration $configuration)
[void](Initialize-EPLogging -Root $PSScriptRoot)
$upper = $Environment.ToUpperInvariant()
$secretName = [string]$configuration["${upper}_DATABASE_URL_SYNC_SECRET"]
$projectRef = [string]$configuration["SUPABASE_${upper}_PROJECT_REF"]
$backupRoot = [string]$configuration.BACKUP_ROOT
$version = [string]$configuration.SUPABASE_CLI_VERSION

if (-not (Resolve-EPExecutable @('gcloud.cmd'))) { throw 'Google Cloud CLI is missing. Run bootstrap.ps1.' }
if (-not (Resolve-EPExecutable @('npx.cmd'))) { throw 'Node.js/npm is missing. Run bootstrap.ps1.' }

$auth = Invoke-EPCommand -FilePath 'gcloud.cmd' -ArgumentList @('auth','list','--filter=status:ACTIVE','--format=value(account)') -NoLogOutput
if (-not $auth.StdOut.Trim()) {
    if ($NonInteractive) { throw 'No cached Google Cloud login is available to the scheduled backup task.' }
    throw 'No active Google Cloud login. Run gcloud auth login.'
}

$secretResult = Invoke-EPCommand -FilePath 'gcloud.cmd' -ArgumentList @('secrets','versions','access','latest','--secret',$secretName,'--project',[string]$configuration.GCP_PROJECT_ID) -NoLogOutput
$databaseUrl = $secretResult.StdOut.Trim()
Add-EPRedaction $databaseUrl
if (-not $databaseUrl.StartsWith('postgresql', [StringComparison]::OrdinalIgnoreCase)) { throw 'Secret is not a PostgreSQL URL.' }

$uri = [uri]$databaseUrl
$userInfo = [uri]::UnescapeDataString($uri.UserInfo).Split(':',2)
if ($userInfo.Count -ne 2) { throw 'The Supabase pooler URL must include a username and password.' }
$password = $userInfo[1]
Add-EPRedaction $password

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$destination = Join-Path $backupRoot "$Environment\$timestamp"
$temporary = Join-Path $env:TEMP "elderpath-supabase-$([guid]::NewGuid().ToString('N'))"

try {
    if ($PSCmdlet.ShouldProcess($destination, 'Create Supabase logical backup')) {
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        [IO.Directory]::CreateDirectory($temporary) | Out-Null
        $processEnvironment = @{ SUPABASE_DB_PASSWORD=$password }
        Invoke-EPCommand -FilePath 'npx.cmd' -ArgumentList @('--yes',"supabase@$version",'init') -WorkingDirectory $temporary -Environment $processEnvironment | Out-Null
        Invoke-EPCommand -FilePath 'npx.cmd' -ArgumentList @('--yes',"supabase@$version",'link','--project-ref',$projectRef) -WorkingDirectory $temporary -Environment $processEnvironment | Out-Null
        Invoke-EPCommand -FilePath 'npx.cmd' -ArgumentList @('--yes',"supabase@$version",'db','dump','--linked','--file',(Join-Path $destination 'schema.sql')) -WorkingDirectory $temporary -Environment $processEnvironment | Out-Null
        Invoke-EPCommand -FilePath 'npx.cmd' -ArgumentList @('--yes',"supabase@$version",'db','dump','--linked','--data-only','--use-copy','--file',(Join-Path $destination 'data.sql')) -WorkingDirectory $temporary -Environment $processEnvironment | Out-Null

        $manifest = [ordered]@{
            CreatedAt = (Get-Date).ToUniversalTime().ToString('o')
            Environment = $Environment
            ProjectRef = $projectRef
            SchemaSha256 = (Get-FileHash -LiteralPath (Join-Path $destination 'schema.sql') -Algorithm SHA256).Hash
            DataSha256 = (Get-FileHash -LiteralPath (Join-Path $destination 'data.sql') -Algorithm SHA256).Hash
            RestoreAutomatically = $false
        } | ConvertTo-Json
        [IO.File]::WriteAllText((Join-Path $destination 'manifest.json'),$manifest,[Text.UTF8Encoding]::new($false))

        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls.exe $destination /inheritance:r /grant:r "${identity}:(OI)(CI)F" *> $null
        if ($LASTEXITCODE -ne 0) { Write-EPLog 'Windows ACL isolation could not be applied; protect this directory manually.' -Level WARN }

        $cutoff = (Get-Date).AddDays(-[int]$configuration.BACKUP_RETENTION_DAYS)
        Get-ChildItem -LiteralPath (Join-Path $backupRoot $Environment) -Directory -ErrorAction SilentlyContinue |
            Where-Object LastWriteTime -lt $cutoff |
            ForEach-Object {
                $resolved = $_.FullName
                $base = (Resolve-Path -LiteralPath (Join-Path $backupRoot $Environment)).Path
                if (-not $resolved.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe retention target: $resolved" }
                Remove-Item -LiteralPath $resolved -Recurse -Force
                Write-EPLog "Removed expired backup $resolved. It is not recoverable from this toolkit."
            }
        Write-EPLog "Backup completed: $destination"
    }
} finally {
    $databaseUrl = $null
    $password = $null
    if (Test-Path -LiteralPath $temporary) {
        $resolvedTemp = (Resolve-Path -LiteralPath $temporary).Path
        $tempRoot = (Resolve-Path -LiteralPath $env:TEMP).Path
        if ($resolvedTemp.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        }
    }
}

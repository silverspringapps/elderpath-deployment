[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigurationPath = (Join-Path $PSScriptRoot 'config\deployment.env'),
    [switch]$SkipDockerWait,
    [switch]$SkipNpmInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'lib\ElderPath.Deployment.psm1') -Force

function Get-CommandVersion {
    param([string]$Command, [string[]]$Arguments = @('--version'))
    $found = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $found) { return $null }
    try { return (& $found.Source @Arguments 2>$null | Select-Object -First 1) } catch { return $null }
}

function Update-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
    $user = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = @($machine,$user) -join ';'
}

function Install-WingetPackage {
    param([string]$Id, [string]$Label)
    Write-Host "Installing $Label ($Id)..."
    if (-not $WhatIfPreference) {
        & winget install --id $Id --exact --accept-package-agreements --accept-source-agreements --silent
        if ($LASTEXITCODE -ne 0) { throw "winget failed to install $Label (exit $LASTEXITCODE)." }
    }
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'Windows Package Manager (winget) is required. Install App Installer from Microsoft Store, then rerun this script.'
}

$tools = @(
    @{ Command='git';    Winget='Git.Git';             Label='Git for Windows' },
    @{ Command='node';   Winget='OpenJS.NodeJS.22';    Label='Node.js 22' },
    @{ Command='docker'; Winget='Docker.DockerDesktop';Label='Docker Desktop' },
    @{ Command='gcloud'; Winget='Google.CloudSDK';     Label='Google Cloud CLI' },
    @{ Command='gh';     Winget='GitHub.cli';          Label='GitHub CLI' }
)

# Store-launched PowerShell can inherit a stale PATH even when machine-scoped tools
# are already installed. Refresh before deciding that any package is missing.
Update-ProcessPath
foreach ($tool in $tools) {
    $version = Get-CommandVersion -Command $tool.Command
    if (-not $version) { Install-WingetPackage -Id $tool.Winget -Label $tool.Label }
    else { Write-Host "$($tool.Label): $version" }
}

Update-ProcessPath

$nodeVersion = Get-CommandVersion -Command node -Arguments @('--version')
if ($nodeVersion -and $nodeVersion -notmatch '^v22\.') {
    throw "Node.js 22 is required; found $nodeVersion. Install side-by-side or remove the conflicting Node installation."
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $powerShellStatuses = @(Get-EPPowerShellExecutableStatus)
    $powerShell7 = $powerShellStatuses | Where-Object Compatible | Select-Object -First 1
    if (-not $powerShell7) {
        Install-WingetPackage -Id 'Microsoft.PowerShell' -Label 'PowerShell 7'
        Update-ProcessPath
        $powerShellStatuses = @(Get-EPPowerShellExecutableStatus)
        $powerShell7 = $powerShellStatuses | Where-Object Compatible | Select-Object -First 1
    }
    if (-not $powerShell7) {
        if ($WhatIfPreference) {
            Write-Host 'WHATIF install and relaunch under PowerShell 7.'
            return
        }
        $existing = @($powerShellStatuses | Where-Object Exists)
        $launchable = @($existing | Where-Object Launchable)
        if (-not $existing.Count) { throw 'PowerShell 7 could not be found after installation. Open a new terminal and rerun bootstrap.ps1.' }
        if ($launchable.Count) {
            $versions = ($launchable | ForEach-Object MajorVersion | Sort-Object -Unique) -join ', '
            throw "PowerShell executables were found, but only major version(s) $versions could run. PowerShell 7 or newer is required."
        }
        throw 'PowerShell executables were found but could not be launched. Repair the PowerShell installation or its Windows App Execution Alias, then retry.'
    }

    $relayArguments = Get-EPBootstrapRelaunchArguments -ScriptPath $PSCommandPath -ConfigurationPath $ConfigurationPath `
        -SkipDockerWait:$SkipDockerWait -SkipNpmInstall:$SkipNpmInstall -WhatIf:$WhatIfPreference
    Write-Host "Relaunching bootstrap with PowerShell $($powerShell7.MajorVersion): $($powerShell7.Path)"
    $powerShell7Path = [string]$powerShell7.Path
    & $powerShell7Path @relayArguments
    exit $LASTEXITCODE
}

$minimumPester = [version]'5.5.0'
$pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -or $pester.Version -lt $minimumPester) {
    Write-Host "Installing Pester $minimumPester or newer for the current user..."
    if ($PSCmdlet.ShouldProcess('Pester', 'Install PowerShell module')) {
        Install-Module Pester -MinimumVersion $minimumPester -Scope CurrentUser -Force -SkipPublisherCheck
    }
}

$repoPath = 'C:\Scripts\Git\elderpath'
if (Test-Path -LiteralPath $ConfigurationPath) {
    $configuration = ConvertFrom-EPEnvFile $ConfigurationPath
    if ($configuration.Contains('ELDERPATH_REPO_PATH')) { $repoPath = $configuration.ELDERPATH_REPO_PATH }
}
if (-not (Test-Path -LiteralPath (Join-Path $repoPath 'package-lock.json'))) { throw "ElderPath package-lock.json not found under $repoPath." }

if (-not $SkipNpmInstall -and $PSCmdlet.ShouldProcess($repoPath, 'Run npm ci')) {
    Push-Location $repoPath
    try { & npm.cmd ci; if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' } } finally { Pop-Location }
}

if (-not $SkipDockerWait) {
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
        if (-not (Test-Path -LiteralPath $desktop)) { throw 'Docker Desktop is installed but its executable was not found.' }
        if ($PSCmdlet.ShouldProcess($desktop, 'Start Docker Desktop hidden')) {
            Start-Process -FilePath $desktop -WindowStyle Hidden
            $deadline = (Get-Date).AddMinutes(4)
            do {
                Start-Sleep -Seconds 5
                & docker info *> $null
                if ($LASTEXITCODE -eq 0) { break }
            } while ((Get-Date) -lt $deadline)
            if ($LASTEXITCODE -ne 0) { throw 'Docker did not become ready within four minutes. Start Docker Desktop manually and rerun.' }
        }
    }
}

# The bootstrap's -WhatIf is for installation and repository mutations. Pester creates
# isolated TestDrive files as part of its safety tests, so do not leak WhatIfPreference
# into the test process or those assertions become false failures.
$bootstrapWhatIfPreference = $WhatIfPreference
try {
    $WhatIfPreference = $false
    Import-Module Pester -MinimumVersion $minimumPester
    $result = Invoke-Pester -Path (Join-Path $PSScriptRoot 'tests') -PassThru
} finally {
    $WhatIfPreference = $bootstrapWhatIfPreference
}
if ($result.FailedCount -gt 0) { throw "$($result.FailedCount) deployment test(s) failed." }

Write-Host ''
Write-Host 'Bootstrap complete. Next:'
Write-Host "  Copy-Item '$PSScriptRoot\config\deployment.env.example' '$PSScriptRoot\config\deployment.env'"
Write-Host "  pwsh '$PSScriptRoot\Deploy-ElderPath.ps1' -Phase Validate"

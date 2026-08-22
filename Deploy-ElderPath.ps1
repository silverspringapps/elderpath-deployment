[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [ValidateSet('Validate','Provision','RepairDatabaseSecrets','ConfigureCI','ConfigureCloudflare','ConfigureReleaseTopology','ManualRelease','DeployStaging','DeployProduction','CreateBindingsPR','CleanupAccidentalR2','Monitoring','GeocodeCalifornia','PromoteAdmin','All','Resume')]
    [string]$Phase = 'Validate',
    [string]$ConfigurationPath = (Join-Path $PSScriptRoot 'config\deployment.env'),
    [switch]$RotateSecrets,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\ElderPath.Deployment.psm1') -Force

$script:DryRun = [bool]$WhatIfPreference
$script:Sensitive = @{}
$script:CloudflareEnvironment = @{}
$script:ActiveRepository = $null
$script:TemporaryWorktree = $null
$script:Config = ConvertFrom-EPEnvFile -Path $ConfigurationPath
[void](Assert-EPConfiguration -Configuration $script:Config)
if ((Resolve-Path -LiteralPath $script:Config.DEPLOYMENT_ROOT).Path -ne (Resolve-Path -LiteralPath $PSScriptRoot).Path) {
    throw "DEPLOYMENT_ROOT must resolve to this toolkit: $PSScriptRoot"
}
$script:Log = Initialize-EPLogging -Root $PSScriptRoot
$script:State = Get-EPCheckpoint -Root $PSScriptRoot

function Get-Cfg([string]$Name) { return [string]$script:Config[$Name] }
function Get-CfgBool([string]$Name) { return ConvertTo-EPBoolean -Value (Get-Cfg $Name) -Name $Name }

function Invoke-Tool {
    param([string]$FilePath,[string[]]$Arguments,[string]$WorkingDirectory,[string]$InputText,[hashtable]$Environment=@{},[switch]$AllowFailure,[switch]$NoLogOutput)
    return Invoke-EPCommand -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -InputText $InputText -Environment $Environment -AllowFailure:$AllowFailure -NoLogOutput:$NoLogOutput -WhatIf:$script:DryRun
}

function Invoke-ReadOnlyTool {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [switch]$AllowFailure,
        [switch]$NoLogOutput
    )
    return Invoke-EPCommand -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -AllowFailure:$AllowFailure -NoLogOutput:$NoLogOutput
}
function Invoke-Gcloud { param([string[]]$Arguments,[string]$InputText,[switch]$AllowFailure,[switch]$NoLogOutput) Invoke-Tool 'gcloud.cmd' $Arguments -InputText $InputText -AllowFailure:$AllowFailure -NoLogOutput:$NoLogOutput }
function Invoke-Gh { param([string[]]$Arguments,[string]$InputText,[switch]$AllowFailure,[switch]$NoLogOutput) Invoke-Tool 'gh.exe' $Arguments -InputText $InputText -AllowFailure:$AllowFailure -NoLogOutput:$NoLogOutput }
function Get-ExecutionRepository { if ($script:ActiveRepository) { return $script:ActiveRepository }; return (Get-Cfg 'ELDERPATH_REPO_PATH') }
function Invoke-Npm { param([string[]]$Arguments,[hashtable]$Environment=@{},[switch]$AllowFailure) Invoke-Tool 'npm.cmd' $Arguments -WorkingDirectory (Get-ExecutionRepository) -Environment $Environment -AllowFailure:$AllowFailure }
function Invoke-Wrangler {
    param([string[]]$Arguments,[string]$InputText,[switch]$AllowFailure,[string]$WorkingDirectory)
    if (-not $WorkingDirectory) { $WorkingDirectory = Get-ExecutionRepository }
    Invoke-Tool 'npx.cmd' (@('--no-install','wrangler') + $Arguments) -WorkingDirectory $WorkingDirectory -InputText $InputText -Environment $script:CloudflareEnvironment -AllowFailure:$AllowFailure
}

function Get-SensitiveValue {
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][AllowEmptyString()][string]$Prompt,[switch]$Generate)
    if ($script:Sensitive.ContainsKey($Name)) { return $script:Sensitive[$Name] }
    if ($script:DryRun) {
        $value = '[DRY-RUN-SECRET]'
    } else {
        if ($NonInteractive) { throw "Secret '$Name' is required interactively and is not accepted in deployment.env or command arguments." }
        $value = if ($Generate) { New-EPRandomSecret } else { Read-EPSecureValue -Prompt $Prompt }
    }
    Add-EPRedaction $value
    $script:Sensitive[$Name] = $value
    return $value
}

function Complete-Step([string]$Name) {
    Set-EPCheckpointComplete -Root $PSScriptRoot -State $script:State -Name $Name
    Write-EPLog "Completed checkpoint: $Name"
}
function Invoke-Step([string]$Name,[scriptblock]$Action) {
    $forceForRotation = $RotateSecrets -and ($Name -eq 'gcp.secrets' -or $Name -like 'deploy.worker.*')
    if ((Test-EPCheckpointComplete -State $script:State -Name $Name) -and -not $forceForRotation) { Write-EPLog "Checkpoint already complete; skipping $Name"; return }
    & $Action
    if (-not $script:DryRun) { Complete-Step $Name }
}

function Initialize-ReviewedWorktree {
    if ($script:ActiveRepository) { return $script:ActiveRepository }
    if ($script:DryRun) { $script:ActiveRepository = Get-Cfg 'ELDERPATH_REPO_PATH'; return $script:ActiveRepository }
    $repo = Get-Cfg 'ELDERPATH_REPO_PATH'
    $script:TemporaryWorktree = Join-Path $env:TEMP "elderpath-release-$([guid]::NewGuid().ToString('N'))"
    Invoke-Tool 'git.exe' @('worktree','add','--detach',$script:TemporaryWorktree,"origin/$(Get-Cfg 'GITHUB_DEFAULT_BRANCH')") -WorkingDirectory $repo | Out-Null
    $script:ActiveRepository = $script:TemporaryWorktree
    Invoke-Tool 'npm.cmd' @('ci') -WorkingDirectory $script:ActiveRepository | Out-Null
    Write-EPLog "Release commands use isolated worktree $($script:ActiveRepository)."
    return $script:ActiveRepository
}

function Remove-ReviewedWorktree {
    if (-not $script:TemporaryWorktree) { return }
    $repo = Get-Cfg 'ELDERPATH_REPO_PATH'
    Invoke-Tool 'git.exe' @('worktree','remove',$script:TemporaryWorktree,'--force') -WorkingDirectory $repo -AllowFailure | Out-Null
    $script:TemporaryWorktree = $null
    $script:ActiveRepository = $null
}

function Assert-Tools {
    $required = @('git.exe','node.exe','npm.cmd','npx.cmd','docker.exe','gcloud.cmd','gh.exe')
    foreach ($tool in $required) { if (-not (Resolve-EPExecutable @($tool))) { throw "$tool is missing. Run .\bootstrap.ps1 first." } }
    $bash = Resolve-EPExecutable @('C:\Program Files\Git\bin\bash.exe','C:\Program Files (x86)\Git\bin\bash.exe')
    if (-not $bash) { throw 'Git for Windows Bash is required; WSL Bash is intentionally not used.' }
}

function Assert-RepositoryReady {
    $repo = Get-Cfg 'ELDERPATH_REPO_PATH'
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { throw "Not a Git repository: $repo" }
    Invoke-Tool 'git.exe' @('fetch','origin',(Get-Cfg 'GITHUB_DEFAULT_BRANCH'),(Get-Cfg 'GITHUB_STAGING_BRANCH'),'--prune') -WorkingDirectory $repo | Out-Null
    $remoteRef = "origin/$(Get-Cfg 'GITHUB_DEFAULT_BRANCH')"
    $requiredFiles = @('wrangler.jsonc','services/statecare-registry/scripts/deploy_cloud_run.sh','scripts/db-promote-remote.mjs','.github/workflows/deploy.yml')
    foreach ($file in $requiredFiles) {
        $result = Invoke-Tool 'git.exe' @('cat-file','-e',"${remoteRef}:$file") -WorkingDirectory $repo -AllowFailure
        if ($result.ExitCode -ne 0) { throw "$file is not present on $remoteRef. Merge the reviewed application deployment changes before provisioning." }
    }
    if (-not $script:DryRun -and (Get-CfgBool 'CONFIGURE_GITHUB_CI')) {
        $workflowResult = Invoke-Tool 'git.exe' @('show',"${remoteRef}:.github/workflows/deploy.yml") -WorkingDirectory $repo -NoLogOutput
        $workflow = $workflowResult.StdOut
        $requiredMarkers = @('workflow_run:','branches: [dev, main]','STATECARE_REGISTRY_API_KEY_STAGING','STATECARE_REGISTRY_API_KEY_PRODUCTION','CLOUDFLARE_API_TOKEN_PRODUCTION')
        foreach ($marker in $requiredMarkers) {
            if (-not $workflow.Contains($marker)) {
                throw "The GitHub Free private-repository deployment workflow is not present on $remoteRef. Merge the reviewed unified deployment workflow before rerunning the toolkit."
            }
        }
        if ($workflow -match '(?m)^\s*environment\s*:') {
            throw "The deployment workflow on $remoteRef still uses GitHub environments, which are unsupported for this private GitHub Free deployment. Merge the reviewed unified workflow before rerunning the toolkit."
        }
    }
    if ((Get-CfgBool 'DEPLOY_PRODUCTION')) {
        $status = Invoke-Tool 'git.exe' @('status','--porcelain') -WorkingDirectory $repo -NoLogOutput
        if ($status.StdOut.Trim()) { Write-EPLog 'The application worktree is dirty. It will remain untouched; all config edits use a temporary origin/main worktree.' -Level WARN }
    }
}

function Assert-InteractiveAuthentication {
    if ($script:DryRun) { return }
    $gcp = Invoke-Gcloud @('auth','list','--filter=status:ACTIVE','--format=value(account)') -AllowFailure -NoLogOutput
    if ($gcp.ExitCode -ne 0) {
        throw 'Google Cloud CLI is installed but could not run. Review the redacted diagnostic above, verify gcloud --version, then retry.'
    }
    if (-not $gcp.StdOut.Trim()) {
        throw 'No active Google Cloud account was found. Run gcloud auth login and gcloud auth application-default login, then retry.'
    }
    $github = Invoke-Gh @('auth','status') -AllowFailure -NoLogOutput
    if ($github.ExitCode -ne 0) { throw 'No authenticated GitHub CLI session was found. Run gh auth login, then retry.' }
}

function Invoke-TestGate {
    if (-not (Get-CfgBool 'RUN_FULL_TEST_GATE')) { Write-EPLog 'RUN_FULL_TEST_GATE=false; application tests were explicitly skipped.' -Level WARN; return }
    [void](Initialize-ReviewedWorktree)
    $commands = @('format:check','lint','typecheck','test:unit','db:contract:check','test:db-automation','statecare:lint','statecare:typecheck','statecare:test','build','audit:prod','test:e2e')
    foreach ($name in $commands) { Invoke-Npm @('run',$name) | Out-Null }
}

function Invoke-ValidatePhase {
    Assert-Tools
    Assert-RepositoryReady
    Assert-InteractiveAuthentication
    $summary = [ordered]@{
        Repository = Get-Cfg 'ELDERPATH_REPO_PATH'; GoogleProject = Get-Cfg 'GCP_PROJECT_ID'; Region = Get-Cfg 'GCP_REGION'
        SupabaseStaging = Get-Cfg 'SUPABASE_STAGING_PROJECT_REF'; SupabaseProduction = Get-Cfg 'SUPABASE_PRODUCTION_PROJECT_REF'
        StagingHost = Get-Cfg 'STAGING_APP_HOST'; ProductionHost = Get-Cfg 'PRODUCTION_APP_HOST'; DryRun = $script:DryRun
    }
    Write-EPLog ("Validated configuration:`n" + ($summary | ConvertTo-Json))
}

function Test-GcloudResource([string[]]$Arguments) {
    if ($script:DryRun) { return $false }
    return (Invoke-Gcloud $Arguments -AllowFailure -NoLogOutput).ExitCode -eq 0
}

function Test-GcloudRunJobExists([string]$JobName) {
    return Test-GcloudResource @(
        'run','jobs','describe',$JobName,'--project',(Get-Cfg 'GCP_PROJECT_ID'),'--region',(Get-Cfg 'GCP_REGION')
    )
}

function Get-StateCareRequiredJobNames([string]$EnvironmentName) {
    $service = Get-Cfg "STATECARE_$($EnvironmentName.ToUpperInvariant())_SERVICE"
    return @(
        "$service-migrate",
        "$service-import-ca-rcfe",
        "$service-geocode-menifee",
        "$service-geocode-southern-california",
        "$service-geocode-california-initial",
        "$service-geocode-california-delta"
    )
}

function Get-MissingStateCareRequiredJobs([string]$EnvironmentName) {
    if ($script:DryRun) { return [string[]]@() }
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($job in (Get-StateCareRequiredJobNames $EnvironmentName)) {
        if (-not (Test-GcloudRunJobExists $job)) { [void]$missing.Add($job) }
    }
    return [string[]]$missing.ToArray()
}

function Test-GeocodioSecretReady([string]$EnvironmentName) {
    if ($script:DryRun) { return $true }
    $secretName = Get-Cfg "$($EnvironmentName.ToUpperInvariant())_GEOCODIO_API_KEY_SECRET"
    if (-not (Test-GcloudResource @('secrets','describe',$secretName,'--project',(Get-Cfg 'GCP_PROJECT_ID')))) {
        return $false
    }
    $versions = Invoke-Gcloud @(
        'secrets','versions','list',$secretName,'--project',(Get-Cfg 'GCP_PROJECT_ID'),'--filter=state:ENABLED','--format=value(name)'
    ) -AllowFailure -NoLogOutput
    return [bool]$versions.StdOut.Trim()
}

function Ensure-GeocodioSecretAccessor([string]$SecretName) {
    $project = Get-Cfg 'GCP_PROJECT_ID'
    $runtime = "$(Get-Cfg 'GCP_RUNTIME_SERVICE_ACCOUNT')@$project.iam.gserviceaccount.com"
    Invoke-Gcloud @(
        'secrets','add-iam-policy-binding',$SecretName,'--project',$project,"--member=serviceAccount:$runtime",'--role=roles/secretmanager.secretAccessor','--quiet'
    ) | Out-Null
}

function Ensure-GeocodioSecretReady([string]$EnvironmentName) {
    if ($script:DryRun) { return }
    if (Test-GeocodioSecretReady $EnvironmentName) { return }
    $tier = $EnvironmentName.ToUpperInvariant()
    $configurationKey = "${tier}_GEOCODIO_API_KEY_SECRET"
    $secretName = Get-Cfg $configurationKey
    Write-EPLog "$EnvironmentName Geocodio secret '$secretName' is missing or has no enabled version; requesting it securely."
    $value = Get-SensitiveValue -Name $configurationKey -Prompt "$EnvironmentName Geocodio API key"
    Ensure-GcpSecret -Name $secretName -InitialValue $value
    Ensure-GeocodioSecretAccessor $secretName
}

function Assert-StateCareRequiredJobsPresent([string]$EnvironmentName) {
    $missing = @(Get-MissingStateCareRequiredJobs $EnvironmentName)
    if ($missing.Count -gt 0) {
        throw "$EnvironmentName StateCare deploy finished but required Cloud Run jobs are still missing: $($missing -join ', ')."
    }
}

function Assert-StateCareGeocodeJobsReady([string]$EnvironmentName, [switch]$Refresh) {
    if ($script:DryRun) { return }
    $service = Get-Cfg "STATECARE_$($EnvironmentName.ToUpperInvariant())_SERVICE"
    $jobs = @("$service-import-ca-rcfe")
    $jobs += if ($Refresh) { "$service-geocode-california-delta" } else { "$service-geocode-california-initial" }
    foreach ($job in $jobs) {
        if (-not (Test-GcloudRunJobExists $job)) {
            throw "Cloud Run job '$job' is missing. Run -Phase DeployStaging or -Phase DeployProduction to recreate StateCare jobs, then rerun -Phase GeocodeCalifornia."
        }
    }
    if (-not $Refresh) { Ensure-GeocodioSecretReady $EnvironmentName }
}

function Invoke-StateCareDeployStep([string]$EnvironmentName, [string]$CheckpointName) {
    $missingJobs = @(Get-MissingStateCareRequiredJobs $EnvironmentName)
    if ($missingJobs.Count -gt 0 -and (Test-EPCheckpointComplete -State $script:State -Name $CheckpointName)) {
        Write-EPLog "$EnvironmentName StateCare checkpoint is complete but required Cloud Run jobs are missing: $($missingJobs -join ', '). Redeploying StateCare."
        Ensure-GeocodioSecretReady $EnvironmentName
        Invoke-StateCareDeploy $EnvironmentName
        if (-not $script:DryRun) { Complete-Step $CheckpointName }
        return
    }
    Invoke-Step $CheckpointName { Invoke-StateCareDeploy $EnvironmentName }
}

function Ensure-GcpSecret {
    param([string]$Name,[string]$InitialValue,[switch]$ForceNewVersion)
    if (-not (Test-GcloudResource @('secrets','describe',$Name,'--project',(Get-Cfg 'GCP_PROJECT_ID')))) {
        Invoke-Gcloud @('secrets','create',$Name,'--project',(Get-Cfg 'GCP_PROJECT_ID'),'--replication-policy=automatic','--quiet') | Out-Null
    }
    $versions = Invoke-Gcloud @('secrets','versions','list',$Name,'--project',(Get-Cfg 'GCP_PROJECT_ID'),'--filter=state:ENABLED','--format=value(name)') -AllowFailure -NoLogOutput
    if ($ForceNewVersion -or $RotateSecrets -or -not $versions.StdOut.Trim()) {
        if ($null -eq $InitialValue) { throw "No initial value supplied for Secret Manager resource $Name." }
        Invoke-Gcloud @('secrets','versions','add',$Name,'--project',(Get-Cfg 'GCP_PROJECT_ID'),'--data-file=-') -InputText $InitialValue -NoLogOutput | Out-Null
    }
}

function Get-SupabaseDatabaseUrlSet([ValidateSet('STAGING','PRODUCTION')][string]$Tier) {
    $environmentName = $Tier.ToLowerInvariant()
    $password = Get-SensitiveValue -Name "SUPABASE_${Tier}_DATABASE_PASSWORD" -Prompt "$environmentName Supabase database password"
    return ConvertTo-EPSupabaseConnectionUrlSet `
        -ProjectRef (Get-Cfg "SUPABASE_${Tier}_PROJECT_REF") `
        -PoolerHost (Get-Cfg "SUPABASE_${Tier}_POOLER_HOST") `
        -CredentialValue $password
}

function Test-SupabaseDatabaseConnection {
    param(
        [ValidateSet('staging','production')][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$SyncUrl
    )
    $tier = $EnvironmentName.ToUpperInvariant()
    [void](Assert-EPSupabaseUrl `
        -Value $SyncUrl `
        -Driver psycopg `
        -ProjectRef (Get-Cfg "SUPABASE_${tier}_PROJECT_REF") `
        -PoolerHost (Get-Cfg "SUPABASE_${tier}_POOLER_HOST") `
        -Context "$EnvironmentName Supabase sync session-pooler URL")
    $uri = [uri]$SyncUrl
    $userInfo = [uri]::UnescapeDataString($uri.UserInfo).Split(':',2)
    $environment = @{ PGPASSWORD=$userInfo[1]; PGSSLMODE='require' }
    Add-EPRedaction $userInfo[1]
    $result = Invoke-Tool 'docker.exe' @(
        'run','--rm','-e','PGPASSWORD','-e','PGSSLMODE','postgres:17-alpine','psql',
        '-h',$uri.Host,'-p',([string]$uri.Port),'-U',$userInfo[0],'-d',$uri.AbsolutePath.TrimStart('/'),
        '-tAc','SELECT 1;'
    ) -Environment $environment -AllowFailure -NoLogOutput
    if ($script:DryRun) { return }
    if ($result.ExitCode -ne 0 -or $result.StdOut.Trim() -ne '1') {
        throw "$EnvironmentName Supabase database connection preflight failed. Verify the database password, then run -Phase RepairDatabaseSecrets."
    }
    Write-EPLog "$EnvironmentName Supabase database connection preflight succeeded."
}

function Invoke-SupabaseDatabaseSecretUpdate([switch]$ForceNewVersion) {
    $urls = @{
        STAGING = Get-SupabaseDatabaseUrlSet 'STAGING'
        PRODUCTION = Get-SupabaseDatabaseUrlSet 'PRODUCTION'
    }
    Invoke-EPValidatedSecretPublication -UrlSets $urls `
        -Probe {
            param($environmentName,$syncUrl)
            Test-SupabaseDatabaseConnection -EnvironmentName $environmentName -SyncUrl $syncUrl
        } `
        -Publish {
            param($configurationKey,$value)
            Ensure-GcpSecret -Name (Get-Cfg $configurationKey) -InitialValue $value -ForceNewVersion:$ForceNewVersion
        }
}

function Test-LatestSupabaseDatabaseSecret([ValidateSet('staging','production')][string]$EnvironmentName) {
    $tier = $EnvironmentName.ToUpperInvariant()
    $urlSet = if ($script:DryRun) {
        ConvertTo-EPSupabaseConnectionUrlSet `
            -ProjectRef (Get-Cfg "SUPABASE_${tier}_PROJECT_REF") `
            -PoolerHost (Get-Cfg "SUPABASE_${tier}_POOLER_HOST") `
            -CredentialValue '[DRY-RUN-SECRET]'
    } else {
        [pscustomobject]@{
            Async = Get-GcpSecret (Get-Cfg "${tier}_DATABASE_URL_SECRET")
            Sync = Get-GcpSecret (Get-Cfg "${tier}_DATABASE_URL_SYNC_SECRET")
        }
    }
    try {
        [void](Assert-EPSupabaseUrl `
            -Value $urlSet.Async `
            -Driver asyncpg `
            -ProjectRef (Get-Cfg "SUPABASE_${tier}_PROJECT_REF") `
            -PoolerHost (Get-Cfg "SUPABASE_${tier}_POOLER_HOST") `
            -Context "$EnvironmentName latest Supabase async session-pooler URL")
    } catch {
        throw "$($_.Exception.Message) Run -Phase RepairDatabaseSecrets before deploying StateCare."
    }
    Test-SupabaseDatabaseConnection -EnvironmentName $EnvironmentName -SyncUrl $urlSet.Sync
}

function Invoke-RepairDatabaseSecretsPhase {
    Invoke-SupabaseDatabaseSecretUpdate -ForceNewVersion
    if (-not $script:DryRun) {
        $script:State.Resources['DatabaseSecretsRepairedAt'] = (Get-Date).ToUniversalTime().ToString('o')
        Complete-Step 'gcp.database-secrets.repaired.v1'
    }
    Write-EPLog 'Supabase database URL secrets were validated and updated without rotating unrelated secrets.'
}

function Get-GcpSecret([string]$Name) {
    $result = Invoke-Gcloud @('secrets','versions','access','latest','--secret',$Name,'--project',(Get-Cfg 'GCP_PROJECT_ID')) -NoLogOutput
    $value = if ($script:DryRun) { "[DRY-RUN-GCP-SECRET:$Name]" } else { $result.StdOut.Trim() }
    Add-EPRedaction $value
    return $value
}

function Resolve-StateCareServiceUrl(
    [ValidateSet('staging','production')][string]$EnvironmentName,
    [switch]$AllowMissing
) {
    $existing = [string]$script:State.Resources["${EnvironmentName}StateCareUrl"]
    if ($existing) { return $existing }
    $service = Get-Cfg "STATECARE_$($EnvironmentName.ToUpperInvariant())_SERVICE"
    $result = Invoke-Gcloud @(
        'run','services','describe',$service,
        '--project',(Get-Cfg 'GCP_PROJECT_ID'),
        '--region',(Get-Cfg 'GCP_REGION'),
        '--format=value(status.url)'
    ) -NoLogOutput -AllowFailure:$AllowMissing
    if (-not $script:DryRun -and $result.ExitCode -ne 0) {
        if ($AllowMissing) { return '' }
        throw "Unable to resolve the $EnvironmentName StateCare service URL."
    }
    $url = if ($script:DryRun) { "https://$service.$(Get-Cfg 'GCP_REGION').run.invalid" } else { $result.StdOut.Trim() }
    if ($url -notmatch '^https://[^/]+$') { throw "Unable to resolve the $EnvironmentName StateCare service URL." }
    $script:State.Resources["${EnvironmentName}StateCareUrl"] = $url
    return $url
}

function Invoke-ProvisionPhase {
    $project = Get-Cfg 'GCP_PROJECT_ID'; $region = Get-Cfg 'GCP_REGION'
    Invoke-Step 'gcp.project' {
        if (-not (Test-GcloudResource @('projects','describe',$project))) { Invoke-Gcloud @('projects','create',$project,'--name=ElderPath Production','--quiet') | Out-Null }
        Invoke-Gcloud @('billing','projects','link',$project,'--billing-account',(Get-Cfg 'GCP_BILLING_ACCOUNT_ID'),'--quiet') | Out-Null
        Invoke-Gcloud @('config','set','project',$project) | Out-Null
    }
    Invoke-Step 'gcp.apis' {
        Invoke-Gcloud (@('services','enable','run.googleapis.com','artifactregistry.googleapis.com','cloudbuild.googleapis.com','secretmanager.googleapis.com','iamcredentials.googleapis.com','sts.googleapis.com','cloudscheduler.googleapis.com','cloudbilling.googleapis.com','billingbudgets.googleapis.com','monitoring.googleapis.com','--project',$project)) | Out-Null
    }
    Invoke-Step 'gcp.artifact-registry' {
        $repo = Get-Cfg 'GCP_ARTIFACT_REPOSITORY'
        if (-not (Test-GcloudResource @('artifacts','repositories','describe',$repo,'--location',$region,'--project',$project))) {
            Invoke-Gcloud @('artifacts','repositories','create',$repo,'--repository-format=docker','--location',$region,'--project',$project,'--description=ElderPath StateCare images','--quiet') | Out-Null
        }
        $policyPath = Join-Path $PSScriptRoot 'state\artifact-cleanup-policy.json'
        if (-not $script:DryRun) {
            [System.IO.Directory]::CreateDirectory((Split-Path $policyPath)) | Out-Null
            $policy = ConvertTo-EPArtifactCleanupPolicyJson `
                -KeepCount ([int](Get-Cfg 'GCP_ARTIFACT_KEEP_COUNT')) `
                -RetentionDays ([int](Get-Cfg 'ARTIFACT_RETENTION_DAYS'))
            [void](Assert-EPArtifactCleanupPolicyJson -Json $policy)
            [System.IO.File]::WriteAllText($policyPath,$policy,[Text.UTF8Encoding]::new($false))
        }
        Invoke-Gcloud @('artifacts','repositories','set-cleanup-policies',$repo,'--location',$region,'--project',$project,"--policy=$policyPath",'--no-dry-run','--quiet') | Out-Null
    }
    Invoke-Step 'gcp.service-accounts' {
        foreach ($pair in @(@((Get-Cfg 'GCP_RUNTIME_SERVICE_ACCOUNT'),'StateCare runtime'),@((Get-Cfg 'GCP_DEPLOY_SERVICE_ACCOUNT'),'GitHub deployment'))) {
            $email = "$($pair[0])@$project.iam.gserviceaccount.com"
            if (-not (Test-GcloudResource @('iam','service-accounts','describe',$email,'--project',$project))) {
                Invoke-Gcloud @('iam','service-accounts','create',$pair[0],'--display-name',$pair[1],'--project',$project) | Out-Null
            }
        }
    }
    Invoke-Step 'gcp.secrets' {
        Invoke-SupabaseDatabaseSecretUpdate
        $definitions = @(
            @('STAGING_REGISTRY_KEY_SECRET','', $true), @('STAGING_ADMIN_KEY_SECRET','', $true),
            @('PRODUCTION_REGISTRY_KEY_SECRET','', $true), @('PRODUCTION_ADMIN_KEY_SECRET','', $true)
        )
        foreach ($definition in $definitions) {
            $secretName = Get-Cfg $definition[0]
            $value = Get-SensitiveValue -Name $definition[0] -Prompt $definition[1] -Generate:$definition[2]
            Ensure-GcpSecret -Name $secretName -InitialValue $value
        }
        Ensure-GeocodioSecretReady 'staging'
        Ensure-GeocodioSecretReady 'production'
        $runtime = "$(Get-Cfg 'GCP_RUNTIME_SERVICE_ACCOUNT')@$project.iam.gserviceaccount.com"
        foreach ($secretKey in @(
            'STAGING_DATABASE_URL_SECRET','STAGING_DATABASE_URL_SYNC_SECRET','PRODUCTION_DATABASE_URL_SECRET','PRODUCTION_DATABASE_URL_SYNC_SECRET',
            'STAGING_REGISTRY_KEY_SECRET','STAGING_ADMIN_KEY_SECRET','PRODUCTION_REGISTRY_KEY_SECRET','PRODUCTION_ADMIN_KEY_SECRET',
            'STAGING_GEOCODIO_API_KEY_SECRET','PRODUCTION_GEOCODIO_API_KEY_SECRET'
        )) {
            Invoke-Gcloud @('secrets','add-iam-policy-binding',(Get-Cfg $secretKey),'--project',$project,"--member=serviceAccount:$runtime",'--role=roles/secretmanager.secretAccessor','--quiet') | Out-Null
        }
    }
    foreach ($environmentName in @('staging','production')) {
        Ensure-GeocodioSecretReady $environmentName
    }
    Invoke-Step 'gcp.deploy-iam' {
        $deploy = "$(Get-Cfg 'GCP_DEPLOY_SERVICE_ACCOUNT')@$project.iam.gserviceaccount.com"
        foreach ($role in @('roles/run.admin','roles/artifactregistry.writer','roles/iam.serviceAccountUser','roles/secretmanager.viewer')) {
            Invoke-Gcloud @('projects','add-iam-policy-binding',$project,"--member=serviceAccount:$deploy","--role=$role",'--condition=None','--quiet') | Out-Null
        }
    }
    Invoke-Step 'gcp.budget' {
        $existing = Invoke-Gcloud @('billing','budgets','list','--billing-account',(Get-Cfg 'GCP_BILLING_ACCOUNT_ID'),'--filter=displayName:ElderPath-Monthly-Budget','--format=value(name)') -AllowFailure -NoLogOutput
        if (-not $existing.StdOut.Trim()) {
            Invoke-Gcloud @('billing','budgets','create','--billing-account',(Get-Cfg 'GCP_BILLING_ACCOUNT_ID'),'--display-name=ElderPath-Monthly-Budget',"--budget-amount=$(Get-Cfg 'GCP_MONTHLY_BUDGET_USD')USD",'--threshold-rule=percent=0.5','--threshold-rule=percent=0.9','--threshold-rule=percent=1.0') | Out-Null
        }
    }
}

function Invoke-ConfigureCIPhase {
    $project = Get-Cfg 'GCP_PROJECT_ID'; $pool = Get-Cfg 'GCP_WORKLOAD_IDENTITY_POOL'; $provider = Get-Cfg 'GCP_WORKLOAD_IDENTITY_PROVIDER'
    $repository = "$(Get-Cfg 'GITHUB_OWNER')/$(Get-Cfg 'GITHUB_REPOSITORY')"; $branch = "refs/heads/$(Get-Cfg 'GITHUB_DEFAULT_BRANCH')"
    Invoke-Step 'github.wif' {
        if (-not (Test-GcloudResource @('iam','workload-identity-pools','describe',$pool,'--location=global','--project',$project))) {
            Invoke-Gcloud @('iam','workload-identity-pools','create',$pool,'--location=global','--project',$project,'--display-name=GitHub Actions') | Out-Null
        }
        if (-not (Test-GcloudResource @('iam','workload-identity-pools','providers','describe',$provider,"--workload-identity-pool=$pool",'--location=global','--project',$project))) {
            $condition = "assertion.repository=='$repository' && assertion.ref=='$branch'"
            Invoke-Gcloud @('iam','workload-identity-pools','providers','create-oidc',$provider,"--workload-identity-pool=$pool",'--location=global','--project',$project,'--issuer-uri=https://token.actions.githubusercontent.com','--attribute-mapping=google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref',"--attribute-condition=$condition") | Out-Null
        }
        $numberResult = Invoke-Gcloud @('projects','describe',$project,'--format=value(projectNumber)') -NoLogOutput
        $number = if($script:DryRun){'000000000000'}else{$numberResult.StdOut.Trim()}
        $principal = "principalSet://iam.googleapis.com/projects/$number/locations/global/workloadIdentityPools/$pool/attribute.repository/$repository"
        $deploy = "$(Get-Cfg 'GCP_DEPLOY_SERVICE_ACCOUNT')@$project.iam.gserviceaccount.com"
        Invoke-Gcloud @('iam','service-accounts','add-iam-policy-binding',$deploy,'--project',$project,"--member=$principal",'--role=roles/iam.workloadIdentityUser','--quiet') | Out-Null
        $script:State.Resources['WorkloadIdentityProvider'] = "projects/$number/locations/global/workloadIdentityPools/$pool/providers/$provider"
    }
    Invoke-Step 'github.wif.workflow-policy' {
        $workflowRef = "$repository/.github/workflows/deploy.yml@$branch"
        $mapping = 'google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.workflow_ref=assertion.workflow_ref'
        $condition = "assertion.repository=='$repository' && assertion.ref=='$branch' && assertion.workflow_ref=='$workflowRef'"
        Invoke-Gcloud @(
            'iam','workload-identity-pools','providers','update-oidc',$provider,
            "--workload-identity-pool=$pool",'--location=global',"--project=$project",
            '--issuer-uri=https://token.actions.githubusercontent.com',"--attribute-mapping=$mapping","--attribute-condition=$condition"
        ) | Out-Null
        if (-not $script:State.Resources.WorkloadIdentityProvider) {
            $numberResult = Invoke-Gcloud @('projects','describe',$project,'--format=value(projectNumber)') -NoLogOutput
            $number = if ($script:DryRun) { '000000000000' } else { $numberResult.StdOut.Trim() }
            $script:State.Resources['WorkloadIdentityProvider'] = "projects/$number/locations/global/workloadIdentityPools/$pool/providers/$provider"
        }
    }
    Invoke-Step 'github.repository-settings' {
        $owner = Get-Cfg 'GITHUB_OWNER'; $repo = Get-Cfg 'GITHUB_REPOSITORY'; $repoSlug = "$owner/$repo"
        $variables = @{
            GCP_PROJECT_ID=$project
            GCP_REGION=Get-Cfg 'GCP_REGION'
            GCP_ARTIFACT_REPOSITORY=Get-Cfg 'GCP_ARTIFACT_REPOSITORY'
            GCP_WORKLOAD_IDENTITY_PROVIDER=$script:State.Resources.WorkloadIdentityProvider
            GCP_DEPLOY_SERVICE_ACCOUNT="$(Get-Cfg 'GCP_DEPLOY_SERVICE_ACCOUNT')@$project.iam.gserviceaccount.com"
            STATECARE_RUNTIME_SERVICE_ACCOUNT="$(Get-Cfg 'GCP_RUNTIME_SERVICE_ACCOUNT')@$project.iam.gserviceaccount.com"
            NOMINATIM_USER_AGENT=Get-Cfg 'NOMINATIM_USER_AGENT'
            CALIFORNIA_RCFE_SOURCE_URL=Get-Cfg 'CALIFORNIA_RCFE_SOURCE_URL'
            CLOUDFLARE_ACCOUNT_ID=Get-Cfg 'CLOUDFLARE_ACCOUNT_ID'
            STAGING_DEPLOYMENT_URL="https://$(Get-Cfg 'STAGING_APP_HOST')"
            PRODUCTION_DEPLOYMENT_URL="https://$(Get-Cfg 'PRODUCTION_APP_HOST')"
            STATECARE_STAGING_SERVICE_NAME=Get-Cfg 'STATECARE_STAGING_SERVICE'
            STATECARE_PRODUCTION_SERVICE_NAME=Get-Cfg 'STATECARE_PRODUCTION_SERVICE'
            STATECARE_STAGING_DATABASE_URL_SECRET=Get-Cfg 'STAGING_DATABASE_URL_SECRET'
            STATECARE_STAGING_DATABASE_URL_SYNC_SECRET=Get-Cfg 'STAGING_DATABASE_URL_SYNC_SECRET'
            STATECARE_STAGING_REGISTRY_API_KEY_SECRET=Get-Cfg 'STAGING_REGISTRY_KEY_SECRET'
            STATECARE_STAGING_ADMIN_API_KEY_SECRET=Get-Cfg 'STAGING_ADMIN_KEY_SECRET'
            STATECARE_STAGING_GEOCODIO_API_KEY_SECRET=Get-Cfg 'STAGING_GEOCODIO_API_KEY_SECRET'
            STATECARE_PRODUCTION_DATABASE_URL_SECRET=Get-Cfg 'PRODUCTION_DATABASE_URL_SECRET'
            STATECARE_PRODUCTION_DATABASE_URL_SYNC_SECRET=Get-Cfg 'PRODUCTION_DATABASE_URL_SYNC_SECRET'
            STATECARE_PRODUCTION_REGISTRY_API_KEY_SECRET=Get-Cfg 'PRODUCTION_REGISTRY_KEY_SECRET'
            STATECARE_PRODUCTION_ADMIN_API_KEY_SECRET=Get-Cfg 'PRODUCTION_ADMIN_KEY_SECRET'
            STATECARE_PRODUCTION_GEOCODIO_API_KEY_SECRET=Get-Cfg 'PRODUCTION_GEOCODIO_API_KEY_SECRET'
            STATECARE_STAGING_VERIFY_ENABLED='false'
            STATECARE_PRODUCTION_VERIFY_ENABLED='false'
        }
        foreach ($environmentName in @('staging','production')) {
            $url = Resolve-StateCareServiceUrl $environmentName -AllowMissing
            if ($url) {
                $variables["STATECARE_REGISTRY_URL_$($environmentName.ToUpperInvariant())"] = $url
            } else {
                Write-EPLog "$environmentName StateCare service does not exist yet; ConfigureReleaseTopology or ManualRelease will set its repository URL after deployment." -Level WARN
            }
        }
        foreach ($pair in $variables.GetEnumerator()) {
            Invoke-Gh @('variable','set',$pair.Key,'--repo',$repoSlug,'--body',[string]$pair.Value) | Out-Null
        }

        $repositorySecretNames = @{
            STAGING=@{Registry='STATECARE_REGISTRY_API_KEY_STAGING';Cloudflare='CLOUDFLARE_API_TOKEN_STAGING'}
            PRODUCTION=@{Registry='STATECARE_REGISTRY_API_KEY_PRODUCTION';Cloudflare='CLOUDFLARE_API_TOKEN_PRODUCTION'}
        }
        foreach ($tier in @('STAGING','PRODUCTION')) {
            $registryKey = Get-GcpSecret (Get-Cfg "${tier}_REGISTRY_KEY_SECRET")
            Invoke-Gh @('secret','set',$repositorySecretNames[$tier].Registry,'--repo',$repoSlug) -InputText $registryKey -NoLogOutput | Out-Null
            $cloudflareToken = Get-SensitiveValue -Name "CLOUDFLARE_CI_TOKEN_$tier" -Prompt "Cloudflare $($tier.ToLowerInvariant()) CI deployment token"
            Invoke-Gh @('secret','set',$repositorySecretNames[$tier].Cloudflare,'--repo',$repoSlug) -InputText $cloudflareToken -NoLogOutput | Out-Null
        }
    }
}

function Initialize-CloudflareToken {
    if ($script:CloudflareEnvironment.ContainsKey('CLOUDFLARE_API_TOKEN')) { return }
    $token = Get-SensitiveValue -Name 'CLOUDFLARE_BOOTSTRAP_TOKEN' -Prompt 'Local Cloudflare bootstrap token'
    $script:CloudflareEnvironment = @{ CLOUDFLARE_API_TOKEN=$token; CLOUDFLARE_ACCOUNT_ID=(Get-Cfg 'CLOUDFLARE_ACCOUNT_ID') }
}

function Get-D1Databases {
    if ($script:DryRun) { return @() }
    $result = Invoke-Wrangler @('d1','list','--json')
    return @($result.StdOut | ConvertFrom-Json)
}

function Ensure-D1Database([string]$Name) {
    $database = Get-D1Databases | Where-Object name -eq $Name | Select-Object -First 1
    if (-not $database) {
        Invoke-Wrangler @('d1','create',$Name,'--location',(Get-Cfg 'CLOUDFLARE_D1_LOCATION')) | Out-Null
        $database = Get-D1Databases | Where-Object name -eq $Name | Select-Object -First 1
    }
    if ($script:DryRun) { return "DRY-RUN-$Name-ID" }
    if (-not $database.uuid) { throw "Unable to resolve D1 UUID for $Name." }
    return [string]$database.uuid
}

function Ensure-R2Bucket([string]$Name) {
    $list = Invoke-Wrangler @('r2','bucket','list') -AllowFailure
    if ($list.StdOut -notmatch [regex]::Escape($Name)) { Invoke-Wrangler @('r2','bucket','create',$Name,'--location',(Get-Cfg 'CLOUDFLARE_R2_LOCATION')) | Out-Null }
}

function Invoke-ConfigureCloudflarePhase {
    Initialize-CloudflareToken
    Invoke-Step 'cloudflare.zone-identity' {
        if($script:DryRun){Write-EPLog 'WHATIF verify Cloudflare zone name and owning account';return}
        $headers=@{Authorization="Bearer $($script:CloudflareEnvironment.CLOUDFLARE_API_TOKEN)"}
        $response=Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$(Get-Cfg 'CLOUDFLARE_ZONE_ID')" -Headers $headers -Method Get
        if(-not$response.success){throw 'Cloudflare zone lookup failed.'}
        if($response.result.name -ne (Get-Cfg 'PRIMARY_DOMAIN')){throw "Cloudflare zone is '$($response.result.name)', not PRIMARY_DOMAIN."}
        if($response.result.account.id -and $response.result.account.id -ne (Get-Cfg 'CLOUDFLARE_ACCOUNT_ID')){throw 'Cloudflare zone belongs to a different account.'}
    }
    Invoke-Step 'cloudflare.storage' {
        $script:State.Resources['StagingD1Id'] = Ensure-D1Database (Get-Cfg 'CLOUDFLARE_STAGING_D1_NAME')
        $script:State.Resources['ProductionD1Id'] = Ensure-D1Database (Get-Cfg 'CLOUDFLARE_PRODUCTION_D1_NAME')
        Ensure-R2Bucket (Get-Cfg 'CLOUDFLARE_STAGING_R2_BUCKET'); Ensure-R2Bucket (Get-Cfg 'CLOUDFLARE_PRODUCTION_R2_BUCKET')
    }
    Invoke-Step 'resend.domain' {
        $resendKey = Get-SensitiveValue -Name 'RESEND_API_KEY' -Prompt 'Resend API key'
        if ($script:DryRun) { Write-EPLog 'WHATIF create/verify Resend sending domain and exact Cloudflare DNS records'; return }
        $headers = @{Authorization="Bearer $resendKey";'Content-Type'='application/json'}
        $domain = Get-Cfg 'EMAIL_SENDING_DOMAIN'
        $domains = Invoke-RestMethod -Uri 'https://api.resend.com/domains' -Headers $headers -Method Get
        $record = @($domains.data | Where-Object name -eq $domain | Select-Object -First 1)
        if (-not $record) { $record = Invoke-RestMethod -Uri 'https://api.resend.com/domains' -Headers $headers -Method Post -Body (@{name=$domain;region='us-west-1'}|ConvertTo-Json) }
        else { $record = Invoke-RestMethod -Uri "https://api.resend.com/domains/$($record.id)" -Headers $headers -Method Get }
        $cfHeaders = @{Authorization="Bearer $($script:CloudflareEnvironment.CLOUDFLARE_API_TOKEN)";'Content-Type'='application/json'}
        foreach ($dns in @($record.records)) {
            $type = [string]$dns.type; $name = [string]$dns.name; $value = [string]$dns.value
            $query = "https://api.cloudflare.com/client/v4/zones/$(Get-Cfg 'CLOUDFLARE_ZONE_ID')/dns_records?type=$type&name=$([uri]::EscapeDataString($name))"
            $existing = Invoke-RestMethod -Uri $query -Headers $cfHeaders -Method Get
            $same = @($existing.result | Where-Object content -eq $value)
            if ($existing.result.Count -and -not $same.Count) { throw "Conflicting Cloudflare DNS record exists for $type $name; refusing to overwrite it." }
            if (-not $same.Count) {
                $body = ConvertTo-EPCloudflareDnsRecordBody -Type $type -Name $name -Content $value -SourceRecord $dns
                try {
                    Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$(Get-Cfg 'CLOUDFLARE_ZONE_ID')/dns_records" -Headers $cfHeaders -Method Post -Body ($body|ConvertTo-Json) | Out-Null
                } catch {
                    $errorPayload = if ($null -ne $_.ErrorDetails) { [string]$_.ErrorDetails.Message } else { '' }
                    if (Test-EPCloudflareApiErrorCode -Payload $errorPayload -Code 81058) {
                        Write-EPLog "Cloudflare reports that the identical $type DNS record already exists; reusing it."
                    } else {
                        throw
                    }
                }
            }
        }
        Invoke-RestMethod -Uri "https://api.resend.com/domains/$($record.id)/verify" -Headers $headers -Method Post | Out-Null
        $deadline=(Get-Date).AddMinutes(5); do { Start-Sleep -Seconds 10; $checked=Invoke-RestMethod -Uri "https://api.resend.com/domains/$($record.id)" -Headers $headers -Method Get; if($checked.status -eq 'verified'){break} } while((Get-Date)-lt $deadline)
        if ($checked.status -ne 'verified') { throw "Resend verification is still '$($checked.status)'. Correct DNS if needed, then rerun -Phase Resume." }
    }
}

function Get-StateCareEnvironment([string]$EnvironmentName) {
    $upper = $EnvironmentName.ToUpperInvariant()
    return @{
        GCP_PROJECT_ID=Get-Cfg 'GCP_PROJECT_ID'; GCP_REGION=Get-Cfg 'GCP_REGION'; GCP_ARTIFACT_REPOSITORY=Get-Cfg 'GCP_ARTIFACT_REPOSITORY'
        STATECARE_RUNTIME_SERVICE_ACCOUNT="$(Get-Cfg 'GCP_RUNTIME_SERVICE_ACCOUNT')@$(Get-Cfg 'GCP_PROJECT_ID').iam.gserviceaccount.com"
        STATECARE_SERVICE_NAME=Get-Cfg "STATECARE_${upper}_SERVICE"; ELDERPATH_ORIGIN="https://$(Get-Cfg "${upper}_APP_HOST")"
        NOMINATIM_USER_AGENT=Get-Cfg 'NOMINATIM_USER_AGENT'; CALIFORNIA_RCFE_SOURCE_URL=Get-Cfg 'CALIFORNIA_RCFE_SOURCE_URL'
        DATABASE_URL_SECRET=Get-Cfg "${upper}_DATABASE_URL_SECRET"; DATABASE_URL_SYNC_SECRET=Get-Cfg "${upper}_DATABASE_URL_SYNC_SECRET"
        STATECARE_REGISTRY_API_KEY_SECRET=Get-Cfg "${upper}_REGISTRY_KEY_SECRET"; ADMIN_API_KEY_SECRET=Get-Cfg "${upper}_ADMIN_KEY_SECRET"
        GEOCODIO_API_KEY_SECRET=Get-Cfg "${upper}_GEOCODIO_API_KEY_SECRET"
        GEOCODIO_INITIAL_BATCH_SIZE=Get-Cfg 'GEOCODIO_INITIAL_BATCH_SIZE'
        GEOCODIO_INITIAL_MAX_ITEMS=Get-Cfg 'GEOCODIO_INITIAL_MAX_ITEMS'
        GEOCODIO_MIN_ACCURACY=Get-Cfg 'GEOCODIO_MIN_ACCURACY'
        STATEWIDE_GEOCODING_REQUIRED_COVERAGE_PERCENT=Get-Cfg 'STATEWIDE_GEOCODING_REQUIRED_COVERAGE_PERCENT'
        CALIFORNIA_NOMINATIM_DELTA_LIMIT=Get-Cfg 'CALIFORNIA_NOMINATIM_DELTA_LIMIT'
        GITHUB_SHA='manual'
    }
}

function Test-SupabaseSize([string]$EnvironmentName) {
    if ($script:DryRun) { Write-EPLog "WHATIF query $EnvironmentName PostgreSQL size through ephemeral postgres container"; return }
    $upper=$EnvironmentName.ToUpperInvariant(); $url=Get-GcpSecret (Get-Cfg "${upper}_DATABASE_URL_SYNC_SECRET")
    $uri=[uri]$url; $userInfo=[uri]::UnescapeDataString($uri.UserInfo).Split(':',2); $database=$uri.AbsolutePath.TrimStart('/')
    $dockerEnv=@{PGPASSWORD=$userInfo[1]}; Add-EPRedaction $userInfo[1]
    $result=Invoke-Tool 'docker.exe' @('run','--rm','-e','PGPASSWORD','postgres:17-alpine','psql','-h',$uri.Host,'-p',([string]$uri.Port),'-U',$userInfo[0],'-d',$database,'-tAc','SELECT pg_database_size(current_database());') -Environment $dockerEnv -NoLogOutput
    $bytes=[long]$result.StdOut.Trim(); Write-EPLog "$EnvironmentName Supabase database size: $bytes bytes"
    if ($bytes -ge [long](Get-Cfg 'SUPABASE_DATABASE_BLOCK_BYTES')) { throw "$EnvironmentName database size is at/above the configured Free-plan deployment block threshold." }
    if ($bytes -ge [long](Get-Cfg 'SUPABASE_DATABASE_WARNING_BYTES')) { Write-EPLog "$EnvironmentName database is approaching the Free-plan threshold; upgrade or reduce retained data." -Level WARN }
}

function Invoke-StateCareDeploy([string]$EnvironmentName) {
    Test-LatestSupabaseDatabaseSecret $EnvironmentName
    Ensure-GeocodioSecretReady $EnvironmentName
    [void](Initialize-ReviewedWorktree)
    $repo=Get-ExecutionRepository; $bash=Resolve-EPExecutable @('C:\Program Files\Git\bin\bash.exe','C:\Program Files (x86)\Git\bin\bash.exe')
    $envMap=Get-StateCareEnvironment $EnvironmentName
    $shaResult=Invoke-Tool 'git.exe' @('rev-parse','HEAD') -WorkingDirectory $repo -NoLogOutput
    $envMap.GITHUB_SHA=if($script:DryRun){'dry-run-sha'}else{$shaResult.StdOut.Trim()}
    $scriptPath=(Join-Path $repo 'services\statecare-registry\scripts\deploy_cloud_run.sh').Replace('\','/')
    Invoke-Tool $bash @($scriptPath) -WorkingDirectory $repo -Environment $envMap | Out-Null
    Assert-StateCareRequiredJobsPresent $EnvironmentName
    $service=Get-Cfg "STATECARE_$($EnvironmentName.ToUpperInvariant())_SERVICE"; $project=Get-Cfg 'GCP_PROJECT_ID';$region=Get-Cfg 'GCP_REGION'
    Invoke-Gcloud @('run','services','update',$service,'--project',$project,'--region',$region,"--min=$(Get-Cfg 'STATECARE_MIN_INSTANCES')","--max=$(Get-Cfg 'STATECARE_MAX_INSTANCES')","--concurrency=$(Get-Cfg 'STATECARE_CONCURRENCY')","--timeout=$(Get-Cfg 'STATECARE_REQUEST_TIMEOUT_SECONDS')s",'--quiet') | Out-Null
    Invoke-Gcloud @('run','jobs','update',"$service-geocode-menifee",'--project',$project,'--region',$region,'--command=python',"--args=-m,scripts.drain_geocoding_queue,--scope,menifee,--mode,delta,--max-items,$(Get-Cfg 'MENIFEE_GEOCODING_LIMIT')",'--quiet') | Out-Null
    Invoke-Gcloud @('run','jobs','update',"$service-geocode-southern-california",'--project',$project,'--region',$region,'--command=python',"--args=-m,scripts.drain_geocoding_queue,--scope,southern-california,--mode,delta,--max-items,$(Get-Cfg 'SOUTHERN_CALIFORNIA_GEOCODING_LIMIT')",'--quiet') | Out-Null
    Invoke-Gcloud @('run','jobs','update',"$service-geocode-california-initial",'--project',$project,'--region',$region,'--command=python',"--args=-m,scripts.drain_geocoding_queue,--scope,california,--mode,initial,--batch-size,$(Get-Cfg 'GEOCODIO_INITIAL_BATCH_SIZE'),--max-items,$(Get-Cfg 'GEOCODIO_INITIAL_MAX_ITEMS'),--required-coverage-percent,$(Get-Cfg 'STATEWIDE_GEOCODING_REQUIRED_COVERAGE_PERCENT')",'--quiet') | Out-Null
    Invoke-Gcloud @('run','jobs','update',"$service-geocode-california-delta",'--project',$project,'--region',$region,'--command=python',"--args=-m,scripts.drain_geocoding_queue,--scope,california,--mode,delta,--max-items,$(Get-Cfg 'CALIFORNIA_NOMINATIM_DELTA_LIMIT')",'--quiet') | Out-Null
    $urlResult=Invoke-Gcloud @('run','services','describe',$service,'--project',$project,'--region',$region,'--format=value(status.url)') -NoLogOutput
    $url=if($script:DryRun){"https://$service.$region.run.invalid"}else{$urlResult.StdOut.Trim()}
    $script:State.Resources["${EnvironmentName}StateCareUrl"]=$url
    Test-SupabaseSize $EnvironmentName
}

function Invoke-StateCareDataVerify([string]$EnvironmentName) {
    $service=Get-Cfg "STATECARE_$($EnvironmentName.ToUpperInvariant())_SERVICE"
    $url=[string]$script:State.Resources["${EnvironmentName}StateCareUrl"]
    if (-not $url) {
        $project=Get-Cfg 'GCP_PROJECT_ID'; $region=Get-Cfg 'GCP_REGION'
        $urlResult=Invoke-Gcloud @('run','services','describe',$service,'--project',$project,'--region',$region,'--format=value(status.url)') -NoLogOutput
        $url=if($script:DryRun){"https://$service.$region.run.invalid"}else{$urlResult.StdOut.Trim()}
        $script:State.Resources["${EnvironmentName}StateCareUrl"]=$url
    }
    Test-SupabaseSize $EnvironmentName
    $key=Get-GcpSecret (Get-Cfg "$($EnvironmentName.ToUpperInvariant())_REGISTRY_KEY_SECRET")
    Invoke-Npm @('run','statecare:verify') -Environment @{STATECARE_REGISTRY_URL=$url;STATECARE_REGISTRY_API_KEY=$key} | Out-Null
    if(Get-CfgBool 'CONFIGURE_GITHUB_CI'){
        $tier=$EnvironmentName.ToUpperInvariant()
        Invoke-Gh @('variable','set',"STATECARE_${tier}_VERIFY_ENABLED",'--repo',"$(Get-Cfg 'GITHUB_OWNER')/$(Get-Cfg 'GITHUB_REPOSITORY')",'--body','true')|Out-Null
    }
}

function Invoke-GeocodeCaliforniaEnvironment([string]$EnvironmentName,[switch]$Refresh) {
    Assert-StateCareGeocodeJobsReady $EnvironmentName -Refresh:$Refresh
    $service=Get-Cfg "STATECARE_$($EnvironmentName.ToUpperInvariant())_SERVICE"
    $project=Get-Cfg 'GCP_PROJECT_ID'
    $region=Get-Cfg 'GCP_REGION'
    Invoke-Gcloud @('run','jobs','execute',"$service-import-ca-rcfe",'--project',$project,'--region',$region,'--wait','--quiet') | Out-Null
    $job=if($Refresh){"$service-geocode-california-delta"}else{"$service-geocode-california-initial"}
    Invoke-Gcloud @('run','jobs','execute',$job,'--project',$project,'--region',$region,'--wait','--quiet') | Out-Null
    if (-not $Refresh) {
        $script:State.Resources["${EnvironmentName}CaliforniaGeocode"]='completed'
        if (-not $script:DryRun) { Save-EPCheckpoint -Root $PSScriptRoot -State $script:State }
    }
    Invoke-StateCareDataVerify $EnvironmentName
}

function Invoke-GeocodeCaliforniaPhase {
    foreach ($environmentName in @('staging','production')) {
        if ($environmentName -eq 'staging' -and -not (Get-CfgBool 'DEPLOY_STAGING')) { continue }
        if ($environmentName -eq 'production' -and -not (Get-CfgBool 'DEPLOY_PRODUCTION')) { continue }
        $checkpoint="statecare.california-geocode.$environmentName.v1"
        if (-not (Test-EPCheckpointComplete -State $script:State -Name $checkpoint)) {
            Invoke-Step $checkpoint { Invoke-GeocodeCaliforniaEnvironment $environmentName }
        } elseif ($script:ActivePhase -eq 'GeocodeCalifornia') {
            Write-EPLog "Initial $environmentName statewide Geocodio run already complete; importing and draining the bounded Nominatim delta."
            Invoke-GeocodeCaliforniaEnvironment $environmentName -Refresh
        }
    }
}

function Set-WorkerSecret([string]$EnvironmentName,[string]$Name,[string]$Value) {
    Invoke-Wrangler @('secret','put',$Name,'--env',$EnvironmentName) -InputText $Value | Out-Null
}

function Set-WorkerSecrets([string]$EnvironmentName) {
    $upper=$EnvironmentName.ToUpperInvariant(); $serviceUrl=[string]$script:State.Resources["${EnvironmentName}StateCareUrl"]
    if (-not $serviceUrl) { throw "Missing StateCare URL for $EnvironmentName." }
    $resend=Get-SensitiveValue 'RESEND_API_KEY' 'Resend API key'; $openai=Get-SensitiveValue 'OPENAI_API_KEY' 'OpenAI API key'
    $values=@{
        BETTER_AUTH_SECRET=Get-SensitiveValue "BETTER_AUTH_SECRET_$upper" '' -Generate
        BETTER_AUTH_URL="https://$(Get-Cfg "${upper}_APP_HOST")"; RESEND_API_KEY=$resend; EMAIL_FROM=Get-Cfg 'EMAIL_FROM'
        OPENAI_API_KEY=$openai; STATECARE_REGISTRY_URL=$serviceUrl; STATECARE_REGISTRY_API_KEY=Get-GcpSecret (Get-Cfg "${upper}_REGISTRY_KEY_SECRET")
    }
    if (Get-CfgBool 'ENABLE_GOOGLE_OAUTH') {
        $values.GOOGLE_CLIENT_ID=Get-SensitiveValue 'GOOGLE_CLIENT_ID' 'Google OAuth client ID'
        $values.GOOGLE_CLIENT_SECRET=Get-SensitiveValue 'GOOGLE_CLIENT_SECRET' 'Google OAuth client secret'
    }
    foreach($pair in $values.GetEnumerator()){ Set-WorkerSecret $EnvironmentName $pair.Key ([string]$pair.Value) }
}

function Invoke-WorkerDeploy([string]$EnvironmentName) {
    [void](Initialize-ReviewedWorktree)
    Initialize-CloudflareToken
    $secretCheckpoint="worker.secrets.$EnvironmentName"
    if($RotateSecrets -or -not(Test-EPCheckpointComplete $script:State $secretCheckpoint)){Set-WorkerSecrets $EnvironmentName;if(-not$script:DryRun){Complete-Step $secretCheckpoint}}
    $migration=if($EnvironmentName-eq'production'){'db:migrate:production'}else{'db:migrate:staging'}
    $seed=if($EnvironmentName-eq'production'){'db:seed:production'}else{'db:seed:staging'}
    Invoke-Npm @('run',$migration)|Out-Null; Invoke-Npm @('run',$seed)|Out-Null; Invoke-Npm @('run',"deploy:$EnvironmentName")|Out-Null
    Test-WorkerDeployment $EnvironmentName
}

function Test-WorkerDeployment([string]$EnvironmentName) {
    $appHostName=Get-Cfg "$($EnvironmentName.ToUpperInvariant())_APP_HOST"; $url="https://$appHostName"
    if ($script:DryRun) { Write-EPLog "WHATIF smoke test $url"; return }
    $health=Invoke-WebRequest -Uri "$url/api/health" -UseBasicParsing; if($health.StatusCode-ne200){throw "Health check failed: $($health.StatusCode)"}
    foreach($header in @('content-security-policy','x-content-type-options')){if(-not $health.Headers[$header]){throw "Health response lacks $header."}}
    $homeResponse=Invoke-WebRequest -Uri $url -UseBasicParsing; if($homeResponse.Content-notmatch'Riverside County'){throw 'Landing page does not contain Riverside County messaging.'}; if($homeResponse.Content-match'(?i)\bpilot\b'){throw 'Landing page unexpectedly renders the word pilot.'}
}

function Invoke-PrepareBeforeBindings {
    if(Get-CfgBool 'DEPLOY_STAGING'){
        Invoke-StateCareDeployStep 'staging' 'deploy.statecare.staging'
        Initialize-CloudflareToken
        if(-not(Test-EPCheckpointComplete $script:State 'worker.secrets.staging')){Set-WorkerSecrets 'staging';if(-not$script:DryRun){Complete-Step 'worker.secrets.staging'}}
    }
    if(Get-CfgBool 'DEPLOY_PRODUCTION'){
        if(-not$script:DryRun -and -not(Test-EPCheckpointComplete $script:State 'deploy.statecare.staging')){throw 'Staging StateCare must pass before preparing production.'}
        if(-not(Test-EPCheckpointComplete $script:State 'deploy.statecare.production') -and -not$script:DryRun){Request-EPTypedConfirmation 'PREPARE PRODUCTION' 'Deploy the production StateCare revision and prepare Worker secrets before the bindings PR.'}
        Invoke-StateCareDeployStep 'production' 'deploy.statecare.production'
        Initialize-CloudflareToken
        if(-not(Test-EPCheckpointComplete $script:State 'worker.secrets.production')){Set-WorkerSecrets 'production';if(-not$script:DryRun){Complete-Step 'worker.secrets.production'}}
    }
}

function Invoke-DeployStagingPhase {
    if(-not(Get-CfgBool 'DEPLOY_STAGING')){Write-EPLog 'Staging deployment disabled.';return}
    Invoke-StateCareDeployStep 'staging' 'deploy.statecare.staging'
    Invoke-Step 'deploy.worker.staging' { Invoke-WorkerDeploy 'staging' }
}

function Invoke-DeployProductionPhase {
    if(-not(Get-CfgBool 'DEPLOY_PRODUCTION')){Write-EPLog 'Production deployment disabled.';return}
    $missingJobs = @(Get-MissingStateCareRequiredJobs 'production')
    $stateCareComplete = Test-EPCheckpointComplete $script:State 'deploy.statecare.production'
    $workerComplete = Test-EPCheckpointComplete $script:State 'deploy.worker.production'
    if ($stateCareComplete -and $workerComplete -and $missingJobs.Count -eq 0) {
        Write-EPLog 'Production deployment checkpoints are already complete.'
        return
    }
    if (-not $script:DryRun -and -not (Test-EPCheckpointComplete $script:State 'deploy.worker.staging')) {
        throw 'Successful staging deployment is required before production.'
    }
    if ($missingJobs.Count -gt 0 -and $stateCareComplete -and $workerComplete) {
        Write-EPLog "Production StateCare checkpoint is complete but required Cloud Run jobs are missing: $($missingJobs -join ', '). Redeploying StateCare only."
        Ensure-GeocodioSecretReady 'production'
        Invoke-StateCareDeploy 'production'
        if (-not $script:DryRun) { Complete-Step 'deploy.statecare.production' }
        return
    }
    if(-not $script:DryRun){Request-EPTypedConfirmation 'DEPLOY PRODUCTION' 'Production migrations and deployment are about to run.'}
    Initialize-CloudflareToken
    Invoke-Step 'production.rollback-capture' {
        $project=Get-Cfg 'GCP_PROJECT_ID';$region=Get-Cfg 'GCP_REGION';$service=Get-Cfg 'STATECARE_PRODUCTION_SERVICE'
        $script:State.Resources['PriorCloudRunRevision']=(Invoke-Gcloud @('run','services','describe',$service,'--project',$project,'--region',$region,'--format=value(status.latestReadyRevisionName)') -AllowFailure -NoLogOutput).StdOut.Trim()
        $bookmark=Invoke-Wrangler @('d1','time-travel','info',(Get-Cfg 'CLOUDFLARE_PRODUCTION_D1_NAME'),'--env','production','--remote') -AllowFailure
        $script:State.Resources['D1RecoveryBookmark']=(Protect-EPText $bookmark.StdOut.Trim())
    }
    Invoke-StateCareDeployStep 'production' 'deploy.statecare.production'
    Invoke-Step 'deploy.worker.production' { Invoke-WorkerDeploy 'production'; $envMap=@{DEPLOYMENT_URL="https://$(Get-Cfg 'PRODUCTION_APP_HOST')"}; Invoke-Npm @('run','smoke:production') -Environment $envMap|Out-Null }
}

function Invoke-CreateBindingsPRPhase {
    if(-not(Get-CfgBool 'CREATE_GITHUB_BINDINGS_PR')){return}; Initialize-CloudflareToken
    if(-not $script:State.Resources.StagingD1Id -or -not $script:State.Resources.ProductionD1Id){throw 'D1 IDs are not available; run ConfigureCloudflare first.'}
    if($script:DryRun){Write-EPLog 'WHATIF create temporary origin/main worktree, patch exact bindings/domains, commit, push, and open PR';return}
    if(Test-EPCheckpointComplete $script:State 'bindings.pr.created'){
        $url=[string]$script:State.Resources.BindingsPullRequest
        $status=Invoke-Gh @('pr','view',$url,'--json','state,mergedAt,mergeCommit','--jq','if .mergedAt then "merged " + .mergeCommit.oid else (.state|ascii_downcase) end') -NoLogOutput
        if(-not $status.StdOut.Trim().StartsWith('merged ')){throw "PAUSE: The bindings PR is not merged: $url. Review and merge it, then run -Phase Resume."}
        $mergeSha=$status.StdOut.Trim().Substring(7)
        $script:State.Resources['BindingsMergeSha']=$mergeSha
        $repo=Get-Cfg 'ELDERPATH_REPO_PATH';$remoteRef="origin/$(Get-Cfg 'GITHUB_DEFAULT_BRANCH')"
        Invoke-Tool 'git.exe' @('fetch','origin',(Get-Cfg 'GITHUB_DEFAULT_BRANCH'),'--prune') -WorkingDirectory $repo|Out-Null
        $ancestor=Invoke-Tool 'git.exe' @('merge-base','--is-ancestor',$mergeSha,$remoteRef) -WorkingDirectory $repo -AllowFailure -NoLogOutput
        if($ancestor.ExitCode-ne0){throw "Bindings merge $mergeSha is no longer an ancestor of $remoteRef. Resolve the branch history before deployment."}
        $releaseSha=(Invoke-Tool 'git.exe' @('rev-parse',$remoteRef) -WorkingDirectory $repo -NoLogOutput).StdOut.Trim()
        if($releaseSha-notmatch'^[0-9a-fA-F]{40}$'){throw "Unable to resolve a full release SHA from $remoteRef."}
        $script:State.Resources['ReleaseSha']=$releaseSha
        Save-EPCheckpoint -Root $PSScriptRoot -State $script:State
        Write-EPLog "Release SHA: $releaseSha"
        if(-not(Test-EPCheckpointComplete $script:State 'bindings.pr.merged')){Complete-Step 'bindings.pr.merged'}
        if(Get-CfgBool 'CONFIGURE_GITHUB_CI'){Wait-GitHubReleaseRuns $releaseSha}
        return
    }
    $repo=Get-Cfg 'ELDERPATH_REPO_PATH';$branch="codex/deployment-bindings-$((Get-Date).ToString('yyyyMMddHHmmss'))";$worktree=Join-Path $env:TEMP "elderpath-bindings-$([guid]::NewGuid().ToString('N'))"
    try{
        Invoke-Tool 'git.exe' @('worktree','add','-b',$branch,$worktree,"origin/$(Get-Cfg 'GITHUB_DEFAULT_BRANCH')") -WorkingDirectory $repo|Out-Null
        $path=Join-Path $worktree 'wrangler.jsonc';$content=[IO.File]::ReadAllText($path)
        foreach($replacement in @(@('REPLACE_WITH_STAGING_D1_DATABASE_ID',[string]$script:State.Resources.StagingD1Id),@('REPLACE_WITH_PRODUCTION_D1_DATABASE_ID',[string]$script:State.Resources.ProductionD1Id))){$count=([regex]::Matches($content,[regex]::Escape($replacement[0]))).Count;if($count-ne1){throw "Expected exactly one $($replacement[0]) placeholder; found $count."};$content=$content.Replace($replacement[0],$replacement[1])}
        if(Get-CfgBool 'USE_CUSTOM_WORKER_DOMAINS'){
            $content=$content.Replace('"name": "elderpath-staging",','"name": "elderpath-staging",' + [Environment]::NewLine + '      "routes": [{ "pattern": "' + (Get-Cfg 'STAGING_APP_HOST') + '", "custom_domain": true }],')
            $content=$content.Replace('"name": "elderpath-production",','"name": "elderpath-production",' + [Environment]::NewLine + '      "routes": [{ "pattern": "' + (Get-Cfg 'PRODUCTION_APP_HOST') + '", "custom_domain": true }],')
        }
        [IO.File]::WriteAllText($path,$content,[Text.UTF8Encoding]::new($false));Invoke-Tool 'git.exe' @('diff','--check') -WorkingDirectory $worktree|Out-Null
        $diff=Invoke-Tool 'git.exe' @('diff','--','wrangler.jsonc') -WorkingDirectory $worktree;Write-EPLog "Wrangler binding diff:`n$($diff.StdOut)"
        Invoke-Tool 'git.exe' @('add','--','wrangler.jsonc') -WorkingDirectory $worktree|Out-Null;Invoke-Tool 'git.exe' @('commit','-m','chore: configure production deployment bindings') -WorkingDirectory $worktree|Out-Null;Invoke-Tool 'git.exe' @('push','-u','origin',$branch) -WorkingDirectory $worktree|Out-Null
        $pr=Invoke-Gh @('pr','create','--repo',"$(Get-Cfg 'GITHUB_OWNER')/$(Get-Cfg 'GITHUB_REPOSITORY')",'--head',$branch,'--base',(Get-Cfg 'GITHUB_DEFAULT_BRANCH'),'--title','Configure ElderPath production bindings','--body','Configures reviewed D1 UUIDs and custom Worker domains. No credentials are included.')
        $script:State.Resources['BindingsPullRequest']=$pr.StdOut.Trim();Complete-Step 'bindings.pr.created';Write-EPLog "Bindings PR created: $($script:State.Resources.BindingsPullRequest)"
        throw 'PAUSE: Review and merge the bindings PR, wait for CI, then run -Phase Resume.'
    }finally{Invoke-Tool 'git.exe' @('worktree','remove',$worktree,'--force') -WorkingDirectory $repo -AllowFailure|Out-Null}
}

function Wait-GitHubWorkflowRun([string]$Workflow,[string]$CommitSha,[string]$EventName,[string]$Branch=(Get-Cfg 'GITHUB_DEFAULT_BRANCH')) {
    $owner=Get-Cfg 'GITHUB_OWNER';$repo=Get-Cfg 'GITHUB_REPOSITORY'
    $checkpoint=Get-EPReleaseCheckpointName -Category "github.run.$($Workflow.Replace(' ','-')).$($EventName.Replace('_','-'))" -CommitSha $CommitSha
    if(Test-EPCheckpointComplete $script:State $checkpoint){return}
    if($script:DryRun){Write-EPLog "WHATIF wait for GitHub workflow $Workflow event $EventName at $CommitSha";return}
    $deadline=(Get-Date).AddMinutes(90);$run=$null;$lastStatus=''
    while((Get-Date)-lt$deadline){
        $arguments=@('run','list','--repo',"$owner/$repo",'--workflow',$Workflow,'--event',$EventName)
        if($EventName-ne'workflow_run'){$arguments+=@('--branch',$Branch)}
        $arguments+=@('--limit','30','--json','databaseId,headSha,status,conclusion,url')
        $json=(Invoke-Gh $arguments -NoLogOutput).StdOut
        $matchingRuns=@($json|ConvertFrom-Json|Where-Object headSha -eq $CommitSha)
        $run=@(
            $matchingRuns|Where-Object { $_.status-eq'completed' -and $_.conclusion-eq'success' }|Select-Object -First 1
        )
        if(-not$run){$run=@($matchingRuns|Select-Object -First 1)}
        if($run){
            $statusText="$($run.status)/$($run.conclusion)"
            if($statusText-ne$lastStatus){Write-EPLog "${Workflow}: $statusText $($run.url)";$lastStatus=$statusText}
            if($run.status-eq'completed'){
                if($run.conclusion-ne'success'){throw "$Workflow failed for ${CommitSha}: $($run.url)"}
                Complete-Step $checkpoint;return
            }
        }
        Start-Sleep -Seconds 15
    }
    throw "Timed out waiting for GitHub workflow '$Workflow' event '$EventName' at $CommitSha. Check Actions, then resume."
}

function Wait-GitHubReleaseRuns([string]$CommitSha) {
    Wait-GitHubWorkflowRun -Workflow 'CI' -CommitSha $CommitSha -EventName 'push'
    Wait-GitHubWorkflowRun -Workflow 'Deploy' -CommitSha $CommitSha -EventName 'workflow_run'
    $stagingReleaseCheckpoint=Get-EPReleaseCheckpointName -Category 'deploy.release.staging' -CommitSha $CommitSha
    if(-not(Test-EPCheckpointComplete $script:State $stagingReleaseCheckpoint)){Complete-Step $stagingReleaseCheckpoint}
    foreach($checkpoint in @('deploy.statecare.staging','deploy.worker.staging')){if(-not(Test-EPCheckpointComplete $script:State $checkpoint)){Complete-Step $checkpoint}}
    [void](Initialize-ReviewedWorktree)
    $stagingSmokeCheckpoint=Get-EPReleaseCheckpointName -Category 'smoke.worker.staging' -CommitSha $CommitSha
    Invoke-Step $stagingSmokeCheckpoint { Test-WorkerDeployment 'staging' }
    if(-not(Get-CfgBool 'DEPLOY_PRODUCTION')){return}
    Initialize-CloudflareToken
    $rollbackCheckpoint=Get-EPReleaseCheckpointName -Category 'production.rollback-capture' -CommitSha $CommitSha
    Invoke-Step $rollbackCheckpoint {
        $project=Get-Cfg 'GCP_PROJECT_ID';$region=Get-Cfg 'GCP_REGION';$service=Get-Cfg 'STATECARE_PRODUCTION_SERVICE'
        $script:State.Resources['PriorCloudRunRevision']=(Invoke-Gcloud @('run','services','describe',$service,'--project',$project,'--region',$region,'--format=value(status.latestReadyRevisionName)') -AllowFailure -NoLogOutput).StdOut.Trim()
        $bookmark=Invoke-Wrangler @('d1','time-travel','info',(Get-Cfg 'CLOUDFLARE_PRODUCTION_D1_NAME'),'--env','production','--remote') -AllowFailure
        $script:State.Resources['D1RecoveryBookmark']=(Protect-EPText $bookmark.StdOut.Trim())
        $worker=Invoke-Wrangler @('deployments','list','--env','production','--json') -AllowFailure
        $script:State.Resources['PriorWorkerDeployments']=(Protect-EPText $worker.StdOut.Trim())
    }
    $dispatchCheckpoint=Get-EPReleaseCheckpointName -Category 'github.production.dispatched' -CommitSha $CommitSha
    Invoke-Step $dispatchCheckpoint {
        $repoPath=Get-Cfg 'ELDERPATH_REPO_PATH';$defaultBranch=Get-Cfg 'GITHUB_DEFAULT_BRANCH';$remoteRef="origin/$defaultBranch"
        Invoke-Tool 'git.exe' @('fetch','origin',$defaultBranch,'--prune') -WorkingDirectory $repoPath|Out-Null
        $currentMain=(Invoke-Tool 'git.exe' @('rev-parse',$remoteRef) -WorkingDirectory $repoPath -NoLogOutput).StdOut.Trim()
        if($currentMain-ne$CommitSha){throw "origin/$defaultBranch advanced from release $CommitSha to $currentMain. Resume so staging is verified for the new release before production."}
        if(-not $script:DryRun){Request-EPTypedConfirmation 'DEPLOY PRODUCTION' 'Dispatch the GitHub production workflow for the reviewed main commit.'}
        Invoke-Gh @('workflow','run','Deploy','--repo',"$(Get-Cfg 'GITHUB_OWNER')/$(Get-Cfg 'GITHUB_REPOSITORY')",'--ref',$defaultBranch,'-f','confirmation=DEPLOY PRODUCTION')|Out-Null
    }
    Wait-GitHubWorkflowRun -Workflow 'Deploy' -CommitSha $CommitSha -EventName 'workflow_dispatch'
    $productionReleaseCheckpoint=Get-EPReleaseCheckpointName -Category 'deploy.release.production' -CommitSha $CommitSha
    if(-not(Test-EPCheckpointComplete $script:State $productionReleaseCheckpoint)){Complete-Step $productionReleaseCheckpoint}
    foreach($checkpoint in @('deploy.statecare.production','deploy.worker.production')){if(-not(Test-EPCheckpointComplete $script:State $checkpoint)){Complete-Step $checkpoint}}
    $productionSmokeCheckpoint=Get-EPReleaseCheckpointName -Category 'smoke.worker.production' -CommitSha $CommitSha
    Invoke-Step $productionSmokeCheckpoint { Test-WorkerDeployment 'production';$envMap=@{DEPLOYMENT_URL="https://$(Get-Cfg 'PRODUCTION_APP_HOST')"};Invoke-Npm @('run','smoke:production') -Environment $envMap|Out-Null }
}

function Assert-ReleaseTopologyBranchState {
    $repo = Get-Cfg 'ELDERPATH_REPO_PATH'
    $main = "origin/$(Get-Cfg 'GITHUB_DEFAULT_BRANCH')"
    $dev = "origin/$(Get-Cfg 'GITHUB_STAGING_BRANCH')"
    if (-not $script:DryRun) {
        Invoke-Tool 'git.exe' @('fetch','origin',(Get-Cfg 'GITHUB_DEFAULT_BRANCH'),(Get-Cfg 'GITHUB_STAGING_BRANCH'),'--prune') -WorkingDirectory $repo | Out-Null
    }
    foreach ($ref in @($main,$dev)) {
        $exists = Invoke-ReadOnlyTool 'git.exe' @('rev-parse','--verify',$ref) -WorkingDirectory $repo -AllowFailure -NoLogOutput
        if ($exists.ExitCode -ne 0) { throw "Required release branch $ref does not exist." }
    }
    $ancestor = Invoke-ReadOnlyTool 'git.exe' @('merge-base','--is-ancestor',$dev,$main) -WorkingDirectory $repo -AllowFailure -NoLogOutput
    if ($ancestor.ExitCode -ne 0) {
        throw "$dev is not an ancestor of $main. Resolve branch divergence through a reviewed pull request before configuring release topology."
    }
    $workflow = (Invoke-ReadOnlyTool 'git.exe' @('show',"${main}:.github/workflows/deploy.yml") -WorkingDirectory $repo -NoLogOutput).StdOut
    foreach ($marker in @('branches: [dev, main]','STATECARE_REGISTRY_URL_STAGING','STATECARE_REGISTRY_URL_PRODUCTION','exact Git tree','head_branch == ''dev''')) {
        if (-not $workflow.Contains($marker)) { throw "The reviewed dev/main deployment workflow is missing '$marker' on $main." }
    }
    $wrangler = (Invoke-ReadOnlyTool 'git.exe' @('show',"${main}:wrangler.jsonc") -WorkingDirectory $repo -NoLogOutput).StdOut
    foreach ($marker in @('"name": "elderpath-staging"','"workers_dev": true','"pattern": "elderpath.ai"','"pattern": "www.elderpath.ai"')) {
        if (-not $wrangler.Contains($marker)) { throw "The reviewed Worker topology is missing '$marker' on $main." }
    }
    return [pscustomobject]@{ Repository=$repo; MainRef=$main; DevRef=$dev }
}

function Invoke-ConfigureReleaseTopologyPhase {
    $branches = Assert-ReleaseTopologyBranchState
    $owner = Get-Cfg 'GITHUB_OWNER'; $repository = Get-Cfg 'GITHUB_REPOSITORY'; $slug = "$owner/$repository"
    $stagingRegistryUrl = Resolve-StateCareServiceUrl 'staging'
    $productionRegistryUrl = Resolve-StateCareServiceUrl 'production'
    $stagingRegistryKey = Get-GcpSecret (Get-Cfg 'STAGING_REGISTRY_KEY_SECRET')
    $productionRegistryKey = Get-GcpSecret (Get-Cfg 'PRODUCTION_REGISTRY_KEY_SECRET')

    Invoke-Step 'release-topology.repository-values.v1' {
        foreach ($pair in ([ordered]@{
            STAGING_DEPLOYMENT_URL='https://elderpath-staging.elderpath.workers.dev'
            PRODUCTION_DEPLOYMENT_URL='https://elderpath.ai'
            STATECARE_REGISTRY_URL_STAGING=$stagingRegistryUrl
            STATECARE_REGISTRY_URL_PRODUCTION=$productionRegistryUrl
        }).GetEnumerator()) {
            Invoke-Gh @('variable','set',$pair.Key,'--repo',$slug,'--body',[string]$pair.Value) | Out-Null
        }
        Invoke-Gh @('secret','set','STATECARE_REGISTRY_API_KEY_STAGING','--repo',$slug) -InputText $stagingRegistryKey -NoLogOutput | Out-Null
        Invoke-Gh @('secret','set','STATECARE_REGISTRY_API_KEY_PRODUCTION','--repo',$slug) -InputText $productionRegistryKey -NoLogOutput | Out-Null
    }

    Invoke-Step 'release-topology.worker-secrets.v1' {
        Initialize-CloudflareToken
        Set-WorkerSecret 'staging' 'BETTER_AUTH_URL' 'https://elderpath-staging.elderpath.workers.dev'
        Set-WorkerSecret 'staging' 'STATECARE_REGISTRY_URL' $stagingRegistryUrl
        Set-WorkerSecret 'staging' 'STATECARE_REGISTRY_API_KEY' $stagingRegistryKey
        Set-WorkerSecret 'production' 'BETTER_AUTH_URL' 'https://elderpath.ai'
        Set-WorkerSecret 'production' 'STATECARE_REGISTRY_URL' $productionRegistryUrl
        Set-WorkerSecret 'production' 'STATECARE_REGISTRY_API_KEY' $productionRegistryKey
    }

    $mainSha = (Invoke-ReadOnlyTool 'git.exe' @('rev-parse',$branches.MainRef) -WorkingDirectory $branches.Repository -NoLogOutput).StdOut.Trim()
    $devSha = (Invoke-ReadOnlyTool 'git.exe' @('rev-parse',$branches.DevRef) -WorkingDirectory $branches.Repository -NoLogOutput).StdOut.Trim()
    if ($mainSha -ne $devSha) {
        if ($script:DryRun) {
            Write-EPLog "WHATIF require 'FAST FORWARD DEV TO MAIN' and push $($branches.MainRef) to refs/heads/$(Get-Cfg 'GITHUB_STAGING_BRANCH')"
        } else {
            Request-EPTypedConfirmation 'FAST FORWARD DEV TO MAIN' 'Synchronize the ancestor dev branch to the reviewed main release topology.'
            Invoke-Tool 'git.exe' @('push','origin',"$($branches.MainRef):refs/heads/$(Get-Cfg 'GITHUB_STAGING_BRANCH')") -WorkingDirectory $branches.Repository | Out-Null
        }
    } else {
        Write-EPLog 'dev already matches main; no branch synchronization is needed.'
    }
    if ($script:DryRun) {
        Write-EPLog "WHATIF monitor dev CI and staging deployment for tree $mainSha, then reuse successful main CI and production deployment for the same commit"
        return
    }

    Wait-GitHubWorkflowRun -Workflow 'CI' -CommitSha $mainSha -EventName 'push' -Branch (Get-Cfg 'GITHUB_STAGING_BRANCH')
    Wait-GitHubWorkflowRun -Workflow 'Deploy' -CommitSha $mainSha -EventName 'workflow_run' -Branch (Get-Cfg 'GITHUB_STAGING_BRANCH')
    Test-WorkerDeployment 'staging'
    Wait-GitHubWorkflowRun -Workflow 'CI' -CommitSha $mainSha -EventName 'push' -Branch (Get-Cfg 'GITHUB_DEFAULT_BRANCH')
    Wait-GitHubWorkflowRun -Workflow 'Deploy' -CommitSha $mainSha -EventName 'workflow_run' -Branch (Get-Cfg 'GITHUB_DEFAULT_BRANCH')
    Test-WorkerDeployment 'production'
    $script:State.Resources['ReleaseSha'] = $mainSha
    $script:State.PausedAt = $null
    Complete-Step "release-topology.release.$mainSha"
    Write-EPLog 'Release topology is active: dev deploys staging and identical staged main trees deploy production automatically.'
}

function Assert-ManualReleaseWorkflowsDisabled {
    if (Get-CfgBool 'CONFIGURE_GITHUB_CI') {
        throw 'ManualRelease requires CONFIGURE_GITHUB_CI=false while the GitHub Actions quota is exhausted.'
    }
    $slug = "$(Get-Cfg 'GITHUB_OWNER')/$(Get-Cfg 'GITHUB_REPOSITORY')"
    foreach ($workflow in @(
        @{ Name='CI'; Path='ci.yml' },
        @{ Name='Deploy'; Path='deploy.yml' }
    )) {
        if ($script:DryRun) {
            Write-EPLog "WHATIF verify GitHub workflow '$($workflow.Name)' ($($workflow.Path)) is disabled_manually"
            continue
        }
        $endpoint = "repos/$slug/actions/workflows/$($workflow.Path)"
        $result = Invoke-Gh @('api',$endpoint,'--jq','.state') -AllowFailure -NoLogOutput
        [void](Assert-EPGitHubWorkflowDisabledState `
            -WorkflowName $workflow.Name `
            -WorkflowPath $workflow.Path `
            -State $result.StdOut `
            -ExitCode $result.ExitCode)
    }
}

function Get-ManualReleaseSelection {
    $repository = Get-Cfg 'ELDERPATH_REPO_PATH'
    $main = "origin/$(Get-Cfg 'GITHUB_DEFAULT_BRANCH')"
    $dev = "origin/$(Get-Cfg 'GITHUB_STAGING_BRANCH')"
    if (-not $script:DryRun) {
        Invoke-Tool 'git.exe' @('fetch','origin',(Get-Cfg 'GITHUB_DEFAULT_BRANCH'),(Get-Cfg 'GITHUB_STAGING_BRANCH'),'--prune') -WorkingDirectory $repository | Out-Null
    }
    $mainSha = (Invoke-ReadOnlyTool 'git.exe' @('rev-parse',$main) -WorkingDirectory $repository -NoLogOutput).StdOut.Trim()
    $mainTree = (Invoke-ReadOnlyTool 'git.exe' @('rev-parse',"$main^{tree}") -WorkingDirectory $repository -NoLogOutput).StdOut.Trim()
    $devTree = (Invoke-ReadOnlyTool 'git.exe' @('rev-parse',"$dev^{tree}") -WorkingDirectory $repository -NoLogOutput).StdOut.Trim()
    if ($mainSha -notmatch '^[0-9a-fA-F]{40}$') { throw "Unable to resolve a full release SHA from $main." }
    if ($mainTree -ne $devTree) {
        throw 'origin/dev and origin/main do not have identical Git trees. Promote the reviewed dev tree to main before ManualRelease.'
    }
    $script:State.Resources['ReleaseSha'] = $mainSha
    Write-EPLog "Manual release selected origin/main commit $mainSha with an identical dev tree."
    return $mainSha
}

function Test-StateCareCoverage([ValidateSet('staging','production')][string]$EnvironmentName) {
    if ($script:DryRun) {
        Write-EPLog "WHATIF verify $EnvironmentName StateCare current California count and coordinate coverage >= $(Get-Cfg 'STATEWIDE_GEOCODING_REQUIRED_COVERAGE_PERCENT')%"
        return [pscustomobject]@{ Current=12522; Located=12469; Coverage=99.577 }
    }
    $tier = $EnvironmentName.ToUpperInvariant()
    $url = Get-GcpSecret (Get-Cfg "${tier}_DATABASE_URL_SYNC_SECRET")
    $uri = [uri]$url
    $credentials = [uri]::UnescapeDataString($uri.UserInfo).Split(':',2)
    if ($credentials.Count -ne 2) { throw "$EnvironmentName Supabase sync URL credentials are malformed." }
    Add-EPRedaction $credentials[1]
    $query = "SELECT count(*) FILTER (WHERE latitude IS NOT NULL AND longitude IS NOT NULL), count(*) FROM facilities WHERE is_current = true AND state_code = 'CA';"
    $result = Invoke-Tool 'docker.exe' @(
        'run','--rm','-e','PGPASSWORD','-e','PGSSLMODE','postgres:17-alpine','psql',
        '-h',$uri.Host,'-p',([string]$uri.Port),'-U',$credentials[0],'-d',$uri.AbsolutePath.TrimStart('/'),
        '-At','-F','|','-c',$query
    ) -Environment @{ PGPASSWORD=$credentials[1]; PGSSLMODE='require' } -NoLogOutput
    $parts = $result.StdOut.Trim().Split('|')
    if ($parts.Count -ne 2) { throw "$EnvironmentName StateCare coverage query returned an unexpected result." }
    $located = [long]$parts[0]
    $current = [long]$parts[1]
    if ($current -le 0) { throw "$EnvironmentName StateCare has no current California records." }
    $coverage = [math]::Round(($located * 100.0) / $current,3)
    $required = [double](Get-Cfg 'STATEWIDE_GEOCODING_REQUIRED_COVERAGE_PERCENT')
    Write-EPLog "$EnvironmentName StateCare coverage: $located of $current current California facilities located ($coverage%)."
    if ($coverage -lt $required) {
        throw "$EnvironmentName StateCare coverage is $coverage%, below the $required% gate. Stop and run the existing $EnvironmentName Geocodio initial operation; ManualRelease will not import or geocode automatically."
    }
    return [pscustomobject]@{ Current=$current; Located=$located; Coverage=$coverage }
}

function Test-WorkerRegistryDiagnostics([ValidateSet('staging','production')][string]$EnvironmentName) {
    $url = "https://$(Get-Cfg "$($EnvironmentName.ToUpperInvariant())_APP_HOST")"
    if ($script:DryRun) { Write-EPLog "WHATIF verify $url uses the $EnvironmentName Registry without a temporary-unavailability response"; return }
    $response = Invoke-WebRequest -Uri "$url/api/facilities/search?lat=33.6971&lng=-117.1853&radiusMiles=15&locationLabel=Menifee%2C%20California&limit=5" -UseBasicParsing
    $payload = $response.Content | ConvertFrom-Json
    if ([string]$payload.sourceDiagnostics.registry -ne 'ok') {
        throw "$EnvironmentName Worker Registry diagnostics are '$($payload.sourceDiagnostics.registry)' instead of 'ok'."
    }
    if ($response.Content -match 'State licensing registry is temporarily unavailable') {
        throw "$EnvironmentName Worker returned the StateCare temporary-unavailability message."
    }
}

function Invoke-TaggedWorkerRelease(
    [ValidateSet('staging','production')][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$CommitSha
) {
    $tier = $EnvironmentName.ToUpperInvariant()
    $registryUrl = Resolve-StateCareServiceUrl $EnvironmentName
    $registryKey = Get-GcpSecret (Get-Cfg "${tier}_REGISTRY_KEY_SECRET")
    Set-WorkerSecret $EnvironmentName 'STATECARE_REGISTRY_URL' $registryUrl
    Set-WorkerSecret $EnvironmentName 'STATECARE_REGISTRY_API_KEY' $registryKey
    $migration = if ($EnvironmentName -eq 'production') { 'db:migrate:production' } else { 'db:migrate:staging' }
    $seed = if ($EnvironmentName -eq 'production') { 'db:seed:production' } else { 'db:seed:staging' }
    Invoke-Npm @('run',$migration) | Out-Null
    Invoke-Npm @('run',$seed) | Out-Null
    $tag = "release-$($CommitSha.Substring(0,12))"
    $message = "ElderPath release $CommitSha"
    Invoke-Npm @('run',"deploy:$EnvironmentName",'--','--tag',$tag,'--message',$message) | Out-Null
    Test-WorkerDeployment $EnvironmentName
    Invoke-Npm @('run','smoke:browser') -Environment @{ DEPLOYMENT_URL="https://$(Get-Cfg "${tier}_APP_HOST")" } | Out-Null
    Test-WorkerRegistryDiagnostics $EnvironmentName

    $workerName = if ($EnvironmentName -eq 'production') { 'elderpath-production' } else { 'elderpath-staging' }
    $versions = Invoke-Wrangler @('versions','list','--name',$workerName,'--json')
    $deployment = Invoke-Wrangler @('deployments','status','--name',$workerName,'--json')
    if (-not $script:DryRun -and ($versions.StdOut -notmatch [regex]::Escape($tag) -or $deployment.StdOut -notmatch [regex]::Escape($CommitSha))) {
        throw "$EnvironmentName Worker active version does not report release tag '$tag' and SHA '$CommitSha'."
    }
    Write-EPLog "$EnvironmentName Worker active version is tagged $tag for $CommitSha."
}

function Invoke-ManualReleasePhase {
    Assert-ManualReleaseWorkflowsDisabled
    $releaseSha = Get-ManualReleaseSelection
    [void](Initialize-ReviewedWorktree)
    if ($script:DryRun) {
        Write-EPLog "WHATIF create a temporary detached worktree for exact origin/main release $releaseSha"
    } else {
        $worktreeSha = (Invoke-ReadOnlyTool 'git.exe' @('rev-parse','HEAD') -WorkingDirectory (Get-ExecutionRepository) -NoLogOutput).StdOut.Trim()
        if ($worktreeSha -ne $releaseSha) { throw "Reviewed worktree is $worktreeSha instead of selected release $releaseSha." }
    }
    Initialize-CloudflareToken

    $registryCheckpoint = Get-EPReleaseCheckpointName -Category 'manual.registry-preflight' -CommitSha $releaseSha
    Invoke-Step $registryCheckpoint {
        $stagingUrl = Resolve-StateCareServiceUrl 'staging'
        $productionUrl = Resolve-StateCareServiceUrl 'production'
        if ($stagingUrl -eq $productionUrl) { throw 'Staging and production StateCare service URLs must be different.' }
        Invoke-StateCareDataVerify 'staging'
        [void](Test-StateCareCoverage 'staging')
        Invoke-StateCareDataVerify 'production'
        [void](Test-StateCareCoverage 'production')
        Write-EPLog 'Both Registry stacks pass readiness, freshness, current-record, nearby, and 99% coordinate-coverage gates; import and geocoding are skipped.'
    }

    $stagingCheckpoint = Get-EPReleaseCheckpointName -Category 'manual.worker.staging' -CommitSha $releaseSha
    Invoke-Step $stagingCheckpoint { Invoke-TaggedWorkerRelease 'staging' $releaseSha }
    if (-not (Get-CfgBool 'DEPLOY_PRODUCTION')) { return }
    if (-not $script:DryRun) { Request-EPTypedConfirmation 'DEPLOY PRODUCTION' "Deploy the exact verified origin/main release $releaseSha." }

    $bookmarkCheckpoint = Get-EPReleaseCheckpointName -Category 'manual.production-bookmark' -CommitSha $releaseSha
    Invoke-Step $bookmarkCheckpoint {
        $bookmark = Invoke-Wrangler @('d1','time-travel','info',(Get-Cfg 'CLOUDFLARE_PRODUCTION_D1_NAME'),'--env','production','--remote')
        $script:State.Resources["D1RecoveryBookmark.$releaseSha"] = Protect-EPText $bookmark.StdOut.Trim()
    }
    $productionCheckpoint = Get-EPReleaseCheckpointName -Category 'manual.worker.production' -CommitSha $releaseSha
    Invoke-Step $productionCheckpoint {
        Invoke-TaggedWorkerRelease 'production' $releaseSha
        Invoke-Npm @('run','smoke:production') -Environment @{ DEPLOYMENT_URL='https://elderpath.ai' } | Out-Null
    }
    Write-EPLog "Manual release $releaseSha is active in staging and production. StateCare was verified but not redeployed, imported, or geocoded."
}

function Invoke-CleanupAccidentalR2Phase {
    $bucketName='elderpath-media'
    if($script:DryRun){
        Write-EPLog "WHATIF verify R2 bucket '$bucketName' exists, contains no objects, and is not bound to any Worker"
        Write-EPLog "WHATIF require confirmation 'DELETE UNUSED R2 $bucketName', delete only that bucket, and verify it is absent"
        [void](Invoke-EPR2BucketCleanup -BucketName $bucketName -GetObjectList {} -GetWorkerSettings {} -ConfirmDeletion {} -DeleteBucket {} -DryRun)
        return
    }
    Initialize-CloudflareToken
    Invoke-Step 'cloudflare.cleanup.accidental-r2' {
        $accountId=Get-Cfg 'CLOUDFLARE_ACCOUNT_ID'
        $base="https://api.cloudflare.com/client/v4/accounts/$accountId"
        $headers=@{Authorization="Bearer $($script:CloudflareEnvironment.CLOUDFLARE_API_TOKEN)"}
        $bucketList=Invoke-RestMethod -Uri "$base/r2/buckets?per_page=1000" -Headers $headers -Method Get
        if(-not$bucketList.success){throw 'Cloudflare R2 bucket listing failed.'}
        $bucketsProperty=$bucketList.result.PSObject.Properties['buckets']
        $buckets=if($null-eq$bucketsProperty-or$null-eq$bucketsProperty.Value){@()}else{@($bucketsProperty.Value)}
        if(-not($buckets|Where-Object name -eq $bucketName|Select-Object -First 1)){
            Write-EPLog "R2 bucket '$bucketName' is already absent."
            return
        }

        $getObjects={param($name)Invoke-RestMethod -Uri "$base/r2/buckets/$name/objects?per_page=1" -Headers $headers -Method Get}
        $getWorkerSettings={
            $scripts=Invoke-RestMethod -Uri "$base/workers/scripts" -Headers $headers -Method Get
            if(-not$scripts.success){throw 'Cloudflare Worker script listing failed; refusing R2 cleanup.'}
            foreach($worker in @($scripts.result)){
                $scriptName=[string]$worker.id
                if([string]::IsNullOrWhiteSpace($scriptName)){throw 'Cloudflare returned a Worker without an ID; refusing R2 cleanup.'}
                $escaped=[uri]::EscapeDataString($scriptName)
                [pscustomobject]@{ScriptName=$scriptName;Response=(Invoke-RestMethod -Uri "$base/workers/scripts/$escaped/settings" -Headers $headers -Method Get)}
            }
        }
        $confirm={param($name)Request-EPTypedConfirmation "DELETE UNUSED R2 $name" "The verified empty, unbound accidental R2 bucket will be permanently deleted."}
        $delete={
            param($name)
            $response=Invoke-RestMethod -Uri "$base/r2/buckets/$name" -Headers $headers -Method Delete
            if(-not$response.success){throw "Cloudflare did not confirm deletion of R2 bucket '$name'."}
            $after=Invoke-RestMethod -Uri "$base/r2/buckets?per_page=1000" -Headers $headers -Method Get
            $afterBucketsProperty=$after.result.PSObject.Properties['buckets']
            $afterBuckets=if($null-eq$afterBucketsProperty-or$null-eq$afterBucketsProperty.Value){@()}else{@($afterBucketsProperty.Value)}
            if($afterBuckets|Where-Object name -eq $name|Select-Object -First 1){throw "R2 bucket '$name' still appears after deletion."}
        }
        $result=Invoke-EPR2BucketCleanup -BucketName $bucketName -GetObjectList $getObjects -GetWorkerSettings $getWorkerSettings -ConfirmDeletion $confirm -DeleteBucket $delete
        if($result.Deleted){Write-EPLog "Deleted verified empty and unbound R2 bucket '$bucketName'."}
    }
}

function Invoke-MonitoringPhase {
    $project=Get-Cfg 'GCP_PROJECT_ID';$region=Get-Cfg 'GCP_REGION'
    Invoke-Step 'monitoring.scheduler' {
        foreach($environmentName in @('staging','production')){
            $service=Get-Cfg "STATECARE_$($environmentName.ToUpperInvariant())_SERVICE";$url=[string]$script:State.Resources["${environmentName}StateCareUrl"]
            if(-not$url){$url=(Invoke-Gcloud @('run','services','describe',$service,'--project',$project,'--region',$region,'--format=value(status.url)') -NoLogOutput).StdOut.Trim()}
            $job="statecare-$environmentName-readiness";if(-not(Test-GcloudResource @('scheduler','jobs','describe',$job,'--location',$region,'--project',$project))){Invoke-Gcloud @('scheduler','jobs','create','http',$job,"--uri=$url/health/ready","--schedule=$(Get-Cfg 'READINESS_SCHEDULE')",'--time-zone=Etc/UTC','--http-method=GET','--location',$region,'--project',$project)|Out-Null}else{Invoke-Gcloud @('scheduler','jobs','update','http',$job,"--uri=$url/health/ready","--schedule=$(Get-Cfg 'READINESS_SCHEDULE')",'--time-zone=Etc/UTC','--http-method=GET','--location',$region,'--project',$project)|Out-Null}
        }
    }
    if(Get-CfgBool 'CONFIGURE_WEEKLY_BACKUP_TASK'){
        $taskName='ElderPath-StateCare-Weekly-Backup';$scriptPath=Join-Path $PSScriptRoot 'Backup-StateCare.ps1';$action="pwsh.exe -NoProfile -File `"$scriptPath`" -Environment production -NonInteractive"
        $dayMap=@{Monday='MON';Tuesday='TUE';Wednesday='WED';Thursday='THU';Friday='FRI';Saturday='SAT';Sunday='SUN'};$day=$dayMap[(Get-Cfg 'BACKUP_DAY_OF_WEEK')]
        if(-not$day){throw 'BACKUP_DAY_OF_WEEK must be Monday through Sunday.'}
        Invoke-Tool 'schtasks.exe' @('/Create','/TN',$taskName,'/TR',$action,'/SC','WEEKLY','/D',$day,'/ST',(Get-Cfg 'BACKUP_LOCAL_TIME'),'/F')|Out-Null
    }
}

function Invoke-PromoteAdminPhase {
    [void](Initialize-ReviewedWorktree)
    Initialize-CloudflareToken;$email=Get-Cfg 'INITIAL_SUPER_ADMIN_EMAIL';$dbId=[string]$script:State.Resources.ProductionD1Id;if(-not$dbId){throw 'Production D1 ID missing from checkpoint.'}
    if(-not$script:DryRun){Request-EPTypedConfirmation $email "Confirm that this account has registered, verified its email, and signed in normally."}
    $environment=@{CLOUDFLARE_ACCOUNT_ID=Get-Cfg 'CLOUDFLARE_ACCOUNT_ID';CLOUDFLARE_API_TOKEN=$script:CloudflareEnvironment.CLOUDFLARE_API_TOKEN;D1_DATABASE_ID=$dbId}
    Invoke-Npm @('run','db:promote:remote','--',$email) -Environment $environment|Out-Null
    $script:Sensitive.Remove('CLOUDFLARE_BOOTSTRAP_TOKEN');$script:CloudflareEnvironment=@{}
    Write-EPLog 'Administrator promoted. Sign out/in, verify /staff, then create and verify a second super administrator.' -Level WARN
}

function Invoke-AllPhase {
    Invoke-ValidatePhase
    Invoke-Step 'tests.full-gate' { Invoke-TestGate }
    Invoke-ProvisionPhase
    if(Get-CfgBool 'CONFIGURE_GITHUB_CI'){Invoke-ConfigureCIPhase}
    Invoke-ConfigureCloudflarePhase
    Invoke-PrepareBeforeBindings
    Invoke-CreateBindingsPRPhase
    Invoke-DeployStagingPhase
    Invoke-DeployProductionPhase
    Invoke-GeocodeCaliforniaPhase
    Invoke-MonitoringPhase
    Write-EPLog 'Deployment automation completed. Register and verify the initial admin account, then run -Phase PromoteAdmin.'
}

function Invoke-RequestedPhase([string]$Requested) {
    switch($Requested){
        'Validate'{Invoke-ValidatePhase}
        'Provision'{Invoke-ValidatePhase;Invoke-ProvisionPhase}
        'RepairDatabaseSecrets'{Invoke-ValidatePhase;Invoke-RepairDatabaseSecretsPhase}
        'ConfigureCI'{Invoke-ValidatePhase;Invoke-ConfigureCIPhase}
        'ConfigureCloudflare'{Invoke-ValidatePhase;Invoke-ConfigureCloudflarePhase}
        'ConfigureReleaseTopology'{Invoke-ValidatePhase;Invoke-ConfigureReleaseTopologyPhase}
        'ManualRelease'{Invoke-ValidatePhase;Invoke-ManualReleasePhase}
        'DeployStaging'{Invoke-ValidatePhase;Invoke-DeployStagingPhase}
        'DeployProduction'{Invoke-ValidatePhase;Invoke-DeployProductionPhase}
        'CreateBindingsPR'{Invoke-ValidatePhase;Invoke-CreateBindingsPRPhase}
        'CleanupAccidentalR2'{Invoke-ValidatePhase;Invoke-CleanupAccidentalR2Phase}
        'Monitoring'{Invoke-ValidatePhase;Invoke-MonitoringPhase}
        'GeocodeCalifornia'{Invoke-ValidatePhase;Invoke-GeocodeCaliforniaPhase}
        'PromoteAdmin'{Invoke-ValidatePhase;Invoke-PromoteAdminPhase}
        'All'{Invoke-AllPhase}
        'Resume' {
            if ([string]$script:State.PausedAt -eq 'ConfigureReleaseTopology') {
                $script:ActivePhase = 'ConfigureReleaseTopology'
                Invoke-ValidatePhase
                Invoke-ConfigureReleaseTopologyPhase
            } elseif ([string]$script:State.PausedAt -eq 'GeocodeCalifornia') {
                $script:ActivePhase = 'GeocodeCalifornia'
                Invoke-ValidatePhase
                Invoke-GeocodeCaliforniaPhase
            } else {
                Invoke-AllPhase
            }
        }
    }
}

$script:ActivePhase = $Phase
try { Invoke-RequestedPhase $Phase }
catch {
    $script:State.PausedAt=$script:ActivePhase
    if(-not$script:DryRun){Save-EPCheckpoint -Root $PSScriptRoot -State $script:State}
    Write-EPLog (Protect-EPText $_.Exception.Message) -Level ERROR
    throw
}
finally {
    Remove-ReviewedWorktree
    foreach($key in @($script:Sensitive.Keys)){$script:Sensitive[$key]=$null}
    $script:Sensitive.Clear();$script:CloudflareEnvironment.Clear()
}

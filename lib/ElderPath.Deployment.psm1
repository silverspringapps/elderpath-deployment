Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Redactions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:LogPath = $null

function ConvertFrom-EPEnvFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    $result = [ordered]@{}
    $lineNumber = 0
    foreach ($rawLine in [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path).Path)) {
        $lineNumber++
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('export ', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Line $lineNumber must not use shell syntax such as 'export'."
        }
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) { throw "Line $lineNumber must use KEY=VALUE syntax." }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($key -notmatch '^[A-Z][A-Z0-9_]*$') { throw "Invalid configuration key '$key' on line $lineNumber." }
        if ($result.Contains($key)) { throw "Duplicate configuration key '$key' on line $lineNumber." }
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $result[$key] = $value
    }
    return $result
}

function ConvertTo-EPBoolean {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value, [Parameter(Mandatory)][string]$Name)
    switch ($Value.Trim().ToLowerInvariant()) {
        'true' { return $true }
        'false' { return $false }
        default { throw "$Name must be true or false." }
    }
}

function Assert-EPConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Configuration)

    $required = @(
        'ELDERPATH_REPO_PATH','DEPLOYMENT_ROOT','BACKUP_ROOT','PRIMARY_DOMAIN','STAGING_APP_HOST',
        'PRODUCTION_APP_HOST','EMAIL_SENDING_DOMAIN','EMAIL_FROM','OPERATIONS_EMAIL',
        'INITIAL_SUPER_ADMIN_EMAIL','SUPABASE_STAGING_PROJECT_REF','SUPABASE_PRODUCTION_PROJECT_REF',
        'SUPABASE_STAGING_POOLER_HOST','SUPABASE_PRODUCTION_POOLER_HOST',
        'SUPABASE_CLI_VERSION','GCP_PROJECT_ID','GCP_BILLING_ACCOUNT_ID','GCP_REGION',
        'GCP_ARTIFACT_REPOSITORY','GCP_RUNTIME_SERVICE_ACCOUNT','GCP_DEPLOY_SERVICE_ACCOUNT',
        'GCP_WORKLOAD_IDENTITY_POOL','GCP_WORKLOAD_IDENTITY_PROVIDER','STATECARE_STAGING_SERVICE',
        'STATECARE_PRODUCTION_SERVICE','STAGING_DATABASE_URL_SECRET','STAGING_DATABASE_URL_SYNC_SECRET',
        'STAGING_REGISTRY_KEY_SECRET','STAGING_ADMIN_KEY_SECRET','STAGING_GEOCODIO_API_KEY_SECRET',
        'PRODUCTION_DATABASE_URL_SECRET','PRODUCTION_DATABASE_URL_SYNC_SECRET',
        'PRODUCTION_REGISTRY_KEY_SECRET','PRODUCTION_ADMIN_KEY_SECRET','PRODUCTION_GEOCODIO_API_KEY_SECRET',
        'CLOUDFLARE_ACCOUNT_ID','CLOUDFLARE_ZONE_ID','CLOUDFLARE_STAGING_D1_NAME',
        'CLOUDFLARE_PRODUCTION_D1_NAME','CLOUDFLARE_STAGING_R2_BUCKET','CLOUDFLARE_PRODUCTION_R2_BUCKET',
        'GITHUB_OWNER','GITHUB_REPOSITORY','GITHUB_DEFAULT_BRANCH','GITHUB_STAGING_BRANCH','GITHUB_DEPLOYMENT_MODE',
        'CALIFORNIA_RCFE_SOURCE_URL','NOMINATIM_BASE_URL','NOMINATIM_USER_AGENT',
        'GEOCODIO_INITIAL_BATCH_SIZE','GEOCODIO_INITIAL_MAX_ITEMS','GEOCODIO_MIN_ACCURACY',
        'GEOCODIO_ACCEPTED_ACCURACY_TYPES','STATEWIDE_GEOCODING_REQUIRED_COVERAGE_PERCENT',
        'CALIFORNIA_NOMINATIM_DELTA_LIMIT','CALIFORNIA_NOMINATIM_REQUESTS_PER_MINUTE','OPENAI_MODEL'
    )
    $missing = @()
    foreach ($name in $required) {
        if (-not $Configuration.Contains($name) -or [string]::IsNullOrWhiteSpace([string]$Configuration[$name]) -or $Configuration[$name] -eq 'REQUIRED') {
            $missing += $name
        }
    }
    if ($missing.Count) { throw "Required configuration is missing: $($missing -join ', ')" }

    foreach ($name in @('INSTALL_MISSING_TOOLS','RUN_FULL_TEST_GATE','DEPLOY_STAGING','DEPLOY_PRODUCTION',
        'CREATE_GITHUB_BINDINGS_PR','CONFIGURE_GITHUB_CI','CONFIGURE_WEEKLY_BACKUP_TASK',
        'USE_CUSTOM_WORKER_DOMAINS','GITHUB_PREVENT_SELF_REVIEW','ENABLE_SOUTHERN_CALIFORNIA_GEOCODING',
        'AI_USE_GROQ','AI_OPENAI_FALLBACK_ENABLED','AI_WEB_SEARCH_ENABLED','ENABLE_GOOGLE_OAUTH')) {
        if ($Configuration.Contains($name)) { [void](ConvertTo-EPBoolean -Value $Configuration[$name] -Name $name) }
    }

    foreach ($name in @('SUPABASE_DATABASE_WARNING_BYTES','SUPABASE_DATABASE_BLOCK_BYTES','GCP_MONTHLY_BUDGET_USD',
        'GCP_ARTIFACT_KEEP_COUNT','STATECARE_MIN_INSTANCES','STATECARE_MAX_INSTANCES','STATECARE_CONCURRENCY',
        'STATECARE_REQUEST_TIMEOUT_SECONDS','GEOCODER_PROCESS_AFTER_IMPORT_LIMIT','MENIFEE_GEOCODING_LIMIT',
        'SOUTHERN_CALIFORNIA_GEOCODING_LIMIT','GEOCODIO_INITIAL_BATCH_SIZE','GEOCODIO_INITIAL_MAX_ITEMS',
        'CALIFORNIA_NOMINATIM_DELTA_LIMIT','CALIFORNIA_NOMINATIM_REQUESTS_PER_MINUTE',
        'BACKUP_RETENTION_DAYS','ARTIFACT_RETENTION_DAYS')) {
        if ($Configuration.Contains($name)) {
            $number = 0L
            if (-not [long]::TryParse($Configuration[$name], [ref]$number) -or $number -lt 0) { throw "$name must be a non-negative integer." }
        }
    }
    foreach ($name in @('GCP_ARTIFACT_KEEP_COUNT','ARTIFACT_RETENTION_DAYS','GEOCODIO_INITIAL_BATCH_SIZE',
        'GEOCODIO_INITIAL_MAX_ITEMS','CALIFORNIA_NOMINATIM_DELTA_LIMIT',
        'CALIFORNIA_NOMINATIM_REQUESTS_PER_MINUTE')) {
        if ([long]$Configuration[$name] -lt 1) { throw "$name must be a positive integer." }
    }
    foreach ($name in @('GEOCODIO_MIN_ACCURACY','STATEWIDE_GEOCODING_REQUIRED_COVERAGE_PERCENT')) {
        $number = 0.0
        if (-not [double]::TryParse(
            [string]$Configuration[$name],
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$number
        )) {
            throw "$name must be an invariant decimal number."
        }
        if ($name -eq 'GEOCODIO_MIN_ACCURACY' -and ($number -lt 0 -or $number -gt 1)) {
            throw 'GEOCODIO_MIN_ACCURACY must be between 0 and 1.'
        }
        if ($name -eq 'STATEWIDE_GEOCODING_REQUIRED_COVERAGE_PERCENT' -and ($number -lt 99 -or $number -gt 100)) {
            throw 'STATEWIDE_GEOCODING_REQUIRED_COVERAGE_PERCENT must be between 99 and 100.'
        }
    }

    if ($Configuration.SUPABASE_STAGING_PROJECT_REF -eq $Configuration.SUPABASE_PRODUCTION_PROJECT_REF) {
        throw 'Staging and production Supabase project references must be different.'
    }
    if ($Configuration.GITHUB_DEPLOYMENT_MODE -ne 'free-private') {
        throw 'GITHUB_DEPLOYMENT_MODE must be free-private for this private GitHub Free deployment toolkit.'
    }
    if ($Configuration.PRIMARY_DOMAIN -eq 'example.com' -or $Configuration.OPERATIONS_EMAIL.EndsWith('@example.com') -or $Configuration.INITIAL_SUPER_ADMIN_EMAIL.EndsWith('@example.com')) {
        throw 'Replace the example.com domain and email placeholders before deployment.'
    }
    if ($Configuration.GCP_PROJECT_ID -notmatch '^[a-z][a-z0-9-]{4,28}[a-z0-9]$') { throw 'GCP_PROJECT_ID is not a valid Google Cloud project ID.' }
    if ($Configuration.GCP_BILLING_ACCOUNT_ID -notmatch '^[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}$') { throw 'GCP_BILLING_ACCOUNT_ID must look like 000000-000000-000000.' }
    if ($Configuration.CLOUDFLARE_ACCOUNT_ID -notmatch '^[0-9a-fA-F]{32}$' -or $Configuration.CLOUDFLARE_ZONE_ID -notmatch '^[0-9a-fA-F]{32}$') {
        throw 'Cloudflare account and zone IDs must each be 32 hexadecimal characters.'
    }
    if ($Configuration.SUPABASE_STAGING_PROJECT_REF -notmatch '^[a-z0-9]{8,32}$' -or $Configuration.SUPABASE_PRODUCTION_PROJECT_REF -notmatch '^[a-z0-9]{8,32}$') {
        throw 'Supabase project refs must be lowercase alphanumeric project identifiers.'
    }
    foreach ($poolerHostName in @('SUPABASE_STAGING_POOLER_HOST','SUPABASE_PRODUCTION_POOLER_HOST')) {
        $poolerHost = [string]$Configuration[$poolerHostName]
        if ($poolerHost -notmatch '^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.pooler\.supabase\.com$') {
            throw "$poolerHostName must be a Supabase pooler hostname without a scheme, port, path, or credentials."
        }
    }
    if ($Configuration.NOMINATIM_USER_AGENT -notmatch [regex]::Escape($Configuration.OPERATIONS_EMAIL)) {
        throw 'NOMINATIM_USER_AGENT must contain OPERATIONS_EMAIL as a valid contact identity.'
    }
    if ([long]$Configuration.SUPABASE_DATABASE_WARNING_BYTES -ge [long]$Configuration.SUPABASE_DATABASE_BLOCK_BYTES) {
        throw 'SUPABASE_DATABASE_WARNING_BYTES must be below SUPABASE_DATABASE_BLOCK_BYTES.'
    }
    if ([int]$Configuration.MENIFEE_GEOCODING_LIMIT -gt 100 -or [int]$Configuration.SOUTHERN_CALIFORNIA_GEOCODING_LIMIT -gt 100) {
        throw 'Public Nominatim geocoding limits must not exceed 100 items per run.'
    }
    if ([int]$Configuration.GEOCODER_PROCESS_AFTER_IMPORT_LIMIT -ne 0) {
        throw 'GEOCODER_PROCESS_AFTER_IMPORT_LIMIT must be 0 for production imports.'
    }
    if ([int]$Configuration.GEOCODIO_INITIAL_BATCH_SIZE -gt 10000) {
        throw 'GEOCODIO_INITIAL_BATCH_SIZE must not exceed the Geocodio batch limit of 10000.'
    }
    if ([int]$Configuration.GEOCODIO_INITIAL_MAX_ITEMS -lt [int]$Configuration.GEOCODIO_INITIAL_BATCH_SIZE) {
        throw 'GEOCODIO_INITIAL_MAX_ITEMS must be at least GEOCODIO_INITIAL_BATCH_SIZE.'
    }
    if ([int]$Configuration.CALIFORNIA_NOMINATIM_DELTA_LIMIT -gt 100) {
        throw 'CALIFORNIA_NOMINATIM_DELTA_LIMIT must not exceed the public-policy backlog ceiling of 100.'
    }
    if ([int]$Configuration.CALIFORNIA_NOMINATIM_REQUESTS_PER_MINUTE -gt 4) {
        throw 'CALIFORNIA_NOMINATIM_REQUESTS_PER_MINUTE must not exceed 4.'
    }
    $acceptedAccuracyTypes = @(
        ([string]$Configuration.GEOCODIO_ACCEPTED_ACCURACY_TYPES).Split(',') |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Where-Object { $_ }
    )
    $allowedAccuracyTypes = @('rooftop','point','range_interpolation','nearest_rooftop_match')
    if (-not $acceptedAccuracyTypes.Count -or @($acceptedAccuracyTypes | Where-Object { $_ -notin $allowedAccuracyTypes }).Count) {
        throw "GEOCODIO_ACCEPTED_ACCURACY_TYPES may contain only: $($allowedAccuracyTypes -join ', ')."
    }
    if ($acceptedAccuracyTypes.Count -ne @($acceptedAccuracyTypes | Select-Object -Unique).Count) {
        throw 'GEOCODIO_ACCEPTED_ACCURACY_TYPES must not contain duplicates.'
    }
    if ([string]$Configuration.STAGING_GEOCODIO_API_KEY_SECRET -ceq [string]$Configuration.PRODUCTION_GEOCODIO_API_KEY_SECRET) {
        throw 'Staging and production Geocodio API key secret names must be different.'
    }
    $gcpSecretNamePattern = '^[A-Za-z][A-Za-z0-9_-]{0,254}$'
    foreach ($name in @('STAGING_GEOCODIO_API_KEY_SECRET','PRODUCTION_GEOCODIO_API_KEY_SECRET')) {
        if ([string]$Configuration[$name] -notmatch $gcpSecretNamePattern) {
            throw "$name must be a Google Secret Manager resource name, not an API key."
        }
    }
    $expectedStagingHost = "elderpath-staging.$($Configuration.CLOUDFLARE_WORKERS_SUBDOMAIN).workers.dev"
    if ([string]$Configuration.STAGING_APP_HOST -cne $expectedStagingHost) {
        throw "STAGING_APP_HOST must be the exact workers.dev hostname $expectedStagingHost."
    }
    if ([string]$Configuration.PRODUCTION_APP_HOST -cne [string]$Configuration.PRIMARY_DOMAIN) {
        throw 'PRODUCTION_APP_HOST must exactly equal PRIMARY_DOMAIN for the canonical apex deployment.'
    }
    if (-not $Configuration.EMAIL_SENDING_DOMAIN.EndsWith(".$($Configuration.PRIMARY_DOMAIN)", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'EMAIL_SENDING_DOMAIN must be a subdomain of PRIMARY_DOMAIN.'
    }
    if ($Configuration.GITHUB_DEFAULT_BRANCH -cne 'main' -or $Configuration.GITHUB_STAGING_BRANCH -cne 'dev') {
        throw 'The release topology requires GITHUB_DEFAULT_BRANCH=main and GITHUB_STAGING_BRANCH=dev.'
    }

    $forbiddenKeyPattern = '(?i)(^|_)(PASSWORD|TOKEN|API_KEY|CLIENT_SECRET|DATABASE_URL)$'
    $allowedNamePattern = '(?i)(_SECRET$|SECRET_NAME$)'
    foreach ($entry in $Configuration.GetEnumerator()) {
        if ($entry.Key -match $forbiddenKeyPattern -and $entry.Key -notmatch $allowedNamePattern) {
            throw "Secret-bearing key '$($entry.Key)' is not allowed in deployment.env. Store only remote secret resource names."
        }
        $value = [string]$entry.Value
        if ($value -match '(?i)(postgres(?:ql)?://[^\s]+:[^\s]+@|sk-[A-Za-z0-9_-]{16,}|-----BEGIN [A-Z ]+PRIVATE KEY-----)') {
            throw "Configuration value '$($entry.Key)' appears to contain a secret."
        }
    }
    return $true
}

function Assert-EPSupabaseUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][ValidateSet('asyncpg','psycopg')][string]$Driver,
        [Parameter(Mandatory)][string]$ProjectRef,
        [Parameter(Mandatory)][string]$PoolerHost,
        [string]$Context = 'The Supabase URL'
    )
    Add-EPRedaction $Value
    $expectedPrefix = "postgresql+${Driver}://"
    if (-not $Value.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Context must start with $expectedPrefix. Supabase displays postgresql://; replace only that prefix with $expectedPrefix."
    }
    try { $uri = [uri]$Value } catch { throw "$Context is malformed." }
    if (-not $uri.Host -or -not $uri.UserInfo.Contains(':') -or $uri.AbsolutePath -eq '/') { throw "$Context must contain credentials, pooler host, and database name." }
    $userInfo = $uri.UserInfo.Split(':',2)
    $userName = [uri]::UnescapeDataString($userInfo[0])
    $password = if ($userInfo.Count -eq 2) { [uri]::UnescapeDataString($userInfo[1]) } else { '' }
    if ($userName -cne "postgres.$ProjectRef") { throw "$Context must use the exact Session pooler username postgres.$ProjectRef." }
    if ([string]::IsNullOrWhiteSpace($password) -or $password -match '(?i)^\[?YOUR-PASSWORD\]?$|^<.*PASSWORD.*>$|DATABASE-PASSWORD') {
        throw "$Context must contain the actual percent-encoded database password, not a placeholder."
    }
    if ($uri.Host -ine $PoolerHost) { throw "$Context must use the configured Session pooler host $PoolerHost." }
    if ($uri.Port -ne 5432) { throw "$Context must use Session pooler port 5432." }
    if ($uri.AbsolutePath -cne '/postgres') { throw "$Context must use database /postgres." }
    $query = @{}
    foreach ($pair in $uri.Query.TrimStart('?').Split('&',[System.StringSplitOptions]::RemoveEmptyEntries)) {
        $parts = $pair.Split('=',2)
        $key = [uri]::UnescapeDataString($parts[0])
        $query[$key] = if ($parts.Count -eq 2) { [uri]::UnescapeDataString($parts[1]) } else { '' }
    }
    $requiredSslParameter = if ($Driver -eq 'asyncpg') { 'ssl' } else { 'sslmode' }
    $incompatibleSslParameter = if ($Driver -eq 'asyncpg') { 'sslmode' } else { 'ssl' }
    if ($query.ContainsKey($incompatibleSslParameter)) {
        throw "$Context must not include $incompatibleSslParameter for the $Driver driver; use ${requiredSslParameter}=require."
    }
    if (-not $query.ContainsKey($requiredSslParameter) -or $query[$requiredSslParameter] -cne 'require') {
        throw "$Context must include ${requiredSslParameter}=require for the $Driver driver."
    }
    return $true
}

function ConvertTo-EPSupabaseConnectionUrlSet {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword',
        'CredentialValue',
        Justification='The securely prompted value must be percent-encoded in memory before constructing server-only connection URLs.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{8,32}$')][string]$ProjectRef,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.pooler\.supabase\.com$')][string]$PoolerHost,
        [Parameter(Mandatory)][string]$CredentialValue
    )

    Add-EPRedaction $CredentialValue
    if ([string]::IsNullOrWhiteSpace($CredentialValue) -or $CredentialValue -match '(?i)^\[?YOUR-PASSWORD\]?$|^<.*PASSWORD.*>$|DATABASE-PASSWORD') {
        throw 'The Supabase database password cannot be empty or a placeholder.'
    }
    $encodedPassword = [uri]::EscapeDataString($CredentialValue)
    $base = "postgres.$ProjectRef`:$encodedPassword@$PoolerHost`:5432/postgres"
    $urls = [pscustomobject]@{
        Async = "postgresql+asyncpg://$base`?ssl=require"
        Sync = "postgresql+psycopg://$base`?sslmode=require"
    }
    Add-EPRedaction $urls.Async
    Add-EPRedaction $urls.Sync
    [void](Assert-EPSupabaseUrl -Value $urls.Async -Driver asyncpg -ProjectRef $ProjectRef -PoolerHost $PoolerHost -Context 'Generated async Supabase URL')
    [void](Assert-EPSupabaseUrl -Value $urls.Sync -Driver psycopg -ProjectRef $ProjectRef -PoolerHost $PoolerHost -Context 'Generated sync Supabase URL')
    return $urls
}

function Invoke-EPValidatedSecretPublication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$UrlSets,
        [Parameter(Mandatory)][scriptblock]$Probe,
        [Parameter(Mandatory)][scriptblock]$Publish
    )

    $tiers = @('STAGING','PRODUCTION')
    foreach ($tier in $tiers) {
        if (-not $UrlSets.Contains($tier)) { throw "Missing $tier Supabase URL set." }
        $urlSet = $UrlSets[$tier]
        if ($null -eq $urlSet -or -not $urlSet.PSObject.Properties['Async'] -or -not $urlSet.PSObject.Properties['Sync']) {
            throw "$tier Supabase URL set must contain Async and Sync values."
        }
        & $Probe $tier.ToLowerInvariant() ([string]$urlSet.Sync)
    }
    foreach ($tier in $tiers) {
        $urlSet = $UrlSets[$tier]
        & $Publish "${tier}_DATABASE_URL_SECRET" ([string]$urlSet.Async)
        & $Publish "${tier}_DATABASE_URL_SYNC_SECRET" ([string]$urlSet.Sync)
    }
}

function New-EPDryRunSupabaseUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('asyncpg','psycopg')][string]$Driver,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+$')][string]$ProjectRef
    )
    $sslQuery = if ($Driver -eq 'asyncpg') { 'ssl=require' } else { 'sslmode=require' }
    return "postgresql+${Driver}://postgres.${ProjectRef}:dry-run@pooler.supabase.invalid:5432/postgres?$sslQuery"
}

function ConvertTo-EPArtifactCleanupPolicyJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$KeepCount,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$RetentionDays
    )

    $policies = @(
        [ordered]@{
            name = 'delete-old'
            action = [ordered]@{ type = 'Delete' }
            condition = [ordered]@{ olderThan = "${RetentionDays}d" }
        },
        [ordered]@{
            name = 'keep-recent'
            action = [ordered]@{ type = 'Keep' }
            mostRecentVersions = [ordered]@{ keepCount = $KeepCount }
        }
    )
    return ConvertTo-Json -InputObject $policies -Depth 8
}

function Assert-EPArtifactCleanupPolicyJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Json)

    try {
        $policies = ConvertFrom-Json -InputObject $Json -ErrorAction Stop
    } catch {
        throw "Artifact Registry cleanup policy is not valid JSON: $($_.Exception.Message)"
    }
    if ($policies -isnot [System.Array]) {
        throw 'Artifact Registry cleanup policy root must be a JSON array.'
    }
    if ($policies.Count -ne 2) {
        throw 'Artifact Registry cleanup policy must contain exactly the delete-old and keep-recent policies.'
    }

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($policy in $policies) {
        if (-not $policy.PSObject.Properties['name'] -or [string]::IsNullOrWhiteSpace([string]$policy.name)) {
            throw 'Every Artifact Registry cleanup policy must have a nonempty name.'
        }
        if (-not $names.Add([string]$policy.name)) {
            throw "Artifact Registry cleanup policy names must be unique; duplicate '$($policy.name)'."
        }
        if (-not $policy.PSObject.Properties['action'] -or -not $policy.action.PSObject.Properties['type']) {
            throw "Artifact Registry cleanup policy '$($policy.name)' must define action.type."
        }
        $actionType = [string]$policy.action.type
        if ($actionType -cnotin @('Delete','Keep')) {
            throw "Artifact Registry cleanup policy '$($policy.name)' has unsupported action type '$actionType'."
        }
    }

    $deletePolicy = $policies | Where-Object name -EQ 'delete-old'
    $keepPolicy = $policies | Where-Object name -EQ 'keep-recent'
    if ($null -eq $deletePolicy -or $null -eq $keepPolicy) {
        throw 'Artifact Registry cleanup policy must contain delete-old and keep-recent policies.'
    }
    if ([string]$deletePolicy.action.type -cne 'Delete' -or
        -not $deletePolicy.PSObject.Properties['condition'] -or
        [string]$deletePolicy.condition.olderThan -notmatch '^[1-9][0-9]*d$') {
        throw 'The delete-old policy must use action.type Delete and a positive condition.olderThan day duration.'
    }

    $keepCount = 0L
    $hasKeepCount = $keepPolicy.PSObject.Properties['mostRecentVersions'] -and
        $keepPolicy.mostRecentVersions.PSObject.Properties['keepCount']
    if ([string]$keepPolicy.action.type -cne 'Keep' -or -not $hasKeepCount -or
        -not [long]::TryParse([string]$keepPolicy.mostRecentVersions.keepCount, [ref]$keepCount) -or
        $keepCount -lt 1) {
        throw 'The keep-recent policy must use action.type Keep and a positive mostRecentVersions.keepCount.'
    }
    return $true
}

function Add-EPRedaction {
    param([AllowNull()][string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value) -and $Value.Length -ge 4) { [void]$script:Redactions.Add($Value) }
}

function Protect-EPText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    $safe = $Text
    foreach ($secret in ($script:Redactions | Sort-Object Length -Descending)) { $safe = $safe.Replace($secret, '[REDACTED]') }
    $safe = [regex]::Replace($safe, '(?i)(postgres(?:ql)?://[^:\s]+:)[^@\s]+(@)', '$1[REDACTED]$2')
    $safe = [regex]::Replace($safe, '(?i)(authorization\s*:\s*(?:bearer|basic)\s+)[^\s]+', '$1[REDACTED]')
    return $safe
}

function Initialize-EPLogging {
    param([Parameter(Mandatory)][string]$Root)
    $logDirectory = Join-Path $Root 'logs'
    [System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
    $script:LogPath = Join-Path $logDirectory ("deployment-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    return $script:LogPath
}

function Write-EPLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $safe = Protect-EPText $Message
    $line = '{0} [{1}] {2}' -f (Get-Date).ToUniversalTime().ToString('o'), $Level, $safe
    Write-Host $line
    if ($script:LogPath) { [System.IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false)) }
}

function New-EPRandomSecret {
    [CmdletBinding()]
    param([ValidateRange(24,256)][int]$ByteLength = 48)
    $bytes = [byte[]]::new($ByteLength)
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function Read-EPSecureValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ([string]::IsNullOrWhiteSpace($plain)) { throw "$Prompt cannot be empty." }
        Add-EPRedaction $plain
        return $plain
    } finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}

function ConvertTo-EPLegacyProcessArgument {
    param([AllowEmptyString()][string]$Argument)
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }
    # CommandLineToArgvW-compatible quoting for Windows PowerShell/.NET Framework, where
    # ProcessStartInfo.ArgumentList is unavailable. Backslashes are doubled only when
    # they precede a quote or the closing delimiter.
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-EPCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [AllowNull()][string]$InputText,
        [hashtable]$Environment = @{},
        [switch]$AllowFailure,
        [switch]$NoLogOutput,
        [switch]$WhatIf
    )
    $display = "$FilePath " + (($ArgumentList | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' ')
    if ($WhatIf) {
        Write-EPLog "WHATIF $display"
        return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; Skipped = $true }
    }

    $resolvedFilePath = Resolve-EPExecutable @($FilePath)
    if (-not $resolvedFilePath) {
        throw "Executable not found: $FilePath. Run bootstrap.ps1 or correct the process PATH, then retry."
    }
    $display = "$resolvedFilePath " + (($ArgumentList | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' ')
    Write-EPLog "RUN $display"
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    # Batch files use %~dp0 to locate adjacent runtime files. A bare .cmd/.bat name makes
    # ProcessStartInfo preserve the caller's working directory instead of the installation path.
    $info.FileName = $resolvedFilePath
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.CreateNoWindow = $true
    if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }
    if ($info.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $ArgumentList) { [void]$info.ArgumentList.Add($argument) }
    } else {
        $info.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-EPLegacyProcessArgument ([string]$_) }) -join ' ')
    }
    foreach ($pair in $Environment.GetEnumerator()) { $info.Environment[$pair.Key] = [string]$pair.Value }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        if ($null -ne $InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if (-not $NoLogOutput) {
            if ($stdout.Trim()) { Write-EPLog (Protect-EPText $stdout.Trim()) }
            if ($stderr.Trim()) { Write-EPLog (Protect-EPText $stderr.Trim()) -Level $(if ($process.ExitCode) {'WARN'} else {'INFO'}) }
        } elseif ($process.ExitCode -ne 0 -and $stderr.Trim()) {
            # Successful secret reads stay silent. Failures retain a bounded, redacted diagnostic
            # so an installation problem is not hidden behind the generic exit-code exception.
            $diagnostic = Protect-EPText $stderr.Trim()
            $maximumDiagnosticLength = 4096
            if ($diagnostic.Length -gt $maximumDiagnosticLength) {
                $diagnostic = $diagnostic.Substring(0, $maximumDiagnosticLength) + ' [diagnostic truncated]'
            }
            Write-EPLog $diagnostic -Level WARN
        }
        if ($process.ExitCode -ne 0 -and -not $AllowFailure) { throw "Command failed with exit code $($process.ExitCode): $display" }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr; Skipped = $false }
    } finally { $process.Dispose() }
}

function Get-EPCheckpoint {
    param([Parameter(Mandatory)][string]$Root)
    $path = Join-Path $Root 'state\deployment-state.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{ Version = 1; UpdatedAt = $null; Completed = @(); PausedAt = $null; Resources = [ordered]@{} }
    }
    $state = ConvertTo-EPDictionary (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    if ($state.Version -ne 1) { throw "Unsupported checkpoint version $($state.Version)." }
    return $state
}

function ConvertTo-EPDictionary {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $dictionary = [ordered]@{}
        foreach ($key in $Value.Keys) { $dictionary[[string]$key] = ConvertTo-EPDictionary $Value[$key] }
        return $dictionary
    }
    if ($Value.PSObject.TypeNames -contains 'System.Management.Automation.PSCustomObject') {
        $dictionary = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $dictionary[$property.Name] = ConvertTo-EPDictionary $property.Value }
        return $dictionary
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-EPDictionary $_ })
    }
    return $Value
}

function Save-EPCheckpoint {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $directory = Join-Path $Root 'state'
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $State.UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
    $json = $State | ConvertTo-Json -Depth 12
    $temporary = Join-Path $directory ('deployment-state.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination (Join-Path $directory 'deployment-state.json') -Force
}

function Set-EPCheckpointComplete {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][System.Collections.IDictionary]$State, [Parameter(Mandatory)][string]$Name)
    if ($State.Completed -notcontains $Name) { $State.Completed = @($State.Completed) + $Name }
    $State.PausedAt = $null
    Save-EPCheckpoint -Root $Root -State $State
}

function Test-EPCheckpointComplete {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State, [Parameter(Mandatory)][string]$Name)
    return $State.Completed -contains $Name
}

function Request-EPTypedConfirmation {
    param([Parameter(Mandatory)][string]$Expected, [Parameter(Mandatory)][string]$Message)
    $answer = Read-Host "$Message Type '$Expected' to continue"
    if ($answer -cne $Expected) { throw 'Confirmation did not match; no production change was made.' }
}

function Resolve-EPExecutable {
    param([Parameter(Mandatory)][string[]]$Candidates)
    foreach ($candidate in $Candidates) {
        if ([System.IO.Path]::IsPathRooted($candidate) -and (Test-Path -LiteralPath $candidate)) { return $candidate }
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    return $null
}

function Get-EPPowerShellExecutableStatus {
    [CmdletBinding()]
    param([string[]]$Candidates)

    if (-not $Candidates) {
        $discovered = Get-Command pwsh -ErrorAction SilentlyContinue
        $Candidates = @(
            if ($discovered) { $discovered.Source }
            if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe' }
            if ($env:ProgramW6432) { Join-Path $env:ProgramW6432 'PowerShell\7\pwsh.exe' }
            if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }
            if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe' }
        )
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $resolved = $null
        if ([IO.Path]::IsPathRooted($candidate)) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $resolved = (Resolve-Path -LiteralPath $candidate).Path }
        } else {
            $command = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($command) { $resolved = $command.Source }
        }
        if (-not $resolved) {
            [pscustomobject]@{ Candidate=$candidate; Path=$null; Exists=$false; Launchable=$false; MajorVersion=$null; Compatible=$false; Error='not_found' }
            continue
        }
        if (-not $seen.Add($resolved)) { continue }

        $majorVersion = $null
        $launchError = $null
        try {
            $versionOutput = & $resolved -NoLogo -NoProfile -NonInteractive -Command '[Console]::Out.Write($PSVersionTable.PSVersion.Major)' 2>$null
            $exitCode = $LASTEXITCODE
            $parsedVersion = 0
            if ($exitCode -eq 0 -and [int]::TryParse(([string]$versionOutput).Trim(), [ref]$parsedVersion)) {
                $majorVersion = $parsedVersion
            } else {
                $launchError = if ($exitCode -ne 0) { "exit_$exitCode" } else { 'invalid_version_output' }
            }
        } catch {
            $launchError = 'launch_failed'
        }
        $launchable = $null -ne $majorVersion
        [pscustomobject]@{
            Candidate=$candidate
            Path=$resolved
            Exists=$true
            Launchable=$launchable
            MajorVersion=$majorVersion
            Compatible=($launchable -and $majorVersion -ge 7)
            Error=$launchError
        }
    }
}

function Get-EPBootstrapRelaunchArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [switch]$SkipDockerWait,
        [switch]$SkipNpmInstall,
        [switch]$WhatIf
    )
    $arguments = @('-NoProfile','-File',$ScriptPath,'-ConfigurationPath',$ConfigurationPath)
    if ($SkipDockerWait) { $arguments += '-SkipDockerWait' }
    if ($SkipNpmInstall) { $arguments += '-SkipNpmInstall' }
    if ($WhatIf) { $arguments += '-WhatIf' }
    return $arguments
}

function ConvertTo-EPCloudflareDnsRecordBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][object]$SourceRecord
    )

    $body = @{
        type = $Type
        name = $Name
        content = $Content
        ttl = 1
        proxied = $false
    }
    $priorityProperty = $SourceRecord.PSObject.Properties['priority']
    if ($null -eq $priorityProperty -or $null -eq $priorityProperty.Value) {
        return $body
    }

    $priorityText = [string]$priorityProperty.Value
    if ([string]::IsNullOrWhiteSpace($priorityText)) {
        return $body
    }

    $priority = 0
    $parsed = [int]::TryParse(
        $priorityText,
        [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$priority
    )
    if (-not $parsed -or $priority -lt 0 -or $priority -gt 65535) {
        throw "Resend DNS priority must be an integer from 0 through 65535; received '$priorityText'."
    }
    $body.priority = $priority
    return $body
}

function Test-EPCloudflareApiErrorCode {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Payload,
        [Parameter(Mandatory)][int]$Code
    )

    if ([string]::IsNullOrWhiteSpace($Payload)) {
        return $false
    }
    try {
        $response = $Payload | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $false
    }
    $errorsProperty = $response.PSObject.Properties['errors']
    if ($null -eq $errorsProperty -or $null -eq $errorsProperty.Value) {
        return $false
    }
    foreach ($errorItem in @($errorsProperty.Value)) {
        $codeProperty = $errorItem.PSObject.Properties['code']
        if ($null -ne $codeProperty -and [string]$codeProperty.Value -eq [string]$Code) {
            return $true
        }
    }
    return $false
}

function Get-EPReleaseCheckpointName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$CommitSha
    )
    if ($CommitSha -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Release commit must be a full 40-character Git SHA; received '$CommitSha'."
    }
    $normalizedCategory = ($Category.ToLowerInvariant() -replace '[^a-z0-9.-]', '-') -replace '-+', '-'
    return "$normalizedCategory.$($CommitSha.ToLowerInvariant())"
}

function Invoke-EPR2BucketCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BucketName,
        [Parameter(Mandatory)][scriptblock]$GetObjectList,
        [Parameter(Mandatory)][scriptblock]$GetWorkerSettings,
        [Parameter(Mandatory)][scriptblock]$ConfirmDeletion,
        [Parameter(Mandatory)][scriptblock]$DeleteBucket,
        [switch]$DryRun
    )
    if ($DryRun) {
        return [pscustomobject]@{ BucketName=$BucketName; Deleted=$false; Skipped=$true }
    }

    $objects = & $GetObjectList $BucketName
    $objectSuccess = $objects.PSObject.Properties['success']
    $objectResult = $objects.PSObject.Properties['result']
    if ($null -eq $objectSuccess -or $objectSuccess.Value -ne $true -or $null -eq $objectResult) {
        throw "Cloudflare did not return a successful object listing for R2 bucket '$BucketName'."
    }
    if (@($objectResult.Value).Count -ne 0) {
        throw "R2 bucket '$BucketName' is not empty. No objects will be deleted automatically."
    }
    $resultInfo = $objects.PSObject.Properties['result_info']
    if ($null -ne $resultInfo -and $null -ne $resultInfo.Value) {
        $truncated = $resultInfo.Value.PSObject.Properties['is_truncated']
        if ($null -ne $truncated -and $truncated.Value -eq $true) {
            throw "Cloudflare returned a truncated object listing for R2 bucket '$BucketName'; cleanup cannot prove it is empty."
        }
    }

    $workerSettings = @(& $GetWorkerSettings)
    foreach ($worker in $workerSettings) {
        $scriptName = [string]$worker.ScriptName
        $response = $worker.Response
        $settingsSuccess = $response.PSObject.Properties['success']
        $settingsResult = $response.PSObject.Properties['result']
        if ($null -eq $settingsSuccess -or $settingsSuccess.Value -ne $true -or $null -eq $settingsResult) {
            throw "Cloudflare did not return readable settings for Worker '$scriptName'."
        }
        $bindingsProperty = $settingsResult.Value.PSObject.Properties['bindings']
        $bindings = if ($null -eq $bindingsProperty -or $null -eq $bindingsProperty.Value) { @() } else { @($bindingsProperty.Value) }
        foreach ($binding in $bindings) {
            $typeProperty = $binding.PSObject.Properties['type']
            $bucketProperty = $binding.PSObject.Properties['bucket_name']
            if ($null -ne $typeProperty -and $typeProperty.Value -eq 'r2_bucket' -and
                $null -ne $bucketProperty -and $bucketProperty.Value -eq $BucketName) {
                throw "R2 bucket '$BucketName' is still bound to Worker '$scriptName'."
            }
        }
    }

    & $ConfirmDeletion $BucketName
    & $DeleteBucket $BucketName
    return [pscustomobject]@{ BucketName=$BucketName; Deleted=$true; Skipped=$false }
}

Export-ModuleMember -Function ConvertFrom-EPEnvFile,ConvertTo-EPBoolean,Assert-EPConfiguration,Add-EPRedaction,
    Assert-EPSupabaseUrl,New-EPDryRunSupabaseUrl,ConvertTo-EPArtifactCleanupPolicyJson,Assert-EPArtifactCleanupPolicyJson,
    Protect-EPText,Initialize-EPLogging,Write-EPLog,New-EPRandomSecret,Read-EPSecureValue,Invoke-EPCommand,
    Get-EPCheckpoint,Save-EPCheckpoint,Set-EPCheckpointComplete,Test-EPCheckpointComplete,
    Request-EPTypedConfirmation,Resolve-EPExecutable,Get-EPPowerShellExecutableStatus,Get-EPBootstrapRelaunchArguments,
    ConvertTo-EPCloudflareDnsRecordBody,Test-EPCloudflareApiErrorCode,ConvertTo-EPSupabaseConnectionUrlSet,
    Get-EPReleaseCheckpointName,Invoke-EPR2BucketCleanup,
    Invoke-EPValidatedSecretPublication

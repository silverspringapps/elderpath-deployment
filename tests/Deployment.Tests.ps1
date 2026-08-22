BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'lib\ElderPath.Deployment.psm1') -Force
    $script:ExamplePath = Join-Path $script:Root 'config\deployment.env.example'
}

Describe 'Strict deployment.env parsing' {
    It 'parses values literally without evaluating PowerShell' {
        $path = Join-Path $TestDrive 'literal.env'
        [IO.File]::WriteAllText($path, "SAFE=`$(throw 'executed')`nPLAIN=value=with=equals`n")
        $result = ConvertFrom-EPEnvFile $path
        $result.SAFE | Should -Be '$(throw ''executed'')'
        $result.PLAIN | Should -Be 'value=with=equals'
    }

    It 'rejects duplicate keys' {
        $path = Join-Path $TestDrive 'duplicate.env'
        [IO.File]::WriteAllText($path, "VALUE=one`nVALUE=two`n")
        { ConvertFrom-EPEnvFile $path } | Should -Throw '*Duplicate*'
    }

    It 'rejects shell export syntax and invalid lines' {
        $path = Join-Path $TestDrive 'shell.env'
        [IO.File]::WriteAllText($path, "export TOKEN=value`n")
        { ConvertFrom-EPEnvFile $path } | Should -Throw '*shell syntax*'
    }
}

Describe 'Configuration validation' {
    BeforeEach {
        $script:Valid = ConvertFrom-EPEnvFile $script:ExamplePath
        $script:Valid.PRIMARY_DOMAIN = 'elderpath.test'
        $script:Valid.CLOUDFLARE_WORKERS_SUBDOMAIN = 'elderpath'
        $script:Valid.STAGING_APP_HOST = 'elderpath-staging.elderpath.workers.dev'
        $script:Valid.PRODUCTION_APP_HOST = 'elderpath.test'
        $script:Valid.EMAIL_SENDING_DOMAIN = 'mail.elderpath.test'
        $script:Valid.EMAIL_FROM = 'ElderPath <no-reply@mail.elderpath.test>'
        $script:Valid.OPERATIONS_EMAIL = 'ops@elderpath.test'
        $script:Valid.INITIAL_SUPER_ADMIN_EMAIL = 'admin@elderpath.test'
        $script:Valid.NOMINATIM_USER_AGENT = 'ElderPath-StateCare/1.0 (ops@elderpath.test)'
        $script:Valid.SUPABASE_STAGING_PROJECT_REF = 'abcdefghijklmnopqrst'
        $script:Valid.SUPABASE_PRODUCTION_PROJECT_REF = 'zyxwvutsrqponmlkjihg'
        $script:Valid.SUPABASE_STAGING_POOLER_HOST = 'aws-0-us-west-1.pooler.supabase.com'
        $script:Valid.SUPABASE_PRODUCTION_POOLER_HOST = 'aws-0-us-east-1.pooler.supabase.com'
        $script:Valid.GCP_PROJECT_ID = 'elderpath-prod1'
        $script:Valid.GCP_BILLING_ACCOUNT_ID = 'ABCDEF-123456-ABCDEF'
        $script:Valid.CLOUDFLARE_ACCOUNT_ID = '0123456789abcdef0123456789abcdef'
        $script:Valid.CLOUDFLARE_ZONE_ID = 'abcdef0123456789abcdef0123456789'
        $script:Valid.GITHUB_STAGING_BRANCH = 'dev'
    }

    It 'accepts the completed example' { Assert-EPConfiguration $script:Valid | Should -BeTrue }

    It 'rejects the same Supabase project for both environments' {
        $script:Valid.SUPABASE_PRODUCTION_PROJECT_REF = $script:Valid.SUPABASE_STAGING_PROJECT_REF
        { Assert-EPConfiguration $script:Valid } | Should -Throw '*must be different*'
    }

    It 'requires the private GitHub Free deployment mode' {
        $script:Valid.GITHUB_DEPLOYMENT_MODE = 'protected-environments'
        { Assert-EPConfiguration $script:Valid } | Should -Throw '*GITHUB_DEPLOYMENT_MODE must be free-private*'
    }

    It 'rejects geocoding batches above the public Nominatim cap' {
        $script:Valid.MENIFEE_GEOCODING_LIMIT = '101'
        { Assert-EPConfiguration $script:Valid } | Should -Throw '*must not exceed 100*'
    }

    It 'rejects a statewide Nominatim delta above the public-policy ceiling' {
        $script:Valid.CALIFORNIA_NOMINATIM_DELTA_LIMIT = '101'
        { Assert-EPConfiguration $script:Valid } | Should -Throw '*backlog ceiling of 100*'
    }

    It 'requires a measured statewide coverage gate of at least 99 percent' {
        $script:Valid.STATEWIDE_GEOCODING_REQUIRED_COVERAGE_PERCENT = '98.9'
        { Assert-EPConfiguration $script:Valid } | Should -Throw '*must be between 99 and 100*'
    }

    It 'requires distinct staging and production Geocodio secret names' {
        $script:Valid.PRODUCTION_GEOCODIO_API_KEY_SECRET = $script:Valid.STAGING_GEOCODIO_API_KEY_SECRET
        { Assert-EPConfiguration $script:Valid } | Should -Throw '*Geocodio API key secret names must be different*'
    }

    It 'rejects a Geocodio API key stored as the Secret Manager name' {
        $script:Valid.STAGING_GEOCODIO_API_KEY_SECRET = '58b6d175d5babbaa571b59dd95bba6ca86a9817'
        { Assert-EPConfiguration $script:Valid } | Should -Throw '*Secret Manager resource name*'
    }

    It 'requires positive Artifact Registry retention values' {
        $script:Valid.GCP_ARTIFACT_KEEP_COUNT = '0'
        { Assert-EPConfiguration $script:Valid } | Should -Throw '*GCP_ARTIFACT_KEEP_COUNT must be a positive integer*'

        $script:Valid.GCP_ARTIFACT_KEEP_COUNT = '3'
        $script:Valid.ARTIFACT_RETENTION_DAYS = '0'
        { Assert-EPConfiguration $script:Valid } | Should -Throw '*ARTIFACT_RETENTION_DAYS must be a positive integer*'
    }

    It 'rejects embedded database credentials' {
        $script:Valid['UNRELATED_SETTING'] = 'postgresql://user:password@host/database'
        { Assert-EPConfiguration $script:Valid } | Should -Throw '*appears to contain a secret*'
    }

    It 'rejects a raw secret-bearing configuration key' {
        $script:Valid['OPENAI_API_KEY'] = 'not-allowed-here'
        { Assert-EPConfiguration $script:Valid } | Should -Throw '*not allowed*'
    }

    It 'requires host-only Supabase pooler configuration' {
        $script:Valid.SUPABASE_STAGING_POOLER_HOST = 'https://aws-0-us-west-1.pooler.supabase.com:5432/postgres'
        { Assert-EPConfiguration $script:Valid } | Should -Throw '*pooler hostname without a scheme*'
    }
}

Describe 'Supabase connection validation' {
    BeforeAll {
        $script:PoolerHost = 'aws-0-us-west-1.pooler.supabase.com'
        $script:ProjectRef = 'abcdefghijklmnopqrst'
    }

    It 'accepts a matching async session-pooler URL' {
        Assert-EPSupabaseUrl `
            -Value 'postgresql+asyncpg://postgres.abcdefghijklmnopqrst:password@aws-0-us-west-1.pooler.supabase.com:5432/postgres?ssl=require' `
            -Driver asyncpg -ProjectRef $script:ProjectRef -PoolerHost $script:PoolerHost | Should -BeTrue
    }

    It 'accepts a matching psycopg session-pooler URL' {
        Assert-EPSupabaseUrl `
            -Value 'postgresql+psycopg://postgres.abcdefghijklmnopqrst:password@aws-0-us-west-1.pooler.supabase.com:5432/postgres?sslmode=require' `
            -Driver psycopg -ProjectRef $script:ProjectRef -PoolerHost $script:PoolerHost | Should -BeTrue
    }

    It 'rejects a reversed project or wrong driver' {
        {
            Assert-EPSupabaseUrl `
                -Value 'postgresql+psycopg://postgres.abcdefghijklmnopqrst:password@aws-0-us-west-1.pooler.supabase.com:5432/postgres?sslmode=require' `
                -Driver asyncpg -ProjectRef 'zyxwvutsrqponmlkjihg' -PoolerHost $script:PoolerHost
        } | Should -Throw
    }

    It 'creates valid non-routable async and sync dry-run URLs' {
        $projectRef = 'abcdefghijklmnopqrst'
        $asyncUrl = New-EPDryRunSupabaseUrl -Driver asyncpg -ProjectRef $projectRef
        $syncUrl = New-EPDryRunSupabaseUrl -Driver psycopg -ProjectRef $projectRef
        Assert-EPSupabaseUrl -Value $asyncUrl -Driver asyncpg -ProjectRef $projectRef -PoolerHost 'pooler.supabase.invalid' | Should -BeTrue
        Assert-EPSupabaseUrl -Value $syncUrl -Driver psycopg -ProjectRef $projectRef -PoolerHost 'pooler.supabase.invalid' | Should -BeTrue
        ([uri]$asyncUrl).Host | Should -Be 'pooler.supabase.invalid'
        ([uri]$syncUrl).Host | Should -Be 'pooler.supabase.invalid'
        ([uri]$asyncUrl).Query | Should -Be '?ssl=require'
        ([uri]$syncUrl).Query | Should -Be '?sslmode=require'
    }

    It 'derives both driver URLs and percent-encodes a special-character password' {
        $urls = ConvertTo-EPSupabaseConnectionUrlSet -ProjectRef $script:ProjectRef -PoolerHost $script:PoolerHost -CredentialValue 'p@ss:/?#% value'
        $urls.Async | Should -Be 'postgresql+asyncpg://postgres.abcdefghijklmnopqrst:p%40ss%3A%2F%3F%23%25%20value@aws-0-us-west-1.pooler.supabase.com:5432/postgres?ssl=require'
        $urls.Sync | Should -Be 'postgresql+psycopg://postgres.abcdefghijklmnopqrst:p%40ss%3A%2F%3F%23%25%20value@aws-0-us-west-1.pooler.supabase.com:5432/postgres?sslmode=require'
    }

    It 'rejects SSL parameters belonging to the other database driver' {
        {
            Assert-EPSupabaseUrl `
                -Value 'postgresql+asyncpg://postgres.abcdefghijklmnopqrst:password@aws-0-us-west-1.pooler.supabase.com:5432/postgres?sslmode=require' `
                -Driver asyncpg -ProjectRef $script:ProjectRef -PoolerHost $script:PoolerHost
        } | Should -Throw '*must not include sslmode*use ssl=require*'
        {
            Assert-EPSupabaseUrl `
                -Value 'postgresql+psycopg://postgres.abcdefghijklmnopqrst:password@aws-0-us-west-1.pooler.supabase.com:5432/postgres?ssl=require' `
                -Driver psycopg -ProjectRef $script:ProjectRef -PoolerHost $script:PoolerHost
        } | Should -Throw '*must not include ssl*use sslmode=require*'
    }

    It 'rejects invalid Session pooler URL components' -TestCases @(
        @{ Value='postgresql+asyncpg://postgres.wrongprojectref:password@aws-0-us-west-1.pooler.supabase.com:5432/postgres?ssl=require'; ExpectedError='*exact Session pooler username*' }
        @{ Value='postgresql+asyncpg://postgres.abcdefghijklmnopqrst:password@other.pooler.supabase.com:5432/postgres?ssl=require'; ExpectedError='*configured Session pooler host*' }
        @{ Value='postgresql+asyncpg://postgres.abcdefghijklmnopqrst:password@aws-0-us-west-1.pooler.supabase.com:6543/postgres?ssl=require'; ExpectedError='*port 5432*' }
        @{ Value='postgresql+asyncpg://postgres.abcdefghijklmnopqrst:password@aws-0-us-west-1.pooler.supabase.com:5432/post?ssl=require'; ExpectedError='*database /postgres*' }
        @{ Value='postgresql+asyncpg://postgres.abcdefghijklmnopqrst:password@aws-0-us-west-1.pooler.supabase.com:5432/postgres'; ExpectedError='*ssl=require*' }
        @{ Value='postgresql+asyncpg://postgres.abcdefghijklmnopqrst:%3CYOUR-PASSWORD%3E@aws-0-us-west-1.pooler.supabase.com:5432/postgres?ssl=require'; ExpectedError='*actual percent-encoded database password*' }
    ) {
        param($Value,$ExpectedError)
        $candidate = $Value
        {
            Assert-EPSupabaseUrl -Value $candidate -Driver asyncpg -ProjectRef $script:ProjectRef -PoolerHost $script:PoolerHost
        } | Should -Throw $ExpectedError
    }

    It 'explains how to adapt the Supabase-provided URL scheme' {
        {
            Assert-EPSupabaseUrl `
                -Value 'postgresql://postgres.abcdefghijklmnopqrst:password@aws-0-us-west-1.pooler.supabase.com:5432/postgres?ssl=require' `
                -Driver asyncpg -ProjectRef $script:ProjectRef -PoolerHost $script:PoolerHost -Context 'staging Supabase async session-pooler URL'
        } | Should -Throw '*staging Supabase async*replace only that prefix*postgresql+asyncpg://*'
    }
}

Describe 'Resend DNS record conversion' {
    It 'omits priority when the property is absent' {
        $record = [pscustomobject]@{ type='TXT'; name='send.example.test'; value='v=spf1 include:amazonses.com ~all' }
        $body = ConvertTo-EPCloudflareDnsRecordBody -Type $record.type -Name $record.name -Content $record.value -SourceRecord $record
        $body.ContainsKey('priority') | Should -BeFalse
    }

    It 'omits priority when the property is null' {
        $record = [pscustomobject]@{ type='TXT'; name='resend._domainkey.example.test'; value='p=key'; priority=$null }
        $body = ConvertTo-EPCloudflareDnsRecordBody -Type $record.type -Name $record.name -Content $record.value -SourceRecord $record
        $body.ContainsKey('priority') | Should -BeFalse
    }

    It 'includes a numeric MX priority' {
        $record = [pscustomobject]@{ type='MX'; name='send.example.test'; value='feedback-smtp.us-east-1.amazonses.com'; priority=10 }
        $body = ConvertTo-EPCloudflareDnsRecordBody -Type $record.type -Name $record.name -Content $record.value -SourceRecord $record
        $body.priority | Should -Be 10
        $body.priority | Should -BeOfType ([int])
    }

    It 'includes a string-form MX priority' {
        $record = [pscustomobject]@{ type='MX'; name='send.example.test'; value='feedback-smtp.us-east-1.amazonses.com'; priority='20' }
        $body = ConvertTo-EPCloudflareDnsRecordBody -Type $record.type -Name $record.name -Content $record.value -SourceRecord $record
        $body.priority | Should -Be 20
        $body.priority | Should -BeOfType ([int])
    }

    It 'preserves priority zero' {
        $record = [pscustomobject]@{ type='MX'; name='send.example.test'; value='feedback-smtp.us-east-1.amazonses.com'; priority=0 }
        $body = ConvertTo-EPCloudflareDnsRecordBody -Type $record.type -Name $record.name -Content $record.value -SourceRecord $record
        $body.ContainsKey('priority') | Should -BeTrue
        $body.priority | Should -Be 0
    }

    It 'rejects malformed and out-of-range priorities' -TestCases @(
        @{ Priority='ten' }
        @{ Priority='1.5' }
        @{ Priority='-1' }
        @{ Priority='65536' }
    ) {
        param($Priority)
        $record = [pscustomobject]@{ type='MX'; name='send.example.test'; value='feedback-smtp.us-east-1.amazonses.com'; priority=$Priority }
        {
            ConvertTo-EPCloudflareDnsRecordBody -Type $record.type -Name $record.name -Content $record.value -SourceRecord $record
        } | Should -Throw '*integer from 0 through 65535*'
    }
}

Describe 'Cloudflare DNS idempotency errors' {
    It 'recognizes only the explicit identical-record error code' {
        $payload = '{"result":null,"success":false,"errors":[{"code":81058,"message":"An identical record already exists."}],"messages":[]}'
        Test-EPCloudflareApiErrorCode -Payload $payload -Code 81058 | Should -BeTrue
        Test-EPCloudflareApiErrorCode -Payload $payload -Code 81057 | Should -BeFalse
    }

    It 'rejects other Cloudflare errors even when their message mentions an identical record' {
        $payload = '{"success":false,"errors":[{"code":10003,"message":"An identical record already exists."}]}'
        Test-EPCloudflareApiErrorCode -Payload $payload -Code 81058 | Should -BeFalse
    }

    It 'rejects empty, malformed, and code-less responses' -TestCases @(
        @{ Payload='' }
        @{ Payload='not-json' }
        @{ Payload='{}' }
        @{ Payload='{"success":false,"errors":[{"message":"failed"}]}' }
    ) {
        param($Payload)
        Test-EPCloudflareApiErrorCode -Payload $Payload -Code 81058 | Should -BeFalse
    }
}

Describe 'Secret handling' {
    It 'creates unique cryptographic URL-safe secrets' {
        $first = New-EPRandomSecret
        $second = New-EPRandomSecret
        $first | Should -Not -Be $second
        $first | Should -Match '^[A-Za-z0-9_-]+$'
        $first.Length | Should -BeGreaterThan 50
    }

    It 'redacts registered secrets and PostgreSQL passwords' {
        Add-EPRedaction 'very-sensitive-value'
        $safe = Protect-EPText 'token=very-sensitive-value db=postgresql://user:pass@host/db'
        $safe | Should -Not -Match 'very-sensitive-value|:pass@'
        $safe | Should -Match '\[REDACTED\]'
    }

    It 'does not execute a command in WhatIf mode' {
        $marker = Join-Path $TestDrive 'must-not-exist'
        $result = Invoke-EPCommand -FilePath 'pwsh' -ArgumentList @('-Command',"New-Item -ItemType File -Path '$marker'") -WhatIf
        $result.Skipped | Should -BeTrue
        $marker | Should -Not -Exist
    }

    It 'resolves a bare Windows batch command so percent-tilde-dp0 points to its installation directory' {
        $commandDirectory = Join-Path $TestDrive 'command-bin'
        $workingDirectory = Join-Path $TestDrive 'unrelated-working-directory'
        [IO.Directory]::CreateDirectory($commandDirectory) | Out-Null
        [IO.Directory]::CreateDirectory($workingDirectory) | Out-Null
        [IO.File]::WriteAllText((Join-Path $commandDirectory 'sibling.txt'), 'present')
        [IO.File]::WriteAllText(
            (Join-Path $commandDirectory 'ep-path-regression.cmd'),
            "@echo off`r`nif exist `"%~dp0sibling.txt`" (echo resolved) else (echo unresolved 1>&2 & exit /b 9)`r`n"
        )
        $originalPath = $env:Path
        try {
            $env:Path = "$commandDirectory;$originalPath"
            $result = Invoke-EPCommand -FilePath 'ep-path-regression.cmd' -WorkingDirectory $workingDirectory
            $result.ExitCode | Should -Be 0
            $result.StdOut.Trim() | Should -Be 'resolved'
        } finally {
            $env:Path = $originalPath
        }
    }

    It 'fails clearly when an executable cannot be resolved' {
        { Invoke-EPCommand -FilePath "missing-$([guid]::NewGuid().ToString('N')).exe" } | Should -Throw '*Executable not found*'
    }

    It 'logs bounded redacted stderr for a failed silent command' {
        $secret = 'stderr-secret-value'
        Add-EPRedaction $secret
        $captured = (& {
            $result = Invoke-EPCommand -FilePath 'cmd.exe' -ArgumentList @('/d','/c',"(echo $secret 1>&2) & (for /L %i in (1,1,5000) do @<nul set /p =x 1>&2) & exit /b 9") -AllowFailure -NoLogOutput
            $result.ExitCode | Should -Be 9
        } 6>&1 | Out-String)
        $captured | Should -Not -Match ([regex]::Escape($secret))
        $captured | Should -Match '\[REDACTED\]'
        $captured | Should -Match 'diagnostic truncated'
        $captured.Length | Should -BeLessThan 5000
    }

    It 'suppresses successful sensitive output when NoLogOutput is set' {
        $secret = 'successful-sensitive-output'
        Add-EPRedaction $secret
        $captured = (& {
            $result = Invoke-EPCommand -FilePath 'cmd.exe' -ArgumentList @('/d','/c',"echo $secret") -NoLogOutput
            $result.ExitCode | Should -Be 0
        } 6>&1 | Out-String)
        $captured | Should -Not -Match ([regex]::Escape($secret))
    }

    It 'returns and redacts a securely prompted value' {
        Mock Read-Host -ModuleName ElderPath.Deployment {
            $secureValue = [System.Security.SecureString]::new()
            foreach ($character in 'prompted-secret-value'.ToCharArray()) { $secureValue.AppendChar($character) }
            $secureValue.MakeReadOnly()
            $secureValue
        }
        $value = Read-EPSecureValue -Prompt 'Test secret'
        $value | Should -Be 'prompted-secret-value'
        Protect-EPText "value=$value" | Should -Be 'value=[REDACTED]'
    }

    It 'rejects an empty securely prompted value' {
        Mock Read-Host -ModuleName ElderPath.Deployment {
            [System.Security.SecureString]::new()
        }
        { Read-EPSecureValue -Prompt 'Test secret' } | Should -Throw '*cannot be empty*'
    }
}

Describe 'Interactive deployment secret assignment' {
    BeforeAll {
        $script:DeploymentSource = Get-Content (Join-Path $script:Root 'Deploy-ElderPath.ps1') -Raw
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $script:DeploymentSource,
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors.Count) { throw "Deploy-ElderPath.ps1 did not parse: $($errors[0].Message)" }
        $script:SensitiveFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SensitiveValue' },
            $true
        ).Extent.Text
    }

    It 'assigns both prompted and generated real values before caching them' {
        $script:SensitiveFunction | Should -Match '\$value\s*=\s*if\s*\(\$Generate\)\s*\{\s*New-EPRandomSecret\s*\}\s*else\s*\{\s*Read-EPSecureValue\s+-Prompt\s+\$Prompt\s*\}'
        $script:SensitiveFunction | Should -Match 'Add-EPRedaction\s+\$value'
        $script:SensitiveFunction | Should -Match '\$script:Sensitive\[\$Name\]\s*=\s*\$value'
        $script:SensitiveFunction | Should -Match 'return\s+\$value'
    }

    It 'preserves the noninteractive failure boundary' {
        $script:SensitiveFunction | Should -Match 'if\s*\(\$NonInteractive\)\s*\{\s*throw\s+"Secret.*required interactively'
    }

    It 'requests one database password per environment and derives the URLs' {
        $script:DeploymentSource | Should -Match 'SUPABASE_\$\{Tier\}_DATABASE_PASSWORD'
        $script:DeploymentSource | Should -Match 'Supabase database password'
        $script:DeploymentSource | Should -Match 'ConvertTo-EPSupabaseConnectionUrlSet'
        $script:DeploymentSource | Should -Not -Match 'Supabase async Session pooler URL \(port 5432'
    }
}

Describe 'Database-only secret repair' {
    BeforeAll {
        $script:DeploymentSource = Get-Content (Join-Path $script:Root 'Deploy-ElderPath.ps1') -Raw
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:DeploymentSource,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw "Deploy-ElderPath.ps1 did not parse: $($errors[0].Message)" }
        $script:SetDatabaseSecretsFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-SupabaseDatabaseSecretUpdate' },
            $true
        ).Extent.Text
        $script:DatabasePreflightFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-SupabaseDatabaseConnection' },
            $true
        ).Extent.Text
        $script:LatestDatabaseSecretsFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-LatestSupabaseDatabaseSecret' },
            $true
        ).Extent.Text
    }

    It 'performs both connection probes before uploading exactly four database secrets' {
        $firstProbe = $script:SetDatabaseSecretsFunction.IndexOf('-Probe')
        $firstUpload = $script:SetDatabaseSecretsFunction.IndexOf('-Publish')
        $firstProbe | Should -BeGreaterOrEqual 0
        $firstUpload | Should -BeGreaterThan $firstProbe
        $script:SetDatabaseSecretsFunction | Should -Match 'Invoke-EPValidatedSecretPublication'
        $script:SetDatabaseSecretsFunction | Should -Not -Match 'REGISTRY_KEY|ADMIN_KEY|BETTER_AUTH|CLOUDFLARE'
    }

    It 'uploads no secret versions when either connection probe fails' {
        $uploads = [System.Collections.Generic.List[string]]::new()
        $urlSets = @{
            STAGING = [pscustomobject]@{ Async='async-staging'; Sync='sync-staging' }
            PRODUCTION = [pscustomobject]@{ Async='async-production'; Sync='sync-production' }
        }
        {
            Invoke-EPValidatedSecretPublication -UrlSets $urlSets `
                -Probe { param($environmentName,$syncUrl); if (-not $syncUrl) { throw 'missing URL' }; if ($environmentName -eq 'production') { throw 'probe failed' } } `
                -Publish { param($configurationKey,$value); if ($value) { [void]$uploads.Add($configurationKey) } }
        } | Should -Throw '*probe failed*'
        $uploads.Count | Should -Be 0
    }

    It 'uploads exactly four database URL versions after both probes succeed' {
        $uploads = [System.Collections.Generic.List[string]]::new()
        $urlSets = @{
            STAGING = [pscustomobject]@{ Async='async-staging'; Sync='sync-staging' }
            PRODUCTION = [pscustomobject]@{ Async='async-production'; Sync='sync-production' }
        }
        Invoke-EPValidatedSecretPublication -UrlSets $urlSets `
            -Probe { param($environmentName,$syncUrl); if (-not $environmentName -or -not $syncUrl) { throw 'missing probe value' } } `
            -Publish { param($configurationKey,$value); if (-not $value) { throw 'missing URL' }; [void]$uploads.Add("secret-$configurationKey") }
        $uploads.Count | Should -Be 4
        $uploads | Should -Contain 'secret-STAGING_DATABASE_URL_SECRET'
        $uploads | Should -Contain 'secret-STAGING_DATABASE_URL_SYNC_SECRET'
        $uploads | Should -Contain 'secret-PRODUCTION_DATABASE_URL_SECRET'
        $uploads | Should -Contain 'secret-PRODUCTION_DATABASE_URL_SYNC_SECRET'
    }

    It 'passes the password through Docker environment rather than command arguments' {
        $script:DatabasePreflightFunction | Should -Match ([regex]::Escape("@{ PGPASSWORD=`$userInfo[1]; PGSSLMODE='require' }"))
        $script:DatabasePreflightFunction | Should -Match "'run','--rm','-e','PGPASSWORD','-e','PGSSLMODE'"
        $script:DatabasePreflightFunction | Should -Not -Match "'-W'|--password|\$SyncUrl\s*\)\s*-Environment"
    }

    It 'validates both latest secrets and directs stale async URLs to the repair phase' {
        $script:LatestDatabaseSecretsFunction | Should -Match '\$\{tier\}_DATABASE_URL_SECRET'
        $script:LatestDatabaseSecretsFunction | Should -Match '\$\{tier\}_DATABASE_URL_SYNC_SECRET'
        $script:LatestDatabaseSecretsFunction | Should -Match '-Driver asyncpg'
        $script:LatestDatabaseSecretsFunction | Should -Match 'Run -Phase RepairDatabaseSecrets before deploying StateCare'
        {
            Assert-EPSupabaseUrl `
                -Value 'postgresql+asyncpg://postgres.abcdefghijklmnopqrst:password@aws-0-us-west-1.pooler.supabase.com:5432/postgres?sslmode=require' `
                -Driver asyncpg -ProjectRef 'abcdefghijklmnopqrst' -PoolerHost 'aws-0-us-west-1.pooler.supabase.com'
        } | Should -Throw '*must not include sslmode*'
    }

    It 'exposes an explicit repeatable repair phase and preflights every StateCare deployment' {
        $script:DeploymentSource | Should -Match "'RepairDatabaseSecrets'\{Invoke-ValidatePhase;Invoke-RepairDatabaseSecretsPhase\}"
        $script:DeploymentSource | Should -Match 'function Invoke-StateCareDeploy[\s\S]*?Test-LatestSupabaseDatabaseSecret \$EnvironmentName'
        $script:DeploymentSource | Should -Match 'gcp\.database-secrets\.repaired\.v1'
    }
}

Describe 'GitHub Free private-repository deployment' {
    BeforeAll {
        $script:DeploymentSource = Get-Content (Join-Path $script:Root 'Deploy-ElderPath.ps1') -Raw
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:DeploymentSource,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw "Deploy-ElderPath.ps1 did not parse: $($errors[0].Message)" }
        $script:ConfigureCiFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ConfigureCIPhase' },
            $true
        ).Extent.Text
        $script:WorkflowWaitFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-GitHubWorkflowRun' },
            $true
        ).Extent.Text
        $script:ReleaseWaitFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-GitHubReleaseRuns' },
            $true
        ).Extent.Text
        $script:RepositoryReadyFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-RepositoryReady' },
            $true
        ).Extent.Text
        $script:ReleaseTopologyFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ConfigureReleaseTopologyPhase' },
            $true
        ).Extent.Text
        $script:ManualReleaseFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ManualReleasePhase' },
            $true
        ).Extent.Text
        $script:ManualWorkflowGuardFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-ManualReleaseWorkflowsDisabled' },
            $true
        ).Extent.Text
        $script:ManualSelectionFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ManualReleaseSelection' },
            $true
        ).Extent.Text
        $script:TaggedWorkerReleaseFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-TaggedWorkerRelease' },
            $true
        ).Extent.Text
        $script:ReleaseBranchesFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-ReleaseTopologyBranchState' },
            $true
        ).Extent.Text
        $script:RequestedPhaseFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-RequestedPhase' },
            $true
        ).Extent.Text
        $script:StateCareDeployFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-StateCareDeploy' },
            $true
        ).Extent.Text
        $script:DeployStagingFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DeployStagingPhase' },
            $true
        ).Extent.Text
        $script:DeployProductionFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DeployProductionPhase' },
            $true
        ).Extent.Text
        $script:GeocodeCaliforniaFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GeocodeCaliforniaEnvironment' },
            $true
        ).Extent.Text
        $script:GeocodeCaliforniaPhaseFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GeocodeCaliforniaPhase' },
            $true
        ).Extent.Text
        $script:ProvisionPhaseFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ProvisionPhase' },
            $true
        ).Extent.Text
        $script:EnsureGeocodioSecretFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Ensure-GeocodioSecretReady' },
            $true
        ).Extent.Text
        $script:AllPhaseFunction = $ast.Find(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-AllPhase' },
            $true
        ).Extent.Text
    }

    It 'does not call unsupported GitHub environment protection APIs' {
        $script:ConfigureCiFunction | Should -Not -Match '/environments/'
        $script:ConfigureCiFunction | Should -Not -Match 'wait_timer|prevent_self_review|reviewers'
        $script:ConfigureCiFunction | Should -Match "github\.repository-settings"
    }

    It 'binds Google OIDC to the reviewed deployment workflow' {
        $script:ConfigureCiFunction | Should -Match 'assertion\.workflow_ref'
        $script:ConfigureCiFunction | Should -Not -Match 'assertion\.job_workflow_ref'
        $script:ConfigureCiFunction | Should -Match '\.github/workflows/deploy\.yml@'
        $script:ConfigureCiFunction | Should -Match "github\.wif\.workflow-policy"
    }

    It 'fails closed until the unified workflow is merged into origin main' {
        foreach ($marker in @('workflow_run:','branches: [dev, main]','STATECARE_REGISTRY_API_KEY_STAGING','STATECARE_REGISTRY_API_KEY_PRODUCTION','CLOUDFLARE_API_TOKEN_PRODUCTION')) {
            $script:RepositoryReadyFunction | Should -Match ([regex]::Escape($marker))
        }
        $script:RepositoryReadyFunction | Should -Match 'still uses GitHub environments'
    }

    It 'uploads distinct staging and production repository secrets through standard input' {
        foreach ($name in @(
            'CLOUDFLARE_API_TOKEN_STAGING','CLOUDFLARE_API_TOKEN_PRODUCTION',
            'STATECARE_REGISTRY_API_KEY_STAGING','STATECARE_REGISTRY_API_KEY_PRODUCTION'
        )) { $script:ConfigureCiFunction | Should -Match $name }
        $script:ConfigureCiFunction | Should -Match "'secret','set'.*'--repo'.*-InputText"
        $script:ConfigureCiFunction | Should -Not -Match "'secret','set'.*'--env'"
    }

    It 'configures isolated Registry credentials and only the intended Worker secrets' {
        $script:ReleaseTopologyFunction | Should -Match 'STATECARE_REGISTRY_URL_STAGING'
        $script:ReleaseTopologyFunction | Should -Match 'STATECARE_REGISTRY_URL_PRODUCTION'
        $script:ReleaseTopologyFunction | Should -Match 'STATECARE_REGISTRY_API_KEY_STAGING'
        $script:ReleaseTopologyFunction | Should -Match 'STATECARE_REGISTRY_API_KEY_PRODUCTION'
        $script:ReleaseTopologyFunction | Should -Not -Match 'STATECARE_REGISTRY_URL_SHARED|STATECARE_REGISTRY_API_KEY_SHARED'
        $script:ReleaseTopologyFunction | Should -Match "Invoke-Step 'release-topology\.worker-secrets\.v1' \{[\s\S]*Initialize-CloudflareToken"
        $script:ReleaseTopologyFunction | Should -Match "Set-WorkerSecret 'staging' 'BETTER_AUTH_URL'"
        $script:ReleaseTopologyFunction | Should -Match "Set-WorkerSecret 'staging' 'STATECARE_REGISTRY_URL'"
        $script:ReleaseTopologyFunction | Should -Match "Set-WorkerSecret 'staging' 'STATECARE_REGISTRY_API_KEY'"
        $script:ReleaseTopologyFunction | Should -Match "Set-WorkerSecret 'production' 'BETTER_AUTH_URL'"
        $script:ReleaseTopologyFunction | Should -Match "Set-WorkerSecret 'production' 'STATECARE_REGISTRY_URL'"
        $script:ReleaseTopologyFunction | Should -Match "Set-WorkerSecret 'production' 'STATECARE_REGISTRY_API_KEY'"
        $script:ReleaseTopologyFunction | Should -Not -Match 'BETTER_AUTH_SECRET|RESEND_API_KEY|OPENAI_API_KEY'
        $script:ReleaseTopologyFunction | Should -Match "'secret','set','STATECARE_REGISTRY_API_KEY_STAGING'.*-InputText"
        $script:ReleaseTopologyFunction | Should -Match "'secret','set','STATECARE_REGISTRY_API_KEY_PRODUCTION'.*-InputText"
    }

    It 'guards and scopes manual release to one identical main and dev tree' {
        $script:RequestedPhaseFunction | Should -Match "'ManualRelease'\{Invoke-ValidatePhase;Invoke-ManualReleasePhase\}"
        $script:ManualWorkflowGuardFunction | Should -Match "CONFIGURE_GITHUB_CI"
        $script:ManualWorkflowGuardFunction | Should -Match "disabled_manually"
        $script:ManualWorkflowGuardFunction | Should -Match "workflow','view"
        $script:ManualSelectionFunction | Should -Match '\^\{tree\}'
        $script:ManualSelectionFunction | Should -Match "origin/dev and origin/main do not have identical Git trees"
        $script:ManualReleaseFunction | Should -Match 'Initialize-ReviewedWorktree'
        $script:ManualReleaseFunction | Should -Match 'manual\.registry-preflight'
        $script:ManualReleaseFunction | Should -Match 'manual\.production-bookmark'
        $script:ManualReleaseFunction | Should -Match 'Invoke-TaggedWorkerRelease ''staging'''
        $script:ManualReleaseFunction | Should -Match 'Invoke-TaggedWorkerRelease ''production'''
    }

    It 'tags both Worker releases and verifies the active version metadata' {
        $script:TaggedWorkerReleaseFunction | Should -Match "'--tag'"
        $script:TaggedWorkerReleaseFunction | Should -Match "'--message'"
        $script:TaggedWorkerReleaseFunction | Should -Match "'versions','list'"
        $script:TaggedWorkerReleaseFunction | Should -Match "'deployments','status'"
        $script:TaggedWorkerReleaseFunction | Should -Match 'Test-WorkerRegistryDiagnostics'
        $script:TaggedWorkerReleaseFunction | Should -Not -Match 'BETTER_AUTH_SECRET|RESEND_API_KEY|OPENAI_API_KEY'
    }

    It 'requires an ancestor dev branch and exact confirmation before one-time synchronization' {
        $script:ReleaseBranchesFunction | Should -Match "merge-base','--is-ancestor"
        $script:ReleaseTopologyFunction | Should -Match "Request-EPTypedConfirmation 'FAST FORWARD DEV TO MAIN'"
        $script:ReleaseTopologyFunction | Should -Match "refs/heads/\$\(Get-Cfg 'GITHUB_STAGING_BRANCH'\)"
    }

    It 'keeps WhatIf non-mutating and previews the dev and production monitors' {
        $script:ReleaseTopologyFunction | Should -Match 'if \(\$script:DryRun\)'
        $script:ReleaseTopologyFunction | Should -Match 'WHATIF monitor dev CI and staging deployment'
        $script:ReleaseTopologyFunction | Should -Match "Wait-GitHubWorkflowRun -Workflow 'Deploy'.*GITHUB_STAGING_BRANCH"
        $script:ReleaseTopologyFunction | Should -Match "Wait-GitHubWorkflowRun -Workflow 'Deploy'.*GITHUB_DEFAULT_BRANCH"
        $script:WorkflowWaitFunction | Should -Match 'if\(\$EventName-ne''workflow_run''\)'
        $script:WorkflowWaitFunction | Should -Match '\$arguments\+=@\(''--branch'',\$Branch\)'
        $script:WorkflowWaitFunction | Should -Match "conclusion-eq'success'"
        $script:ReleaseTopologyFunction | Should -Not -Match "workflow','run','CI'"
        $script:ReleaseTopologyFunction | Should -Match "Workflow 'CI'.*EventName 'push'.*GITHUB_DEFAULT_BRANCH"
    }

    It 'resumes a paused release topology through its branch-aware phase' {
        $script:RequestedPhaseFunction | Should -Match "'Resume'[\s\S]*PausedAt[\s\S]*ConfigureReleaseTopology"
        $script:RequestedPhaseFunction | Should -Match "ActivePhase\s*=\s*'ConfigureReleaseTopology'"
        $script:RequestedPhaseFunction | Should -Match "Invoke-ConfigureReleaseTopologyPhase"
        $script:RequestedPhaseFunction | Should -Match "else[\s\S]*Invoke-AllPhase"
        $script:DeploymentSource | Should -Match 'catch \{[\s\S]*PausedAt=\$script:ActivePhase'
    }

    It 'runs statewide Geocodio once per environment and later Nominatim deltas only on the explicit phase' {
        $script:RequestedPhaseFunction | Should -Match "'GeocodeCalifornia'\{Invoke-ValidatePhase;Invoke-GeocodeCaliforniaPhase\}"
        $script:RequestedPhaseFunction | Should -Match "PausedAt -eq 'GeocodeCalifornia'"
        $script:StateCareDeployFunction | Should -Not -Match "'jobs','execute'"
        $script:StateCareDeployFunction | Should -Match 'Ensure-GeocodioSecretReady \$EnvironmentName'
        $script:StateCareDeployFunction | Should -Match 'Assert-StateCareRequiredJobsPresent \$EnvironmentName'
        $script:GeocodeCaliforniaFunction | Should -Match 'Assert-StateCareGeocodeJobsReady \$EnvironmentName'
        $script:GeocodeCaliforniaFunction | Should -Match 'geocode-california-initial'
        $script:GeocodeCaliforniaFunction | Should -Match 'geocode-california-delta'
        $script:GeocodeCaliforniaFunction | Should -Not -Match 'GEOCODIO_API_KEY='
        $script:GeocodeCaliforniaPhaseFunction | Should -Match 'statecare\.california-geocode\.\$environmentName\.v1'
        $script:AllPhaseFunction | Should -Match 'Invoke-DeployProductionPhase[\s\S]*Invoke-GeocodeCaliforniaPhase'
        $script:EnsureGeocodioSecretFunction | Should -Match 'Get-SensitiveValue -Name \$configurationKey -Prompt'
        $script:EnsureGeocodioSecretFunction | Should -Match 'Ensure-GcpSecret -Name \$secretName -InitialValue \$value'
        $script:EnsureGeocodioSecretFunction | Should -Match 'Ensure-GeocodioSecretAccessor \$secretName'
        $script:ProvisionPhaseFunction | Should -Match "foreach \(\`$environmentName in @\('staging','production'\)\) \{[\s\S]*Ensure-GeocodioSecretReady"
        $script:DeploymentSource | Should -Not -Match 'add the secret manually before deploying StateCare'
        $script:DeploymentSource | Should -Match 'STAGING_GEOCODIO_API_KEY_SECRET'
        $script:DeploymentSource | Should -Match 'Read-EPSecureValue'
    }

    It 'redeploys StateCare when California Cloud Run jobs are missing despite completed checkpoints' {
        $script:DeployStagingFunction | Should -Match 'Invoke-StateCareDeployStep ''staging'' ''deploy\.statecare\.staging'''
        $script:DeployProductionFunction | Should -Match 'Get-MissingStateCareRequiredJobs ''production'''
        $script:DeployProductionFunction | Should -Match 'Redeploying StateCare only'
        $script:DeploymentSource | Should -Match 'geocode-california-initial'
        $script:DeploymentSource | Should -Match 'function Get-MissingStateCareRequiredJobs'
        $script:DeploymentSource | Should -Match '\[System\.Collections\.Generic\.List\[string\]\]'
        $script:DeploymentSource | Should -Match 'return \[string\[\]\]'
        $script:DeploymentSource | Should -Match '@\(Get-MissingStateCareRequiredJobs'
        $script:DeploymentSource | Should -Match 'function Invoke-StateCareDeployStep'
    }

    It 'clears the pause and records the activated release SHA after production verification' {
        $script:ReleaseTopologyFunction | Should -Match "Test-WorkerDeployment 'production'[\s\S]*Resources\['ReleaseSha'\]\s*="
        $script:ReleaseTopologyFunction | Should -Match 'PausedAt\s*=\s*\$null[\s\S]*release-topology\.release\.\$mainSha'
    }
}

Describe 'Artifact Registry cleanup policy' {
    It 'generates the exact array schema accepted by Google Cloud' {
        $json = ConvertTo-EPArtifactCleanupPolicyJson -KeepCount 3 -RetentionDays 7
        Assert-EPArtifactCleanupPolicyJson -Json $json | Should -BeTrue

        $policies = ConvertFrom-Json $json
        $policies.GetType().IsArray | Should -BeTrue
        $policies.Count | Should -Be 2
        $policies[0].name | Should -Be 'delete-old'
        $policies[0].action.type | Should -Be 'Delete'
        $policies[0].condition.olderThan | Should -Be '7d'
        $policies[1].name | Should -Be 'keep-recent'
        $policies[1].action.type | Should -Be 'Keep'
        $policies[1].mostRecentVersions.keepCount | Should -Be 3
    }

    It 'rejects an object root and duplicate policy names' {
        { Assert-EPArtifactCleanupPolicyJson -Json '{"delete-old":{"action":"DELETE"}}' } |
            Should -Throw '*root must be a JSON array*'

        $duplicate = '[{"name":"delete-old","action":{"type":"Delete"},"condition":{"olderThan":"7d"}},{"name":"delete-old","action":{"type":"Keep"},"mostRecentVersions":{"keepCount":3}}]'
        { Assert-EPArtifactCleanupPolicyJson -Json $duplicate } | Should -Throw '*must be unique*'
    }

    It 'rejects invalid actions and nonpositive retention values' {
        $invalidAction = '[{"name":"delete-old","action":{"type":"DELETE"},"condition":{"olderThan":"7d"}},{"name":"keep-recent","action":{"type":"Keep"},"mostRecentVersions":{"keepCount":3}}]'
        { Assert-EPArtifactCleanupPolicyJson -Json $invalidAction } | Should -Throw '*unsupported action type*'

        $invalidRetention = '[{"name":"delete-old","action":{"type":"Delete"},"condition":{"olderThan":"0d"}},{"name":"keep-recent","action":{"type":"Keep"},"mostRecentVersions":{"keepCount":0}}]'
        { Assert-EPArtifactCleanupPolicyJson -Json $invalidRetention } | Should -Throw '*positive condition.olderThan*'
    }

    It 'does not write the policy file in WhatIf mode' {
        $source = Get-Content (Join-Path $script:Root 'Deploy-ElderPath.ps1') -Raw
        $source | Should -Match 'if \(-not \$script:DryRun\)'
        $source | Should -Match 'Assert-EPArtifactCleanupPolicyJson'
        $source | Should -Match 'set-cleanup-policies'
    }
}

Describe 'PowerShell 7 bootstrap relaunch' {
    BeforeAll {
        function New-FakePowerShellCommand {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$Body
            )
            [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
            [IO.File]::WriteAllText($Path, "@echo off`r`n$Body`r`n")
            return $Path
        }
    }

    It 'accepts a working version 7 Microsoft Store-style alias path' {
        $candidate = New-FakePowerShellCommand -Path (Join-Path $TestDrive 'Microsoft\WindowsApps\pwsh.cmd') -Body 'echo 7'
        $status = @(Get-EPPowerShellExecutableStatus -Candidates $candidate)
        $status.Count | Should -Be 1
        $status[0].Path | Should -Be (Resolve-Path $candidate).Path
        $status[0].MajorVersion | Should -Be 7
        $status[0].Compatible | Should -BeTrue
    }

    It 'accepts a working version 7 MSI-style installation path' {
        $candidate = New-FakePowerShellCommand -Path (Join-Path $TestDrive 'Program Files\PowerShell\7\pwsh.cmd') -Body 'echo 7'
        $status = @(Get-EPPowerShellExecutableStatus -Candidates $candidate)
        $status[0].Launchable | Should -BeTrue
        $status[0].Compatible | Should -BeTrue
    }

    It 'reports a missing candidate separately' {
        $candidate = Join-Path $TestDrive 'missing\pwsh.exe'
        $status = @(Get-EPPowerShellExecutableStatus -Candidates $candidate)
        $status[0].Exists | Should -BeFalse
        $status[0].Error | Should -Be 'not_found'
    }

    It 'reports a broken candidate separately' {
        $candidate = New-FakePowerShellCommand -Path (Join-Path $TestDrive 'broken\pwsh.cmd') -Body 'exit /b 3'
        $status = @(Get-EPPowerShellExecutableStatus -Candidates $candidate)
        $status[0].Exists | Should -BeTrue
        $status[0].Launchable | Should -BeFalse
        $status[0].Error | Should -Be 'exit_3'
    }

    It 'rejects a working executable below version 7' {
        $candidate = New-FakePowerShellCommand -Path (Join-Path $TestDrive 'old\pwsh.cmd') -Body 'echo 5'
        $status = @(Get-EPPowerShellExecutableStatus -Candidates $candidate)
        $status[0].Launchable | Should -BeTrue
        $status[0].MajorVersion | Should -Be 5
        $status[0].Compatible | Should -BeFalse
    }

    It 'preserves the configuration and all bootstrap switches' {
        $scriptPath = 'C:\Scripts\Git\elderpath-deployment\bootstrap.ps1'
        $configurationPath = 'C:\Scripts\Git\elderpath-deployment\config\custom.env'
        $arguments = @(Get-EPBootstrapRelaunchArguments -ScriptPath $scriptPath -ConfigurationPath $configurationPath `
            -SkipDockerWait -SkipNpmInstall -WhatIf)
        $arguments | Should -Be @(
            '-NoProfile','-File',$scriptPath,'-ConfigurationPath',$configurationPath,
            '-SkipDockerWait','-SkipNpmInstall','-WhatIf'
        )
    }

    It 'keeps Microsoft Store and MSI candidates in default discovery' {
        $source = Get-Content (Join-Path $script:Root 'lib\ElderPath.Deployment.psm1') -Raw
        $source | Should -Match 'Microsoft\\WindowsApps\\pwsh\.exe'
        $source | Should -Match 'ProgramW6432'
        $source | Should -Match 'PowerShell\\7\\pwsh\.exe'
    }
}

Describe 'Checkpoint recovery' {
    It 'writes, reloads, and idempotently completes a checkpoint' {
        $root = Join-Path $TestDrive 'deployment'
        $state = Get-EPCheckpoint $root
        Set-EPCheckpointComplete -Root $root -State $state -Name 'gcp.project'
        Set-EPCheckpointComplete -Root $root -State $state -Name 'gcp.project'
        $reloaded = Get-EPCheckpoint $root
        @($reloaded.Completed).Count | Should -Be 1
        Test-EPCheckpointComplete $reloaded 'gcp.project' | Should -BeTrue
    }
}

Describe 'SHA-scoped release recovery' {
    It 'creates distinct checkpoints for distinct release commits' {
        $first = Get-EPReleaseCheckpointName -Category 'GitHub Run.Deploy.workflow_dispatch' -CommitSha ('a' * 40)
        $second = Get-EPReleaseCheckpointName -Category 'GitHub Run.Deploy.workflow_dispatch' -CommitSha ('b' * 40)
        $first | Should -Be "github-run.deploy.workflow-dispatch.$('a' * 40)"
        $second | Should -Not -Be $first
    }

    It 'rejects abbreviated or malformed release commits' {
        { Get-EPReleaseCheckpointName -Category 'github.run.ci.push' -CommitSha '0eb0de7' } |
            Should -Throw '*full 40-character Git SHA*'
    }

    It 'resolves the current main release and verifies the bindings merge ancestry' {
        $source = Get-Content (Join-Path $script:Root 'Deploy-ElderPath.ps1') -Raw
        $source | Should -Match "merge-base','--is-ancestor'"
        $source | Should -Match 'Bindings merge \$mergeSha is no longer an ancestor'
        $source | Should -Match 'rev-parse'',\$remoteRef'
        $source | Should -Match 'Resources\[''ReleaseSha''\]=\$releaseSha'
        $source | Should -Match 'Wait-GitHubReleaseRuns \$releaseSha'
        $source | Should -Match 'Get-EPReleaseCheckpointName -Category "github\.run\.'
        $source | Should -Match 'github\.production\.dispatched''.*-CommitSha \$CommitSha'
        $source | Should -Match 'origin/\$defaultBranch advanced from release'
    }
}

Describe 'Guarded accidental R2 cleanup' {
    BeforeEach {
        $script:deletedBucket = $null
        $script:confirmedBucket = $null
        $script:probeCalls = 0
    }

    It 'deletes one exact bucket only after empty and unbound probes succeed' {
        $result = Invoke-EPR2BucketCleanup -BucketName 'elderpath-media' `
            -GetObjectList { param($name) $null=$name; $script:probeCalls++; [pscustomobject]@{success=$true;result=@();result_info=[pscustomobject]@{is_truncated=$false}} } `
            -GetWorkerSettings { $script:probeCalls++; @([pscustomobject]@{ScriptName='elderpath-staging';Response=[pscustomobject]@{success=$true;result=[pscustomobject]@{bindings=@([pscustomobject]@{type='r2_bucket';bucket_name='elderpath-media-staging'})}}}) } `
            -ConfirmDeletion { param($name) $script:confirmedBucket=$name } `
            -DeleteBucket { param($name) $script:deletedBucket=$name }
        $result.Deleted | Should -BeTrue
        $script:probeCalls | Should -Be 2
        $script:confirmedBucket | Should -Be 'elderpath-media'
        $script:deletedBucket | Should -Be 'elderpath-media'
    }

    It 'refuses to delete a nonempty bucket' {
        {
            Invoke-EPR2BucketCleanup -BucketName 'elderpath-media' `
                -GetObjectList { [pscustomobject]@{success=$true;result=@([pscustomobject]@{key='unexpected'})} } `
                -GetWorkerSettings { throw 'must not run' } -ConfirmDeletion {} `
                -DeleteBucket { $script:deletedBucket='called' }
        } | Should -Throw '*is not empty*'
        $script:deletedBucket | Should -BeNullOrEmpty
    }

    It 'refuses to delete a bucket still bound to any Worker' {
        {
            Invoke-EPR2BucketCleanup -BucketName 'elderpath-media' `
                -GetObjectList { [pscustomobject]@{success=$true;result=@()} } `
                -GetWorkerSettings { @([pscustomobject]@{ScriptName='elderpath';Response=[pscustomobject]@{success=$true;result=[pscustomobject]@{bindings=@([pscustomobject]@{type='r2_bucket';bucket_name='elderpath-media'})}}}) } `
                -ConfirmDeletion {} -DeleteBucket { $script:deletedBucket='called' }
        } | Should -Throw "*still bound to Worker 'elderpath'*"
        $script:deletedBucket | Should -BeNullOrEmpty
    }

    It 'fails closed when Worker settings cannot be read' {
        {
            Invoke-EPR2BucketCleanup -BucketName 'elderpath-media' `
                -GetObjectList { [pscustomobject]@{success=$true;result=@()} } `
                -GetWorkerSettings { throw 'HTTP 403' } -ConfirmDeletion {} `
                -DeleteBucket { $script:deletedBucket='called' }
        } | Should -Throw '*HTTP 403*'
        $script:deletedBucket | Should -BeNullOrEmpty
    }

    It 'performs no probes, confirmation, or deletion in WhatIf mode' {
        $result = Invoke-EPR2BucketCleanup -BucketName 'elderpath-media' `
            -GetObjectList { $script:probeCalls++ } -GetWorkerSettings { $script:probeCalls++ } `
            -ConfirmDeletion { $script:confirmedBucket='called' } `
            -DeleteBucket { $script:deletedBucket='called' } -DryRun
        $result.Skipped | Should -BeTrue
        $script:probeCalls | Should -Be 0
        $script:confirmedBucket | Should -BeNullOrEmpty
        $script:deletedBucket | Should -BeNullOrEmpty
    }

    It 'hard-codes the intended bucket and exact typed confirmation in the explicit phase' {
        $source = Get-Content (Join-Path $script:Root 'Deploy-ElderPath.ps1') -Raw
        $source | Should -Match "\$bucketName='elderpath-media'"
        $source | Should -Match 'DELETE UNUSED R2 \$name'
        $source | Should -Match "'CleanupAccidentalR2'\{Invoke-ValidatePhase;Invoke-CleanupAccidentalR2Phase\}"
    }
}

Describe 'Static mutation safety' {
    It 'keeps runtime state and local configuration ignored' {
        $ignore = Get-Content (Join-Path $script:Root '.gitignore') -Raw
        foreach ($entry in @('config/deployment.env','state/','logs/','backups/','*.secret')) { $ignore | Should -Match ([regex]::Escape($entry)) }
    }

    It 'never accepts raw cloud credentials as script parameters' {
        $source = Get-Content (Join-Path $script:Root 'Deploy-ElderPath.ps1') -Raw
        $source | Should -Not -Match 'param\([^)]*(ApiKey|Password|Token)'
        $source | Should -Match "Read-EPSecureValue"
    }

    It 'uses standard input for remote secret uploads' {
        $source = Get-Content (Join-Path $script:Root 'Deploy-ElderPath.ps1') -Raw
        $source | Should -Match "--data-file=-"
        $source | Should -Match "secret','set'"
        $source | Should -Match "secret','put'"
    }

    It 'models typed dry-run secrets and derived cloud outputs without skipping validation' {
        $source = Get-Content (Join-Path $script:Root 'Deploy-ElderPath.ps1') -Raw
        $source | Should -Match 'ConvertTo-EPSupabaseConnectionUrlSet'
        $source | Should -Match '\[AllowEmptyString\(\)\]\[string\]\$Prompt'
        $source | Should -Match '\[DRY-RUN-GCP-SECRET:'
        $source | Should -Match '000000000000'
        $source | Should -Match 'run\.invalid'
        $source | Should -Not -Match 'if\s*\(\$script:DryRun\)\s*\{\s*return\s*\}\s*\r?\n\s*if\s*\(\$NonInteractive\)'
    }

    It 'contains provider boundaries without contacting live services' {
        $source = Get-Content (Join-Path $script:Root 'Deploy-ElderPath.ps1') -Raw
        foreach ($provider in @('gcloud','gh.exe','wrangler','api.resend.com','api.cloudflare.com','supabase')) { $source | Should -Match ([regex]::Escape($provider)) }
    }
}

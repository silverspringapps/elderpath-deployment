# ElderPath deployment automation

This Windows-only toolkit provisions and deploys ElderPath's production topology:

- Cloudflare Workers, D1, and R2 for the web application.
- Google Cloud Run services/jobs for StateCare.
- Two Supabase PostgreSQL/PostGIS projects, initially on the Free plan.
- Google Secret Manager, workflow-bound GitHub OIDC, repository deployment settings, Resend DNS, readiness checks, and off-site logical backups.

It deliberately cannot create vendor accounts, accept terms, create Supabase projects, activate Google billing, buy a domain, finish interactive logins, click verification emails, or merge a pull request. It pauses at those trust boundaries. It never stores a database URL, API token, password, generated application secret, or OAuth secret in `deployment.env`, logs, checkpoints, Git, or command arguments.

## Honest Free-plan guidance

This architecture can launch with Supabase Free. It is appropriate for an MVP with bounded California imports, one-time Geocodio statewide geocoding, and small, manually invoked Nominatim deltas. It is not a zero-risk production database: Free projects can be paused, have tighter quotas, and do not provide the same backup/recovery guarantees as a paid project. The automation warns at 350 MB, blocks a production promotion at 400 MB by default, and creates off-site logical dumps. Upgrade production to Supabase Pro before ElderPath depends on uninterrupted availability or managed point-in-time recovery.

Google Cloud requires a billing account even when usage remains inside free allowances. Cloudflare, Resend, domain registration, AI calls, Artifact Registry storage, outbound traffic, and Cloud Run/Scheduler usage can also create charges. The script creates a budget alert; a budget is notification, not a hard spending cap.

## 1. Manual setup

Create or verify these items first:

1. A Cloudflare account with `example.com` as an active zone. Replace the example domain with yours.
2. Two different Supabase projects: one staging, one production. In each project, enable `postgis` and `pg_trgm` from **Database → Extensions**. Do not expose registry tables through browser Supabase clients.
3. A Google Cloud account and billing account. You may let the script create the named project, but billing activation and terms are manual.
4. The private GitHub repository under the configured owner. The Free-compatible workflow uses repository secrets, deploys `dev` automatically to staging, and deploys an identical staged tree from `main` automatically to production; it does not use paid GitHub environment protections.
5. A Resend account and API key. The sending subdomain must be under the Cloudflare zone.
6. An OpenAI API key. Google OAuth is optional.

The application deployment changes must be reviewed and merged into `origin/main`. The toolkit refuses to release a StateCare script or workflow that is absent from that branch. Your current ElderPath worktree may remain dirty: builds and deployments use a separate detached worktree and never reset, clean, switch, or commit it.

## 2. Install and copy configuration

Open Windows PowerShell or PowerShell 7 as your normal user. When started from Windows PowerShell 5.1, bootstrap validates the installed PowerShell 7 executable and relaunches itself automatically:

```powershell
Set-Location C:\Scripts\Git\elderpath-deployment
.\bootstrap.ps1

Copy-Item `
  C:\Scripts\Git\elderpath-deployment\config\deployment.env.example `
  C:\Scripts\Git\elderpath-deployment\config\deployment.env
```

`bootstrap.ps1` requires Winget. It installs only missing PowerShell 7, Git for Windows, Node.js 22, Docker Desktop, Google Cloud CLI, GitHub CLI, and Pester. It runs `npm ci`, starts Docker Desktop hidden when necessary, and runs the offline deployment tests. Existing acceptable tools are not upgraded.

After installation, open a new PowerShell 7 terminal and authenticate interactively:

```powershell
gcloud auth login
gcloud auth application-default login
gh auth login
```

Bootstrap does not authenticate vendor accounts and never stores their credentials. Both Google commands and `gh auth login` are required before `Deploy-ElderPath.ps1 -Phase Validate` can complete.

Do not export a Cloudflare token globally. The deployment script requests it securely only when needed.

## 3. Fill in `config\deployment.env`

Use `C:\Scripts\Git\elderpath-deployment\config\deployment.env`. Every `REQUIRED` value must be replaced. The parser reads literal `KEY=VALUE` lines; it does not evaluate PowerShell or shell expressions.

### Repository and switches

| Variable | What to enter |
|---|---|
| `ELDERPATH_REPO_PATH` | Absolute path to the ElderPath clone. |
| `DEPLOYMENT_ROOT` / `BACKUP_ROOT` | Keep the supplied paths unless you intentionally moved the toolkit or backups. |
| `INSTALL_MISSING_TOOLS` | Reserved policy switch; bootstrap installs missing tools. |
| `RUN_FULL_TEST_GATE` | Keep `true` for releases. Runs format, lint, types, unit, D1 contract/automation, StateCare lint/types/tests, build, production audit, and Playwright. |
| `DEPLOY_STAGING` / `DEPLOY_PRODUCTION` | Enable each deployment tier. Production still requires staging and typed approval. |
| `CREATE_GITHUB_BINDINGS_PR` | Keep `true` so real D1 UUIDs/custom domains enter the reviewed branch via a dedicated PR. |
| `CONFIGURE_GITHUB_CI` | Configures workflow-bound WIF plus free-private repository variables and secrets. |
| `CONFIGURE_WEEKLY_BACKUP_TASK` | Registers a current-user Windows task; the machine and cached cloud/Supabase logins must be available at run time. |

### Domains and operations

Find the zone on **Cloudflare Dashboard → Websites**.

| Variable | Example / location |
|---|---|
| `PRIMARY_DOMAIN` | `elderpath.ai`, already active in Cloudflare. |
| `STAGING_APP_HOST` | `elderpath-staging.elderpath.workers.dev`, using the account's Workers subdomain. |
| `PRODUCTION_APP_HOST` | `elderpath.ai`, the canonical apex origin. |
| `EMAIL_SENDING_DOMAIN` | `mail.elderpath.ai`; Resend DNS is created here. |
| `EMAIL_FROM` | `ElderPath <no-reply@mail.elderpath.ai>`. |
| `OPERATIONS_EMAIL` | Monitored address used in geocoder identity and alerts. |
| `INITIAL_SUPER_ADMIN_EMAIL` | Account you will register and verify after deployment. |
| `USE_CUSTOM_WORKER_DOMAINS` | Keep `true` for the hostnames above. |

### Supabase

Find the project ref in **Project Settings → General**. Find pooler connection strings in **Connect → Session pooler**.

| Variable | What to enter |
|---|---|
| `SUPABASE_REGION` | The region selected when creating both projects. |
| `SUPABASE_STAGING_PROJECT_REF` / `SUPABASE_PRODUCTION_PROJECT_REF` | Different project refs, never URLs or passwords. |
| `SUPABASE_STAGING_POOLER_HOST` / `SUPABASE_PRODUCTION_POOLER_HOST` | Host only from **Connect → Session pooler**, such as `aws-0-us-west-1.pooler.supabase.com`. |
| warning/block bytes | Keep `350000000` and `400000000` initially. |
| `SUPABASE_CLI_VERSION` | Keep the tested pin (`2.114.0`) until intentionally validated. |

During provisioning, enter each project's database password once at the masked prompt. The toolkit derives both required URLs in memory:

- Async API/job URL: `postgresql+asyncpg://postgres.<project-ref>:<encoded-password>@<pooler-host>:5432/postgres?ssl=require`.
- Sync Alembic URL: `postgresql+psycopg://postgres.<project-ref>:<encoded-password>@<pooler-host>:5432/postgres?sslmode=require`.

Passwords are percent-encoded automatically. Both databases must pass a read-only SSL `SELECT 1` before any URL secret is uploaded. The generated URLs go from process memory directly to Google Secret Manager over standard input and are never written locally.

### Google Cloud

Find the billing ID under **Google Cloud Console → Billing → Manage billing accounts**. Use a globally unique lowercase project ID and a Cloud Run region near the Supabase region. Service-account values are account names, not email addresses. Secret variables are remote Secret Manager resource names; keep the defaults unless they collide.

The script enables Cloud Run, Artifact Registry, Cloud Build, Secret Manager, IAM Credentials, STS/WIF, Cloud Scheduler, Billing/Budgets, and Monitoring. It creates a 10 USD alert budget, one Docker repository with cleanup, runtime/deployment identities, and the eight StateCare secrets.

### Cloudflare

Find account/zone IDs on the Cloudflare zone overview. The Workers subdomain is under **Workers & Pages**. The script securely requests:

- Bootstrap token: Account D1 Edit, Account R2 Edit, Workers Scripts Edit, Workers Routes Edit, Zone DNS Edit, and Zone Read, restricted to this account/zone.
- Staging and production CI tokens: create separate narrowly scoped Workers/D1/R2 deployment tokens. They are piped directly to distinct repository secrets and never written locally.

Do not use the Global API Key. D1 and R2 locations should remain `wnam` for this Riverside-focused US deployment.

### GitHub

Keep `GITHUB_DEPLOYMENT_MODE=free-private` for this private GitHub Free repository. The toolkit does not create environment protection rules. It stores non-secret deployment configuration as repository variables and securely uploads these repository secrets through standard input:

- `CLOUDFLARE_API_TOKEN_STAGING`
- `CLOUDFLARE_API_TOKEN_PRODUCTION`
- `STATECARE_REGISTRY_API_KEY_STAGING`
- `STATECARE_REGISTRY_API_KEY_PRODUCTION`

The OIDC provider accepts only `silverspringapps/elderpath` tokens from `refs/heads/main` executing `.github/workflows/deploy.yml`; edit the owner/repository values if the canonical repository changes. A real deployment also verifies that this unified workflow has been merged into `origin/main` before it changes cloud resources.

If an earlier run created an empty `staging` GitHub environment, it is intentionally left unused. The toolkit neither depends on it nor deletes it automatically.

### StateCare, AI, and monitoring

Keep the official California source URL unless the authoritative publisher changes it. Set `NOMINATIM_USER_AGENT` to a real ElderPath identifier with your monitored contact email.

Statewide coordinates use a one-time Geocodio batch (`GEOCODER_PROVIDER=geocodio` only on `geocode-california-initial`). Store API keys in Secret Manager names `STAGING_GEOCODIO_API_KEY_SECRET` and `PRODUCTION_GEOCODIO_API_KEY_SECRET` in `deployment.env`; never put the API key itself in that file, Worker vars, checkpoints, or GitHub Secrets. If the Secret Manager resources are missing, Provision, DeployStaging, DeployProduction, and GeocodeCalifornia securely prompt for each key and upload it. Quality requires accuracy >= 0.8 and rooftop/point/range_interpolation/nearest_rooftop_match. City/county/state centroids are rejected. Coverage must be at least 99% of current California facilities or the run fails closed.

Later license/address deltas use public Nominatim on `geocode-california-delta` only: California scope, 100 rows per run, 4 requests/minute. The API, import, Menifee, and Southern California jobs stay on Nominatim and do not receive the Geocodio secret. StateCare deploy itself applies code and migrations only; it does not execute import or geocode jobs.

`AI_USE_GROQ=false`, fallback/web search off, and the configured OpenAI model are the lowest-complexity launch settings. The OpenAI key is requested securely. If Google OAuth is enabled, its client ID/secret are requested and its exact production callback must also be configured in Google Cloud Console:

```text
https://elderpath.ai/api/auth/callback/google
https://elderpath-staging.elderpath.workers.dev/api/auth/callback/google
```

Two public readiness requests run every eight hours. `READINESS_SCHEDULE` is UTC cron. Backups use local Windows time.

## 4. Validate, dry-run, and deploy

```powershell
Set-Location C:\Scripts\Git\elderpath-deployment

# Configuration/auth/repository checks; no cloud mutation
pwsh .\Deploy-ElderPath.ps1 -Phase Validate

# Print the cloud/repository mutations without performing them
pwsh .\Deploy-ElderPath.ps1 -Phase All -WhatIf

# Provision and begin the staged release
pwsh .\Deploy-ElderPath.ps1 -Phase All
```

`-WhatIf` is noninteractive: it does not request or use real secrets. The toolkit validates
driver-specific, non-routable Supabase placeholders in memory and prints the complete intended
workflow without contacting vendor APIs or writing deployment checkpoints.

Expected secure prompts are the two Supabase database passwords, a narrow local Cloudflare token, separate staging/production CI tokens, Resend/OpenAI keys, staging/production Geocodio keys, and optional Google OAuth values. Separate random Better Auth, registry, and registry-admin keys are generated cryptographically for staging and production.

The first full run creates storage, deploys StateCare staging without executing import/geocode, asks you to type `PREPARE PRODUCTION`, deploys production StateCare the same way, then runs `GeocodeCalifornia`: import plus one-time Geocodio per environment that has not completed `statecare.california-geocode.<env>.v1`. After Worker secrets and the bindings PR, it pauses. Review the exact `wrangler.jsonc` diff and merge it. Resume with:

```powershell
pwsh .\Deploy-ElderPath.ps1 -Phase Resume
```

The resume run confirms the PR is merged and still contained in `origin/main`, records the current
`origin/main` commit as `ReleaseSha`, and uses SHA-scoped CI/deployment checkpoints. It watches CI and
the ordered automatic staging workflow, captures the D1 bookmark and prior Cloud Run/Worker
revisions, then requests the exact phrase `DEPLOY PRODUCTION` before dispatching production. If
`main` advances before dispatch, the release fails closed and a new resume verifies staging for the
new SHA. The production job independently verifies the confirmation, successful CI, and successful
staging deployment for its exact SHA, captures its own D1 bookmark artifact, then deploys StateCare
and the Worker in order. If GitHub CI automation is disabled, the script performs the same
staging-first deployment locally. If a command fails, correct the cause and use `-Phase Resume`;
completed checkpoints are not recreated. Use `-RotateSecrets` only for an intentional rotation.

Individual recovery entry points are also available:

```powershell
pwsh .\Deploy-ElderPath.ps1 -Phase Provision
pwsh .\Deploy-ElderPath.ps1 -Phase RepairDatabaseSecrets
pwsh .\Deploy-ElderPath.ps1 -Phase ConfigureCI
pwsh .\Deploy-ElderPath.ps1 -Phase ConfigureCloudflare
pwsh .\Deploy-ElderPath.ps1 -Phase ConfigureReleaseTopology
pwsh .\Deploy-ElderPath.ps1 -Phase ManualRelease
pwsh .\Deploy-ElderPath.ps1 -Phase DeployStaging
pwsh .\Deploy-ElderPath.ps1 -Phase DeployProduction
pwsh .\Deploy-ElderPath.ps1 -Phase GeocodeCalifornia
pwsh .\Deploy-ElderPath.ps1 -Phase Monitoring
```

`ConfigureReleaseTopology` activates the ongoing branch release model after the reviewed repository
change is merged. It validates that `dev` is an ancestor of `main`, sets the workers.dev/apex GitHub
variables, uploads separate staging and production Registry data keys through standard input, and
keeps each Worker bound to its matching Cloud Run/Supabase Registry. It changes only the auth
origin and Registry secrets for each Worker. It requires
`FAST FORWARD DEV TO MAIN` for the one-time synchronization, waits for dev staging, then runs main CI
so the identical-tree gate can perform the first automatic apex production release. Its `-WhatIf`
mode does not contact providers, change branches, write checkpoints, or prompt for secrets.
If this phase pauses because CI or deployment fails, correct the cause and run `-Phase Resume`.
Resume detects `PausedAt=ConfigureReleaseTopology`, returns directly to this branch-aware phase,
reuses completed topology checkpoints, and records the current release SHA after verification.

`ManualRelease` is the temporary quota-exhaustion path. Set `CONFIGURE_GITHUB_CI=false`, disable the
GitHub `CI` and `Deploy` workflows, complete the application gate locally, and promote an identical
Git tree through `dev` and `main`. The phase fails closed unless both workflows report
`disabled_manually` and both remote branches have the same tree. It then:

1. Checks readiness, freshness, a bounded nearby result, current California record counts, and at
   least 99% coordinate coverage against both environment-specific Registries.
2. Skips StateCare deployment, import, and geocoding when those gates pass.
3. Applies idempotent staging D1 migrations/RBAC, deploys and browser-smokes the exact
   `origin/main` SHA against the staging Registry.
4. Captures a production D1 Time Travel bookmark, applies production D1 migrations/RBAC, and
   deploys/smokes the same SHA against the production Registry.
5. Adds `release-<short-sha>` and the full SHA to each Worker version and verifies the active
   deployment metadata.

Run it with `pwsh .\Deploy-ElderPath.ps1 -Phase ManualRelease`. Keep the workflows disabled until
the Actions quota resets. Then set `CONFIGURE_GITHUB_CI=true`, run `-Phase ConfigureCI`, re-enable
both workflows, and validate one normal identical-tree release.

`GeocodeCalifornia` is the only phase that executes import/geocode jobs. The first run per
environment performs California RCFE import, the Geocodio initial job, and `statecare:verify`.
Later explicit `-Phase GeocodeCalifornia` runs import plus the public-Nominatim California delta
(<=100 pending, 4 req/min). `-Phase All` after a completed initial checkpoint does not re-run
delta. Resume detects `PausedAt=GeocodeCalifornia` and returns to this phase. Dry-run never
stores Geocodio keys in checkpoints.

If an earlier StateCare deploy completed before the California Geocodio jobs existed, rerunning
`-Phase DeployStaging` or `-Phase DeployProduction` recreates the missing Cloud Run jobs even when
the StateCare checkpoint is already complete. After the jobs exist, run `-Phase GeocodeCalifornia`
once; it processes staging and production in one pass.

GitHub Actions `deploy.yml` needs the Secret Manager resource name, not the API key.
ConfigureCI writes repository variables `STATECARE_STAGING_GEOCODIO_API_KEY_SECRET` and
`STATECARE_PRODUCTION_GEOCODIO_API_KEY_SECRET`. The unified production job passes
`GEOCODIO_API_KEY_SECRET` from `STATECARE_PRODUCTION_GEOCODIO_API_KEY_SECRET` when StateCare
source changes. Never put the Geocodio key in GitHub Secrets or Worker vars.

`RepairDatabaseSecrets` is repeatable and database-only. It asks for the staging and production database passwords, derives and validates the four driver-specific Session pooler URLs, tests both databases before uploading, and adds new versions only to the four database URL secrets. If a StateCare deployment finds an invalid or unreachable latest database secret, it stops before building and directs you to this phase. Existing Secret Manager versions remain available for manual rollback.

## 5. First administrator

The script does not create a password or mark an email verified. After production is healthy:

1. Open `https://elderpath.ai/signup`.
2. Register `INITIAL_SUPER_ADMIN_EMAIL`.
3. Open the Resend verification email.
4. Confirm ordinary sign-in works.
5. Run:

```powershell
pwsh .\Deploy-ElderPath.ps1 -Phase PromoteAdmin
```

If an earlier environment-less Vite build created the unintended root R2 bucket `elderpath-media`,
remove it only after the corrected staging and production deployments are healthy:

```powershell
pwsh .\Deploy-ElderPath.ps1 -Phase CleanupAccidentalR2
```

This phase lists one object, reads every Worker's settings, and refuses deletion unless the bucket
is both empty and unbound. It never deletes objects and requires the exact confirmation
`DELETE UNUSED R2 elderpath-media`. Use `-WhatIf` to preview the checks without contacting
Cloudflare.

Type the configured email when prompted. The existing remote D1 promotion command verifies that the identity exists and is verified. Sign out/in, test `/staff`, then create a second verified super administrator so one person is not the only recovery path.

## 6. Backups

Log the Supabase CLI in once if it requests authentication, then run:

```powershell
pwsh .\Backup-StateCare.ps1 -Environment production
```

The script retrieves the sync pooler URL from Secret Manager, exposes only the password through a child-process environment variable, initializes a temporary pinned Supabase CLI workspace, and writes `schema.sql`, `data.sql`, and SHA-256 manifest files under `BACKUP_ROOT\production\<UTC timestamp>`. It applies a current-user Windows ACL when supported and removes directories older than the configured retention period only after resolving them under the explicit backup root.

The optional weekly task runs under the current Windows user. The computer must be on and the cached Google/Supabase login must remain valid. Periodically restore a dump into a disposable test project; an untested dump is not a recovery plan.

## 7. Verification and rollback

The release gate includes local tests, environment-specific `npm run statecare:verify`, Cloud Run readiness, current-record and coordinate-coverage checks, PostgreSQL size, Worker `/api/health`, Registry diagnostics, hydrated browser navigation, security headers, Riverside landing copy, and production smoke tests. Manually verify signup email delivery, provider/staff authorization, a Menifee search, and that no browser network response exposes StateCare or vendor keys.

Inspect non-secret state and logs here:

```text
C:\Scripts\Git\elderpath-deployment\state\deployment-state.json
C:\Scripts\Git\elderpath-deployment\logs\
```

The checkpoint records prior Cloud Run revision and the D1 Time Travel output before production. On a bad release:

1. Stop promotion and preserve logs/request IDs.
2. Route Cloud Run back to the recorded prior revision and roll back the Worker deployment first.
3. Re-run health and read-only checks.
4. Restore Supabase or D1 data only if an additive migration/data change actually requires it, with a reviewed restore plan. This toolkit never restores data automatically.

Reference guidance: [Cloudflare CI tokens](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/), [Google GitHub WIF](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines), [GitHub repository variables](https://cli.github.com/manual/gh_variable_set), [GitHub repository secrets](https://cli.github.com/manual/gh_secret_set), [Resend domains API](https://resend.com/docs/api-reference/domains/create-domain), and [Supabase backups](https://supabase.com/docs/guides/platform/backups).

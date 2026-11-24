# CI demo releases: controlled Recreate on loopback 18094

Status: implementation and mocked regression verification only. A subsequent **authorized real
GitHub push** must run all ten Jenkins stages before this change is runtime-accepted. Do not
use Build Now, a webhook ping, previous manual tests, or Build #5 as proof of this new lifecycle.

## Verified baseline (2026-11-24)

Jenkins `GoMove-GitHub-Demo-CI` Build #5 completed SUCCESS in 382284 ms with a real
`com.cloudbees.jenkins.GitHubPushCause`. Source: `3c068d513581c7fa3c2a68fca68d30dfe9ca047c`.
Its original `build.xml`, evidence/state.json and containers were not changed by adoption.

- Flutter: 630 tests, 0 failures; Backend: 267 tests, 0 failures/errors/skips.
- New JAR and extracted image JAR SHA-256:
  `35773c9aad61be79b9ef9b293bcab119d9cfc15eca7709c430c231ea5c72e947`.
- Image: `sha256:832be007a4bbfe0b65a19a3da943662367b8a900a039c6d815acb15434ea8c3a`.
- Project: `gomove-demo-ci-b5-3c068d513581`.
- Backend: `d75f4b5517d566d017daa93b8960198b407c2c378cff6fcde68fae7527752ea6`.
- PostgreSQL: `f3673cb29e1fe74793cc196baa31717e3231216d4bdd2f5829e6317cd65af7d3`.
- OSRM: `fc49e2fa849ea19a15431b94aa231d2b8c98cdc5f67c7f7aa08060866181e04f`.
- Build #5 smoke: health/readiness HTTP 200 UP, OSRM HTTP 200/Ok, Flyway 19 successful
  migrations through V19, expected JDBC client, least-privilege application role, all 17
  business tables empty, Worker OFF, protected environments unchanged.

The initial registry was adopted from these completed build records and both JAR files, then
checked against live IDs, labels, image, bind mounts, private network IDs, volume creation
identity, loopback port mapping and real health/readiness. Adoption performs no Docker writes.

## Durable state and cutover

`%USERPROFILE%\AppData\Local\GoMove\JenkinsDemoReleases\registry.json` is outside the
per-build workspace. ACL permits the controller account and SYSTEM only. An exclusive file
lock excludes concurrent lifecycle actions; atomic same-directory replacement follows a
flushed write. A crash releases the OS lock but does **not** clear the transaction.

The registry holds active release, transaction (previous/candidate, cutover phase, build,
creation token and protected snapshot), and retained history. It contains metadata only.
Do not edit, delete or reconstruct it from port/container names. Missing, inconsistent or
ambiguous metadata blocks deployment. No resource is automatically deleted.

1. Stages 01-08 retain mandatory tests and new JAR/image verification. Active staging keeps
   running. Init blocks a new workload if a previous transaction remains unresolved.
2. Deploy revalidates the old active identity and verifies it stayed untouched since Init.
   The occupied port must belong to its exact backend ID. An unknown host/Docker owner fails.
3. Record `Preparing` before allocating anything. Use fresh per-build secrets, project,
   private network and database. Create candidate containers **stopped**, with a unique
   transaction label. Capture all three exact IDs and resource identities; persist `Prepared`.
4. Revalidate both releases and unrelated environments. Persist `StoppingPrevious` with
   cutover=true **before** the first stop. Stop only old backend -> OSRM -> PostgreSQL by ID.
   Keep containers, volume, networks, secrets and image. Check the port really became free.
5. Persist `StartingCandidate`. Start candidate PostgreSQL, check TCP readiness plus SELECT 1,
   initialize only its new app role/schema, then start OSRM and backend. Persist `AwaitingSmoke`.
6. Retain full health, Flyway/JDBC, empty DB, OSRM, image and effective Worker OFF smoke.
   Only after every check passes atomically promote candidate and retain the old manifest
   in history. `ProtectedSnapshot` also covers unrelated containers and other CI releases.

No simultaneous running full Blue-Green stacks. Downtime includes candidate database and
backend initialization. Each successful release has a **fresh empty database**; this is CI
staging, not a production data migration or promotion of Platform 18090.

## Failure and interruption

Deploy/Smoke errors after cutover attempt rollback once: verify all identities, stop verified
candidate backend -> OSRM -> PostgreSQL, verify port free or owned by the exact previous
backend, start exact previous PostgreSQL -> OSRM -> backend, check container health and actual HTTP health/readiness, expected image and
unchanged protected snapshot. Already running old services are not restarted. A first release
with no previous release instead verifies empty staging. No Compose recreation is used.

For `Prepared`, pre-stop `StoppingPrevious`, or an explicit rollback retry, the previous
backend may legitimately still own 18094. Recovery accepts that exact verified owner instead
of requiring a free port. Unknown owners and simultaneous running release backends remain
blocked. Already running previous services are health-checked, not restarted.

Promotion and rollback completion publish a separate registry object atomically before
updating caller memory. A publication failure retains the pending transaction, previous
active pointer and uncommitted history in memory. Rollback write failures stay blocking as
`RollbackFailed`; neither a successful runtime restore nor an exception is a false promotion.

The original action still exits nonzero and Jenkins remains FAILURE even if rollback passes.
Jenkins `post unsuccessful` provides best-effort recovery after abort; artifact cleanup runs
after recovery. If the agent/controller was killed, the durable journal remains. If rollback
failed, post does not automatically retry. New builds fail closed until operator recovery.

Read-only status (safe now):

```powershell
Set-Location D:\goMove
pwsh -NoProfile -File .\ci\Invoke-GoMoveDemo.ps1 -Action DeploymentStatus
```

Explicit recovery, **only after operator review**:

1. Let Jenkins record the affected build as completed/aborted and empty its queue. No active
   builds of this CI job are allowed; the registry lock must be obtainable. Do not restart either Jenkins
   controller just to force this check. Read the actual transaction build number from status.
2. Inspect its recorded previous/candidate identities and failure evidence. Do not guess IDs,
   clear the journal, free the port by killing an unknown process, or use `compose down`.
3. For the actual recorded build N, run once:

```powershell
# Example only: replace 6 with the transaction's actual build number.
pwsh -NoProfile -File .\ci\Invoke-GoMoveDemo.ps1 `
  -Action RecoverInterruptedDeployment -RecoveryBuild 6 -ConfirmRecovery
pwsh -NoProfile -File .\ci\Invoke-GoMoveDemo.ps1 -Action DeploymentStatus
```

If interrupted before candidate ID capture, automatic recovery refuses to infer stop targets.
Explicit recovery may retire that pre-cutover attempt **without any runtime mutation** only
if the old release is verified healthy and every surviving candidate has the exact transaction
token/expected configuration and is stopped. All partial resources remain for inspection.
If any such container is running, identity is wrong, or rollback verification fails: STOP,
preserve evidence/resources and request review. Never claim restored availability on exception.

## Explicit active restoration after Windows/Docker reboot

Compose deliberately retains `restart: "no"`. The pipeline never silently starts an old
release just to satisfy the healthy-previous-release gate. After reboot, an operator can use
this explicit action **after review**, with no pending transaction and no active CI build or
queued Jenkins work:

```powershell
pwsh -NoProfile -File D:\goMove\ci\Invoke-GoMoveDemo.ps1 -Action DeploymentStatus
pwsh -NoProfile -File D:\goMove\ci\Invoke-GoMoveDemo.ps1 `
  -Action RestoreActiveDeployment -ConfirmRestore
```

Do not execute the mutating action against the currently healthy Build #5 during hardening.
It holds the same registry lock, validates the complete active release/container identities,
expected immutable images, network/volume and port ownership, and rejects unresolved
transactions. It starts only verified `created`/`exited` active CI containers, PostgreSQL ->
OSRM -> backend. Running services are not restarted. It verifies image, container health and
real HTTP health/readiness, then checks the unrelated-environment snapshot is unchanged.
No Compose recreation, database initialization, resource deletion, Jenkins restart, or
Platform/sandbox/manual/legacy mutation occurs. A partial start or verification error remains
a failure; inspect evidence before an explicit retry. A healthy retry performs no starts.

## Low-memory settings and next authorized run

Initial implementation verification on 2026-11-24 (before final hardening):

- `pwsh -NoProfile -File ci/Test-GoMoveDemoLifecycle.ps1`: **30 tests, 30 PASS, 0 FAIL**, exit 0;
  mocked Docker only, including partial stop, interrupted preparation, token handoff, rollback
  failure and protected identities. No application test suites were rerun.
- PowerShell AST syntax: all four edited/new scripts PASS, exit 0.
- `pwsh -NoProfile -File ci/Invoke-GoMoveDemo.ps1 -Action StaticPreflight`: Compose PASS,
  exit 0, build/deploy false. Last available Windows memory: 5105950720 bytes.
- Jenkinsfile Groovy CONVERSION parse: PASS, exit 0; this is not a new live Jenkins build
  or full runtime Declarative verification.
- `git diff --check`: exit 0; separate checks of new/untracked files: zero whitespace diagnostics.
- Read-back registry: Build #5 identity verified, transaction null. Its three services remain
  running/healthy. Both original evidence hashes and all twelve protected baseline entries match.
  The adoption before/after check also preserved all 34 existing containers. Job history still
  contains only builds 1-5. No job/controller/webhook configuration was changed.

Final hardening regression coverage preserves all original 30 cases and adds Prepared and
pre-stop rollback, already-running previous backend retry, unrelated port owners, explicit
active restoration (confirmation, identity, start order, partial state, errors and protected
environments), and durable completion write failures. The exported verification report records
the final actual command output and totals. These are focused mocked lifecycle tests, not a
new Flutter/Backend test run or runtime acceptance of Build #6.

Only the local launcher startup threshold changes from 6 to 1.5 GiB (512 MiB Java heap,
256 MiB metaspace plus headroom). It still refuses a running controller, queued/unfinished
builds or wrong WAR/Home/security. It does not automatically stop/restart anything.
Stage RAM gates (1.5/2/2.5 GiB), sequential execution, Maven settings, Docker memory limits,
GIT_CONFIG_COUNT isolation, authentication and loopback bindings remain unchanged.

Before review: `git diff --check` and the focused lifecycle suite; do not rerun application
tests manually. After explicit approval to commit/push, the operator may use:

```powershell
git add -- Jenkinsfile.demo compose.demo-staging.yaml ci/Invoke-GoMoveDemo.ps1 `
  ci/GoMoveDemoLifecycle.ps1 ci/Test-GoMoveDemoLifecycle.ps1 ci/DEMO_RELEASE_RECOVERY.md
git commit -m "feat(ci): add repeatable staging cutover and rollback"
git push origin HEAD:feature/m4-2-tracking-reliability
```

These commands are a future run plan, not authorization to execute them during implementation.
The local untracked launcher and unrelated files are deliberately excluded. Observe the one
real push-triggered build: ten stages, actual test counts, dynamic Git SHA, new JAR/image SHA,
cutover, smoke and active-registry promotion. A real failure/abort rollback exercise remains
separately NOT VERIFIED; mocked regressions do not prove live rollback behavior. Do not
deliberately break Build #5 or any protected environment to test this implementation.

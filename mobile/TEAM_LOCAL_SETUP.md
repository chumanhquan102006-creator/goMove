# Team local setup (Windows)

Each member uses a personal Git branch and their own local environment. A
Docker installation on a **separate computer** has independent containers,
volumes and database data. Running several GoMove stacks on **one shared Docker
Engine** can conflict: the Compose file names gomove-postgres, binds 5432 and
explicitly names the gomove_postgres_data volume. Coordinate any shared-engine
setup; do not delete another member's volume.

## Prerequisites and checkout

Install Git, Java 21, Docker Desktop with Compose, Flutter (check the SDK
constraint in mobile/pubspec.yaml), Android SDK/platform tools for adb, and a
local OSRM runtime with Hanoi road data. Use only trusted official installers
and project-reviewed tooling. Check with git --version, java -version,
docker compose version, flutter doctor and adb version.

~~~powershell
git clone https://github.com/chumanhquan102006-creator/goMove.git
Set-Location goMove
git fetch origin
$base = 'origin/feature/mobile-demo-gps-simulation' # Example only: confirm the reviewed base with the project lead.
git rev-parse --verify "$base^{commit}"
if ($LASTEXITCODE -ne 0) { throw 'Assigned base branch is not available locally.' }
$baseCommit = git rev-parse $base
git log -1 --oneline $base
git switch -c feature/YOUR_NAME-TASK $base
if ($LASTEXITCODE -ne 0) { throw 'Task branch creation failed.' }
git status --short --branch
$headCommit = git rev-parse HEAD
if ($headCommit -ne $baseCommit) { throw 'HEAD does not match the assigned base.' }
git log -1 --oneline HEAD
~~~

Use the **exact stable base branch assigned by the project lead**; the example
above is the current reviewed GPS-simulation baseline, and the lead may name a
newer one. Confirm that HEAD matches the chosen base before editing. Do not
merge into, push to, or modify a protected branch as part of checkout.

The repository does not bundle an OSRM binary or Hanoi .osm.pbf/.osrm data.
Prepare the team's approved Hanoi dataset with the standard OSRM car profile
and matching MLD preprocessing, then run the local osrm-routed service on port
5000. For an already preprocessed dataset, the runtime command is
osrm-routed --algorithm mld PATH_TO_HANOI.osrm. Verify the actual engine with
the read-only route check in tools/check-demo-readiness.ps1. Do not replace the
dataset or change shared routing configuration just to make a demo pass.

## Local PostgreSQL, secret and Backend

From the repo root, start only the existing PostGIS service on your own
computer:

~~~powershell
docker compose up -d postgres
docker compose ps
~~~

The checked-in Compose settings are for local development. Every member uses
their **own** local development JWT secret. Create it **once per Windows user
and computer**, protected by Windows DPAPI in LocalAppData outside the repo.
DPAPI ties this encrypted file to that Windows account on that computer. If
JWT_SECRET is already set in this shell, the one-time block preserves and
encrypts **that existing value** rather than generating another one. If the
DPAPI file already exists, the block stops without overwriting it. Never put
the secret in Git, a command transcript, a Flutter
dart-define or a screenshot. The commands below do not print its value.

Run this one-time creation block in PowerShell from any directory:

~~~powershell
$secretFile = Join-Path $env:LOCALAPPDATA 'GoMove\jwt-secret.dpapi'
if (Test-Path -LiteralPath $secretFile) { throw 'The DPAPI secret file already exists; do not overwrite it.' }
New-Item -ItemType Directory -Path (Split-Path -Parent $secretFile) -Force | Out-Null
if ($env:JWT_SECRET) {
    $secure = ConvertTo-SecureString $env:JWT_SECRET -AsPlainText -Force
} else {
    $secretBytes = New-Object byte[] 48
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($secretBytes)
        $secure = ConvertTo-SecureString ([Convert]::ToBase64String($secretBytes)) -AsPlainText -Force
    } finally {
        [Array]::Clear($secretBytes, 0, $secretBytes.Length)
        $rng.Dispose()
    }
}
$encrypted = ConvertFrom-SecureString $secure
$payload = [Text.Encoding]::UTF8.GetBytes($encrypted)
$stream = [IO.File]::Open($secretFile, [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($payload, 0, $payload.Length) }
finally { $stream.Dispose() }
~~~

Before **each** Backend startup, including after restarting PowerShell or
Windows, load that same secret into the Backend process environment. If
JWT_SECRET is already set to a *different* value, this block stops rather than
overwriting it. Use the same Windows user that created the DPAPI file:

~~~powershell
$secretFile = Join-Path $env:LOCALAPPDATA 'GoMove\jwt-secret.dpapi'
if (-not (Test-Path -LiteralPath $secretFile)) { throw 'Local JWT secret file is missing; do not generate a replacement for an existing demo environment.' }
$secure = ConvertTo-SecureString (Get-Content -LiteralPath $secretFile -Raw)
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $storedSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ($env:JWT_SECRET -and $env:JWT_SECRET -cne $storedSecret) {
        throw 'JWT_SECRET is already set to a different value; no overwrite was made.'
    }
    if (-not $env:JWT_SECRET) { $env:JWT_SECRET = $storedSecret }
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    $storedSecret = $null
}
$env:OSRM_BASE_URL = 'http://127.0.0.1:5000'
Set-Location backend
./mvnw.cmd spring-boot:run
~~~

The Backend dev profile uses the Compose PostGIS on localhost:5432; Flyway
migrations run during normal startup. Keep this shell open. In another shell,
inspect http://127.0.0.1:8080/actuator/health or run the readiness checker.
Do not rotate an existing demo JWT secret merely because a temporary service
fails; use the local secret assigned to that environment. If its Windows user
profile or DPAPI file is lost, recover the original secret from a secure backup
before restarting an environment whose existing tokens must remain valid.

## Flutter device addresses

Three addresses have different purposes:

| Purpose | Address |
| --- | --- |
| Android Emulator reaches Backend on its host PC | http://10.0.2.2:8080 |
| Physical Nokia reaches Backend over Wi-Fi | http://ASUS_CURRENT_LAN_IPV4:8080 |
| Laptop ADB reaches Nokia wireless debugging | CURRENT_NOKIA_DEBUG_IP:CURRENT_DEBUG_PORT |

Read the current ASUS Wi-Fi IPv4 from tools/check-demo-readiness.ps1 or
Get-NetIPAddress; do not reuse an old hardcoded address. Read the Nokia ADB
address from its current Wireless debugging screen. ADB connectivity alone
does not prove the tablet can reach the Backend over LAN.

~~~powershell
Set-Location mobile
flutter pub get
flutter devices
flutter run -d emulator-5554 --dart-define=MOCK_ENABLED=false --dart-define=API_BASE_URL=http://10.0.2.2:8080
~~~

For the Nokia, replace the device ID and API address with the values actually
shown on this computer and network:

~~~powershell
adb connect CURRENT_NOKIA_DEBUG_IP:CURRENT_DEBUG_PORT
flutter run -d NOKIA_SERIAL --dart-define=MOCK_ENABLED=false --dart-define=API_BASE_URL=http://ASUS_CURRENT_LAN_IPV4:8080
~~~

Use separate authorized Customer and Driver accounts. The Backend determines
approval, dispatch, ownership, Quote, trip and CASH state. The simulation
script in tools/ changes only one verified emulator GPS provider.

## Local checks and team Git workflow

~~~powershell
Set-Location mobile
./tools/test-demo-gps-route.ps1
./tools/test-check-demo-readiness.ps1
flutter analyze
flutter test
Set-Location ../backend
./mvnw.cmd clean test
Set-Location ..
git diff --check
git status --short --branch
~~~

Backend integration tests use Testcontainers; they may need a working Docker
Engine but should not alter the shared demo database. Run only the tests
relevant to your task before submitting a personal-branch Pull Request.
Review git diff, commit **only your own reviewed files** on your personal
branch, then push that branch and request review. Follow AGENTS.md and the
task's scope. A Markdown rules file cannot block a push: protected branches
require actual GitHub permissions and branch-protection rules.

Ordinary team members need authorization before changing infrastructure or
Docker configuration, Backend business rules, database schema or historical
Flyway migrations, JWT/security settings, dispatch/GPS protections,
Booking/payment logic, commission calculations, or protected branches. Do not
commit secrets, token values, customer data or full database dumps.

For the demo order, recovery paths, endpoint hold and optional marker motion,
see DEMO_READINESS.md and tools/README.md.

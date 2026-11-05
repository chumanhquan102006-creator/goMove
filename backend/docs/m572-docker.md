# M5.7.2: isolated local Backend, PostGIS and OSRM

This stack is for local verification of the current GoMove Backend. It does not
replace the existing `docker-compose.yml`, `gomove` or `gomove-midterm` projects.
Its Compose project is `gomove-m572`; only the Backend is published, on
`127.0.0.1:18081`. PostgreSQL and OSRM have no host ports. The dedicated
`gomove-m572_postgres_data` volume must never be confused with the existing
development or Midterm volumes. The Docker network permits outbound HTTPS so
the existing Photon geocoder can work; the Backend host binding remains local.
Public HTTPS/WSS, certificates and a reverse proxy belong to M5.7.3.

## Prerequisites and preflight

- Docker Desktop with Linux containers and Compose. Check `docker compose version`.
- A prepared Hanoi OSRM **MLD** dataset directory, such as `D:/GoMove-routing`,
  containing `hanoi.osrm.partition`, `hanoi.osrm.cells`, `hanoi.osrm.mldgr` and
  the other `hanoi.osrm.*` files. This stack mounts that directory read-only.
  It does not download or preprocess map data. Its OSRM image is pinned to the
  digest already verified for the local dataset; PostGIS is pinned to a
  compatible PostgreSQL 16/PostGIS 3.5 image.
- Port `127.0.0.1:18081` free. Existing ports 8080, 5432, 5000, 18080 and
  15432 can stay in use. Allow enough memory for an additional Java process,
  Postgres and OSRM before starting the full stack.
- A private secret directory outside the repository. Each developer must use
  their own local DB password and JWT signing key. Never paste secret values
  into `.env.m572`, screenshots, logs or Git.

From the repository root, inspect the existing environment without changing it:

```powershell
git status -sb
docker compose ls
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
Get-NetTCPConnection -LocalPort 18081 -State Listen -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath 'D:\GoMove-routing' -Filter 'hanoi.osrm.*' |
  Select-Object -ExpandProperty Name
```

## Create secrets once on Windows

Run the following in your own PowerShell session. The files are in your
Windows profile, outside Git. This script **refuses to overwrite** either
existing secret. Windows profile ACLs should restrict access to your account,
Administrators and SYSTEM; inspect the ACL on a shared computer. Docker Desktop
must be able to read the files for Compose file-backed secrets. Back up the
secrets securely if you need existing JWTs to remain valid after a restart.

```powershell
$secretDir = Join-Path $env:LOCALAPPDATA 'GoMove\M572\secrets'
New-Item -ItemType Directory -Path $secretDir -Force | Out-Null
$dbSecret = Join-Path $secretDir 'db-password.txt'
$jwtSecret = Join-Path $secretDir 'jwt-secret.txt'
if ((Test-Path -LiteralPath $dbSecret) -or (Test-Path -LiteralPath $jwtSecret)) {
  throw 'A M5.7.2 secret already exists. Keep it; do not rotate or overwrite it.'
}
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
  $dbBytes = New-Object byte[] 32
  $jwtBytes = New-Object byte[] 48
  $rng.GetBytes($dbBytes)
  $rng.GetBytes($jwtBytes)
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($dbSecret, [Convert]::ToBase64String($dbBytes), $utf8)
  [System.IO.File]::WriteAllText($jwtSecret, [Convert]::ToBase64String($jwtBytes), $utf8)
} finally {
  $rng.Dispose()
}
```

If one file already exists and the other is missing, investigate before
starting. Do not regenerate the first file or reset an existing database. A
password change requires a deliberate, coordinated database rotation; a JWT
change invalidates issued tokens. File-backed Compose secrets are plaintext
files on the host, protected by Windows file permissions, and mounted into
containers at `/run/secrets/`. They are never copied into the Docker image.

Copy `.env.m572.example` to `.env.m572` and edit only the two absolute paths.
Use forward slashes for Windows drive paths. `.env.m572` is Git-ignored and
contains paths, not secret values. Quote a value if the Windows user name has
spaces. For example:

```dotenv
M572_SECRET_DIR="C:/Users/YOUR USER/AppData/Local/GoMove/M572/secrets"
M572_OSRM_DATA_DIR=D:/GoMove-routing
```

The container profile imports the secret files with Spring Boot `configtree`.
`JWT_SECRET` and `spring.datasource.password` are read from those files. It
uses `jdbc:postgresql://postgres:5432/gomove_m572` and
`http://osrm:5000`; it does not activate the `dev` profile or use localhost
inside containers. The password and JWT secret are required at startup.

## Validate, build and start

All commands below are scoped to this Compose project. Run them from the
repository root. `config` displays the resolved **file paths**, not the secret
contents; review its output before starting anything.

```powershell
$m572 = @('--env-file', '.env.m572', '-p', 'gomove-m572', '-f', 'compose.m572.yaml')
docker compose @m572 config
docker compose @m572 build backend
docker compose @m572 up -d postgres osrm backend
docker compose @m572 ps
```

If the Hanoi dataset is unavailable, start **PostGIS only** with
`docker compose @m572 up -d postgres`. The path variable still has to be set
for Compose interpolation, but the OSRM bind mount is not used in this partial
mode. Partial startup is not full-stack acceptance. Do not point this stack
at the existing OSRM container merely to mark it healthy.

The Backend waits for Postgres health and starts after OSRM starts. OSRM has
no image-provided HTTP probe, so verify an actual route response before
declaring routing ready. The Backend health check probes Actuator readiness,
including database connectivity. Flyway runs at startup and Hibernate validates
the schema. The Backend image runs as UID 10001, with a read-only filesystem
and a writable temporary directory. Springdoc API docs and Swagger UI are
disabled in this profile; only Actuator health is exposed. Existing JWT and
role authorization remain unchanged. Compose disables Spring's unused
generated in-memory user, so its random password is not logged. WebSocket
origins are explicit local
origins, without a wildcard.

## Verification

```powershell
docker compose @m572 ps
docker compose @m572 logs --tail=100 postgres osrm backend
curl.exe --fail --silent http://127.0.0.1:18081/actuator/health
curl.exe --fail --silent http://127.0.0.1:18081/actuator/health/readiness
docker compose @m572 exec -T postgres psql -U gomove_m572 -d gomove_m572 -Atc 'SELECT PostGIS_Version()'
docker compose @m572 exec -T postgres psql -U gomove_m572 -d gomove_m572 -Atc 'SELECT version, success FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 1'
docker compose @m572 exec -T backend java -cp /app/health HealthProbe 'http://osrm:5000/nearest/v1/driving/105.834,21.028' 'Ok'
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

The OSRM nearest check verifies container-to-container routing using an
ordinary Hanoi coordinate; it does not change data or create a Quote. A real
authenticated REST smoke check requires a deliberately created fixture in
the isolated database. Do not reuse or change accounts in the existing
development or Midterm databases. An unauthenticated protected request may
be checked for HTTP 401 without creating data.

## Shutdown, persistence and recovery

```powershell
docker compose @m572 stop
docker compose @m572 ps
```

`stop` preserves the isolated database volume. Do **not** use `down -v`,
`docker volume prune` or broad Docker cleanup. Never target the existing
`gomove` or `gomove-midterm` projects. To back up meaningful M5.7.2 data,
run `pg_dump -Fc` from this project's Postgres container and save the dump in
a private, access-controlled folder outside Git. Test restoration to a
separate, explicitly named disposable database before depending on the dump.
Do not restore over the active database without an approved recovery plan.

## Acceptance boundary

M5.7.2 needs a successful image build, isolated services healthy, PostGIS and
Flyway V18 confirmed, OSRM connectivity and Backend health confirmed, and
proof that existing services remain untouched. These local checks do not
establish public HTTPS/WSS, Nokia 4G reachability or production readiness.

## Local verification record (2026-11-05)

- `docker compose --env-file .env.m572 -p gomove-m572 -f compose.m572.yaml config`:
  exit 0, including
  the final configuration. The resolved backend binding was
  `127.0.0.1:18081:8080`; Postgres and OSRM had no published host ports.
- The final digest-pinned Backend Dockerfile built with exit 0. The uncached
  Maven Wrapper build produced the Spring Boot JAR with `BUILD SUCCESS`;
  tests were intentionally skipped inside the image build.
- In the isolated stack, Backend and Postgres were healthy. The Backend ran
  as UID 10001 with a read-only root filesystem. Its readiness URL returned
  HTTP 200 and `{"status":"UP"}`. The OSRM nearest-route probe from the
  Backend container exited 0. PostGIS reported version 3.5; read-only SQL
  showed Flyway version 18, success `true`, and 18 successful migrations.
- `/v3/api-docs`, `/swagger-ui/index.html` and `/actuator/env` returned 404;
  unauthenticated `/api/v1/auth/me` returned 401. The final container startup
  log showed the `container` profile and no generated Spring security password.
- A Windows PowerShell run of `backend/mvnw.cmd -B -ntp clean test` was reported
  by the tester as `BUILD SUCCESS`, exit 0, 179 tests, 0 failures, 0 errors and
  0 skipped. Independently inspected Surefire reports contain 35 report files
  with the same 179/0/0/0 totals. The terminal exit code is tester-reported.
- After Docker Desktop reopened, the existing GoMove and Midterm containers
  were up. The isolated stack was then stopped to conserve laptop memory;
  its dedicated Postgres volume was
  retained. A stopped container's current health label is not a live health
  result. Restart with the scoped `up` command above to repeat live checks.

An authenticated REST smoke test was not run because the new database has no
approved test account. Docker Desktop exited unexpectedly during an earlier
uncached rebuild; the cause was not established. After Docker Desktop was
reopened, the final cached image build and isolated runtime checks succeeded.
Available Windows memory was about 814 MB while the extra stack was running,
so avoid simultaneous heavy builds or emulator sessions on this laptop.

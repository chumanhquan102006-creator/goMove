# M5.7.3C2A — offline production infrastructure proposal

This directory contains **configuration and guarded tools only**. It has not
been deployed or run on Oracle A1. C1's [readiness assessment](M573C1_READINESS.md)
lists the blockers. Do not run `compose.prod.yaml up`, publish images, alter DNS,
or create cloud resources until a separate deployment approval and the gates
below are complete. Existing GoMove, Midterm and M5.7.2 volumes are unrelated.

## Topology and boundaries

```text
Nokia 4G -- HTTPS/WSS 443 --> Caddy -- edge --> one Spring Boot Backend
                                               |-- data (internal) --> PostgreSQL/PostGIS
                                               `-- routing (internal) --> OSRM + Hanoi MLD
                                   Backend -- edge egress --> reviewed HTTPS geocoder
```

`compose.prod.yaml` fixes the project name to `gomove-m573`. Only Caddy publishes
TCP 80/443; Backend, PostgreSQL and OSRM have no host ports. The edge network is
intentionally **not** `internal`, so Backend can reach the configured HTTPS
geocoder. Data and routing networks are internal. One Backend is required while
the STOMP simple broker and token-expiry session registry are in memory.

The PostGIS image name in Compose is a *future publishing target*. The native
ARM64 source-build PoC passed its isolated tests, but its APT dependency chain
and vulnerability review are incomplete. No approved production PostGIS or
Backend digest exists. The Caddy digest also requires review. Empty digest
variables fail Compose interpolation; the sample validator uses an all-zero
digest that is deliberately rejected in real preflight. OSRM uses the pinned
upstream multi-architecture digest from M5.7.2; its actual ARM64 Hanoi runtime
remains untested. Never point this stack to `postgis/postgis:16-3.5` or the
M5.7.2 volume. Do not publish or upload the private local map files without
separate approval.

Initial memory/CPU limits are **unmeasured guardrails**, not Oracle capacity
evidence: Backend 2 GiB/0.75 CPU, PostgreSQL 2 GiB/0.5 CPU, OSRM 3 GiB/0.5
CPU, Caddy 256 MiB/0.25 CPU. They need ARM64 startup/load measurements before
deployment. PostgreSQL persists in `gomove-m573-postgres-data`; Caddy persists
certificate/config state in its two dedicated volumes. No `down -v` or prune
command is part of this runbook.

## Production inputs (names only)

Store a **path-only** Compose environment file outside Git. The repository's
[`.env.prod.example`](.env.prod.example) deliberately has empty values:

| Input | Purpose |
| --- | --- |
| `M573_PUBLIC_HOSTNAME` | Reviewed DNS name for Caddy and exact `https://` WebSocket origin. No wildcard/IP. |
| `M573_GEOCODING_BASE_URL` | Explicit reviewed HTTPS geocoder URL. Photon demo remains a limited external dependency. |
| `M573_SECRET_DIR` | Private external directory containing `db-password-backend.txt`, `db-password-postgres.txt` and `jwt-secret.txt`. |
| `M573_OSRM_DATA_DIR` | Approved read-only directory with the full prepared `hanoi.osrm.*` MLD set. |
| `M573_CADDY_DIGEST` | Reviewed ARM64 Caddy image SHA-256, without the `sha256:` prefix. |
| `M573_BACKEND_DIGEST` | Built and reviewed ARM64 Backend image SHA-256. |
| `M573_POSTGIS_DIGEST` | Reviewed production PostGIS 16/3.5 ARM64 image SHA-256; PoC alone is insufficient. |

The secret files are external Compose secrets. PostgreSQL reads
`POSTGRES_PASSWORD_FILE`; Spring imports `configtree:/run/secrets/` and sees
`spring.datasource.password` and `JWT_SECRET`. The two database files must
contain the **same password** but are separate bind mounts: on a standard
rootful Linux host, the Backend copy is owned by UID 10001 and the PostgreSQL
copy by the reviewed image's `postgres` UID (expected 999), both mode 0400.
The JWT file is owned by UID 10001, mode 0400. Compose does **not** remap
UID/GID for file-backed secrets, so do not assume one root-owned 0400 file is
readable to both containers. Verify the actual image UID and container
readability before deployment. The preflight checks owners, modes and that
the two password copies have matching hashes without printing the value.
Never put values in the env file,
Flutter defines, GitHub Actions logs, Compose YAML or an image. Keep the files
owner-readable only on the Linux host. Do not generate or rotate production
secrets during this offline phase. An actual preflight refuses absent, short or
group/world-readable files. Secure key custody and recovery must be agreed
before a real deployment.

Spring always activates the explicit `prod` profile from Compose. The profile
uses private `postgres:5432` and `osrm:5000`, requires the selected hostname and
geocoder URL, disables API docs/Swagger, and binds Actuator health on Backend
loopback port 8081 (never published). Caddy only routes `/api/v1/*` and `/ws`,
returns 404 for management/docs/other paths, caps HTTP request bodies at 1 MB,
and sanitizes forwarding headers before Spring processes them. Caddy handles
WebSocket Upgrade automatically. The OSRM container health check tests required
files/process only; **Backend health** additionally requests a real candidate
Hanoi route. That route pair and all health checks still require runtime proof.
Caddy's health check validates its configuration, not end-to-end TLS reachability.

## Offline validation now; future deployment only after approval

From the repository root, the following commands only parse configuration and
run security regression checks. They neither need Docker Engine nor start any
container:

```text
python infra/deployment/validate_prod_config.py --sample
python -B -m unittest discover -s infra/deployment -p test_validate_prod_config.py -v
docker compose -f infra/deployment/compose.prod.yaml config --format json
```

The last command is **expected to fail** with unset required digests. For an
actual deployment preflight, supply an external path-only env file and a
separately reviewed SHA-256 manifest listing every `hanoi.osrm.*` file. The
validator checks each file's checksum, secret metadata, image digests, network
isolation, hostname and exposed ports without printing secret contents:

```text
python3 infra/deployment/validate_prod_config.py \
  --env-file /private/path/gomove-prod.paths.env \
  --dataset-manifest /private/path/hanoi.osrm.sha256
```

Prepare the manifest on the trusted dataset source after approval; do not
commit it or upload map files during C2A. Before a future approved first start,
validate the Caddyfile with the **reviewed pinned Caddy image** using its
`caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` command,
without requesting certificates. Then inspect `docker compose ... config` and
the host firewall/OCI security list. Caddy needs a real DNS name pointing to
the approved host, public TCP 80/443 for ACME, and persistent `/data`. Backend,
PostgreSQL and OSRM ports must stay private. Only after separate approval may
an operator pull the reviewed digests and run `docker compose --project-name
gomove-m573 --env-file <external-path-file> -f infra/deployment/compose.prod.yaml
up -d`. This command is intentionally **not run** in C2A.

## Backup, retention and isolated restore

The future operator must choose an **off-server** destination, verify the
recipient GPG public-key fingerprint out of band, and keep the private
decryption key away from the VM and GitHub. GnuPG is an operational prerequisite,
not a repository dependency. On the approved Linux host, create a private
mounted `GOMOVE_BACKUP_DIR` (mode 0700) and its empty marker
`.gomove-m573-backups`. The scripts reject a directory in this repository or
with group/other access. `GOMOVE_PROD_ENV_FILE` is the external path-only env
file; `GOMOVE_BACKUP_RECIPIENT_FPR` is a full public-key fingerprint.

After the production database is approved and live, run
`bash infra/deployment/backup-prod.sh daily` each day and
`bash infra/deployment/backup-prod.sh weekly` once a week.
`pg_dump -Fc` runs inside the compatible PostgreSQL image and streams directly
to GPG public-key encryption; the host never writes a plaintext dump. Each
ciphertext gets a SHA-256 sidecar. Transfer **both** files to off-server
storage and verify the hash there; a local backup alone does not satisfy the
recovery requirement. Check alarms and free disk space.
`bash infra/deployment/prune-backups.sh`
shows a dry run by default; `--apply` retains the newest 7 daily and 4 weekly
encrypted files and deletes only recognized older names in the marked backup
directory. Never apply retention before confirming off-server copies.

`compose.restore.yaml` derives a separate private project name
`gomove-m573-restore-<M573_RESTORE_SUFFIX>`, with its **own** data volume and disposable password
file (`M573_RESTORE_DB_PASSWORD_FILE`). It has no host ports and does not mount
the production volume. After an approved rehearsal creates that isolated
container, call `bash infra/deployment/restore-isolated.sh --container <container-id> --target-db
gomove_restore_<name> --db-user gomove_prod --backup <encrypted-file>` on a
host with the authorized GPG private key. The script checks the ciphertext
hash, restore-project and PostgreSQL service labels, the exact project-scoped
`restore_data` volume, and a successful **nonexistence** query for the new
target database. A failed query aborts before `createdb`.
It never uses `--clean` or restores over `gomove_prod`. If restoration fails,
the partial isolated database is left for inspection, not automatically
deleted. Check PostGIS, Flyway V18, counts and an authorized application smoke
test before accepting recovery. Production restore needs a separate written
recovery decision; rolling an application image back by digest is safe only
when the database migration remains compatible.

Backup/restore scripts were not executed on any real database in C2A. No
off-server store, GPG key or restore container is configured yet. The proposed
7-daily/4-weekly policy is not a measured RPO/RTO.

## Remaining gates before Oracle A1 or public use

1. Approve tenancy, Always Free quota/cost guard, DNS name, backup destination,
   dataset transfer and signing/key custody. No paid resource is authorized.
2. Build and smoke-test the actual Backend image on native ARM64; review the
   PostGIS production build and all image vulnerabilities; validate OSRM with
   the checksummed Hanoi MLD set on ARM64. Measure memory/startup/load.
3. Validate Caddy syntax and trusted HTTPS/WSS with a private isolated test;
   test forward-header spoof rejection, explicit origins, expired STOMP
   subscription, unauthorized tracking and completed-trip GPS masking.
4. Define public rate limits for auth, Quote/OSRM and WebSocket abuse. The
   current per-account geocoding limit does not cover them.
5. Rehearse encrypted off-server backup and isolated restore. Review Flyway
   compatibility before any app digest rollback. Never edit V1–V18.
6. Only after all checks and separate approval, perform a manual first deploy.
   Nokia 4G HTTPS/WSS Golden Path and negative security tests remain the final
   acceptance gate; LAN E2E is insufficient.

Neither C2A nor the repository's existing CI publishes images or deploys.

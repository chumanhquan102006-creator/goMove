# M5.7.3C2B isolated runtime evidence

Status: **partial verification, not production acceptance**. These tests used
disposable local environments on Windows/Docker Desktop x86_64. No public
deployment, production Compose, certificate request, private Hanoi map transfer
or existing database change was made.

Local reproduction from the repository root (only on a machine with a usable
Docker Engine; each test creates its own disposable resources):

    python -B -m unittest discover -s infra/deployment -p test_validate_prod_config.py -v
    python infra/deployment/validate_prod_config.py --sample
    python -B infra/deployment/test_c2b_caddy_runtime.py
    docker build --progress=plain --platform linux/amd64 -f backend/Dockerfile -t gomove-c2b-backend:b08a9be backend
    python -B infra/deployment/test_c2b_backend_runtime.py
    python -B infra/deployment/test_c2b_osrm_runtime.py

For backup/restore, run test_c2b_recovery_runtime.py under Ubuntu WSL with
GOMOVE_C2B_DOCKER pointing to the Windows Docker Desktop CLI. It requires the
pre-existing local image gomove-postgis35-spike:amd64 and never calls the real
production Compose source. The ARM64 workflow has not been executed.

## Baseline and isolation

- Source commit: b08a9beb23da37d6731907c006a2b8dec9887e07.
- New local branch: feature/m5-7-3-runtime-validation; changes remain unstaged.
- [GitHub CI run 42049581966](https://github.com/chumanhquan102006-creator/goMove/actions/runs/42049581966)
  for the source commit completed successfully: Backend tests, Flutter checks
  and AMD64 Backend image build. That CI run did not execute C2B.
- Local Docker Engine: Linux x86_64, version 29.6.1. Existing GoMove and
  Midterm containers were left running. C2B containers, networks and volumes
  used random names; C2B volumes and networks were label checked before
  removal. Post-test C2B container/volume/network inventories were empty.

## Caddy actual-binary tests

The test used the official Caddy 2.10.2 Alpine multi-architecture index digest
sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d.
This is a **test image**, not an approved production digest. The real Caddy
binary accepted Caddyfile.prod via caddy validate and caddy adapt --validate
(both exit 0). It emitted non-fatal warnings about redundant forwarding-header
assignments and formatting.

The command python -B infra/deployment/test_c2b_caddy_runtime.py exited 0:
**4/4 tests passed** against an isolated mock upstream and Caddy bound only to
a random 127.0.0.1 port. The tests covered REST proxying, /ws Upgrade (101),
denial of Actuator/Swagger/docs and unknown paths (404), spoofed Forwarded and
X-Forwarded header sanitization, a body over 1 MiB (413), and a malformed
header (400). One idle snapshot measured startup 0.55 s, CPU 0.00%, memory
12.42 MiB. These are not load or Oracle capacity measurements.

The test hostname used **HTTP**, so trusted HTTPS certificates, TLS renewal,
real WSS and external firewall behavior remain **NOT RUN**.

## Backend production profile on local AMD64

The current backend/Dockerfile built successfully for linux/amd64 with Maven
package inside the image (exit 0; Maven build success, tests skipped in this
image build). The temporary test image tag was removed after the smoke test.
The separate source-commit GitHub CI run above had already passed Backend tests.

The command python -B infra/deployment/test_c2b_backend_runtime.py exited 0.
It used a fresh PostGIS tmpfs database, an isolated network, a newly created
synthetic secret volume and no host ports. The production profile exited
nonzero when mandatory configuration was absent. With synthetic secrets, the
non-root UID 10001 Backend reported private Actuator readiness UP after 11.50 s,
and **real Flyway migrations V1–V18** succeeded on the fresh database. A single
idle snapshot measured Backend CPU 0.73% and memory 360.7 MiB. This is local
**AMD64** evidence, not native ARM64 or Oracle capacity proof.

## OSRM and synthetic route

The production-pinned OSRM image index digest
sha256:55dbfd47d984c2cacd64e32901b4321c86b5ec761438e69aa053dc78698a786f
has both linux/amd64 and linux/arm64 manifests. Local execution was **AMD64
only**. The command python -B infra/deployment/test_c2b_osrm_runtime.py exited
0: the checked-in **synthetic** OSM road passed osrm-extract, osrm-partition and
osrm-customize; MLD routing returned HTTP code=Ok from a non-root UID 10001
container with loopback-only host binding. The production-style MLD-file and
process health probe passed. The final idle snapshot measured startup 0.81 s,
CPU 0.00%, memory 2.324 MiB.

The first non-root attempt against a Windows NTFS bind mount failed with
permission denied for route.osrm.fileIndex. Repeating with a new, labeled
Docker Linux volume and explicitly readable files passed. This establishes a
**dataset file-permission prerequisite** for a future Linux host; it does not
prove a defect in production Compose. The private, prepared Hanoi MLD dataset
was never used, copied or uploaded. Native ARM64 OSRM runtime and actual Hanoi
routing remain **NOT RUN**.

## Encrypted backup and isolated restore

The script test_c2b_recovery_runtime.py was run under Ubuntu WSL with temporary
Linux 0700 directories and the Windows Docker CLI. It exited 0 against two
isolated PostGIS **AMD64** containers, a newly created labeled restore volume,
a short-lived synthetic GPG key and synthetic table data. A narrow test-only
Docker shim redirected the production backup script's fixed Compose source to
the synthetic source container; the real production Compose was never called.
The restore and retention scripts ran without source modification.

Observed passes: unknown GPG recipient and failed dump returned nonzero without publishing a backup;
backup ciphertext was nonempty and decrypted to PGDMP; checksum mismatch,
outside-directory path and symlink were rejected; wrong project, wrong service,
wrong data mount and failed DB-existence inspection returned nonzero; valid
restore produced the source record in a **new** database; a repeat restore
refused to overwrite it; retention dry run changed nothing; apply removed only
old **synthetic files in a newly created temporary directory** and was
idempotent. The restored PostGIS reported version 3.5; its
flyway_schema_history row was a **synthetic V18 marker**, not execution of real
Flyway V1–V18 in this rehearsal. Idle source/restore DB snapshots measured
65.72/30.46 MiB and 0.03/0.05% CPU respectively.

The first Windows Git Bash attempt failed its 0700 directory guard on NTFS;
the WSL ext4 rerun passed. Encrypted **off-server** transfer/retention and a
production backup recovery decision remain **BLOCKED** pending approved storage
and key custody.

## Native ARM64 follow-up

The new workflow .github/workflows/runtime-arm64-c2b.yml and script
infra/deployment/run-c2b-arm64.sh prepare a GitHub-hosted native
ubuntu-24.04-arm test. It will build current Backend and PostGIS images without
publishing, pull pinned OSRM, check linux/arm64 architecture, exercise
missing-prod-config failure, non-root secret-file readability, private Backend
readiness, real Flyway V18 migration on a fresh disposable DB, and an OSRM route
using only the synthetic fixture. It also prints startup and CPU/memory
snapshots. All three services have no host port binding.
Registry manifest inspection confirmed linux/arm64 entries for the pinned
Maven, Java 21 JRE, PostgreSQL and OSRM base images; runtime compatibility
still requires the workflow to execute.

The script passed Bash syntax checking, and the workflow passed YAML parsing.
**GitHub Actions has not run this new workflow** because this patch is neither
committed nor pushed. Native ARM64 Backend/OSRM results are therefore **NOT
RUN**. This workflow still cannot validate the private Hanoi dataset, Oracle
A1, production digests, real secrets, production backup/restore or public
HTTPS/WSS. The existing PostGIS image build has unpinned APT dependency
resolution and needs production provenance/vulnerability review.

## Remaining deployment gates

1. Review this patch, then obtain a successful native ARM64 C2B workflow run.
2. Validate approved Hanoi MLD files and permissions on an isolated ARM64 host
   without uploading the private dataset to GitHub.
3. Approve production image digests and review vulnerabilities/resource use.
4. Establish off-server encrypted backup, independent integrity checks and a
   restore rehearsal under an approved recovery plan.
5. Configure reviewed DNS, firewall, trusted TLS and public HTTPS/WSS; verify
   JWT/STOMP authorization, GPS privacy and abuse controls over Nokia 4G.
6. Perform representative load and recovery tests. No observed idle snapshot
   here establishes production capacity or RPO/RTO.

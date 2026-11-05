# M5.7.3C1 — secure public deployment readiness (planning only)

Date: 2026-11-05. Baseline: `4bb3185` on `feature/m5-7-3-postgis-arm64`.
This document proposes a later implementation; it does not provision, publish,
deploy, change DNS, or certify a production service. M5.7.3A CI and the M5.7.3B
native ARM64 **isolated PoC** passed. No Oracle A1 or public Nokia 4G test has run.

## 1. Recommended topology and trust boundaries

```text
Nokia on 4G -- HTTPS/WSS :443 --> Caddy -- private edge network --> one Backend
                                           Backend -- private data network --> PostgreSQL/PostGIS
                                           Backend -- private routing network --> OSRM
                                           Backend -- HTTPS egress --> Photon demo (limited use)
Nokia -- HTTPS egress --> OpenFreeMap tiles (external service)
```

- Use one Backend process initially. Spring STOMP's simple broker and
  `TripSessionRegistry` live in process memory; multiple replicas would need a
  separately designed shared broker/session solution. REST/PostgreSQL remains
  the durable trip source. The existing inbound interceptor checks JWT, role,
  ownership and destination; outbound private ride frames check token expiry.
- Publish only Caddy's TCP 443 and TCP 80 (ACME challenge and redirect). Caddy
  serves one selected public hostname with an automatically renewed trusted
  certificate, persists `/data` and `/config`, and reverse-proxies both REST
  and `/ws` to the one Backend. Caddy handles WebSocket Upgrade without a
  second public port. [Caddy HTTPS](https://caddyserver.com/docs/automatic-https),
  [Caddy reverse proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy).
- Put Caddy and Backend on an edge Docker network; Backend/PostgreSQL on a
  private data network; Backend/OSRM on a private routing network. PostgreSQL,
  OSRM and Backend get **no host `ports` mapping**. Caddy alone reaches Backend.
  Use host firewall and OCI NSG/security rules as separate defenses. SSH, if
  needed, is restricted to an approved admin source/VPN; never open 8080,
  5000 or 5432 to the Internet. [OCI network security](https://docs.oracle.com/en-us/iaas/Content/Security/Reference/networking_security.htm).
- Reverse proxy only expected `/api/v1/*` and `/ws` paths. Return 404 for
  `/actuator/**`, `/swagger-ui/**`, `/v3/api-docs/**` and all other paths from
  outside. Keep readiness accessible only inside the private stack. Disable
  Swagger/API docs in the production Spring profile. The current Security
  configuration permits `/actuator/**` at the filter level, so proxy/network
  isolation is mandatory even though the local container profile exposes only
  health. Do not expose container port 8080 as a bypass.
- Set an explicit production `gomove.realtime.allowed-origins` containing the
  exact approved HTTPS origin(s), never `*`. Test the native Nokia handshake
  with and without an Origin header; Origin is not authentication. Keep STOMP
  JWT, per-destination ownership and outbound expiry checks. Configure a
  production forwarded-header strategy and test that Caddy overwrites or
  rejects untrusted client-supplied forwarding headers. Do not trust arbitrary
  upstream proxies. [Spring Boot 3.5 proxy guidance](https://docs.spring.io/spring-boot/3.5/how-to/webserver.html),
  [OWASP WebSocket guidance](https://cheatsheetseries.owasp.org/cheatsheets/WebSocket_Security_Cheat_Sheet.html).

## 2. What the repository currently proves

| Area | Evidence and gap |
| --- | --- |
| Local infrastructure | `compose.m572.yaml` pins local PostGIS and OSRM images; Backend binds only `127.0.0.1:18081`, and database/OSRM have no host ports. It has no Caddy or public profile. `docker-compose.yml` is a **development** database with a known password and published 5432; never use it for deployment. |
| Backend image | `backend/Dockerfile` pins Maven/Temurin 21 build and JRE images, runs UID 10001 and is verified by CI on AMD64. Both pinned base-image manifests contain `linux/arm64/v8` (read-only `docker buildx imagetools inspect` on 2026-11-05). The GoMove Backend image itself has **not** been built, started or load-tested on ARM64. |
| PostGIS | `infra/postgis-arm64/Dockerfile` built and ran on a native ARM64 GitHub runner; PostgreSQL 16.15, PostGIS 3.5.7, spatial smoke and Flyway V1–V18/8 spatial tests passed in [run 41993679729](https://github.com/chumanhquan102006-creator/goMove/actions/runs/41993679729). This was a fresh, disposable database, not a production image/volume upgrade. APT dependency resolution is not fully immutable; image vulnerability review and recovery testing remain open. |
| OSRM image | The pinned `ghcr.io/project-osrm/osrm-backend@sha256:55dbfd47d984c2cacd64e32901b4321c86b5ec761438e69aa053dc78698a786f` index contains `linux/arm64` and `linux/amd64` (manifest inspected 2026-11-05). It is from the [upstream OSRM image project](https://github.com/Project-OSRM/osrm-backend). ARM64 runtime with the **actual Hanoi dataset** has not been tested. |
| Hanoi dataset | `D:\GoMove-routing` has 26 prepared MLD `hanoi.osrm.*` files totaling 248,944,460 bytes (~237.4 MiB), plus a 26,370,112-byte source PBF. Local M5.7.2 mounts the prepared set read-only and starts `osrm-routed --algorithm mld`. Dataset source/version, extraction profile, generation command and checksums are not recorded in this repository. Prepare a transfer manifest; do not commit the dataset or assume cross-version compatibility. [OSRM MLD tools](https://github.com/Project-OSRM/osrm-backend/blob/master/docs/tools.md). |
| Spring configuration | `application.yml` defaults to `dev`, uses `${JWT_SECRET}` and defaults OSRM to localhost. `application-container.yml` imports file-backed secrets, disables Springdoc, exposes only health and uses localhost WebSocket origins. C2 needs an explicit production profile and reverse-proxy settings; never rely on the dev defaults. |
| Mobile | `AppConfig` converts an HTTPS `API_BASE_URL` to WSS `/ws` by default; real mode requires `MOCK_ENABLED=false`. Android release does not allow cleartext, but the current Gradle **release build uses the debug signing key**. That is acceptable only for a controlled demonstration APK, not a production-distribution claim. Verify a Nokia build uses the intended HTTPS host and WSS endpoint. |
| Third-party APIs | Backend geocoding defaults to the public Photon demo and has a per-account 30-request/60-second limit. Photon allows reasonable demo use but gives no uptime guarantee and may throttle heavy use. MapLibre loads public OpenFreeMap tiles, with required attribution and no SLA. Neither service should be described as self-hosted or guaranteed. [Photon policy](https://github.com/komoot/photon/blob/master/README.md), [OpenFreeMap terms](https://openfreemap.org/tos/). |
| Running environment | Docker Desktop's engine was unavailable during this C1 audit, so container RAM/CPU and live OSRM behavior were not measured. No existing service was started or changed. |

## 3. ARM64 sizing and cost decision

Oracle's current Always Free documentation describes the monthly A1 allowance
as **1,500 OCPU-hours and 9,000 GB-hours**, equivalent for an Always Free
tenancy to **2 OCPU/12 GB RAM** continuously, plus **200 GB total** block/boot
volume in the home region (a typical boot volume uses about 50 GB). A1 capacity
can be unavailable, and idle instances may be reclaimed. Verify the actual
tenancy and region before selecting a shape; do not assume an earlier 4/24 GB
allowance, a paid trial credit, or an upgrade to Pay As You Go is needed or
authorized. [OCI Always Free](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm).

For a **measurement starting point only**, budget roughly 2 GiB Backend,
2 GiB PostgreSQL, 2–3 GiB OSRM, under 256 MiB Caddy, and leave several GiB
for Linux, filesystem cache, WAL, backup and transient peaks. Set actual
container/JVM limits only after an ARM64 runtime benchmark. Build heavy images
in CI, not on the 2-OCPU VM. Measure startup RSS, peak memory, CPU, disk,
latency and failure recovery with the Hanoi dataset and representative traffic.
The dataset's disk size is not its runtime memory requirement.

Zero-cost deployment is conditional: resource eligibility/capacity, public IP,
DNS choice, egress, off-server backup destination, image registry visibility
and any extra volume/backup use must be reviewed against account quotas before
provisioning. Public GHCR packages currently have no usage charge; private
packages have plan-dependent limits. The user must choose package visibility
and set spending controls. [GitHub Packages billing](https://docs.github.com/en/packages/learn-github-packages/introduction-to-github-packages).

## 4. Hostname, TLS and network prerequisites

1. Preferred: an existing user-controlled domain/subdomain such as
   `api.<owned-domain>` with an A record to a stable OCI public IP. This needs
   no new domain purchase if one is already owned. A controlled free DNS
   subdomain is a possible alternative after its terms, stability and ACME
   support are verified. No hostname has been selected.
2. A raw public IP is not the selected production hostname: the planned Caddy
   configuration depends on a publicly trusted certificate for a DNS name.
   Do not assume Caddy's local/self-signed IP certificate is trusted by Nokia.
3. Caddy needs publicly reachable TCP 80 and 443 for normal HTTP-01/TLS-ALPN
   issuance and renewal, a persistent writable certificate data volume, and
   correct DNS. Only 443 serves the app; 80 is for ACME and redirect. Keep
   private service ports closed at OCI and host firewalls.

## 5. Production Compose/Caddy requirements for C2

Create a **separate** production Compose project, network and named database
volume. Do not reuse or migrate `gomove`, `gomove-midterm` or `gomove-m572`
volumes. Compose should specify immutable image digests, an explicit `prod`
Spring profile, one Backend replica, private service networks, PostGIS health,
an actual OSRM route probe, Backend DB readiness, and bounded restart policies.
Only Caddy has published ports. Mount the versioned Hanoi MLD set read-only;
persist PostgreSQL and Caddy certificate state. Apply CPU/memory/PID limits
after measurement; use non-root users, read-only filesystems, dropped
capabilities and `no-new-privileges` wherever startup and volume ownership
tests show they work. Do not weaken Postgres file permissions merely to force
non-root startup.

Keep database password and JWT signing key in owner-restricted host files
outside Git and images. Grant each Compose service only the secret it needs;
the Backend already supports Spring `configtree:/run/secrets/`, and the Postgres
image supports `POSTGRES_PASSWORD_FILE`. Do not put live values in `.env`,
Compose YAML, GitHub Actions logs, Flutter dart-defines or screenshots.
[Docker Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets).
Back up the secret files through a separately controlled encrypted channel;
losing the DB password or rotating the JWT key has operational consequences.

Caddy must maintain HTTPS/WSS, forward the original scheme/host/client address
only from the trusted edge, and never log JWT, request bodies or GPS payloads.
Use short log retention and limit path/identity exposure; Booking UUIDs and
location-related requests are sensitive. Verify unauthenticated/private API
responses are not cached. A Caddy reload can close existing WebSockets, so
test client reconnect and REST reconciliation.

## 6. Public security gates

- **Authorization/privacy:** Re-run real JWT, object-ownership, role, completed
  trip GPS masking and expired-subscription tests through the HTTPS/WSS proxy.
  A UUID or Origin header alone never grants access. Test unauthorized
  SUBSCRIBE/SEND and a refreshed-token reconnect. Existing logout revokes
  refresh tokens, while an issued access JWT can remain valid until its
  15-minute expiry; assess the accepted residual risk for active WebSockets.
- **Abuse/resource controls:** Current login lockout is per account and the
  geocoding limiter covers only geocoding. Define and test bounded public
  registration/login/refresh, Quote/OSRM, WebSocket connection/message and
  request-body rates/sizes before opening the API. Do not assume Caddy has a
  built-in per-IP rate limiter; select any extra component only after provenance
  review. [OWASP API risks](https://api-security.owasp.org/editions/2023/en/0x11-t10/),
  [OWASP WebSocket guidance](https://cheatsheetseries.owasp.org/cheatsheets/WebSocket_Security_Cheat_Sheet.html).
- **Exposure/supply chain:** External 404 for Actuator, Swagger and API docs;
  no public DB, OSRM or Backend port; no wildcard WebSocket origin or REST CORS.
  Scan the pinned Backend, PostGIS, OSRM and Caddy images and review findings,
  including PostGIS's mutable APT packages. Pin reviewed action SHAs and
  deployable images; record SBOM/digests before release.
- **External providers:** Bound Photon calls and handle failure; keep
  OpenFreeMap attribution and its fallback. Neither external provider has a
  production SLA in the current design. Avoid logging search terms or
  Customer/Driver coordinates.

## 7. Persistence, backup, restore and rollback

Use a persistent, isolated PostgreSQL volume with enough headroom for WAL and
growth. Before first public use, choose an **off-server** destination controlled
by the project owner. Proposed minimum: a daily `pg_dump -Fc` of the GoMove
database, encrypted before transfer; retain 7 daily and 4 weekly copies, with
hashes and failure alerts. This is a proposed policy, not an implemented job
or a measured RPO. Keep decryption keys separate from the VM and GitHub. Also
record required database roles/globals; `pg_dump` alone covers only one
database. Run a monthly isolated restore rehearsal and another before any
schema-changing release; verify PostGIS, Flyway history, key row counts and an
authorized smoke test. [PostgreSQL pg_dump](https://www.postgresql.org/docs/16/app-pgdump.html),
[pg_restore](https://www.postgresql.org/docs/16/app-pgrestore.html).

On deployment, validate Flyway checksums and pending migrations before
startup; never edit V1–V18 or run `flyway clean` against production. Take and
verify a pre-migration backup. Roll back the **application** by a previously
recorded image digest only when the migrated schema remains compatible.
Otherwise stop writes and use a reviewed forward fix or restore into an
isolated environment before switching service; a database restore can lose
writes newer than the backup. No automatic database rollback is promised.
[Flyway validation](https://documentation.red-gate.com/flyway/reference/commands/validate).

## 8. CI/CD proposal and exact C2 sequence

1. **Decisions and cost gate:** Project lead confirms an eligible A1 tenancy
   and home region, spending/quotas, hostname/DNS control, backup destination,
   acceptable test data, GHCR visibility and who may approve production. No
   resource is created by this document.
2. **Offline configuration:** Add `infra/deployment/compose.prod.yaml`, a
   Caddyfile and sample path-only environment file; add an explicit production
   Spring configuration file under `backend/src/main/resources/`. Review
   origins, forwarded headers, path allowlist, secrets, network isolation,
   health checks and resource limits. Keep application business logic intact.
   Validate Compose and Caddy syntax without touching local stacks.
3. **ARM64 release evidence:** Build and smoke-test the actual Backend ARM64
   image on a native runner. Re-review/pin the PostGIS PoC dependencies and
   scan all four images. Generate a manifest for the prepared Hanoi dataset,
   transfer it privately to an isolated ARM64 test target, verify checksums,
   then test OSRM route/nearest and resource use. Do not equate image-manifest
   support with runtime compatibility.
4. **Recovery rehearsal:** Provision a new disposable deployment database,
   exercise V1–V18, backup encryption, off-server transfer and restore into a
   second isolated database. Record RPO/RTO from the exercise and ensure no
   existing development volume is referenced.
5. **Publication gate:** Refactor or wrap existing CI/ARM checks so a release
   workflow has a verifiable dependency chain for the **same commit SHA**;
   previous unrelated runs alone are insufficient. On a protected reviewed
   ref, publish only approved images to GHCR tagged by commit SHA, record the
   immutable digest, use `contents:read` by default and `packages:write` only
   in the publish job. Do not use `latest` as deployment identity. Pin Actions
   to reviewed SHAs. [GHCR digests](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry),
   [Actions security](https://docs.github.com/en/actions/reference/security/secure-use).
6. **Manual initial deployment:** After separate approval, provision the
   reviewed A1 host, private volumes and host secrets; configure firewall,
   DNS and Caddy certificate; pull images **by digest**. Deploy manually
   first. Later CD may use a GitHub Environment with required reviewer,
   protected branch, deployment concurrency and narrowly scoped credentials.
   Check repository visibility and plan first: on GitHub Free/Pro/Team,
   required environment reviewers are available only for public repositories.
   If this repository is private on one of those plans, use a documented
   out-of-band approval and manual deployment instead of claiming an Actions
   reviewer gate exists.
   Do not give CI direct DB/JWT secrets or unrestricted root/Docker access.
   A Docker-group SSH user is effectively host-root and is not a safe default.
   No automatic deployment on push. [GitHub environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments).
7. **Public acceptance:** Test from Nokia on cellular data with Wi-Fi off:
   trusted HTTPS, WSS subscribe/reconnect/token expiry, Customer→Driver trip,
   GPS privacy, Quote via OSRM, CASH, image/health checks and negative auth
   paths. Confirm public 80/443 only; DB/OSRM/Actuator/docs unreachable.
   Measure ARM64 load/latency/memory and execute a rollback drill. Record
   exact results; no LAN test substitutes for this gate.

## 9. Readiness matrix at C1

| Prerequisite | Status | Reason |
| --- | --- | --- |
| M5.7.3A CI and M5.7.3B native PostGIS ARM64 PoC | **PASS** | Verified GitHub workflows; fresh test database only. |
| Backend base images and pinned OSRM image ARM64 manifests | **PASS (manifest only)** | All inspected manifests include `linux/arm64`; application/runtime evidence is separate. |
| Prepared local Hanoi MLD dataset | **PASS (local presence only)** | 26 files, 248,944,460 bytes; provenance/checksum manifest pending. |
| Backend ARM64 application image and OSRM Hanoi runtime | **NOT RUN** | No native app/dataset runtime test. Docker Desktop engine unavailable during this audit. |
| Oracle A1 entitlement, capacity, costs and host | **BLOCKED** | No tenancy/region selection or provisioning approval. |
| Public hostname, DNS, ACME and Nokia 4G | **BLOCKED** | No approved hostname, DNS or public host; no public E2E. |
| Production Compose, Caddy, origins, forwarded headers and firewall | **NOT RUN** | Production configuration does not yet exist. |
| Public rate/resource limits and image vulnerability review | **NOT RUN** | Existing geocoding limiter is not a general edge/WS control. |
| Persistent database backup, off-server encryption and restore | **BLOCKED** | No approved destination or recovery rehearsal. |
| GHCR publish and approval-gated CD | **NOT RUN** | CI is test-only; no images published or deployment job. |
| Mobile distribution signing and Profile/load measurements | **NOT RUN** | Release still uses debug key; performance unmeasured. |

**C1 conclusion:** architecture is plausible for a limited academic demo, but
public deployment is **BLOCKED** until the production configuration, security,
cost, recovery and 4G acceptance gates above are completed. This is a
planning checkpoint, not authorization to open a service or spend money.

# PostgreSQL 16 / PostGIS 3.5 ARM64 compatibility spike

This is an isolated test image, not a replacement for `compose.m572.yaml` or an approved production image. It has no initialization script: Flyway V1 creates `postgis` in each new application database. The GoMove migrations use the core `postgis` extension and `GEOGRAPHY(Point,4326)`; they do not create raster, topology, tiger geocoder or protobuf extensions. Those optional components are disabled in this build.

## Provenance and choice

| Option | Finding |
| --- | --- |
| Existing `postgis/postgis@sha256:94146ac...` | Its manifest contains `linux/amd64` only. The PostGIS image project also documents AMD64 as its supported architecture; the `16-3.5` tag is no longer updated. It cannot be used as a native ARM64 image. |
| PGDG package on the official PostgreSQL base | The current `bookworm-pgdg` ARM64 index offers PostGIS 3.6/3.7, not 3.5. Installing the unpinned candidate would silently change the PostGIS minor version. |
| This source build | Starts from the multi-architecture Docker Official Image `postgres:16.15-bookworm@sha256:e8a07d2c...`. The official PostGIS 3.5.7 tarball is downloaded from OSGeo and checked against SHA-256 `af9ab591854d52a0d1115f90b797ef1cd60d01b85a11ff813073689e332272ff`, independently computed from the downloaded tarball. Build tools stay in the builder stage; the runtime stage contains only the extension artifacts and required shared libraries. |
| Other prebuilt images | Not selected: no third-party publisher, provenance, update policy and ARM64 manifest have been reviewed to the same standard. |

The Dockerfile pins the PostgreSQL base digest, PostGIS source hash, PostgreSQL development package, and GEOS/PROJ package versions. `libjson-c`, `libxml2` and transitive APT packages still resolve from current signed Debian/PGDG indexes. Therefore rebuilds are **source-verified but not bit-for-bit reproducible**; a dated package snapshot or a reviewed, checksum-locked package manifest is needed before production use. Rebuild and review the image for security updates rather than treating an old digest as permanently secure.

Sources: [Docker PostGIS project](https://github.com/postgis/docker-postgis), [Docker Official PostgreSQL image metadata](https://github.com/docker-library/official-images/blob/master/library/postgres), [PostGIS 3.5 source](https://postgis.net/development/source_code/), [PostGIS build options](https://postgis.net/docs/manual-3.5/en/postgis_installation.html), [PGDG APT](https://wiki.postgresql.org/wiki/Apt).

## Evidence from the 2026-11-05 local run

| Check | Result |
| --- | --- |
| Host architecture | `linux/x86_64` (Docker Desktop 29.6.1). |
| Official PostgreSQL base manifest | `linux/arm64/v8` present; pinned index digest inspected. |
| Existing M5.7.2 PostGIS manifest | ARM64 absent. |
| Official PostgreSQL ARM64 base runtime | `docker run --platform linux/arm64 ... uname -m` printed `aarch64` under emulation. This is **not native ARM64**. |
| PoC ARM64 build on local builder | **FAIL** at first `RUN`: `exec /bin/sh: exec format error` (exit 1). The separate `docker-container` builder reported AMD64 platforms only and was removed with `--keep-state`; no ARM64 PoC image was produced locally. |
| PoC AMD64 build | **PASS**, exit 0; image `linux/amd64`, size 179,148,340 bytes. |
| PoC AMD64 runtime and spatial smoke | **PASS** in a fresh container with no network or host port and tmpfs data: PostgreSQL 16.15 healthy, PostGIS 3.5.7 loaded, geography distance/radius and GiST checks passed. The temporary container was stopped; no existing service or volume was touched. |
| AMD64 Testcontainers + Flyway | **PASS**, `./mvnw.cmd ... clean test` exit 0: 8 tests, 0 failures/errors/skips. Surefire confirms image `gomove-postgis35-spike:amd64`; Flyway applied all 18 migrations to fresh `public`, ending at V18. |
| Default Backend regression suite | **PASS**, `./mvnw.cmd -B -ntp clean test` exit 0: 180 tests, 0 failures/errors/skips, `BUILD SUCCESS` (2026-11-05). It used the original `postgis/postgis:16-3.5` image. |
| Native ARM64 image build, health, PostGIS, Flyway and spatial tests on this Windows host | **NOT RUN locally**. The native GitHub runner evidence is recorded below. |

The PoC-specific AMD64 run used only the two spatial test classes. The full regression run used the default image and does not validate the ARM64 image. No public image was pushed, and no development database was reused or migrated.

## Native ARM64 validation path

The test-only [PostGIS ARM64 spike workflow](../../.github/workflows/postgis-arm64-spike.yml) is restricted to pushes of `feature/m5-7-3-postgis-arm64`. It uses GitHub's `ubuntu-24.04-arm` runner, builds without publishing, checks image and container architecture, starts a new private tmpfs PostgreSQL instance, executes [smoke.sql](smoke.sql), then runs the two existing spatial integration classes against a **new Testcontainer** built from the PoC image. The `BaseIntegrationTest` override is opt-in; all other tests retain their existing image by default.

## Native ARM64 acceptance evidence — 2026-11-05

The committed spike at `ddffd3e9529c4d530129cb672ade9332e7b1b36d` ran on GitHub's native ARM64 runner. [Run 41993679729](https://github.com/chumanhquan102006-creator/goMove/actions/runs/41993679729) completed successfully. Its runner-architecture check, `linux/arm64` image build, image/runtime architecture and health checks, spatial smoke, and ARM64 Testcontainers job steps all passed. The job log reports PostgreSQL `16.15 (Debian 16.15-1.pgdg12+2)`, `POSTGIS="3.5.7 9816f82"`, Flyway successfully applying 18 migrations to fresh `public` at V18, and Maven `Tests run: 8, Failures: 0, Errors: 0, Skipped: 0; BUILD SUCCESS`.

The separate [regular CI run 41993679733](https://github.com/chumanhquan102006-creator/goMove/actions/runs/41993679733) also completed successfully: Backend tests, Flutter analyze/tests and the AMD64 Backend Docker build all passed. These are GitHub Actions results for the committed checkpoint, not a production deployment or an Oracle A1 runtime test.

The isolated PostgreSQL 16.15/PostGIS 3.5.7 ARM64 PoC is accepted. Production readiness remains **unverified**: some APT packages and transitive dependencies are not pinned to an immutable snapshot; no Oracle Ampere A1 runtime, production backup/restore, public HTTPS/WSS or production load test has been performed. No image was published, no application database was reused, and no deployment was performed. Do not connect this image to an existing PostgreSQL data directory; plan a separately validated backup and dump/restore procedure before any migration.

The standard public-repository ARM64 runner currently provides 4 vCPUs, 16 GB RAM and 14 GB SSD. The source build completed there, but peak disk and memory use were not measured. The spike uses `make -j2` and caps its private smoke container at 1 GB/2 CPUs. The current M5.7.2 image uses a different Debian/glibc and PostGIS version, so successful fresh-database tests do not establish in-place data-directory compatibility.

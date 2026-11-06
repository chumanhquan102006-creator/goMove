# M5.7.3C2B-H1: local Hanoi OSRM dataset validation

Status on 2026-11-06: **local AMD64 runtime PASS with a permission caveat; native Hanoi ARM64 NOT RUN**. This is an isolated data/runtime check, not production deployment acceptance.

## Scope and source

- Git starting point: `57e6dc38e8452ddc82b01170b07f3847ddab05da` on `feature/m5-7-3-runtime-validation`. H1 branch: `feature/m5-7-3-hanoi-osrm-validation`. The unrelated pre-existing untracked file is untouched.
- `backend/docs/m572-docker.md` and `compose.m572.yaml` refer to the existing `D:\GoMove-routing` directory. `infra/deployment/compose.prod.yaml` expects the same prepared MLD base path as `/data/hanoi.osrm`. The local directory was inspected, never preprocessed or edited.
- The source PBF header contains `writingprogram=https://download.BBBike.org`, a replication timestamp of `2026-10-26 00:00:00 UTC`, and a bounding box of longitude `105.289`–`106.020`, latitude `20.565`–`21.382`. This supports BBBike/OSM provenance and Hanoi coverage, but the original download URL, extract request, exact polygon, profile file, preprocessing command and source checksum published by BBBike are **not recorded**. Do not infer them from the filename.
- [BBBike's extract page](https://download.bbbike.org/) identifies its extracts as OpenStreetMap data under ODbL. [OpenStreetMap's copyright page](https://www.openstreetmap.org/copyright) requires attribution and makes the ODbL terms explicit. No separate license or redistribution note was found in this local directory. Before distributing the PBF or prepared routing database, confirm attribution and any ODbL derived-database obligations; H1 uploaded nothing.

## Dataset inventory and integrity

- `D:\GoMove-routing`: 26 `hanoi.osrm.*` sidecars, **248,944,460 bytes**, plus `hanoi.osm.pbf`, **26,370,112 bytes**. Total: **275,314,572 bytes**.
- Required MLD sidecars are present: `.cells` (576,512 bytes), `.partition` (5,106,176 bytes), `.mldgr` (30,901,760 bytes), and `.fileIndex` (19,732,300 bytes).
- There is no physical `hanoi.osrm` file. [Upstream OSRM documentation](https://github.com/Project-OSRM/osrm-backend#using-docker) explicitly says `.osrm` is the **base path** for multiple `.osrm.*` files and need not exist as a file. The runtime result below confirms this directory is loadable.
- Per-file SHA-256 values, including the source PBF, are in [h1-hanoi-dataset.sha256](h1-hanoi-dataset.sha256). The manifest has 27 entries and SHA-256 `694b6c8e404875fdc21dcb9a63b1e67d8075a91f520314152c02dd19100ad6bd`. Key hashes: PBF `f9cdf160af9861f15cca77c57b047e080edd476ac9100aa6f49abd03daedf715`; `.cells` `1386640a5cdda3b213f4d22d394b56bbfa6d05fb3366ba456b44505ac20f58dd`; `.partition` `f1cabbc4b02df7b57e3513e5ee37546d043abf879c472e801dc3d4cd89fee87d`; `.mldgr` `1b40d6d8ca82479f728456bc5c5a6056c510a1491932b0463bbc423f0314bd46`; `.fileIndex` `8351db7fb4b9dda8bcbdda1c306be7e75d5219af1375a0299ba32ab277d4f55a`.
- All 26 source sidecar hashes were unchanged after the test. The disposable Linux volume copy matched every source sidecar SHA-256 before being used and was removed afterward.

## Isolated Docker Desktop x86_64 runtime

Command, exit code **0**:

```powershell
python infra\deployment\test_h1_hanoi_osrm_local.py --data-dir 'D:\GoMove-routing' --expect-arch amd64
```

The test used the existing pinned OSRM index `ghcr.io/project-osrm/osrm-backend@sha256:55dbfd47d984c2cacd64e32901b4321c86b5ec761438e69aa053dc78698a786f`. Local image architecture was `linux/amd64`; `osrm-routed --version` reported **v26.10.0**. The locally cached test client image ID was `sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` (the client was not pulled during this test).

| Check | Result |
| --- | --- |
| Original NTFS directory bind mounted read-only; OSRM ran with image default root user | **PASS**: MLD loaded and HTTP route returned `code=Ok` |
| Route `105.834,21.028` → `105.84,21.03` (longitude, latitude) | **PASS**: 950.4 m; 109.3 s, plausible for this pair |
| Original NTFS read-only bind under UID/GID 10001 | **FAIL**: `hanoi.osrm.fileIndex` appears as mode `0700`, owned by root inside Docker Desktop; `test -r` exited 1. `.cells`, `.partition`, `.mldgr` were readable. The Windows directory ACL permits `BUILTIN\Users` read and execute; Docker's translated Unix mode for `.fileIndex` is the blocker. |
| Byte-identical temporary Linux volume copy with read permission for UID 10001 | **PASS**: all 26 SHA-256 values match; OSRM served the same 950.4 m / 109.3 s route with UID/GID 10001 |
| Startup to first successful route | 1.47 s direct-root; 0.92 s UID 10001 volume copy, on this warmed local machine only |
| `docker stats --no-stream` observation | Direct-root: 0.00% CPU, 160.8 MiB / 7.609 GiB; UID 10001 copy: 0.00% CPU, 162.4 MiB / 7.609 GiB. These idle snapshots are **not** sizing or load-test evidence. |
| Isolation and cleanup | **PASS**: unique `gomove.h1` labels/names, internal network, no host port, read-only dataset mounts; only matching H1 container/network/volume IDs were removed. Existing GoMove/Midterm containers and volumes were not targeted. |

A separate strict negative check used `--require-direct-nonroot`; it exited **1** on the known NTFS `.fileIndex` denial and still removed its own network. This ensures the native ARM64 procedure cannot silently accept a failed direct UID 10001 mount. The production Compose `osrm` service is configured as UID/GID 10001 with a read-only bind; this Windows NTFS directory cannot be assumed to work with that configuration as-is. The local Linux volume result demonstrates a permission remedy on a disposable copy, not a change to the original data.

## Manual native ARM64 validation, after separate approval

1. Choose an isolated **native** ARM64 Linux host with sufficient spare RAM and storage; confirm `uname -m` is `aarch64` and `docker info --format '{{.Architecture}}'` reports `aarch64` or `arm64`. Do not use QEMU/emulation as native evidence. Do not create an Oracle VM as part of H1.
2. After explicit approval, transfer the **26 prepared MLD sidecars** through a private encrypted channel directly to a dedicated host directory. The source PBF is not needed for routing and should be transferred only if separately required for provenance or a rebuild. Do **not** use GitHub Actions artifacts, GitHub repository, GHCR, third-party file storage or a production volume. Preserve original local files. Record the transfer method and the source extract URL/provenance separately. The checksum manifest contains hashes, not map data, and may accompany the deployment code.
3. On the ARM64 host, in the transferred dataset directory, verify **26/26** sidecar checksums with `grep '  hanoi\.osrm\.' /path/to/h1-hanoi-dataset.sha256 | sha256sum -c -`; if the PBF was also transferred, use `sha256sum -c /path/to/h1-hanoi-dataset.sha256` and require **27/27 OK**. Verify the intended absolute path with `realpath` and confirm all 26 sidecars exist. Check host permissions/ACLs. The direct bind must allow UID/GID 10001 to read **all** sidecars, especially `.fileIndex`; if permissions need adjustment, change **only the transferred isolated copy**, never the Windows original or an existing production dataset.
4. Pull/review the pinned OSRM multiarchitecture index above and a separately reviewed/pinned Alpine test-client image. Verify `docker image inspect ... --format '{{.Os}}/{{.Architecture}}'` returns `linux/arm64` for both; record the resolved ARM64 manifest digests and `osrm-routed --version`. Pre-cache both images; the H1 runner uses `--pull never`.
5. Run the checked-in H1 runner on the ARM64 host with `--data-dir /absolute/isolated/hanoi --expect-arch arm64 --require-direct-nonroot --client-image <reviewed-pinned-alpine-digest>`. It creates a uniquely labeled internal network and temporary container/volume, publishes no host port, probes the real route, verifies all copied hashes, records startup/resource observations and cleans only its own labeled resources. Require exit code **0** and separately verify no `gomove.h1` resources remain.
6. Record full command output, image/platform IDs, all transferred-file checksum results, dataset permissions, route distance/duration, health, CPU/RAM under a representative load and cleanup evidence. Only then may **Hanoi dataset on native ARM64** be marked PASS. The local AMD64 result does not establish cross-architecture route quality or Oracle A1 capacity.

## Remaining blockers

- **NOT RUN:** actual Hanoi dataset on native ARM64; no approved host or private transfer was used.
- **BLOCKED for direct Windows production-style bind:** UID 10001 cannot read NTFS-translated `.fileIndex`. Verify and correct permissions on a separately transferred Linux copy before using the production Compose bind.
- **NOT VERIFIED:** exact PBF download URL/bounding area, OSRM extraction profile/commands, comprehensive route coverage, representative load, Oracle A1 storage/RAM and public HTTPS/WSS or Nokia 4G E2E.
- Production image vulnerability approval, backup/restore and public deployment remain separate C2B/C2C work. No database or existing Docker state was changed by H1.

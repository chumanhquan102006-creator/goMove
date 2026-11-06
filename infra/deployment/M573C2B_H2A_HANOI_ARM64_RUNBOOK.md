# M5.7.3C2B-H2A Hanoi OSRM ARM64 preflight

## Evidence and scope

| Check | Status | Evidence |
| --- | --- | --- |
| ASUS source dataset | **PASS** | `D:\GoMove-routing` matches the H1 manifest, 27/27 SHA-256. Inventory is 26 MLD sidecars (248,944,460 bytes) and one source PBF (26,370,112 bytes). |
| Pinned image platform | **PASS** | GHCR OCI index `sha256:55dbfd47d984c2cacd64e32901b4321c86b5ec761438e69aa053dc78698a786f` lists `linux/arm64` child `sha256:b0045097b8b4ad5e72dce6b900326cd6ee0e98c729709214e674d0472b463f49`. Verified with `docker buildx imagetools inspect --raw`. |
| Runner and command examples | **PASS (offline)** | Python, Bash, PowerShell and OpenSSH config checks passed. Mocked Docker checks covered the route, architecture and mount rejection, direct read denial, and cleanup ownership. The runner rejected Windows with exit code 1 before Docker. |
| Windows direct UID 10001 bind | **FAIL (H1)** | Docker Desktop exposed `hanoi.osrm.fileIndex` as `root:root` mode `0700`. H1 served the real dataset on AMD64 through a direct root mount and a separate non-root Linux volume copy. |
| ASUS → ARM64 transfer | **NOT RUN** | Requires separate approval for a specific host and recipient. |
| Real Hanoi on native ARM64 | **NOT RUN** | H1 AMD64 and C2B synthetic ARM64 evidence cover different cases. H2A prepares the exact direct bind test. |

The input path `/data/hanoi.osrm` is a base name for the sidecars. The [H1 evidence](M573C2B_H1_HANOI_OSRM_EVIDENCE.md) describes the 26-file MLD inventory, pinned image and reference route (950.4 m, 109.3 s on AMD64). Use the H2A runner below for the native check. It opens all 27 files and starts OSRM in the same container as UID/GID `10001:10001`.

The PBF header identifies BBBike as the writing program. Keep the available source and timestamp record, and confirm the exact extract provenance before broader reuse or redistribution. BBBike identifies its OSM extracts as ODbL data. Credit `© OpenStreetMap contributors` in public routing services and apps that use them. Keep attribution and the ODbL notice with any distributed database, and review ODbL share-alike obligations for the derived routing database before distributing it. Keep this test transfer private. [BBBike extract licensing](https://download.bbbike.org/) · [OSM copyright and ODbL](https://www.openstreetmap.org/copyright) · [OSMF routing attribution guidance](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines#Routing_engines).

## Prerequisites for a future authorized run

- Obtain explicit approval for the host, recipient/account, 27 source files, incoming and test paths, and retention period. Record the host public key fingerprint through a trusted channel independent of SSH. Use a private, isolated host with the approved SSH endpoint already available.
- Verify the host is native ARM64 Linux and `uname -m` reports `aarch64`. Use a local Docker Engine with its Unix socket at `/var/run/docker.sock`. Its architecture must be `aarch64` or `arm64`. Use a Docker CLI/Engine supporting `--mount` with `bind-recursive=disabled`. The runner uses that local socket and refuses `DOCKER_HOST` or `DOCKER_CONTEXT` overrides.
- Use a local Linux filesystem with POSIX ownership and mode support, such as ext4 or XFS. Reserve at least 550,629,144 bytes for both the incoming files and isolated copy, plus space for the pinned image and logs. Confirm the host has spare RAM for the run. H1 idle measurements are reference observations.
- Have OpenSSH on ASUS and the approved host, Python 3 on Linux, Bash and GNU utilities (`sha256sum`, `stat`, `install`, `realpath`), and an authorized Linux operator with access to the local Docker socket and the dataset. Use a reviewed checkout with the H2A runner and the unchanged [H1 manifest](h1-hanoi-dataset.sha256) on both machines.

## Transfer from ASUS after approval

1. From the host console, the administrator obtains the public key and fingerprint with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256`. Obtain both through the trusted channel. On ASUS, save exactly one matching entry `gomove-h2a-hostkey ssh-ed25519 <approved public key blob>` in a dedicated `known_hosts` file outside Git. Compare its SHA-256 fingerprint using `ssh-keygen -lf <known_hosts file> -E sha256`. Stop on an unknown or changed fingerprint and reverify it through the trusted channel.
2. On the Linux host, as the dedicated transfer operator, set `umask 077` and create an empty staging directory with `mktemp -d "$HOME/gomove-h2a-incoming.XXXXXXXX"`. Record the exact returned path. The directory is private to that operator (mode `0700`). Keep incoming and test copies outside any repository and existing service path.
3. On ASUS, put the following OpenSSH configuration in `%USERPROFILE%\.ssh\gomove-h2a.conf`. Replace every placeholder with an approved value. Keep the client key and SSH configuration outside Git. Load the key in an agent if it requires a passphrase. Use direct SFTP over SSH with the pinned host key.

~~~ssh-config
Host gomove-h2a-arm64
    HostName <approved private host>
    Port <approved SSH port>
    User <approved transfer operator>
    HostKeyAlias gomove-h2a-hostkey
    HostKeyAlgorithms ssh-ed25519
    StrictHostKeyChecking yes
    UserKnownHostsFile "C:/Users/<operator>/.ssh/gomove-h2a.known_hosts"
    GlobalKnownHostsFile "C:/Users/<operator>/.ssh/gomove-h2a.known_hosts"
    VerifyHostKeyDNS no
    UpdateHostKeys no
    IdentityFile "C:/Users/<operator>/.ssh/<dedicated private key filename>"
    IdentitiesOnly yes
    PreferredAuthentications publickey
    BatchMode yes
    ForwardAgent no
    ClearAllForwardings yes
~~~

4. After confirming the destination, run this PowerShell block on ASUS. The batch sends only manifest-listed files and aborts on an SFTP error. Use the approved private channel for all 27 files. Keep map data out of sharing links, Git, GitHub Actions artifacts and third-party storage. Keep passwords, keys and tokens outside Git and logs.

~~~powershell
$ErrorActionPreference = 'Stop'
$h2aSource = 'D:\GoMove-routing'
$h2aManifest = 'D:\goMove\infra\deployment\h1-hanoi-dataset.sha256'
$h2aStage = '<exact approved incoming directory>'
$h2aSshConfig = Join-Path $env:USERPROFILE '.ssh\gomove-h2a.conf'
if ($h2aStage -cnotmatch '^/[A-Za-z0-9._/-]+/gomove-h2a-incoming\.[A-Za-z0-9]{8}$' -or
    ($h2aStage -split '/') -contains '..') { throw 'Set the exact approved staging path' }

$h2aNames = [System.Collections.Generic.List[string]]::new()
foreach ($line in Get-Content -LiteralPath $h2aManifest) {
    if ($line -cnotmatch '^([a-f0-9]{64})  (hanoi\.(?:osm\.pbf|osrm\.[A-Za-z0-9_]+))$') {
        throw 'Invalid manifest entry'
    }
    $digest = $Matches[1]
    $name = $Matches[2]
    if ($h2aNames.Contains($name)) { throw "Duplicate manifest entry: $name" }
    $file = Get-Item -LiteralPath (Join-Path $h2aSource $name) -Force
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a regular file: $name"
    }
    if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $digest) {
        throw "SHA-256 mismatch: $name"
    }
    $h2aNames.Add($name)
}
if ($h2aNames.Count -ne 27 -or !$h2aNames.Contains('hanoi.osm.pbf')) {
    throw 'Expected the 26 sidecars and source PBF'
}

$h2aBatch = New-TemporaryFile
try {
    $commands = @('lcd "D:/GoMove-routing"', ('cd "{0}"' -f $h2aStage))
    $commands += @($h2aNames | ForEach-Object { "put $_" })
    $commands | Set-Content -LiteralPath $h2aBatch.FullName -Encoding ascii
    & sftp.exe -F $h2aSshConfig -b $h2aBatch.FullName gomove-h2a-arm64
    if ($LASTEXITCODE -ne 0) { throw "SFTP exited $LASTEXITCODE" }
}
finally {
    Remove-Item -LiteralPath $h2aBatch.FullName
}
~~~

## Verify and seal the Linux copy

After the SFTP session closes, run as the same trusted operator on the isolated Linux host. Keep other writers out of the staging directory. Use the manifest from the independently reviewed checkout, verify **27/27** incoming files, and only then create the isolated copy. Apply the numeric group `10001` to that copy and grant only directory traversal and file reads to the container identity.

~~~bash
set -euo pipefail
repo='/absolute/path/to/reviewed/goMove'
stage='/home/<operator>/gomove-h2a-incoming.<approved-suffix>'
manifest="$repo/infra/deployment/h1-hanoi-dataset.sha256"

[[ "$stage" == "$HOME"/gomove-h2a-incoming.* ]]
[[ "$(realpath -e -- "$stage")" == "$stage" ]]
[[ "$(stat -c '%u:%a' -- "$stage")" == "$(id -u):700" ]]
[[ "$(find "$stage" -mindepth 1 -maxdepth 1 -printf . | wc -c)" -eq 27 ]]
names=()
while read -r digest name; do
    [[ "$digest" =~ ^[a-f0-9]{64}$ && "$name" =~ ^hanoi\.(osm\.pbf|osrm\.[A-Za-z0-9_]+)$ ]]
    path="$stage/$name"
    [[ -f "$path" && ! -L "$path" && "$(stat -c '%h' -- "$path")" == 1 ]]
    names+=("$name")
done < "$manifest"
[[ "${#names[@]}" -eq 27 ]]
(cd -- "$stage" && sha256sum --strict --check -- "$manifest")

dataset="$(sudo mktemp -d /srv/gomove-h2a-hanoi.XXXXXXXX)"
printf 'H2A copy: %s\n' "$dataset"
for name in "${names[@]}"; do
    sudo install -o root -g 10001 -m 0440 -- "$stage/$name" "$dataset/$name"
done
sudo chown root:10001 -- "$dataset"
sudo chmod 0750 -- "$dataset"
findmnt -T "$dataset" -o TARGET,SOURCE,FSTYPE,OPTIONS
sudo bash -c 'cd -- "$1" && sha256sum --strict --check -- "$2"' h2a "$dataset" "$manifest"
~~~

Record both checksum results. Confirm `root:10001` mode `0750` for the directory and `root:10001` mode `0440` for the 27 files. If user namespace mapping or a filesystem security policy prevents reads, resolve access for the isolated copy and recheck under UID/GID 10001. The script treats a denial as a failure. Keep the original ASUS files and any existing service data directories outside these permission changes. [Docker bind mount behavior](https://docs.docker.com/engine/storage/bind-mounts/).

## Native ARM64 verification

Run this on the approved ARM64 host with the reviewed `repo` and `dataset` paths from the previous step. Obtain the pinned ARM64 child from GHCR in advance. The runner uses the local cache.

~~~bash
set -euo pipefail
test "$(uname -m)" = aarch64
osrm_image='ghcr.io/project-osrm/osrm-backend@sha256:b0045097b8b4ad5e72dce6b900326cd6ee0e98c729709214e674d0472b463f49'
sudo docker --host unix:///var/run/docker.sock info --format '{{.OSType}}/{{.Architecture}}'
sudo docker --host unix:///var/run/docker.sock pull --platform linux/arm64 "$osrm_image"
sudo docker --host unix:///var/run/docker.sock image inspect "$osrm_image" --format '{{.Os}}/{{.Architecture}} {{.Id}}'
sudo python3 -B "$repo/infra/deployment/verify_hanoi_osrm_arm64.py" --data-dir "$dataset"
~~~

Capture exit code and output. For PASS, require all 27 SHA-256 values to match before and after, a single inspected container with the pinned image, a successful file open under UID/GID 10001, and HTTP 200 with `code=Ok` on the Hanoi route from `105.834,21.028` to `105.84,21.03`. Record OSRM version, actual distance and duration, seconds from container start to the successful route, and CPU/RAM from the post-route `docker stats` sample. Report the actual sample as observed on that host.

The runner uses a unique `gomove-h2a-osrm-<token>` name and label `io.gomove.h2a.run=<token>`. It checks the container before starting it. The only mount is the exact dataset at `/data` in read-only mode, with submounts excluded. Docker `none` networking leaves an internal loopback for the HTTP probe. The runner publishes no host ports and creates no Docker networks or volumes. [Docker none network](https://docs.docker.com/engine/network/drivers/none/).

## Rollback and cleanup

- On transfer or hash failure, stop before runtime and keep the rejected files in the private staging directory until reviewed. Retry into a new empty staging directory after resolving the failure. The original ASUS source remains the checksum reference.
- On normal exit or handled failure, the runner stops and removes its container only after checking the full ID, exact name and exact run label. Confirm the runner reported removal. On an interruption or daemon failure, recover the full ID from the log or with `sudo docker --host unix:///var/run/docker.sock container ls --all --no-trunc --filter "label=io.gomove.h2a.run=<exact token>"`. If the result is ambiguous, stop and investigate. For a remaining container, compare all three identities before both mutations.

~~~bash
set -euo pipefail
run_token='<recorded 32-character token>'
container_id='<verified full 64-character container ID>'
[[ "$run_token" =~ ^[a-f0-9]{32}$ && "$container_id" =~ ^[a-f0-9]{64}$ ]]
d=(sudo docker --host unix:///var/run/docker.sock)
check_owner() {
    local actual
    actual="$("${d[@]}" container inspect --format '{{.Id}} {{.Name}} {{index .Config.Labels "io.gomove.h2a.run"}}' "$container_id")"
    [[ "$actual" == "$container_id /gomove-h2a-osrm-$run_token $run_token" ]]
}
check_owner
running="$("${d[@]}" container inspect --format '{{.State.Running}}' "$container_id")"
if [[ "$running" == true ]]; then
    "${d[@]}" container stop --time 5 "$container_id"
fi
check_owner
"${d[@]}" container rm "$container_id"
"${d[@]}" container ls --all --no-trunc --filter "label=io.gomove.h2a.run=$run_token"
~~~

- When approved retention ends, confirm the recorded staging and test paths with `realpath`, ownership and contents. Remove only the manifest-listed files within those exact paths and finish with `rmdir` on the now empty directories. Investigate unexpected contents without recursive deletion. Revoke any temporary transfer access per the approved plan. Leave the existing GoMove, Midterm and M5.7.2 resources out of cleanup.

OpenSSH's strict mode rejects unknown and changed host keys, and SFTP batch mode aborts on a failed `put` or `cd`. [OpenSSH host key checks](https://man.openbsd.org/ssh_config#StrictHostKeyChecking) · [OpenSSH SFTP batch mode](https://man.openbsd.org/sftp#-b).

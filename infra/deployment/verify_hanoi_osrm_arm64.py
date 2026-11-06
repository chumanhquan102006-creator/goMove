"""Run the real Hanoi MLD smoke on an approved, native ARM64 Linux host."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
import uuid


MANIFEST = Path(__file__).resolve().with_name("h1-hanoi-dataset.sha256")
# linux/arm64 child of the OSRM index pinned in compose.prod.yaml.
IMAGE = "ghcr.io/project-osrm/osrm-backend@sha256:b0045097b8b4ad5e72dce6b900326cd6ee0e98c729709214e674d0472b463f49"
DOCKER = ("docker", "--host", "unix:///var/run/docker.sock")
USER = "10001:10001"
RUN_LABEL = "io.gomove.h2a.run"
ROUTE = "/route/v1/driving/105.834,21.028;105.84,21.03?overview=false"
STARTUP_TIMEOUT = 60
REQUIRED_FILES = {
    "hanoi.osm.pbf",
    "hanoi.osrm.cells",
    "hanoi.osrm.partition",
    "hanoi.osrm.mldgr",
    "hanoi.osrm.fileIndex",
}

READ_AND_START = r"""
if [[ $EUID != 10001 || $(id -g) != 10001 ]]; then
    echo 'Expected UID/GID 10001' >&2
    exit 1
fi
for name in "$@"; do
    file="/data/$name"
    if [[ ! -f "$file" || -L "$file" ]] || ! : < "$file"; then
        printf 'UID 10001 cannot open %s\n' "$file" >&2
        exit 1
    fi
done
printf 'UID 10001 opened all %s files on the direct bind mount\n' "$#"
exec osrm-routed --algorithm mld --ip 127.0.0.1 --port 5000 /data/hanoi.osrm
"""

# Use Bash from the pinned OSRM image. The network namespace only has loopback.
PROBE = r"""
{ exec 3<>/dev/tcp/127.0.0.1/5000; } 2>/dev/null || exit 10
printf 'GET %s HTTP/1.0\r\nHost: 127.0.0.1:5000\r\nConnection: close\r\n\r\n' "$1" >&3 || exit 11
status=0
LC_ALL=C IFS= read -r -d '' -n 16384 -t 3 response <&3 || status=$?
[[ $status == 1 && -n $response ]] || exit 11
printf '%s' "$response"
"""


def run(args, *, check=True, timeout=15):
    result = subprocess.run(args, capture_output=True, timeout=timeout)
    if check and result.returncode:
        error = result.stderr.decode("utf-8", errors="replace").strip()
        command = " ".join(args[3:5]) if args[:3] == DOCKER else " ".join(args[1:])
        raise RuntimeError(f"{args[0]} {command} exited {result.returncode}: {error}")
    return result


def docker(*args, **kwargs):
    return run((*DOCKER, *args), **kwargs)


def read_manifest():
    files = {}
    for line in MANIFEST.read_text(encoding="ascii").splitlines():
        entry = re.fullmatch(r"([0-9a-f]{64})  (hanoi\.(?:osm\.pbf|osrm\.[A-Za-z0-9_]+))", line)
        if not entry:
            raise ValueError("Invalid H1 checksum manifest entry")
        digest, name = entry.groups()
        if name in files:
            raise ValueError(f"Duplicate H1 checksum entry: {name}")
        files[name] = digest
    if len(files) != 27 or not REQUIRED_FILES <= files.keys():
        raise ValueError("Expected the H1 inventory of 26 MLD sidecars and one source PBF")
    return files


def verify_dataset(directory, files):
    if {item.name for item in directory.iterdir()} != files.keys():
        raise ValueError("Dataset directory must contain exactly the 27 files in the H1 manifest")
    for name, expected in files.items():
        path = directory / name
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError(f"Expected a regular file with one link: {name}")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != expected:
            raise ValueError(f"SHA-256 mismatch: {name}")


def native_host():
    if sys.platform != "linux" or run(("uname", "-m")).stdout.strip() != b"aarch64":
        raise RuntimeError("Run on native ARM64 Linux with uname -m = aarch64")
    if os.environ.get("DOCKER_HOST") or os.environ.get("DOCKER_CONTEXT"):
        raise RuntimeError("Unset DOCKER_HOST and DOCKER_CONTEXT for this local verification")
    if not stat.S_ISSOCK(Path("/var/run/docker.sock").stat().st_mode):
        raise RuntimeError("Expected the local Docker Engine socket at /var/run/docker.sock")


def local_image():
    engine = docker("info", "--format", "{{.OSType}}/{{.Architecture}}").stdout.decode().strip()
    if engine not in ("linux/aarch64", "linux/arm64"):
        raise RuntimeError(f"Expected local ARM64 Docker Engine, found {engine}")
    (image,) = json.loads(docker("image", "inspect", IMAGE).stdout)
    if (image["Os"], image["Architecture"]) != ("linux", "arm64") or IMAGE not in (image["RepoDigests"] or ()):
        raise RuntimeError("Expected the exact pinned linux/arm64 OSRM image in the local cache")
    if image["Config"].get("Volumes"):
        raise RuntimeError("Refusing an image that declares anonymous volumes")
    print(f"PASS: uname=aarch64, Docker Engine={engine}, image={IMAGE}, ID={image['Id']}", flush=True)
    return image["Id"]


def owned_container(container_id, name, token):
    if not re.fullmatch(r"[0-9a-f]{64}", container_id):
        raise RuntimeError("Expected a full Docker container ID")
    (item,) = json.loads(docker("container", "inspect", container_id).stdout)
    labels = item["Config"].get("Labels") or {}
    if (item["Id"] != container_id or item["Name"] != f"/{name}"
            or labels.get(RUN_LABEL) != token):
        raise RuntimeError(f"Container ID, name or label mismatch: {container_id}")
    return item


def verify_isolation(item, directory, image_id):
    host = item["HostConfig"]
    if (item["Image"] != image_id or item["Config"]["User"] != USER
            or host["NetworkMode"] != "none" or host["PublishAllPorts"] or host["PortBindings"]
            or host["Privileged"] or not host["ReadonlyRootfs"]):
        raise RuntimeError("Container does not match the isolated UID, image, or network configuration")
    mounts = item["Mounts"]
    if len(mounts) != 1:
        raise RuntimeError("Expected only the dataset bind mount")
    mount = mounts[0]
    if (mount["Type"], mount["Source"], mount["Destination"], mount["RW"]) != ("bind", str(directory), "/data", False):
        raise RuntimeError("Expected the exact dataset path mounted read-only at /data")


def route_result(response):
    headers, separator, body = response.partition(b"\r\n\r\n")
    status = headers.split(b"\r\n", 1)[0]
    if not separator or not re.fullmatch(rb"HTTP/1\.[01] 200(?: .*)?", status):
        raise RuntimeError(f"Expected route HTTP 200, got {status[:120]!r}")
    payload = json.loads(body)
    routes = payload.get("routes") if isinstance(payload, dict) and payload.get("code") == "Ok" else None
    if not isinstance(routes, list) or not routes or not isinstance(routes[0], dict):
        raise RuntimeError("Expected OSRM code=Ok and at least one route")
    route = routes[0]
    distance, duration = route.get("distance"), route.get("duration")
    if (type(distance) not in (int, float) or type(duration) not in (int, float)
            or not (500 < distance < 20_000 and 0 < duration < 7200)):
        raise RuntimeError(f"Implausible Hanoi route: distance={distance!r}, duration={duration!r}")
    return distance, duration


def wait_for_route(container_id, name, token, started):
    while time.monotonic() - started < STARTUP_TIMEOUT:
        result = docker("container", "exec", container_id, "/bin/bash", "-c", PROBE, "h2a", ROUTE,
                        check=False, timeout=8)
        if result.returncode == 0:
            startup = time.monotonic() - started
            if startup > STARTUP_TIMEOUT:
                break
            distance, duration = route_result(result.stdout)
            return distance, duration, startup
        if not owned_container(container_id, name, token)["State"]["Running"]:
            logs = docker("container", "logs", "--tail", "20", container_id)
            raise RuntimeError(f"OSRM exited during startup:\n{(logs.stdout + logs.stderr).decode(errors='replace')}")
        if result.returncode != 10:
            raise RuntimeError(f"Internal route probe failed (exit {result.returncode})")
        time.sleep(0.5)
    raise RuntimeError(f"OSRM did not serve a route within {STARTUP_TIMEOUT} seconds")


def cleanup(container_id, name, token):
    # The exact label also finds a container if creation succeeded before the CLI was interrupted.
    query = ("container", "ls", "--all", "--quiet", "--no-trunc", "--filter", f"label={RUN_LABEL}={token}")
    ids = docker(*query).stdout.decode().split()
    if not ids and container_id is None:
        return
    if len(ids) != 1 or (container_id is not None and ids[0] != container_id):
        raise RuntimeError(f"Cannot confirm the unique container for {RUN_LABEL}={token}. See runbook.")
    (found_id,) = ids
    if owned_container(found_id, name, token)["State"]["Running"]:
        docker("container", "stop", "--time", "5", found_id)
    owned_container(found_id, name, token)
    docker("container", "rm", found_id)
    if docker(*query).stdout.strip():
        raise RuntimeError(f"Container still present for {RUN_LABEL}={token}")
    print(f"PASS: removed owned container {found_id}", flush=True)


def verify(data_dir):
    native_host()
    directory = data_dir.resolve(strict=True)
    if data_dir != directory or any(char in str(directory) for char in ',\"\r\n'):
        raise ValueError("Use the canonical absolute dataset path without symlinks, commas or quotes")
    files = read_manifest()
    verify_dataset(directory, files)
    print(f"PASS: 27/27 dataset SHA-256 checks in {directory}", flush=True)
    image_id = local_image()
    token = uuid.uuid4().hex
    name = f"gomove-h2a-osrm-{token}"
    print(f"Run container name={name} {RUN_LABEL}={token}", flush=True)
    container_id = None
    try:
        container_id = docker(
            "container", "create", "--pull", "never", "--platform", "linux/arm64",
            "--name", name, "--label", f"{RUN_LABEL}={token}", "--network", "none",
            "--user", USER, "--read-only", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--log-driver", "local", "--no-healthcheck",
            "--mount", f"type=bind,source={directory},target=/data,readonly,bind-recursive=disabled",
            "--entrypoint", "/bin/bash", IMAGE, "-ec", READ_AND_START, "h2a", *files,
        ).stdout.decode().strip()
        item = owned_container(container_id, name, token)
        verify_isolation(item, directory, image_id)
        print(f"PASS: isolated container ID={container_id}, read-only bind, no host ports", flush=True)

        started = time.monotonic()
        docker("container", "start", container_id)
        distance, duration, startup = wait_for_route(container_id, name, token, started)
        version = docker("container", "exec", container_id, "osrm-routed", "--version").stdout.decode().strip()
        stats = docker("stats", "--no-stream", "--format", "cpu={{.CPUPerc}} ram={{.MemUsage}}",
                       container_id).stdout.decode().strip()
        if not version or not stats or "--" in stats or "ram=0B / 0B" in stats:
            raise RuntimeError("OSRM version or container resource sample unavailable")
        print("PASS: UID/GID 10001 opened all 27 files directly and started OSRM MLD", flush=True)
        print(f"PASS: OSRM {version}, HTTP 200 code=Ok, distance={distance} m, duration={duration} s, "
              f"startup_to_route={startup:.2f} s", flush=True)
        print(f"Resource sample after route: {stats}", flush=True)
    finally:
        try:
            cleanup(container_id, name, token)
        finally:
            verify_dataset(directory, files)
            print("PASS: 27/27 SHA-256 still match after the run", flush=True)


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, required=True, help="Absolute path to the approved Linux copy")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, interrupt)
    try:
        verify(args.data_dir)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        parser.exit(1, f"FAIL: {error or 'interrupted'}\n")
    print("PASS: real Hanoi OSRM MLD on native ARM64", flush=True)


if __name__ == "__main__":
    main()

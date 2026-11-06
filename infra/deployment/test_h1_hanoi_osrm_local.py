"""Isolated, read-only Hanoi OSRM MLD smoke on local Docker Desktop.

The original dataset is never modified. Docker resources have unique H1 names and
labels; cleanup checks those labels before stopping/removing only this run's IDs.
"""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid


OSRM_IMAGE = "ghcr.io/project-osrm/osrm-backend@sha256:55dbfd47d984c2cacd64e32901b4321c86b5ec761438e69aa053dc78698a786f"
DEFAULT_CLIENT_IMAGE = "alpine:latest"  # Used only from the local image cache, never pulled.
LABEL = "gomove.h1"
ROUTE_URL = "http://osrm:5000/route/v1/driving/105.834,21.028;105.84,21.03?overview=false"


def docker(*args, check=True, timeout=90):
    result = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"docker {args[0]} failed ({result.returncode}): {result.stderr.strip()[-1200:]}")
    return result


def inspect(kind, identifier):
    result = docker(kind, "inspect", identifier, check=False)
    return json.loads(result.stdout)[0] if result.returncode == 0 else None


def check_label(kind, identifier, token):
    item = inspect(kind, identifier)
    if item is None:
        return False
    labels = item.get("Config", {}).get("Labels", {}) if kind == "container" else item.get("Labels", {})
    if labels.get(LABEL) != token:
        raise RuntimeError(f"Refusing to clean up {kind} without the H1 run label: {identifier}")
    return True


def snapshot(directory):
    result = {}
    for path in sorted(directory.glob("hanoi.osrm.*")):
        if not path.is_file():
            continue
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        result[path.name] = (path.stat().st_size, digest.hexdigest())
    return result


def route_probe(network, token, name, client_image):
    # The client has no host port; the internal bridge has no external route.
    command = "for i in $(seq 1 40); do wget -qO- \"$1\" 2>/dev/null && exit 0; sleep 0.25; done; exit 1"
    result = docker("run", "--rm", "--pull", "never", "--name", name,
                    "--label", f"{LABEL}={token}", "--network", network,
                    client_image, "sh", "-c", command, "sh", ROUTE_URL, timeout=75)
    payload = json.loads(result.stdout)
    if payload.get("code") != "Ok" or not payload.get("routes"):
        raise RuntimeError(f"Route probe returned {payload.get('code')}")
    route = payload["routes"][0]
    distance, duration = route["distance"], route["duration"]
    if not (500 < distance < 20000 and 0 < duration < 7200):
        raise RuntimeError(f"Implausible Hanoi route: {distance} m, {duration} s")
    print(f"PASS: code=Ok, distance={distance} m, duration={duration} s", flush=True)


def start_server(name, network, token, mount, user=None):
    command = ["run", "--detach", "--rm", "--pull", "never", "--name", name,
               "--label", f"{LABEL}={token}", "--network", network,
               "--network-alias", "osrm", "--read-only", "--tmpfs", "/tmp:rw,nosuid,nodev,size=16m",
               "--cap-drop", "ALL", "--security-opt", "no-new-privileges"]
    if user:
        command += ["--user", user]
    command += ["--mount", mount, OSRM_IMAGE,
                "osrm-routed", "--algorithm", "mld", "/data/hanoi.osrm"]
    container_id = docker(*command).stdout.strip()
    item = inspect("container", container_id)
    if not item or item["HostConfig"]["PortBindings"] or any(m["RW"] for m in item["Mounts"]):
        stop_owned(container_id, token)
        raise RuntimeError("H1 container has unexpected host ports or a writable data mount")
    return container_id


def stop_owned(container_id, token):
    if check_label("container", container_id, token):
        docker("stop", "--time", "5", container_id, check=False, timeout=20)
    if check_label("container", container_id, token):
        docker("rm", container_id, check=False, timeout=20)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--client-image", default=DEFAULT_CLIENT_IMAGE)
    parser.add_argument("--expect-arch", choices=("amd64", "arm64"), required=True)
    parser.add_argument("--require-direct-nonroot", action="store_true")
    args = parser.parse_args()
    directory = args.data_dir.resolve(strict=True)
    if not directory.is_dir():
        raise RuntimeError("Dataset path is not a directory")
    before = snapshot(directory)
    for suffix in ("cells", "partition", "mldgr", "fileIndex"):
        if f"hanoi.osrm.{suffix}" not in before:
            raise RuntimeError(f"Missing hanoi.osrm.{suffix}")
    print(f"Dataset: {directory}; {len(before)} MLD sidecar files; {sum(size for size, _ in before.values())} bytes", flush=True)
    architecture = docker("image", "inspect", OSRM_IMAGE, "--format", "{{.Os}}/{{.Architecture}}").stdout.strip()
    if architecture != f"linux/{args.expect_arch}":
        raise RuntimeError(f"Expected linux/{args.expect_arch}, found {architecture}")
    client_id = docker("image", "inspect", args.client_image, "--format", "{{.Id}}").stdout.strip()
    print(f"Images: OSRM={architecture}; test client={client_id}", flush=True)
    token = uuid.uuid4().hex[:12]
    base = f"gomove-h1-{token}"
    print("OSRM:", docker("run", "--rm", "--pull", "never", "--network", "none",
                           "--name", base + "-version", "--label", f"{LABEL}={token}", OSRM_IMAGE,
                           "osrm-routed", "--version").stdout.strip(), flush=True)
    network = base + "-net"
    volume = base + "-data"
    containers = []
    network_id = None
    volume_created = False
    bind = f"type=bind,source={directory},target=/data,readonly"
    try:
        network_id = docker("network", "create", "--internal", "--label", f"{LABEL}={token}", network).stdout.strip()
        # Direct NTFS bind mount: explicitly record whether production UID 10001 can read every file.
        preflight = docker("run", "--rm", "--pull", "never", "--name", base + "-read",
                           "--label", f"{LABEL}={token}", "--network", "none",
                           "--user", "10001:10001", "--read-only", "--mount", bind,
                           "--entrypoint", "sh", OSRM_IMAGE, "-c",
                           "for f in /data/hanoi.osrm.*; do test -r \"$f\" || { echo \"DENIED: ${f##*/}\"; exit 1; }; done",
                           check=False)
        print(f"Direct bind UID 10001 read check: exit={preflight.returncode} {preflight.stdout.strip()}", flush=True)
        if args.require_direct_nonroot and preflight.returncode:
            raise RuntimeError("UID 10001 cannot read the direct read-only mount")

        direct = start_server(base + "-direct", network, token, bind)
        containers.append(direct)
        started = time.monotonic()
        route_probe(network, token, base + "-client-direct", args.client_image)
        print(f"PASS: original read-only dataset with pinned OSRM image; startup={time.monotonic()-started:.2f}s", flush=True)
        print("DIRECT STATS:", docker("stats", "--no-stream", "--format",
                                       "cpu={{.CPUPerc}} memory={{.MemUsage}}", direct).stdout.strip(), flush=True)
        stop_owned(direct, token)
        containers.remove(direct)

        # Docker Desktop NTFS can make .fileIndex mode 0700. A temporary Linux volume
        # tests the same bytes with corrected permissions; the original stays read-only.
        docker("volume", "create", "--label", f"{LABEL}={token}", volume)
        volume_created = True
        docker("run", "--rm", "--pull", "never", "--name", base + "-copy",
               "--label", f"{LABEL}={token}", "--network", "none",
               "--mount", f"type=bind,source={directory},target=/source,readonly",
               "--mount", f"type=volume,source={volume},target=/data",
               args.client_image, "sh", "-c", "cp -a /source/hanoi.osrm.* /data/ && chmod -R a+rX /data")
        hashes = docker("run", "--rm", "--pull", "never", "--name", base + "-hash",
                        "--label", f"{LABEL}={token}", "--network", "none",
                        "--mount", f"type=volume,source={volume},target=/data,readonly",
                        args.client_image, "sh", "-c", "cd /data && sha256sum hanoi.osrm.*").stdout
        copied = {line.split("  ", 1)[1]: line.split("  ", 1)[0] for line in hashes.splitlines()}
        if copied != {name: digest for name, (_, digest) in before.items()}:
            raise RuntimeError("Disposable Linux volume is not byte-identical to the original MLD set")
        print("PASS: disposable Linux volume sidecars match all original SHA-256 hashes", flush=True)
        replica = start_server(base + "-uid10001", network, token,
                               f"type=volume,source={volume},target=/data,readonly", "10001:10001")
        containers.append(replica)
        started = time.monotonic()
        route_probe(network, token, base + "-client-uid10001", args.client_image)
        docker("exec", replica, "sh", "-c",
               "test -r /data/hanoi.osrm.cells && test -r /data/hanoi.osrm.partition && test -r /data/hanoi.osrm.mldgr && test -r /data/hanoi.osrm.fileIndex && kill -0 1")
        print(f"PASS: UID 10001 read-only Linux volume replica; startup={time.monotonic()-started:.2f}s", flush=True)
        print("UID10001 STATS:", docker("stats", "--no-stream", "--format",
                                        "cpu={{.CPUPerc}} memory={{.MemUsage}}", replica).stdout.strip(), flush=True)
    finally:
        for container_id in reversed(containers):
            stop_owned(container_id, token)
        # Also catch a one-shot client/copy container if its Docker CLI timed out.
        remaining = docker("ps", "-aq", "--filter", f"label={LABEL}={token}", check=False).stdout.splitlines()
        for container_id in remaining:
            item = inspect("container", container_id)
            if item and item["Name"].lstrip("/").startswith(base):
                stop_owned(container_id, token)
        if volume_created and check_label("volume", volume, token):
            docker("volume", "rm", volume)
        if network_id and check_label("network", network_id, token):
            docker("network", "rm", network_id)
        after = snapshot(directory)
        if after != before:
            raise RuntimeError("Original Hanoi dataset changed during H1 verification")
        print("PASS: original checksums unchanged; H1 resources removed", flush=True)


if __name__ == "__main__":
    main()

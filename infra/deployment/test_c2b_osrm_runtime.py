"""Disposable x86_64 OSRM MLD smoke using a synthetic road, never Hanoi data."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid


HERE = Path(__file__).resolve().parent
IMAGE = "ghcr.io/project-osrm/osrm-backend@sha256:55dbfd47d984c2cacd64e32901b4321c86b5ec761438e69aa053dc78698a786f"


def docker(*args):
    result = subprocess.run(["docker", *args], capture_output=True, text=True, check=True)
    return result.stdout.strip()


def main():
    token = uuid.uuid4().hex[:12]
    network = f"gomove-c2b-osrm-{token}"
    container = network + "-routed"
    volume = network + "-data"
    temp_parent = Path(tempfile.gettempdir()).resolve()
    temp_dir = Path(tempfile.mkdtemp(prefix="gomove-c2b-osrm-", dir=temp_parent)).resolve()
    if temp_dir.parent != temp_parent or not temp_dir.name.startswith("gomove-c2b-osrm-"):
        raise AssertionError("Unsafe temporary directory")
    created_network = False
    created_container = False
    created_volume = False
    try:
        shutil.copyfile(HERE / "c2b_synthetic_route.osm", temp_dir / "route.osm")
        arch = docker("image", "inspect", IMAGE, "--format", "{{.Os}}/{{.Architecture}}")
        assert arch == "linux/amd64", arch
        print("PASS: Local OSRM image is linux/amd64 (native ARM64 is not tested here)", flush=True)
        for command in (
            ("osrm-extract", "-p", "/opt/car.lua", "/data/route.osm"),
            ("osrm-partition", "/data/route.osrm"),
            ("osrm-customize", "/data/route.osrm"),
        ):
            docker("run", "--rm", "--network", "none", "--label", f"gomove.c2b={token}",
                   "--mount", f"type=bind,source={temp_dir},target=/data", IMAGE, *command)
            print(f"PASS: {command[0]} on synthetic fixture", flush=True)
        assert all((temp_dir / f"route.osrm.{suffix}").is_file() for suffix in ("cells", "partition", "mldgr"))
        print("PASS: Synthetic MLD files exist", flush=True)
        docker("volume", "create", "--label", f"gomove.c2b={token}", volume)
        created_volume = True
        docker("run", "--rm", "--network", "none", "--label", f"gomove.c2b={token}",
               "--mount", f"type=bind,source={temp_dir},target=/input,readonly",
               "--mount", f"type=volume,source={volume},target=/data",
               "alpine:latest", "sh", "-c", "cp -a /input/. /data/ && chmod -R a+rX /data")
        docker("network", "create", "--label", f"gomove.c2b={token}", network)
        created_network = True
        started = time.monotonic()
        docker("run", "--detach", "--name", container,
               "--label", f"gomove.c2b={token}", "--network", network,
               "--user", "10001:10001", "--read-only", "--tmpfs", "/tmp:rw,size=16m",
               "--mount", f"type=volume,source={volume},target=/data,readonly",
               "--publish", "127.0.0.1::5000", IMAGE,
               "osrm-routed", "--algorithm", "mld", "/data/route.osrm")
        created_container = True
        ports = json.loads(docker("inspect", "--format", "{{json .NetworkSettings.Ports}}", container))
        if "5000/tcp" not in ports or not ports["5000/tcp"]:
            result = subprocess.run(["docker", "logs", container], capture_output=True, text=True)
            raise AssertionError(f"OSRM port was not published; logs: {(result.stdout + result.stderr)[-800:]}")
        port = int(ports["5000/tcp"][0]["HostPort"])
        assert ports["5000/tcp"][0]["HostIp"] == "127.0.0.1"
        url = f"http://127.0.0.1:{port}/route/v1/driving/0.000000,0.000000;0.002000,0.001000?overview=false"
        for _ in range(40):
            try:
                with urllib.request.urlopen(url, timeout=2) as response:
                    payload = json.load(response)
                if payload.get("code") == "Ok":
                    break
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.25)
        else:
            raise AssertionError("Synthetic MLD HTTP route did not become available")
        assert payload["routes"][0]["distance"] > 0
        print(f"PASS: Synthetic MLD route returned code=Ok; startup={time.monotonic()-started:.2f}s", flush=True)
        assert docker("inspect", "--format", "{{.Config.User}}", container) == "10001:10001"
        docker("exec", container, "sh", "-c", "test -r /data/route.osrm.cells && test -r /data/route.osrm.partition && test -r /data/route.osrm.mldgr && kill -0 1")
        print("PASS: Production-style OSRM file/process health probe", flush=True)
        print("PASS: Routed container runs as UID/GID 10001 and only binds host loopback", flush=True)
        print("MEASURED:", docker("stats", "--no-stream", "--format", "cpu={{.CPUPerc}} memory={{.MemUsage}}", container), flush=True)
    finally:
        if created_container:
            label = subprocess.run(["docker", "inspect", "--format", '{{index .Config.Labels "gomove.c2b"}}', container], capture_output=True, text=True)
            if label.returncode == 0 and label.stdout.strip() == token:
                subprocess.run(["docker", "stop", container], capture_output=True, check=False)
                subprocess.run(["docker", "rm", container], capture_output=True, check=False)
        if created_network:
            label = subprocess.run(["docker", "network", "inspect", "--format", '{{index .Labels "gomove.c2b"}}', network], capture_output=True, text=True)
            if label.returncode == 0 and label.stdout.strip() == token:
                subprocess.run(["docker", "network", "rm", network], capture_output=True, check=False)
        if created_volume:
            label = subprocess.run(["docker", "volume", "inspect", "--format", '{{index .Labels "gomove.c2b"}}', volume], capture_output=True, text=True)
            if label.returncode == 0 and label.stdout.strip() == token:
                subprocess.run(["docker", "volume", "rm", volume], capture_output=True, check=False)
        if temp_dir.parent == temp_parent and temp_dir.name.startswith("gomove-c2b-osrm-"):
            shutil.rmtree(temp_dir)


if __name__ == "__main__":
    main()

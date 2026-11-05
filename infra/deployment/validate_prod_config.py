"""Offline guard for the proposed production Compose configuration.

Requires Docker Compose CLI, not a running Docker Engine. Never starts services.
Sample mode uses unusable zero digests and nonexistent paths for syntax checks.
"""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
from urllib.parse import urlparse


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
COMPOSE = HERE / "compose.prod.yaml"
RESTORE_COMPOSE = HERE / "compose.restore.yaml"
ZERO_DIGEST = "0" * 64
IMAGE_DIGEST = re.compile(r"^[^\s]+@sha256:([0-9a-f]{64})$")
IMAGE_PREFIXES = {
    "caddy": "caddy@sha256:",
    "backend": "ghcr.io/chumanhquan102006-creator/gomove-backend@sha256:",
    "postgres": "ghcr.io/chumanhquan102006-creator/gomove-postgis-arm64@sha256:",
    "osrm": "ghcr.io/project-osrm/osrm-backend@sha256:",
}
DNS_LABEL = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
MANIFEST_LINE = re.compile(r"^([0-9a-f]{64})  (hanoi\.osrm\.[A-Za-z0-9_.-]+)$")


class PreflightError(Exception):
    pass


def sample_environment() -> dict[str, str]:
    return {
        "M573_CADDY_DIGEST": ZERO_DIGEST,
        "M573_BACKEND_DIGEST": ZERO_DIGEST,
        "M573_POSTGIS_DIGEST": ZERO_DIGEST,
        "M573_PUBLIC_HOSTNAME": "api.example.invalid",
        "M573_GEOCODING_BASE_URL": "https://photon.komoot.io",
        "M573_SECRET_DIR": str(HERE / "unavailable-sample-secrets"),
        "M573_OSRM_DATA_DIR": str(HERE / "unavailable-sample-osrm"),
    }


def render_compose(*, sample: bool, env_file: Path | None = None) -> dict:
    command = ["docker", "compose"]
    if env_file is not None:
        command += ["--env-file", str(env_file)]
    command += ["-f", str(COMPOSE), "config", "--format", "json"]
    environment = os.environ.copy()
    if sample:
        environment.update(sample_environment())
    result = subprocess.run(command, env=environment, capture_output=True, text=True, check=False)
    if result.returncode:
        # Compose can echo paths and environment values in errors; keep output private.
        raise PreflightError(f"Docker Compose config failed (exit {result.returncode}).")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise PreflightError("Docker Compose did not produce valid JSON.") from error


def render_restore_sample() -> dict:
    environment = os.environ.copy()
    environment.update({
        "M573_RESTORE_SUFFIX": "sample",
        "M573_POSTGIS_DIGEST": ZERO_DIGEST,
        "M573_RESTORE_DB_PASSWORD_FILE": str(HERE / "unavailable-restore-password"),
    })
    result = subprocess.run(
        ["docker", "compose", "-f", str(RESTORE_COMPOSE), "config", "--format", "json"],
        env=environment, capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise PreflightError(f"Restore Compose config failed (exit {result.returncode}).")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise PreflightError("Restore Compose did not produce valid JSON.") from error


def validate_restore_config(config: dict) -> None:
    if config.get("name") != "gomove-m573-restore-sample":
        raise PreflightError("Restore project must be isolated from production.")
    services = config.get("services", {})
    if set(services) != {"postgres"} or services["postgres"].get("ports"):
        raise PreflightError("Restore stack must contain only a private PostgreSQL service.")
    if not services["postgres"].get("image", "").startswith(IMAGE_PREFIXES["postgres"]):
        raise PreflightError("Restore must use the reviewed PostGIS image family.")
    if not config.get("networks", {}).get("restore_private", {}).get("internal"):
        raise PreflightError("Restore network must be internal.")
    if set(config.get("volumes", {})) != {"restore_data"}:
        raise PreflightError("Restore stack must use a dedicated data volume.")
    if config["volumes"]["restore_data"].get("name") != "gomove-m573-restore-sample_restore_data":
        raise PreflightError("Restore data volume must be scoped to its own project.")


def valid_hostname(hostname: str, *, sample: bool) -> bool:
    if not hostname or len(hostname) > 253 or hostname != hostname.lower():
        return False
    try:
        ipaddress.ip_address(hostname)
        return False
    except ValueError:
        pass
    labels = hostname.split(".")
    if len(labels) < 2 or not all(DNS_LABEL.fullmatch(label) for label in labels):
        return False
    if not sample and labels[-1] in {"invalid", "example", "test", "localhost", "local"}:
        return False
    return True


def validate_config(config: dict, *, sample: bool) -> None:
    services = config.get("services", {})
    if config.get("name") != "gomove-m573" or set(services) != {"caddy", "backend", "postgres", "osrm"}:
        raise PreflightError("Unexpected Compose project or service set.")

    for name, service in services.items():
        match = IMAGE_DIGEST.fullmatch(service.get("image", ""))
        if match is None or not service["image"].startswith(IMAGE_PREFIXES[name]) or (not sample and match.group(1) == ZERO_DIGEST):
            raise PreflightError(f"{name}: image must use a reviewed nonzero SHA-256 digest.")
        if name != "caddy" and service.get("ports"):
            raise PreflightError(f"{name}: host port exposure is forbidden.")
        if service.get("privileged") or service.get("network_mode") or service.get("pid"):
            raise PreflightError(f"{name}: privileged or host namespace access is forbidden.")

    ports = services["caddy"].get("ports", [])
    actual_ports = {(str(item.get("published")), item.get("target"), item.get("protocol")) for item in ports}
    if actual_ports != {("80", 80, "tcp"), ("443", 443, "tcp")}:
        raise PreflightError("Caddy must be the only service publishing TCP 80/443.")

    networks = config.get("networks", {})
    if not networks.get("data", {}).get("internal") or not networks.get("routing", {}).get("internal"):
        raise PreflightError("Database and routing networks must be internal.")
    if networks.get("edge", {}).get("internal"):
        raise PreflightError("The Backend edge network must permit outbound geocoding.")
    for service_name, expected in {
        "caddy": {"edge"},
        "backend": {"edge", "data", "routing"},
        "postgres": {"data"},
        "osrm": {"routing"},
    }.items():
        if set(services[service_name].get("networks", {})) != expected:
            raise PreflightError(f"{service_name}: incorrect network boundary.")

    backend_env = services["backend"].get("environment", {})
    caddy_env = services["caddy"].get("environment", {})
    hostname = caddy_env.get("M573_PUBLIC_HOSTNAME", "")
    if not valid_hostname(hostname, sample=sample):
        raise PreflightError("A valid, explicit public DNS hostname is required.")
    if backend_env.get("GOMOVE_PROD_PUBLIC_HOSTNAME") != hostname:
        raise PreflightError("Backend WebSocket origin hostname differs from Caddy.")
    if backend_env.get("SPRING_PROFILES_ACTIVE") != "prod":
        raise PreflightError("Backend must explicitly activate prod, never dev.")
    if any(key in backend_env for key in ("JWT_SECRET", "SPRING_DATASOURCE_PASSWORD")):
        raise PreflightError("Secrets must be file-backed, not environment values.")
    geocoder = urlparse(backend_env.get("GOMOVE_PROD_GEOCODING_BASE_URL", ""))
    if geocoder.scheme != "https" or not geocoder.hostname or geocoder.hostname in {"localhost", "127.0.0.1"}:
        raise PreflightError("An explicit HTTPS geocoding endpoint is required.")

    secrets = config.get("secrets", {})
    if set(secrets) != {"db_password_backend", "db_password_postgres", "jwt_secret"}:
        raise PreflightError("Expected the two UID-scoped database copies and JWT file-backed secret.")
    if {entry.get("target") for entry in services["backend"].get("secrets", [])} != {
        "spring.datasource.password", "JWT_SECRET"
    }:
        raise PreflightError("Backend secret mounts do not match the prod profile.")
    if {entry.get("target") for entry in services["postgres"].get("secrets", [])} != {"db-password"}:
        raise PreflightError("PostgreSQL must mount only its password file.")
    if set(config.get("volumes", {})) != {"postgres_data", "caddy_data", "caddy_config"}:
        raise PreflightError("Unexpected persistent volumes.")
    expected_volume_names = {
        "postgres_data": "gomove-m573-postgres-data",
        "caddy_data": "gomove-m573-caddy-data",
        "caddy_config": "gomove-m573-caddy-config",
    }
    if any(config["volumes"][key].get("name") != value for key, value in expected_volume_names.items()):
        raise PreflightError("Production volume name differs from the isolated M5.7.3 set.")

    caddyfile = (HERE / "Caddyfile.prod").read_text(encoding="utf-8")
    for required in ("{$M573_PUBLIC_HOSTNAME}", "handle /ws", "handle /api/v1/*", "/actuator/*", "/swagger-ui/*", "/v3/api-docs/*", "respond 404"):
        if required not in caddyfile:
            raise PreflightError("Caddy routing or private endpoint denial is incomplete.")
    prod_profile = (ROOT / "backend/src/main/resources/application-prod.yml").read_text(encoding="utf-8")
    for required in ("configtree:/run/secrets/", "forward-headers-strategy: framework", "address: 127.0.0.1", "https://${GOMOVE_PROD_PUBLIC_HOSTNAME}"):
        if required not in prod_profile:
            raise PreflightError("Spring production security profile is incomplete.")


def outside_repository(path: Path) -> bool:
    resolved = path.resolve()
    return resolved != ROOT and ROOT not in resolved.parents


def validate_secret_files(config: dict) -> None:
    owners = {"db_password_backend": 10001, "db_password_postgres": 999, "jwt_secret": 10001}
    for name, minimum_size in (("db_password_backend", 24), ("db_password_postgres", 24), ("jwt_secret", 32)):
        path = Path(config["secrets"][name]["file"])
        if not path.is_absolute() or not outside_repository(path) or path.is_symlink() or not path.is_file():
            raise PreflightError(f"{name}: secret must be an existing file outside Git.")
        metadata = path.stat()
        if metadata.st_size < minimum_size:
            raise PreflightError(f"{name}: secret file is unexpectedly short.")
        if os.name == "posix":
            if stat.S_IMODE(metadata.st_mode) & 0o077 or not stat.S_IMODE(metadata.st_mode) & 0o400:
                raise PreflightError(f"{name}: secret file must be owner-readable only.")
            if metadata.st_uid != owners[name]:
                raise PreflightError(f"{name}: host owner UID must match the container reader.")
            if stat.S_IMODE(path.parent.stat().st_mode) & 0o077:
                raise PreflightError("Secret directory must not grant group/other access.")
    backend_path = Path(config["secrets"]["db_password_backend"]["file"])
    postgres_path = Path(config["secrets"]["db_password_postgres"]["file"])
    if hashlib.sha256(backend_path.read_bytes()).digest() != hashlib.sha256(postgres_path.read_bytes()).digest():
        raise PreflightError("Backend and PostgreSQL database password copies differ.")


def validate_dataset(config: dict, manifest: Path) -> None:
    mounts = config["services"]["osrm"].get("volumes", [])
    data_mounts = [mount for mount in mounts if mount.get("target") == "/data"]
    if len(data_mounts) != 1 or not data_mounts[0].get("read_only"):
        raise PreflightError("OSRM dataset must have one read-only mount.")
    directory = Path(data_mounts[0]["source"])
    if not directory.is_absolute() or not outside_repository(directory) or directory.is_symlink() or not directory.is_dir():
        raise PreflightError("OSRM dataset must be a directory outside Git.")
    if not manifest.is_file() or not outside_repository(manifest):
        raise PreflightError("A separate approved dataset SHA-256 manifest is required.")
    expected: dict[str, str] = {}
    for line in manifest.read_text(encoding="utf-8").splitlines():
        match = MANIFEST_LINE.fullmatch(line)
        if not match or match.group(2) in expected:
            raise PreflightError("Invalid or duplicate dataset manifest entry.")
        expected[match.group(2)] = match.group(1)
    actual = {path.name for path in directory.glob("hanoi.osrm.*") if path.is_file()}
    if not {"hanoi.osrm.partition", "hanoi.osrm.cells", "hanoi.osrm.mldgr"} <= actual or actual != set(expected):
        raise PreflightError("Dataset files do not match the approved manifest.")
    for filename, digest in expected.items():
        sha = hashlib.sha256()
        with (directory / filename).open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                sha.update(block)
        if sha.hexdigest() != digest:
            raise PreflightError(f"Dataset checksum mismatch: {filename}.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--sample", action="store_true", help="Offline syntax/structure check using unusable dummy values")
    mode.add_argument("--env-file", type=Path, help="Path-only deployment environment file outside Git")
    parser.add_argument("--dataset-manifest", type=Path, help="Approved SHA-256 manifest; required with --env-file")
    args = parser.parse_args()
    try:
        if not args.sample:
            if not args.env_file.is_file() or not outside_repository(args.env_file):
                raise PreflightError("Deployment environment file must exist outside Git.")
            if args.dataset_manifest is None:
                raise PreflightError("--dataset-manifest is required for a deployment preflight.")
        config = render_compose(sample=args.sample, env_file=args.env_file)
        validate_config(config, sample=args.sample)
        if args.sample:
            validate_restore_config(render_restore_sample())
        if not args.sample:
            validate_secret_files(config)
            validate_dataset(config, args.dataset_manifest)
    except (OSError, PreflightError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: offline production configuration checks (no containers started).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

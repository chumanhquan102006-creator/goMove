"""Disposable local AMD64 production-profile Backend and Flyway V18 smoke."""

import json
import secrets
import subprocess
import time
import uuid


BACKEND = "gomove-c2b-backend:b08a9be"
POSTGIS = "gomove-postgis35-spike:amd64"
PYTHON = "python@sha256:e031123e3d85762b141ad1cbc56452ba69c6e722ebf2f042cc0dc86c47c0d8b3"


def docker(*args, env=None, expect=0):
    result = subprocess.run(["docker", *args], env=env, capture_output=True, text=True, check=False)
    if (result.returncode == 0) != (expect == 0):
        raise AssertionError(f"Unexpected Docker exit {result.returncode}: {args[:3]}\n{result.stderr[-1000:]}")
    return result.stdout.strip()


def main():
    token = uuid.uuid4().hex[:12]
    network = f"gomove-c2b-backend-{token}"
    db = network + "-postgres"
    app = network + "-app"
    secret_volume = network + "-secrets"
    created = []
    try:
        assert docker("image", "inspect", BACKEND, "--format", "{{.Os}}/{{.Architecture}}") == "linux/amd64"
        assert docker("image", "inspect", BACKEND, "--format", "{{.Config.User}}") == "10001:10001"
        print("PASS: Current Backend image is linux/amd64 and declares UID/GID 10001", flush=True)

        # Deliberately omit both prod configtree files and DB networking.
        missing = subprocess.run(
            ["docker", "run", "--rm", "--network", "none", "--env", "SPRING_PROFILES_ACTIVE=prod", BACKEND],
            capture_output=True, text=True, timeout=45, check=False,
        )
        assert missing.returncode != 0
        assert any(text in missing.stdout + missing.stderr for text in
                   ("configtree", "JWT_SECRET", "Config data resource", "Could not resolve placeholder"))
        print("PASS: Prod profile fails closed without mandatory configuration", flush=True)

        docker("volume", "create", "--label", f"gomove.c2b={token}", secret_volume)
        created.append(("volume", secret_volume))
        password = secrets.token_urlsafe(32)
        secret_writer = """
import os, pathlib, secrets
root=pathlib.Path('/run/secrets')
for name, value in (
    ('spring.datasource.password', os.environ['C2B_DB_PASSWORD']),
    ('JWT_SECRET', secrets.token_hex(48)),
):
    path=root/name
    path.write_text(value)
    path.chmod(0o400)
    os.chown(path, 10001, 10001)
"""
        docker("run", "--rm", "--network", "none",
               "--mount", f"type=volume,source={secret_volume},target=/run/secrets",
               "--env", f"C2B_DB_PASSWORD={password}",
               PYTHON, "python", "-c", secret_writer)
        docker("network", "create", "--label", f"gomove.c2b={token}", network)
        created.append(("network", network))
        docker("run", "--detach", "--name", db, "--network", network, "--network-alias", "postgres",
               "--label", f"gomove.c2b={token}", "--tmpfs", "/var/lib/postgresql/data:rw,size=768m",
               "--env", f"POSTGRES_PASSWORD={password}", "--env", "POSTGRES_DB=gomove_prod",
               "--env", "POSTGRES_USER=gomove_prod", POSTGIS)
        created.append(("container", db))
        for _ in range(60):
            if docker("inspect", "--format", "{{.State.Health.Status}}", db) == "healthy":
                break
            time.sleep(1)
        else:
            raise AssertionError("Synthetic PostgreSQL did not become healthy")
        print("PASS: Fresh isolated PostGIS database is healthy", flush=True)

        started = time.monotonic()
        docker("run", "--detach", "--name", app, "--network", network,
               "--label", f"gomove.c2b={token}", "--user", "10001:10001",
               "--read-only", "--tmpfs", "/tmp:rw,size=64m", "--cap-drop", "ALL",
               "--security-opt", "no-new-privileges:true",
               "--mount", f"type=volume,source={secret_volume},target=/run/secrets,readonly",
               "--env", "SPRING_PROFILES_ACTIVE=prod",
               "--env", "SPRING_AUTOCONFIGURE_EXCLUDE=org.springframework.boot.autoconfigure.security.servlet.UserDetailsServiceAutoConfiguration",
               "--env", "GOMOVE_PROD_PUBLIC_HOSTNAME=c2b.example.invalid",
               "--env", "GOMOVE_PROD_GEOCODING_BASE_URL=https://geocoder.example.invalid",
               BACKEND)
        created.append(("container", app))
        ready = False
        for _ in range(90):
            result = subprocess.run(
                ["docker", "exec", app, "java", "-cp", "/app/health", "HealthProbe",
                 "http://127.0.0.1:8081/actuator/health/readiness", '"status":"UP"'],
                capture_output=True, text=True, check=False,
            )
            if result.returncode == 0:
                ready = True
                break
            state = docker("inspect", "--format", "{{.State.Running}}", app)
            if state != "true":
                break
            time.sleep(1)
        if not ready:
            logs = subprocess.run(["docker", "logs", app], capture_output=True, text=True)
            raise AssertionError(f"Backend readiness failed: {(logs.stdout + logs.stderr)[-2000:]}")
        print(f"PASS: Prod Backend readiness UP after {time.monotonic()-started:.2f}s", flush=True)
        version = docker("exec", "-u", "postgres", db, "psql", "-U", "gomove_prod",
                         "-d", "gomove_prod", "-Atqc",
                         "SELECT version FROM flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1")
        assert version == "18", version
        print("PASS: Real Flyway V1–V18 ran on fresh isolated PostGIS", flush=True)
        ports = json.loads(docker("inspect", "--format", "{{json .HostConfig.PortBindings}}", app))
        assert not ports
        print("PASS: Backend has no host port binding", flush=True)
        print("MEASURED:", docker("stats", "--no-stream", "--format",
                                  "cpu={{.CPUPerc}} memory={{.MemUsage}}", app), flush=True)
    finally:
        for kind, name in reversed(created):
            if kind == "container":
                label = subprocess.run(["docker", "inspect", "--format",
                                        '{{index .Config.Labels "gomove.c2b"}}', name],
                                       capture_output=True, text=True)
                if label.returncode == 0 and label.stdout.strip() == token:
                    subprocess.run(["docker", "stop", name], capture_output=True, check=False)
                    subprocess.run(["docker", "rm", name], capture_output=True, check=False)
            elif kind == "network":
                label = subprocess.run(["docker", "network", "inspect", "--format",
                                        '{{index .Labels "gomove.c2b"}}', name],
                                       capture_output=True, text=True)
                if label.returncode == 0 and label.stdout.strip() == token:
                    subprocess.run(["docker", "network", "rm", name], capture_output=True, check=False)
            elif kind == "volume":
                label = subprocess.run(["docker", "volume", "inspect", "--format",
                                        '{{index .Labels "gomove.c2b"}}', name],
                                       capture_output=True, text=True)
                if label.returncode == 0 and label.stdout.strip() == token:
                    subprocess.run(["docker", "volume", "rm", name], capture_output=True, check=False)


if __name__ == "__main__":
    main()

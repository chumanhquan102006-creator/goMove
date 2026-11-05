"""C2B synthetic backup/restore rehearsal on disposable, labeled Docker resources.

Requires Git Bash with GPG on Windows (or Bash/GPG on Linux), a Docker Engine,
and the already-built local gomove-postgis35-spike:amd64 image. The production
backup script is called through a narrow Docker shim that redirects its fixed
Compose source to the synthetic source container; it cannot reach production.
No existing container, volume, network, secret or backup directory is used.
"""

import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time
import uuid


HERE = Path(__file__).resolve().parent
IMAGE = "gomove-postgis35-spike:amd64"
BASH = os.environ.get("GOMOVE_C2B_BASH", "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else "/bin/bash")
DOCKER = os.environ.get("GOMOVE_C2B_DOCKER", "docker")


def run(args, *, env=None, expect=0):
    result = subprocess.run(args, env=env, capture_output=True, text=True, check=False)
    if (result.returncode == 0) != (expect == 0):
        raise AssertionError(f"Unexpected exit {result.returncode}: {args[:3]}\n{result.stderr[-800:]}")
    return result


def docker(*args, env=None):
    return run([DOCKER, *args], env=env).stdout.strip()


def unix(path):
    if os.name != "nt":
        return str(path)
    return run([BASH, "-c", 'cygpath -u "$1"', "_", str(path)]).stdout.strip()


def shell(command, *, env=None, expect=0):
    return run([BASH, "-c", command], env=env, expect=expect)


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print("PASS:", message, flush=True)


def wait_healthy(name):
    for _ in range(60):
        status = docker("inspect", "--format", "{{.State.Health.Status}}", name)
        if status == "healthy":
            return
        time.sleep(1)
    raise AssertionError(f"Synthetic PostgreSQL {name} did not become healthy")


def main():
    token = uuid.uuid4().hex[:12]
    source = f"gomove-c2b-{token}-source"
    target = f"gomove-c2b-{token}-restore"
    project = f"gomove-m573-restore-{token}"
    volume = f"{project}_restore_data"
    dummy = f"gomove-c2b-{token}-guard"
    created_containers = []
    created_volume = False
    temp_parent = Path(tempfile.gettempdir()).resolve()
    temp_root = Path(tempfile.mkdtemp(prefix="gomove-c2b-", dir=temp_parent)).resolve()
    if temp_root.parent != temp_parent or not temp_root.name.startswith("gomove-c2b-"):
        raise AssertionError("Unsafe temporary directory")
    try:
        image_arch = docker("image", "inspect", IMAGE, "--format", "{{.Os}}/{{.Architecture}}")
        check(image_arch == "linux/amd64", "Disposable PostGIS image is linux/amd64; this is not ARM64 proof")
        password = secrets.token_urlsafe(32)
        docker(
            "run", "--detach", "--rm", "--name", source, "--network", "none",
            "--label", f"gomove.c2b={token}",
            "--tmpfs", "/var/lib/postgresql/data:rw,size=512m",
            "--env", f"POSTGRES_PASSWORD={password}", "--env", "POSTGRES_DB=gomove_prod",
            "--env", "POSTGRES_USER=gomove_prod", IMAGE,
        )
        created_containers.append(source)
        wait_healthy(source)
        print("MEASURED:", docker("stats", "--no-stream", "--format", "cpu={{.CPUPerc}} memory={{.MemUsage}}", source), flush=True)
        docker("exec", "-u", "postgres", source, "psql", "-U", "gomove_prod", "-d", "gomove_prod",
               "-v", "ON_ERROR_STOP=1", "-c", "CREATE EXTENSION postgis; CREATE TABLE c2b_synthetic(id integer PRIMARY KEY, note text NOT NULL); INSERT INTO c2b_synthetic VALUES (1, 'synthetic-only'); CREATE TABLE flyway_schema_history(installed_rank integer, version text, success boolean); INSERT INTO flyway_schema_history VALUES (18, '18', true);")

        docker("volume", "create", "--label", f"gomove.c2b={token}", volume)
        created_volume = True
        docker(
            "run", "--detach", "--rm", "--name", target, "--network", "none",
            "--label", f"gomove.c2b={token}",
            "--label", f"com.docker.compose.project={project}",
            "--label", "com.docker.compose.service=postgres",
            "--mount", f"type=volume,source={volume},target=/var/lib/postgresql/data",
            "--env", f"POSTGRES_PASSWORD={password}", "--env", "POSTGRES_DB=postgres",
            "--env", "POSTGRES_USER=gomove_prod", IMAGE,
        )
        created_containers.append(target)
        wait_healthy(target)
        print("MEASURED:", docker("stats", "--no-stream", "--format", "cpu={{.CPUPerc}} memory={{.MemUsage}}", target), flush=True)

        backups = temp_root / "backups"
        backups.mkdir(mode=0o700)
        (backups / ".gomove-m573-backups").write_text("")
        env_file = temp_root / "paths.env"
        env_file.write_text("# Synthetic test only\n")
        gnupg = temp_root / "gnupg"
        gnupg.mkdir(mode=0o700)
        shim_dir = temp_root / "shim"
        shim_dir.mkdir(mode=0o700)
        shim = shim_dir / "docker"
        shim.write_text("""#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == compose ]]; then
  [[ "$*" == *'--project-name gomove-m573'* ]] || exit 91
  while [[ "$1" != exec ]]; do shift; [[ $# -gt 0 ]] || exit 92; done
  shift
  [[ "$1" == -T && "$2" == -u && "$3" == postgres && "$4" == postgres && "$5" == pg_dump ]] || exit 93
  shift 4
  [[ "${C2B_FAIL_DUMP:-}" != 1 ]] || exit 94
  exec "$C2B_REAL_DOCKER" exec -u postgres "$C2B_SOURCE" "$@"
fi
if [[ "${C2B_FAIL_INSPECTION:-}" == 1 && "$1" == exec && "$*" == *'SELECT 1 FROM pg_database'* ]]; then
  exit 95
fi
exec "$C2B_REAL_DOCKER" "$@"
""")
        shim.chmod(0o700)
        docker_exe = DOCKER if Path(DOCKER).is_absolute() else shutil.which(DOCKER)
        if docker_exe is None:
            raise AssertionError("Docker CLI missing")
        env = os.environ.copy()
        env.update({
            "GNUPGHOME": unix(gnupg),
            "GOMOVE_BACKUP_DIR": unix(backups),
            "GOMOVE_PROD_ENV_FILE": unix(env_file),
            "C2B_REAL_DOCKER": unix(Path(docker_exe)),
            "C2B_SOURCE": source,
            "C2B_SHIM_DIR": unix(shim_dir),
        })
        shell("gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'GoMove C2B Synthetic <c2b@example.invalid>' rsa2048 encr 0", env=env)
        fingerprint = shell("gpg --batch --with-colons --list-keys | awk -F: '$1 == \"fpr\" {print $10; exit}'", env=env).stdout.strip()
        check(len(fingerprint) == 40, "Disposable GPG recipient key created outside repository")
        env["GOMOVE_BACKUP_RECIPIENT_FPR"] = fingerprint
        script_backup = unix(HERE / "backup-prod.sh")
        script_restore = unix(HERE / "restore-isolated.sh")
        script_prune = unix(HERE / "prune-backups.sh")
        prefix = 'export PATH="$C2B_SHIM_DIR:$PATH"; '

        unknown_recipient = shell(prefix + f'bash "{script_backup}" daily',
                                  env=env | {"GOMOVE_BACKUP_RECIPIENT_FPR": "0" * 40}, expect=1)
        check(unknown_recipient.returncode != 0 and not list(backups.glob("*.dump.gpg")),
              "Unknown GPG recipient returns nonzero without publishing a backup")
        failure_env = env | {"C2B_FAIL_DUMP": "1"}
        result = shell(prefix + f'bash "{script_backup}" weekly', env=failure_env, expect=1)
        check(result.returncode != 0 and not list(backups.glob("*.dump.gpg")), "Failed pg_dump returns nonzero and leaves no published backup")

        shell(prefix + f'bash "{script_backup}" daily', env=env)
        encrypted = next(backups.glob("*.dump.gpg"))
        check(encrypted.stat().st_size > 0 and encrypted.read_bytes()[:5] != b"PGDMP", "Backup is encrypted and nonempty")
        shell(f'gpg --batch --decrypt --output - "{unix(encrypted)}" | head -c 5', env=env)
        check(shell(f'gpg --batch --decrypt --output - "{unix(encrypted)}" | head -c 5', env=env).stdout == "PGDMP", "Encrypted backup decrypts to pg_dump custom format")

        base = prefix + f'bash "{script_restore}" --container "{target}" --target-db '
        args = f' --db-user gomove_prod --backup "{unix(encrypted)}"'
        wrong_project = shell(prefix + f'bash "{script_restore}" --container "{source}" --target-db gomove_restore_wrong' + args, env=env, expect=1)
        check(wrong_project.returncode != 0, "Non-restore project is rejected")
        inspect_fail = shell(base + "gomove_restore_inspection" + args, env=env | {"C2B_FAIL_INSPECTION": "1"}, expect=1)
        check(inspect_fail.returncode != 0, "Failed database inspection returns nonzero before creation")
        absent = docker("exec", "-u", "postgres", target, "psql", "-U", "gomove_prod", "-d", "postgres", "-Atqc", "SELECT 1 FROM pg_database WHERE datname='gomove_restore_inspection'")
        check(not absent, "Failed inspection did not create a database")

        # Label and mount guards are exercised with a disposable inert container.
        for case, labels, mount in (
            ("service", [f"com.docker.compose.project={project}", "com.docker.compose.service=other"], []),
            ("mount", [f"com.docker.compose.project={project}", "com.docker.compose.service=postgres"], ["--tmpfs", "/var/lib/postgresql/data:rw,size=16m"]),
        ):
            docker("run", "--detach", "--rm", "--name", dummy, "--network", "none",
                   "--label", f"gomove.c2b={token}", *(part for label in labels for part in ("--label", label)),
                   *mount, "alpine:latest", "sleep", "120")
            created_containers.append(dummy)
            rejected = shell(prefix + f'bash "{script_restore}" --container "{dummy}" --target-db gomove_restore_{case}' + args, env=env, expect=1)
            check(rejected.returncode != 0, f"{case} guard returns nonzero")
            docker("stop", dummy)
            created_containers.remove(dummy)

        outside = temp_root / encrypted.name
        shutil.copyfile(encrypted, outside)
        shutil.copyfile(Path(str(encrypted) + ".sha256"), Path(str(outside) + ".sha256"))
        traversal = shell(base + "gomove_restore_traversal" + args.replace(unix(encrypted), unix(outside)), env=env, expect=1)
        check(traversal.returncode != 0, "Backup outside marked directory is rejected")
        link = backups / "gomove-prod-weekly-20200101T000000Z.dump.gpg"
        try:
            link.symlink_to(outside)
        except OSError:
            print("NOT RUN: Symlink creation is unavailable on this filesystem", flush=True)
        else:
            Path(str(link) + ".sha256").write_text(Path(str(encrypted) + ".sha256").read_text())
            symlink = shell(base + "gomove_restore_symlink" + args.replace(unix(encrypted), unix(link)), env=env, expect=1)
            check(symlink.returncode != 0, "Symlink to backup outside marked directory is rejected")

        corrupt = backups / encrypted.name.replace("daily", "weekly")
        content = bytearray(encrypted.read_bytes())
        content[len(content) // 2] ^= 0xFF
        corrupt.write_bytes(content)
        shutil.copyfile(Path(str(encrypted) + ".sha256"), Path(str(corrupt) + ".sha256"))
        rejected = shell(base + "gomove_restore_corrupt" + args.replace(unix(encrypted), unix(corrupt)), env=env, expect=1)
        check(rejected.returncode != 0, "Corrupted ciphertext/checksum returns nonzero")

        shell(base + "gomove_restore_valid" + args, env=env)
        count = docker("exec", "-u", "postgres", target, "psql", "-U", "gomove_prod", "-d", "gomove_restore_valid", "-Atqc", "SELECT count(*) FROM c2b_synthetic WHERE note='synthetic-only'")
        check(count == "1", "Isolated restore contains the source synthetic record")
        postgis = docker("exec", "-u", "postgres", target, "psql", "-U", "gomove_prod", "-d", "gomove_restore_valid", "-Atqc", "SELECT PostGIS_Version()")
        check(postgis.startswith("3.5"), f"Restored PostGIS version is {postgis}")
        flyway = docker("exec", "-u", "postgres", target, "psql", "-U", "gomove_prod", "-d", "gomove_restore_valid", "-Atqc", "SELECT version || ':' || success FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 1")
        check(flyway == "18:true", "Restored synthetic Flyway marker is V18")
        repeated = shell(base + "gomove_restore_valid" + args, env=env, expect=1)
        check(repeated.returncode != 0, "Existing restore target is never overwritten")

        for day in range(1, 10):
            candidate = backups / f"gomove-prod-daily-202001{day:02d}T000000Z.dump.gpg"
            candidate.write_bytes(b"synthetic retention candidate")
            Path(str(candidate) + ".sha256").write_text("synthetic checksum")
        unrelated = backups / "unrelated.txt"
        unrelated.write_text("keep")
        dry = shell(f'bash "{script_prune}"', env=env)
        check("Would remove:" in dry.stdout and len(list(backups.glob("gomove-prod-daily-202001*.dump.gpg"))) == 9,
              "Retention dry run does not delete synthetic files")
        shell(f'bash "{script_prune}" --apply', env=env)
        remaining = len(list(backups.glob("gomove-prod-daily-202001*.dump.gpg")))
        check(remaining == 6 and unrelated.exists() and encrypted.exists(), "Apply deletes only excess synthetic daily backups")
        second = shell(f'bash "{script_prune}" --apply', env=env)
        check("Removed expired" not in second.stdout, "Retention apply is idempotent in the disposable directory")
    finally:
        for name in reversed(created_containers):
            label = subprocess.run([DOCKER, "inspect", "--format", '{{index .Config.Labels "gomove.c2b"}}', name], capture_output=True, text=True)
            if label.returncode == 0 and label.stdout.strip() == token:
                subprocess.run([DOCKER, "stop", name], capture_output=True, check=False)
        if created_volume:
            label = subprocess.run([DOCKER, "volume", "inspect", "--format", '{{index .Labels "gomove.c2b"}}', volume], capture_output=True, text=True)
            if label.returncode == 0 and label.stdout.strip() == token:
                subprocess.run([DOCKER, "volume", "rm", volume], capture_output=True, check=False)
        if temp_root.parent == temp_parent and temp_root.name.startswith("gomove-c2b-"):
            shutil.rmtree(temp_root)


if __name__ == "__main__":
    main()

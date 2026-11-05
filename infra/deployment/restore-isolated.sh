#!/usr/bin/env bash
# Restores only into a NEW database in an explicitly labeled isolated container.
# Never accepts the production Compose project or gomove_prod as a target.
set -euo pipefail
source "$(dirname "$0")/backup-common.sh"

[[ $# -eq 8 ]] || fail 'Usage: restore-isolated.sh --container NAME --target-db gomove_restore_NAME --db-user USER --backup FILE'
[[ "$1" = --container && "$3" = --target-db && "$5" = --db-user && "$7" = --backup ]] || fail 'Use the documented explicit arguments.'
container="$2"
target_db="$4"
db_user="$6"
backup="$8"
[[ "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || fail 'Invalid container name.'
[[ "$target_db" =~ ^gomove_restore_[a-z][a-z0-9_]{0,46}$ ]] || fail 'Target must be a new gomove_restore_* database.'
[[ "$db_user" =~ ^[a-z][a-z0-9_]{0,62}$ ]] || fail 'Invalid database user.'
require_backup_directory
[[ -f "$backup" && -f "$backup.sha256" ]] || fail 'Encrypted backup and checksum are both required.'
backup="$(realpath "$backup")"
[[ "$(dirname "$backup")" = "$GOMOVE_BACKUP_DIR" ]] || fail 'Backup must be in the approved backup directory.'
[[ "$(basename "$backup")" =~ ^gomove-prod-(daily|weekly)-[0-9]{8}T[0-9]{6}Z\.dump\.gpg$ ]] || fail 'Unrecognized backup filename.'
command -v docker >/dev/null || fail 'Docker CLI is required.'
command -v gpg >/dev/null || fail 'GPG is required.'
command -v sha256sum >/dev/null || fail 'sha256sum is required.'

expected="$(head -c 64 "$backup.sha256")"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail 'Invalid checksum file.'
actual="$(sha256sum "$backup" | cut -d ' ' -f1)"
[[ "$expected" = "$actual" ]] || fail 'Encrypted backup checksum mismatch.'

project="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$container")"
[[ "$project" =~ ^gomove-m573-restore-[a-z0-9-]+$ ]] || fail 'Container is not in a dedicated M5.7.3 restore project.'
service="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$container")"
[[ "$service" = postgres ]] || fail 'Restore target is not the isolated PostgreSQL service.'
data_mount="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Type}}:{{.Name}}{{end}}{{end}}' "$container")"
[[ "$data_mount" = "volume:${project}_restore_data" ]] || fail 'Restore target does not use its dedicated data volume.'
[[ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ]] || fail 'Restore container is not running.'
existing="$(docker exec -u postgres "$container" psql -U "$db_user" -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$target_db'")" \
  || fail 'Could not verify target database nonexistence.'
if [[ "$existing" = 1 ]]; then
  fail 'Target database already exists; refusing to overwrite it.'
fi
[[ -z "$existing" ]] || fail 'Unexpected database-existence query result.'

docker exec -u postgres "$container" createdb -U "$db_user" -O "$db_user" "$target_db"
printf 'Created new isolated database %s. Decrypting directly into pg_restore.\n' "$target_db"
gpg --batch --decrypt --output - "$backup" \
  | docker exec -i -u postgres "$container" pg_restore -U "$db_user" -d "$target_db" \
      --no-owner --no-privileges --exit-on-error
docker exec -u postgres "$container" psql -U "$db_user" -d "$target_db" \
  -v ON_ERROR_STOP=1 -Atqc 'SELECT PostGIS_Version()'
docker exec -u postgres "$container" psql -U "$db_user" -d "$target_db" \
  -v ON_ERROR_STOP=1 -Atqc 'SELECT version, success FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 1'
printf 'Restore completed in isolated database %s. Verify application data before any recovery decision.\n' "$target_db"

#!/usr/bin/env bash
# Streams pg_dump directly into GPG public-key encryption. No plaintext dump file.
set -euo pipefail
source "$(dirname "$0")/backup-common.sh"

[[ $# -eq 1 && ( "$1" = daily || "$1" = weekly ) ]] || fail 'Usage: backup-prod.sh daily|weekly'
backup_kind="$1"
require_backup_directory
require_external_env_file
[[ -n "${GOMOVE_BACKUP_RECIPIENT_FPR:-}" ]] || fail 'Set GOMOVE_BACKUP_RECIPIENT_FPR to the reviewed public GPG key fingerprint.'
[[ "$GOMOVE_BACKUP_RECIPIENT_FPR" =~ ^[A-Fa-f0-9]{40}([A-Fa-f0-9]{24})?$ ]] || fail 'GPG recipient must be a full 40- or 64-hex fingerprint.'
command -v docker >/dev/null || fail 'Docker CLI is required.'
command -v gpg >/dev/null || fail 'GPG is required for public-key encryption.'
command -v sha256sum >/dev/null || fail 'sha256sum is required.'
gpg --batch --list-keys "$GOMOVE_BACKUP_RECIPIENT_FPR" >/dev/null 2>&1 || fail 'Reviewed recipient public key is not imported.'

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
compose=(docker compose --project-name gomove-m573 --env-file "$GOMOVE_PROD_ENV_FILE" -f "$script_dir/compose.prod.yaml")
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
destination="$GOMOVE_BACKUP_DIR/gomove-prod-${backup_kind}-${stamp}.dump.gpg"
[[ ! -e "$destination" && ! -e "$destination.sha256" ]] || fail 'Backup output already exists.'
umask 077
temporary="$(mktemp "$GOMOVE_BACKUP_DIR/.gomove-prod-backup.XXXXXXXX")"
trap 'rm -f -- "$temporary"' EXIT

"${compose[@]}" exec -T -u postgres postgres \
  pg_dump -U gomove_prod -d gomove_prod -Fc --no-owner --no-privileges \
  | gpg --batch --yes --trust-model always \
      --recipient "$GOMOVE_BACKUP_RECIPIENT_FPR" --encrypt --output "$temporary"
[[ -s "$temporary" ]] || fail 'Encrypted backup is empty.'
checksum="$(sha256sum "$temporary" | cut -d ' ' -f1)"
mv -- "$temporary" "$destination"
printf '%s  %s\n' "$checksum" "$(basename "$destination")" > "$destination.sha256"
trap - EXIT
printf 'Encrypted backup created: %s\n' "$destination"
printf 'Transfer the encrypted file and checksum off-server; verify both there.\n'

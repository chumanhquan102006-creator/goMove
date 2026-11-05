#!/usr/bin/env bash
# Dry-run by default. Deletes only recognized encrypted backups on --apply.
set -euo pipefail
source "$(dirname "$0")/backup-common.sh"
[[ $# -eq 0 || ( $# -eq 1 && "$1" = --apply ) ]] || fail 'Usage: prune-backups.sh [--apply]'
apply=false
[[ $# -eq 1 ]] && apply=true
require_backup_directory

for kind in daily weekly; do
  keep=7
  [[ "$kind" = weekly ]] && keep=4
  mapfile -t found < <(find "$GOMOVE_BACKUP_DIR" -maxdepth 1 -type f -name "gomove-prod-${kind}-*.dump.gpg" -print | sort -r)
  candidates=()
  for file in "${found[@]}"; do
    name="$(basename "$file")"
    [[ "$name" =~ ^gomove-prod-(daily|weekly)-[0-9]{8}T[0-9]{6}Z\.dump\.gpg$ ]] || continue
    if [[ ! -f "$file.sha256" ]]; then
      printf 'Skipping backup without checksum: %s\n' "$name" >&2
      continue
    fi
    candidates+=("$file")
  done
  for ((index = keep; index < ${#candidates[@]}; index++)); do
    file="${candidates[$index]}"
    name="$(basename "$file")"
    if "$apply"; then
      rm -f -- "$file" "$file.sha256"
      printf 'Removed expired encrypted backup: %s\n' "$name"
    else
      printf 'Would remove: %s\n' "$name"
    fi
  done
done

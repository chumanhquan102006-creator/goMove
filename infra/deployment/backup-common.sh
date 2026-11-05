#!/usr/bin/env bash
# Shared guard for future, explicitly approved production backup operations.
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_backup_directory() {
  [[ -n "${GOMOVE_BACKUP_DIR:-}" ]] || fail 'Set GOMOVE_BACKUP_DIR to a private, mounted backup directory.'
  [[ -d "$GOMOVE_BACKUP_DIR" ]] || fail 'Backup directory does not exist.'
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  repo_root="$(cd "$script_dir/../.." && pwd -P)"
  GOMOVE_BACKUP_DIR="$(realpath "$GOMOVE_BACKUP_DIR")"
  [[ "$GOMOVE_BACKUP_DIR" = /* ]] || fail 'Backup directory must be absolute.'
  case "$GOMOVE_BACKUP_DIR" in
    /|"$repo_root"|"$repo_root"/*) fail 'Backup directory must be outside Git and cannot be /.' ;;
  esac
  [[ -f "$GOMOVE_BACKUP_DIR/.gomove-m573-backups" ]] || fail 'Backup directory lacks its M5.7.3 marker.'
  if [[ -n "$(find "$GOMOVE_BACKUP_DIR" -maxdepth 0 -perm /077 -print)" ]]; then
    fail 'Backup directory must not grant group or other access.'
  fi
}

require_external_env_file() {
  [[ -n "${GOMOVE_PROD_ENV_FILE:-}" && -f "$GOMOVE_PROD_ENV_FILE" ]] || fail 'Set GOMOVE_PROD_ENV_FILE to an existing path-only Compose environment file.'
  local script_dir repo_root resolved
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  repo_root="$(cd "$script_dir/../.." && pwd -P)"
  resolved="$(realpath "$GOMOVE_PROD_ENV_FILE")"
  case "$resolved" in
    "$repo_root"|"$repo_root"/*) fail 'Production environment file must be outside Git.' ;;
  esac
  GOMOVE_PROD_ENV_FILE="$resolved"
}

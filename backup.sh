#!/usr/bin/env bash

set -Eeuo pipefail

NOW="$(date +'%Y-%m-%d_%H-%M-%S')"
CONFIG="/home/alvin/projects/backup-script/.env"
[[ -r "$CONFIG" ]] || { echo "FATAL: missing $CONFIG" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"

# ===== Paths =====
PROJECT_ROOT="${BACKUP_DIR%/}/${PROJECT_NAME}"
RUN_DIR="${PROJECT_ROOT}/${NOW}"
PROJ_DIR="${RUN_DIR}/project"
DB_DIR="${RUN_DIR}/db"

mkdir -p "$PROJ_DIR" "$DB_DIR"

# ---- Logging ----
LOG_FILE="${RUN_DIR}/backup-${NOW}.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] %s\n' "$(ts)" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }

exec > >(tee -a "$LOG_FILE") 2>&1
trap 'ec=$?; ln=${BASH_LINENO[0]}; err "Aborted (exit=$ec) at line $ln"; exit $ec' ERR

# ===== Helpers =====
compress_cmd() {
  case "${COMPRESSOR:-zstd}" in
    zstd) echo "zstd -T0 -19 --long=31" ;;
    xz)   echo "xz -T0 -9e" ;;
    *)    echo "zstd -T0 -19 --long=31" ;;
  esac
}
archive_ext() {
  case "${COMPRESSOR:-zstd}" in
    zstd) echo "tar.zst" ;;
    xz)   echo "tar.xz" ;;
    *)    echo "tar.zst" ;;
  esac
}
build_tar_excludes() {
  local args=(); for e in ${EXCLUDES:-}; do args+=("--exclude=$e"); done
  printf '%s ' "${args[@]}"
}

# ---- Telegram (safe with set -u) ----
tg_enabled() { [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]; }
escape_json() { python3 - "$1" <<'PY'
import json,sys; print(json.dumps(sys.argv[1])[1:-1])
PY
}
tg_curl_json() {
  local method="${1:-}" data="${2:-}"
  [[ -z "$method" ]] && { warn "tg_curl_json called without method"; return 1; }
  local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/${method}"
  local out code; out="$(mktemp)"
  code=$(curl -sS -o "$out" -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$url" --data "$data" || true)
  if [[ "$code" != "200" ]]; then warn "Telegram ${method} failed ($code): $(head -c 200 "$out")"; fi
  rm -f "$out"
}
tg_text() {
  tg_enabled || return 0
  local msg="${1:-}"; [[ -z "$msg" ]] && return 0
  local safe; safe="$(escape_json "$msg")"
  tg_curl_json "sendMessage" "{\"chat_id\":\"${TG_CHAT_ID}\",\"text\":\"${safe}\",\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}" || true
}
tg_document() {
  tg_enabled || return 0
  local file="${1:-}" caption="${2:-}"
  [[ -z "$file" ]] && { warn "tg_document called without file"; return 1; }
  local out code; out="$(mktemp)"
  code=$(curl -sS -o "$out" -w "%{http_code}" -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F "chat_id=${TG_CHAT_ID}" -F "document=@${file}" -F "caption=${caption}" || true)
  if [[ "$code" != "200" ]]; then warn "Telegram sendDocument failed ($code): $(head -c 200 "$out")"; fi
  rm -f "$out"
}
split_if_needed_and_send() {
  local file="${1:-}" caption="${2:-}" max_mb="${SPLIT_SIZE_MB:-1950}"
  [[ -z "$file" ]] && { warn "split_if_needed_and_send called without file"; return 1; }
  local size_mb=$(( $(stat -c%s "$file") / 1024 / 1024 ))
  if (( size_mb > max_mb )); then
    info "Splitting $(basename "$file") ${size_mb}MB to <= ${max_mb}MB parts"
    ( cd "$(dirname "$file")" && split -b "${max_mb}m" -d -a 3 "$(basename "$file")" "$(basename "$file").part" )
    rm -f "$file"
    local idx=0 p; for p in "$(dirname "$file")"/"$(basename "$file")".part*; do
      idx=$((idx+1)); tg_document "$p" "${caption} (part ${idx})"
    done
  else
    tg_document "$file" "$caption"
  fi
}

# ===== MySQL dump =====
dump_mysql() {
  [[ "${ENABLE_DB_BACKUP:-no}" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || { info "DB: disabled"; return 0; }
  [[ -n "${DB_NAME:-}" ]] || { err "DB: missing DB_NAME"; return 1; }
  command -v mysqldump >/dev/null || { err "DB: mysqldump not found"; return 1; }

  local CNF="${RUN_DIR}/.my.cnf"
  {
    echo "[client]"
    echo "user=${DB_USER:-root}"
    [[ -n "${DB_PASS:-}" ]] && echo "password=${DB_PASS}"
    [[ -n "${DB_HOST:-}" ]] && echo "host=${DB_HOST}"
    [[ -n "${DB_PORT:-}" ]] && echo "port=${DB_PORT}"
    [[ -n "${DB_SOCKET:-}" ]] && echo "socket=${DB_SOCKET}"
  } > "$CNF"; chmod 0600 "$CNF"

  local SQL="${DB_DIR}/${PROJECT_NAME}-db-${NOW}.sql"
  info "DB: dumping -> ${SQL}"
  mysqldump --defaults-extra-file="$CNF" --single-transaction --quick --routines --triggers --events \
            --set-gtid-purged=OFF ${DB_EXTRA_OPTS:-} "${DB_NAME}" > "$SQL"
  rm -f "$CNF"
  ( cd "$DB_DIR" && sha256sum * > "db-${NOW}.sha256" ) || true
  info "DB: dump size $(du -h "$SQL" | awk '{print $1}')"
}

# ===== Main =====
info "=== ${PROJECT_NAME} backup started ${NOW} ==="
tg_text "🚀 Starting backup of <b>${PROJECT_NAME}</b> at <code>${NOW}</code>"

[[ -d "$SOURCE_DIR" ]] || { err "SOURCE_DIR does not exist: $SOURCE_DIR"; exit 2; }

NICE=(nice "-n" "${NICE_LEVEL:-10}")
IONICE=(ionice "-c" "${IONICE_CLASS:-2}" "-n" "${IONICE_PRIORITY:-7}")

# 1) DB dump
dump_mysql

# 2) Project archive (to project/)
ARCHIVE_NAME="${PROJECT_NAME}-project-${NOW}.$(archive_ext)"
ARCHIVE_PATH="${PROJ_DIR}/${ARCHIVE_NAME}"
EXCLUDE_ARGS=($(build_tar_excludes))
COMPRESSOR_CMD="$(compress_cmd)"

info "Project: archiving -> $ARCHIVE_PATH"
"${IONICE[@]}" "${NICE[@]}" bash -c "
  tar --numeric-owner ${EXCLUDE_ARGS[*]} -cf - -C \"${SOURCE_DIR}\" . \
  | ${COMPRESSOR_CMD} -o \"${ARCHIVE_PATH}\"
"

# 3) Optional GPG on project archive
if [[ "${ENABLE_GPG:-no}" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
  info "Encrypting project archive for ${GPG_RECIPIENT}"
  gpg --yes --batch --trust-model always -r "$GPG_RECIPIENT" -o "${ARCHIVE_PATH}.gpg" -e "$ARCHIVE_PATH"
  rm -f "$ARCHIVE_PATH"; ARCHIVE_PATH="${ARCHIVE_PATH}.gpg"
fi

# 4) Checksums (project archive)
info "Checksumming project archive..."
( cd "$PROJ_DIR" && sha256sum "$(basename "$ARCHIVE_PATH")" > "$(basename "$ARCHIVE_PATH").sha256" )

# 5) Telegram upload (project archive + checksum only)
if tg_enabled; then
  info "Uploading project archive to Telegram..."
  split_if_needed_and_send "$ARCHIVE_PATH" "Backup ${PROJECT_NAME} ${NOW}"
  tg_document "${PROJ_DIR}/$(basename "$ARCHIVE_PATH").sha256" "SHA-256 ${PROJECT_NAME} ${NOW}"
else
  warn "Telegram not configured; skipping upload."
fi

# 6) Retention
info "Retention: removing run-folders under ${PROJECT_ROOT} older than ${RETAIN_DAYS} days"
find "$PROJECT_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"${RETAIN_DAYS}" -print -exec rm -rf {} +

info "=== ${PROJECT_NAME} backup completed ${NOW} ==="

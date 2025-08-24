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

final_notification() {
  local exit_code=$?
  sync

  if [[ -f "${LOG_FILE}" ]]; then
    tg_document "${LOG_FILE}" "Backup log for ${PROJECT_NAME} (${NOW})"
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    tg_text "✅ Backup completed successfully for <b>${PROJECT_NAME}</b>"
  else
    tg_text "❌ Backup FAILED for <b>${PROJECT_NAME}</b> (exit code: ${exit_code})"
  fi

  sleep 2
}

# ===== Helpers =====
tg_enabled() { [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]; }

escape_json() { python3 - "$1" <<'PY'
import json,sys; print(json.dumps(sys.argv[1])[1:-1])
PY
}

tg_curl() {
  local url="$1" out_file="$2"; shift 2
  local http_code
  http_code=$(curl -sS -o "$out_file" -w "%{http_code}" "$url" "$@" || true)
  if [[ "$http_code" != "200" ]]; then
    printf '[%s] %s\n' "$(ts)" "WARN  Telegram API failed ($http_code) for ${url}: $(head -c 200 "$out_file")" >&2
  fi
}

tg_text() {
  tg_enabled || return 0
  local msg="${1:-}"; [[ -z "$msg" ]] && return 0
  local safe; safe="$(escape_json "$msg")"
  local data="{\"chat_id\":\"${TG_CHAT_ID}\",\"text\":\"${safe}\",\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}"
  local out; out="$(mktemp)"
  tg_curl "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" "$out" \
    -H 'Content-Type: application/json' -X POST --data "$data"
  rm -f "$out"
}

exec > >(tee -a "$LOG_FILE") 2>&1
trap 'ec=$?; ln=${BASH_LINENO[0]}; err "Aborted (exit=$ec) at line $ln"; final_notification; exit $ec' ERR
trap final_notification EXIT

COMPRESSOR_CMD=""
ARCHIVE_EXT="tar"
DB_ARCHIVE_EXT=""
case "${COMPRESSOR:-}" in
  zstd)
    COMPRESSOR_CMD="zstd -T0 -19 --long=31"
    ARCHIVE_EXT="tar.zst"
    DB_ARCHIVE_EXT="zst"
    ;;
  xz)
    COMPRESSOR_CMD="xz -T0 -9e -c"
    ARCHIVE_EXT="tar.xz"
    DB_ARCHIVE_EXT="xz"
    ;;
  "")
    info "Compression is disabled."
    ;;
  *)
    warn "Unknown COMPRESSOR '${COMPRESSOR}', disabling compression."
    COMPRESSOR=""
    ;;
esac

build_tar_excludes_array() {
  TAR_EXCLUDE_ARGS=()
  for e in ${EXCLUDES:-}; do
    TAR_EXCLUDE_ARGS+=("--exclude=$e")
  done
}

tg_document() {
  tg_enabled || return 0
  local file="${1:-}" caption="${2:-}"
  [[ -f "$file" ]] || { warn "tg_document called with non-existent file: $file"; return 1; }
  local out; out="$(mktemp)"
  tg_curl "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" "$out" \
    -F "chat_id=${TG_CHAT_ID}" -F "document=@${file}" -F "caption=${caption}"
  rm -f "$out"
}

split_if_needed_and_send() {
  local file="${1:-}" caption="${2:-}" max_mb="${SPLIT_SIZE_MB:-1950}"
  [[ -f "$file" ]] || { warn "split_if_needed_and_send called with non-existent file: $file"; return 1; }
  local size_mb=$(( $(stat -c%s "$file") / 1024 / 1024 ))
  if (( size_mb > max_mb )); then
    info "Splitting $(basename "$file") ${size_mb}MB to <= ${max_mb}MB parts"
    local split_dir; split_dir="$(dirname "$file")"
    local split_base; split_base="$(basename "$file")"
    ( cd "$split_dir" && split -b "${max_mb}m" -d -a 3 "$split_base" "${split_base}.part" )
    rm -f "$file"
    local idx=0 p; for p in "${split_dir}/${split_base}".part*; do
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

  local cnf_file="${RUN_DIR}/.my.cnf"
  {
    echo "[client]"; echo "user=${DB_USER:-root}"
    [[ -n "${DB_PASS:-}" ]] && echo "password=${DB_PASS}"
    [[ -n "${DB_HOST:-}" ]] && echo "host=${DB_HOST}"
    [[ -n "${DB_PORT:-}" ]] && echo "port=${DB_PORT}"
    [[ -n "${DB_SOCKET:-}" ]] && echo "socket=${DB_SOCKET}"
  } > "$cnf_file"; chmod 0600 "$cnf_file"

  local out_file="${DB_DIR}/${PROJECT_NAME}-db-${NOW}.sql"
  [[ -n "$DB_ARCHIVE_EXT" ]] && out_file="${out_file}.${DB_ARCHIVE_EXT}"
  [[ "${ENABLE_GPG:-no}" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] && out_file="${out_file}.gpg"
  info "DB: dumping -> ${out_file}"

  local dump_cmd
  dump_cmd=( mysqldump --defaults-extra-file="'${cnf_file}'" --single-transaction --quick
             --routines --triggers --events --set-gtid-purged=OFF
             ${DB_EXTRA_OPTS:-} "'${DB_NAME}'" )

  local pipeline_str="${dump_cmd[*]}"

  if [[ -n "$COMPRESSOR_CMD" ]]; then
    pipeline_str+=" | ${COMPRESSOR_CMD}"
  fi
  if [[ "${ENABLE_GPG:-no}" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
    pipeline_str+=" | gpg --yes --batch --trust-model always -r '${GPG_RECIPIENT}' -e"
  fi

  "${IONICE[@]}" "${NICE[@]}" bash -c "${pipeline_str} > '${out_file}'"

  rm -f "$cnf_file"
  ( cd "$DB_DIR" && sha256sum "$(basename "$out_file")" > "db-${NOW}.sha256" ) || true
  info "DB: artifact $(du -h "$out_file" | awk '{print $1}')"

  export LAST_DB_FILE="$out_file"
  export LAST_DB_SHA="${DB_DIR}/db-${NOW}.sha256"
}

# ===== Main =====
info "=== ${PROJECT_NAME} backup started ${NOW} ==="
tg_text "🚀 Starting backup of <b>${PROJECT_NAME}</b> at <code>${NOW}</code>"

[[ -d "$SOURCE_DIR" ]] || { err "SOURCE_DIR does not exist: $SOURCE_DIR"; exit 2; }

NICE=(nice "-n" "${NICE_LEVEL:-10}")
IONICE=(ionice "-c" "${IONICE_CLASS:-2}" "-n" "${IONICE_PRIORITY:-7}")

# 1) DB dump and optional upload
dump_mysql
if [[ "${ENABLE_DB_BACKUP:-no}" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] && tg_enabled; then
  info "Uploading DB dump to Telegram..."
  split_if_needed_and_send "${LAST_DB_FILE:-}" "DB dump ${PROJECT_NAME} ${NOW} (database: ${DB_NAME})"
  tg_document "${LAST_DB_SHA:-}" "DB SHA-256 ${PROJECT_NAME} ${NOW}"
fi

# 2) Project archive
build_tar_excludes_array
ARCHIVE_NAME="${PROJECT_NAME}-project-${NOW}.${ARCHIVE_EXT}"
ARCHIVE_PATH="${PROJ_DIR}/${ARCHIVE_NAME}"
info "Project: archiving -> $ARCHIVE_PATH"

tar_cmd=(tar --numeric-owner "${TAR_EXCLUDE_ARGS[@]}" -cf - -C "'$SOURCE_DIR'" .)
pipeline_str="${tar_cmd[*]}"
if [[ -n "$COMPRESSOR_CMD" ]]; then
  pipeline_str+=" | ${COMPRESSOR_CMD}"
fi
"${IONICE[@]}" "${NICE[@]}" bash -c "${pipeline_str} > '${ARCHIVE_PATH}'"

# 3) Optional GPG on project archive
if [[ "${ENABLE_GPG:-no}" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
  info "Encrypting project archive for ${GPG_RECIPIENT}"
  gpg --yes --batch --trust-model always -r "$GPG_RECIPIENT" -o "${ARCHIVE_PATH}.gpg" -e "$ARCHIVE_PATH"
  rm -f "$ARCHIVE_PATH"; ARCHIVE_PATH="${ARCHIVE_PATH}.gpg"
fi

# 4) Checksums (project archive)
info "Checksumming project archive..."
( cd "$PROJ_DIR" && sha256sum "$(basename "$ARCHIVE_PATH")" > "$(basename "$ARCHIVE_PATH").sha256" )

# 5) Telegram upload (project archive + checksum)
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
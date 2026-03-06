#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env"
DATA_DIR="./data"
CERT_DIR="${DATA_DIR}/pq_proxy_certs"
TOR_HS_DIR="${DATA_DIR}/tor_hs_data/hs"
OPENWEBUI_DATA_DIR="${DATA_DIR}/open_webui_data"
CERT_KEY_FILE="${CERT_DIR}/key.pem"
CERT_PEM_FILE="${CERT_DIR}/cert.pem"

SECRET_KEY_VAR="WEBUI_SECRET_KEY"
WEBUI_UID_VAR="WEBUI_UID"
WEBUI_GID_VAR="WEBUI_GID"
TOR_UID_VAR="TOR_UID"
TOR_GID_VAR="TOR_GID"
OLLAMA_BASE_URL_VAR="OLLAMA_BASE_URL"

DEFAULT_OLLAMA_BASE_URL="http://172.30.10.10:11434"
LEGACY_OLLAMA_BASE_URL="http://host.docker.internal:11434"
LEGACY_INTERNAL_OLLAMA_BASE_URL="http://ollama-proxy:11434"
CERT_TOOL_IMAGE_TAG="alpine:3.23.3"
CERT_TOOL_IMAGE_DIGEST="alpine@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659"

USE_COLOR=false
if [[ -t 1 ]]; then
  USE_COLOR=true
fi

DOCKER_COMPOSE=()

print_color() {
  local color="$1"
  shift
  if [[ "$USE_COLOR" == "true" ]]; then
    printf "\033[%sm%s\033[0m\n" "$color" "$*"
  else
    printf "%s\n" "$*"
  fi
}

log_info() {
  print_color "0;33" "$*"
}

log_success() {
  print_color "0;32" "$*"
}

log_error() {
  print_color "0;31" "$*"
}

die() {
  log_error "Error: $*"
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  ./run.sh <command> [options]

Commands:
  init                  Prepare .env and certificates (idempotent)
  up [--no-build]       Initialize if needed, then start stack in background
  down                  Stop stack and remove containers/networks
  status                Show compose service status
  logs [args...]        Show compose logs (pass-through to docker compose logs)
  onion [--wait] [--timeout SEC]
                        Print onion hostname (optionally wait for it)
  reset --force         Stop stack and delete Tor/WebUI data + TLS certs
  fresh --force [--no-build]
                        Reset data, reinitialize, then start stack
  help                  Show this help

Examples:
  ./run.sh init
  ./run.sh up
  ./run.sh up --no-build
  ./run.sh onion --wait --timeout 120
  ./run.sh logs -f pq-proxy
  ./run.sh reset --force
  ./run.sh fresh --force
USAGE
}

detect_docker_compose() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE=(docker-compose)
  else
    die "Neither 'docker compose' nor 'docker-compose' is available."
  fi
}

require_docker_daemon() {
  command -v docker >/dev/null 2>&1 || die "Docker CLI not found."
  docker info >/dev/null 2>&1 || die "Docker daemon is not running or not reachable."
  detect_docker_compose
}

compose() {
  "${DOCKER_COMPOSE[@]}" "$@"
}

generate_secret_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    # Fallback if openssl is unavailable on host.
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

get_env_var() {
  local key="$1"
  local line

  [[ -f "$ENV_FILE" ]] || return 1
  line="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 || true)"
  [[ -n "$line" ]] || return 1
  printf "%s\n" "${line#*=}"
}

set_env_var() {
  local key="$1"
  local value="$2"
  local tmp_file

  tmp_file="$(mktemp)"
  if [[ -f "$ENV_FILE" ]]; then
    awk -v key="$key" -v value="$value" '
      BEGIN { updated=0 }
      $0 ~ ("^" key "=") {
        if (!updated) {
          print key "=" value
          updated=1
        }
        next
      }
      { print }
      END {
        if (!updated) {
          print key "=" value
        }
      }
    ' "$ENV_FILE" > "$tmp_file"
  else
    printf "%s=%s\n" "$key" "$value" > "$tmp_file"
  fi

  mv "$tmp_file" "$ENV_FILE"
}

ensure_env_var() {
  local key="$1"
  local value="$2"

  if [[ -z "$(get_env_var "$key" || true)" ]]; then
    set_env_var "$key" "$value"
    log_success "Added ${key} to ${ENV_FILE}."
  fi
}

ensure_data_dirs() {
  mkdir -p "$CERT_DIR" "$TOR_HS_DIR" "$OPENWEBUI_DATA_DIR"
}

ensure_cert_helper_image() {
  if ! docker image inspect "$CERT_TOOL_IMAGE_TAG" >/dev/null 2>&1; then
    log_info "Pulling ${CERT_TOOL_IMAGE_TAG} helper image..."
    docker pull "$CERT_TOOL_IMAGE_TAG" >/dev/null
  fi
}

generate_tls_cert() {
  local cert_cn="$1"
  local cert_san="$2"

  ensure_cert_helper_image

  docker run --rm \
    -e CERT_CN="$cert_cn" \
    -e CERT_SAN="$cert_san" \
    -v "${SCRIPT_DIR}/data/pq_proxy_certs:/certs" \
    "$CERT_TOOL_IMAGE_DIGEST" \
    sh -ceu 'apk add --no-cache openssl >/dev/null && \
             openssl req -x509 \
               -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
               -keyout /certs/key.pem \
               -out /certs/cert.pem \
               -nodes -days 3650 \
               -subj "/CN=${CERT_CN}" \
               -addext "subjectAltName=DNS:${CERT_SAN}"'
}

read_cert_subject() {
  if command -v openssl >/dev/null 2>&1; then
    openssl x509 -in "$CERT_PEM_FILE" -noout -subject -nameopt RFC2253
  else
    ensure_cert_helper_image
    docker run --rm -v "${SCRIPT_DIR}/data/pq_proxy_certs:/certs:ro" \
      "$CERT_TOOL_IMAGE_DIGEST" \
      sh -ceu 'apk add --no-cache openssl >/dev/null && \
               openssl x509 -in /certs/cert.pem -noout -subject -nameopt RFC2253'
  fi
}

read_cert_san() {
  if command -v openssl >/dev/null 2>&1; then
    openssl x509 -in "$CERT_PEM_FILE" -noout -ext subjectAltName
  else
    ensure_cert_helper_image
    docker run --rm -v "${SCRIPT_DIR}/data/pq_proxy_certs:/certs:ro" \
      "$CERT_TOOL_IMAGE_DIGEST" \
      sh -ceu 'apk add --no-cache openssl >/dev/null && \
               openssl x509 -in /certs/cert.pem -noout -ext subjectAltName'
  fi
}

cert_matches_onion() {
  local onion="$1"
  local subject_line
  local san_block

  [[ -s "$CERT_KEY_FILE" && -s "$CERT_PEM_FILE" ]] || return 1

  subject_line="$(read_cert_subject 2>/dev/null || true)"
  san_block="$(read_cert_san 2>/dev/null || true)"

  grep -Fq "CN=${onion}" <<<"$subject_line" &&
    grep -Fq "DNS:${onion}" <<<"$san_block"
}

sync_cert_with_onion() {
  local onion="$1"

  if cert_matches_onion "$onion"; then
    log_success "TLS certificate already matches onion hostname (${onion})."
    return 0
  fi

  log_info "Updating TLS certificate to CN/SAN=${onion}..."
  generate_tls_cert "$onion" "$onion"
  [[ -s "$CERT_KEY_FILE" && -s "$CERT_PEM_FILE" ]] || die "Certificate regeneration failed."
  chmod 644 "$CERT_KEY_FILE" "$CERT_PEM_FILE"
  log_success "TLS certificate updated to CN/SAN=${onion}."

  log_info "Restarting pq-proxy to load updated certificate..."
  compose restart pq-proxy >/dev/null
}

ensure_env_file() {
  local host_uid
  local host_gid
  local current_secret
  local current_ollama

  host_uid="$(id -u)"
  host_gid="$(id -g)"

  if [[ ! -f "$ENV_FILE" ]]; then
    touch "$ENV_FILE"
    log_success "Created ${ENV_FILE}."
  fi

  current_secret="$(get_env_var "$SECRET_KEY_VAR" || true)"
  if [[ -z "$current_secret" ]]; then
    set_env_var "$SECRET_KEY_VAR" "$(generate_secret_key)"
    log_success "Generated ${SECRET_KEY_VAR} in ${ENV_FILE}."
  fi

  current_ollama="$(get_env_var "$OLLAMA_BASE_URL_VAR" || true)"
  if [[ "$current_ollama" == "$LEGACY_OLLAMA_BASE_URL" || "$current_ollama" == "$LEGACY_INTERNAL_OLLAMA_BASE_URL" ]]; then
    set_env_var "$OLLAMA_BASE_URL_VAR" "$DEFAULT_OLLAMA_BASE_URL"
    log_success "Migrated ${OLLAMA_BASE_URL_VAR} to ${DEFAULT_OLLAMA_BASE_URL}."
  fi

  ensure_env_var "$OLLAMA_BASE_URL_VAR" "$DEFAULT_OLLAMA_BASE_URL"
  ensure_env_var "$WEBUI_UID_VAR" "$host_uid"
  ensure_env_var "$WEBUI_GID_VAR" "$host_gid"
  ensure_env_var "$TOR_UID_VAR" "$host_uid"
  ensure_env_var "$TOR_GID_VAR" "$host_gid"

  log_success "Using WEBUI UID:GID $(get_env_var "$WEBUI_UID_VAR"):$(get_env_var "$WEBUI_GID_VAR")."
  log_success "Using TOR UID:GID $(get_env_var "$TOR_UID_VAR"):$(get_env_var "$TOR_GID_VAR")."
}

ensure_certs() {
  ensure_data_dirs

  if [[ -s "$CERT_KEY_FILE" && -s "$CERT_PEM_FILE" ]]; then
    log_success "TLS certificates already exist in ${CERT_DIR}."
  else
    log_info "Generating bootstrap ECDSA P-256 self-signed certificate..."
    generate_tls_cert "my-boringssl-onion-service" "my-boringssl-onion-service"

    [[ -s "$CERT_KEY_FILE" && -s "$CERT_PEM_FILE" ]] || die "Certificate generation failed."
    log_success "TLS certificates generated in ${CERT_DIR}."
  fi

  # pq-proxy runs as non-root; mounted cert/key must be world-readable.
  chmod 644 "$CERT_KEY_FILE" "$CERT_PEM_FILE"
}

wait_for_onion_hostname() {
  local timeout="$1"
  local interval=2
  local elapsed=0
  local hostname_file="${TOR_HS_DIR}/hostname"

  while (( elapsed < timeout )); do
    if [[ -s "$hostname_file" ]]; then
      cat "$hostname_file"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  return 1
}

show_access_hint() {
  local onion="${1:-}"

  if [[ -z "$onion" ]]; then
    if onion="$(wait_for_onion_hostname 90)"; then
      log_success "Tor hidden service: https://${onion}"
    else
      log_info "Tor hostname not ready yet. Check later with: ./run.sh onion --wait"
    fi
  else
    log_success "Tor hidden service: https://${onion}"
  fi

  printf "\n"
  log_info "Access notes:"
  printf "%s\n" "  - Open the onion URL in Tor Browser."
  printf "%s\n" "  - Self-signed cert warning is expected in this setup (CN/SAN now follows your onion hostname)."
  printf "%s\n" "  - Strict PQ-only TLS policy is enforced at pq-proxy."
}

wipe_persistent_data() {
  ensure_data_dirs

  if [[ -d "$TOR_HS_DIR" ]]; then
    find "$TOR_HS_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi

  if [[ -d "$OPENWEBUI_DATA_DIR" ]]; then
    find "$OPENWEBUI_DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi

  rm -f "$CERT_KEY_FILE" "$CERT_PEM_FILE"
}

cmd_init() {
  [[ $# -eq 0 ]] || die "init does not accept positional arguments."

  require_docker_daemon
  ensure_env_file
  ensure_certs

  log_success "Initialization complete."
}

cmd_up() {
  local build=true
  local onion

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-build)
        build=false
        ;;
      *)
        die "Unknown option for up: $1"
        ;;
    esac
    shift
  done

  require_docker_daemon
  ensure_env_file
  ensure_certs

  if [[ "$build" == "true" ]]; then
    log_info "Starting services with build..."
    compose up --build -d
  else
    log_info "Starting services without build..."
    compose up -d
  fi

  onion="$(wait_for_onion_hostname 120 || true)"
  if [[ -n "$onion" ]]; then
    sync_cert_with_onion "$onion"
  else
    log_info "Tor hostname not available yet; certificate CN/SAN sync will happen on next './run.sh up'."
  fi

  log_success "Stack started successfully."
  show_access_hint "$onion"
}

cmd_down() {
  [[ $# -eq 0 ]] || die "down does not accept positional arguments."

  require_docker_daemon
  log_info "Stopping services..."
  compose down --remove-orphans
  log_success "Stack stopped."
}

cmd_status() {
  [[ $# -eq 0 ]] || die "status does not accept positional arguments."

  require_docker_daemon
  compose ps
}

cmd_logs() {
  require_docker_daemon
  compose logs "$@"
}

cmd_onion() {
  local wait=false
  local timeout=60
  local onion

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wait)
        wait=true
        ;;
      --timeout)
        shift
        [[ $# -gt 0 ]] || die "--timeout requires a value in seconds."
        timeout="$1"
        ;;
      *)
        die "Unknown option for onion: $1"
        ;;
    esac
    shift
  done

  [[ "$timeout" =~ ^[0-9]+$ ]] || die "timeout must be an integer (seconds)."

  if onion="$(wait_for_onion_hostname 1)"; then
    printf "%s\n" "$onion"
    return 0
  fi

  if [[ "$wait" == "true" ]]; then
    if onion="$(wait_for_onion_hostname "$timeout")"; then
      printf "%s\n" "$onion"
      return 0
    fi
    die "Timed out after ${timeout}s waiting for ${TOR_HS_DIR}/hostname"
  fi

  die "Onion hostname not found yet. Run './run.sh onion --wait' or check './run.sh status'."
}

cmd_reset() {
  local force=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        force=true
        ;;
      *)
        die "Unknown option for reset: $1"
        ;;
    esac
    shift
  done

  [[ "$force" == "true" ]] || die "reset is destructive and requires --force"

  require_docker_daemon
  log_info "Stopping services before reset..."
  compose down --remove-orphans || true

  log_info "Deleting Tor keys, WebUI data, and TLS certificates..."
  wipe_persistent_data
  log_success "Reset complete."
}

cmd_fresh() {
  local force=false
  local build=true
  local onion

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        force=true
        ;;
      --no-build)
        build=false
        ;;
      *)
        die "Unknown option for fresh: $1"
        ;;
    esac
    shift
  done

  [[ "$force" == "true" ]] || die "fresh is destructive and requires --force"

  require_docker_daemon

  log_info "Stopping existing stack..."
  compose down --remove-orphans || true

  log_info "Resetting persistent data..."
  wipe_persistent_data

  ensure_env_file
  ensure_certs

  if [[ "$build" == "true" ]]; then
    log_info "Starting fresh stack with build..."
    compose up --build -d
  else
    log_info "Starting fresh stack without build..."
    compose up -d
  fi

  onion="$(wait_for_onion_hostname 120 || true)"
  if [[ -n "$onion" ]]; then
    sync_cert_with_onion "$onion"
  else
    log_info "Tor hostname not available yet; certificate CN/SAN sync will happen on next './run.sh up'."
  fi

  log_success "Fresh instance started successfully."
  show_access_hint "$onion"
}

main() {
  local command="${1:-help}"

  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$command" in
    init)
      cmd_init "$@"
      ;;
    up|start)
      cmd_up "$@"
      ;;
    down|stop)
      cmd_down "$@"
      ;;
    status|ps)
      cmd_status "$@"
      ;;
    logs)
      cmd_logs "$@"
      ;;
    onion)
      cmd_onion "$@"
      ;;
    reset)
      cmd_reset "$@"
      ;;
    fresh)
      cmd_fresh "$@"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage
      die "Unknown command: ${command}"
      ;;
  esac
}

main "$@"

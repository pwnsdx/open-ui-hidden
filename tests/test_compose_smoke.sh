#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE=(docker-compose)
else
  fail "docker compose (or docker-compose) is required"
fi

ENV_FILE="$(mktemp)"
STARTED_STACK="false"

cleanup() {
  if [[ "$STARTED_STACK" == "true" ]]; then
    "${DOCKER_COMPOSE[@]}" --env-file "$ENV_FILE" down --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

cat >"$ENV_FILE" <<EOF
WEBUI_SECRET_KEY=ci_secret_key_for_tests_only
OLLAMA_BASE_URL=http://ollama-proxy:11434
WEBUI_UID=${HOST_UID}
WEBUI_GID=${HOST_GID}
TOR_UID=${HOST_UID}
TOR_GID=${HOST_GID}
EOF

mkdir -p ./data/pq_proxy_certs ./data/tor_hs_data/hs ./data/open_webui_data

if [[ ! -s ./data/pq_proxy_certs/key.pem || ! -s ./data/pq_proxy_certs/cert.pem ]]; then
  echo "[smoke] generating self-signed certificate for pq-proxy"
  openssl req -x509 \
    -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout ./data/pq_proxy_certs/key.pem \
    -out ./data/pq_proxy_certs/cert.pem \
    -nodes -days 3650 \
    -subj "/CN=ci-pq-proxy"
fi

if docker ps --format '{{.Names}}' | grep -qx 'pq-nginx-proxy-kyber768'; then
  echo "[smoke] reusing existing running stack"
else
  echo "[smoke] starting docker compose stack"
  "${DOCKER_COMPOSE[@]}" --env-file "$ENV_FILE" up -d --build
  STARTED_STACK="true"
fi

wait_health() {
  local container="$1"
  local timeout_sec="${2:-180}"
  local elapsed=0
  local status

  while (( elapsed < timeout_sec )); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    if [[ "$status" == "healthy" || "$status" == "running" ]]; then
      echo "[smoke] ${container}: ${status}"
      return 0
    fi
    if [[ "$status" == "unhealthy" || "$status" == "exited" || "$status" == "dead" ]]; then
      echo "[smoke] ${container} entered terminal state: ${status}" >&2
      docker ps -a --filter "name=$container" || true
      docker logs --tail=200 "$container" || true
      return 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done

  echo "[smoke] ${container} health timeout. Current status: ${status:-unknown}" >&2
  docker ps -a --filter "name=$container" || true
  docker logs --tail=200 "$container" || true
  return 1
}

echo "[smoke] waiting for services to become healthy"
# Tor can stay "starting" for several minutes in cold CI runners.
wait_health tor-hs-alpine 420
wait_health ollama-proxy 120
wait_health open-webui 180
wait_health pq-nginx-proxy-kyber768 180

echo "[smoke] validating compose/service state"
"${DOCKER_COMPOSE[@]}" ps
"${DOCKER_COMPOSE[@]}" exec -T pq-proxy nginx -t

CURVE_LINE="$("${DOCKER_COMPOSE[@]}" exec -T pq-proxy sh -lc "grep -n 'ssl_ecdh_curve' /etc/nginx/nginx.conf")"
echo "$CURVE_LINE"

if ! grep -q 'X25519MLKEM768:X25519Kyber768Draft00;' <<<"$CURVE_LINE"; then
  fail "pq-proxy is not enforcing the expected strict PQ-only curve list"
fi
if grep -q ':X25519;' <<<"$CURVE_LINE"; then
  fail "classical X25519 fallback is still present"
fi

echo "[smoke] probing TLS policy: classical X25519 handshake must fail"
set +e
TLS_PROBE_OUTPUT="$("${DOCKER_COMPOSE[@]}" exec -T webui sh -lc \
  "openssl s_client -connect pq-proxy:443 -servername pq-proxy -tls1_3 -groups X25519 -brief < /dev/null" 2>&1)"
TLS_PROBE_RC=$?
set -e

echo "$TLS_PROBE_OUTPUT"

if [[ "$TLS_PROBE_RC" -eq 0 ]]; then
  fail "classical X25519 handshake unexpectedly succeeded"
fi

if ! grep -Eiq 'handshake failure|alert handshake failure|no suitable key share' <<<"$TLS_PROBE_OUTPUT"; then
  fail "unexpected TLS probe failure mode: expected a handshake/key-share rejection"
fi

echo "[smoke] all checks passed"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

COMPOSE_FILES=(
  -f docker-compose.yml
  -f tests/docker-compose.smoke.override.yml
)

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

if docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE=(docker compose "${COMPOSE_FILES[@]}")
elif command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE=(docker-compose "${COMPOSE_FILES[@]}")
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
OLLAMA_BASE_URL=http://172.30.10.10:11434
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

# CI runs pq-proxy as non-root nginx user; ensure mounted cert/key are readable.
chmod 644 ./data/pq_proxy_certs/cert.pem ./data/pq_proxy_certs/key.pem

if docker ps --format '{{.Names}}' | grep -qx 'pq-nginx-proxy-kyber768'; then
  echo "[smoke] reusing existing running stack"
else
  echo "[smoke] building tor/tor-http-proxy/webui-fw/ollama-proxy/pq-proxy images"
  "${DOCKER_COMPOSE[@]}" --env-file "$ENV_FILE" build tor tor-http-proxy webui-fw ollama-proxy pq-proxy
  echo "[smoke] pulling lightweight webui image"
  "${DOCKER_COMPOSE[@]}" --env-file "$ENV_FILE" pull webui
  echo "[smoke] starting docker compose stack"
  "${DOCKER_COMPOSE[@]}" --env-file "$ENV_FILE" up -d --no-build
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
wait_health tor-http-proxy 120
wait_health open-webui-fw 120
wait_health ollama-proxy 120
wait_health open-webui 180
wait_health pq-nginx-proxy-kyber768 180

echo "[smoke] validating compose/service state"
"${DOCKER_COMPOSE[@]}" ps
"${DOCKER_COMPOSE[@]}" exec -T pq-proxy nginx -t

echo "[smoke] checking webui network whitelist"
"${DOCKER_COMPOSE[@]}" exec -T webui sh -lc \
  "python3 -c \"import socket; s=socket.create_connection(('172.30.10.10', 11434), 3); s.close()\""
"${DOCKER_COMPOSE[@]}" exec -T webui sh -lc \
  "python3 -c \"import socket; s=socket.create_connection(('172.30.11.10', 8118), 3); s.close()\""

set +e
DIRECT_EGRESS_OUTPUT="$("${DOCKER_COMPOSE[@]}" exec -T webui sh -lc \
  "python3 -c \"import socket; s=socket.create_connection(('1.1.1.1', 443), 3); s.close()\"" 2>&1)"
DIRECT_EGRESS_RC=$?
set -e
echo "$DIRECT_EGRESS_OUTPUT"
if [[ "$DIRECT_EGRESS_RC" -eq 0 ]]; then
  fail "webui unexpectedly reached the public internet directly"
fi

echo "[smoke] checking pq-proxy build surface"
NGINX_BUILD_INFO="$("${DOCKER_COMPOSE[@]}" exec -T pq-proxy nginx -V 2>&1)"
echo "$NGINX_BUILD_INFO"

for required_flag in \
  '--with-http_ssl_module' \
  '--with-http_v2_module' \
  '--without-select_module' \
  '--without-poll_module' \
  '--without-http_charset_module' \
  '--without-http_ssi_module' \
  '--without-http_userid_module' \
  '--without-http_access_module' \
  '--without-http_auth_basic_module' \
  '--without-http_mirror_module' \
  '--without-http_autoindex_module' \
  '--without-http_geo_module' \
  '--without-http_map_module' \
  '--without-http_split_clients_module' \
  '--without-http_referer_module' \
  '--without-http_rewrite_module' \
  '--without-http_fastcgi_module' \
  '--without-http_uwsgi_module' \
  '--without-http_scgi_module' \
  '--without-http_grpc_module' \
  '--without-http_memcached_module' \
  '--without-http_limit_req_module' \
  '--without-http_empty_gif_module' \
  '--without-http_browser_module' \
  '--without-http_upstream_hash_module' \
  '--without-http_upstream_ip_hash_module' \
  '--without-http_upstream_least_conn_module' \
  '--without-http_upstream_random_module' \
  '--without-http_upstream_zone_module' \
  '--add-dynamic-module=/usr/src/ngx_brotli'
do
  if ! grep -q -- "$required_flag" <<<"$NGINX_BUILD_INFO"; then
    fail "pq-proxy build is missing required nginx flag: $required_flag"
  fi
done

for unwanted_flag in \
  '--with-http_perl_module' \
  '--with-http_geoip_module' \
  '--with-http_image_filter_module' \
  '--with-http_xslt_module' \
  '--with-http_realip_module' \
  '--with-http_addition_module' \
  '--with-http_sub_module' \
  '--with-http_dav_module' \
  '--with-http_flv_module' \
  '--with-http_mp4_module' \
  '--with-http_gunzip_module' \
  '--with-http_gzip_static_module' \
  '--with-http_random_index_module' \
  '--with-http_secure_link_module' \
  '--with-http_stub_status_module' \
  '--with-http_auth_request_module' \
  '--with-http_limit_req_module' \
  '--with-pcre-jit' \
  '--with-threads' \
  '--with-stream' \
  '--with-mail' \
  '--with-http_v3_module' \
  '--with-compat' \
  '--with-file-aio'
do
  if grep -q -- "$unwanted_flag" <<<"$NGINX_BUILD_INFO"; then
    fail "pq-proxy build unexpectedly kept nginx flag: $unwanted_flag"
  fi
done

if "${DOCKER_COMPOSE[@]}" exec -T pq-proxy sh -lc 'test -e /usr/lib/nginx/modules/ngx_http_brotli_static_module.so'; then
  fail "unused ngx_http_brotli_static_module.so is still shipped in pq-proxy runtime image"
fi

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
  "openssl s_client -connect 172.30.10.30:443 -servername pq-proxy -tls1_3 -groups X25519 -brief < /dev/null" 2>&1)"
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

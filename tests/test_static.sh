#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$file"; then
    fail "$message"
  fi
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if grep -Eq "$pattern" "$file"; then
    fail "$message"
  fi
}

echo "[static] checking bash syntax"
bash -n "$ROOT_DIR/run.sh"
bash -n "$ROOT_DIR/scripts/update-image-digests.sh"
bash -n "$ROOT_DIR/tests/test_static.sh"
bash -n "$ROOT_DIR/tests/test_compose_smoke.sh"

if command -v shellcheck >/dev/null 2>&1; then
  echo "[static] running shellcheck"
  shellcheck \
    "$ROOT_DIR/run.sh" \
    "$ROOT_DIR/scripts/update-image-digests.sh" \
    "$ROOT_DIR/tests/test_static.sh" \
    "$ROOT_DIR/tests/test_compose_smoke.sh"
else
  echo "[static] shellcheck not found, skipping"
fi

echo "[static] checking strict PQ-only TLS config"
assert_contains \
  "$ROOT_DIR/docker/pq-proxy/nginx.conf" \
  'ssl_ecdh_curve[[:space:]]+X25519MLKEM768:X25519Kyber768Draft00;' \
  "nginx.conf must enforce X25519MLKEM768:X25519Kyber768Draft00"

assert_not_contains \
  "$ROOT_DIR/docker/pq-proxy/nginx.conf" \
  'ssl_ecdh_curve[[:space:]].*:X25519;' \
  "nginx.conf must not allow classical X25519 fallback"
assert_not_contains \
  "$ROOT_DIR/docker/pq-proxy/nginx.conf" \
  'load_module[[:space:]]+modules/ngx_http_brotli_static_module\.so;' \
  "nginx.conf should not load the unused brotli static module"
assert_not_contains \
  "$ROOT_DIR/docker/pq-proxy/nginx.conf" \
  'brotli_static[[:space:]]+on;' \
  "nginx.conf should not enable unused brotli_static handling"
assert_not_contains \
  "$ROOT_DIR/docker/pq-proxy/nginx.conf" \
  'pcre_jit[[:space:]]+on;' \
  "nginx.conf should not enable pcre_jit when regex modules are removed"
assert_contains \
  "$ROOT_DIR/docker/pq-proxy/nginx.conf" \
  'client_max_body_size[[:space:]]+25m;' \
  "nginx.conf must cap request body size at the pq-proxy edge"
assert_contains \
  "$ROOT_DIR/docker/pq-proxy/nginx.conf" \
  "limit_conn_zone[[:space:]]+\\\$server_name[[:space:]]+zone=global_conn:1m;" \
  "nginx.conf must enforce a global connection cap for the onion edge"
assert_contains \
  "$ROOT_DIR/docker/pq-proxy/nginx.conf" \
  'proxy_connect_timeout[[:space:]]+5s;' \
  "nginx.conf must use strict upstream connect timeouts"

echo "[static] checking tor package install is CI-safe"
assert_not_contains \
  "$ROOT_DIR/docker/tor/Dockerfile" \
  'apk add --no-cache[[:space:]]+tor=' \
  "docker/tor/Dockerfile must not pin exact tor apk revision"
assert_contains \
  "$ROOT_DIR/docker/tor/Dockerfile" \
  'apk add --no-cache[[:space:]]+tor([[:space:]]|$)' \
  "docker/tor/Dockerfile must install tor package"

echo "[static] checking changelog/release metadata"
assert_contains \
  "$ROOT_DIR/CHANGELOG.md" \
  '^## \[Unreleased\]' \
  "CHANGELOG.md must contain an [Unreleased] section"

echo "[static] checking compose file parses cleanly"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f "$ROOT_DIR/docker-compose.yml" config >/dev/null
  docker compose -f "$ROOT_DIR/docker-compose.yml" -f "$ROOT_DIR/tests/docker-compose.smoke.override.yml" config >/dev/null
else
  echo "[static] docker compose not available, skipping compose parse check"
fi

echo "[static] checking smoke override keeps webui lightweight"
assert_contains \
  "$ROOT_DIR/tests/docker-compose.smoke.override.yml" \
  'image:[[:space:]]*python:3\.12-slim@sha256:' \
  "smoke override must use a lightweight webui image"

echo "[static] checking mutable upstream images are pinned by digest"
assert_contains \
  "$ROOT_DIR/docker/webui/Dockerfile" \
  '^FROM[[:space:]]+ghcr\.io/open-webui/open-webui:0\.8\.8-ollama@sha256:' \
  "docker/webui/Dockerfile must pin Open WebUI by digest"
assert_contains \
  "$ROOT_DIR/docker/ollama-proxy/Dockerfile" \
  '^FROM[[:space:]]+nginx:1\.28-alpine@sha256:' \
  "docker/ollama-proxy/Dockerfile must pin nginx by digest"
assert_contains \
  "$ROOT_DIR/scripts/update-image-digests.sh" \
  'ghcr\.io/open-webui/open-webui:0\.8\.8-ollama' \
  "update-image-digests.sh must track the pinned Open WebUI image"
assert_contains \
  "$ROOT_DIR/scripts/update-image-digests.sh" \
  'nginx:1\.28-alpine' \
  "update-image-digests.sh must track the pinned nginx image"
assert_contains \
  "$ROOT_DIR/scripts/update-image-digests.sh" \
  'python:3\.12-slim' \
  "update-image-digests.sh must track the pinned smoke-test image"

echo "[static] checking Linux host gateway mapping for ollama-proxy"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'host\.docker\.internal:host-gateway' \
  "docker-compose.yml must map host.docker.internal to host-gateway for Linux CI"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  '"1234"[[:space:]]*# Expose OpenAI-compatible passthrough \(LM Studio\)' \
  "ollama-proxy must expose internal port 1234 for OpenAI-compatible host backends"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  '/app/backend/open_webui/static:rw,noexec,nosuid,nodev,uid=\$\{WEBUI_UID:-1000\},gid=\$\{WEBUI_GID:-1000\},mode=0700' \
  "webui static tmpfs must be isolated and owned by the runtime user"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'HTTP_PROXY=http://tor-http-proxy:8118' \
  "webui must route outbound HTTP through the dedicated tor-http-proxy sidecar"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'HTTPS_PROXY=http://tor-http-proxy:8118' \
  "webui must route outbound HTTPS through the dedicated tor-http-proxy sidecar"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'ALL_PROXY=http://tor-http-proxy:8118' \
  "webui must route generic proxy-aware traffic through the dedicated tor-http-proxy sidecar"
assert_not_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'ollama-proxy:127\.0\.0\.1' \
  "webui should not need loopback host overrides once proxychains is removed"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'tor-http-proxy' \
  "compose must define a dedicated Tor HTTP proxy sidecar"

echo "[static] checking tor service user mapping"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'user:[[:space:]]*"\$\{TOR_UID:-1000\}:\$\{TOR_GID:-1000\}"' \
  "tor service must run with host-mapped UID/GID"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'tor-hidden-internal' \
  "compose must define a dedicated hidden-service network for Tor"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'tor-socks-internal' \
  "compose must define a dedicated SOCKS network for Tor egress"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'webui-egress' \
  "compose must define a dedicated egress network between webui and tor-http-proxy"
assert_not_contains \
  "$ROOT_DIR/docker-compose.yml" \
  '^[[:space:]]*-[[:space:]]*tor-internal$|^[[:space:]]*tor-internal:' \
  "legacy shared tor-internal network should be removed"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  '/var/cache/nginx:rw,noexec,nosuid,nodev,uid=101,gid=101,mode=0700' \
  "nginx tmpfs mounts must be hardened and owned by the nginx runtime user"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  '/tmp:rw,noexec,nosuid,nodev,uid=\$\{WEBUI_UID:-1000\},gid=\$\{WEBUI_GID:-1000\},mode=0700' \
  "webui tmpfs mounts must be hardened and owned by the runtime user"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'pids_limit:[[:space:]]*\$\{PQ_PROXY_PIDS_LIMIT:-128\}' \
  "pq-proxy must set a default pids limit"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'mem_limit:[[:space:]]*"\$\{WEBUI_MEM_LIMIT:-2g\}"' \
  "webui must set a default memory limit"

echo "[static] checking tor entrypoint waits for pq-proxy DNS"
assert_contains \
  "$ROOT_DIR/docker/tor/entrypoint.sh" \
  'WAIT_HOST="\$\{TOR_UPSTREAM_HOST:-pq-proxy\}"' \
  "tor entrypoint must default DNS wait target to pq-proxy"
assert_contains \
  "$ROOT_DIR/docker/tor/entrypoint.sh" \
  'getent[[:space:]]+hosts[[:space:]]+"[\\$]WAIT_HOST"' \
  "tor entrypoint must wait for pq-proxy DNS before launching tor"

echo "[static] checking webui/tor dependency does not deadlock startup"
if ! awk '
  $1 == "webui:" {in_webui=1; next}
  in_webui && /^[^[:space:]]/ {in_webui=0}
  in_webui && $1 == "tor-http-proxy:" {found=1}
  END {exit found ? 0 : 1}
' "$ROOT_DIR/docker-compose.yml"; then
  fail "webui must depend on the dedicated tor-http-proxy sidecar"
fi
if ! awk '
  $1 == "tor-http-proxy:" {in_proxy=1; next}
  in_proxy && /^[^[:space:]]/ {in_proxy=0}
  in_proxy && $1 == "tor:" {found=1}
  END {exit found ? 0 : 1}
' "$ROOT_DIR/docker-compose.yml"; then
  fail "tor-http-proxy must depend on tor service_started to avoid tor/pq-proxy startup deadlock"
fi

echo "[static] checking proxychains wrapper has been removed"
assert_not_contains \
  "$ROOT_DIR/docker/webui/Dockerfile" \
  'proxychains-ng|socat|ENTRYPOINT' \
  "docker/webui/Dockerfile should not inject proxychains or a custom entrypoint anymore"
if [[ -e "$ROOT_DIR/docker/webui/docker-entrypoint.sh" ]]; then
  fail "docker/webui/docker-entrypoint.sh should be removed once proxychains is replaced"
fi

echo "[static] all checks passed"

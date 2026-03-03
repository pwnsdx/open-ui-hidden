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
bash -n "$ROOT_DIR/tests/test_static.sh"
bash -n "$ROOT_DIR/tests/test_compose_smoke.sh"

if command -v shellcheck >/dev/null 2>&1; then
  echo "[static] running shellcheck"
  shellcheck "$ROOT_DIR/run.sh" "$ROOT_DIR/tests/test_static.sh" "$ROOT_DIR/tests/test_compose_smoke.sh"
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
else
  echo "[static] docker compose not available, skipping compose parse check"
fi

echo "[static] checking Linux host gateway mapping for ollama-proxy"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'host\.docker\.internal:host-gateway' \
  "docker-compose.yml must map host.docker.internal to host-gateway for Linux CI"

echo "[static] checking tor service user mapping"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'user:[[:space:]]*"\$\{TOR_UID:-1000\}:\$\{TOR_GID:-1000\}"' \
  "tor service must run with host-mapped UID/GID"

echo "[static] checking tor entrypoint waits for pq-proxy DNS"
assert_contains \
  "$ROOT_DIR/docker/tor/entrypoint.sh" \
  'WAIT_HOST="\$\{TOR_UPSTREAM_HOST:-pq-proxy\}"' \
  "tor entrypoint must default DNS wait target to pq-proxy"
assert_contains \
  "$ROOT_DIR/docker/tor/entrypoint.sh" \
  'getent[[:space:]]+hosts[[:space:]]+"\$WAIT_HOST"' \
  "tor entrypoint must wait for pq-proxy DNS before launching tor"

echo "[static] checking webui/tor dependency does not deadlock startup"
assert_contains \
  "$ROOT_DIR/docker-compose.yml" \
  'condition:[[:space:]]*service_started[[:space:]]*# Avoid startup deadlock with tor waiting on pq-proxy DNS' \
  "webui must depend on tor service_started to avoid tor/pq-proxy startup deadlock"

echo "[static] all checks passed"

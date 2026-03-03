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

echo "[static] checking compose file parses cleanly"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f "$ROOT_DIR/docker-compose.yml" config >/dev/null
else
  echo "[static] docker compose not available, skipping compose parse check"
fi

echo "[static] all checks passed"

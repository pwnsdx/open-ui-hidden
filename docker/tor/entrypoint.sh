#!/bin/sh
set -e

# Keep mounted Tor state private; continue with warnings if chmod fails due bind mount ACLs.
if [ -d "/var/lib/tor" ]; then
    CURRENT_UID="$(id -u)"
    CURRENT_GID="$(id -g)"
    DATA_UID="$(stat -c '%u' /var/lib/tor 2>/dev/null || true)"
    DATA_GID="$(stat -c '%g' /var/lib/tor 2>/dev/null || true)"

    if [ "${DATA_UID}" != "${CURRENT_UID}" ] || [ "${DATA_GID}" != "${CURRENT_GID}" ]; then
        echo "Warning: /var/lib/tor ownership (${DATA_UID}:${DATA_GID}) differs from runtime UID:GID (${CURRENT_UID}:${CURRENT_GID})."
    fi

    echo "Attempting to set permissions for /var/lib/tor to 700..."
    if ! chmod 700 /var/lib/tor; then
        echo "Warning: could not chmod /var/lib/tor (continuing)."
    fi
    if [ -d "/var/lib/tor/hs" ]; then
        echo "Attempting to set permissions for /var/lib/tor/hs to 700..."
        if ! chmod 700 /var/lib/tor/hs; then
            echo "Warning: could not chmod /var/lib/tor/hs (continuing)."
        fi
    fi
fi

# Wait for pq-proxy DNS entry before launching Tor. Tor validates
# HiddenServicePort target syntax at startup and fails if hostname is unresolved.
WAIT_HOST="${TOR_UPSTREAM_HOST:-pq-proxy}"
WAIT_TIMEOUT_SEC="${TOR_DNS_WAIT_TIMEOUT_SEC:-300}"
ELAPSED_SEC=0

echo "Waiting for ${WAIT_HOST} hostname resolution before launching Tor (timeout: ${WAIT_TIMEOUT_SEC}s)..."
while ! getent hosts "$WAIT_HOST" > /dev/null 2>&1; do
    if [ "$ELAPSED_SEC" -ge "$WAIT_TIMEOUT_SEC" ]; then
        echo "Warning: timed out waiting for ${WAIT_HOST} DNS resolution; starting Tor anyway."
        break
    fi
    sleep 1
    ELAPSED_SEC=$((ELAPSED_SEC + 1))
done

if getent hosts "$WAIT_HOST" > /dev/null 2>&1; then
    echo "${WAIT_HOST} resolved, starting Tor."
fi

# Execute the CMD (tor -f /etc/tor/torrc)
exec "$@" 

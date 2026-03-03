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

# Wait for pq-proxy service to be resolvable for HiddenServicePort
echo "Waiting for pq-proxy hostname resolution before launching Tor..."
while ! getent hosts pq-proxy > /dev/null; do
    sleep 1
done
echo "pq-proxy resolved, starting Tor."

# Execute the CMD (tor -f /etc/tor/torrc)
exec "$@" 

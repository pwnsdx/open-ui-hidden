#!/bin/sh
set -e

# Ensure correct permissions on the hidden service directory, especially if volume is mounted
# The user 'toruser' (UID/GID will be dynamically assigned by Alpine unless specified)
# needs to own /var/lib/tor and /var/lib/tor.
# The Dockerfile already creates 'toruser' and chowns /var/lib/tor.
# This entrypoint ensures the hs directory within the volume is also correct if it's re-mounted.

if [ -d "/var/lib/tor" ]; then
    # Get the UID and GID of toruser
    TOR_UID=$(id -u toruser)
    TOR_GID=$(id -g toruser)
    
    # Check current ownership of /var/lib/tor
    HS_DIR_UID=$(stat -c '%u' /var/lib/tor)
    HS_DIR_GID=$(stat -c '%g' /var/lib/tor)

    if [ "${HS_DIR_UID}" != "${TOR_UID}" ] || [ "${HS_DIR_GID}" != "${TOR_GID}" ]; then
        echo "Correcting ownership of /var/lib/tor..."
        # sudo is not available, and we are toruser if this part is needed after initial chown by root
        # This chown should ideally be done by root before switching user, 
        # or the volume mount should be managed by docker to respect toruser's UID/GID from the image.
        # However, for a fresh volume, the directory might be created by root.
        # A more robust solution for mounted volumes is for the Dockerfile to not chown /var/lib/tor
        # and let this entrypoint (running as root initially, then dropping to toruser) handle it.
        # For now, assuming the Dockerfile's chown of /var/lib/tor is sufficient for the parent,
        # and /var/lib/tor might need adjustment if it's a new volume.
        # This is a bit tricky since the entrypoint runs as toruser.
        # The best approach is to ensure the volume mount point is created with correct ownership by Docker or a setup script.
        # For now, we'll just log if it's wrong as toruser cannot chown it.
        CURRENT_USER=$(whoami)
        echo "Entrypoint running as: ${CURRENT_USER}"
        echo "Warning: /var/lib/tor ownership might be incorrect if this is a new volume."
        echo "Expected UID: ${TOR_UID}, GID: ${TOR_GID}. Found UID: ${HS_DIR_UID}, GID: ${HS_DIR_GID}."
        echo "If Tor fails, ensure the volume at ./data/tor_hs_data/hs on the host is owned by UID/GID that maps to toruser in the container."
    fi
    echo "Attempting to set permissions for /var/lib/tor to 700..."
    chmod 700 /var/lib/tor # Ensure parent is 700
    if [ -d "/var/lib/tor/hs" ]; then
        echo "Attempting to set permissions for /var/lib/tor/hs to 700..."
        chmod 700 /var/lib/tor/hs # Ensure hs dir is 700 if it exists
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
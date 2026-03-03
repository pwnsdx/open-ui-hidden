#!/bin/bash
set -euo pipefail # Exit on error, unset var, or pipe failure

# --- Configuration ---
ENV_FILE=".env"
SECRET_KEY_VAR="WEBUI_SECRET_KEY"
WEBUI_UID_VAR="WEBUI_UID"
WEBUI_GID_VAR="WEBUI_GID"
OLLAMA_BASE_URL_VAR="OLLAMA_BASE_URL"
# Updated paths for the new data structure
DATA_DIR="./data"
CERT_DIR="${DATA_DIR}/pq_proxy_certs"
TOR_HS_DIR="${DATA_DIR}/tor_hs_data/hs"
CERT_KEY_FILE="${CERT_DIR}/key.pem"
CERT_PEM_FILE="${CERT_DIR}/cert.pem"

# Docker Compose command detection
DOCKER_COMPOSE_CMD="docker-compose"

# --- Helper Functions ---
echo_green() {
    echo -e "\033[0;32m${1}\033[0m"
}

echo_yellow() {
    echo -e "\033[0;33m${1}\033[0m"
}

echo_red() {
    echo -e "\033[0;31m${1}\033[0m"
}

# --- Cleanup Function ---
cleanup() {
    echo_yellow "\nPerforming cleanup... stopping Docker containers."
    if ! ${DOCKER_COMPOSE_CMD} down; then
        echo_red "Warning: Docker Compose down command failed. You may need to stop containers manually."
    else
        echo_green "Docker containers stopped successfully."
    fi
    echo_green "Exiting."
}

# Trap SIGINT (Ctrl+C) and EXIT signals to run the cleanup function
trap cleanup SIGINT EXIT

# 1. Check for Docker and Docker Compose
check_docker() {
    echo_yellow "Checking Docker installation and status..."
    if ! command -v docker &> /dev/null; then
        echo_red "Error: Docker CLI not found. Please install Docker."
        exit 1
    fi
    if ! docker info &> /dev/null; then # docker info is more reliable than docker ps for daemon status
        echo_red "Error: Docker daemon is not running or not responding. Please start Docker."
        exit 1
    fi
    echo_green "Docker is installed and running."

    echo_yellow "Detecting Docker Compose command..."
    if command -v docker &> /dev/null && docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
        echo_green "Using 'docker compose'."
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
        echo_green "Using 'docker-compose'."
    else
        echo_red "Error: Neither 'docker compose' nor 'docker-compose' found. Please install Docker Compose."
        exit 1
    fi
}

# 2. Set up WEBUI_SECRET_KEY in .env file
setup_env_file() {
    echo_yellow "Setting up WEBUI_SECRET_KEY..."
    local new_key_generated=false
    local host_uid
    local host_gid
    host_uid=$(id -u)
    host_gid=$(id -g)

    if [ -f "${ENV_FILE}" ]; then
        if grep -q "^${SECRET_KEY_VAR}=" "${ENV_FILE}"; then
            echo_green "${SECRET_KEY_VAR} already exists in ${ENV_FILE}. Using existing key."
            export "${SECRET_KEY_VAR}=$(grep "^${SECRET_KEY_VAR}=" "${ENV_FILE}" | tail -n1 | cut -d'=' -f2-)"
        else
            local secret_key
            secret_key=$(openssl rand -hex 32)
            printf "%s=%s\n" "${SECRET_KEY_VAR}" "${secret_key}" >> "${ENV_FILE}"
            export "${SECRET_KEY_VAR}=${secret_key}"
            new_key_generated=true
            echo_green "Generated and added ${SECRET_KEY_VAR} to ${ENV_FILE}."
        fi

        if grep -q "^${OLLAMA_BASE_URL_VAR}=" "${ENV_FILE}"; then
            local current_ollama_base_url
            current_ollama_base_url="$(grep "^${OLLAMA_BASE_URL_VAR}=" "${ENV_FILE}" | tail -n1 | cut -d'=' -f2-)"
            if [ "${current_ollama_base_url}" = "http://host.docker.internal:11434" ]; then
                sed -i.bak "s|^${OLLAMA_BASE_URL_VAR}=.*|${OLLAMA_BASE_URL_VAR}=http://ollama-proxy:11434|" "${ENV_FILE}"
                rm -f "${ENV_FILE}.bak"
                echo_green "Migrated ${OLLAMA_BASE_URL_VAR} to http://ollama-proxy:11434 in ${ENV_FILE}."
            fi
        else
            printf "%s=%s\n" "${OLLAMA_BASE_URL_VAR}" "http://ollama-proxy:11434" >> "${ENV_FILE}"
            echo_green "Added ${OLLAMA_BASE_URL_VAR} to ${ENV_FILE}."
        fi
        if ! grep -q "^${WEBUI_UID_VAR}=" "${ENV_FILE}"; then
            printf "%s=%s\n" "${WEBUI_UID_VAR}" "${host_uid}" >> "${ENV_FILE}"
            echo_green "Added ${WEBUI_UID_VAR}=${host_uid} to ${ENV_FILE}."
        fi
        if ! grep -q "^${WEBUI_GID_VAR}=" "${ENV_FILE}"; then
            printf "%s=%s\n" "${WEBUI_GID_VAR}" "${host_gid}" >> "${ENV_FILE}"
            echo_green "Added ${WEBUI_GID_VAR}=${host_gid} to ${ENV_FILE}."
        fi
    else
        local secret_key
        secret_key=$(openssl rand -hex 32)
        cat > "${ENV_FILE}" <<EOF
${SECRET_KEY_VAR}=${secret_key}
${OLLAMA_BASE_URL_VAR}=http://ollama-proxy:11434
${WEBUI_UID_VAR}=${host_uid}
${WEBUI_GID_VAR}=${host_gid}
EOF
        export "${SECRET_KEY_VAR}=${secret_key}"
        new_key_generated=true
        echo_green "Generated ${SECRET_KEY_VAR} and created ${ENV_FILE}."
    fi

    export "${WEBUI_UID_VAR}=$(grep "^${WEBUI_UID_VAR}=" "${ENV_FILE}" | tail -n1 | cut -d'=' -f2-)"
    export "${WEBUI_GID_VAR}=$(grep "^${WEBUI_GID_VAR}=" "${ENV_FILE}" | tail -n1 | cut -d'=' -f2-)"

    if [ "${new_key_generated}" = true ]; then
        echo_yellow "Important: A new WEBUI_SECRET_KEY has been generated. If you had existing Open-WebUI data, this might affect your session/login."
    fi
    echo_green "WebUI will run as UID:GID ${WEBUI_UID}:${WEBUI_GID}."
    echo_green "${ENV_FILE} is configured."
}

# 3. Generate Certificates (ECDSA P-256 for Nginx with BoringSSL)
generate_certs() {
    echo_yellow "Handling certificates for Nginx (ECDSA P-256)..."
    mkdir -p "${CERT_DIR}"
    mkdir -p "${TOR_HS_DIR%/*}"
    mkdir -p "${DATA_DIR}/open_webui_data"

    if [ -f "${CERT_KEY_FILE}" ] && [ -f "${CERT_PEM_FILE}" ]; then
        echo_green "Certificates (key.pem and cert.pem) already exist in ${CERT_DIR}. Skipping generation."
        echo_yellow "To regenerate certificates, please remove them manually from ${CERT_DIR} and re-run this script."
    else
        echo_yellow "Generating ECDSA P-256 certificates..."
        if ! docker image inspect alpine:3.21.3 &> /dev/null; then
            echo_yellow "Pulling alpine:3.21.3 image (used for cert generation utility)..."
            docker pull alpine:3.21.3
        fi

        # Use alpine and install openssl, then generate certs
        docker run --rm -v "$(pwd)/${CERT_DIR#./}:/certs" \
          alpine@sha256:de4fe7064d8f98419ea6b49190df1abbf43450c1702eeb864fe9ced453c1cc5f \
          sh -c "apk add --no-cache openssl && \
                 openssl req -x509 \
                   -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
                   -keyout /certs/key.pem \
                   -out /certs/cert.pem \
                   -nodes -days 3650 \
                   -subj \"/CN=my-boringssl-onion-service\"" # Changed CN for clarity
        
        if [ -f "${CERT_KEY_FILE}" ] && [ -f "${CERT_PEM_FILE}" ]; then
            echo_green "ECDSA P-256 certificates generated successfully in ${CERT_DIR}."
        else
            echo_red "Error: Certificate generation failed. Check Docker output and permissions."
            exit 1
        fi
    fi
}

# --- Main Script ---
echo_green "--- Welcome to the Open-WebUI with Tor & Post-Quantum TLS Setup ---"
echo_yellow "This script will guide you through setting up your private and secure AI interface."
echo ""

check_docker
echo ""
setup_env_file
echo ""
generate_certs
echo ""

# 4. Run Docker Compose
echo_yellow "Building and starting services with Docker Compose..."
echo_yellow "This may take a while the first time if the base Nginx image needs pulling."
if ${DOCKER_COMPOSE_CMD} up --build -d; then
    echo_green "Docker Compose services started successfully."
else
    echo_red "Error: Docker Compose failed to start. Check the output above for details."
    exit 1
fi

echo ""
echo_green "--- Setup Complete! ---"

# Wait for Tor hidden service hostname file to appear, with a timeout
MAX_WAIT_SECONDS=60
WAIT_INTERVAL_SECONDS=5
ELAPSED_SECONDS=0
HOSTNAME_FILE="${TOR_HS_DIR}/hostname"

echo_yellow "Waiting for Tor hidden service to publish (up to ${MAX_WAIT_SECONDS} seconds)..."

while [ ! -f "${HOSTNAME_FILE}" ] && [ "${ELAPSED_SECONDS}" -lt "${MAX_WAIT_SECONDS}" ]; do
    sleep "${WAIT_INTERVAL_SECONDS}"
    ELAPSED_SECONDS=$((ELAPSED_SECONDS + WAIT_INTERVAL_SECONDS))
    echo_yellow "Still waiting for ${HOSTNAME_FILE} (${ELAPSED_SECONDS}s/${MAX_WAIT_SECONDS}s)..."
done

if [ -f "${HOSTNAME_FILE}" ]; then
    ONION_HOSTNAME=$(cat "${HOSTNAME_FILE}")
    echo_green "Your Tor Hidden Service .onion address is: https://${ONION_HOSTNAME}"
else
    echo_red "Timeout: Tor hostname file (${HOSTNAME_FILE}) not found after ${MAX_WAIT_SECONDS} seconds."
    echo_yellow "Please check the Tor service logs: ${DOCKER_COMPOSE_CMD} logs tor"
    echo_yellow "You may need to wait longer or check for errors. The service might still be starting."
fi

echo ""
echo_yellow "Next steps to access your service:"
echo "1. Open your .onion address in Tor Browser."
echo "   - Tor Browser stable should connect without extra about:config flags."
echo "   - The proxy prefers X25519MLKEM768, then X25519Kyber768Draft00."
echo "   - Otherwise, TLS falls back automatically to X25519."
echo "   - On iOS, there is no official Tor Browser; use Onion Browser."
echo "2. If a self-signed certificate warning appears, verify/accept it and continue."
echo ""
echo_yellow "The services are now running in the background."
echo_yellow "Press Ctrl+C or close this terminal to stop the services and perform cleanup."
echo_yellow "Alternatively, you can manually stop them later with: ${DOCKER_COMPOSE_CMD} down"
echo ""

# Keep the script running until Ctrl+C is pressed, so the trap can execute
# This can be a simple sleep loop or reading user input.
# For simplicity, we'll just let the trap handle the exit.
# If the script were to exit immediately, the 'trap EXIT' would fire.
# By not exiting, we rely on Ctrl+C (SIGINT) or user closing the terminal (which often sends SIGHUP then SIGINT/SIGTERM)
# or an explicit 'exit' command somewhere later if we added more logic.
echo_yellow "Monitoring... (Script will keep running to allow cleanup on exit)"
while true; do
    sleep 86400 # Sleep for a day, effectively waiting for SIGINT
done 

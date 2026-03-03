#!/bin/bash
set -e

# Resolve Tor container IP
TOR_IP=$(getent hosts tor | awk '{print $1}')

# Generate proxychains config
cat > /tmp/proxychains.conf <<EOF
dynamic_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

# Bypass proxy for local networks
# The static IP for ollama-proxy (e.g., 172.20.0.5) should fall under one of these ranges
# or be covered by the NO_PROXY environment variable set in docker-compose.yml.
localnet 127.0.0.0/8
localnet 10.0.0.0/8
localnet 172.16.0.0/12
localnet 192.168.0.0/16

[ProxyList]
socks5 $TOR_IP 9050
EOF

echo "INFO: Starting Uvicorn via proxychains, using --host from Dockerfile CMD..."
# Execute the passed command (CMD from Dockerfile) via proxychains
exec proxychains4 -f /tmp/proxychains.conf "$@" 
#!/bin/bash
set -e

start_local_forward() {
  local listen_port="$1"
  local upstream_host="$2"
  local upstream_port="$3"

  socat \
    TCP-LISTEN:"$listen_port",bind=127.0.0.1,reuseaddr,fork \
    TCP:"$upstream_host":"$upstream_port" \
    >/dev/null 2>&1 &
}

# Resolve Tor container IPv4 (proxychains + tor in this stack is IPv4 SOCKS).
TOR_IP="$(getent ahostsv4 tor | awk 'NR==1 {print $1}')"
if [ -z "$TOR_IP" ]; then
  TOR_IP="$(getent hosts tor | awk 'NR==1 {print $1}')"
fi
if [ -z "$TOR_IP" ]; then
  echo "ERROR: Unable to resolve Tor service IP."
  exit 1
fi

# Generate proxychains config
cat > /tmp/proxychains.conf <<EOF
dynamic_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000

# Bypass proxy for local networks
# The internal DNS host for ollama-proxy is excluded via NO_PROXY in docker-compose.yml.
localnet 127.0.0.0/8
localnet 10.0.0.0/8
localnet 172.16.0.0/12
localnet 192.168.0.0/16
# Bypass local/private IPv6 ranges used by Docker internal networking.
localnet fc00::/7
localnet fe80::/10

[ProxyList]
socks5 $TOR_IP 9050
EOF

# Bridge local loopback ports to the real upstream proxy service.
# This keeps local service calls compatible with proxychains.
start_local_forward 11434 ollama-upstream 11434
start_local_forward 1234 ollama-upstream 1234

echo "INFO: Starting Uvicorn via proxychains, using --host from Dockerfile CMD..."
# Execute the passed command (CMD from Dockerfile) via proxychains
exec proxychains4 -f /tmp/proxychains.conf "$@" 

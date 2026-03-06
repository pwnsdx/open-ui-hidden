#!/bin/sh
set -eu

require_env() {
  name="$1"
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "ERROR: missing required environment variable: $name" >&2
    exit 1
  fi
}

for var in OLLAMA_PROXY_IP TOR_HTTP_PROXY_IP PQ_PROXY_IP WEBUI_PORT; do
  require_env "$var"
done

READY_FILE="/tmp/firewall.ready"
rm -f "$READY_FILE"

# IPv6 is not used in this stack. Drop it explicitly so the shared network
# namespace cannot bypass the IPv4 policy.
ip6tables -F
ip6tables -X
ip6tables -P INPUT DROP
ip6tables -P OUTPUT DROP
ip6tables -P FORWARD DROP

iptables -F
iptables -X
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow pq-proxy to reach the local webui HTTP listener.
iptables -A INPUT -p tcp -s "$PQ_PROXY_IP" --dport "$WEBUI_PORT" -j ACCEPT

# Allow the only intended outbound paths from the shared webui namespace.
iptables -A OUTPUT -p tcp -d "$OLLAMA_PROXY_IP" -m multiport --dports 11434,1234 -j ACCEPT
iptables -A OUTPUT -p tcp -d "$TOR_HTTP_PROXY_IP" --dport 8118 -j ACCEPT

# Keep the existing TLS smoke probe working while staying on an internal-only
# destination.
iptables -A OUTPUT -p tcp -d "$PQ_PROXY_IP" --dport 443 -j ACCEPT

touch "$READY_FILE"

exec sh -c 'trap "exit 0" TERM INT; while :; do sleep 3600; done'

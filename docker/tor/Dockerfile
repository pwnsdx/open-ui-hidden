FROM alpine@sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c

ARG TOR_VERSION=0.4.8.16-r0
# Install Tor and remove bash
RUN apk add --no-cache tor=${TOR_VERSION}

# Create a non-root user for Tor
RUN addgroup -S toruser && adduser -S -G toruser -h /var/lib/tor toruser

# Create directories for Tor data and configuration with correct permissions
RUN mkdir -p /var/lib/tor && \
    mkdir -p /var/lib/tor/hs && \
    chown -R toruser:toruser /var/lib/tor && \
    chmod -R 700 /var/lib/tor

# Copy custom torrc configuration and entrypoint script
COPY torrc /etc/tor/torrc
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && \
    # Ensure entrypoint.sh uses /bin/sh
    sed -i '1s|#!/bin/bash|#!/bin/sh|' /entrypoint.sh

USER toruser

VOLUME /var/lib/tor

EXPOSE 9050

ENTRYPOINT ["/entrypoint.sh"]
CMD ["tor", "-f", "/etc/tor/torrc"] 
FROM ghcr.io/open-webui/open-webui:0.6.10-ollama

USER root
RUN apt-get update && apt-get install -y proxychains-ng && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["uvicorn","open_webui.main:app","--host","0.0.0.0","--port","8080","--forwarded-allow-ips='*'"] 
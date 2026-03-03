FROM nginx:1.28-alpine

# Remove default Nginx config
RUN rm /etc/nginx/conf.d/default.conf

# Copy our custom Nginx config
COPY nginx.conf /etc/nginx/nginx.conf

# Create a non-root user and group for Nginx
# Nginx official images already create a non-root 'nginx' user.
# We'll ensure proper permissions for log and cache directories.

# Create necessary directories and set permissions for non-root user
RUN mkdir -p /var/cache/nginx /var/log/nginx /var/run && \
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx /var/run && \
    chmod -R 700 /var/cache/nginx /var/log/nginx /var/run

# Switch to the non-root user
USER nginx

CMD ["nginx", "-g", "daemon off;"] 
# syntax=docker/dockerfile:1.4
# Builder stage for BoringSSL - compiles with hardening flags
FROM alpine@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS boringssl-builder
# Support multi-arch builds with architecture-specific optimizations
ARG TARGETARCH

# Install build dependencies with APK cache mount for faster rebuilds
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache --virtual .build-deps \
		build-base \
		ca-certificates \
		cmake \
		curl \
		git \
		go \
		linux-headers \
		perl

# Security hardening flags for all compiled binaries
# - O3: Optimization level 3
# - D_FORTIFY_SOURCE=2: Detect buffer overflows in standard functions
# - fstack-protector-strong: Stack canaries to prevent stack smashing
# - Wformat, Werror=format-security: Prevent format string vulnerabilities
# - fno-semantic-interposition: Performance optimization for dynamic linking
# - Wl,-z,relro,-z,now: Memory hardening, resolve all symbols at load time
ENV CFLAGS_BASE="-O3 -D_FORTIFY_SOURCE=2 -fstack-protector-strong -Wformat -Werror=format-security -fno-semantic-interposition" \
    LDFLAGS_BASE="-Wl,-z,relro,-z,now -fno-semantic-interposition"

# BoringSSL git URL and pinned commit.
# Keep this pinned for reproducible builds and controlled TLS behavior.
ENV BORINGSSL_GIT_URL=https://boringssl.googlesource.com/boringssl \
    # https://boringssl.googlesource.com/boringssl/+/d0fcf49574b06de7090cba4ad8124df638a0134e
    # Tue Mar 03 06:12:52 2026 -08:00
    BORINGSSL_COMMIT=d0fcf49574b06de7090cba4ad8124df638a0134e

# Clone and build BoringSSL with security hardening flags
# Retries handle transient upstream/network failures in CI.
RUN set -eux; \
		for attempt in 1 2 3 4 5; do \
			rm -rf /usr/src/boringssl; \
			if git clone "$BORINGSSL_GIT_URL" /usr/src/boringssl; then \
				break; \
			fi; \
			if [ "$attempt" -eq 5 ]; then \
				echo "error: failed to clone BoringSSL after ${attempt} attempts" >&2; \
				exit 1; \
			fi; \
			sleep $((attempt * 3)); \
		done \
		&& cd /usr/src/boringssl \
		&& git checkout --force --quiet $BORINGSSL_COMMIT \
		&& mkdir -p /usr/src/boringssl/build \
		&& if [ "$TARGETARCH" = "arm64" ]; then ARCH_FLAGS="-march=armv8-a -mno-outline-atomics"; else ARCH_FLAGS="-march=x86-64"; fi \
		&& cmake -B/usr/src/boringssl/build -S/usr/src/boringssl \
			-DCMAKE_BUILD_TYPE=RelWithDebInfo \
			-DCMAKE_C_FLAGS="$CFLAGS_BASE $ARCH_FLAGS" \
			-DCMAKE_CXX_FLAGS="$CFLAGS_BASE $ARCH_FLAGS" \
			-DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS_BASE" \
		# Build only libraries needed by nginx; skip test binaries from `all`.
		&& make -C /usr/src/boringssl/build -j$(getconf _NPROCESSORS_ONLN) crypto ssl

# Builder stage - compiles Nginx and modules with hardening flags
FROM alpine@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS nginx-builder
# Support multi-arch builds with architecture-specific optimizations
ARG TARGETARCH

# Install build dependencies with APK cache mount for faster rebuilds
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache --virtual .build-deps \
		build-base \
		ca-certificates \
		cmake \
		curl \
		git \
		gnupg \
		linux-headers \
		tar \
		zlib-dev

# Security hardening flags for all compiled binaries
ENV CFLAGS_BASE="-O3 -D_FORTIFY_SOURCE=2 -fstack-protector-strong -Wformat -Werror=format-security -fno-semantic-interposition" \
    LDFLAGS_BASE="-Wl,-z,relro,-z,now -fno-semantic-interposition"

# Nginx version to build
ENV NGINX_VERSION=1.28.2

# Nginx download URLs
ENV NGINX_TAR_URL=https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz \
    NGINX_SIG_URL=https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc \
    NGINX_GPG_KEYS="D6786CE303D9A9022998DC6CC8464D549AF75C0A 43387825DDB1BB97EC36BA5D007C8D7C15D87369" \
    NGINX_BROTLI_GIT_URL=https://github.com/google/ngx_brotli \
    NGINX_BROTLI_COMMIT=a71f9312c2deb28875acc7bacfdd5695a111aa53

# Copy BoringSSL from the boringssl-builder stage
COPY --from=boringssl-builder /usr/src/boringssl /usr/src/boringssl

# Patch for dynamic_tls_records
COPY nginx__dynamic_tls_records_1.27.5+.patch /usr/src/nginx-$NGINX_VERSION/dynamic_tls_records.patch

# Create nginx user
RUN addgroup -S nginx \
	&& adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx

# Download Nginx source code and signature
RUN curl -fSL $NGINX_TAR_URL -o nginx-$NGINX_VERSION.tar.gz \
	&& curl -fSL $NGINX_SIG_URL -o nginx-$NGINX_VERSION.tar.gz.asc

# Verify Nginx source code integrity with GPG
RUN GNUPGHOME="$(mktemp -d)" \
	&& found=''; \
	for server in \
		ha.pool.sks-keyservers.net \
		hkp://keyserver.ubuntu.com:80 \
		hkp://p80.pool.sks-keyservers.net:80 \
		pgp.mit.edu \
	; do \
		echo "Fetching GPG key $NGINX_GPG_KEYS from $server"; \
		gpg --keyserver "$server" --keyserver-options timeout=10 --recv-keys $NGINX_GPG_KEYS && found=yes && break; \
	done; \
	test -z "$found" && echo >&2 "error: failed to fetch GPG key $NGINX_GPG_KEYS" && exit 1; \
	gpg --batch --verify nginx-$NGINX_VERSION.tar.gz.asc nginx-$NGINX_VERSION.tar.gz \
	&& mkdir -p /usr/src \
	&& tar -zxC /usr/src -f nginx-$NGINX_VERSION.tar.gz \
	&& rm nginx-$NGINX_VERSION.tar.gz \
	&& rm -rf "$GNUPGHOME" nginx-$NGINX_VERSION.tar.gz.asc

# Clone Brotli compression module for Nginx
# Retries handle transient GitHub 5xx/network failures in CI.
RUN set -eux; \
		for attempt in 1 2 3 4 5; do \
			rm -rf /usr/src/ngx_brotli; \
			if git clone "$NGINX_BROTLI_GIT_URL" /usr/src/ngx_brotli; then \
				break; \
			fi; \
			if [ "$attempt" -eq 5 ]; then \
				echo "error: failed to clone ngx_brotli after ${attempt} attempts" >&2; \
				exit 1; \
			fi; \
			sleep $((attempt * 3)); \
		done \
	&& cd /usr/src/ngx_brotli \
	&& git checkout --force --quiet $NGINX_BROTLI_COMMIT \
	&& git submodule update --init --recursive --depth=1

# Build Brotli static libraries once so the Nginx filter module can link cleanly.
RUN set -eux; \
		if [ "$TARGETARCH" = "arm64" ]; then ARCH_FLAGS="-march=armv8-a -mno-outline-atomics"; else ARCH_FLAGS="-march=x86-64"; fi; \
		cmake -S /usr/src/ngx_brotli/deps/brotli -B /usr/src/ngx_brotli/deps/brotli/out \
			-DCMAKE_BUILD_TYPE=Release \
			-DBUILD_SHARED_LIBS=OFF \
			-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
			-DCMAKE_C_FLAGS="$CFLAGS_BASE $ARCH_FLAGS" \
			-DCMAKE_CXX_FLAGS="$CFLAGS_BASE $ARCH_FLAGS" \
			-DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS_BASE" \
			-DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS_BASE" \
			-DCMAKE_MODULE_LINKER_FLAGS="$LDFLAGS_BASE" \
		&& cmake --build /usr/src/ngx_brotli/deps/brotli/out --config Release --target brotlienc -j"$(getconf _NPROCESSORS_ONLN)"

# Build and install an intentionally minimal Nginx for reverse proxy duties.
RUN cd /usr/src/nginx-$NGINX_VERSION \
		&& patch -p1 < dynamic_tls_records.patch \
		&& sed -i 's/-lssl -lcrypto/-lssl -lcrypto -lstdc++/g' auto/lib/openssl/conf \
		&& if [ "$TARGETARCH" = "arm64" ]; then ARCH_FLAGS="-march=armv8-a -mno-outline-atomics"; else ARCH_FLAGS="-march=x86-64"; fi \
		&& CONFIG="\
		--prefix=/etc/nginx \
		--sbin-path=/usr/sbin/nginx \
		--modules-path=/usr/lib/nginx/modules \
		--conf-path=/etc/nginx/nginx.conf \
		--error-log-path=/var/log/nginx/error.log \
		--http-log-path=/var/log/nginx/access.log \
		--pid-path=/var/run/nginx.pid \
		--lock-path=/var/run/nginx.lock \
		--http-client-body-temp-path=/var/cache/nginx/client_temp \
		--http-proxy-temp-path=/var/cache/nginx/proxy_temp \
		--user=nginx \
		--group=nginx \
		--without-select_module \
		--without-poll_module \
		--without-http_charset_module \
		--without-http_ssi_module \
		--without-http_userid_module \
		--without-http_access_module \
		--without-http_auth_basic_module \
		--without-http_mirror_module \
		--without-http_autoindex_module \
		--without-http_geo_module \
		--without-http_map_module \
		--without-http_split_clients_module \
		--without-http_referer_module \
		--without-http_rewrite_module \
		--without-http_fastcgi_module \
		--without-http_uwsgi_module \
		--without-http_scgi_module \
		--without-http_grpc_module \
		--without-http_memcached_module \
		--without-http_limit_req_module \
		--without-http_empty_gif_module \
		--without-http_browser_module \
		--without-http_upstream_hash_module \
		--without-http_upstream_ip_hash_module \
		--without-http_upstream_least_conn_module \
		--without-http_upstream_random_module \
		--without-http_upstream_zone_module \
		--with-http_ssl_module \
		--with-http_v2_module \
		--add-dynamic-module=/usr/src/ngx_brotli \
		" \
		&& ./configure $CONFIG \
			--with-cc-opt="-I/usr/src/boringssl/include $CFLAGS_BASE $ARCH_FLAGS" \
			--with-ld-opt="-L/usr/src/boringssl/build -L/usr/src/boringssl/build/ssl -L/usr/src/boringssl/build/crypto $LDFLAGS_BASE" \
		&& make -j$(getconf _NPROCESSORS_ONLN) \
	&& make install \
	&& rm -rf /etc/nginx/html/ \
	&& mkdir -p /etc/nginx/conf.d/ \
	&& strip /usr/sbin/nginx \
	&& strip /usr/lib/nginx/modules/*.so \
	&& rm -f /usr/lib/nginx/modules/ngx_http_brotli_static_module.so \
	&& rm -rf /usr/src/nginx-$NGINX_VERSION \
	&& rm -rf /usr/src/ngx_*

# Runtime stage - minimal image with only what's needed to run Nginx
FROM alpine@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS runner
ARG NGINX_UID=101
ARG NGINX_GID=101

# Install minimal runtime dependencies.
# libstdc++/libgcc are required by newer BoringSSL static archives linked into nginx.
RUN apk add --no-cache libstdc++ libgcc

# Copy only the necessary files from the builder stage
COPY --from=nginx-builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx-builder /usr/lib/nginx/modules /usr/lib/nginx/modules
COPY --from=nginx-builder /etc/nginx/mime.types /etc/nginx/mime.types

# Setup nginx user, directories, and log forwarding for containerized environment
RUN addgroup -g "$NGINX_GID" -S nginx \
 && adduser -D -S -H -u "$NGINX_UID" -h /var/cache/nginx -s /sbin/nologin -G nginx nginx \
 && mkdir -p /var/cache/nginx /etc/nginx/conf.d /var/log/nginx \
 && ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log \
 && ln -s /usr/lib/nginx/modules /etc/nginx/modules

# Add configuration and static content
COPY ./nginx.conf /etc/nginx/nginx.conf

# Expose HTTPS port
EXPOSE 443
STOPSIGNAL SIGTERM

# Run as non-root user for better security
USER nginx
CMD ["nginx", "-g", "daemon off;"]

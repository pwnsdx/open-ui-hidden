# syntax=docker/dockerfile:1.4
# Builder stage for BoringSSL - compiles with hardening flags
FROM alpine@sha256:de4fe7064d8f98419ea6b49190df1abbf43450c1702eeb864fe9ced453c1cc5f AS boringssl-builder
# Support multi-arch builds with architecture-specific optimizations
ARG TARGETARCH

# Install build dependencies with APK cache mount for faster rebuilds
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache --virtual .build-deps \
		build-base \
		ca-certificates \
		cmake \
		curl \
		gcc \
		git \
		go \
		libc-dev \
		libgcc \
		libstdc++ \
		linux-headers \
		make \
		perl-dev

# Security hardening flags for all compiled binaries
# - O3: Optimization level 3
# - D_FORTIFY_SOURCE=2: Detect buffer overflows in standard functions
# - fstack-protector-strong: Stack canaries to prevent stack smashing
# - Wformat, Werror=format-security: Prevent format string vulnerabilities
# - fno-semantic-interposition: Performance optimization for dynamic linking
# - Wl,-z,relro,-z,now: Memory hardening, resolve all symbols at load time
ENV CFLAGS_BASE="-O3 -D_FORTIFY_SOURCE=2 -fstack-protector-strong -Wformat -Werror=format-security -fno-semantic-interposition" \
    LDFLAGS_BASE="-Wl,-z,relro,-z,now -fno-semantic-interposition"

# BoringSSL git URL and commit
ENV BORINGSSL_GIT_URL=https://boringssl.googlesource.com/boringssl \
    # https://boringssl.googlesource.com/boringssl/+/e6489902b7fb692875341b8ab5e57f0515f47bc1
	# Last known commit to work with Nginx 1.28.0
	# Wed Dec 06 22:08:40 2023
	# Ultimately, when browsers fully support ML-KEM, we might want to switch to oqsprovider
    BORINGSSL_COMMIT=e6489902b7fb692875341b8ab5e57f0515f47bc1

# Clone and build BoringSSL with security hardening flags
RUN git clone $BORINGSSL_GIT_URL /usr/src/boringssl \
		&& cd /usr/src/boringssl \
		&& git checkout --force --quiet $BORINGSSL_COMMIT \
		&& (grep -qxF 'SET_TARGET_PROPERTIES(crypto PROPERTIES SOVERSION 1)' /usr/src/boringssl/crypto/CMakeLists.txt || echo -e '\nSET_TARGET_PROPERTIES(crypto PROPERTIES SOVERSION 1)' >> /usr/src/boringssl/crypto/CMakeLists.txt) \
		&& (grep -qxF 'SET_TARGET_PROPERTIES(ssl PROPERTIES SOVERSION 1)' /usr/src/boringssl/ssl/CMakeLists.txt || echo -e '\nSET_TARGET_PROPERTIES(ssl PROPERTIES SOVERSION 1)' >> /usr/src/boringssl/ssl/CMakeLists.txt) \
		&& mkdir -p /usr/src/boringssl/build \
		&& if [ "$TARGETARCH" = "arm64" ]; then ARCH_FLAGS="-march=armv8-a -mno-outline-atomics"; else ARCH_FLAGS="-march=x86-64"; fi \
		&& cmake -B/usr/src/boringssl/build -S/usr/src/boringssl \
			-DCMAKE_BUILD_TYPE=RelWithDebInfo \
			-DCMAKE_C_FLAGS="$CFLAGS_BASE $ARCH_FLAGS" \
			-DCMAKE_CXX_FLAGS="$CFLAGS_BASE $ARCH_FLAGS" \
			-DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS_BASE" \
		&& make -C /usr/src/boringssl/build -j$(getconf _NPROCESSORS_ONLN)

# Builder stage - compiles Nginx and modules with hardening flags
FROM alpine@sha256:de4fe7064d8f98419ea6b49190df1abbf43450c1702eeb864fe9ced453c1cc5f AS nginx-builder
# Support multi-arch builds with architecture-specific optimizations
ARG TARGETARCH

# Install build dependencies with APK cache mount for faster rebuilds
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache --virtual .build-deps \
		autoconf \
		automake \
		bind-tools \
		binutils \
		build-base \
		ca-certificates \
		curl \
		gcc \
		gd-dev \
		geoip-dev \
		git \
		gnupg \
		libc-dev \
		libgcc \
		libstdc++ \
		libtool \
		libxslt-dev \
		linux-headers \
		make \
		pcre \
		pcre-dev \
		perl-dev \
		su-exec \
		tar \
		tzdata \
		zlib \
		zlib-dev

# Security hardening flags for all compiled binaries
ENV CFLAGS_BASE="-O3 -D_FORTIFY_SOURCE=2 -fstack-protector-strong -Wformat -Werror=format-security -fno-semantic-interposition" \
    LDFLAGS_BASE="-Wl,-z,relro,-z,now -fno-semantic-interposition"

# Nginx version to build
ENV NGINX_VERSION=1.28.0

# Nginx download URLs
ENV NGINX_TAR_URL=https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz \
    NGINX_SIG_URL=https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc \
    NGINX_GPG_KEYS=D6786CE303D9A9022998DC6CC8464D549AF75C0A \
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
		gpg --keyserver "$server" --keyserver-options timeout=10 --recv-keys "$NGINX_GPG_KEYS" && found=yes && break; \
	done; \
	test -z "$found" && echo >&2 "error: failed to fetch GPG key $NGINX_GPG_KEYS" && exit 1; \
	gpg --batch --verify nginx-$NGINX_VERSION.tar.gz.asc nginx-$NGINX_VERSION.tar.gz \
	&& mkdir -p /usr/src \
	&& tar -zxC /usr/src -f nginx-$NGINX_VERSION.tar.gz \
	&& rm nginx-$NGINX_VERSION.tar.gz \
	&& rm -rf "$GNUPGHOME" nginx-$NGINX_VERSION.tar.gz.asc

# Clone Brotli compression module for Nginx
RUN git clone --depth=1 --recurse-submodules $NGINX_BROTLI_GIT_URL /usr/src/ngx_brotli \
	&& cd /usr/src/ngx_brotli \
	&& git checkout --force --quiet $NGINX_BROTLI_COMMIT

# Build and install optimized release version of Nginx with security hardening
RUN cd /usr/src/nginx-$NGINX_VERSION \
	&& patch -p1 < dynamic_tls_records.patch \
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
		--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
		--http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
		--http-scgi-temp-path=/var/cache/nginx/scgi_temp \
		--user=nginx \
		--group=nginx \
		--with-http_ssl_module \
		--with-http_realip_module \
		--with-http_addition_module \
		--with-http_sub_module \
		--with-http_dav_module \
		--with-http_flv_module \
		--with-http_mp4_module \
		--with-http_gunzip_module \
		--with-http_gzip_static_module \
		--with-http_random_index_module \
		--with-http_secure_link_module \
		--with-http_stub_status_module \
		--with-http_auth_request_module \
		--with-http_xslt_module=dynamic \
		--with-http_image_filter_module=dynamic \
		--with-http_geoip_module=dynamic \
		--with-http_perl_module=dynamic \
		--with-threads \
		--with-stream \
		--with-stream_ssl_module \
		--with-stream_ssl_preread_module \
		--with-stream_realip_module \
		--with-stream_geoip_module=dynamic \
		--with-http_slice_module \
		--with-mail \
		--with-mail_ssl_module \
		--with-compat \
		--with-file-aio \
		--with-http_v2_module \
		--with-http_v3_module \
		--add-dynamic-module=/usr/src/ngx_brotli \
	" \
	&& ./configure $CONFIG \
		--with-cc-opt="-I/usr/src/boringssl/include $CFLAGS_BASE $ARCH_FLAGS" \
		--with-ld-opt="-L/usr/src/boringssl/build/ssl -L/usr/src/boringssl/build/crypto $LDFLAGS_BASE" \
	&& make -j$(getconf _NPROCESSORS_ONLN) \
	&& make install \
	&& rm -rf /etc/nginx/html/ \
	&& mkdir -p /etc/nginx/conf.d/ \
	&& mkdir -p /usr/share/nginx/html/ \
	&& install -m644 html/index.html /usr/share/nginx/html/ \
	&& install -m644 html/50x.html /usr/share/nginx/html/ \
	&& ln -s ../../usr/lib/nginx/modules /etc/nginx/modules \
	&& strip /usr/sbin/nginx \
	&& strip /usr/lib/nginx/modules/*.so \
	&& rm -rf /usr/src/nginx-$NGINX_VERSION \
	&& rm -rf /usr/src/ngx_*

# Runtime stage - minimal image with only what's needed to run Nginx
FROM alpine@sha256:a8560b36e8b8210634f77d9f7f9efd7ffa463e380b75e2e74aff4511df3ef88c AS runner

# Install minimal runtime dependencies
RUN apk add --no-cache tzdata ca-certificates pcre brotli

# Copy only the necessary files from the builder stage
COPY --from=nginx-builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=nginx-builder /usr/lib/nginx /usr/lib/nginx
COPY --from=nginx-builder /etc/nginx/mime.types /etc/nginx/mime.types
COPY --from=nginx-builder /etc/nginx/fastcgi_params /etc/nginx/fastcgi_params
COPY --from=nginx-builder /etc/nginx/fastcgi.conf /etc/nginx/fastcgi.conf
COPY --from=nginx-builder /etc/nginx/uwsgi_params /etc/nginx/uwsgi_params
COPY --from=nginx-builder /etc/nginx/scgi_params /etc/nginx/scgi_params

# Setup nginx user, directories, and log forwarding for containerized environment
RUN addgroup -S nginx \
 && adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx \
 && mkdir -p /var/cache/nginx /etc/nginx/conf.d /usr/share/nginx/html /var/log/nginx \
 && ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log \
 && ln -s /usr/lib/nginx/modules /etc/nginx/modules

# Add configuration and static content
COPY ./nginx.conf /etc/nginx/nginx.conf
COPY --from=nginx-builder /usr/share/nginx/html /usr/share/nginx/html

# Expose HTTPS port
EXPOSE 443
STOPSIGNAL SIGTERM

# Run as non-root user for better security
USER nginx
CMD ["nginx", "-g", "daemon off;"]
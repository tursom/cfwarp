FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG APT_DISABLE_PROXY=false

RUN set -eux; \
    apt_opts="-o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"; \
    if [ "${APT_DISABLE_PROXY}" = "true" ]; then \
        apt_opts="${apt_opts} -o Acquire::http::Proxy=false -o Acquire::https::Proxy=false"; \
    fi; \
    apt-get ${apt_opts} update; \
    apt-get ${apt_opts} install -y --no-install-recommends \
        ca-certificates \
        bash \
        curl \
        gnupg \
        iproute2 \
        lsb-release \
        procps \
        tini; \
    mkdir -p /usr/share/keyrings; \
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/cloudflare-client.list; \
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; \
    chmod +x /usr/sbin/policy-rc.d; \
    apt-get ${apt_opts} update; \
    apt-get ${apt_opts} install -y --no-install-recommends cloudflare-warp; \
    rm -f /usr/sbin/policy-rc.d; \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/cfwarp-entrypoint

RUN chmod +x /usr/local/bin/cfwarp-entrypoint \
    && mkdir -p /var/lib/cloudflare-warp

VOLUME ["/var/lib/cloudflare-warp"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/cfwarp-entrypoint"]

# One image for every podman NAT scenario, built as localhost/storage-nat.
# Carries the storage binary + miniupnpd (for the upnp/pcp routers); scenarios
# differ only in their entrypoint scripts, which compose mounts.
# Build context = project root.
FROM ubuntu:24.04

ARG NIM_VERSION=2.2.12

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc g++ make cmake git curl ca-certificates xz-utils \
    libc-dev ccache pkg-config \
    iproute2 iptables nftables jq \
    libnftnl-dev libmnl-dev \
    && rm -rf /var/lib/apt/lists/*

# miniupnpd with the real nftables backend (the iptables backend no longer builds
# against modern libiptc), used by the upnp/pcp routers: its mapping requests
# install a genuine DNAT on the router, so AutoNAT's dial-back reaches the node.
RUN git clone --depth=1 --branch miniupnpd_2_3_9 \
        https://github.com/miniupnp/miniupnp.git /tmp/miniupnp-nft \
    && cd /tmp/miniupnp-nft/miniupnpd \
    && ./configure --firewall=nftables \
    && make miniupnpd \
    && install -m 755 miniupnpd /usr/local/sbin/miniupnpd-nft \
    && rm -rf /tmp/miniupnp-nft

RUN curl -fsSL "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz" \
    | tar -xJ -C /opt
RUN ln -s "/opt/nim-${NIM_VERSION}/bin/nim" /usr/local/bin/nim

WORKDIR /app

# vendor/ already has the checked-out submodules, so no `make update` here.
COPY vendor/ vendor/
COPY storage/ storage/
COPY build.nims config.nims storage.nim network_presets.json ./

# libplum static lib, linked by nim-libplum.
RUN --mount=type=cache,target=/root/.ccache \
    export PATH="/usr/lib/ccache:$PATH" && \
    rm -rf vendor/nim-libplum/vendor/libplum/build && \
    cmake -B vendor/nim-libplum/vendor/libplum/build \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        vendor/nim-libplum/vendor/libplum && \
    make -j"$(nproc)" -C vendor/nim-libplum/vendor/libplum/build && \
    cp vendor/nim-libplum/vendor/libplum/build/libplum.a \
        vendor/nim-libplum/vendor/libplum/libplum.a

RUN --mount=type=cache,target=/root/.ccache \
    export PATH="/usr/lib/ccache:$PATH" && \
    USE_SYSTEM_NIM=1 vendor/nimbus-build-system/scripts/env.sh \
        nim storage -d:disable_libbacktrace build.nims

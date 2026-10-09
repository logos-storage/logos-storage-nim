# One image for every podman NAT scenario, built as localhost/storage-nat.
# Carries the storage binary + miniupnpd (for the upnp/pcp routers); scenarios
# differ only in their entrypoint scripts, which compose mounts.
# Build context = project root.
FROM ubuntu:24.04

ARG MAKE_PARALLEL=4

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

COPY tools/scripts/setup-nim.sh tools/scripts/toolchain-versions.sh /opt/bootstrap/
RUN /opt/bootstrap/setup-nim.sh /opt/toolchain
ENV PATH="/usr/lib/ccache:/opt/toolchain/bin:${PATH}"
ENV NIMBLE_DIR=/opt/nimbledeps
ENV NIMBLE_FLAGS=--useSystemNim

WORKDIR /app
COPY . .
RUN --mount=type=cache,target=/root/.ccache \
    make NIMFLAGS="--parallelBuild:${MAKE_PARALLEL} -d:disableMarchNative" USE_LIBBACKTRACE=0
# The scenarios invoke /app/build/storage and mount their own router scripts.

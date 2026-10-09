# Variables
ARG BUILDER=ubuntu:24.04
ARG IMAGE=${BUILDER}
ARG BUILD_HOME=/src
ARG MAKE_PARALLEL=4
ARG NIMFLAGS="-d:disableMarchNative"
ARG USE_LIBBACKTRACE=1
ARG APP_HOME=/logosstorage
ARG NAT_IP_AUTO=false

# Build
FROM ${BUILDER} AS builder
ARG BUILD_HOME
ARG MAKE_PARALLEL
ARG NIMFLAGS
ARG USE_LIBBACKTRACE

RUN apt-get update && apt-get install -y --no-install-recommends \
    git cmake curl make bash build-essential ca-certificates xz-utils \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-c"]
COPY tools/scripts/setup-nim.sh tools/scripts/toolchain-versions.sh /opt/bootstrap/
RUN /opt/bootstrap/setup-nim.sh /opt/toolchain
ENV PATH="/opt/toolchain/bin:${PATH}"
ENV NIMBLE_DIR=/opt/nimbledeps
ENV NIMBLE_FLAGS=--useSystemNim

WORKDIR ${BUILD_HOME}
COPY . .
RUN make NIMFLAGS="${NIMFLAGS} --parallelBuild:${MAKE_PARALLEL}" USE_LIBBACKTRACE="${USE_LIBBACKTRACE}"

# Create
FROM ${IMAGE}
ARG BUILD_HOME
ARG APP_HOME
ARG NAT_IP_AUTO

WORKDIR ${APP_HOME}
COPY --from=builder ${BUILD_HOME}/build/* /usr/local/bin
COPY --from=builder ${BUILD_HOME}/openapi.yaml .
COPY --from=builder --chmod=0755 ${BUILD_HOME}/docker/docker-entrypoint.sh /
RUN apt-get update && apt-get install -y libgomp1 curl jq && rm -rf /var/lib/apt/lists/*
ENV NAT_IP_AUTO=${NAT_IP_AUTO}
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["storage"]

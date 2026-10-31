# Variables
ARG BUILDER=ubuntu:24.04
ARG IMAGE=${BUILDER}
ARG BUILD_HOME=/src
ARG MAKE_PARALLEL=${MAKE_PARALLEL:-4}
ARG NIMFLAGS="${NIMFLAGS:-"-d:disableMarchNative"}"
ARG USE_LIBBACKTRACE=${USE_LIBBACKTRACE:-1}
ARG APP_HOME=/logosstorage
ARG NAT_IP_AUTO=${NAT_IP_AUTO:-false}

# Build
FROM ${BUILDER} AS builder
ARG BUILD_HOME
ARG MAKE_PARALLEL
ARG NIMFLAGS
ARG USE_LIBBACKTRACE

RUN apt-get update && apt-get install -y git cmake curl make bash lcov build-essential xz-utils

SHELL ["/bin/bash", "-c"]
ENV BASH_ENV="/etc/bash_env"

# Nim >= 2.2.14 ships the Nimble version that storage.nimble needs.
ARG NIM_VERSION=2.2.14
RUN case "$(uname -m)" in \
      x86_64) nim_arch=x64 ;; \
      aarch64) nim_arch=arm64 ;; \
      *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_${nim_arch}.tar.xz" | tar -xJ -C /opt
ENV PATH="/opt/nim-${NIM_VERSION}/bin:${PATH}"

WORKDIR ${BUILD_HOME}
COPY . .
RUN nimble setup -l
RUN make -j ${MAKE_PARALLEL}

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

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
# Changing NIM_VERSION means changing the two sha256 too.
ARG NIM_VERSION=2.2.14
ARG NIM_SHA256_X64=c1cbd106f9ff0c856e38abebd0ac9503c23aa3393174fcfc3307ee3b2bfe909a
ARG NIM_SHA256_ARM64=74c03927d88f935a9acf18576d599eceb3d6f6bd1f7a4d267675c4b6007b901f
RUN case "$(uname -m)" in \
      x86_64) nim_arch=x64; nim_sha256=${NIM_SHA256_X64} ;; \
      aarch64) nim_arch=arm64; nim_sha256=${NIM_SHA256_ARM64} ;; \
      *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/nim.tar.xz "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_${nim_arch}.tar.xz" && \
    echo "${nim_sha256}  /tmp/nim.tar.xz" | sha256sum -c - && \
    tar -xJf /tmp/nim.tar.xz -C /opt && \
    rm /tmp/nim.tar.xz
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

# check=skip=InvalidDefaultArgInFrom
#
# Builder image: a pinned Debian base image, packages from a frozen apt
# archive/snapshot, and pinned build tools built from verified sources.
# After this image is built the LLVM build itself needs no network access.
#
# Built by ./build.sh image — all ARGs come from config/versions.env and
# distros/<distro>/distro.env.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG DISTRO
ARG ARCH
ARG BUILD_PYTHON=0
ARG CMAKE_VERSION
ARG NINJA_VERSION
ARG ZSTD_VERSION
ARG PYTHON_VERSION

ENV LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    TZ=UTC \
    DEBIAN_FRONTEND=noninteractive \
    PATH=/opt/tools/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY distros/${DISTRO}/sources.list /etc/apt/sources.list

RUN set -eux; \
    rm -f /etc/apt/sources.list.d/*; \
    printf '%s\n' \
        'Acquire::Check-Valid-Until "false";' \
        'Acquire::Retries "5";' \
        'APT::Install-Recommends "false";' \
        'APT::Install-Suggests "false";' \
        > /etc/apt/apt.conf.d/90builder; \
    apt-get update; \
    if [ "$BUILD_PYTHON" = 1 ]; then py=; else py=python3; fi; \
    apt-get install -y build-essential patch xz-utils zlib1g-dev $py; \
    rm -rf /var/lib/apt/lists/*

COPY sources/cmake-${CMAKE_VERSION}-linux-${ARCH}.tar.gz \
     sources/ninja-${NINJA_VERSION}.tar.gz \
     sources/zstd-${ZSTD_VERSION}.tar.gz \
     sources/Python-${PYTHON_VERSION}.tar.xz \
     /tmp/deps/
COPY docker/install-tools.sh /tmp/install-tools.sh

RUN /tmp/install-tools.sh && rm -rf /tmp/deps /tmp/install-tools.sh

FROM ubuntu:22.04 AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

RUN apt update && apt install -y --no-install-recommends \
    sudo \
    micro \
    tree \
    file \
    curl \
    wget \
    vim \
    expect \
    python3 \
    git \
    libglib2.0-dev \
    libfdt-dev \
    libpixman-1-dev \
    zlib1g-dev \
    ninja-build \
    build-essential \
    pkg-config \
    cmake \
    python-is-python3 \
    golang-1.18-go \
    libelf-dev \
    debootstrap \
    libslirp-dev \
    libncurses-dev \
    gawk \
    flex \
    bison \
    openssl \
    libssl-dev \
    dkms \
    libelf-dev \
    libudev-dev \
    libpci-dev \
    libiberty-dev \
    autoconf \
    llvm \
    flex \
    fakeroot \
    crash \
    kexec-tools \
    makedumpfile \
    kernel-wedge \
    libncurses5 \
    libncurses5-dev \
    asciidoc \
    binutils-dev \
    libcap-dev \
    default-jdk \
    curl \
    zstd

WORKDIR /workspace

COPY --chown=root:root moneta-modified/ /workspace/moneta
COPY --chown=root:root scripts/entrypoint.sh /workspace/entrypoint.sh

RUN chmod +x /workspace/moneta/scripts/*.sh
RUN chmod +x /workspace/moneta/build.sh
RUN chmod +x /workspace/entrypoint.sh

ENTRYPOINT [ "/workspace/entrypoint.sh" ]

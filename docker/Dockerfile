FROM ubuntu:22.04 AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

RUN echo "kexec-tools kexec-tools/load_kexec boolean false" | debconf-set-selections
ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y --no-install-recommends \
    sudo \
    micro \
    tree \
    file \
    curl \
    wget \
    vim \
    expect \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY --chown=root:root moneta-modified/ /workspace/moneta
COPY --chown=root:root scripts/entrypoint.sh /workspace/entrypoint.sh

RUN chmod +x /workspace/moneta/scripts/*.sh
RUN chmod +x /workspace/moneta/build.sh
RUN chmod +x /workspace/entrypoint.sh

ENTRYPOINT [ "/workspace/entrypoint.sh" ]

# syntax=docker/dockerfile:1.7
FROM debian:12-slim

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
    NODE_VERSION=20.18.0 \
    KUBECTL_VERSION=v1.30.5 \
    HELM_VERSION=v3.16.2 \
    HOME=/home/claude-agent

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq tini procps \
      python3 python3-pip python3-venv \
      tmux less vim-tiny \
      restic \
    && rm -rf /var/lib/apt/lists/*

# Node.js (needed for `claude` CLI which is npm-distributed)
# Map TARGETARCH (amd64/arm64) to Node's arch naming (x64/arm64) without bash-
# specific parameter substitution — Dockerfile RUN uses /bin/sh (dash on Debian).
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) NODE_ARCH=x64   ;; \
      arm64) NODE_ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
        -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version && npm --version

# kubectl
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
        -o /usr/local/bin/kubectl \
    && chmod 0755 /usr/local/bin/kubectl \
    && kubectl version --client=true

# Helm
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
        -o /tmp/helm.tgz \
    && tar -xzf /tmp/helm.tgz -C /tmp \
    && mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm \
    && rm -rf /tmp/helm.tgz /tmp/linux-${TARGETARCH} \
    && helm version

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# yq (binary)
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${TARGETARCH}" \
        -o /usr/local/bin/yq \
    && chmod 0755 /usr/local/bin/yq

# Claude Code CLI
# Run install/version-check with HOME=/tmp and from a known working dir.
# The claude-agent user doesn't exist yet, so /home/claude-agent isn't usable
# yet, and `claude` is known to scan the working directory on startup — running
# from `/` as root has triggered OOM in some environments. See
# anthropics/claude-code#22536.
WORKDIR /tmp
RUN HOME=/tmp npm install -g @anthropic-ai/claude-code \
    && HOME=/tmp claude --version

# Non-root user (uid 1000) matches the VM's claude-agent
RUN groupadd -g 1000 claude-agent \
    && useradd -m -u 1000 -g 1000 -s /bin/bash claude-agent \
    && mkdir -p /workspace /jobs \
    && chown -R claude-agent:claude-agent /workspace /home/claude-agent

COPY claude-run-pod /usr/local/bin/claude-run-pod
RUN chmod 0755 /usr/local/bin/claude-run-pod

USER claude-agent
WORKDIR /workspace
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/claude-run-pod"]

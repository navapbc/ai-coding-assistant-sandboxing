# AI Agent Sandbox container: all three assistants + default-deny egress firewall.
# Built on the devcontainers Ubuntu base (includes the non-root `vscode` user).
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Firewall tooling + common dev utilities. dnsutils provides dig; jq parses
# GitHub's IP-range metadata in init-firewall.sh; dnsmasq backs the optional
# DNS allowlist (ENABLE_DNS_ALLOWLIST).
RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables \
    ipset \
    dnsutils \
    dnsmasq \
    jq \
    curl \
    ca-certificates \
    git \
    gh \
    && rm -rf /var/lib/apt/lists/*
# dnsmasq is installed but not run by default; init-firewall.sh launches it only
# when ENABLE_DNS_ALLOWLIST=true. (No init system in the container starts it.)

# Node.js for the AI CLIs (NodeSource keeps this current on Ubuntu).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# The three AI coding assistants.
RUN npm install -g \
    @anthropic-ai/claude-code \
    @openai/codex \
    @github/copilot

# Managed policy baked into the image: developers inside the container cannot
# override these Claude Code settings (same file MDM deploys on host macOS,
# at the Linux managed path).
RUN mkdir -p /etc/claude-code
COPY managed-settings.json /etc/claude-code/managed-settings.json

# Codex enforced requirements (Linux managed path).
RUN mkdir -p /etc/codex
COPY requirements.toml /etc/codex/requirements.toml

# Firewall: script + allowlist, runnable via sudo by the vscode user ONLY for
# this exact command (no general root).
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY allowed-domains.txt /usr/local/etc/allowed-domains.txt
RUN chmod 755 /usr/local/bin/init-firewall.sh \
    && echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/init-firewall \
    && chmod 440 /etc/sudoers.d/init-firewall

# --- Experimental opt-in: Envoy CONNECT forward proxy (EGRESS_MODE=proxy) -----
# The scripts are always copied (tiny, unused unless EGRESS_MODE=proxy). Envoy +
# its run-as user are installed ONLY when built with --build-arg EGRESS_PROXY=true,
# so the default image isn't bloated. init-firewall.sh hands off to this when
# EGRESS_MODE=proxy. See egress-proxy/README.md. EXPERIMENTAL — verify the Envoy
# install/version on your platform before relying on it.
COPY egress-proxy/ /usr/local/share/egress-proxy/
RUN chmod 0755 /usr/local/share/egress-proxy/init-egress-proxy.sh
ARG EGRESS_PROXY=false
ARG ENVOY_VERSION=1.31.0
RUN if [ "$EGRESS_PROXY" = "true" ]; then \
        set -eux; \
        apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*; \
        curl -fsSL https://func-e.io/install.sh | bash -s -- -b /usr/local/bin; \
        func-e use "${ENVOY_VERSION}"; \
        install -m 0755 "$(func-e which)" /usr/local/bin/envoy; \
        useradd --system --no-create-home --shell /usr/sbin/nologin envoyproxy; \
    fi

USER vscode

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

USER vscode

#!/usr/bin/env bash
#
# setup-macos.sh — Idempotent macOS environment setup for bcvk E2E tests
#
# Installs all dependencies on a bare macOS machine (e.g. Scaleway Mac mini).
# Safe to run multiple times; skips already-installed components.
#
set -euo pipefail

echo "=== bcvk E2E: macOS Environment Setup ==="

# --- Homebrew ---
if ! command -v brew &>/dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

# --- Packages ---
for pkg in podman vfkit rust git go node; do
    if brew list "$pkg" &>/dev/null; then
        echo "  $pkg: already installed"
    else
        echo "  $pkg: installing..."
        brew install "$pkg"
    fi
done

# --- SSH key ---
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
    echo "Generating SSH key..."
    mkdir -p ~/.ssh
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "bcvk-e2e"
else
    echo "  SSH key: already exists"
fi

# --- Podman Machine ---
if ! podman machine info --format '{{.Host.CurrentMachine}}' 2>/dev/null | grep -q .; then
    echo "Initializing podman machine..."
    podman machine init
    echo "Starting podman machine..."
    podman machine start
else
    if ! podman machine info --format '{{.Host.MachineState}}' 2>/dev/null | grep -qi running; then
        echo "Starting podman machine..."
        podman machine start
    else
        echo "  Podman machine: already running"
    fi
fi

echo ""
echo "=== Setup Complete ==="
echo "  podman: $(podman --version)"
echo "  vfkit:  $(vfkit --version 2>&1 || echo 'not found')"
echo "  gvproxy: $(ls /opt/homebrew/opt/podman/libexec/podman/gvproxy 2>/dev/null || echo 'not found')"
echo "  rust:   $(rustc --version)"
echo "  node:   $(node --version)"
echo "  bcvk:   $(bcvk --version 2>/dev/null || echo 'not yet installed')"

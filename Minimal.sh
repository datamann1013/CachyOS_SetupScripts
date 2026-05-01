#!/bin/bash
# setup-minimal.sh - Part 1 of the modular CachyOS setup
# Run on a fresh CachyOS installation.

set -euo pipefail

DRY_RUN=""
for arg in "$@"; do
    [ "$arg" = "--dry-run" ] && DRY_RUN=1
done

run() {
    if [ -n "$DRY_RUN" ]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

echo "========================================="
echo " Starting Minimal Profile Setup${DRY_RUN:+ (DRY RUN)}"
echo "========================================="

# --- 1. System Update & Essential Packages ---
echo ">>> Updating system and installing base packages..."
run sudo pacman -Syu --noconfirm
run sudo pacman -S --needed --noconfirm \
    flatpak \
    distrobox \
    firewalld \
    git \
    base-devel \
    podman \
    netavark \
    crun \
    wget \
    curl \
    wireguard-tools

# --- 2. Enable and Start Firewall ---
echo ">>> Enabling firewalld..."
run sudo systemctl enable --now firewalld
if [ -z "$DRY_RUN" ]; then
    echo "Firewall status: $(sudo firewall-cmd --state)"
fi

# --- 3. Flatpak Setup ---
echo ">>> Configuring Flathub..."
run flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# --- 4. Verify installations ---
echo ">>> Verifying installs..."
if [ -z "$DRY_RUN" ]; then
    distrobox --version
    podman --version
fi

# --- 5. Verify LTS Kernel ---
echo ">>> Checking for LTS kernel..."
if [ -z "$DRY_RUN" ]; then
    if pacman -Q linux-cachyos-lts &>/dev/null; then
        echo "LTS kernel (linux-cachyos-lts) is installed."
    else
        echo "WARNING: LTS kernel not found. Install with: sudo pacman -S linux-cachyos-lts linux-cachyos-lts-headers"
    fi
fi

echo "========================================="
echo " Minimal Profile Setup Complete!"
echo "========================================="

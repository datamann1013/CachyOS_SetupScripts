#!/bin/bash
# setup-minimal.sh - Part 1 of the modular CachyOS "dock" setup
# Run this on a fresh CachyOS installation.

set -euo pipefail  # Exit on error, undefined variable, or pipe failure

echo "========================================="
echo " Starting Minimal Profile Setup"
echo "========================================="

# --- 1. System Update & Essential Packages ---
echo ">>> Updating system and installing base packages..."
sudo pacman -Syu --noconfirm

# Install packages, explicitly choosing providers to avoid prompts
sudo pacman -S --needed --noconfirm \
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
echo ">>> Enabling and starting firewalld..."
sudo systemctl enable --now firewalld
echo "Firewall status:"
sudo firewall-cmd --state

# --- 3. Flatpak Setup ---
echo ">>> Configuring Flatpak and Flathub..."
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# --- 4. Basic Distrobox & Podman Verification ---
echo ">>> Verifying Distrobox and Podman installations..."
distrobox --version
podman --version

# --- 5. Verify LTS Kernel is Present ---
echo ">>> Checking for LTS kernel..."
if pacman -Q linux-cachyos-lts &>/dev/null; then
    echo "LTS kernel (linux-cachyos-lts) is installed."
else
    echo "WARNING: LTS kernel not found. Install it with: sudo pacman -S linux-cachyos-lts"
fi

echo "========================================="
echo " Minimal Profile Setup Complete!"
echo "========================================="
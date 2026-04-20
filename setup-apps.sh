#!/bin/bash
# setup-apps.sh - Part 2 of the modular CachyOS "dock" setup
# Run this AFTER setup-minimal.sh

set -euo pipefail

echo "========================================="
echo " Starting Apps Profile Setup"
echo "========================================="

# --- 1. Install Flatpak Applications ---
echo ">>> Installing additional Flatpak applications..."
flatpak install -y flathub \
    com.discordapp.Discord \
    com.spotify.Client \
    com.github.tchx84.Flatseal \
    org.onlyoffice.desktopeditors

# Optional: If you prefer LibreOffice over OnlyOffice, replace the line above with:
# flatpak install -y flathub org.libreoffice.LibreOffice

# --- 2. Create File Server Container (Distrobox) ---
echo ">>> Setting up Samba file server container..."
# Create a Distrobox container using Ubuntu LTS for Samba compatibility
distrobox create --name fileserver --image ubuntu:24.04 --yes
distrobox enter fileserver -- bash -c "
    sudo apt update && sudo apt install -y samba
"

# Create a samba configuration that shares the host directories
# We'll bind mount the host directories into the container
cat > ~/.config/distrobox/fileserver.ini << 'EOF'
[container]
additional_volumes="
    ~/MachineFiles:/mnt/MachineFiles:rw
    ~/BrowserDownloads:/mnt/BrowserDownloads:rw
"
EOF

echo ">>> File server container created. To start it and configure Samba:"
echo "    distrobox enter fileserver"
echo "    sudo nano /etc/samba/smb.conf"
echo "    (Add shares for /mnt/MachineFiles and /mnt/BrowserDownloads)"
echo "    sudo systemctl enable --now smbd"

# --- 3. Verification ---
echo "========================================="
echo " Apps Profile Setup Complete!"
echo "========================================="
echo ""
echo "Verification commands:"
echo "  flatpak list | grep -E 'Discord|Spotify|Flatseal|OnlyOffice'"
echo "  distrobox list"
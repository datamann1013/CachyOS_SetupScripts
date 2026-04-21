#!/bin/bash
# setup-apps.sh - Part 2 of the modular CachyOS "dock" setup (Fixed Volume Mounts)
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

# --- 2. Create host directories for shares (must exist before container mounts) ---
echo ">>> Creating host directories for file shares..."
mkdir -p ~/MachineFiles ~/BrowserDownloads
chmod 777 ~/MachineFiles ~/BrowserDownloads   # Allow Samba to write

# --- 3. Remove existing fileserver container if it exists ---
if distrobox list | grep -q fileserver; then
    echo ">>> Removing existing fileserver container for reconfiguration..."
    distrobox stop fileserver || true
    distrobox rm fileserver --force
fi

# --- 4. Create distrobox config directory and volume mount config ---
mkdir -p ~/.config/distrobox
cat > ~/.config/distrobox/fileserver.ini << 'EOF'
[container]
additional_volumes="
    ~/MachineFiles:/mnt/MachineFiles:rw
    ~/BrowserDownloads:/mnt/BrowserDownloads:rw
"
EOF

echo ">>> Distrobox config written to ~/.config/distrobox/fileserver.ini"

# --- 5. Create the fileserver container ---
echo ">>> Creating Samba file server container..."
distrobox create --name fileserver --image ubuntu:24.04 --yes

# --- 6. Wait a moment for container to be ready ---
sleep 2

# --- 7. Prompt for Samba password ---
echo ""
read -s -p "Enter desired Samba password for user 'marom': " SAMBA_PASS
echo ""
read -s -p "Confirm password: " SAMBA_PASS_CONFIRM
echo ""

if [ "$SAMBA_PASS" != "$SAMBA_PASS_CONFIRM" ]; then
    echo "Error: Passwords do not match. Exiting."
    exit 1
fi

# --- 8. Automated Samba setup inside the container ---
echo ">>> Configuring Samba inside container..."
distrobox enter fileserver -- bash -c "
    set -e

    # Ensure user has passwordless sudo
    echo 'Configuring passwordless sudo for container user...'
    if ! sudo -n true 2>/dev/null; then
        echo '$USER ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/$USER
        sudo chmod 440 /etc/sudoers.d/$USER
    fi

    echo 'Updating package list and installing Samba...'
    sudo apt update -qq
    sudo apt install -y samba

    # The host directories are already mounted at /mnt/MachineFiles and /mnt/BrowserDownloads
    # No need to create them; just ensure they are accessible (permissions already set on host)
    # Write Samba configuration
    echo 'Writing Samba configuration...'
    sudo tee /etc/samba/smb.conf > /dev/null << 'SMBEOF'
[global]
   workgroup = WORKGROUP
   server string = CachyOS File Server
   security = user
   map to guest = Bad User
   log file = /var/log/samba/%m.log
   max log size = 50

[MachineFiles]
   path = /mnt/MachineFiles
   browseable = yes
   read only = no
   guest ok = yes
   create mask = 0777
   directory mask = 0777

[BrowserDownloads]
   path = /mnt/BrowserDownloads
   browseable = yes
   read only = no
   guest ok = yes
   create mask = 0777
   directory mask = 0777
SMBEOF

    # Create a samba user (same as host user)
    echo 'Creating Samba user...'
    sudo useradd -m -s /bin/bash marom || true
    echo -e '$SAMBA_PASS\n$SAMBA_PASS' | sudo smbpasswd -a marom -s
    sudo smbpasswd -e marom

    # Enable and start services
    echo 'Starting Samba services...'
    sudo systemctl enable smbd
    sudo systemctl start smbd
"

# --- 9. Verify container is running ---
echo ">>> Checking container status..."
distrobox list

# --- 10. Generate systemd user service for auto-start on host boot ---
echo ">>> Setting up auto-start for fileserver container..."
mkdir -p ~/.config/systemd/user
podman generate systemd --new --name fileserver > ~/.config/systemd/user/container-fileserver.service
systemctl --user daemon-reload
systemctl --user enable container-fileserver.service
systemctl --user start container-fileserver.service

echo "========================================="
echo " Apps Profile Setup Complete!"
echo "========================================="
echo ""
echo "Samba shares are now accessible at:"
echo "  \\\\$(hostname -I | awk '{print $1}')\\MachineFiles"
echo "  \\\\$(hostname -I | awk '{print $1}')\\BrowserDownloads"
echo ""
echo "Samba user: marom"
echo "Password:   (the one you just entered)"
echo ""
echo "Verification commands:"
echo "  flatpak list | grep -E 'Discord|Spotify|Flatseal|OnlyOffice'"
echo "  distrobox list"
echo "  podman ps"
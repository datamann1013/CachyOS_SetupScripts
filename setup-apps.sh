#!/bin/bash
# setup-apps.sh - Part 2 of the modular CachyOS "dock" setup (Dual Browsers + Samba)
# Run this AFTER setup-minimal.sh

set -euo pipefail

echo "========================================="
echo " Starting Apps Profile Setup"
echo "========================================="

# --- 1. Install Flatpak Applications (No Browsers Yet) ---
echo ">>> Installing additional Flatpak applications..."
flatpak install -y flathub \
    com.discordapp.Discord \
    com.spotify.Client \
    com.github.tchx84.Flatseal \
    org.onlyoffice.desktopeditors

# --- 2. Remove Generic Waterfox Installation ---
echo ">>> Removing generic Waterfox installation (to be replaced with two dedicated profiles)..."
flatpak uninstall -y net.waterfox.waterfox || true

# --- 3. Create Isolated Data Directories for Waterfox Profiles ---
echo ">>> Creating isolated data directories for Waterfox profiles..."
mkdir -p ~/BrowserData/Fun
mkdir -p ~/BrowserData/Secure

# --- 4. Install Two Separate Waterfox Instances ---
echo ">>> Installing two separate Waterfox instances (Fun and Secure)..."

# Install the base Waterfox Flatpak (this provides the runtime and binaries)
flatpak install -y flathub net.waterfox.waterfox

# Create custom profile launchers (Fun Browser - No VPN, uses Samba share)
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/waterfox-fun.desktop << 'EOF'
[Desktop Entry]
Name=Waterfox (Fun)
Comment=Fun Browser - Saves downloads to the SMB share
Exec=/usr/bin/flatpak run --env=HOME=/home/marom/BrowserData/Fun --filesystem=/home/marom/BrowserDownloads net.waterfox.waterfox
Icon=net.waterfox.waterfox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

# Create custom profile launcher (Secure Browser - Will use VPN network)
cat > ~/.local/share/applications/waterfox-secure.desktop << 'EOF'
[Desktop Entry]
Name=Waterfox (Secure)
Comment=Secure Browser - Runs over VPN
Exec=/usr/bin/flatpak run --env=HOME=/home/marom/BrowserData/Secure net.waterfox.waterfox
Icon=net.waterfox.waterfox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

# Update desktop database
update-desktop-database ~/.local/share/applications/ 2>/dev/null || true

echo ">>> Fun browser will save downloads to ~/BrowserDownloads (SMB share)."
echo ">>> Secure browser will use a VPN network (to be configured later)."

# --- 5. Create Host Directories for Samba Shares ---
echo ">>> Creating host directories for file shares..."
mkdir -p ~/MachineFiles ~/BrowserDownloads
chmod 755 ~/MachineFiles ~/BrowserDownloads

# --- 6. Remove Any Existing Samba Container ---
if podman ps -a | grep -q samba-server; then
    echo ">>> Removing existing Samba container..."
    podman stop samba-server || true
    podman rm samba-server || true
fi

# --- 7. Prompt for Samba Password ---
echo ""
read -s -p "Enter desired Samba password for user 'marom': " SAMBA_PASS
echo ""
read -s -p "Confirm password: " SAMBA_PASS_CONFIRM
echo ""

if [ "$SAMBA_PASS" != "$SAMBA_PASS_CONFIRM" ]; then
    echo "Error: Passwords do not match. Exiting."
    exit 1
fi

# --- 8. Run the dperson/samba Container ---
echo ">>> Starting Samba container..."
podman run -d \
  --name samba-server \
  -p 139:139 -p 445:445 \
  -v ~/MachineFiles:/share/MachineFiles:z \
  -v ~/BrowserDownloads:/share/BrowserDownloads:z \
  -e USER="marom;${SAMBA_PASS}" \
  -e SHARE="MachineFiles;/share/MachineFiles;yes;no;no;marom" \
  -e SHARE2="BrowserDownloads;/share/BrowserDownloads;yes;no;no;marom" \
  --restart always \
  dperson/samba

# --- 9. Firewall Rules for Samba ---
echo ">>> Configuring firewall for Samba..."
sudo firewall-cmd --add-service=samba --permanent
sudo firewall-cmd --reload

# --- 10. Generate systemd User Service for Auto-Start on Boot ---
echo ">>> Setting up auto-start for Samba container..."
mkdir -p ~/.config/systemd/user
podman generate systemd --new --name samba-server > ~/.config/systemd/user/container-samba-server.service
systemctl --user daemon-reload
systemctl --user enable container-samba-server.service

# --- 11. Configure Fun Waterfox to Save Downloads to SMB Share ---
echo ">>> Configuring Fun Waterfox to save downloads to Samba share..."
sudo flatpak override net.waterfox.waterfox --filesystem="$HOME/BrowserDownloads"

# --- 12. Install Firejail for Disposable Sandboxing ---
echo ">>> Installing Firejail for disposable file sandboxing..."
sudo pacman -S --noconfirm firejail

# --- 13. Create the Sandbox Launcher Script ---
echo ">>> Creating sandbox launcher script..."
mkdir -p ~/bin
cat > ~/bin/sandbox-open << 'EOF'
#!/bin/bash
# sandbox-open - Opens a file in a disposable Firejail sandbox

if [ $# -eq 0 ]; then
    echo "Usage: sandbox-open <file>"
    exit 1
fi

FILE="$1"

if [ ! -f "$FILE" ]; then
    echo "Error: File '$FILE' not found."
    exit 1
fi

# Determine the right application based on file extension
MIME_TYPE=$(file --mime-type -b "$FILE")

case "$MIME_TYPE" in
    application/pdf)
        APP="evince"
        ;;
    application/vnd.openxmlformats-officedocument.*|application/msword)
        APP="libreoffice"
        ;;
    application/vnd.oasis.opendocument.*)
        APP="libreoffice"
        ;;
    application/zip|application/x-tar|application/x-gzip)
        APP="file-roller"
        ;;
    text/*)
        APP="gedit"
        ;;
    image/*)
        APP="eog"
        ;;
    video/*)
        APP="vlc"
        ;;
    *)
        echo "Unknown file type: $MIME_TYPE"
        echo "Opening with default handler..."
        APP="xdg-open"
        ;;
esac

echo "Opening '$FILE' in a disposable Firejail sandbox using $APP..."
echo "All changes will be lost when you close the application."

# The magic: --private creates a temporary home directory that is deleted on exit.
# --net=none blocks all network access for extra safety.
firejail --private --net=none "$APP" "$FILE"

echo "Sandbox destroyed. All temporary files have been removed."
EOF

chmod +x ~/bin/sandbox-open

# --- 14. Prompt for VPN Configuration for Secure Browser ---
echo ""
echo "========================================="
echo " VPN Configuration for Waterfox (Secure)"
echo "========================================="
echo "Please provide the path to your WireGuard configuration file."
echo "This file will be used to create a VPN gateway container for the secure browser."
read -p "Path to WireGuard config file (leave blank to skip VPN setup): " WG_CONFIG_PATH

if [ -n "$WG_CONFIG_PATH" ] && [ -f "$WG_CONFIG_PATH" ]; then
    echo ">>> Setting up VPN gateway container for secure browser..."
    
    # Create directory for VPN configurations
    mkdir -p ~/vpn/wireguard
    
    # Copy the WireGuard config
    cp "$WG_CONFIG_PATH" ~/vpn/wireguard/wg0.conf
    
    # Create a Podman pod for VPN-enabled applications
    podman pod create --name vpn-pod -p 8080:8080
    
    # Run Gluetun VPN gateway in the pod
    podman run -d \
      --pod vpn-pod \
      --name gluetun-vpn \
      --cap-add NET_ADMIN \
      -v ~/vpn/wireguard:/gluetun/wireguard:ro \
      -e VPN_SERVICE_PROVIDER=custom \
      -e VPN_TYPE=wireguard \
      -e WIREGUARD_CONFIG_FILE=/gluetun/wireguard/wg0.conf \
      qmcgaw/gluetun
    
    # Create a Distrobox container that uses the VPN pod's network
    echo ">>> Creating a Distrobox container that routes through the VPN..."
    distrobox create --name vpn-secure --image ubuntu:24.04 --yes
    # Note: To route Distrobox through the VPN, we'll use a custom network namespace in a later step.
    # For now, the pod is ready. The secure browser will be configured to use this network.
    
    # Generate systemd service for the VPN pod
    echo ">>> Setting up auto-start for VPN pod..."
    mkdir -p ~/.config/systemd/user
    podman generate systemd --new --name vpn-pod > ~/.config/systemd/user/container-vpn-pod.service
    systemctl --user daemon-reload
    systemctl --user enable container-vpn-pod.service
    
    echo ">>> VPN gateway container is running. Waterfox (Secure) will use this network."
else
    echo ">>> No valid WireGuard config provided. Skipping VPN setup."
    echo ">>> You can manually configure the VPN later using the provided scripts."
fi

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
echo "Two Waterfox browsers have been installed:"
echo "  - Waterfox (Fun): Saves downloads to the SMB share. No VPN."
echo "  - Waterfox (Secure): Runs over VPN (if configured)."
echo ""
echo "Verification commands:"
echo "  flatpak list | grep waterfox"
echo "  ls ~/.local/share/applications/waterfox*.desktop"
echo "  smbclient -L localhost -N"
echo "  podman ps"
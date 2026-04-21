#!/bin/bash
# setup-apps.sh - Part 2 of the modular CachyOS "dock" setup (Dual Browsers + Samba + VPN)
# Run this AFTER setup-minimal.sh

set -euo pipefail

echo "========================================="
echo " Starting Apps Profile Setup"
echo "========================================="

# --- Helper: Get primary IP address ---
get_ip() {
    ip -4 addr show scope global | grep inet | head -1 | awk '{print $2}' | cut -d/ -f1
}

# --- 1. Configure Podman Registries ---
echo ">>> Configuring Podman to use Docker Hub..."
sudo mkdir -p /etc/containers
sudo tee /etc/containers/registries.conf << 'EOF' > /dev/null
unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "docker.io"
location = "docker.io"
EOF

# --- 2. Install Flatpak Applications ---
echo ">>> Installing additional Flatpak applications..."
flatpak install -y flathub \
    com.discordapp.Discord \
    com.spotify.Client \
    com.github.tchx84.Flatseal \
    org.onlyoffice.desktopeditors

# --- 3. Remove Generic Waterfox Installation ---
echo ">>> Removing generic Waterfox installation..."
flatpak uninstall -y net.waterfox.waterfox 2>/dev/null || true

# --- 4. Create Isolated Data Directories for Waterfox Profiles ---
echo ">>> Creating isolated data directories for Waterfox profiles..."
mkdir -p ~/BrowserData/Fun
mkdir -p ~/BrowserData/Secure

# --- 5. Install Waterfox (Flatpak) for Fun Browser ---
echo ">>> Installing Waterfox (Flatpak) for Fun browser..."
flatpak install -y flathub net.waterfox.waterfox

# Fun browser launcher (uses isolated profile, saves to SMB share)
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/waterfox-fun.desktop << EOF
[Desktop Entry]
Name=Waterfox (Fun)
Comment=Fun Browser - Saves downloads to the SMB share
Exec=/usr/bin/flatpak run --env=HOME=${HOME}/BrowserData/Fun --filesystem=${HOME}/BrowserDownloads net.waterfox.waterfox
Icon=net.waterfox.waterfox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

# --- 6. Create Host Directories for Samba Shares ---
echo ">>> Creating host directories for file shares..."
mkdir -p ~/MachineFiles ~/BrowserDownloads
chmod 755 ~/MachineFiles ~/BrowserDownloads

# --- 7. Remove Any Existing Samba Container ---
if podman ps -a | grep -q samba-server; then
    echo ">>> Removing existing Samba container..."
    podman stop samba-server 2>/dev/null || true
    podman rm samba-server 2>/dev/null || true
fi

# --- 8. Prompt for Samba Password ---
echo ""
read -s -p "Enter desired Samba password for user '$USER': " SAMBA_PASS
echo ""
read -s -p "Confirm password: " SAMBA_PASS_CONFIRM
echo ""

if [ "$SAMBA_PASS" != "$SAMBA_PASS_CONFIRM" ]; then
    echo "Error: Passwords do not match. Exiting."
    exit 1
fi

# --- 9. Run the Samba Container (High Ports for Rootless) ---
echo ">>> Starting Samba container..."
podman run -d \
  --name samba-server \
  -p 1139:139 -p 1445:445 \
  -v ~/MachineFiles:/share/MachineFiles:z \
  -v ~/BrowserDownloads:/share/BrowserDownloads:z \
  -e USER="${USER};${SAMBA_PASS}" \
  -e SHARE="MachineFiles;/share/MachineFiles;yes;no;no;${USER}" \
  -e SHARE2="BrowserDownloads;/share/BrowserDownloads;yes;no;no;${USER}" \
  --restart always \
  docker.io/servercontainers/samba:latest

# --- 10. Firewall Rules for Samba (High Ports) ---
echo ">>> Configuring firewall for Samba..."
sudo firewall-cmd --add-port=1139/tcp --add-port=1445/tcp --permanent 2>/dev/null || true
sudo firewall-cmd --reload 2>/dev/null || true

# --- 11. Generate systemd User Service for Auto-Start ---
echo ">>> Setting up auto-start for Samba container..."
mkdir -p ~/.config/systemd/user
podman generate systemd --new --name samba-server > ~/.config/systemd/user/container-samba-server.service
systemctl --user daemon-reload
systemctl --user enable container-samba-server.service

# --- 12. Configure Fun Waterfox to Save Downloads to SMB Share ---
echo ">>> Configuring Fun Waterfox to save downloads to Samba share..."
sudo flatpak override net.waterfox.waterfox --filesystem="$HOME/BrowserDownloads"

# --- 13. Install Firejail ---
echo ">>> Installing Firejail..."
sudo pacman -S --noconfirm firejail

# --- 14. Create Sandbox Launcher ---
echo ">>> Creating sandbox launcher script..."
mkdir -p ~/bin
cat > ~/bin/sandbox-open << 'EOF'
#!/bin/bash
[ $# -eq 0 ] && { echo "Usage: sandbox-open <file>"; exit 1; }
FILE="$1"
[ ! -f "$FILE" ] && { echo "File not found: $FILE"; exit 1; }
MIME=$(file --mime-type -b "$FILE")
case "$MIME" in
    application/pdf) APP="evince" ;;
    application/vnd.openxmlformats-officedocument.*|application/msword) APP="libreoffice" ;;
    application/vnd.oasis.opendocument.*) APP="libreoffice" ;;
    application/zip|application/x-tar|application/x-gzip) APP="file-roller" ;;
    text/*) APP="gedit" ;;
    image/*) APP="eog" ;;
    video/*) APP="vlc" ;;
    *) APP="xdg-open" ;;
esac
echo "Opening '$FILE' in disposable Firejail sandbox using $APP..."
firejail --private --net=none "$APP" "$FILE"
echo "Sandbox destroyed."
EOF
chmod +x ~/bin/sandbox-open

# --- 15. VPN Setup (WireGuard) ---
echo ""
echo "========================================="
echo " VPN Configuration for Secure Browser"
echo "========================================="
read -p "Path to WireGuard config file (leave blank to skip): " WG_CONFIG_PATH

VPN_ENABLED=false
if [ -n "$WG_CONFIG_PATH" ] && [ -f "$WG_CONFIG_PATH" ]; then
    VPN_ENABLED=true
    echo ">>> Setting up VPN pod and gateway..."
    mkdir -p ~/vpn/wireguard
    cp "$WG_CONFIG_PATH" ~/vpn/wireguard/wg0.conf

    # Remove existing VPN pod if any
    podman pod stop vpn-pod 2>/dev/null || true
    podman pod rm vpn-pod 2>/dev/null || true

    # Create pod
    podman pod create --name vpn-pod -p 8080:8080

    # Start Gluetun inside the pod
    podman run -d \
      --pod vpn-pod \
      --name gluetun-vpn \
      --cap-add NET_ADMIN \
      -v ~/vpn/wireguard:/gluetun/wireguard:ro \
      -e VPN_SERVICE_PROVIDER=custom \
      -e VPN_TYPE=wireguard \
      -e WIREGUARD_CONFIG_FILE=/gluetun/wireguard/wg0.conf \
      docker.io/qmcgaw/gluetun

    # Auto-start systemd service
    mkdir -p ~/.config/systemd/user
    podman generate systemd --new --name vpn-pod > ~/.config/systemd/user/container-vpn-pod.service
    systemctl --user daemon-reload
    systemctl --user enable container-vpn-pod.service

    echo ">>> VPN gateway configured."

    # --- 16. Secure Browser inside Distrobox (Routed through VPN) ---
    echo ">>> Creating secure browser container (VPN routed)..."
    distrobox create --name vpn-browser --image ubuntu:24.04 --yes \
      --additional-flags "--network pod:vpn-pod"

    # Install Waterfox inside the container
    distrobox enter vpn-browser -- bash -c "
        sudo apt update && sudo apt install -y flatpak
        flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
        flatpak install -y flathub net.waterfox.waterfox
    "

    # Export the launcher to the host (appears in app menu)
    distrobox enter vpn-browser -- distrobox-export --app net.waterfox.waterfox

    echo ">>> Secure browser installed. Look for 'Waterfox (on vpn-browser)' in your menu."
else
    echo ">>> No VPN config provided. Secure browser will not be installed."
    echo ">>> You can manually set up VPN later."
fi

# --- Final Summary ---
IP_ADDR=$(get_ip)
echo ""
echo "========================================="
echo " Apps Profile Setup Complete!"
echo "========================================="
echo ""
echo "Samba shares are accessible at:"
echo "  \\\\${IP_ADDR}\\MachineFiles   (port 445)"
echo "  \\\\${IP_ADDR}\\BrowserDownloads (port 445)"
if [ "$VPN_ENABLED" = true ]; then
    echo "  (If using high ports, connect via port 1445)"
fi
echo ""
echo "Samba user: $USER"
echo "To test locally: smbclient -L localhost -p 1139 -N"
echo ""
echo "Browsers installed:"
echo "  - Waterfox (Fun)    : Saves to SMB share, no VPN"
if [ "$VPN_ENABLED" = true ]; then
    echo "  - Waterfox (on vpn-browser) : All traffic routed through WireGuard VPN"
fi
echo ""
echo "Sandbox launcher: sandbox-open <file>"
#!/bin/bash
# setup-apps.sh - Part 2 of the modular CachyOS "dock" setup (Dual Browsers + Samba)
# Run this AFTER setup-minimal.sh

set -euo pipefail

echo "========================================="
echo " Starting Apps Profile Setup"
echo "========================================="

# --- 1. Configure Podman Registries ---
echo ">>> Configuring Podman to use Docker Hub..."
sudo mkdir -p /etc/containers
sudo tee /etc/containers/registries.conf << 'EOF' > /dev/null
unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "docker.io"
location = "docker.io"
EOF

# --- 2. Install Flatpak Applications (No Browsers Yet) ---
echo ">>> Installing additional Flatpak applications..."
flatpak install -y flathub \
    com.discordapp.Discord \
    com.spotify.Client \
    com.github.tchx84.Flatseal \
    org.onlyoffice.desktopeditors

# --- 3. Remove Generic Waterfox Installation ---
echo ">>> Removing generic Waterfox installation (to be replaced with two dedicated profiles)..."
flatpak uninstall -y net.waterfox.waterfox 2>/dev/null || true

# --- 4. Create Isolated Data Directories for Waterfox Profiles ---
echo ">>> Creating isolated data directories for Waterfox profiles..."
mkdir -p ~/BrowserData/Fun
mkdir -p ~/BrowserData/Secure

# --- 5. Install Two Separate Waterfox Instances ---
echo ">>> Installing two separate Waterfox instances (Fun and Secure)..."
flatpak install -y flathub net.waterfox.waterfox

# Create custom profile launchers (Fun Browser - No VPN, uses Samba share)
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

# Create custom profile launcher (Secure Browser - Will use VPN network)
cat > ~/.local/share/applications/waterfox-secure.desktop << EOF
[Desktop Entry]
Name=Waterfox (Secure)
Comment=Secure Browser - Runs over VPN
Exec=/usr/bin/flatpak run --env=HOME=${HOME}/BrowserData/Secure net.waterfox.waterfox
Icon=net.waterfox.waterfox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

update-desktop-database ~/.local/share/applications/ 2>/dev/null || true

echo ">>> Fun browser will save downloads to ~/BrowserDownloads (SMB share)."
echo ">>> Secure browser will use a VPN network (to be configured later)."

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
read -s -p "Enter desired Samba password for user 'marom': " SAMBA_PASS
echo ""
read -s -p "Confirm password: " SAMBA_PASS_CONFIRM
echo ""

if [ "$SAMBA_PASS" != "$SAMBA_PASS_CONFIRM" ]; then
    echo "Error: Passwords do not match. Exiting."
    exit 1
fi

# --- 9. Run the Samba Container ---
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
  docker.io/servercontainers/samba:latest

# --- 10. Firewall Rules for Samba ---
echo ">>> Configuring firewall for Samba..."
sudo firewall-cmd --add-service=samba --permanent 2>/dev/null || true
sudo firewall-cmd --reload 2>/dev/null || true

# --- 11. Generate systemd User Service for Auto-Start on Boot ---
echo ">>> Setting up auto-start for Samba container..."
mkdir -p ~/.config/systemd/user
podman generate systemd --new --name samba-server > ~/.config/systemd/user/container-samba-server.service
systemctl --user daemon-reload
systemctl --user enable container-samba-server.service

# --- 12. Configure Fun Waterfox to Save Downloads to SMB Share ---
echo ">>> Configuring Fun Waterfox to save downloads to Samba share..."
sudo flatpak override net.waterfox.waterfox --filesystem="$HOME/BrowserDownloads"

# --- 13. Install Firejail for Disposable Sandboxing ---
echo ">>> Installing Firejail for disposable file sandboxing..."
sudo pacman -S --noconfirm firejail

# --- 14. Create the Sandbox Launcher Script ---
echo ">>> Creating sandbox launcher script..."
mkdir -p ~/bin
cat > ~/bin/sandbox-open << 'EOF'
#!/bin/bash

if [ $# -eq 0 ]; then
    echo "Usage: sandbox-open <file>"
    exit 1
fi

FILE="$1"

if [ ! -f "$FILE" ]; then
    echo "Error: File '$FILE' not found."
    exit 1
fi

MIME_TYPE=$(file --mime-type -b "$FILE")

case "$MIME_TYPE" in
    application/pdf)                    APP="evince" ;;
    application/vnd.openxmlformats-officedocument.*|application/msword) APP="libreoffice" ;;
    application/vnd.oasis.opendocument.*) APP="libreoffice" ;;
    application/zip|application/x-tar|application/x-gzip) APP="file-roller" ;;
    text/*)                             APP="gedit" ;;
    image/*)                            APP="eog" ;;
    video/*)                            APP="vlc" ;;
    *)                                  APP="xdg-open" ;;
esac

echo "Opening '$FILE' in a disposable Firejail sandbox using $APP..."
firejail --private --net=none "$APP" "$FILE"
echo "Sandbox destroyed."
EOF

chmod +x ~/bin/sandbox-open

# --- 15. VPN Configuration ---
echo ""
echo "========================================="
echo " VPN Configuration for Waterfox (Secure)"
echo "========================================="
read -p "Path to WireGuard config file (leave blank to skip): " WG_CONFIG_PATH

if [ -n "$WG_CONFIG_PATH" ] && [ -f "$WG_CONFIG_PATH" ]; then
    echo ">>> Setting up VPN gateway container..."
    mkdir -p ~/vpn/wireguard
    cp "$WG_CONFIG_PATH" ~/vpn/wireguard/wg0.conf
    
    podman pod create --name vpn-pod -p 8080:8080
    podman run -d \
      --pod vpn-pod \
      --name gluetun-vpn \
      --cap-add NET_ADMIN \
      -v ~/vpn/wireguard:/gluetun/wireguard:ro \
      -e VPN_SERVICE_PROVIDER=custom \
      -e VPN_TYPE=wireguard \
      -e WIREGUARD_CONFIG_FILE=/gluetun/wireguard/wg0.conf \
      docker.io/qmcgaw/gluetun
    
    mkdir -p ~/.config/systemd/user
    podman generate systemd --new --name vpn-pod > ~/.config/systemd/user/container-vpn-pod.service
    systemctl --user daemon-reload
    systemctl --user enable container-vpn-pod.service
    echo ">>> VPN gateway configured."
else
    echo ">>> Skipping VPN setup."
fi

echo "========================================="
echo " Apps Profile Setup Complete!"
echo "========================================="
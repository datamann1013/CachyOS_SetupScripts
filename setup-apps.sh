#!/bin/bash
# setup-apps.sh - Part 2 of the modular CachyOS "dock" setup (Dual Browsers + Samba + VPN)
# Run this AFTER setup-minimal.sh

set -euo pipefail

echo "========================================="
echo " Starting Apps Profile Setup"
echo "========================================="

# --- Helper: Get primary IP address (works in VMs and bare metal) ---
get_ip() {
    ip -4 addr show scope global | grep -v 'docker\|veth\|br-\|virbr' | grep inet | head -1 | awk '{print $2}' | cut -d/ -f1
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

# --- 7. Remove Existing Samba Container (clean start) ---
if podman ps -a | grep -q samba-server; then
    echo ">>> Removing existing Samba container..."
    podman stop samba-server 2>/dev/null || true
    podman rm samba-server 2>/dev/null || true
fi

# --- 8. Prompt for Samba Password (with retry) ---
MAX_ATTEMPTS=3
ATTEMPT=1
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo ""
    read -s -p "Enter desired Samba password for user '$USER': " SAMBA_PASS
    echo ""
    read -s -p "Confirm password: " SAMBA_PASS_CONFIRM
    echo ""

    if [ "$SAMBA_PASS" != "$SAMBA_PASS_CONFIRM" ]; then
        echo "Error: Passwords do not match."
        if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
            echo "Please try again ($((MAX_ATTEMPTS - ATTEMPT)) attempts remaining)."
        else
            echo "Maximum attempts reached. Exiting."
            exit 1
        fi
        ATTEMPT=$((ATTEMPT + 1))
    else
        break
    fi
done

# --- 9. Run the Samba Container (High Ports for Rootless) ---
echo ">>> Starting Samba container..."
podman run -d --replace \
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

# --- 14. Create Sandbox Launcher Script ---
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

# --- 15. Add ~/bin to PATH for Fish shell ---
if command -v fish &>/dev/null; then
    fish -c "fish_add_path ~/bin"
fi

# --- 16. Create Right-Click Service Menu (KDE/Dolphin) ---
echo ">>> Creating right-click 'Open in Sandbox' menu entry..."
mkdir -p ~/.local/share/kio/servicemenus
cat > ~/.local/share/kio/servicemenus/sandbox-open.desktop << EOF
[Desktop Entry]
Type=Service
MimeType=application/octet-stream;text/plain;application/pdf;image/jpeg;image/png;
Actions=openInSandbox
X-KDE-Priority=TopLevel

[Desktop Action openInSandbox]
Name=Open in Sandbox
Icon=security-high
Exec=${HOME}/bin/sandbox-open %f
EOF

# --- 17. VPN Setup (WireGuard) ---
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

    # Remove existing VPN resources
    podman pod stop vpn-pod 2>/dev/null || true
    podman pod rm vpn-pod 2>/dev/null || true
    podman stop vpn-browser gluetun-vpn 2>/dev/null || true
    podman rm vpn-browser gluetun-vpn 2>/dev/null || true

    # Create pod
    podman pod create --name vpn-pod -p 8080:8080

    # Start Gluetun inside the pod (privileged)
    podman run -d \
      --pod vpn-pod \
      --name gluetun-vpn \
      --cap-add NET_ADMIN \
      --privileged \
      -v ~/vpn/wireguard:/gluetun/wireguard:ro \
      -e VPN_SERVICE_PROVIDER=custom \
      -e VPN_TYPE=wireguard \
      -e WIREGUARD_CONFIG_FILE=/gluetun/wireguard/wg0.conf \
      docker.io/qmcgaw/gluetun

    # Create browser container (privileged)
    podman create \
      --name vpn-browser \
      --pod vpn-pod \
      --privileged \
      -e DISPLAY="${DISPLAY}" \
      -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
      -v "${HOME}/BrowserData/Secure:${HOME}/BrowserData/Secure:Z" \
      docker.io/library/ubuntu:24.04 \
      tail -f /dev/null

    podman start vpn-browser

    echo ">>> Installing Waterfox inside the VPN container (this may take a few minutes)..."
    podman exec vpn-browser bash -c "
      apt update -qq && apt install -y flatpak
      flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
      flatpak install -y flathub net.waterfox.waterfox
    "

    # Create launcher on host
    cat > ~/.local/share/applications/waterfox-secure.desktop << EOF
[Desktop Entry]
Name=Waterfox (Secure VPN)
Comment=Secure Browser - All traffic routed through WireGuard VPN
Exec=/usr/bin/podman exec -e DISPLAY=${DISPLAY} vpn-browser flatpak run net.waterfox.waterfox
Icon=net.waterfox.waterfox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

    update-desktop-database ~/.local/share/applications/ 2>/dev/null || true

    # Auto-start systemd service for VPN pod
    mkdir -p ~/.config/systemd/user
    podman generate systemd --new --name vpn-pod > ~/.config/systemd/user/container-vpn-pod.service
    systemctl --user daemon-reload
    systemctl --user enable container-vpn-pod.service

    echo ">>> VPN gateway and secure browser configured."
else
    echo ">>> No VPN config provided. Secure browser will not be installed."
fi

# --- Final Summary ---
IP_ADDR=$(get_ip)
echo ""
echo "========================================="
echo " Apps Profile Setup Complete!"
echo "========================================="
echo ""
if [ -n "$IP_ADDR" ]; then
    echo "Samba shares:"
    echo "  \\\\${IP_ADDR}\\MachineFiles"
    echo "  \\\\${IP_ADDR}\\BrowserDownloads"
else
    echo "Samba shares: (could not detect IP; use 'ip addr' to find it)"
fi
echo ""
echo "Samba user: $USER"
echo "Test locally: smbclient -L localhost -p 1139 -N"
echo ""
echo "Browsers installed:"
echo "  - Waterfox (Fun)        : No VPN, downloads to SMB share"
if [ "$VPN_ENABLED" = true ]; then
    echo "  - Waterfox (Secure VPN) : Routed through WireGuard"
fi
echo ""
echo "Sandbox launcher: sandbox-open <file>"
echo "Right-click menu: 'Open in Sandbox'"
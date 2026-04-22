#!/bin/bash
# setup-apps.sh - Part 2 of the modular CachyOS setup (Apps + Isolation + VPN)
# Run AFTER minimal.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo " Starting Apps Profile Setup"
echo "========================================="

# Returns the primary non-virtual IPv4 address
get_ip() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'
}

# --- 1. Configure Podman Registries ---
echo ">>> Configuring Podman to use Docker Hub..."
sudo mkdir -p /etc/containers
sudo tee /etc/containers/registries.conf > /dev/null << 'EOF'
unqualified-search-registries = ["docker.io"]

[[registry]]
prefix = "docker.io"
location = "docker.io"
EOF

# --- 2. Install Flatpak Applications ---
echo ">>> Installing Flatpak applications..."
flatpak install -y flathub \
    com.discordapp.Discord \
    com.spotify.Client \
    com.github.tchx84.Flatseal \
    org.onlyoffice.desktopeditors

# --- 3. Build Waterfox Container Image ---
echo ">>> Building Waterfox container image..."
CONTAINERFILE="${SCRIPT_DIR}/containers/waterfox-base.containerfile"
if [ ! -f "$CONTAINERFILE" ]; then
    echo "ERROR: Missing ${CONTAINERFILE}" >&2
    exit 1
fi
podman build -t localhost/waterfox-base -f "$CONTAINERFILE" "${SCRIPT_DIR}/containers/"

# --- 4. Create Download Directories ---
echo ">>> Creating file share directories..."
mkdir -p ~/BrowserDownloads ~/SecureDownloads ~/MachineFiles
chmod 755 ~/BrowserDownloads ~/SecureDownloads ~/MachineFiles

# --- 5. Fun Browser Launcher ---
echo ">>> Creating Fun browser launcher..."
mkdir -p ~/.local/bin ~/.local/share/applications

cat > ~/.local/bin/waterfox-fun << 'SCRIPT'
#!/bin/bash
# Runs Waterfox in a fresh, isolated container. Exits when browser closes.
# Only ~/BrowserDownloads is accessible — no host home directory.
WAYLAND_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"
exec podman run --rm \
    --name "waterfox-fun-$$" \
    --security-opt no-new-privileges \
    -e WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
    -e XDG_RUNTIME_DIR=/tmp/runtime \
    -v "${WAYLAND_SOCK}:/tmp/runtime/${WAYLAND_DISPLAY:-wayland-0}:ro" \
    -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
    -e DISPLAY="${DISPLAY:-:0}" \
    -v "${HOME}/BrowserDownloads:/home/waterfox/Downloads:Z" \
    localhost/waterfox-base
SCRIPT
chmod +x ~/.local/bin/waterfox-fun

cat > ~/.local/share/applications/waterfox-fun.desktop << EOF
[Desktop Entry]
Name=Waterfox (Fun)
Comment=Isolated browser — downloads go to ~/BrowserDownloads only
Exec=${HOME}/.local/bin/waterfox-fun
Icon=waterfox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
StartupNotify=true
EOF

# --- 6. Samba File Server ---
echo ">>> Setting up Samba file server..."

# Stop and remove existing container cleanly
podman stop samba-server 2>/dev/null || true
podman rm samba-server 2>/dev/null || true

# Prompt for Samba password — max 3 attempts
MAX_ATTEMPTS=3
ATTEMPT=1
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo ""
    read -s -p "Enter Samba password for user '${USER}': " SAMBA_PASS
    echo ""
    read -s -p "Confirm password: " SAMBA_PASS_CONFIRM
    echo ""
    if [ "$SAMBA_PASS" = "$SAMBA_PASS_CONFIRM" ]; then
        break
    fi
    echo "Passwords do not match."
    ATTEMPT=$((ATTEMPT + 1))
    if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
        echo "Maximum attempts reached. Exiting." >&2
        exit 1
    fi
    echo "Try again ($((MAX_ATTEMPTS - ATTEMPT + 1)) attempts remaining)."
done

# Write password to a temp env-file (never passed via -e / visible in ps)
SAMBA_ENV=$(mktemp)
chmod 600 "$SAMBA_ENV"
printf 'USER=%s;%s\n' "${USER}" "${SAMBA_PASS}" > "$SAMBA_ENV"
unset SAMBA_PASS SAMBA_PASS_CONFIRM

podman run -d \
    --name samba-server \
    -p 1139:139 -p 1445:445 \
    -v ~/MachineFiles:/share/MachineFiles:z \
    -v ~/BrowserDownloads:/share/BrowserDownloads:z \
    --env-file "$SAMBA_ENV" \
    -e SHARE="MachineFiles;/share/MachineFiles;yes;no;no;${USER}" \
    -e SHARE2="BrowserDownloads;/share/BrowserDownloads;yes;no;no;${USER}" \
    --restart on-failure:5 \
    docker.io/servercontainers/samba:4

rm -f "$SAMBA_ENV"

# Firewall rules for Samba high ports
sudo firewall-cmd --add-port=1139/tcp --add-port=1445/tcp --permanent 2>/dev/null || true
sudo firewall-cmd --reload 2>/dev/null || true

# systemd user service for Samba auto-start
mkdir -p ~/.config/systemd/user
podman generate systemd --name samba-server > ~/.config/systemd/user/container-samba-server.service
systemctl --user daemon-reload
systemctl --user enable container-samba-server.service

# --- 7. Firejail Sandbox Launcher ---
echo ">>> Installing Firejail..."
sudo pacman -S --noconfirm firejail

mkdir -p ~/bin
cat > ~/bin/sandbox-open << 'SCRIPT'
#!/bin/bash
[ $# -eq 0 ] && { echo "Usage: sandbox-open <file>"; exit 1; }
FILE="$1"
[ ! -f "$FILE" ] && { echo "File not found: $FILE"; exit 1; }
MIME=$(file --mime-type -b "$FILE")
case "$MIME" in
    application/pdf)                                    APP="evince" ;;
    application/vnd.openxmlformats-officedocument.*|\
    application/msword|\
    application/vnd.oasis.opendocument.*)               APP="libreoffice" ;;
    application/zip|\
    application/x-tar|\
    application/x-gzip|\
    application/x-bzip2|\
    application/x-xz)                                   APP="file-roller" ;;
    text/*)                                             APP="gedit" ;;
    image/*)                                            APP="eog" ;;
    video/*)                                            APP="vlc" ;;
    *)                                                  APP="xdg-open" ;;
esac
if ! command -v "$APP" &>/dev/null; then
    echo "Warning: '$APP' not found, falling back to xdg-open"
    APP="xdg-open"
fi
echo "Opening '${FILE}' in Firejail sandbox using ${APP}..."
firejail --private --net=none "$APP" "$FILE"
SCRIPT
chmod +x ~/bin/sandbox-open

# Add ~/bin to PATH for Bash, Zsh, and Fish
grep -qxF 'export PATH="$HOME/bin:$PATH"' ~/.bashrc 2>/dev/null \
    || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
grep -qxF 'export PATH="$HOME/bin:$PATH"' ~/.zshrc 2>/dev/null \
    || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc 2>/dev/null || true
if command -v fish &>/dev/null; then
    fish -c "fish_add_path ~/bin" 2>/dev/null || true
fi

# KDE/Dolphin right-click service menu
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
update-desktop-database ~/.local/share/applications/ 2>/dev/null || true

# --- 8. VPN Setup + Secure Browser (optional) ---
echo ""
echo "========================================="
echo " VPN Configuration for Secure Browser"
echo "========================================="
read -r -p "Path to WireGuard config file (leave blank to skip): " WG_CONFIG_PATH

VPN_ENABLED=false
if [ -n "$WG_CONFIG_PATH" ]; then
    if [ ! -f "$WG_CONFIG_PATH" ]; then
        echo "WARNING: File not found: ${WG_CONFIG_PATH} — skipping VPN setup." >&2
    else
        # Validate minimal WireGuard config structure
        if ! grep -q '^\[Interface\]' "$WG_CONFIG_PATH" || ! grep -q '^\[Peer\]' "$WG_CONFIG_PATH"; then
            echo "WARNING: WireGuard config missing [Interface] or [Peer] section — skipping VPN setup." >&2
        else
            VPN_ENABLED=true
            echo ">>> Configuring VPN gateway and secure browser..."
            mkdir -p ~/vpn/wireguard
            cp "$WG_CONFIG_PATH" ~/vpn/wireguard/wg0.conf
            chmod 600 ~/vpn/wireguard/wg0.conf

            # Clean up any previous VPN resources
            podman stop gluetun waterfox-secure 2>/dev/null || true
            podman rm gluetun waterfox-secure 2>/dev/null || true

            # Gluetun VPN gateway — NET_ADMIN only, no --privileged
            podman run -d \
                --name gluetun \
                --cap-add NET_ADMIN \
                --device /dev/net/tun \
                -v ~/vpn/wireguard:/gluetun/wireguard:ro \
                -e VPN_SERVICE_PROVIDER=custom \
                -e VPN_TYPE=wireguard \
                -e WIREGUARD_CONFIG_FILE=/gluetun/wireguard/wg0.conf \
                --restart on-failure:5 \
                docker.io/qmcgaw/gluetun:v3.40

            # systemd user service for Gluetun auto-start
            podman generate systemd --name gluetun > ~/.config/systemd/user/container-gluetun.service
            systemctl --user daemon-reload
            systemctl --user enable container-gluetun.service

            # Secure browser launcher — joins gluetun network namespace
            mkdir -p ~/.local/bin
            cat > ~/.local/bin/waterfox-secure << 'SCRIPT'
#!/bin/bash
# Runs Waterfox with all traffic through the gluetun VPN container.
# Only ~/SecureDownloads is accessible.
if ! podman inspect --format '{{.State.Status}}' gluetun 2>/dev/null | grep -q '^running$'; then
    echo "Error: gluetun container is not running."
    echo "Start it with: systemctl --user start container-gluetun.service"
    exit 1
fi
WAYLAND_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"
exec podman run --rm \
    --name "waterfox-secure-$$" \
    --network=container:gluetun \
    --security-opt no-new-privileges \
    -e WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
    -e XDG_RUNTIME_DIR=/tmp/runtime \
    -v "${WAYLAND_SOCK}:/tmp/runtime/${WAYLAND_DISPLAY:-wayland-0}:ro" \
    -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
    -e DISPLAY="${DISPLAY:-:0}" \
    -v "${HOME}/SecureDownloads:/home/waterfox/Downloads:Z" \
    localhost/waterfox-base
SCRIPT
            chmod +x ~/.local/bin/waterfox-secure

            cat > ~/.local/share/applications/waterfox-secure.desktop << EOF
[Desktop Entry]
Name=Waterfox (Secure VPN)
Comment=Isolated browser — all traffic through WireGuard VPN
Exec=${HOME}/.local/bin/waterfox-secure
Icon=waterfox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
StartupNotify=true
EOF
            update-desktop-database ~/.local/share/applications/ 2>/dev/null || true
            echo ">>> VPN gateway and secure browser configured."
        fi
    fi
fi

# --- Final Summary ---
IP_ADDR=$(get_ip)
echo ""
echo "========================================="
echo " Apps Profile Setup Complete!"
echo "========================================="
echo ""
if [ -n "${IP_ADDR:-}" ]; then
    echo "Samba shares (local access only, non-standard ports):"
    echo "  smb://localhost:1445/MachineFiles"
    echo "  smb://localhost:1445/BrowserDownloads"
    echo "  Test: smbclient -L localhost -p 1139 -U ${USER}"
else
    echo "Samba shares: (could not detect IP — use 'ip addr')"
fi
echo ""
echo "Browsers:"
echo "  Waterfox (Fun)    : ${HOME}/.local/bin/waterfox-fun"
echo "                      Downloads isolated to ~/BrowserDownloads"
if [ "$VPN_ENABLED" = true ]; then
    echo "  Waterfox (Secure) : ${HOME}/.local/bin/waterfox-secure"
    echo "                      All traffic through WireGuard VPN"
fi
echo ""
echo "Sandbox: sandbox-open <file>"
echo "         Right-click in Dolphin: 'Open in Sandbox'"

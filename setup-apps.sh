#!/bin/bash
# setup-apps.sh - Part 2 of the modular CachyOS setup (Apps + Isolation + VPN)
# Run AFTER minimal.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo " Starting Apps Profile Setup"
echo "========================================="

ensure_podman() {
    sudo loginctl enable-linger "$USER" 2>/dev/null || true
    if ! systemctl --user is-active podman.socket &>/dev/null; then
        echo "Starting podman user socket..."
        systemctl --user start podman.socket 2>/dev/null || true
    fi
}

ensure_podman

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
flatpak install --user -y flathub \
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
CONTAINER_NAME="waterfox-fun"
IMAGE="localhost/waterfox-base"
VOLUME="waterfox-fun-data"

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: Do not run this as root/sudo. Rootless podman stores images in your user account." >&2
    exit 1
fi

if ! systemctl --user is-active podman.socket &>/dev/null; then
    echo "Podman socket not running, starting it..."
    systemctl --user start podman.socket 2>/dev/null || true
fi

if ! podman image exists "$IMAGE" 2>/dev/null; then
    echo "ERROR: Image $IMAGE not found." >&2
    echo "Build it first: podman build -t $IMAGE -f ~/CachyOS_SetupScripts/containers/waterfox-base.containerfile ~/CachyOS_SetupScripts/containers/" >&2
    exit 1
fi

VOLUME_PATH=$(podman volume inspect "$VOLUME" --format '{{.Mountpoint}}' 2>/dev/null)
if [ -n "$VOLUME_PATH" ] && [ "$(stat -c '%U' "$VOLUME_PATH" 2>/dev/null)" != "$USER" ]; then
    echo "Fixing volume ownership for --userns keep-id..."
    sudo chown -R "$(id -u):$(id -g)" "$VOLUME_PATH"
fi

XAUTH=$(find /run/user/$(id -u) -name 'xauth_*' -print -quit 2>/dev/null)
PULSE_SOCK="/run/user/$(id -u)/pulse/native"
WAYLAND_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"

RUN_OPTS=(
    --name "$CONTAINER_NAME"
    --security-opt seccomp=unconfined
    --userns keep-id
    --net=host
    --device /dev/dri
    --mount type=tmpfs,destination=/tmp/runtime
    -e PULSE_SERVER=unix:/tmp/pulse/native
    -e MOZ_DISABLE_CONTENT_SANDBOX=1
    -e MOZ_DISABLE_GMP_SANDBOX=1
    -e MOZ_ENABLE_WAYLAND=1
    -e XDG_RUNTIME_DIR=/tmp/runtime
    -e WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    -v "$VOLUME:/home/waterfox":Z
    -v "${HOME}/BrowserDownloads:/home/waterfox/Downloads:z"
)

if [ -S "$WAYLAND_SOCK" ]; then
    RUN_OPTS+=(-v "$WAYLAND_SOCK:/tmp/runtime/${WAYLAND_DISPLAY:-wayland-0}:ro")
fi

if [ -e /tmp/.X11-unix ]; then
    RUN_OPTS+=(
        -v /tmp/.X11-unix:/tmp/.X11-unix:ro
        -e DISPLAY="${DISPLAY:-:0}"
    )
fi

if [ -n "$XAUTH" ] && [ -n "${DISPLAY:-}" ]; then
    RUN_OPTS+=(
        -v "$XAUTH:/tmp/.Xauthority:ro"
        -e XAUTHORITY=/tmp/.Xauthority
    )
fi

if [ -S "$PULSE_SOCK" ]; then
    RUN_OPTS+=(-v "$PULSE_SOCK:/tmp/pulse/native:z")
fi

for dev in /dev/hidraw*; do
    [ -e "$dev" ] && RUN_OPTS+=(--device "$dev")
done

for dev in /dev/bus/usb/*/*; do
    [ -e "$dev" ] && RUN_OPTS+=(--device "$dev")
done

if [ -S /run/pcscd/pcscd.comm ]; then
    RUN_OPTS+=(
        -v /run/pcscd/pcscd.comm:/run/pcscd/pcscd.comm:z
        -e PCSCLITE_CSOCK_NAME=/run/pcscd/pcscd.comm
    )
fi

podman rm -f "$CONTAINER_NAME" 2>/dev/null
podman run --rm "${RUN_OPTS[@]}" "$IMAGE"
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

# --- 5b. Udev rules for FIDO2/U2F security keys ---
echo ">>> Installing udev rules for FIDO2 security keys..."
sudo tee /etc/udev/rules.d/70-u2f-titan.rules > /dev/null << 'UDEV'
# Google Titan Security Key v2 - USB device node
SUBSYSTEM=="usb", ATTRS{idVendor}=="18d1", ATTRS{idProduct}=="9470", MODE="0666", TAG+="uaccess"
# Google Titan Security Key v2 - hidraw
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="18d1", ATTRS{idProduct}=="9470", MODE="0666", TAG+="uaccess"
# Generic FIDO2/U2F - make all security token hidraw devices accessible
SUBSYSTEM=="hidraw", ENV{ID_SECURITY_TOKEN}=="1", MODE="0666", TAG+="uaccess"
UDEV
sudo udevadm control --reload-rules 2>/dev/null
sudo udevadm trigger 2>/dev/null

# --- 5c. PC/SC smart card daemon for CTAP2/WebAuthn ---
echo ">>> Enabling pcscd for smart card / FIDO2 access..."
sudo pacman -S --needed --noconfirm ccid pcsclite 2>/dev/null
sudo systemctl enable --now pcscd.socket

# --- 6. Samba File Server ---
echo ">>> Setting up Samba file server..."

# Stop and remove existing container cleanly
podman stop samba-server 2>/dev/null || true
podman rm samba-server 2>/dev/null || true

# Prompt for Samba password — max 3 attempts
# If stdin is not a terminal (e.g. piped over SSH), generate a random password
MAX_ATTEMPTS=3
ATTEMPT=1
if [ -t 0 ]; then
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
else
    SAMBA_PASS=$(openssl rand -base64 18)
    echo ""
    echo "Non-interactive mode: generated random Samba password."
    echo "Samba user: ${USER}  password: ${SAMBA_PASS}"
    echo "Save this password — it will not be shown again."
fi

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
    docker.io/servercontainers/samba:latest

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
if [ -t 0 ]; then
    read -r -p "Path to WireGuard config file (leave blank to skip): " WG_CONFIG_PATH
else
    WG_CONFIG_PATH=""
    echo "Non-interactive mode: skipping VPN setup."
fi

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
if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: Do not run this as root/sudo. Rootless podman stores images in your user account." >&2
    exit 1
fi

if ! systemctl --user is-active podman.socket &>/dev/null; then
    systemctl --user start podman.socket 2>/dev/null || true
fi

if ! podman inspect --format '{{.State.Status}}' gluetun 2>/dev/null | grep -q '^running$'; then
    echo "Error: gluetun container is not running."
    echo "Start it with: systemctl --user start container-gluetun.service"
    exit 1
fi
WAYLAND_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"
RUN_OPTS=(
    --name "waterfox-secure-$$"
    --network=container:gluetun
    --security-opt no-new-privileges
    -e PULSE_SERVER=unix:/tmp/pulse/native
    -e MOZ_DISABLE_CONTENT_SANDBOX=1
    -e MOZ_ENABLE_WAYLAND=1
    -e XDG_RUNTIME_DIR=/tmp/runtime
    -e WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    -v "${WAYLAND_SOCK}:/tmp/runtime/${WAYLAND_DISPLAY:-wayland-0}:ro"
    -v "${HOME}/SecureDownloads:/home/waterfox/Downloads:Z"
)
if [ -e /tmp/.X11-unix ]; then
    RUN_OPTS+=(
        -v /tmp/.X11-unix:/tmp/.X11-unix:ro
        -e DISPLAY="${DISPLAY:-:0}"
    )
fi
exec podman run --rm "${RUN_OPTS[@]}" localhost/waterfox-base
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

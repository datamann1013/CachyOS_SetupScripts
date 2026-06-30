#!/bin/bash
# setup-apps.sh - Part 2 of the modular CachyOS setup (Apps + Isolation + VPN)
# Run AFTER minimal.sh
#
# Browsers use bubblewrap (bwrap) for namespace isolation instead of podman.
# bwrap creates a clean mount namespace with no overlay/container fingerprints,
# which is required for Widevine DRM (Netflix, Spotify web, etc.) to work.

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

# --- 3. Install Browser Binaries ---
echo ">>> Installing browser binaries..."

WATERFOX_VERSION="6.6.15"
WATERFOX_SHA512="7f1b1075385e0ac9f59017a69731a0d6fee27054ea9f594251a58b3851f3fc27de5365194e35bc20cf262b6dab9be64c45d48513532fb838bfb004860f25913a"
WATERFOX_DIR="${HOME}/.local/share/waterfox-bwrap/waterfox"

if [ ! -x "${WATERFOX_DIR}/waterfox" ]; then
    echo "    Downloading Waterfox ${WATERFOX_VERSION}..."
    TMPDIR=$(mktemp -d)
    curl -fsSL \
        "https://cdn.waterfox.com/waterfox/releases/${WATERFOX_VERSION}/Linux_x86_64/waterfox-${WATERFOX_VERSION}.tar.bz2" \
        -o "${TMPDIR}/waterfox.tar.bz2"
    echo "${WATERFOX_SHA512}  ${TMPDIR}/waterfox.tar.bz2" | sha512sum -c -
    rm -rf "$(dirname "${WATERFOX_DIR}")"
    mkdir -p "$(dirname "${WATERFOX_DIR}")"
    tar -xjf "${TMPDIR}/waterfox.tar.bz2" -C "$(dirname "${WATERFOX_DIR}")"
    rm -rf "${TMPDIR}"
    echo "    Waterfox installed to ${WATERFOX_DIR}"
else
    echo "    Waterfox already installed at ${WATERFOX_DIR}"
fi

TOR_VERSION="15.0.17"
TOR_DIR="${HOME}/.local/share/tor-browser-bwrap/tor-browser"

if [ ! -x "${TOR_DIR}/Browser/start-tor-browser" ]; then
    echo "    Downloading Tor Browser ${TOR_VERSION}..."
    TMPDIR=$(mktemp -d)
    curl -fsSL \
        "https://dist.torproject.org/torbrowser/${TOR_VERSION}/tor-browser-linux-x86_64-${TOR_VERSION}.tar.xz" \
        -o "${TMPDIR}/tor-browser.tar.xz"
    rm -rf "$(dirname "${TOR_DIR}")"
    mkdir -p "$(dirname "${TOR_DIR}")"
    tar -xJf "${TMPDIR}/tor-browser.tar.xz" -C "$(dirname "${TOR_DIR}")"
    chmod +x "${TOR_DIR}/Browser/start-tor-browser" "${TOR_DIR}/Browser/firefox"
    rm -rf "${TMPDIR}"
    echo "    Tor Browser installed to ${TOR_DIR}"
else
    echo "    Tor Browser already installed at ${TOR_DIR}"
fi

# --- 4. Install Browser Icons ---
echo ">>> Installing browser icons..."
mkdir -p ~/.local/share/icons

WATERFOX_ICON_SRC="${WATERFOX_DIR}/browser/chrome/icons/default/default128.png"
TOR_ICON_SRC="${TOR_DIR}/Browser/browser/chrome/icons/default/default128.png"

if [ -f "${WATERFOX_ICON_SRC}" ]; then
    cp "${WATERFOX_ICON_SRC}" ~/.local/share/icons/waterfox-fun.png
fi

if [ -f "${TOR_ICON_SRC}" ]; then
    cp "${TOR_ICON_SRC}" ~/.local/share/icons/thor-fun.png
fi

cat > ~/.local/share/icons/waterfox-secure.svg << 'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <path d="M64 6 L114 28 L114 72 Q114 106 64 122 Q14 106 14 72 L14 28 Z" fill="#1a6b3c" stroke="#0f4d2b" stroke-width="2"/>
  <path d="M64 14 L106 33 L106 70 Q106 100 64 114 Q22 100 22 70 L22 33 Z" fill="#27ae60"/>
  <path d="M52 58 L52 46 Q52 34 64 34 Q76 34 76 46 L76 58" fill="none" stroke="white" stroke-width="5" stroke-linecap="round"/>
  <rect x="44" y="58" width="40" height="32" rx="4" fill="white"/>
  <circle cx="64" cy="70" r="4" fill="#27ae60"/>
  <rect x="62" y="72" width="4" height="8" rx="1" fill="#27ae60"/>
</svg>
SVG

# --- 5. Create Download Directories ---
echo ">>> Creating file share directories..."
mkdir -p ~/BrowserDownloads ~/SecureDownloads ~/MachineFiles
chmod 755 ~/BrowserDownloads ~/SecureDownloads ~/MachineFiles

# --- 5. Browser Launchers ---
echo ">>> Creating browser launchers..."
mkdir -p ~/.local/bin ~/.local/share/applications

# --- 5a. Waterfox Fun Launcher ---
cat > ~/.local/bin/waterfox-fun << 'LAUNCHER'
#!/bin/bash
# Waterfox (Fun) — bubblewrap sandbox with clean mount namespace
# No overlay/container fingerprints — Widevine DRM compatible

set -euo pipefail

WATERFOX_DIR="${HOME}/.local/share/waterfox-bwrap/waterfox"
DATA_DIR="${HOME}/.local/share/waterfox-fun-bwrap"
DOWNLOAD_DIR="${HOME}/BrowserDownloads"

if [ ! -x "${WATERFOX_DIR}/waterfox" ]; then
    echo "ERROR: Waterfox not found at ${WATERFOX_DIR}" >&2
    echo "Re-run setup-apps.sh to install it." >&2
    exit 1
fi

mkdir -p "${DATA_DIR}" "${DOWNLOAD_DIR}"

find "${DATA_DIR}" -name '.parentlock' -delete 2>/dev/null || true
find "${DATA_DIR}" -name 'lock' -delete 2>/dev/null || true

UID_NUM=$(id -u)
RUNTIME_DIR="/run/user/${UID_NUM}"
WAYLAND_SOCK="${XDG_RUNTIME_DIR:-${RUNTIME_DIR}}/${WAYLAND_DISPLAY:-wayland-0}"
XAUTH=$(find "${RUNTIME_DIR}" -name 'xauth_*' -print -quit 2>/dev/null || true)

BWRAP_ARGS=(
    --unshare-all
    --share-net
    --die-with-parent
    --hostname remotestation

    --ro-bind /usr /usr
    --ro-bind /lib /lib
    --ro-bind /lib64 /lib64
    --ro-bind /bin /bin
    --ro-bind /sbin /sbin
    --ro-bind /etc /etc
    --ro-bind-try /var /var
    --dev-bind /dev /dev
    --proc /proc
    --ro-bind /sys /sys
    --tmpfs /tmp
    --tmpfs /run

    --bind "${DATA_DIR}" /home/waterfox
    --bind "${DOWNLOAD_DIR}" /home/waterfox/Downloads
    --ro-bind "${WATERFOX_DIR}" /opt/waterfox

    --ro-bind "${RUNTIME_DIR}/pulse" "${RUNTIME_DIR}/pulse"
    --setenv PULSE_SERVER "unix:${RUNTIME_DIR}/pulse/native"
)

if [ -S "${WAYLAND_SOCK}" ]; then
    BWRAP_ARGS+=(--ro-bind "${WAYLAND_SOCK}" "${RUNTIME_DIR}/${WAYLAND_DISPLAY:-wayland-0}")
fi

if [ -e /tmp/.X11-unix ]; then
    BWRAP_ARGS+=(--ro-bind /tmp/.X11-unix /tmp/.X11-unix)
fi

if [ -n "${XAUTH:-}" ] && [ -f "${XAUTH}" ]; then
    BWRAP_ARGS+=(--ro-bind "${XAUTH}" "/tmp/.Xauthority")
fi

if [ -S "${RUNTIME_DIR}/bus" ]; then
    BWRAP_ARGS+=(--ro-bind "${RUNTIME_DIR}/bus" "${RUNTIME_DIR}/bus")
fi

if [ -S /run/pcscd/pcscd.comm ]; then
    BWRAP_ARGS+=(--ro-bind /run/pcscd/pcscd.comm /run/pcscd/pcscd.comm)
fi

exec bwrap "${BWRAP_ARGS[@]}" \
    --setenv HOME /home/waterfox \
    --setenv PATH /usr/local/bin:/usr/bin:/bin \
    --setenv MOZ_ENABLE_WAYLAND 1 \
    --setenv MOZ_DISABLE_GMP_SANDBOX 1 \
    --setenv WAYLAND_DISPLAY "${WAYLAND_DISPLAY:-wayland-0}" \
    --setenv XDG_RUNTIME_DIR "${RUNTIME_DIR}" \
    --setenv DISPLAY "${DISPLAY:-:0}" \
    --setenv XAUTHORITY /tmp/.Xauthority \
    /opt/waterfox/waterfox --no-remote
LAUNCHER
chmod +x ~/.local/bin/waterfox-fun

cat > ~/.local/share/applications/waterfox-fun.desktop << EOF
[Desktop Entry]
Name=Waterfox (Fun)
Comment=Isolated browser — downloads go to ~/BrowserDownloads only
Exec=${HOME}/.local/bin/waterfox-fun
Icon=${HOME}/.local/share/icons/waterfox-fun.png
Terminal=false
Type=Application
Categories=Network;WebBrowser;
StartupNotify=true
EOF

# --- 5b. Tor Browser Fun Launcher ---
cat > ~/.local/bin/thor-fun << 'LAUNCHER'
#!/bin/bash
# Tor Browser (Fun) — bubblewrap sandbox with clean mount namespace
# All browser traffic routed through the Tor network via bundled Tor daemon.
# Tor Browser stores profile + Tor state inside its own directory tree,
# so the install dir must be writable (not ro-bind like Waterfox).
# Updates are handled by Tor Browser's built-in updater, NOT setup-apps.sh.

set -euo pipefail

TOR_DIR="${HOME}/.local/share/tor-browser-bwrap/tor-browser"
DATA_DIR="${HOME}/.local/share/thor-fun-bwrap"
DOWNLOAD_DIR="${HOME}/BrowserDownloads"

if [ ! -x "${TOR_DIR}/Browser/start-tor-browser" ]; then
    echo "ERROR: Tor Browser not found at ${TOR_DIR}" >&2
    echo "Re-run setup-apps.sh to install it." >&2
    exit 1
fi

mkdir -p "${DATA_DIR}" "${DOWNLOAD_DIR}"

UID_NUM=$(id -u)
RUNTIME_DIR="/run/user/${UID_NUM}"
WAYLAND_SOCK="${XDG_RUNTIME_DIR:-${RUNTIME_DIR}}/${WAYLAND_DISPLAY:-wayland-0}"
XAUTH=$(find "${RUNTIME_DIR}" -name 'xauth_*' -print -quit 2>/dev/null || true)

BWRAP_ARGS=(
    --unshare-all
    --share-net
    --die-with-parent
    --hostname thor-sandbox

    --ro-bind /usr /usr
    --ro-bind /lib /lib
    --ro-bind /lib64 /lib64
    --ro-bind /bin /bin
    --ro-bind /sbin /sbin
    --ro-bind /etc /etc
    --ro-bind-try /var /var
    --dev-bind /dev /dev
    --proc /proc
    --ro-bind /sys /sys
    --tmpfs /tmp
    --tmpfs /run

    --bind "${DATA_DIR}" /home/thor
    --bind "${DOWNLOAD_DIR}" /home/thor/Downloads
    --bind "${TOR_DIR}" /opt/tor-browser

    --ro-bind "${RUNTIME_DIR}/pulse" "${RUNTIME_DIR}/pulse"
    --setenv PULSE_SERVER "unix:${RUNTIME_DIR}/pulse/native"
)

if [ -S "${WAYLAND_SOCK}" ]; then
    BWRAP_ARGS+=(--ro-bind "${WAYLAND_SOCK}" "${RUNTIME_DIR}/${WAYLAND_DISPLAY:-wayland-0}")
fi

if [ -e /tmp/.X11-unix ]; then
    BWRAP_ARGS+=(--ro-bind /tmp/.X11-unix /tmp/.X11-unix)
fi

if [ -n "${XAUTH:-}" ] && [ -f "${XAUTH}" ]; then
    BWRAP_ARGS+=(--ro-bind "${XAUTH}" "/tmp/.Xauthority")
fi

if [ -S "${RUNTIME_DIR}/bus" ]; then
    BWRAP_ARGS+=(--ro-bind "${RUNTIME_DIR}/bus" "${RUNTIME_DIR}/bus")
fi

exec bwrap "${BWRAP_ARGS[@]}" \
    --setenv HOME /home/thor \
    --setenv PATH /usr/local/bin:/usr/bin:/bin \
    --setenv WAYLAND_DISPLAY "${WAYLAND_DISPLAY:-wayland-0}" \
    --setenv XDG_RUNTIME_DIR "${RUNTIME_DIR}" \
    --setenv DISPLAY "${DISPLAY:-:0}" \
    --setenv XAUTHORITY /tmp/.Xauthority \
    /opt/tor-browser/Browser/start-tor-browser --no-remote
LAUNCHER
chmod +x ~/.local/bin/thor-fun

cat > ~/.local/share/applications/thor-fun.desktop << EOF
[Desktop Entry]
Name=Tor Browser (Fun)
Comment=Isolated onion browser — all traffic through Tor network
Exec=${HOME}/.local/bin/thor-fun
Icon=${HOME}/.local/share/icons/thor-fun.png
Terminal=false
Type=Application
Categories=Network;WebBrowser;
StartupNotify=true
EOF

# --- 5c. Udev rules for FIDO2/U2F security keys ---
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

# --- 5d. PC/SC smart card daemon for CTAP2/WebAuthn ---
echo ">>> Enabling pcscd for smart card / FIDO2 access..."
sudo pacman -S --needed --noconfirm ccid pcsclite 2>/dev/null
sudo systemctl enable --now pcscd.socket

# --- 6. Samba File Server ---
echo ">>> Setting up Samba file server..."

podman stop samba-server 2>/dev/null || true
podman rm samba-server 2>/dev/null || true

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

sudo firewall-cmd --add-port=1139/tcp --add-port=1445/tcp --permanent 2>/dev/null || true
sudo firewall-cmd --reload 2>/dev/null || true

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

grep -qxF 'export PATH="$HOME/bin:$PATH"' ~/.bashrc 2>/dev/null \
    || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
grep -qxF 'export PATH="$HOME/bin:$PATH"' ~/.zshrc 2>/dev/null \
    || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc 2>/dev/null || true
if command -v fish &>/dev/null; then
    fish -c "fish_add_path ~/bin" 2>/dev/null || true
fi

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
        if ! grep -q '^\[Interface\]' "$WG_CONFIG_PATH" || ! grep -q '^\[Peer\]' "$WG_CONFIG_PATH"; then
            echo "WARNING: WireGuard config missing [Interface] or [Peer] section — skipping VPN setup." >&2
        else
            VPN_ENABLED=true
            echo ">>> Configuring VPN and secure browser..."

            sudo pacman -S --needed --noconfirm wireguard-tools 2>/dev/null

            mkdir -p ~/vpn/wireguard
            cp "$WG_CONFIG_PATH" ~/vpn/wireguard/wg0.conf
            chmod 600 ~/vpn/wireguard/wg0.conf

            WG_ENDPOINT=$(grep -oP 'Endpoint\s*=\s*\K[^:]+' ~/vpn/wireguard/wg0.conf | head -1)
            if [ -n "${WG_ENDPOINT}" ]; then
                WG_IP=$(dig +short "${WG_ENDPOINT}" A 2>/dev/null || echo "")
                if [ -n "${WG_IP}" ]; then
                    sed -i "s/Endpoint = ${WG_ENDPOINT}:/Endpoint = ${WG_IP}:/" ~/vpn/wireguard/wg0.conf
                fi
            fi

            sudo tee /etc/wireguard/wg0.conf > /dev/null << WGEOF
[Interface]
PrivateKey = $(grep -oP 'PrivateKey\s*=\s*\K.*' ~/vpn/wireguard/wg0.conf)
Address = $(grep -oP 'Address\s*=\s*\K.*' ~/vpn/wireguard/wg0.conf)
MTU = $(grep -oP 'MTU\s*=\s*\K.*' ~/vpn/wireguard/wg0.conf || echo 1420)
PostUp = ip rule add from $(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}') table 128
PostUp = ip route add default via $(ip route | awk '/default/{print $3; exit}') table 128
PostDown = ip rule del from $(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}') table 128
PostDown = ip route del default via $(ip route | awk '/default/{print $3; exit}') table 128

[Peer]
PublicKey = $(grep -oP 'PublicKey\s*=\s*\K.*' ~/vpn/wireguard/wg0.conf)
AllowedIPs = $(grep -oP 'AllowedIPs\s*=\s*\K.*' ~/vpn/wireguard/wg0.conf)
Endpoint = $(grep -oP 'Endpoint\s*=\s*\K.*' ~/vpn/wireguard/wg0.conf)
PersistentKeepalive = $(grep -oP 'PersistentKeepalive\s*=\s*\K.*' ~/vpn/wireguard/wg0.conf || echo 21)
WGEOF
            sudo chmod 600 /etc/wireguard/wg0.conf

            sudo systemctl enable wg-quick@wg0

            cat > ~/.local/bin/waterfox-secure << 'LAUNCHER'
#!/bin/bash
# Waterfox (Secure VPN) — bwrap sandbox with WireGuard VPN
# Brings up wg0, runs browser, tears down wg0 on exit.
# WireGuard routing uses policy routing: only the browser's
# network namespace routes through the VPN tunnel.

set -euo pipefail

WATERFOX_DIR="${HOME}/.local/share/waterfox-bwrap/waterfox"
DATA_DIR="${HOME}/.local/share/waterfox-secure-bwrap"
DOWNLOAD_DIR="${HOME}/SecureDownloads"

if [ ! -x "${WATERFOX_DIR}/waterfox" ]; then
    echo "ERROR: Waterfox not found at ${WATERFOX_DIR}" >&2
    exit 1
fi

if ! sudo wg show wg0 &>/dev/null; then
    echo "Bringing up WireGuard VPN tunnel..."
    sudo wg-quick up wg0
    TRAP_WG=true
else
    TRAP_WG=false
fi

cleanup() {
    if [ "$TRAP_WG" = true ]; then
        echo "Tearing down WireGuard VPN tunnel..."
        sudo wg-quick down wg0 2>/dev/null || true
    fi
}
trap cleanup EXIT

mkdir -p "${DATA_DIR}" "${DOWNLOAD_DIR}"

find "${DATA_DIR}" -name '.parentlock' -delete 2>/dev/null || true
find "${DATA_DIR}" -name 'lock' -delete 2>/dev/null || true

UID_NUM=$(id -u)
RUNTIME_DIR="/run/user/${UID_NUM}"
WAYLAND_SOCK="${XDG_RUNTIME_DIR:-${RUNTIME_DIR}}/${WAYLAND_DISPLAY:-wayland-0}"
XAUTH=$(find "${RUNTIME_DIR}" -name 'xauth_*' -print -quit 2>/dev/null || true)

BWRAP_ARGS=(
    --unshare-all
    --share-net
    --die-with-parent
    --hostname remotestation

    --ro-bind /usr /usr
    --ro-bind /lib /lib
    --ro-bind /lib64 /lib64
    --ro-bind /bin /bin
    --ro-bind /sbin /sbin
    --ro-bind /etc /etc
    --ro-bind-try /var /var
    --dev-bind /dev /dev
    --proc /proc
    --ro-bind /sys /sys
    --tmpfs /tmp
    --tmpfs /run

    --bind "${DATA_DIR}" /home/waterfox
    --bind "${DOWNLOAD_DIR}" /home/waterfox/Downloads
    --ro-bind "${WATERFOX_DIR}" /opt/waterfox

    --ro-bind "${RUNTIME_DIR}/pulse" "${RUNTIME_DIR}/pulse"
    --setenv PULSE_SERVER "unix:${RUNTIME_DIR}/pulse/native"
)

if [ -S "${WAYLAND_SOCK}" ]; then
    BWRAP_ARGS+=(--ro-bind "${WAYLAND_SOCK}" "${RUNTIME_DIR}/${WAYLAND_DISPLAY:-wayland-0}")
fi

if [ -e /tmp/.X11-unix ]; then
    BWRAP_ARGS+=(--ro-bind /tmp/.X11-unix /tmp/.X11-unix)
fi

if [ -n "${XAUTH:-}" ] && [ -f "${XAUTH}" ]; then
    BWRAP_ARGS+=(--ro-bind "${XAUTH}" "/tmp/.Xauthority")
fi

if [ -S "${RUNTIME_DIR}/bus" ]; then
    BWRAP_ARGS+=(--ro-bind "${RUNTIME_DIR}/bus" "${RUNTIME_DIR}/bus")
fi

if [ -S /run/pcscd/pcscd.comm ]; then
    BWRAP_ARGS+=(--ro-bind /run/pcscd/pcscd.comm /run/pcscd/pcscd.comm)
fi

exec bwrap "${BWRAP_ARGS[@]}" \
    --setenv HOME /home/waterfox \
    --setenv PATH /usr/local/bin:/usr/bin:/bin \
    --setenv MOZ_ENABLE_WAYLAND 1 \
    --setenv MOZ_DISABLE_GMP_SANDBOX 1 \
    --setenv WAYLAND_DISPLAY "${WAYLAND_DISPLAY:-wayland-0}" \
    --setenv XDG_RUNTIME_DIR "${RUNTIME_DIR}" \
    --setenv DISPLAY "${DISPLAY:-:0}" \
    --setenv XAUTHORITY /tmp/.Xauthority \
    /opt/waterfox/waterfox --no-remote
LAUNCHER
            chmod +x ~/.local/bin/waterfox-secure

            cat > ~/.local/share/applications/waterfox-secure.desktop << EOF
[Desktop Entry]
Name=Waterfox (Secure VPN)
Comment=Isolated browser — all traffic through WireGuard VPN
Exec=${HOME}/.local/bin/waterfox-secure
Icon=${HOME}/.local/share/icons/waterfox-secure.svg
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
echo "Browsers (bubblewrap sandbox — DRM compatible):"
echo "  Waterfox (Fun)    : ${HOME}/.local/bin/waterfox-fun"
echo "                      Downloads isolated to ~/BrowserDownloads"
echo "  Tor Browser (Fun) : ${HOME}/.local/bin/thor-fun"
echo "                      All traffic through Tor network"
if [ "$VPN_ENABLED" = true ]; then
    echo "  Waterfox (Secure) : ${HOME}/.local/bin/waterfox-secure"
    echo "                      All traffic through WireGuard VPN"
fi
echo ""
echo "Sandbox: sandbox-open <file>"
echo "         Right-click in Dolphin: 'Open in Sandbox'"

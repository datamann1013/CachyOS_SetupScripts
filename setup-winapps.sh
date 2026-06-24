#!/bin/bash
# setup-winapps.sh - Windows app streaming via WinApps (FreeRDP + Windows VM)
# Run AFTER minimal.sh
#
# This sets up WinApps which runs a Windows VM and surfaces individual
# Windows applications (Access, Visio, etc.) as native-looking Linux windows
# using FreeRDP's RemoteApp protocol.
#
# Prerequisites:
#   - A Windows VM configured with RDP enabled (see WinApps docs)
#   - Windows username and password for RDP

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=""
for arg in "$@"; do
    [ "$arg" = "--dry-run" ] && DRY_RUN=1
done

run() {
    if [ -n "$DRY_RUN" ]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

echo "========================================="
echo " Starting WinApps Profile Setup${DRY_RUN:+ (DRY RUN)}"
echo "========================================="

# --- 1. Install Dependencies ---
echo ">>> Installing WinApps dependencies..."
run sudo pacman -S --needed --noconfirm \
    freerdp \
    curl \
    dialog \
    iproute2 \
    libnotify \
    openbsd-netcat \
    git

# Verify FreeRDP version (needs v3+)
if [ -z "$DRY_RUN" ]; then
    FREERDP_VER=$(xfreerdp3 --version 2>/dev/null | head -1 || xfreerdp --version 2>/dev/null | head -1 || echo "unknown")
    echo "FreeRDP version: ${FREERDP_VER}"
fi

# --- 2. Clone WinApps ---
echo ">>> Cloning WinApps..."
WINAPPS_DIR="${HOME}/.local/share/winapps"
if [ -d "${WINAPPS_DIR}/.git" ]; then
    echo "WinApps already cloned at ${WINAPPS_DIR}, pulling updates..."
    run git -C "${WINAPPS_DIR}" pull
else
    run git clone https://github.com/winapps-org/winapps.git "${WINAPPS_DIR}"
fi

# --- 3. Create WinApps Configuration ---
echo ">>> Creating WinApps configuration..."
mkdir -p ~/.config/winapps

if [ ! -f ~/.config/winapps/winapps.conf ]; then
    echo ""
    echo "WinApps requires a Windows VM with RDP enabled."
    echo "See: https://github.com/winapps-org/winapps/blob/main/docs/docker.md"
    echo ""
    read -r -p "Windows RDP username: " RDP_USER
    read -s -r -p "Windows RDP password: " RDP_PASS
    echo ""

    cat > ~/.config/winapps/winapps.conf << CONF
RDP_USER="${RDP_USER}"
RDP_PASS="${RDP_PASS}"
RDP_IP="127.0.0.1"
RDP_PORT="3389"
WAFLAVOR="podman"
RDP_SCALE="100"
RDP_FLAGS="/cert:tofu /sound /microphone +home-drive"
DEBUG="true"
AUTOPAUSE="off"
CONF
    chmod 600 ~/.config/winapps/winapps.conf
    unset RDP_PASS
    echo "Configuration written to ~/.config/winapps/winapps.conf"
else
    echo "WinApps configuration already exists at ~/.config/winapps/winapps.conf"
fi

# --- 4. Run WinApps Installer ---
echo ">>> Running WinApps installer..."
echo "Make sure your Windows VM is running before proceeding."
echo ""
if [ -z "$DRY_RUN" ]; then
    read -r -p "Is your Windows VM running and RDP-accessible? (y/N): " VM_READY
    if [ "${VM_READY,,}" = "y" ] || [ "${VM_READY,,}" = "yes" ]; then
        cd "${WINAPPS_DIR}"
        bash setup.sh --user
    else
        echo ""
        echo "Skipping WinApps installer. Run it later with:"
        echo "  cd ${WINAPPS_DIR} && bash setup.sh --user"
    fi
fi

# --- Final Summary ---
echo ""
echo "========================================="
echo " WinApps Profile Setup Complete!"
echo "========================================="
echo ""
echo "WinApps installed to: ${WINAPPS_DIR}"
echo "Configuration: ~/.config/winapps/winapps.conf"
echo ""
echo "Usage:"
echo "  Launch Windows apps from KDE application menu"
echo "  Or run: winapps <app-name>"
echo "  Full Windows desktop: winapps windows"
echo "  Re-detect apps: winapps-setup --user --add-apps"
echo ""
echo "Docs: https://github.com/winapps-org/winapps"

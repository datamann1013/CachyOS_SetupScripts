#!/bin/bash
# setup-winapps.sh - Windows app streaming via WinApps (FreeRDP + Windows VM)
# Run AFTER minimal.sh
#
# Creates a Windows VM using dockur/windows + Podman/KVM,
# then installs WinApps to surface individual Windows apps
# (Access, Visio, etc.) as native Linux windows via FreeRDP.

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

ensure_podman() {
    sudo loginctl enable-linger "$USER" 2>/dev/null || true
    if ! systemctl --user is-active podman.socket &>/dev/null; then
        echo "Starting podman user socket..."
        systemctl --user start podman.socket 2>/dev/null || true
    fi
}

ensure_podman

# --- 1. Install Dependencies ---
echo ">>> Installing WinApps dependencies..."
run sudo pacman -S --needed --noconfirm \
    freerdp \
    podman-compose \
    curl \
    dialog \
    iproute2 \
    libnotify \
    openbsd-netcat \
    git

if [ -z "$DRY_RUN" ]; then
    FREERDP_VER=$(xfreerdp3 --version 2>/dev/null | head -1 || xfreerdp --version 2>/dev/null | head -1 || echo "unknown")
    echo "FreeRDP version: ${FREERDP_VER}"
    echo "podman-compose version: $(podman-compose --version 2>/dev/null || echo 'not found')"
fi

# --- 2. Add user to kvm group for /dev/kvm access ---
echo ">>> Ensuring user has KVM access..."
if ! groups | grep -q '\bkvm\b'; then
    run sudo usermod -aG kvm "$USER"
    echo "Added $USER to kvm group. You may need to log out/in for this to take effect."
else
    echo "User already in kvm group."
fi

# --- 3. Load iptables modules for folder sharing ---
echo ">>> Loading iptables kernel modules..."
if [ -z "$DRY_RUN" ]; then
    if ! lsmod | grep -q ip_tables; then
        echo "ip_tables" | sudo tee /etc/modules-load.d/iptables.conf > /dev/null
        echo "iptable_nat" | sudo tee -a /etc/modules-load.d/iptables.conf > /dev/null
        sudo modprobe ip_tables 2>/dev/null || true
        sudo modprobe iptable_nat 2>/dev/null || true
    fi
fi

# --- 4. Clone WinApps ---
echo ">>> Cloning WinApps..."
WINAPPS_DIR="${HOME}/.local/share/winapps"
if [ -d "${WINAPPS_DIR}/.git" ]; then
    echo "WinApps already cloned at ${WINAPPS_DIR}, pulling updates..."
    run git -C "${WINAPPS_DIR}" pull
else
    run git clone https://github.com/winapps-org/winapps.git "${WINAPPS_DIR}"
fi

# --- 5. Prompt for Windows credentials ---
echo ">>> Configuring Windows VM credentials..."
mkdir -p ~/.config/winapps

WIN_USER="${USER}"

if [ -t 0 ]; then
    echo ""
    echo "Windows VM will be created with the following credentials."
    echo "These are used for RDP access from WinApps."
    echo ""
    read -r -p "Windows username [${WIN_USER}]: " INPUT_USER
    WIN_USER="${INPUT_USER:-$WIN_USER}"

    WIN_PASS=""
    WIN_PASS_CONFIRM=""
    MAX_ATTEMPTS=3
    ATTEMPT=1
    while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
        read -s -r -p "Windows password: " WIN_PASS
        echo ""
        read -s -r -p "Confirm password: " WIN_PASS_CONFIRM
        echo ""
        if [ "$WIN_PASS" = "$WIN_PASS_CONFIRM" ]; then
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
    unset WIN_PASS_CONFIRM
else
    WIN_PASS=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)
    echo ""
    echo "Non-interactive mode: generated Windows VM password."
    echo "Windows user: ${WIN_USER}  password: ${WIN_PASS}"
    echo "Save this password — it will not be shown again."
fi

# --- 6. Create WinApps configuration ---
echo ">>> Writing WinApps configuration..."
cat > ~/.config/winapps/winapps.conf << CONF
RDP_USER="${WIN_USER}"
RDP_PASS="${WIN_PASS}"
RDP_IP="127.0.0.1"
RDP_PORT="3389"
WAFLAVOR="podman"
RDP_SCALE="100"
RDP_FLAGS="/cert:tofu /sound /microphone +home-drive"
DEBUG="true"
AUTOPAUSE="on"
CONF
chmod 600 ~/.config/winapps/winapps.conf

# --- 7. Create compose.yaml for Windows VM ---
echo ">>> Creating Windows VM configuration..."
cp "${WINAPPS_DIR}/compose.yaml" ~/.config/winapps/compose.yaml

if [ -z "$DRY_RUN" ]; then
    sed -i \
        -e "s|VERSION: \".*\"|VERSION: \"tiny11\"|" \
        -e "s|RAM_SIZE: \".*\"|RAM_SIZE: \"4G\"|" \
        -e "s|CPU_CORES: \".*\"|CPU_CORES: \"4\"|" \
        -e "s|DISK_SIZE: \".*\"|DISK_SIZE: \"64G\"|" \
        -e "s|USERNAME: \".*\"|USERNAME: \"${WIN_USER}\"|" \
        -e "s|PASSWORD: \".*\"|PASSWORD: \"${WIN_PASS}\"|" \
        ~/.config/winapps/compose.yaml

    sed -i '/PASSWORD:/a\      SHUTDOWN: "yes"' ~/.config/winapps/compose.yaml

    if command -v fish &>/dev/null; then
        sed -i '/group_add:/,/#   - keep-groups/s/^#//' ~/.config/winapps/compose.yaml
    fi

    echo "compose.yaml written to ~/.config/winapps/compose.yaml"
fi
unset WIN_PASS

# --- 8. Copy OEM registry tweaks ---
echo ">>> Copying OEM registry tweaks for RemoteApp..."
if [ -d "${WINAPPS_DIR}/oem" ]; then
    cp -r "${WINAPPS_DIR}/oem" ~/.config/winapps/oem
    echo "OEM tweaks copied."
else
    echo "WARNING: No oem/ directory found in ${WINAPPS_DIR}. RemoteApp registry tweaks will not be applied."
fi

# --- 9. Start the Windows VM ---
echo ""
echo "========================================="
echo " Windows VM Installation"
echo "========================================="
echo ""
echo "The Windows VM will now be created and installed."
echo "This is an AUTOMATED process powered by dockur/windows."
echo "Tiny11 will be downloaded and installed (~5-15 minutes)."
echo ""
echo "You can monitor the installation via VNC:"
echo "  http://127.0.0.1:8006"
echo ""
echo "Once Windows is fully installed and at the desktop,"
echo "run the WinApps installer (next step) to detect apps."
echo ""

if [ -z "$DRY_RUN" ]; then
    START_VM="y"
    if [ -t 0 ]; then
        read -r -p "Start the Windows VM now? (Y/n): " START_VM
    else
        echo "Non-interactive mode: starting Windows VM automatically."
    fi
    if [ "${START_VM,,}" != "n" ] && [ "${START_VM,,}" != "no" ]; then
        cd ~/.config/winapps
        podman-compose --file ./compose.yaml up -d
        echo ""
        echo "Windows VM is starting in the background."
        echo "Monitor at: http://127.0.0.1:8006"
        echo "Wait for Windows to reach the desktop before proceeding."
    fi
fi

# --- 10. Run WinApps Installer ---
echo ""
echo ">>> WinApps Installer"
echo ""
echo "The WinApps installer will scan the Windows VM for installed"
echo "applications and create .desktop shortcuts on this machine."
echo "Make sure Windows is fully booted and at the desktop first."
echo ""

if [ -z "$DRY_RUN" ]; then
    VM_READY="n"
    if [ -t 0 ]; then
        read -r -p "Is Windows running and at the desktop? (y/N): " VM_READY
    else
        echo "Non-interactive mode: skipping WinApps app detection."
        echo "Run it later after Windows VM is ready:"
        echo "  cd ${WINAPPS_DIR} && bash setup.sh --user"
    fi
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
echo "VM config: ~/.config/winapps/compose.yaml"
echo ""
echo "Windows VM management:"
echo "  Start:   podman-compose --file ~/.config/winapps/compose.yaml start"
echo "  Stop:    podman-compose --file ~/.config/winapps/compose.yaml stop"
echo "  Status:  podman-compose --file ~/.config/winapps/compose.yaml ps"
echo "  VNC:     http://127.0.0.1:8006"
echo ""
echo "WinApps usage:"
echo "  Launch Windows apps from KDE application menu"
echo "  Or run: winapps <app-name>"
echo "  Full Windows desktop: winapps windows"
echo "  Re-detect apps: winapps-setup --user --add-apps"
echo ""
echo "Docs: https://github.com/winapps-org/winapps"

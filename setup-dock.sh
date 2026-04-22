#!/bin/bash
# setup-dock.sh - Wireless dock profile (InputLeap KVM + Moonlight streaming)
# Run AFTER minimal.sh

set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
    [ "$arg" = "--dry-run" ] && DRY_RUN=true
done

run() {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

echo "========================================="
echo " Starting Dock Profile Setup${DRY_RUN:+ (DRY RUN)}"
echo "========================================="

# --- 1. Install Packages ---
echo ">>> Installing InputLeap and Moonlight..."
run sudo pacman -S --needed --noconfirm moonlight-qt

# InputLeap is in AUR — use yay/paru if available, otherwise prompt user
if command -v yay &>/dev/null; then
    run yay -S --needed --noconfirm input-leap
elif command -v paru &>/dev/null; then
    run paru -S --needed --noconfirm input-leap
else
    echo ""
    echo "WARNING: No AUR helper found (yay/paru). Install InputLeap manually:"
    echo "  https://github.com/input-leap/input-leap/releases"
    echo "  Or: install yay first, then re-run this script."
    echo ""
fi

# --- 2. Firewall Rules ---
echo ">>> Opening firewall ports..."
# Moonlight (Sunshine server → Moonlight client)
run sudo firewall-cmd --add-port=47984/tcp --permanent
run sudo firewall-cmd --add-port=47989/tcp --permanent
run sudo firewall-cmd --add-port=47990/tcp --permanent
run sudo firewall-cmd --add-port=48010/tcp --permanent
run sudo firewall-cmd --add-port=47998-48000/udp --permanent
# InputLeap server port
run sudo firewall-cmd --add-port=24800/tcp --permanent
run sudo firewall-cmd --reload

# --- 3. InputLeap Server Config ---
# CachyOS acts as the InputLeap server (keyboard/mouse source).
# Windows laptop connects as a client named "WindowsLaptop" by default.
echo ">>> Writing InputLeap server configuration..."

INPUTLEAP_CONF=/etc/inputleap.conf
if $DRY_RUN; then
    echo "[DRY-RUN] Would write ${INPUTLEAP_CONF}"
else
    HOSTNAME_VAL=$(hostname)
    sudo tee "$INPUTLEAP_CONF" > /dev/null << EOF
section: screens
    ${HOSTNAME_VAL}:
    WindowsLaptop:
end

section: links
    ${HOSTNAME_VAL}:
        right = WindowsLaptop
    WindowsLaptop:
        left = ${HOSTNAME_VAL}
end

section: options
    heartbeat = 5000
    switchDelay = 300
end
EOF
    echo "InputLeap config written to ${INPUTLEAP_CONF}"
    echo "Default layout: CachyOS [left] <-> [right] WindowsLaptop"
    echo "Edit ${INPUTLEAP_CONF} if your Windows machine has a different hostname."
fi

# --- 4. InputLeap systemd User Service ---
if command -v input-leaps &>/dev/null; then
    echo ">>> Creating InputLeap server systemd user service..."
    mkdir -p ~/.config/systemd/user
    cat > ~/.config/systemd/user/inputleap-server.service << EOF
[Unit]
Description=InputLeap Server (keyboard/mouse sharing)
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=/usr/bin/input-leaps --config /etc/inputleap.conf --no-daemon
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
    if ! $DRY_RUN; then
        systemctl --user daemon-reload
        systemctl --user enable inputleap-server.service
        systemctl --user start inputleap-server.service
    else
        echo "[DRY-RUN] Would enable and start inputleap-server.service"
    fi
else
    echo ">>> Skipping InputLeap service setup (binary not found — install manually first)"
fi

# --- Final Summary ---
echo ""
echo "========================================="
echo " Dock Profile Setup Complete!"
echo "========================================="
echo ""
echo "Moonlight: installed. Configure Sunshine (Apollo fork) on your Windows laptop."
echo "  Sunshine download: https://github.com/LizardByte/Sunshine/releases"
echo ""
echo "InputLeap layout (edit /etc/inputleap.conf to match your setup):"
echo "  Server (this machine): $(hostname)"
echo "  Client (Windows):      WindowsLaptop"
echo "  Layout:                CachyOS [left screen] | [right screen] WindowsLaptop"
echo ""
echo "InputLeap Windows client download: https://github.com/input-leap/input-leap/releases"
echo "  On Windows: run InputLeap, set mode to 'Client', enter this machine's IP."
echo ""
echo "Firewall ports opened:"
echo "  Moonlight: 47984,47989,47990,48010/tcp   47998-48000/udp"
echo "  InputLeap: 24800/tcp"

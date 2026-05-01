#!/bin/bash
# validate.sh - Full system health check for all CachyOS setup profiles
# Safe to run at any time — read-only, no changes made.
# Usage: ./validate.sh [--profile minimal|apps|dock|full] [--verbose]

set -uo pipefail

PROFILE="full"
VERBOSE=false
for arg in "$@"; do
    case "$arg" in
        --profile=*) PROFILE="${arg#*=}" ;;
        --verbose|-v) VERBOSE=true ;;
        --help|-h)
            echo "Usage: $0 [--profile minimal|apps|dock|full] [--verbose]"
            echo "Checks all components for the given profile and prints pass/fail."
            exit 0
            ;;
    esac
done

PASS=0
FAIL=0
WARN=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

pass() {
    echo -e "  ${GREEN}✓${RESET} $1"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "  ${RED}✗${RESET} $1"
    $VERBOSE && [ -n "${2:-}" ] && echo -e "    ${RED}→ Fix:${RESET} $2"
    FAIL=$((FAIL + 1))
}

warn() {
    echo -e "  ${YELLOW}~${RESET} $1"
    $VERBOSE && [ -n "${2:-}" ] && echo -e "    ${YELLOW}→ Note:${RESET} $2"
    WARN=$((WARN + 1))
}

check_cmd() {
    local label="$1" cmd="$2" fix="${3:-install $2}"
    if command -v "$cmd" &>/dev/null; then pass "$label"; else fail "$label" "$fix"; fi
}

check_file() {
    local label="$1" path="$2" fix="${3:-}"
    if [ -f "$path" ]; then pass "$label"; else fail "$label" "$fix"; fi
}

check_dir() {
    local label="$1" path="$2" fix="${3:-mkdir -p $2}"
    if [ -d "$path" ]; then pass "$label"; else fail "$label" "$fix"; fi
}

check_service_active() {
    local label="$1" svc="$2"
    local user_flag="${3:---user}"
    local fix="${4:-systemctl ${user_flag} start ${svc}}"
    # shellcheck disable=SC2086
    if systemctl $user_flag is-active --quiet "$svc" 2>/dev/null; then
        pass "$label"
    else
        fail "$label" "$fix"
    fi
}

check_service_enabled() {
    local label="$1" svc="$2"
    local user_flag="${3:---user}"
    local fix="${4:-systemctl ${user_flag} enable ${svc}}"
    # shellcheck disable=SC2086
    if systemctl $user_flag is-enabled --quiet "$svc" 2>/dev/null; then
        pass "$label"
    else
        fail "$label" "$fix"
    fi
}

check_port_open() {
    local label="$1" port_proto="$2"
    if sudo firewall-cmd --list-ports 2>/dev/null | grep -qw "$port_proto"; then
        pass "$label"
    else
        fail "$label" "sudo firewall-cmd --add-port=${port_proto} --permanent && sudo firewall-cmd --reload"
    fi
}

check_container_running() {
    local label="$1" name="$2" fix="${3:-podman start $2}"
    local status
    status=$(podman inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
    if [ "$status" = "running" ]; then
        pass "$label"
    else
        fail "$label (status: ${status})" "$fix"
    fi
}

check_container_image() {
    local label="$1" image="$2"
    if podman image exists "$image" 2>/dev/null; then
        pass "$label"
    else
        fail "$label" "podman pull $image  (or rebuild with setup-apps.sh)"
    fi
}

check_flatpak() {
    local label="$1" app_id="$2"
    if flatpak info "$app_id" &>/dev/null; then
        pass "$label"
    else
        fail "$label" "flatpak install flathub $app_id"
    fi
}

# ============================================================
echo ""
echo "[SYSTEM]"

check_cmd "pacman available"        pacman
check_cmd "podman available"        podman    "sudo pacman -S podman"
check_cmd "flatpak available"       flatpak   "sudo pacman -S flatpak"
check_cmd "firewall-cmd available"  firewall-cmd "sudo pacman -S firewalld"
check_cmd "systemctl available"     systemctl
check_cmd "ip available"            ip        "sudo pacman -S iproute2"

# Systemd user session
if systemctl --user status &>/dev/null; then
    pass "systemd user session active"
else
    fail "systemd user session active" "Log out and back in, or: systemctl --user start"
fi

# Wayland socket
WL_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"
if [ -S "$WL_SOCK" ]; then
    pass "Wayland socket: ${WL_SOCK}"
else
    warn "Wayland socket not found at ${WL_SOCK}" "Expected when running under KDE Wayland session"
fi

# LTS kernel
if pacman -Q linux-cachyos-lts &>/dev/null; then
    pass "Kernel: linux-cachyos-lts installed"
else
    warn "Kernel: linux-cachyos-lts not found" "sudo pacman -S linux-cachyos-lts linux-cachyos-lts-headers"
fi

# ============================================================
echo ""
echo "[MINIMAL PROFILE]"

check_service_active "firewalld running"  firewalld  "--system" "sudo systemctl start firewalld"
check_service_enabled "firewalld enabled" firewalld  "--system" "sudo systemctl enable firewalld"

if flatpak remotes 2>/dev/null | grep -q flathub; then
    pass "Flathub remote configured"
else
    fail "Flathub remote configured" "flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
fi

check_cmd "distrobox installed" distrobox "sudo pacman -S distrobox"
check_cmd "wireguard-tools installed" wg "sudo pacman -S wireguard-tools"
if pacman -Q netavark &>/dev/null; then pass "netavark installed"; else fail "netavark installed" "sudo pacman -S netavark"; fi

# ============================================================
if [[ "$PROFILE" =~ ^(apps|full)$ ]]; then
echo ""
echo "[APPS PROFILE — SAMBA]"

check_container_image "Samba image present (servercontainers/samba:4)" "docker.io/servercontainers/samba:4"
check_container_running "Container samba-server running" samba-server "systemctl --user start container-samba-server.service"
check_dir  "~/MachineFiles exists"      "${HOME}/MachineFiles"
check_dir  "~/BrowserDownloads exists"  "${HOME}/BrowserDownloads"
check_file "Samba systemd service file exists" \
    "${HOME}/.config/systemd/user/container-samba-server.service" \
    "Re-run setup-apps.sh"
check_service_enabled "Samba service enabled" container-samba-server.service
check_service_active  "Samba service active"  container-samba-server.service
check_port_open "Port 1139/tcp open (Samba NBT)"  "1139/tcp"
check_port_open "Port 1445/tcp open (Samba SMB)"  "1445/tcp"

# Samba reachability (optional — requires smbclient)
if command -v smbclient &>/dev/null; then
    if smbclient -L localhost -p 1139 -N &>/dev/null; then
        pass "Samba share reachable (smb://localhost:1445)"
    else
        fail "Samba share reachable" "Check container logs: podman logs samba-server"
    fi
else
    warn "Samba reachability (smbclient not installed — skipping live check)"
fi

echo ""
echo "[APPS PROFILE — FUN BROWSER]"

check_container_image "waterfox-base image built" "localhost/waterfox-base"
check_file "~/.local/bin/waterfox-fun launcher exists"  "${HOME}/.local/bin/waterfox-fun"
check_file "waterfox-fun.desktop exists"                "${HOME}/.local/share/applications/waterfox-fun.desktop"

if [ -x "${HOME}/.local/bin/waterfox-fun" ]; then
    pass "waterfox-fun launcher is executable"
else
    fail "waterfox-fun launcher is executable" "chmod +x ${HOME}/.local/bin/waterfox-fun"
fi

if [ -f "${HOME}/.local/share/applications/waterfox-fun.desktop" ]; then
    if grep -q 'filesystem=home' "${HOME}/.local/share/applications/waterfox-fun.desktop"; then
        fail "waterfox-fun.desktop does NOT grant --filesystem=home" \
             "Remove --filesystem=home from the desktop file — browser should only access ~/BrowserDownloads"
    else
        pass "waterfox-fun.desktop does not expose host home"
    fi
fi

echo ""
echo "[APPS PROFILE — FIREJAIL]"

check_cmd  "firejail installed" firejail "sudo pacman -S firejail"
check_file "~/bin/sandbox-open exists" "${HOME}/bin/sandbox-open"

if [ -x "${HOME}/bin/sandbox-open" ]; then
    pass "sandbox-open is executable"
else
    fail "sandbox-open is executable" "chmod +x ${HOME}/bin/sandbox-open"
fi

# PATH checks
for shell_rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    shell_name=$(basename "$shell_rc" | sed 's/\.//')
    if grep -q 'HOME/bin' "$shell_rc" 2>/dev/null; then
        pass "~/bin in PATH (${shell_name})"
    else
        warn "~/bin not in PATH (${shell_name})" "echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ${shell_rc}"
    fi
done

if command -v fish &>/dev/null; then
    if fish -c 'echo $PATH' 2>/dev/null | tr ':' '\n' | grep -q "${HOME}/bin"; then
        pass "~/bin in PATH (fish)"
    else
        warn "~/bin not in PATH (fish)" "fish -c 'fish_add_path ~/bin'"
    fi
fi

check_file "KDE service menu exists" \
    "${HOME}/.local/share/kio/servicemenus/sandbox-open.desktop" \
    "Re-run setup-apps.sh"

echo ""
echo "[APPS PROFILE — FLATPAK APPS]"

check_flatpak "Discord installed"     "com.discordapp.Discord"
check_flatpak "Spotify installed"     "com.spotify.Client"
check_flatpak "Flatseal installed"    "com.github.tchx84.Flatseal"
check_flatpak "OnlyOffice installed"  "org.onlyoffice.desktopeditors"

echo ""
echo "[APPS PROFILE — SECURE BROWSER (VPN)]"

WG_CONF="${HOME}/vpn/wireguard/wg0.conf"
if [ -f "$WG_CONF" ]; then
    pass "WireGuard config exists: ${WG_CONF}"

    if grep -q '^\[Interface\]' "$WG_CONF"; then pass "wg0.conf has [Interface] section"
    else fail "wg0.conf has [Interface] section"; fi

    if grep -q '^\[Peer\]' "$WG_CONF"; then pass "wg0.conf has [Peer] section"
    else fail "wg0.conf has [Peer] section"; fi

    PERMS=$(stat -c '%a' "$WG_CONF" 2>/dev/null || echo "000")
    if [ "$PERMS" = "600" ]; then
        pass "wg0.conf permissions are 600"
    else
        fail "wg0.conf permissions are 600 (got ${PERMS})" "chmod 600 ${WG_CONF}"
    fi

    check_container_running "Container gluetun running" gluetun \
        "systemctl --user start container-gluetun.service"

    # Verify gluetun is NOT running privileged
    if podman inspect gluetun &>/dev/null; then
        PRIV=$(podman inspect --format '{{.HostConfig.Privileged}}' gluetun 2>/dev/null || echo "unknown")
        if [ "$PRIV" = "false" ]; then
            pass "gluetun container is not --privileged"
        else
            fail "gluetun container is not --privileged" \
                "Remove --privileged from gluetun; it only needs --cap-add NET_ADMIN"
        fi

        CAPS=$(podman inspect --format '{{.HostConfig.CapAdd}}' gluetun 2>/dev/null || echo "")
        if echo "$CAPS" | grep -q "NET_ADMIN"; then
            pass "gluetun has NET_ADMIN capability"
        else
            warn "gluetun NET_ADMIN capability not confirmed" "Check: podman inspect gluetun"
        fi
    fi

    check_file "waterfox-secure.desktop exists" \
        "${HOME}/.local/share/applications/waterfox-secure.desktop"
    check_file "~/.local/bin/waterfox-secure exists" \
        "${HOME}/.local/bin/waterfox-secure"
    check_file "Gluetun systemd service file exists" \
        "${HOME}/.config/systemd/user/container-gluetun.service"
    check_service_enabled "Gluetun service enabled" container-gluetun.service
    check_dir  "~/SecureDownloads exists" "${HOME}/SecureDownloads"

    # VPN routing check (optional — needs internet)
    if command -v curl &>/dev/null && podman inspect --format '{{.State.Status}}' gluetun 2>/dev/null | grep -q '^running$'; then
        HOST_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
        VPN_IP=$(podman exec gluetun curl -s --max-time 10 https://ifconfig.me 2>/dev/null || echo "")
        if [ -n "$HOST_IP" ] && [ -n "$VPN_IP" ] && [ "$HOST_IP" != "$VPN_IP" ]; then
            pass "VPN routing: host IP (${HOST_IP}) ≠ VPN IP (${VPN_IP})"
        elif [ -z "$HOST_IP" ] || [ -z "$VPN_IP" ]; then
            warn "VPN routing check skipped (no internet or gluetun not yet connected)"
        else
            fail "VPN routing: host and VPN IPs are the same (${HOST_IP})" \
                "Check gluetun logs: podman logs gluetun"
        fi
    else
        warn "VPN routing check skipped (curl unavailable or gluetun not running)"
    fi
else
    warn "WireGuard config not found at ${WG_CONF}" \
        "Re-run setup-apps.sh and provide a WireGuard config to enable the secure browser"
fi

fi  # end apps|full

# ============================================================
if [[ "$PROFILE" =~ ^(dock|full)$ ]]; then
echo ""
echo "[DOCK PROFILE — INPUTLEAP]"

check_cmd  "inputleap installed (input-leaps)" input-leaps \
    "yay -S input-leap  OR  https://github.com/input-leap/input-leap/releases"
check_file "/etc/inputleap.conf exists" /etc/inputleap.conf \
    "Re-run setup-dock.sh"
check_file "inputleap-server.service file exists" \
    "${HOME}/.config/systemd/user/inputleap-server.service" \
    "Re-run setup-dock.sh"
check_service_enabled "inputleap-server.service enabled" inputleap-server.service
check_service_active  "inputleap-server.service running"  inputleap-server.service
check_port_open "Port 24800/tcp open (InputLeap)" "24800/tcp"

echo ""
echo "[DOCK PROFILE — MOONLIGHT]"

check_cmd  "moonlight-qt installed" moonlight-qt "sudo pacman -S moonlight-qt"
check_port_open "Port 47984/tcp open (Moonlight)" "47984/tcp"
check_port_open "Port 47989/tcp open (Moonlight)" "47989/tcp"
check_port_open "Port 47990/tcp open (Moonlight)" "47990/tcp"
check_port_open "Port 48010/tcp open (Moonlight)" "48010/tcp"
check_port_open "Ports 47998-48000/udp open (Moonlight)" "47998-48000/udp"

fi  # end dock|full

# ============================================================
TOTAL=$((PASS + FAIL + WARN))
echo ""
echo "======================================="
echo " SUMMARY"
echo "======================================="
echo -e "  ${GREEN}Passed${RESET}:  ${PASS} / ${TOTAL}"
[ $WARN -gt 0 ] && echo -e "  ${YELLOW}Warnings${RESET}: ${WARN} / ${TOTAL}"
[ $FAIL -gt 0 ] && echo -e "  ${RED}Failed${RESET}:  ${FAIL} / ${TOTAL}"
echo ""
[ $FAIL -gt 0 ] && echo "Run with --verbose for fix hints on failed checks."
echo ""

[ $FAIL -eq 0 ]

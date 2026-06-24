#!/bin/bash
# cachyos-configure.sh - Master setup orchestrator
# Usage: ./cachyos-configure.sh --profile [minimal|apps|dock|winapps|full]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE=""
DRY_RUN=""

for arg in "$@"; do
    case "$arg" in
        --profile=*) PROFILE="${arg#*=}" ;;
        --dry-run)   DRY_RUN="--dry-run" ;;
        --help|-h)
            echo "Usage: $0 --profile [minimal|apps|dock|winapps|full] [--dry-run]"
            echo ""
            echo "Profiles:"
            echo "  minimal   Base system: podman, flatpak, firewalld, wireguard-tools"
            echo "  apps      Minimal + isolated browsers, Samba, Firejail, optional VPN"
            echo "  dock      Minimal + InputLeap (KVM) + Moonlight (streaming)"
            echo "  winapps   Minimal + Windows app streaming (FreeRDP + Windows VM)"
            echo "  full      All of the above"
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if [ -z "$PROFILE" ]; then
    echo "ERROR: --profile is required." >&2
    echo "Run '$0 --help' for usage." >&2
    exit 1
fi

run_script() {
    local script="${SCRIPT_DIR}/$1"
    if [ ! -f "$script" ]; then
        echo "ERROR: Script not found: ${script}" >&2
        exit 1
    fi
    echo ""
    echo ">>> Running: $1 ${DRY_RUN}"
    bash "$script" ${DRY_RUN}
}

echo "========================================="
echo " CachyOS Configure — profile: ${PROFILE}${DRY_RUN:+ (DRY RUN)}"
echo "========================================="

case "$PROFILE" in
    minimal)
        run_script minimal.sh
        ;;
    apps)
        run_script minimal.sh
        run_script setup-apps.sh
        ;;
    dock)
        run_script minimal.sh
        run_script setup-dock.sh
        ;;
    winapps)
        run_script minimal.sh
        run_script setup-winapps.sh
        ;;
    full)
        run_script minimal.sh
        run_script setup-apps.sh
        run_script setup-dock.sh
        run_script setup-winapps.sh
        ;;
    *)
        echo "ERROR: Unknown profile '${PROFILE}'. Valid: minimal, apps, dock, winapps, full" >&2
        exit 1
        ;;
esac

echo ""
echo "========================================="
echo " All done! Profile '${PROFILE}' complete."
echo "========================================="
echo ""
echo "Run ./validate.sh to verify the installation."

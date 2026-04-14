#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# start-vf-bridge.sh
#
# Creates an SR-IOV VF on the BlueField-3 protected PF (PF0 for the
# managed-proxy MVP), then launches vf-bridge in the background to relay
# Ethernet frames between the VF and a UNIX stream socket consumed by libkrun
# (guest eth1).
#
# Usage:
#   sudo ./start-vf-bridge.sh [OPTIONS]
#
# Options:
#   --pf <dev>       Host PF netdev             (default: enp179s0f1np1)
#   --pci <addr>     PCI address of the BF3 PF  (default: 0000:b3:00.1)
#   --socket <path>  UNIX socket for vf-bridge  (default: /run/openshell/vf-bridge/eth1.sock)
#   --skip-vf        Skip VF creation (VF already exists)
#   --foreground     Run vf-bridge in foreground (default: background)
#   --help           Show this help
#
# Prerequisites:
#   - SR-IOV enabled in BIOS and kernel (iommu=pt intel_iommu=on)
#   - vfio, vfio_pci modules loaded
#   - DPU in switchdev mode with pf0vf0 wired into ovsbr1
#   - vf-bridge binary built (target/debug/vf-bridge or target/release/vf-bridge)
#
# After running this script, verify DPU side via rshim SSH:
#   ssh ubuntu@192.168.100.2
#   sudo ovs-vsctl show              # pf0vf0 should be in ovsbr1
#   sudo ovs-ofctl dump-flows ovsbr1 # check policy rules on pf0vf0

set -euo pipefail

SCRIPT_NAME="vf-bridge"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────
SKIP_VF=false
FOREGROUND=false

# ── Usage ─────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: sudo ./start-vf-bridge.sh [OPTIONS]

Creates SR-IOV VF on the protected BF3 PF and launches vf-bridge.

Options:
  --pf <dev>       Host PF netdev             (default: enp179s0f0np0)
  --pci <addr>     PCI address of the BF3 PF  (default: 0000:b3:00.0)
  --socket <path>  UNIX socket for vf-bridge  (default: /run/openshell/vf-bridge/eth1.sock)
  --skip-vf        Skip VF creation (VF already exists)
  --foreground     Run vf-bridge in foreground
  --help           Show this help
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pf)         PF_DEV="$2";      shift 2 ;;
        --pci)        PF_PCI="$2";      shift 2 ;;
        --socket)     SOCKET_PATH="$2"; shift 2 ;;
        --skip-vf)    SKIP_VF=true;     shift ;;
        --foreground) FOREGROUND=true;  shift ;;
        --help)       usage ;;
        *)            die "Unknown option: $1" ;;
    esac
done

# ── Prerequisite checks ──────────────────────────────────────────────────
require_root

# Note: vfio/vfio_pci are NOT required — vf-bridge uses AF_PACKET sockets,
# not VFIO passthrough. SR-IOV VFs just need the kernel PF driver.

[[ -e "/sys/bus/pci/devices/$PF_PCI" ]] \
    || die "PCI device $PF_PCI not found. Check --pci flag."

ip link show "$PF_DEV" >/dev/null 2>&1 \
    || die "Netdev $PF_DEV not found. Check --pf flag."

[[ -x "$VF_BRIDGE_BIN" ]] \
    || die "vf-bridge not found at $VF_BRIDGE_BIN. Build it first: cargo build -p vf-bridge"

# ── Step 1: Create VF (idempotent) ───────────────────────────────────────
SRIOV_FILE="/sys/bus/pci/devices/$PF_PCI/sriov_numvfs"

if $SKIP_VF; then
    log "Skipping VF creation (--skip-vf)"
else
    CURRENT_VFS=$(cat "$SRIOV_FILE" 2>/dev/null || echo 0)
    if [[ "$CURRENT_VFS" -ge 1 ]]; then
        log "VF already exists (sriov_numvfs=$CURRENT_VFS) — skipping creation."
    else
        log "Creating 1 VF on $PF_PCI ($PF_DEV)..."
        echo 1 > "$SRIOV_FILE"
        sleep 1
    fi
fi

# ── Step 2: Discover VF netdev ────────────────────────────────────────────
# Prefer the sysfs path for robust discovery
VF_DEV=""
VIRTFN0_NET="/sys/bus/pci/devices/$PF_PCI/virtfn0/net"
if [[ -d "$VIRTFN0_NET" ]]; then
    VF_DEV=$(ls "$VIRTFN0_NET" 2>/dev/null | head -1)
fi
# Fallback: scan ip link for enp*v0 pattern
if [[ -z "$VF_DEV" ]]; then
    VF_DEV=$(ip link show 2>/dev/null | awk -F': ' '/enp.*v0/{print $2; exit}' | tr -d ' ')
fi
[[ -n "$VF_DEV" ]] || die "VF netdev not found after creation. Check dmesg for errors."
log "VF netdev: $VF_DEV"

# ── Step 3: Configure VF (MAC + link up) ─────────────────────────────────
log "Setting VF MAC to $VF_MAC..."
ip link set "$VF_DEV" address "$VF_MAC" 2>/dev/null || warn "Could not set MAC (may already be set)"
ip link set "$VF_DEV" up
log "VF $VF_DEV is UP with MAC $VF_MAC."

# ── Step 4: Kill stale vf-bridge + clean socket ──────────────────────────
kill_stale vf-bridge

SOCKET_DIR=$(dirname "$SOCKET_PATH")
mkdir -p "$SOCKET_DIR"
rm_if_exists "$SOCKET_PATH"

# ── Step 5: Launch vf-bridge ─────────────────────────────────────────────
mkdir -p "$LOG_DIR" "$PID_DIR"

if $FOREGROUND; then
    log "Launching vf-bridge in FOREGROUND: $VF_DEV -> $SOCKET_PATH"
    log "Press Ctrl+C to stop."
    exec "$VF_BRIDGE_BIN" --ifname "$VF_DEV" --socket "$SOCKET_PATH"
else
    log "Launching vf-bridge in background: $VF_DEV -> $SOCKET_PATH"
    "$VF_BRIDGE_BIN" --ifname "$VF_DEV" --socket "$SOCKET_PATH" \
        >> "$LOG_DIR/vf-bridge.log" 2>&1 &
    VF_PID=$!
    echo "$VF_PID" > "$PID_DIR/vf-bridge.pid"

    # Verify it stayed alive
    sleep 1
    if kill -0 "$VF_PID" 2>/dev/null; then
        log "vf-bridge running (PID $VF_PID)."
    else
        die "vf-bridge exited immediately. Check $LOG_DIR/vf-bridge.log"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
log "=== vf-bridge status ==="
log "  VF netdev:  $VF_DEV"
log "  VF MAC:     $VF_MAC"
log "  Socket:     $SOCKET_PATH"
log "  PID:        $(cat "$PID_DIR/vf-bridge.pid" 2>/dev/null || echo "$VF_PID")"
log "  Log:        $LOG_DIR/vf-bridge.log"
echo ""
log "=== DPU verification (via rshim SSH) ==="
log "  ssh ubuntu@192.168.100.2"
log "    sudo ovs-vsctl show              # pf0vf0 should be in ovsbr1"
log "    sudo ovs-ofctl dump-flows ovsbr1 # check policy rules on pf0vf0"
echo ""
log "Next: sudo ./start-microvm.sh --with-vf-bridge"

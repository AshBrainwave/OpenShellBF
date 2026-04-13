#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# setup-dpu-nat.sh
#
# Configures OVS connection-tracking with hardware-offloaded SNAT on the
# BlueField-3 DPU for sandbox VF egress.
#
# This script runs on the DPU ARM cores (via rshim SSH).
#
# Architecture:
#   pf1vf0 (sandbox VF representor)
#     → ovsbr2 (OVS bridge)
#     → ct(commit, nat(src=10.185.99.182))  [SNAT to routable IP]
#     → p1 (physical uplink, wire 1)
#     → datacenter network → internet
#   Return traffic:
#     → p1 → ct(nat) → reverse NAT → pf1vf0 → VF → vf-bridge → VM
#
# Wire symmetry: SNAT IP (10.185.99.182) is on enp3s0f1s0 (PF1 SF),
# so the DC router sends return traffic back via wire 1 (p1) where
# the CT state lives on ovsbr2.
#
# Prerequisites:
#   - DPU in switchdev/separated-host mode
#   - PF1 VF created on host (sriov_numvfs >= 1 on PF1)
#   - pf1vf0 representor present and attached to ovsbr2
#   - enp3s0f1s0 has IP 10.185.99.182/24 (PF1 SF application netdev)
#
# Usage:
#   ssh ubuntu@192.168.100.2
#   sudo bash setup-dpu-nat.sh [OPTIONS]
#
# Options:
#   --snat-ip <ip>     SNAT IP address          (default: 10.185.99.182)
#   --bridge <name>    OVS bridge name          (default: ovsbr2)
#   --vf-rep <port>    VF representor port      (default: pf1vf0)
#   --uplink <port>    Physical uplink port     (default: p1)
#   --host-rep <port>  Host PF representor      (default: pf1hpf)
#   --dry-run          Print commands without executing
#   --help             Show this help

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────
SNAT_IP="${SNAT_IP:-10.185.99.182}"
BRIDGE="${BRIDGE:-ovsbr2}"
VF_REP="${VF_REP:-pf1vf0}"
UPLINK="${UPLINK:-p1}"
HOST_REP="${HOST_REP:-pf1hpf}"
SF_REP="${SF_REP:-en3f1pf1sf0}"
DRY_RUN=false

# ── Logging ─────────────────────────────────────────────────────────────
log()  { echo "[$(date +%T)] [dpu-nat] $*"; }
warn() { echo "[$(date +%T)] [dpu-nat] WARN: $*" >&2; }
die()  { echo "[$(date +%T)] [dpu-nat] ERROR: $*" >&2; exit 1; }

run() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        log "  Running: $*"
        eval "$@"
    fi
}

# ── Usage ───────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: sudo bash setup-dpu-nat.sh [OPTIONS]

Configures OVS CT/NAT on the DPU for sandbox VF egress.

Options:
  --snat-ip <ip>     SNAT IP address          (default: 10.185.99.182)
  --bridge <name>    OVS bridge name          (default: ovsbr2)
  --vf-rep <port>    VF representor port      (default: pf1vf0)
  --uplink <port>    Physical uplink port     (default: p1)
  --host-rep <port>  Host PF representor      (default: pf1hpf)
  --dry-run          Print commands without executing
  --help             Show this help
EOF
    exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --snat-ip)   SNAT_IP="$2";  shift 2 ;;
        --bridge)    BRIDGE="$2";   shift 2 ;;
        --vf-rep)    VF_REP="$2";   shift 2 ;;
        --uplink)    UPLINK="$2";   shift 2 ;;
        --host-rep)  HOST_REP="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true;  shift ;;
        --help)      usage ;;
        *)           die "Unknown option: $1" ;;
    esac
done

# ── Prerequisite checks ────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Must run as root (sudo)."

log "Checking prerequisites..."

# Verify bridge exists
ovs-vsctl br-exists "$BRIDGE" 2>/dev/null \
    || die "OVS bridge $BRIDGE not found. Run: ovs-vsctl show"

# Verify VF representor is a port on the bridge
VF_BRIDGE=$(ovs-vsctl port-to-br "$VF_REP" 2>/dev/null || true)
if [[ "$VF_BRIDGE" != "$BRIDGE" ]]; then
    if [[ -z "$VF_BRIDGE" ]]; then
        die "$VF_REP is not attached to any OVS bridge. Create the PF1 VF on the host first."
    else
        die "$VF_REP is on bridge $VF_BRIDGE, expected $BRIDGE."
    fi
fi

# Verify uplink is on the bridge
UPLINK_BRIDGE=$(ovs-vsctl port-to-br "$UPLINK" 2>/dev/null || true)
[[ "$UPLINK_BRIDGE" == "$BRIDGE" ]] \
    || die "$UPLINK is not on $BRIDGE (found: ${UPLINK_BRIDGE:-none})."

log "Prerequisites OK: $VF_REP and $UPLINK are on $BRIDGE, SNAT IP=$SNAT_IP"

# ── Step 1: Enable hardware offload ────────────────────────────────────
log ""
log "=== Step 1: Hardware offload ==="

CURRENT_HW=$(ovs-vsctl get Open_vSwitch . other_config:hw-offload 2>/dev/null || echo "")
if [[ "$CURRENT_HW" == '"true"' ]]; then
    log "hw-offload already enabled."
else
    log "Enabling hw-offload..."
    run "ovs-vsctl set Open_vSwitch . other_config:hw-offload=true"
    warn "hw-offload changed — OVS restart required. Run: systemctl restart openvswitch"
    warn "Then re-run this script."
    exit 1
fi

# Enable TC offload on uplink (idempotent)
run "ethtool -K $UPLINK hw-tc-offload on 2>/dev/null || true"

# ── Step 2: Kernel tuning for conntrack ─────────────────────────────────
log ""
log "=== Step 2: Conntrack tuning ==="
run "sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1 2>/dev/null || true"

# ── Step 3: Install OVS CT/NAT flows ───────────────────────────────────
log ""
log "=== Step 3: OVS flow rules on $BRIDGE ==="

log "Clearing existing flows on $BRIDGE..."
run "ovs-ofctl del-flows $BRIDGE"

log "Installing CT/NAT flows..."

# --- Table 0: Classification ---

# ARP: always allow (needed for SNAT IP reachability)
run "ovs-ofctl add-flow $BRIDGE 'table=0, priority=1000, arp, actions=normal'"

# Host PF representor: pass through (management, SSH, etc.)
run "ovs-ofctl add-flow $BRIDGE 'table=0, priority=900, in_port=$HOST_REP, actions=normal'"

# SF representor: pass through (DPU's own traffic via enp3s0f1s0)
run "ovs-ofctl add-flow $BRIDGE 'table=0, priority=900, in_port=$SF_REP, actions=normal'"

# Local subnet from wire: pass through (DPU management, ARP replies, SSH)
run "ovs-ofctl add-flow $BRIDGE 'table=0, priority=900, in_port=$UPLINK, ip, nw_dst=10.185.99.0/24, actions=normal'"

# VF outbound: untracked IP → send to CT for tracking + NAT
run "ovs-ofctl add-flow $BRIDGE 'table=0, priority=500, ip, in_port=$VF_REP, actions=ct(table=1,nat)'"

# Wire inbound: untracked IP → send to CT for reverse NAT lookup
run "ovs-ofctl add-flow $BRIDGE 'table=0, priority=500, ip, in_port=$UPLINK, actions=ct(table=1,nat)'"

# Default: drop (fail-closed)
run "ovs-ofctl add-flow $BRIDGE 'table=0, priority=0, actions=drop'"

# --- Table 1: Connection tracking decisions ---

# NEW from VF → SNAT + commit + output to wire
run "ovs-ofctl add-flow $BRIDGE 'table=1, priority=100, ip, ct_state=+trk+new, in_port=$VF_REP, actions=ct(commit,nat(src=$SNAT_IP)),output:$UPLINK'"

# ESTABLISHED from VF → output to wire (already committed, NAT applied)
run "ovs-ofctl add-flow $BRIDGE 'table=1, priority=100, ip, ct_state=+trk+est, in_port=$VF_REP, actions=output:$UPLINK'"

# ESTABLISHED from wire → reverse NAT → output to VF
run "ovs-ofctl add-flow $BRIDGE 'table=1, priority=100, ip, ct_state=+trk+est, in_port=$UPLINK, actions=output:$VF_REP'"

# Drop invalid/untracked (fail-closed)
run "ovs-ofctl add-flow $BRIDGE 'table=1, priority=0, actions=drop'"

# ── Step 4: Verify ──────────────────────────────────────────────────────
log ""
log "=== Step 4: Verification ==="

if ! $DRY_RUN; then
    log "Installed flows:"
    ovs-ofctl dump-flows "$BRIDGE" | grep -v "NXST_FLOW" | while read -r line; do
        log "  $line"
    done
fi

# ── Summary ─────────────────────────────────────────────────────────────
log ""
log "=== DPU NAT setup complete ==="
log "  Bridge:    $BRIDGE"
log "  VF rep:    $VF_REP"
log "  Uplink:    $UPLINK"
log "  SNAT IP:   $SNAT_IP"
log "  Host rep:  $HOST_REP (pass-through)"
log ""
log "Test from sandbox VM:"
log "  # On host: create sandbox and curl"
log "  openshell sandbox create --policy policies/allow-anthropic.yaml -- curl -s https://api.anthropic.com/v1/models"
log ""
log "  # On DPU: watch traffic (should see SNAT'd source)"
log "  tcpdump -i $UPLINK -n tcp port 443"
log "  tcpdump -i $VF_REP -n tcp port 443"
log ""
log "  # Check hardware offload"
log "  ovs-appctl dpctl/dump-flows -m | grep offloaded"
log "  conntrack -L | grep $SNAT_IP"

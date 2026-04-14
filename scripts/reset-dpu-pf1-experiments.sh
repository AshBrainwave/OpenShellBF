#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# reset-dpu-pf1-experiments.sh
#
# Host-side wrapper that removes the PF1 NAT experiment state from the DPU
# without touching PF0 / ovsbr1 or the out-of-band interface directly.

set -euo pipefail

SCRIPT_NAME="reset-dpu-pf1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

RESTORE_HW_OFFLOAD="${RESTORE_HW_OFFLOAD:-false}"

usage() {
    cat <<EOF
Usage: sudo ./scripts/reset-dpu-pf1-experiments.sh [OPTIONS]

Remove PF1/ovsbr2 NAT experiment state from the DPU and print a quick status
summary. This script intentionally avoids modifying PF0/ovsbr1 and does not
directly change oob_net0 routing.

Options:
  --dpu-host <host>          DPU SSH host (default: ${DPU_HOST})
  --dpu-user <user>          DPU SSH user (default: ${DPU_USER})
  --restore-hw-offload       Restore Open vSwitch hw-offload=true and restart OVS
  --help                     Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dpu-host) DPU_HOST="$2"; shift 2 ;;
        --dpu-user) DPU_USER="$2"; shift 2 ;;
        --restore-hw-offload) RESTORE_HW_OFFLOAD=true; shift ;;
        --help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

require_root

SSH_TARGET="${DPU_USER}@${DPU_HOST}"
IFS=' ' read -r -a SSH_OPTS_ARR <<<"$DPU_SSH_OPTS"

REMOTE_SCRIPT=$(cat <<EOF
set -euo pipefail

BRIDGE="ovsbr2"
UPLINK_DEV="enp3s0f1s0"
OVS_VETH="ovsnat0"
HOST_VETH="hostnat0"
GUEST_SUBNET="10.99.2.0/24"

restart_ovs() {
    systemctl restart openvswitch-switch 2>/dev/null || systemctl restart openvswitch
}

# Remove debug tables and test-only iptables hooks.
nft delete table inet debug 2>/dev/null || true
nft delete table inet ctdebug 2>/dev/null || true

iptables -t raw -D PREROUTING -i nat0 -s \${GUEST_SUBNET} -j CT --zone 1 2>/dev/null || true
iptables -t raw -D PREROUTING -i \${HOST_VETH} -s \${GUEST_SUBNET} -j CT 2>/dev/null || true

iptables -t nat -D POSTROUTING -s \${GUEST_SUBNET} -o \${UPLINK_DEV} -j SNAT --to-source 10.185.99.182 2>/dev/null || true
iptables -t nat -D POSTROUTING -s \${GUEST_SUBNET} ! -d \${GUEST_SUBNET} -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -s \${GUEST_SUBNET} -j SNAT --to-source 10.185.99.182 2>/dev/null || true

iptables -D FORWARD -i \${HOST_VETH} -o \${UPLINK_DEV} -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i \${UPLINK_DEV} -o \${HOST_VETH} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -s \${GUEST_SUBNET} -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -d \${GUEST_SUBNET} -j ACCEPT 2>/dev/null || true

# Remove PF1 test escape ports / links.
ovs-vsctl --if-exists del-port \${BRIDGE} nat0
ovs-vsctl --if-exists del-port \${BRIDGE} \${OVS_VETH}
ip link del \${OVS_VETH} 2>/dev/null || true
ip link del nat0 2>/dev/null || true

# Clear PF1 experiment flows and return ovsbr2 to a minimal bridge.
ovs-ofctl del-flows \${BRIDGE}
ovs-ofctl add-flow \${BRIDGE} "priority=0,actions=NORMAL"

if [[ "${RESTORE_HW_OFFLOAD}" == "true" ]]; then
    ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
    restart_ovs
fi

echo "=== PF1 experiment state cleaned ==="
echo
echo "-- oob_net0 --"
ip addr show oob_net0 || true
echo
echo "-- routes --"
ip route show || true
echo
echo "-- Open vSwitch hw-offload --"
ovs-vsctl get Open_vSwitch . other_config:hw-offload || true
echo
echo "-- ovsbr2 flows --"
ovs-ofctl dump-flows \${BRIDGE} || true
echo
echo "-- iptables FORWARD --"
iptables -L FORWARD -n -v || true
echo
echo "-- nft tables --"
nft list tables || true
EOF
)

log "Cleaning PF1 NAT experiment state on DPU $SSH_TARGET..."
log "  restore hw-offload: $RESTORE_HW_OFFLOAD"
ssh "${SSH_OPTS_ARR[@]}" "$SSH_TARGET" "sudo RESTORE_HW_OFFLOAD=${RESTORE_HW_OFFLOAD} bash -s" <<<"$REMOTE_SCRIPT"

echo ""
log "If OOB still does not work, check the DPU default route specifically:"
log "  ssh $SSH_TARGET 'ip route get 1.1.1.1; ip route get <openshell-server-ip>'"
log "If the default route is wrong, restore it explicitly via oob_net0."

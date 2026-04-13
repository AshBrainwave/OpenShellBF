#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# test-dpu-veth-nat.sh
#
# Host-side wrapper that configures a DPU-side veth escape path:
#   pf1vf0 -> ovsbr2 -> ovsnat0 <-> hostnat0 -> Linux routing/NAT -> enp3s0f1s0

set -euo pipefail

SCRIPT_NAME="dpu-veth-nat"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Usage: sudo ./scripts/test-dpu-veth-nat.sh [OPTIONS]

Runs the PF1 veth-based Linux NAT test on the DPU.

Options:
  --dpu-host <host>   DPU SSH host (default: ${DPU_HOST})
  --dpu-user <user>   DPU SSH user (default: ${DPU_USER})
  --help              Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dpu-host) DPU_HOST="$2"; shift 2 ;;
        --dpu-user) DPU_USER="$2"; shift 2 ;;
        --help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

require_root

SSH_TARGET="${DPU_USER}@${DPU_HOST}"
IFS=' ' read -r -a SSH_OPTS_ARR <<<"$DPU_SSH_OPTS"
KEEP_MASTER="${DPU_SSH_KEEP_MASTER:-false}"

ensure_master() {
    ssh "${SSH_OPTS_ARR[@]}" -O check "$SSH_TARGET" >/dev/null 2>&1 \
        || ssh "${SSH_OPTS_ARR[@]}" -fN "$SSH_TARGET"
}

stop_master() {
    ssh "${SSH_OPTS_ARR[@]}" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true
}

REMOTE_SCRIPT=$(cat <<'EOF'
set -euo pipefail

BRIDGE="ovsbr2"
VF_REP="pf1vf0"
UPLINK_REP="p1"
HOST_REP="pf1hpf"
SF_REP="en3f1pf1sf0"
UPLINK_DEV="enp3s0f1s0"
OVS_VETH="ovsnat0"
HOST_VETH="hostnat0"
GATEWAY_CIDR="10.99.2.1/24"
GATEWAY_MAC="02:00:00:00:00:01"
GUEST_SUBNET="10.99.2.0/24"
SNAT_IP="10.185.99.182"

restart_ovs() {
    systemctl restart openvswitch-switch 2>/dev/null || systemctl restart openvswitch
}

# Clean prior experiments.
nft delete table inet debug 2>/dev/null || true
nft delete table inet ctdebug 2>/dev/null || true
iptables -t raw -D PREROUTING -i nat0 -s 10.99.2.0/24 -j CT --zone 1 2>/dev/null || true
iptables -t raw -D PREROUTING -i ${HOST_VETH} -s ${GUEST_SUBNET} -j CT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s ${GUEST_SUBNET} -o ${UPLINK_DEV} -j SNAT --to-source ${SNAT_IP} 2>/dev/null || true
iptables -t nat -D POSTROUTING -s ${GUEST_SUBNET} ! -d ${GUEST_SUBNET} -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i ${HOST_VETH} -o ${UPLINK_DEV} -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i ${UPLINK_DEV} -o ${HOST_VETH} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
ovs-vsctl --if-exists del-port ${BRIDGE} nat0
ovs-vsctl --if-exists del-port ${BRIDGE} ${OVS_VETH}
ip link del ${OVS_VETH} 2>/dev/null || true

ovs-vsctl set Open_vSwitch . other_config:hw-offload=false
restart_ovs

ip link del ${OVS_VETH} 2>/dev/null || true
ip link add ${OVS_VETH} type veth peer name ${HOST_VETH}
ip link set ${HOST_VETH} address ${GATEWAY_MAC}
ip link set ${OVS_VETH} up
ip link set ${HOST_VETH} up
ip addr flush dev ${HOST_VETH}
ip addr add ${GATEWAY_CIDR} dev ${HOST_VETH}

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.${UPLINK_DEV}.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.${HOST_VETH}.rp_filter=0 >/dev/null

iptables -t raw -I PREROUTING 1 -i ${HOST_VETH} -s ${GUEST_SUBNET} -j CT
iptables -I FORWARD 1 -i ${HOST_VETH} -o ${UPLINK_DEV} -j ACCEPT
iptables -I FORWARD 1 -i ${UPLINK_DEV} -o ${HOST_VETH} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -I POSTROUTING 1 -s ${GUEST_SUBNET} -o ${UPLINK_DEV} -j SNAT --to-source ${SNAT_IP}

nft add table inet ctdebug
nft 'add chain inet ctdebug forward { type filter hook forward priority filter; policy accept; }'
nft add rule inet ctdebug forward ip saddr 10.99.2.2 ip daddr 160.79.104.10 ct state untracked counter
nft add rule inet ctdebug forward ip saddr 10.99.2.2 ip daddr 160.79.104.10 ct state new counter
nft add rule inet ctdebug forward ip saddr 10.99.2.2 ip daddr 160.79.104.10 ct state established counter
nft add rule inet ctdebug forward ip saddr 10.99.2.2 ip daddr 160.79.104.10 counter

ovs-vsctl --may-exist add-port ${BRIDGE} ${UPLINK_REP}
ovs-vsctl --may-exist add-port ${BRIDGE} ${VF_REP}
ovs-vsctl --may-exist add-port ${BRIDGE} ${HOST_REP}
ovs-vsctl --may-exist add-port ${BRIDGE} ${SF_REP}
ovs-vsctl --may-exist add-port ${BRIDGE} ${OVS_VETH}

ovs-ofctl del-flows ${BRIDGE}
ovs-ofctl add-flow ${BRIDGE} "table=0,priority=1000,arp,actions=normal"
ovs-ofctl add-flow ${BRIDGE} "table=0,priority=900,in_port=${HOST_REP},actions=normal"
ovs-ofctl add-flow ${BRIDGE} "table=0,priority=900,in_port=${SF_REP},actions=normal"
ovs-ofctl add-flow ${BRIDGE} "table=0,priority=900,in_port=${UPLINK_REP},ip,nw_dst=10.185.99.0/24,actions=normal"
ovs-ofctl add-flow ${BRIDGE} "table=0,priority=500,ip,in_port=${VF_REP},actions=output:${OVS_VETH}"
ovs-ofctl add-flow ${BRIDGE} "table=0,priority=500,ip,in_port=${OVS_VETH},nw_dst=${GUEST_SUBNET},actions=output:${VF_REP}"
ovs-ofctl add-flow ${BRIDGE} "table=0,priority=0,actions=drop"

echo "=== DPU veth NAT path installed ==="
ip addr show ${HOST_VETH}
ip link show ${HOST_VETH}
echo
iptables -t raw -L PREROUTING -n -v
echo
iptables -L FORWARD -n -v
echo
nft list chain ip nat POSTROUTING || true
echo
nft list chain inet ctdebug forward
echo
ovs-ofctl dump-flows ${BRIDGE}
EOF
)

if [[ "$KEEP_MASTER" != "true" ]]; then
    stop_master
    trap stop_master EXIT
fi
ensure_master

log "Applying PF1 veth-based NAT test on DPU $SSH_TARGET..."
log "  SSH opts: $DPU_SSH_OPTS"
ssh "${SSH_OPTS_ARR[@]}" "$SSH_TARGET" "sudo bash -s" <<<"$REMOTE_SCRIPT"

echo ""
log "Next on the DPU, watch traffic if needed:"
log "  sudo tcpdump -i pf1vf0 -n 'host 160.79.104.10 and tcp port 443' -c 20"
log "  sudo tcpdump -i hostnat0 -n 'host 10.99.2.2 or host 10.185.99.182 or host 160.79.104.10' -c 20"
log "  sudo tcpdump -i enp3s0f1s0 -n 'host 10.99.2.2 or host 10.185.99.182 or host 160.79.104.10' -c 20"
log "  sudo tcpdump -i p1 -n 'host 160.79.104.10 and tcp port 443' -c 20"

#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# setup-dpu-managed-proxy-path.sh
#
# Host-side helper that prepares the DPU protected-side path for the
# managed-proxy MVP:
#   - assigns 10.99.2.1/24 to the PF0 SF app netdev
#   - installs OVS flows to steer guest proxy traffic between pf0vf0 and SF0

set -euo pipefail

SCRIPT_NAME="setup-dpu-proxy-path"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DPU_SSH_TARGET="${DPU_SSH_TARGET:-bf-dpu}"
SF_APP_DEV="${SF_APP_DEV:-enp3s0f0s0}"
SF_REP="${SF_REP:-en3f0pf0sf0}"
VF_REP="${VF_REP:-pf0vf0}"
BRIDGE="${BRIDGE:-ovsbr1}"
PROXY_IP_CIDR="${PROXY_IP_CIDR:-10.99.2.1/24}"
PROXY_IP="${PROXY_IP:-10.99.2.1}"
GUEST_IP="${GUEST_IP:-10.99.2.2}"
PROXY_PORT="${PROXY_PORT:-3128}"

usage() {
    cat <<'EOF'
Usage: ./setup-dpu-managed-proxy-path.sh [OPTIONS]

Prepare the DPU protected path for the managed-proxy MVP.

Options:
  --host <target>      DPU SSH target              (default: bf-dpu)
  --bridge <name>      OVS bridge                  (default: ovsbr1)
  --vf-rep <name>      VF representor port         (default: pf0vf0)
  --sf-rep <name>      SF representor port         (default: en3f0pf0sf0)
  --sf-app <dev>       SF application netdev       (default: enp3s0f0s0)
  --proxy-ip <cidr>    DPU protected IP            (default: 10.99.2.1/24)
  --guest-ip <ip>      Guest protected IP          (default: 10.99.2.2)
  --proxy-port <port>  Proxy TCP port              (default: 3128)
  --help               Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       DPU_SSH_TARGET="$2"; shift 2 ;;
        --bridge)     BRIDGE="$2"; shift 2 ;;
        --vf-rep)     VF_REP="$2"; shift 2 ;;
        --sf-rep)     SF_REP="$2"; shift 2 ;;
        --sf-app)     SF_APP_DEV="$2"; shift 2 ;;
        --proxy-ip)   PROXY_IP_CIDR="$2"; shift 2 ;;
        --guest-ip)   GUEST_IP="$2"; shift 2 ;;
        --proxy-port) PROXY_PORT="$2"; shift 2 ;;
        --help)       usage ;;
        *)            die "Unknown option: $1" ;;
    esac
done

PROXY_IP="${PROXY_IP_CIDR%/*}"

REMOTE_SCRIPT=$(cat <<EOF
set -euo pipefail

sudo ip link set "$SF_APP_DEV" up
sudo ip addr replace "$PROXY_IP_CIDR" dev "$SF_APP_DEV"

sudo ovs-ofctl add-flow "$BRIDGE" "priority=210,arp,in_port=$VF_REP,arp_tpa=$PROXY_IP,actions=output:$SF_REP"
sudo ovs-ofctl add-flow "$BRIDGE" "priority=210,tcp,in_port=$VF_REP,nw_dst=$PROXY_IP,tp_dst=$PROXY_PORT,actions=output:$SF_REP"
sudo ovs-ofctl add-flow "$BRIDGE" "priority=210,arp,in_port=$SF_REP,actions=output:$VF_REP"
sudo ovs-ofctl add-flow "$BRIDGE" "priority=210,ip,in_port=$SF_REP,nw_dst=$GUEST_IP,actions=output:$VF_REP"

echo "=== DPU managed-proxy path configured ==="
ip -o -4 addr show dev "$SF_APP_DEV"
sudo ovs-ofctl dump-flows "$BRIDGE"
EOF
)

log "Configuring DPU managed-proxy path on $DPU_SSH_TARGET"
log "  bridge:     $BRIDGE"
log "  vf rep:     $VF_REP"
log "  sf rep:     $SF_REP"
log "  sf app dev: $SF_APP_DEV"
log "  proxy ip:   $PROXY_IP_CIDR"
log "  guest ip:   $GUEST_IP"

ssh $DPU_SSH_OPTS "$DPU_SSH_TARGET" "$REMOTE_SCRIPT"

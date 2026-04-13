#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# test-dpu-software-nat.sh
#
# Host-side wrapper that applies the PF1 CT/NAT experiment on the DPU in
# pure software mode. This avoids requiring the OpenShellBF repo to exist
# on the DPU filesystem.

set -euo pipefail

SCRIPT_NAME="dpu-sw-nat"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Usage: sudo ./scripts/test-dpu-software-nat.sh [OPTIONS]

Runs the PF1 OVS CT/NAT test on the DPU with hw-offload disabled.

Options:
  --dpu-host <host>   DPU SSH host (default: ${DPU_HOST})
  --dpu-user <user>   DPU SSH user (default: ${DPU_USER})
  --help              Show this help

Run this on the host. It will SSH to the DPU and:
  1. disable OVS hardware offload
  2. restart OVS
  3. reattach PF1 ports to ovsbr2
  4. install the original CT/NAT flows in software mode
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

restart_ovs() {
    systemctl restart openvswitch-switch 2>/dev/null || systemctl restart openvswitch
}

ovs-vsctl --if-exists del-port ovsbr2 nat0

nft delete table inet debug 2>/dev/null || true
nft delete table inet ctdebug 2>/dev/null || true
iptables -t raw -D PREROUTING -i nat0 -s 10.99.2.0/24 -j CT --zone 1 2>/dev/null || true

ovs-vsctl set Open_vSwitch . other_config:hw-offload=false
restart_ovs

ovs-vsctl --may-exist add-port ovsbr2 p1
ovs-vsctl --may-exist add-port ovsbr2 pf1vf0
ovs-vsctl --may-exist add-port ovsbr2 pf1hpf
ovs-vsctl --may-exist add-port ovsbr2 en3f1pf1sf0

ovs-ofctl del-flows ovsbr2
ovs-ofctl add-flow ovsbr2 "table=0,priority=1000,arp,actions=normal"
ovs-ofctl add-flow ovsbr2 "table=0,priority=900,in_port=pf1hpf,actions=normal"
ovs-ofctl add-flow ovsbr2 "table=0,priority=900,in_port=en3f1pf1sf0,actions=normal"
ovs-ofctl add-flow ovsbr2 "table=0,priority=900,in_port=p1,ip,nw_dst=10.185.99.0/24,actions=normal"
ovs-ofctl add-flow ovsbr2 "table=0,priority=500,ip,in_port=pf1vf0,actions=ct(table=1,nat)"
ovs-ofctl add-flow ovsbr2 "table=0,priority=500,ip,in_port=p1,actions=ct(table=1,nat)"
ovs-ofctl add-flow ovsbr2 "table=0,priority=0,actions=drop"
ovs-ofctl add-flow ovsbr2 "table=1,priority=100,ip,ct_state=+trk+new,in_port=pf1vf0,actions=ct(commit,nat(src=10.185.99.182)),output:p1"
ovs-ofctl add-flow ovsbr2 "table=1,priority=100,ip,ct_state=+trk+est,in_port=pf1vf0,actions=output:p1"
ovs-ofctl add-flow ovsbr2 "table=1,priority=100,ip,ct_state=+trk+est,in_port=p1,actions=output:pf1vf0"
ovs-ofctl add-flow ovsbr2 "table=1,priority=0,actions=drop"

echo "=== DPU software CT/NAT flows installed ==="
ovs-ofctl dump-flows ovsbr2
EOF
)

if [[ "$KEEP_MASTER" != "true" ]]; then
    stop_master
    trap stop_master EXIT
fi
ensure_master

log "Applying PF1 software-mode CT/NAT test on DPU $SSH_TARGET..."
log "  SSH opts: $DPU_SSH_OPTS"
ssh "${SSH_OPTS_ARR[@]}" "$SSH_TARGET" "sudo bash -s" <<<"$REMOTE_SCRIPT"

echo ""
log "Next on the DPU, watch traffic in two terminals:"
log "  sudo tcpdump -i pf1vf0 -n 'host 160.79.104.10 and tcp port 443' -c 20"
log "  sudo tcpdump -i p1 -n 'host 160.79.104.10 and tcp port 443' -c 20"
echo ""
log "Then on the host, run:"
log "  sudo $OPENSHELL_VM_BIN exec -- python3 -c \"import socket; s=socket.socket(); s.settimeout(5); s.bind(('10.99.2.2', 0));"
log "  try: s.connect(('160.79.104.10', 443)); print('CONNECTED')"
log "  except Exception as e: print(e)"
log "  finally: s.close()\""
echo ""
log "After the test, on the DPU run:"
log "  sudo ovs-ofctl dump-flows ovsbr2"
log "  sudo conntrack -L | grep -E '10.99.2.2|10.185.99.182|160.79.104.10'"

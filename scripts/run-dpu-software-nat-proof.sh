#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# run-dpu-software-nat-proof.sh
#
# One-shot host-side harness for the PF1 software-mode CT/NAT experiment.
# It:
#   1. configures the DPU for software OVS CT/NAT
#   2. starts remote tcpdump captures on pf1vf0 and p1
#   3. triggers a single VM connect test from the host
#   4. fetches DPU tcpdump / flow / conntrack output

set -euo pipefail

SCRIPT_NAME="dpu-sw-proof"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

usage() {
    cat <<EOF
Usage: sudo ./scripts/run-dpu-software-nat-proof.sh [OPTIONS]

Runs the PF1 software-mode OVS CT/NAT proof end-to-end from the host.

Options:
  --dest-ip <ip>     Test destination IP (default: 160.79.104.10)
  --dest-port <p>    Test destination TCP port (default: 443)
  --timeout <sec>    Tcpdump timeout (default: 12)
  --dpu-host <host>  DPU SSH host (default: ${DPU_HOST})
  --dpu-user <user>  DPU SSH user (default: ${DPU_USER})
  --help             Show this help
EOF
    exit 0
}

DEST_IP="${DEST_IP:-160.79.104.10}"
DEST_PORT="${DEST_PORT:-443}"
CAPTURE_TIMEOUT="${CAPTURE_TIMEOUT:-12}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest-ip) DEST_IP="$2"; shift 2 ;;
        --dest-port) DEST_PORT="$2"; shift 2 ;;
        --timeout) CAPTURE_TIMEOUT="$2"; shift 2 ;;
        --dpu-host) DPU_HOST="$2"; shift 2 ;;
        --dpu-user) DPU_USER="$2"; shift 2 ;;
        --help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

require_root

SSH_TARGET="${DPU_USER}@${DPU_HOST}"
IFS=' ' read -r -a SSH_OPTS_ARR <<<"$DPU_SSH_OPTS"

ssh_dpu() {
    ssh "${SSH_OPTS_ARR[@]}" "$SSH_TARGET" "$@"
}

ensure_master() {
    ssh "${SSH_OPTS_ARR[@]}" -O check "$SSH_TARGET" >/dev/null 2>&1 \
        || ssh "${SSH_OPTS_ARR[@]}" -fN "$SSH_TARGET"
}

stop_master() {
    ssh "${SSH_OPTS_ARR[@]}" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true
}

stop_master
ensure_master
trap stop_master EXIT

log "Step 1/4: configure DPU for software-mode OVS CT/NAT"
DPU_SSH_KEEP_MASTER=true "$SCRIPT_DIR/test-dpu-software-nat.sh" --dpu-host "$DPU_HOST" --dpu-user "$DPU_USER"

log "Step 2/4: start remote captures on DPU"
REMOTE_DIR=$(ssh_dpu "mktemp -d /tmp/openshell-sw-proof.XXXXXX")
log "  Capture dir: $REMOTE_DIR"

ssh_dpu "sudo bash -lc '
timeout ${CAPTURE_TIMEOUT}s tcpdump -nn -i pf1vf0 \"host ${DEST_IP} and tcp port ${DEST_PORT}\" > ${REMOTE_DIR}/pf1vf0.txt 2>&1 &
timeout ${CAPTURE_TIMEOUT}s tcpdump -nn -i p1 \"host ${DEST_IP} and tcp port ${DEST_PORT}\" > ${REMOTE_DIR}/p1.txt 2>&1 &
wait
'" >/dev/null 2>&1 &
CAPTURE_WRAPPER_PID=$!

sleep 1

log "Step 3/4: trigger VM connect test from host"
set +e
VM_OUTPUT=$("$OPENSHELL_VM_BIN" exec -- python3 -c "
import socket
s = socket.socket()
s.settimeout(5)
s.bind(('10.99.2.2', 0))
try:
    s.connect(('${DEST_IP}', ${DEST_PORT}))
    print('CONNECTED')
except Exception as e:
    print(e)
finally:
    s.close()
" 2>&1)
VM_RC=$?
set -e

log "  VM test exit code: $VM_RC"
printf '%s\n' "$VM_OUTPUT"

log "Step 4/4: collect DPU results"
wait "$CAPTURE_WRAPPER_PID" || true

echo
echo "=== DPU tcpdump: pf1vf0 ==="
ssh_dpu "cat ${REMOTE_DIR}/pf1vf0.txt 2>/dev/null || true"
echo
echo "=== DPU tcpdump: p1 ==="
ssh_dpu "cat ${REMOTE_DIR}/p1.txt 2>/dev/null || true"
echo
echo "=== DPU ovsbr2 flows ==="
ssh_dpu "sudo ovs-ofctl dump-flows ovsbr2"
echo
echo "=== DPU conntrack ==="
ssh_dpu "sudo conntrack -L 2>/dev/null | grep -E '10.99.2.2|10.185.99.182|${DEST_IP}' || true"

ssh_dpu "rm -rf ${REMOTE_DIR}" >/dev/null 2>&1 || true

echo
log "Done."

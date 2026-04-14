#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# check-dpu-managed-proxy-mvp.sh
#
# Host-side helper that inspects the BF3 managed-proxy MVP state on the DPU.

set -euo pipefail

SCRIPT_NAME="dpu-managed-proxy-check"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DPU_SSH_TARGET="${DPU_SSH_TARGET:-bf-dpu}"
SANDBOX_ID="${SANDBOX_ID:-}"
PROXY_LISTEN="${PROXY_LISTEN:-10.99.2.1:3128}"
BRIDGE="${BRIDGE:-ovsbr1}"
VF_REP="${VF_REP:-pf0vf0}"
SF_REP="${SF_REP:-en3f0pf0sf0}"
SF_APP_DEV="${SF_APP_DEV:-enp3s0f0s0}"

usage() {
    cat <<'EOF'
Usage: ./check-dpu-managed-proxy-mvp.sh [OPTIONS]

Inspect the DPU listener, logs, and OVS state for the managed-proxy MVP.

Options:
  --host <target>       DPU SSH target                (default: bf-dpu)
  --sandbox-id <id>     Sandbox id used by DPU stack  (required)
  --listen <addr>       Proxy listen address          (default: 10.99.2.1:3128)
  --bridge <name>       OVS bridge                    (default: ovsbr1)
  --vf-rep <name>       VF representor port           (default: pf0vf0)
  --sf-rep <name>       SF representor port           (default: en3f0pf0sf0)
  --sf-app <dev>        SF application netdev         (default: enp3s0f0s0)
  --help                Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       DPU_SSH_TARGET="$2"; shift 2 ;;
        --sandbox-id) SANDBOX_ID="$2"; shift 2 ;;
        --listen)     PROXY_LISTEN="$2"; shift 2 ;;
        --bridge)     BRIDGE="$2"; shift 2 ;;
        --vf-rep)     VF_REP="$2"; shift 2 ;;
        --sf-rep)     SF_REP="$2"; shift 2 ;;
        --sf-app)     SF_APP_DEV="$2"; shift 2 ;;
        --help)       usage ;;
        *)            die "Unknown option: $1" ;;
    esac
done

[[ -n "$SANDBOX_ID" ]] || die "--sandbox-id is required"

PROXY_HOST="${PROXY_LISTEN%:*}"
PROXY_PORT="${PROXY_LISTEN##*:}"
OUT_DIR="/home/ubuntu/openshell-dpu/${SANDBOX_ID}"

REMOTE_SCRIPT=$(cat <<EOF
set -euo pipefail

echo "=== DPU proxy IP ==="
ip -o -4 addr show dev "$SF_APP_DEV" || true
echo

echo "=== DPU listening sockets ==="
ss -tlnp 2>/dev/null | grep -E "(:$PROXY_PORT\\b|127.0.0.1:8181\\b)" || true
echo

echo "=== DPU process list ==="
{
    pgrep -a -f '[o]penshell-dpu-proxy' || true
    pgrep -a -f '[o]penshell-dpu-agent' || true
    pgrep -a -f "[o]pa run --server --addr 127.0.0.1:8181" || true
} | sort -u
echo

echo "=== DPU proxy TCP probe ==="
timeout 2 bash -lc "echo >/dev/tcp/$PROXY_HOST/$PROXY_PORT" && echo "proxy port open" || echo "proxy port closed"
echo

echo "=== DPU OVS flows ($BRIDGE) ==="
sudo ovs-ofctl dump-flows "$BRIDGE" | grep -E "$VF_REP|$SF_REP|$PROXY_PORT|arp_tpa=$PROXY_HOST" || true
echo

echo "=== DPU state.json ==="
cat "$OUT_DIR/state.json" 2>/dev/null || true
echo

echo "=== DPU agent log ==="
tail -n 80 "$OUT_DIR/logs/dpu-agent-$SANDBOX_ID.log" 2>/dev/null || true
echo

echo "=== DPU OPA log ==="
tail -n 80 "$OUT_DIR/logs/opa-$SANDBOX_ID.log" 2>/dev/null || true
echo

echo "=== DPU proxy log ==="
tail -n 80 "$OUT_DIR/logs/dpu-proxy-$SANDBOX_ID.log" 2>/dev/null || true
EOF
)

log "Inspecting DPU managed-proxy MVP on $DPU_SSH_TARGET"
log "  sandbox_id: $SANDBOX_ID"
log "  listen:     $PROXY_LISTEN"

ssh $DPU_SSH_OPTS "$DPU_SSH_TARGET" "$REMOTE_SCRIPT"

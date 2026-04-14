#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# stop-dpu-managed-proxy-mvp.sh
#
# Host-side helper that stops the BF3 managed-proxy MVP processes on the DPU.

set -euo pipefail

SCRIPT_NAME="dpu-managed-proxy-stop"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DPU_SSH_TARGET="${DPU_SSH_TARGET:-bf-dpu}"
SANDBOX_ID="${SANDBOX_ID:-}"

usage() {
    cat <<'EOF'
Usage: ./stop-dpu-managed-proxy-mvp.sh [OPTIONS]

Stop OPA and openshell-dpu-proxy processes started for the managed-proxy MVP.

Options:
  --host <target>      DPU SSH target      (default: bf-dpu)
  --sandbox-id <id>    Sandbox id suffix used in log filenames (optional)
  --help               Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       DPU_SSH_TARGET="$2"; shift 2 ;;
        --sandbox-id) SANDBOX_ID="$2"; shift 2 ;;
        --help)       usage ;;
        *)            die "Unknown option: $1" ;;
    esac
done

REMOTE_SCRIPT='
set -euo pipefail
pkill -x "openshell-dpu-proxy" 2>/dev/null || true
pkill -x "opa" 2>/dev/null || true
echo "Stopped DPU managed-proxy MVP processes."
'

if [[ -n "$SANDBOX_ID" ]]; then
    log "Stopping DPU managed proxy MVP on $DPU_SSH_TARGET (sandbox_id=$SANDBOX_ID)"
else
    log "Stopping DPU managed proxy MVP on $DPU_SSH_TARGET"
fi

ssh $DPU_SSH_OPTS "$DPU_SSH_TARGET" "$REMOTE_SCRIPT"

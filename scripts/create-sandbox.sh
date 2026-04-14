#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# create-sandbox.sh
#
# Creates a sandbox against the microVM gateway. Does NOT require sudo —
# the mTLS certs should already be in the ubuntu user's config directory
# (copied by start-microvm.sh).
#
# Usage:
#   ./create-sandbox.sh [OPTIONS] [-- COMMAND...]
#
# Options:
#   --name <name>       Sandbox name (auto-generated if omitted)
#   --from <image>      Sandbox source image
#   --policy <path>     Path to policy YAML (default: policies/web-readonly.yaml)
#   --keep              Keep the sandbox after the initial shell / command exits
#   --no-keep           Delete sandbox when command exits
#   --help              Show this help
#
# Examples:
#   ./create-sandbox.sh --name dev
#   ./create-sandbox.sh --policy ../policies/lockdown.yaml --name offline-compute
#   ./create-sandbox.sh --policy ../policies/api-allow.yaml -- python3 agent.py
#   ./create-sandbox.sh --no-keep -- curl -s https://example.com

set -euo pipefail

SCRIPT_NAME="sandbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────
NAME=""
FROM=""
POLICY=""
NO_KEEP=false
KEEP=false
EXTRA_ARGS=()

# ── Usage ─────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: ./create-sandbox.sh [OPTIONS] [-- COMMAND...]

Creates a sandbox against the microVM gateway.

Options:
  --name <name>       Sandbox name (auto-generated if omitted)
  --from <image>      Sandbox source image
  --policy <path>     Path to policy YAML (default: policies/web-readonly.yaml)
  --keep              Keep the sandbox after the initial shell / command exits
  --no-keep           Delete sandbox when command exits
  --help              Show this help

Examples:
  ./create-sandbox.sh --name dev
  ./create-sandbox.sh --policy ../policies/lockdown.yaml --name offline
  ./create-sandbox.sh --no-keep -- curl -s https://example.com
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)    NAME="$2";    shift 2 ;;
        --from)    FROM="$2";    shift 2 ;;
        --policy)  POLICY="$2";  shift 2 ;;
        --keep)    KEEP=true;    shift ;;
        --no-keep) NO_KEEP=true; shift ;;
        --help)    usage ;;
        --)        shift; EXTRA_ARGS=("$@"); break ;;
        *)         die "Unknown option: $1. Use -- before sandbox commands." ;;
    esac
done

# ── Prerequisite checks ──────────────────────────────────────────────────
[[ -x "$OPENSHELL_CLI" ]] \
    || die "openshell CLI not found at $OPENSHELL_CLI."

# Check mTLS certs exist
if [[ ! -f "$USER_CONFIG/mtls/ca.crt" ]]; then
    die "mTLS certs not found at $USER_CONFIG/mtls/. Run start-microvm.sh first (it copies certs from /root/)."
fi

# TCP probe to gateway
log "Checking gateway at 127.0.0.1:$GATEWAY_PORT..."
if ! tcp_probe 127.0.0.1 "$GATEWAY_PORT" 3; then
    die "Gateway not reachable at 127.0.0.1:$GATEWAY_PORT. Is the microVM running? Run start-microvm.sh first."
fi
log "Gateway reachable."

# ── Resolve policy ────────────────────────────────────────────────────────
if [[ -z "$POLICY" ]]; then
    POLICY="$POLICY_DIR/web-readonly.yaml"
    log "No --policy specified. Using default: $POLICY"
fi

if [[ ! -f "$POLICY" ]]; then
    die "Policy file not found: $POLICY"
fi

log "Policy: $POLICY"

# ── Build command ─────────────────────────────────────────────────────────
CMD=("$OPENSHELL_CLI" sandbox create
    --gateway "$GATEWAY_NAME"
    --policy "$POLICY"
    --no-bootstrap
)

[[ -n "$NAME" ]] && CMD+=(--name "$NAME")
[[ -n "$FROM" ]] && CMD+=(--from "$FROM")
$KEEP && CMD+=(--keep)
$NO_KEEP && CMD+=(--no-keep)

if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    CMD+=(-- "${EXTRA_ARGS[@]}")
fi

echo ""
log "Creating sandbox..."
log "  Command: ${CMD[*]}"
echo ""

# ── Execute (interactive — passes through stdin/stdout) ───────────────────
exec "${CMD[@]}"

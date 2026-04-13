#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# start-microvm.sh
#
# Cleans stale state, then boots the openshell-vm microVM gateway.
# After the gateway is healthy, copies mTLS certs to the ubuntu user's
# config directory so the CLI can create sandboxes without sudo.
#
# Usage:
#   sudo ./start-microvm.sh [OPTIONS]
#
# Options:
#   --with-vf-bridge   Start vf-bridge first and wire guest eth1 through DPU
#   --reset            Wipe all runtime state (containerd, kubelet, k3s, PKI)
#   --keep-certs       Do NOT wipe mTLS certs (attempt warm boot)
#   --help             Show this help
#
# The microVM runs in the foreground. Press Ctrl+C to stop it cleanly.
# A background watcher copies mTLS certs once "Gateway healthy" appears in the log.

set -euo pipefail

SCRIPT_NAME="microvm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────
WITH_VF_BRIDGE=false
RESET=false
KEEP_CERTS=false

# ── Usage ─────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: sudo ./start-microvm.sh [OPTIONS]

Boots the openshell-vm microVM gateway with clean state.

Options:
  --with-vf-bridge   Start vf-bridge first, wire guest eth1 through DPU
  --reset            Wipe all runtime state before boot
  --keep-certs       Skip mTLS cert cleanup (warm boot)
  --help             Show this help

The gateway runs in the foreground. Press Ctrl+C to stop.
After the gateway is healthy, mTLS certs are copied to the ubuntu user's
config so 'openshell sandbox create' works without sudo.
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-vf-bridge) WITH_VF_BRIDGE=true; shift ;;
        --reset)          RESET=true;          shift ;;
        --keep-certs)     KEEP_CERTS=true;     shift ;;
        --help)           usage ;;
        *)                die "Unknown option: $1" ;;
    esac
done

# ── Prerequisite checks ──────────────────────────────────────────────────
require_root

[[ -x "$OPENSHELL_VM_BIN" ]] \
    || die "openshell-vm not found at $OPENSHELL_VM_BIN. Build it first."
[[ -d "$ROOTFS" ]] \
    || die "Rootfs not found at $ROOTFS."

# ── Step 1: Kill stale processes ─────────────────────────────────────────
log "Cleaning stale processes..."
kill_stale openshell-vm
kill_stale gvproxy

# Verify port is free
if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
    warn "Port $GATEWAY_PORT still in use. Waiting 3s..."
    sleep 3
    if ss -tlnp 2>/dev/null | grep -q ":${GATEWAY_PORT} "; then
        die "Port $GATEWAY_PORT still in use after cleanup. Check: ss -tlnp | grep $GATEWAY_PORT"
    fi
fi
log "Port $GATEWAY_PORT is free."

# ── Step 2: Clean stale state files ──────────────────────────────────────
log "Cleaning stale state files..."
rm_if_exists "$INSTANCE_DIR"/rootfs-*-vm-state.json
rm_if_exists "$INSTANCE_DIR"/rootfs-*.vm.lock
rm_if_exists /tmp/ovm-exec/*.sock

# ── Step 3: Clean mTLS certs (force cold boot) ───────────────────────────
if $KEEP_CERTS; then
    log "Keeping existing mTLS certs (warm boot)."
else
    log "Cleaning mTLS certs (will cold-boot with fresh PKI)..."
    rm_if_exists "$ROOT_CONFIG"
    rm_if_exists "$USER_CONFIG"
fi

# ── Step 4: Optionally start vf-bridge ────────────────────────────────────
if $WITH_VF_BRIDGE; then
    if [[ -S "$SOCKET_PATH" ]]; then
        log "vf-bridge socket already exists at $SOCKET_PATH — reusing."
    else
        log "Starting vf-bridge..."
        "$SCRIPT_DIR/start-vf-bridge.sh"
        # Verify socket appeared
        sleep 1
        [[ -S "$SOCKET_PATH" ]] || die "vf-bridge socket not found at $SOCKET_PATH after startup."
        log "vf-bridge ready."
    fi
fi

# ── Step 5: Build openshell-vm command ────────────────────────────────────
CMD=("$OPENSHELL_VM_BIN" --rootfs "$ROOTFS")

if $WITH_VF_BRIDGE; then
    CMD+=(--protected-egress-socket "$SOCKET_PATH")
fi

if $RESET; then
    CMD+=(--reset)
fi

# ── Step 6: Prepare log directory ─────────────────────────────────────────
mkdir -p "$LOG_DIR" "$PID_DIR"
VM_LOG="$LOG_DIR/openshell-vm.log"

log "Starting microVM gateway..."
log "  Command: ${CMD[*]}"
log "  Log:     $VM_LOG"
log "  Port:    $GATEWAY_PORT"
echo ""

# ── Step 7: Background cert-copy watcher ──────────────────────────────────
# Monitors the log for "Gateway healthy" and then copies mTLS certs to the
# ubuntu user's config directory so the CLI works without sudo.
(
    # Wait for the cert directory to appear (up to 180s)
    waited=0
    while [[ $waited -lt 180 ]]; do
        if [[ -f "$ROOT_CONFIG/mtls/ca.crt" && -f "$ROOT_CONFIG/mtls/tls.crt" && -f "$ROOT_CONFIG/mtls/tls.key" ]]; then
            break
        fi
        sleep 2
        (( waited += 2 ))
    done

    if [[ ! -f "$ROOT_CONFIG/mtls/ca.crt" ]]; then
        echo "[$(date +%T)] [cert-sync] WARN: mTLS certs not found after 180s — skipping copy." >&2
        exit 0
    fi

    # Copy certs to ubuntu user's config
    mkdir -p "$USER_CONFIG/mtls"
    cp "$ROOT_CONFIG/mtls/ca.crt"  "$USER_CONFIG/mtls/ca.crt"
    cp "$ROOT_CONFIG/mtls/tls.crt" "$USER_CONFIG/mtls/tls.crt"
    cp "$ROOT_CONFIG/mtls/tls.key" "$USER_CONFIG/mtls/tls.key"

    # Copy metadata if present
    if [[ -f "$ROOT_CONFIG/metadata.json" ]]; then
        cp "$ROOT_CONFIG/metadata.json" "$USER_CONFIG/metadata.json"
    fi

    # Fix ownership
    chown -R ubuntu:ubuntu "$USER_CONFIG"

    echo "[$(date +%T)] [cert-sync] mTLS certs copied to $USER_CONFIG/mtls/"
    echo "[$(date +%T)] [cert-sync] You can now run: ./create-sandbox.sh --name test"
) &
CERT_WATCHER_PID=$!

# ── Step 8: Launch openshell-vm (foreground) ──────────────────────────────
# Run in foreground with tee so the user sees output AND we capture a log.
# The cert watcher runs in the background.
"${CMD[@]}" 2>&1 | tee "$VM_LOG"
VM_EXIT=$?

# Clean up cert watcher
kill "$CERT_WATCHER_PID" 2>/dev/null || true

if [[ $VM_EXIT -ne 0 ]]; then
    echo ""
    warn "openshell-vm exited with code $VM_EXIT."
    warn "Check log: $VM_LOG"
fi

exit $VM_EXIT

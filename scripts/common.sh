#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# common.sh — Shared constants, logging, and helper functions for OpenShellBF scripts.
# Source this file; do not execute directly.

# ── Guard ─────────────────────────────────────────────────────────────────
[[ "${BASH_SOURCE[0]}" == "$0" ]] && { echo "Source this file, don't run it."; exit 1; }

# ── Script identity (set by the sourcing script) ─────────────────────────
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "${BASH_SOURCE[1]}" .sh)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

# ── Paths — all overridable via environment ───────────────────────────────

# BlueField-3 hardware — PF0 is the protected sandbox egress lane for the
# managed-proxy MVP (`pf0vf0` on `ovsbr1`, DPU protected IP 10.99.2.1).
PF_PCI="${PF_PCI:-0000:b3:00.0}"
PF_DEV="${PF_DEV:-enp179s0f0np0}"
VF_MAC="${VF_MAC:-52:54:00:aa:bb:cc}"

# Binaries
VF_BRIDGE_BIN="${VF_BRIDGE_BIN:-/home/ubuntu/work/OpenShell/target/debug/vf-bridge}"
OPENSHELL_VM_BIN="${OPENSHELL_VM_BIN:-/home/ubuntu/work/OpenShell/target/debug/openshell-vm}"
OPENSHELL_CLI="${OPENSHELL_CLI:-/home/ubuntu/.local/bin/openshell}"

# vf-bridge socket
SOCKET_PATH="${SOCKET_PATH:-/run/openshell/vf-bridge/eth1.sock}"

# MicroVM rootfs and instance directory
INSTANCE_DIR="${INSTANCE_DIR:-/home/ubuntu/.local/share/openshell/openshell-vm/0.0.28-dev.3+gdafb7996a/instances/default}"
ROOTFS="${ROOTFS:-${INSTANCE_DIR}/rootfs}"

# Gateway identity
GATEWAY_NAME="${GATEWAY_NAME:-openshell-vm-default}"
GATEWAY_PORT="${GATEWAY_PORT:-30051}"

# DPU access
DPU_HOST="${DPU_HOST:-192.168.100.2}"
DPU_USER="${DPU_USER:-ubuntu}"
DPU_SSH_OPTS="${DPU_SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ControlMaster=auto -o ControlPersist=120 -o ControlPath=/tmp/openshellbf-dpu-%r@%h:%p}"

# Logging
LOG_DIR="${LOG_DIR:-/var/log/openshell}"

# mTLS cert locations
ROOT_CONFIG="${ROOT_CONFIG:-/root/.config/openshell/gateways/${GATEWAY_NAME}}"
USER_CONFIG="${USER_CONFIG:-/home/ubuntu/.config/openshell/gateways/${GATEWAY_NAME}}"

# Policies
POLICY_DIR="${POLICY_DIR:-$(cd "$SCRIPT_DIR/../policies" 2>/dev/null && pwd)}"

# PID files
PID_DIR="${PID_DIR:-/run/openshell}"

# ── Logging ───────────────────────────────────────────────────────────────
log()  { echo "[$(date +%T)] [$SCRIPT_NAME] $*"; }
warn() { echo "[$(date +%T)] [$SCRIPT_NAME] WARN: $*" >&2; }
die()  { echo "[$(date +%T)] [$SCRIPT_NAME] ERROR: $*" >&2; exit 1; }

# ── Prerequisite checks ──────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "Must run as root (sudo)."
}

# ── Process helpers ───────────────────────────────────────────────────────

# kill_stale <process-name>
#   Sends SIGTERM, waits up to 3 s, then SIGKILL if still alive.
#   Uses plain pgrep (matches process name only, NOT full command line)
#   so "vf-bridge" matches the binary but not "start-vf-bridge.sh".
kill_stale() {
    local name="$1"
    local pids
    pids=$(pgrep -x "$name" 2>/dev/null || true)
    [[ -z "$pids" ]] && return 0

    log "Killing stale $name (PIDs: $(echo $pids | tr '\n' ' '))..."
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done
    local waited=0
    while [[ $waited -lt 3 ]]; do
        pids=$(pgrep -x "$name" 2>/dev/null || true)
        [[ -z "$pids" ]] && { log "  $name stopped."; return 0; }
        sleep 1
        (( waited++ ))
    done
    # Force kill remaining
    pids=$(pgrep -x "$name" 2>/dev/null || true)
    for pid in $pids; do
        kill -9 "$pid" 2>/dev/null || true
    done
    sleep 0.5
    pids=$(pgrep -x "$name" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        warn "$name still alive after SIGKILL — manual intervention needed."
    else
        log "  $name force-killed."
    fi
}

# ── File helpers ──────────────────────────────────────────────────────────

# rm_if_exists <path> [<path>...]
#   Removes files/directories if they exist, logs each removal.
rm_if_exists() {
    for p in "$@"; do
        if [[ -e "$p" || -S "$p" ]]; then
            rm -rf "$p" 2>/dev/null || true
            log "  Removed: $p"
        fi
    done
}

# ── Network helpers ───────────────────────────────────────────────────────

# tcp_probe <host> <port> [timeout_s]
#   Returns 0 if a TCP connection succeeds, 1 otherwise.
tcp_probe() {
    local host="$1" port="$2" timeout="${3:-2}"
    timeout "$timeout" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null
}

# wait_for_port <host> <port> <max_seconds> [label]
#   Polls until TCP port is reachable or timeout expires.
wait_for_port() {
    local host="$1" port="$2" max="$3" label="${4:-port $2}"
    local elapsed=0
    while [[ $elapsed -lt $max ]]; do
        if tcp_probe "$host" "$port"; then
            log "$label reachable after ${elapsed}s."
            return 0
        fi
        sleep 1
        (( elapsed++ ))
    done
    die "$label not reachable after ${max}s — giving up."
}

# ── Trap helper ───────────────────────────────────────────────────────────

# _cleanup_pids is populated by scripts; cleanup_on_exit kills them.
_CLEANUP_PIDS=()

register_cleanup_pid() {
    _CLEANUP_PIDS+=("$1")
}

cleanup_on_exit() {
    log "Caught signal — cleaning up..."
    for pid in "${_CLEANUP_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            log "  Stopping PID $pid..."
            kill "$pid" 2>/dev/null || true
        fi
    done
    # Give children a moment, then force
    sleep 1
    for pid in "${_CLEANUP_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    done
    log "Cleanup done."
}

setup_trap() {
    trap cleanup_on_exit SIGINT SIGTERM EXIT
}

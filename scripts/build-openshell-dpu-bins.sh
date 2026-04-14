#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# build-openshell-dpu-bins.sh
#
# Build the BF3 DPU-facing OpenShell binaries natively on the DPU after a clean
# source checkout has been staged there.

set -euo pipefail

SCRIPT_NAME="build-openshell-dpu"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DPU_SSH_TARGET="${DPU_SSH_TARGET:-bf-dpu}"
REMOTE_SOURCE="${REMOTE_SOURCE:-/home/ubuntu/work/OpenShell}"
BUILD_MODE="debug"
CARGO_CMD="${CARGO_CMD:-\$HOME/.cargo/bin/cargo}"

usage() {
    cat <<'EOF'
Usage: ./build-openshell-dpu-bins.sh [OPTIONS]

Build openshell-dpu-agent and openshell-dpu-proxy natively on the DPU.

Options:
  --host <target>    SSH target for the DPU                 (default: bf-dpu)
  --source <path>    OpenShell source path on the DPU       (default: /home/ubuntu/work/OpenShell)
  --release          Build release binaries
  --cargo <path>     Cargo path on the DPU                  (default: $HOME/.cargo/bin/cargo)
  --help             Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)    DPU_SSH_TARGET="$2"; shift 2 ;;
        --source)  REMOTE_SOURCE="$2"; shift 2 ;;
        --release) BUILD_MODE="release"; shift ;;
        --cargo)   CARGO_CMD="$2"; shift 2 ;;
        --help)    usage ;;
        *)         die "Unknown option: $1" ;;
    esac
done

BUILD_FLAGS=""
if [[ "$BUILD_MODE" == "release" ]]; then
    BUILD_FLAGS="--release"
fi

log "Building OpenShell DPU binaries on $DPU_SSH_TARGET"
log "  source: $REMOTE_SOURCE"
log "  mode:   $BUILD_MODE"

ssh $DPU_SSH_OPTS "$DPU_SSH_TARGET" "\
    set -euo pipefail; \
    cd '$REMOTE_SOURCE'; \
    if [[ ! -x $CARGO_CMD ]]; then \
        echo 'cargo not found at $CARGO_CMD' >&2; \
        exit 1; \
    fi; \
    $CARGO_CMD build $BUILD_FLAGS -p openshell-sandbox --bin openshell-dpu-agent --bin openshell-dpu-proxy"

log "Build complete."
log "Expected binaries:"
if [[ "$BUILD_MODE" == "release" ]]; then
    log "  $REMOTE_SOURCE/target/release/openshell-dpu-agent"
    log "  $REMOTE_SOURCE/target/release/openshell-dpu-proxy"
else
    log "  $REMOTE_SOURCE/target/debug/openshell-dpu-agent"
    log "  $REMOTE_SOURCE/target/debug/openshell-dpu-proxy"
fi

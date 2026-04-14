#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# stage-openshell-on-dpu.sh
#
# Create a clean committed OpenShell source tree on the DPU for native aarch64
# builds. This clones the local host repo into a temporary clean checkout,
# rewrites origin back to GitHub, then copies that repo to the DPU over SSH.
#
# Default behavior keeps the DPU workdir aligned to the current committed branch
# on the host while deliberately excluding unrelated uncommitted local changes.

set -euo pipefail

SCRIPT_NAME="stage-openshell-dpu"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SOURCE_REPO="${SOURCE_REPO:-/home/ubuntu/work/OpenShell}"
DPU_SSH_TARGET="${DPU_SSH_TARGET:-bf-dpu}"
REMOTE_DEST="${REMOTE_DEST:-/home/ubuntu/work/OpenShell}"
KEEP_TMP=false
REF=""

usage() {
    cat <<'EOF'
Usage: ./stage-openshell-on-dpu.sh [OPTIONS]

Create a clean committed OpenShell checkout on the DPU for native ARM builds.

Options:
  --source <path>   Local OpenShell repo path          (default: /home/ubuntu/work/OpenShell)
  --ref <git-ref>   Commit/branch/tag to deploy        (default: current host branch HEAD)
  --host <target>   SSH target for the DPU             (default: bf-dpu)
  --dest <path>     Destination path on the DPU        (default: /home/ubuntu/work/OpenShell)
  --keep-tmp        Keep the temporary clean checkout for inspection
  --help            Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)   SOURCE_REPO="$2"; shift 2 ;;
        --ref)      REF="$2"; shift 2 ;;
        --host)     DPU_SSH_TARGET="$2"; shift 2 ;;
        --dest)     REMOTE_DEST="$2"; shift 2 ;;
        --keep-tmp) KEEP_TMP=true; shift ;;
        --help)     usage ;;
        *)          die "Unknown option: $1" ;;
    esac
done

[[ -d "$SOURCE_REPO/.git" ]] || die "Source repo not found: $SOURCE_REPO"
command -v git >/dev/null 2>&1 || die "git is required"
command -v tar >/dev/null 2>&1 || die "tar is required"
command -v ssh >/dev/null 2>&1 || die "ssh is required"

if [[ -z "$REF" ]]; then
    REF=$(env GIT_CONFIG_NOSYSTEM=1 git -C "$SOURCE_REPO" rev-parse --abbrev-ref HEAD)
fi

COMMIT=$(env GIT_CONFIG_NOSYSTEM=1 git -C "$SOURCE_REPO" rev-parse "${REF}^{commit}") \
    || die "Could not resolve ref: $REF"
REF_NAME=$(env GIT_CONFIG_NOSYSTEM=1 git -C "$SOURCE_REPO" rev-parse --abbrev-ref "$REF" 2>/dev/null || echo "HEAD")
REMOTE_URL=$(env GIT_CONFIG_NOSYSTEM=1 git -C "$SOURCE_REPO" remote get-url origin 2>/dev/null || true)

TMP_ROOT=$(mktemp -d /tmp/openshell-dpu-src.XXXXXX)
TMP_NAME="$(basename "$REMOTE_DEST")"
TMP_REPO="$TMP_ROOT/$TMP_NAME"

cleanup() {
    if ! $KEEP_TMP; then
        rm -rf "$TMP_ROOT"
    fi
}
trap cleanup EXIT

log "Preparing clean OpenShell checkout from $SOURCE_REPO"
log "  ref:    $REF"
log "  commit: $COMMIT"

env GIT_CONFIG_NOSYSTEM=1 git clone --quiet "$SOURCE_REPO" "$TMP_REPO"
env GIT_CONFIG_NOSYSTEM=1 git -C "$TMP_REPO" checkout --quiet "$COMMIT"

if [[ -n "$REMOTE_URL" ]]; then
    env GIT_CONFIG_NOSYSTEM=1 git -C "$TMP_REPO" remote set-url origin "$REMOTE_URL"
fi

if [[ "$REF_NAME" != "HEAD" ]]; then
    env GIT_CONFIG_NOSYSTEM=1 git -C "$TMP_REPO" checkout --quiet -B "$REF_NAME" "$COMMIT"
fi

echo "$COMMIT" > "$TMP_REPO/.openshell-source-commit"

REMOTE_PARENT="$(dirname "$REMOTE_DEST")"
REMOTE_NAME="$(basename "$REMOTE_DEST")"

log "Copying clean repo to DPU target $DPU_SSH_TARGET:$REMOTE_DEST"
tar -C "$TMP_ROOT" \
    --exclude="$TMP_NAME/target" \
    -cf - "$TMP_NAME" \
    | ssh $DPU_SSH_OPTS "$DPU_SSH_TARGET" \
        "mkdir -p '$REMOTE_PARENT' && rm -rf '$REMOTE_DEST' && tar -xf - -C '$REMOTE_PARENT'"

log "DPU workdir ready."
log "  target:  $REMOTE_DEST"
log "  commit:  $COMMIT"
if [[ -n "$REMOTE_URL" ]]; then
    log "  origin:  $REMOTE_URL"
fi
log "Next: ./scripts/build-openshell-dpu-bins.sh --host $DPU_SSH_TARGET --source $REMOTE_DEST"

if $KEEP_TMP; then
    log "Temporary checkout kept at: $TMP_REPO"
fi

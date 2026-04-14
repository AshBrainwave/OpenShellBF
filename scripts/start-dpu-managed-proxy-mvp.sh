#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# start-dpu-managed-proxy-mvp.sh
#
# Host-side helper that SSHes to the DPU, materializes per-sandbox policy and
# credentials with openshell-dpu-agent, then launches a local OPA daemon and
# the guest-facing openshell-dpu-proxy in TCP mode.

set -euo pipefail

SCRIPT_NAME="dpu-managed-proxy"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DPU_SSH_TARGET="${DPU_SSH_TARGET:-bf-dpu}"
REMOTE_SOURCE="${REMOTE_SOURCE:-/home/ubuntu/work/OpenShell}"
BUILD_MODE="${BUILD_MODE:-release}"
SANDBOX_ID="${SANDBOX_ID:-}"
OPENSHELL_ENDPOINT="${OPENSHELL_ENDPOINT:-}"
PROXY_LISTEN="${PROXY_LISTEN:-10.99.2.1:3128}"
OPA_ADDR="${OPA_ADDR:-127.0.0.1:8181}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
LOG_DIR_REMOTE="${LOG_DIR_REMOTE:-}"
TLS_CA="${TLS_CA:-}"
TLS_CERT="${TLS_CERT:-}"
TLS_KEY="${TLS_KEY:-}"
TLS_SERVER_NAME="${TLS_SERVER_NAME:-}"

usage() {
    cat <<'EOF'
Usage: ./start-dpu-managed-proxy-mvp.sh [OPTIONS]

Bring up the BF3 managed-proxy MVP on the DPU:
  1. run openshell-dpu-agent --oneshot
  2. start local OPA from the generated files
  3. start openshell-dpu-proxy in TCP mode

Options:
  --host <target>      DPU SSH target                      (default: bf-dpu)
  --source <path>      OpenShell source path on DPU       (default: /home/ubuntu/work/OpenShell)
  --debug              Use target/debug instead of release
  --sandbox-id <id>    Sandbox id to materialize          (required)
  --endpoint <url>     OpenShell gRPC endpoint            (required)
  --listen <addr>      Proxy listen address               (default: 10.99.2.1:3128)
  --opa-addr <addr>    OPA bind address                   (default: 127.0.0.1:8181)
  --output-dir <path>  DPU runtime output dir             (default: /var/lib/openshell-dpu/<sandbox>)
  --log-dir <path>     DPU log dir                        (default: /var/log/openshell-dpu)
  --tls-ca <path>      DPU-local CA cert path for gRPC mTLS
  --tls-cert <path>    DPU-local client cert path for gRPC mTLS
  --tls-key <path>     DPU-local client key path for gRPC mTLS
  --tls-server-name <name>
                      Optional TLS hostname/SNI override for gRPC
  --help               Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       DPU_SSH_TARGET="$2"; shift 2 ;;
        --source)     REMOTE_SOURCE="$2"; shift 2 ;;
        --debug)      BUILD_MODE="debug"; shift ;;
        --sandbox-id) SANDBOX_ID="$2"; shift 2 ;;
        --endpoint)   OPENSHELL_ENDPOINT="$2"; shift 2 ;;
        --listen)     PROXY_LISTEN="$2"; shift 2 ;;
        --opa-addr)   OPA_ADDR="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --log-dir)    LOG_DIR_REMOTE="$2"; shift 2 ;;
        --tls-ca)     TLS_CA="$2"; shift 2 ;;
        --tls-cert)   TLS_CERT="$2"; shift 2 ;;
        --tls-key)    TLS_KEY="$2"; shift 2 ;;
        --tls-server-name) TLS_SERVER_NAME="$2"; shift 2 ;;
        --help)       usage ;;
        *)            die "Unknown option: $1" ;;
    esac
done

[[ -n "$SANDBOX_ID" ]] || die "--sandbox-id is required"
[[ -n "$OPENSHELL_ENDPOINT" ]] || die "--endpoint is required"

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="/home/ubuntu/openshell-dpu/${SANDBOX_ID}"
fi
if [[ -z "$LOG_DIR_REMOTE" ]]; then
    LOG_DIR_REMOTE="$OUTPUT_DIR/logs"
fi

if [[ "$BUILD_MODE" == "release" ]]; then
    BIN_DIR="$REMOTE_SOURCE/target/release"
else
    BIN_DIR="$REMOTE_SOURCE/target/debug"
fi

PROXY_BIND_IP="${PROXY_LISTEN%:*}"

REMOTE_SCRIPT=$(cat <<EOF
set -euo pipefail

BIN_DIR="$BIN_DIR"
AGENT_BIN="\$BIN_DIR/openshell-dpu-agent"
PROXY_BIN="\$BIN_DIR/openshell-dpu-proxy"
OPA_BIN="\$(command -v opa || true)"

[[ -x "\$AGENT_BIN" ]] || { echo "openshell-dpu-agent not found at \$AGENT_BIN" >&2; exit 1; }
[[ -x "\$PROXY_BIN" ]] || { echo "openshell-dpu-proxy not found at \$PROXY_BIN" >&2; exit 1; }
[[ -n "\$OPA_BIN" ]] || { echo "opa binary not found on DPU PATH" >&2; exit 1; }
ip -o -4 addr show | grep -qw "$PROXY_BIND_IP" || {
    echo "DPU listen IP $PROXY_BIND_IP is not configured locally. Bring up the protected DPU IP before starting the proxy." >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR/opa" "$LOG_DIR_REMOTE"

pkill -f 'openshell-dpu-proxy' 2>/dev/null || true
pkill -f 'opa run --server --addr $OPA_ADDR' 2>/dev/null || true

export OPENSHELL_ENDPOINT='$OPENSHELL_ENDPOINT'
export OPENSHELL_SANDBOX_ID='$SANDBOX_ID'
export OPENSHELL_DPU_OUTPUT_DIR='$OUTPUT_DIR'
EOF
)

if [[ -n "$TLS_CA" ]]; then
    REMOTE_SCRIPT+=$'\n'"export OPENSHELL_TLS_CA='$TLS_CA'"
fi
if [[ -n "$TLS_CERT" ]]; then
    REMOTE_SCRIPT+=$'\n'"export OPENSHELL_TLS_CERT='$TLS_CERT'"
fi
if [[ -n "$TLS_KEY" ]]; then
    REMOTE_SCRIPT+=$'\n'"export OPENSHELL_TLS_KEY='$TLS_KEY'"
fi
if [[ -n "$TLS_SERVER_NAME" ]]; then
    REMOTE_SCRIPT+=$'\n'"export OPENSHELL_TLS_SERVER_NAME='$TLS_SERVER_NAME'"
fi

REMOTE_SCRIPT+=$(cat <<EOF

"\$AGENT_BIN" --oneshot --openshell-endpoint "$OPENSHELL_ENDPOINT" --sandbox-id "$SANDBOX_ID" --output-dir "$OUTPUT_DIR" \
    2>&1 | tee "$LOG_DIR_REMOTE/dpu-agent-$SANDBOX_ID.log"

nohup "\$OPA_BIN" run --server --addr "$OPA_ADDR" \
    "$OUTPUT_DIR/opa/policy.rego" "$OUTPUT_DIR/opa/data.json" \
    > "$LOG_DIR_REMOTE/opa-$SANDBOX_ID.log" 2>&1 &
OPA_PID=\$!

for _ in \$(seq 1 15); do
    if timeout 1 bash -lc "echo >/dev/tcp/${OPA_ADDR%:*}/${OPA_ADDR##*:}" 2>/dev/null; then
        break
    fi
    sleep 1
done

if ! timeout 1 bash -lc "echo >/dev/tcp/${OPA_ADDR%:*}/${OPA_ADDR##*:}" 2>/dev/null; then
    echo "OPA did not become reachable at $OPA_ADDR" >&2
    exit 1
fi

nohup "\$PROXY_BIN" \
    --mode tcp \
    --listen "$PROXY_LISTEN" \
    --opa-url "http://$OPA_ADDR" \
    --credentials "$OUTPUT_DIR/credentials.json" \
    --ca-cert-out "$OUTPUT_DIR/openshell-dpu-ca.crt" \
    > "$LOG_DIR_REMOTE/dpu-proxy-$SANDBOX_ID.log" 2>&1 &
PROXY_PID=\$!

sleep 2
kill -0 "\$OPA_PID" 2>/dev/null || { echo "OPA exited immediately" >&2; exit 1; }
kill -0 "\$PROXY_PID" 2>/dev/null || { echo "openshell-dpu-proxy exited immediately" >&2; exit 1; }

echo "=== DPU managed proxy MVP started ==="
echo "sandbox_id: $SANDBOX_ID"
echo "output_dir: $OUTPUT_DIR"
echo "proxy_listen: $PROXY_LISTEN"
echo "opa_addr: $OPA_ADDR"
echo "agent_log: $LOG_DIR_REMOTE/dpu-agent-$SANDBOX_ID.log"
echo "opa_log: $LOG_DIR_REMOTE/opa-$SANDBOX_ID.log"
echo "proxy_log: $LOG_DIR_REMOTE/dpu-proxy-$SANDBOX_ID.log"
echo "ca_cert: $OUTPUT_DIR/openshell-dpu-ca.crt"
echo "state: $OUTPUT_DIR/state.json"
EOF
)

log "Starting DPU managed proxy MVP on $DPU_SSH_TARGET"
log "  sandbox_id: $SANDBOX_ID"
log "  endpoint:   $OPENSHELL_ENDPOINT"
log "  listen:     $PROXY_LISTEN"
log "  output_dir: $OUTPUT_DIR"

ssh $DPU_SSH_OPTS "$DPU_SSH_TARGET" "$REMOTE_SCRIPT"

echo ""
log "Next verification from the guest / microVM:"
log "  export HTTPS_PROXY=http://$PROXY_LISTEN"
log "  curl -v --proxy http://$PROXY_LISTEN https://example.com/"
echo ""
log "DPU logs:"
log "  ssh $DPU_SSH_TARGET 'tail -f $LOG_DIR_REMOTE/dpu-agent-$SANDBOX_ID.log'"
log "  ssh $DPU_SSH_TARGET 'tail -f $LOG_DIR_REMOTE/opa-$SANDBOX_ID.log'"
log "  ssh $DPU_SSH_TARGET 'tail -f $LOG_DIR_REMOTE/dpu-proxy-$SANDBOX_ID.log'"

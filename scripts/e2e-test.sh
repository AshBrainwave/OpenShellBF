#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# e2e-test.sh
#
# End-to-end policy enforcement tests for the OpenShellBF microVM sandbox.
# Each test creates a --no-keep sandbox with a specific policy and runs a
# command that should either succeed or fail based on the policy.
#
# Usage:
#   ./e2e-test.sh [--test <name>|--all]
#
# Tests:
#   lockdown      Zero-network policy blocks all outbound
#   web-readonly  Read-only policy allows pip, blocks POST
#   api-allow     API policy allows Anthropic, blocks other hosts
#   dpu-enforced  DPU passthrough allows all (check DPU counters manually)
#   all           Run all tests (default)
#
# Prerequisites:
#   - MicroVM gateway running (start-microvm.sh)
#   - mTLS certs in ubuntu user config (done by start-microvm.sh)
#   - Policy files in ../policies/

set -euo pipefail

SCRIPT_NAME="e2e-test"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ── Test framework ────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
RESULTS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

record_pass() {
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    RESULTS+=("${GREEN}PASS${NC}  $1")
    echo -e "  ${GREEN}PASS${NC}  $1"
}

record_fail() {
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    RESULTS+=("${RED}FAIL${NC}  $1  ($2)")
    echo -e "  ${RED}FAIL${NC}  $1  ($2)"
}

record_skip() {
    SKIP_COUNT=$(( SKIP_COUNT + 1 ))
    RESULTS+=("${YELLOW}SKIP${NC}  $1  ($2)")
    echo -e "  ${YELLOW}SKIP${NC}  $1  ($2)"
}

# run_sandbox_test <test_name> <policy_file> <expect:pass|fail> <command...>
#   Creates a --no-keep sandbox, runs the command, checks exit code.
#   expect=pass: command should exit 0
#   expect=fail: command should exit non-zero
run_sandbox_test() {
    local test_name="$1"
    local policy="$2"
    local expect="$3"
    shift 3
    local cmd=("$@")

    echo ""
    echo -e "${CYAN}── Test: $test_name ──${NC}"
    log "Policy:  $policy"
    log "Command: ${cmd[*]}"
    log "Expect:  $expect"

    if [[ ! -f "$policy" ]]; then
        record_skip "$test_name" "policy file missing: $policy"
        return
    fi

    # Run sandbox with --no-keep and capture exit code
    local exit_code=0
    local output
    output=$("$OPENSHELL_CLI" sandbox create \
        --gateway "$GATEWAY_NAME" \
        --policy "$policy" \
        --no-keep \
        --no-bootstrap \
        --no-tty \
        --no-auto-providers \
        -- "${cmd[@]}" 2>&1) || exit_code=$?

    log "Exit code: $exit_code"
    # Show first few lines of output for debugging (use <<< to avoid SIGPIPE with set -eo pipefail)
    head -10 <<< "$output" || true

    if [[ "$expect" == "pass" ]]; then
        if [[ $exit_code -eq 0 ]]; then
            record_pass "$test_name"
        else
            record_fail "$test_name" "expected exit 0, got $exit_code"
        fi
    elif [[ "$expect" == "fail" ]]; then
        if [[ $exit_code -ne 0 ]]; then
            record_pass "$test_name"
        else
            record_fail "$test_name" "expected non-zero exit, got 0"
        fi
    fi
}

# ── Test definitions ──────────────────────────────────────────────────────

test_lockdown() {
    echo ""
    echo -e "${CYAN}━━━ LOCKDOWN POLICY TESTS ━━━${NC}"

    run_sandbox_test "lockdown-curl" \
        "$POLICY_DIR/lockdown.yaml" \
        "fail" \
        curl -s --max-time 5 https://example.com

    run_sandbox_test "lockdown-dns" \
        "$POLICY_DIR/lockdown.yaml" \
        "fail" \
        python3 -c "import socket; socket.getaddrinfo('example.com', 443)"
}

test_web_readonly() {
    echo ""
    echo -e "${CYAN}━━━ WEB READ-ONLY POLICY TESTS ━━━${NC}"

    run_sandbox_test "web-ro-pip-dryrun" \
        "$POLICY_DIR/web-readonly.yaml" \
        "pass" \
        pip install --dry-run requests

    # POST to pypi should be blocked by read-only enforcement
    run_sandbox_test "web-ro-post-blocked" \
        "$POLICY_DIR/web-readonly.yaml" \
        "fail" \
        curl -s --max-time 5 -X POST https://pypi.org/

    # Non-allowed host should be blocked
    run_sandbox_test "web-ro-other-blocked" \
        "$POLICY_DIR/web-readonly.yaml" \
        "fail" \
        curl -s --max-time 5 https://httpbin.org/get
}

test_api_allow() {
    echo ""
    echo -e "${CYAN}━━━ API ALLOW POLICY TESTS ━━━${NC}"

    # Anthropic API should be reachable (will get 401 but connection succeeds)
    run_sandbox_test "api-anthropic-reachable" \
        "$POLICY_DIR/api-allow.yaml" \
        "pass" \
        curl -s --max-time 5 -o /dev/null -w '' https://api.anthropic.com/v1/models

    # Non-API host should be blocked
    run_sandbox_test "api-other-blocked" \
        "$POLICY_DIR/api-allow.yaml" \
        "fail" \
        curl -s --max-time 5 https://example.com
}

test_dpu_enforced() {
    echo ""
    echo -e "${CYAN}━━━ DPU-ENFORCED POLICY TESTS ━━━${NC}"

    # Use api.anthropic.com — known to respond through the proxy's TLS MITM path.
    # The proxy terminates TLS (OpenShell Sandbox CA) and forwards upstream.
    # curl gets an HTTP response (401 without auth) → exit 0 proves L4 allow worked.
    run_sandbox_test "dpu-pass-curl" \
        "$POLICY_DIR/dpu-enforced.yaml" \
        "pass" \
        curl -s --max-time 10 -o /dev/null -w '' https://api.anthropic.com/v1/models

    echo ""
    log "NOTE: DPU flow counters must be verified manually:"
    log "  ssh ubuntu@192.168.100.2"
    log "    sudo ovs-ofctl dump-flows ovsbr1  # check pf0vf0 counters"
}

# ── Main ──────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: ./e2e-test.sh [OPTIONS]

End-to-end sandbox policy enforcement tests.

Options:
  --test <name>   Run a specific test (lockdown, web-readonly, api-allow, dpu-enforced)
  --all           Run all tests (default)
  --help          Show this help

Prerequisites:
  - MicroVM gateway running (start-microvm.sh)
  - mTLS certs in ubuntu user config
  - Policy files in ../policies/
EOF
    exit 0
}

TEST_NAME="all"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test) TEST_NAME="$2"; shift 2 ;;
        --all)  TEST_NAME="all"; shift ;;
        --help) usage ;;
        *)      die "Unknown option: $1" ;;
    esac
done

# Pre-flight checks
[[ -x "$OPENSHELL_CLI" ]] \
    || die "openshell CLI not found at $OPENSHELL_CLI"

if [[ ! -f "$USER_CONFIG/mtls/ca.crt" ]]; then
    die "mTLS certs not found. Run start-microvm.sh first."
fi

if ! tcp_probe 127.0.0.1 "$GATEWAY_PORT" 3; then
    die "Gateway not reachable at 127.0.0.1:$GATEWAY_PORT. Is the microVM running?"
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   OpenShellBF End-to-End Policy Enforcement Tests   ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
log "Gateway: $GATEWAY_NAME @ 127.0.0.1:$GATEWAY_PORT"
log "Policies: $POLICY_DIR"

case "$TEST_NAME" in
    lockdown)     test_lockdown ;;
    web-readonly) test_web_readonly ;;
    api-allow)    test_api_allow ;;
    dpu-enforced) test_dpu_enforced ;;
    all)
        test_lockdown
        sleep 2  # let k3s clean up terminated pods
        test_web_readonly
        sleep 2
        test_api_allow
        sleep 2
        test_dpu_enforced
        ;;
    *) die "Unknown test: $TEST_NAME. Choose: lockdown, web-readonly, api-allow, dpu-enforced, all" ;;
esac

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}━━━ SUMMARY ━━━${NC}"
for r in "${RESULTS[@]}"; do
    echo -e "  $r"
done
echo ""
echo -e "  ${GREEN}Passed: $PASS_COUNT${NC}  ${RED}Failed: $FAIL_COUNT${NC}  ${YELLOW}Skipped: $SKIP_COUNT${NC}"
TOTAL=$(( PASS_COUNT + FAIL_COUNT + SKIP_COUNT ))
echo "  Total:  $TOTAL"
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo -e "${RED}Some tests FAILED.${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi

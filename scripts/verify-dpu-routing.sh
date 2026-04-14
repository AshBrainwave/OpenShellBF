#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# verify-dpu-routing.sh
#
# Verifies the managed-proxy MVP guest path for the supervisor-upstream model.
# In this design sandbox applications still talk to the local supervisor
# proxy at 10.200.0.1, while the supervisor namespace reaches the DPU proxy
# over the VM protected lane. The VM therefore needs:
#   - eth1 up with 10.99.2.2/24
#   - a permanent neighbor entry for 10.99.2.1 on eth1
#   - policy routing for pod/supervisor traffic (10.42.0.0/24) via table 100
#   - table 100 default via 10.99.2.1 dev eth1
# while the main default route stays on eth0.
#
# Must be run as root (uses openshell-vm exec).
#
# Usage:
#   sudo ./verify-dpu-routing.sh

set -euo pipefail

SCRIPT_NAME="verify-dpu-routing"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

require_root

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PASS=0
FAIL=0

check() {
    local desc="$1"
    local cmd="$2"
    local expect="$3"

    echo -ne "  ${CYAN}CHECK${NC}  $desc ... "
    local output
    output=$("$OPENSHELL_VM_BIN" exec -- bash -lc "$cmd" 2>&1) || true

    if echo "$output" | grep -qE "$expect"; then
        echo -e "${GREEN}OK${NC}"
        PASS=$(( PASS + 1 ))
    else
        echo -e "${RED}FAIL${NC}"
        echo "    Expected pattern: $expect"
        echo "    Got: $output"
        FAIL=$(( FAIL + 1 ))
    fi
}

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║ DPU Supervisor-Upstream Route Verification ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
echo ""

# 1. Protected NIC exists and has the expected static address.
check "eth1 interface is UP" \
    "ip addr show eth1" \
    "state UP"

check "eth1 has IP 10.99.2.2/24" \
    "ip addr show eth1" \
    "inet 10.99.2.2/24"

# 2. Protected-egress route plumbing for supervisor traffic.
check "static neighbor entry for 10.99.2.1 exists on eth1" \
    "ip neigh show dev eth1" \
    "10.99.2.1 .*PERMANENT"

check "ip rule for pod CIDR 10.42.0.0/24 -> table 100" \
    "ip rule show" \
    "from 10.42.0.0/24 lookup 100"

check "route table 100 defaults via 10.99.2.1 dev eth1" \
    "ip route show table 100" \
    "default via 10.99.2.1 dev eth1"

# 3. Management/default traffic must still stay on eth0.
check "main route: default still via gvproxy (eth0)" \
    "ip route show default" \
    "default via .* dev eth0"

# 5. Pod CIDR should exist so supervisor traffic can originate from the VM.
check "pod subnet 10.42.0.0/24 configured" \
    "ip route show" \
    "10.42.0.0/24"

echo ""
echo -e "  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Some checks FAILED. The supervisor upstream path may not be ready.${NC}"
    echo ""
    echo "To debug:"
    echo "  sudo $OPENSHELL_VM_BIN exec -- ip addr show eth1"
    echo "  sudo $OPENSHELL_VM_BIN exec -- ip neigh show dev eth1"
    echo "  sudo $OPENSHELL_VM_BIN exec -- ip rule show"
    echo "  sudo $OPENSHELL_VM_BIN exec -- ip route show table 100"
    echo "  sudo $OPENSHELL_VM_BIN exec -- ip route show"
    exit 1
else
    echo -e "${GREEN}All checks passed. The supervisor should reach the DPU proxy over eth1.${NC}"
    echo ""
    echo "Next after enabling OPENSHELL_UPSTREAM_HTTP_PROXY and starting the DPU proxy:"
    echo "  openshell sandbox connect dpu-proxy-demo"
    echo "  # then inside the sandbox use the normal local proxy path via 10.200.0.1"
    exit 0
fi

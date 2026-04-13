#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# verify-dpu-routing.sh
#
# Verifies that policy routing is correctly configured inside the microVM
# so that sandbox pod traffic (10.42.0.0/24) exits via eth1 → DPU.
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
    output=$("$OPENSHELL_VM_BIN" exec -- bash -c "$cmd" 2>&1) || true

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
echo -e "${CYAN}║   DPU Policy Routing Verification         ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
echo ""

# 1. eth1 is up with correct IP (checked as two grep patterns on multiline output)
check "eth1 interface is UP" \
    "ip addr show eth1" \
    "state UP"

check "eth1 has IP 10.99.2.2/24" \
    "ip addr show eth1" \
    "inet 10.99.2.2/24"

# 2. Static neighbor entry exists for virtual gateway
check "static neighbor entry for 10.99.2.1" \
    "ip neigh show 10.99.2.1 dev eth1" \
    "02:00:00:00:00:01.*PERMANENT"

# 3. Policy routing rule exists
check "ip rule for 10.42.0.0/24 -> table 100" \
    "ip rule show" \
    "from 10.42.0.0/24 lookup 100"

# 4. Route table 100 has default via eth1
check "route table 100: default via 10.99.2.1 dev eth1" \
    "ip route show table 100" \
    "default via 10.99.2.1 dev eth1"

# 5. Default route (main table) still points to gvproxy
check "main route: default still via gvproxy (eth0)" \
    "ip route show default" \
    "default via .* dev eth0"

# 6. Pod CIDR is 10.42.0.0/24
check "pod subnet 10.42.0.0/24 configured" \
    "ip route show" \
    "10.42.0.0/24"

echo ""
echo -e "  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Some checks FAILED. Policy routing may not be working.${NC}"
    echo ""
    echo "To debug:"
    echo "  sudo $OPENSHELL_VM_BIN exec -- ip rule show"
    echo "  sudo $OPENSHELL_VM_BIN exec -- ip route show table 100"
    echo "  sudo $OPENSHELL_VM_BIN exec -- ip neigh show dev eth1"
    exit 1
else
    echo -e "${GREEN}All checks passed! Pod traffic will exit via eth1 → DPU.${NC}"
    echo ""
    echo "Next: create a sandbox and verify DPU flow counters:"
    echo "  openshell sandbox create --policy policies/dpu-enforced.yaml --no-keep -- curl -s https://api.anthropic.com/v1/models"
    echo "  ssh ubuntu@192.168.100.2 sudo ovs-ofctl dump-flows ovsbr1  # check pf0vf0 counters"
    exit 0
fi

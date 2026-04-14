#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# verify-dpu-routing.sh
#
# Verifies the managed-proxy MVP guest path. For this design the guest does
# NOT need the old table-100 policy-routing setup. It only needs a protected
# `eth1` path that can reach the DPU-side proxy endpoint (`10.99.2.1:3128`)
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
echo -e "${CYAN}║   DPU Managed-Proxy Path Verification    ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════╝${NC}"
echo ""

# 1. Protected NIC exists and has the expected static address.
check "eth1 interface is UP" \
    "ip addr show eth1" \
    "state UP"

check "eth1 has IP 10.99.2.2/24" \
    "ip addr show eth1" \
    "inet 10.99.2.2/24"

# 2. Reaching the DPU proxy IP should prefer eth1 from the VM's main table.
check "route to DPU proxy IP 10.99.2.1 uses eth1" \
    "ip route get 10.99.2.1" \
    "dev eth1.*src 10.99.2.2|src 10.99.2.2.*dev eth1"

# 3. Management/default traffic must still stay on eth0.
check "main route: default still via gvproxy (eth0)" \
    "ip route show default" \
    "default via .* dev eth0"

# 4. Pod CIDR should exist so sandbox traffic can originate from the VM.
check "pod subnet 10.42.0.0/24 configured" \
    "ip route show" \
    "10.42.0.0/24"

echo ""
echo -e "  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Some checks FAILED. The guest protected path may not be ready.${NC}"
    echo ""
    echo "To debug:"
    echo "  sudo $OPENSHELL_VM_BIN exec -- ip addr show eth1"
    echo "  sudo $OPENSHELL_VM_BIN exec -- ip route get 10.99.2.1"
    echo "  sudo $OPENSHELL_VM_BIN exec -- ip route show"
    exit 1
else
    echo -e "${GREEN}All checks passed. The guest should reach the DPU proxy over eth1.${NC}"
    echo ""
    echo "Next after starting the DPU proxy:"
    echo "  sudo $OPENSHELL_VM_BIN exec -- curl -sv --proxy http://10.99.2.1:3128 https://example.com/"
    exit 0
fi

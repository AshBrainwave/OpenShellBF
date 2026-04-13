# DPU NAT Design: OVS CT/NAT on BlueField-3

## Decision

Use **OVS connection tracking with hardware-offloaded NAT** on the DPU eSwitch.
This is the documented NVIDIA pattern for BlueField VF egress with SNAT.

**Chosen approach: Option C** — move sandbox VF from PF0 to PF1, use `pf1vf0 → ovsbr2 → p1`
with SNAT to `10.185.99.182` (already routable on PF1/wire 1 via `enp3s0f1s0`).

## Why not the alternatives

| Approach | Why it fails |
|---|---|
| `output:p0` without NAT | Source 10.99.2.2 is non-routable, DC router drops it |
| `LOCAL` → Linux iptables NAT | OVS bypasses netfilter hooks on system/physical ports (documented OVS behavior) |
| `ct(nat(src=PF1_IP)),output:p0` | Asymmetric: SNAT to PF1 IP but egress on PF0 wire. Return traffic arrives on wrong wire. |
| PF0 with new routable IP | Requires allocating a new IP on wire 0's subnet; PF1 already has a working routable IP |

## Architecture

```
VM (10.42.0.x) → eth1 (10.99.2.2) → vf-bridge → host PF1 VF
    → DPU eSwitch → pf1vf0 (ovsbr2)
    → OVS table 0: classification + CT entry
    → OVS table 1: ct(commit, nat(src=10.185.99.182))
    → output:p1 (wire 1)
    → physical network → internet

Return:
    → p1 → ct(table=1, nat) → reverse NAT (HW offloaded)
    → output:pf1vf0 → VF → vf-bridge → VM
```

## Wire symmetry

The SNAT IP `10.185.99.182` belongs to `enp3s0f1s0` (PF1 SF netdev) on wire 1.
The DC router routes return traffic back via wire 1 → p1 → ovsbr2 where the
CT reverse-NAT state lives. No cross-bridge asymmetry.

## Host-side changes

```bash
# common.sh defaults (changed from PF0 to PF1):
PF_PCI=0000:b3:00.1          # was 0000:b3:00.0
PF_DEV=enp179s0f1np1          # was enp179s0f0np0

# VF creation happens on PF1 now:
echo 1 > /sys/bus/pci/devices/0000:b3:00.1/sriov_numvfs

# VF netdev discovered automatically via sysfs (enp179s0f1v0 or similar)
# vf-bridge binds to PF1 VF instead of PF0 VF — no code changes needed
```

## DPU-side OVS flows (ovsbr2)

See `scripts/setup-dpu-nat.sh` for the full executable script.

```bash
# Prerequisites
ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
ethtool -K p1 hw-tc-offload on

# Table 0: Classification
ovs-ofctl add-flow ovsbr2 "table=0, priority=1000, arp, actions=normal"
ovs-ofctl add-flow ovsbr2 "table=0, priority=900, in_port=pf1hpf, actions=normal"
ovs-ofctl add-flow ovsbr2 "table=0, priority=900, in_port=p1, ip, nw_dst=10.185.99.0/24, actions=normal"
ovs-ofctl add-flow ovsbr2 "table=0, priority=500, ip, in_port=pf1vf0, actions=ct(table=1,nat)"
ovs-ofctl add-flow ovsbr2 "table=0, priority=500, ip, in_port=p1, actions=ct(table=1,nat)"
ovs-ofctl add-flow ovsbr2 "table=0, priority=0, actions=drop"

# Table 1: CT decisions
ovs-ofctl add-flow ovsbr2 "table=1, priority=100, ip, ct_state=+trk+new, in_port=pf1vf0, actions=ct(commit,nat(src=10.185.99.182)),output:p1"
ovs-ofctl add-flow ovsbr2 "table=1, priority=100, ip, ct_state=+trk+est, in_port=pf1vf0, actions=output:p1"
ovs-ofctl add-flow ovsbr2 "table=1, priority=100, ip, ct_state=+trk+est, in_port=p1, actions=output:pf1vf0"
ovs-ofctl add-flow ovsbr2 "table=1, priority=0, actions=drop"
```

Key design choices:
- **pf1hpf pass-through** (priority 900): host management traffic on PF1 is unaffected
- **Local subnet pass-through** (priority 900): traffic to 10.185.99.0/24 from wire bypasses CT (DPU management, SSH)
- **Fail-closed** (priority 0): anything not matching an allowed flow is dropped

## Verification

```bash
# Check flows are offloaded
ovs-appctl dpctl/dump-flows -m | grep "offloaded:yes"

# Check connection tracking state
conntrack -L | grep 10.185.99.182

# tcpdump on wire (should see SNAT'd source)
tcpdump -i p1 -n tcp port 443

# tcpdump on VF rep (should see original private IP)
tcpdump -i pf1vf0 -n tcp port 443
```

## Known limitations (BlueField CT offload)

- ICMP CT offload not supported (use TCP for testing, not ping)
- Exclude RoCEv2 UDP/4791 from CT if using RDMA
- Max ~1M offloaded connections (default nf_conntrack_max)
- Recommended: `net.netfilter.nf_conntrack_tcp_be_liberal=1`

## Sources

- NVIDIA "Virtual Switch on BlueField" — Connection Tracking With NAT section
- NVIDIA "OVS in DOCA" PDF — SNAT/DNAT with CT offload
- OVS FAQ — iptables not useful on physical/system ports in OVS bridge

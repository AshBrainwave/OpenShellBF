# Research: BlueField-3 DPU — VF Egress NAT Architecture for Sandbox Traffic

## Context

We're building a sandboxed AI agent runtime (OpenShell) where:
- User workloads run inside a **microVM** (libkrun) on an x86 host
- The host has a **NVIDIA BlueField-3 DPU** (ConnectX-7 NIC in DPU mode, switchdev/separated host)
- The DPU owns the eSwitch — the host kernel cannot modify steering rules
- The DPU runs OVS bridges for packet policy enforcement (allow/deny by flow rules)

## What we have working

1. **Host creates SR-IOV VF** on PF0 (`echo 1 > /sys/bus/pci/devices/0000:b3:00.0/sriov_numvfs`)
2. **vf-bridge** (custom L2 relay) bridges VM's virtio-net eth1 ↔ AF_PACKET socket on the host VF (enp179s0f0v0)
3. **DPU eSwitch** steers VF traffic to representor port **pf0vf0** on the DPU ARM cores
4. **pf0vf0** is a port on **ovsbr1** (OVS bridge), alongside **p0** (PF0 physical uplink) and **pf0hpf** (host PF0 representor)
5. OVS flow rules on ovsbr1 correctly match VF traffic (we verified TCP SYNs from 10.99.2.2 arriving at pf0vf0)

## The problem

Packets from the VM exit pf0vf0 → OVS allows → output:p0 → physical wire. But:
- Source IP is **10.99.2.2** (private, non-routable)
- No NAT happens, so the datacenter router drops the packet (or can't route the response back)
- We need to **SNAT the VF traffic to a routable IP** before it hits the wire

## DPU network topology

```
Physical wire 0 (p0 / PF0)
    └── ovsbr1 (OVS bridge)
            ├── p0           — physical uplink (wire 0)
            ├── pf0hpf       — host PF0 representor
            ├── en3f0pf0sf0  — SF0 representor
            └── pf0vf0       — VF0 representor (our sandbox traffic)

Physical wire 1 (p1 / PF1)
    └── ovsbr2 (OVS bridge)
            ├── p1           — physical uplink (wire 1)
            ├── pf1hpf       — host PF1 representor
            └── en3f1pf1sf0  — SF1 representor

DPU IPs:
    oob_net0:     10.185.99.185/24  (out-of-band management)
    enp3s0f1s0:   10.185.99.182/24  (PF1 SF application netdev, has internet)
    enp3s0f0s0:   no IP             (PF0 SF application netdev)
    tmfifo_net0:  192.168.100.2/30  (rshim to host)
```

## What we tried (and why it failed)

1. **Output to p0 without NAT** — SYN reaches wire but source 10.99.2.2 is not routable. No SYN-ACK returns.

2. **OVS LOCAL action → Linux forwarding → iptables MASQUERADE** — Packets reach Linux (21 pkts in LOCAL flow counter), Linux forwards them (18 pkts in FORWARD chain), they appear on enp3s0f1s0 via tcpdump. But iptables/nftables NAT POSTROUTING shows **0 matches** on our SNAT/MASQUERADE rules. Suspect OVS or the SF representor path bypasses netfilter hooks.

3. **OVS ct(commit,nat(src=10.185.99.182)),output:p0** — SNAT to PF1's IP but output via p0 (PF0 wire). Return traffic arrives on wire 1 (PF1), never hits our return flow rule on p0 (ovsbr1).

## Questions

1. **What is the correct BlueField-3 architecture for VF egress with NAT?** How do production deployments handle SNAT for VF traffic that needs to reach the internet through the DPU?

2. **Should we use OVS ct(nat) or Linux iptables NAT?** When using `actions=LOCAL` to deliver to the Linux stack, why might netfilter NAT hooks not fire? Is there a known issue with OVS internal ports and netfilter?

3. **Which physical port should VF traffic exit through?** If pf0vf0 is on ovsbr1 (wire 0), should egress go via p0? Or should we route through an SF to the Linux stack and exit via a different interface?

4. **How should the PF0 SF (enp3s0f0s0) be used?** It has no IP. Should we assign one for SNAT purposes? Or should VF traffic be routed through the SF pair (en3f0pf0sf0 ↔ enp3s0f0s0) for Linux-level NAT?

5. **Is there a standard pattern for "bump-in-the-wire policy + NAT" on BlueField?** E.g., NVIDIA DOCA DPI reference architectures, or OVN-based designs that handle this?

6. **OVS connection tracking on BlueField** — Does the BlueField OVS datapath support `ct(nat)` actions? Are there kernel module requirements (openvswitch, nf_conntrack, nf_nat)? Any known limitations with hardware offload?

## Constraints

- Host kernel **cannot** modify eSwitch (DPU owns it in separated mode)
- DPU is accessed via **rshim SSH** only (192.168.100.2)
- Cannot install new packages on the DPU (use what's available in DOCA/BFB image)
- BlueField-3 is running stock DOCA/Ubuntu BFB image

## Desired end state

```
VM pod (10.42.0.x) → sandbox proxy (OPA L4+L7 policy)
    → eth1 (virtio-net) → vf-bridge → host VF → DPU eSwitch
    → pf0vf0 → OVS flow rules (L3/L4 policy: allow/deny)
    → [NAT to routable IP] → physical wire → internet
    → response returns → reverse NAT → pf0vf0 → VF → VM
```

Two enforcement points: software (OPA proxy) + hardware (DPU OVS). Defense in depth.

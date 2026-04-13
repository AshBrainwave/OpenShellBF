# Problem: OVS ct(table=X) recirculation silently drops packets on BlueField-3

## Environment
- BlueField-3 DPU in switchdev / separated-host mode
- OVS 3.3.0040 (NVIDIA DOCA build)
- Kernel modules loaded: `openvswitch`, `nf_nat`, `nf_conntrack`, `act_ct`
- `hw-offload=true` (10 flows offloaded)
- Bridge: `ovsbr2` with ports: `p1` (physical uplink), `pf1hpf` (host PF rep), `pf1vf0` (VF representor), `en3f1pf1sf0` (SF rep)
- `pf1vf0` is an eSwitch VF representor (datapath port 10)

## What works

| Flow | Result |
|---|---|
| `in_port=pf1vf0,tcp,tp_dst=443,actions=output:p1` | Packets appear on p1 |
| `in_port=pf1vf0,tcp,tp_dst=443,actions=ct(commit),output:p1` | Packets appear on p1 |
| `in_port=pf1vf0,tcp,tp_dst=443,actions=resubmit(,10)` + `table=10,actions=output:p1` | Packets appear on p1 |

## What fails (silently drops packets)

| Flow | Result |
|---|---|
| `in_port=pf1vf0,actions=ct(table=1,nat)` + `table=1,ct_state=+trk+new,actions=ct(commit,nat(src=IP)),output:p1` | Packets seen on pf1vf0 only, never reach p1 or table 1. No conntrack entries created. |
| `in_port=pf1vf0,actions=ct(table=10)` + `table=10,ct_state=+trk+new,actions=ct(commit,nat(src=IP)),output:p1` | Same — pf1vf0 only, never reaches table 10. |
| `in_port=pf1vf0,actions=ct(nat),ct(commit,nat(src=10.185.99.182)),output:p1` | Packets reach p1 but source IP is NOT rewritten (still 10.99.2.2). No conntrack entries for 10.99.2.2 exist. |

## Key observations

1. **`ct(table=X)` recirculation is broken**: The `ct()` action with a `table=` parameter (which triggers OVS recirc) silently drops the packet. It never arrives at the target table. Without `table=`, `ct(commit)` passes through fine.

2. **NAT rewrite never applies**: Even when packets pass through `ct(commit,nat(src=IP))` (without table recirculation), the source IP is not rewritten. `conntrack -L` shows zero entries for the test traffic.

3. **`ofproto/trace` says it should work**: Running `ovs-appctl ofproto/trace ovsbr2 'in_port=pf1vf0,tcp,...'` shows the correct path: table 0 → ct(table=1,nat) → recirc → table 1 → ct(commit,nat(src=10.185.99.182)) → output:p1. But real traffic does not follow this path.

4. **No datapath flows for pf1vf0 TCP**: `ovs-appctl dpctl/dump-flows` shows zero entries for datapath port 10 (pf1vf0) for any TCP traffic. The `upcall/show` reports 4.2M misses but only 1 cached flow.

5. **Offloaded flows**: `offloaded flows: 10` — the OpenFlow rules are offloaded to hardware. But the offloaded flow dump (`dpctl/dump-flows type=offloaded`) shows no entries for port 10 (pf1vf0) at all.

6. **`ct(commit)` without table recirculation works**: `ct(commit),output:p1` successfully forwards the packet, so the basic CT action isn't completely broken — just the recirc and NAT parts.

## Specific questions

1. **Is `ct(table=X)` recirculation known to be broken or unsupported on NVIDIA OVS 3.3.0040 with eSwitch representors?** Is there a kernel or OVS config needed to enable it?

2. **Why does `ct(commit,nat(src=IP))` execute without error but not rewrite the source IP?** The packet passes through and exits p1, but conntrack creates no entry and NAT doesn't apply. Is the conntrack zone wrong? Is there a missing kernel module or sysctl?

3. **Is hw-offload interfering?** Could the hardware offload path be intercepting pf1vf0 traffic before the software CT/NAT path processes it? Would disabling hw-offload (`other_config:hw-offload=false`) fix this? (We haven't tested this yet because it requires OVS restart.)

4. **Is there a known workaround for CT/NAT on BlueField-3 VF representors?** For example:
   - Using `tc-ct` (TC flower with CT action) instead of OVS OpenFlow CT?
   - Using DOCA Flow CT API instead of OVS?
   - Using a specific OVS bridge mode or datapath type?
   - Punting to LOCAL and using Linux iptables NAT on an internal port (not a physical/system port)?

5. **Could the problem be that pf1vf0 is a VF representor (not a regular port)?** Do VF representors on BlueField have different CT/recirc behavior compared to regular ports like pf1hpf or SF representors?

## What we haven't tried yet
- Disabling hw-offload entirely and testing CT/NAT in pure software mode
- Using `LOCAL` action to punt to Linux stack + iptables MASQUERADE via enp3s0f1s0 (the SF app netdev, which is NOT an OVS port and should have normal netfilter hooks)
- TC flower ct action instead of OVS OpenFlow ct
- Testing ct(table=X) on a non-representor port (e.g., ovsbr2 internal port)

# A Day in the Life of a Packet: OpenShell + BlueField-3 DPU

**How a single `curl https://api.anthropic.com` travels from sandbox to internet
and back, through four trust boundaries and three enforcement points.**

---

## The Cast of Characters

Before we trace the packet, meet the components:

| Component | Where it runs | Role |
|-----------|--------------|------|
| **Sandbox** | Pod inside microVM k3s | Isolated user workload (container) |
| **Sandbox Proxy** | Sidecar in sandbox pod | HTTP CONNECT proxy + OPA policy engine |
| **k3s / kube-proxy** | Inside microVM | Kubernetes control plane + nftables routing |
| **gvproxy** | Host process | Virtual network gateway (NAT for microVM eth0) |
| **vf-bridge** | Host process | L2 frame relay: UNIX socket <-> AF_PACKET on VF |
| **Host VF** | Host kernel (enp179s0f0v0) | SR-IOV Virtual Function on BF3 NIC |
| **BF3 eSwitch** | NIC hardware | Hardware packet steering (SR-IOV) |
| **DPU OVS** | BlueField-3 ARM cores | OVS bridge (ovsbr1) with flow rules |
| **Physical wire** | Datacenter network | Actual copper/fiber to the internet |

---

## Two Network Paths

The microVM has **two virtual NICs** — this is the core architectural insight:

```
                    +-----------+
                    |  microVM  |
                    |           |
              eth0 -+- mgmt    |  eth1 -+- protected egress
              (gvproxy NAT)    |  (vf-bridge -> DPU)
                    |           |
                    +-----------+

eth0 = Management path (gvproxy)
  - Used for: k3s control plane, image pulls, API server
  - NAT via gvproxy on host
  - NOT policy-enforced by DPU

eth1 = Protected egress path (vf-bridge -> VF -> DPU)
  - Used for: sandbox workload traffic
  - Every packet passes through DPU OVS flow table
  - Hardware-enforced policy at the NIC level
  - Host CANNOT bypass (eSwitch owned by DPU)
```

---

## The Journey: `curl https://api.anthropic.com`

### Phase 0: Policy Loading (before any packet)

When the sandbox starts, the **OPA engine** loads the policy YAML:

```yaml
# From api-allow.yaml
network_policies:
  anthropic:
    name: Anthropic API
    endpoints:
      - { host: api.anthropic.com, port: 443 }
    binaries:
      - { path: /usr/bin/curl }
```

This compiles into Rego rules that the proxy evaluates on every CONNECT request.
The policy says: "Allow curl to connect to api.anthropic.com:443. Deny everything else."

---

### Phase 1: Application -> Sandbox Proxy (inside sandbox pod)

```
sandbox@test:~$ curl https://api.anthropic.com/v1/models

[1] curl resolves proxy from environment:
    https_proxy=http://10.200.0.1:3128

[2] curl opens TCP connection to proxy (10.200.0.1:3128)

[3] curl sends CONNECT request:
    CONNECT api.anthropic.com:443 HTTP/1.1
    Host: api.anthropic.com:443
```

**What's happening:** The sandbox container has `https_proxy` set in its environment.
All HTTPS traffic goes through the sidecar proxy. There is no direct internet access.
The proxy is the **first enforcement point** (L4 + L7 policy via OPA).

---

### Phase 2: OPA Policy Evaluation (inside sandbox proxy)

```
Proxy receives: CONNECT api.anthropic.com:443

  [4] Extract: host=api.anthropic.com, port=443
  [5] Identify calling binary: /usr/bin/curl (via /proc/PID/exe)
  [6] Query OPA engine:
      - endpoint_allowed? -> YES (api.anthropic.com:443 in "anthropic" policy)
      - binary_allowed?   -> YES (/usr/bin/curl in "anthropic" binaries)
      - network_action    -> "allow"

  [7] Proxy responds: HTTP/1.1 200 Connection Established
```

**Teaching moment:** The OPA evaluation checks TWO things:
1. **Endpoint match** — is the destination host:port in any policy?
2. **Binary match** — is the calling process (or its ancestors) in the allowed list?

Both must match the SAME policy. A binary allowed for GitHub can't reach Anthropic,
even if another policy allows Anthropic. This prevents one tool from piggybacking
on another tool's network permissions.

**If denied:**
```
  network_action -> "deny"
  Proxy responds: HTTP/1.1 403 Forbidden
  curl exits with: error 56 (Recv failure)
```

---

### Phase 3: TLS Termination (sandbox proxy MITM)

```
  [8]  Proxy establishes TLS with curl (client side):
       - Generates cert for api.anthropic.com
       - Signed by "OpenShell Sandbox CA"
       - curl trusts this via /etc/openshell-tls/ca-bundle.pem

  [9]  Proxy establishes TLS with real api.anthropic.com (upstream side):
       - Real TLS to the actual server
       - Proxy sees plaintext HTTP request

  [10] curl sends: GET /v1/models HTTP/1.1
       Proxy inspects request (if L7 enforcement is configured)
       Proxy forwards to upstream api.anthropic.com
```

**Teaching moment:** The proxy does TLS MITM (Man-in-the-Middle) for L7 inspection.
This lets it enforce rules like "allow GET but deny POST" or "allow /api/** but deny /admin/**".
The sandbox trusts the proxy's CA via a pre-installed certificate bundle.
The proxy is NOT a pass-through tunnel — it can read and filter every HTTP request.

---

### Phase 4: Pod Network -> k3s -> microVM kernel (inside microVM)

```
  [11] Proxy's upstream TCP SYN to api.anthropic.com:443
       Source: 10.200.0.x (pod IP)
       Dest:   resolved IP of api.anthropic.com

  [12] Packet hits CNI bridge (cni0) inside microVM

  [13] kube-proxy nftables rules route it to the default gateway

  [14] microVM kernel routes via eth0 (gvproxy) or eth1 (protected egress)
       - eth0: default route via gvproxy (192.168.127.1)
       - eth1: static route for specific subnets (10.99.2.1/24)
```

**Current state:** Today, sandbox traffic exits via **eth0 (gvproxy)** because the
default route points there. The DPU eth1 path is available but requires routing
rules to steer sandbox traffic through it. This is the next integration step.

**Future state:** Sandbox egress will be routed through eth1, making every packet
pass through the DPU enforcement point.

---

### Phase 5: gvproxy -> Host -> Internet (current path via eth0)

```
  [15] Packet arrives at gvproxy via virtio-net (UNIX socket)

  [16] gvproxy performs NAT:
       Source: 192.168.127.2 (VM) -> host IP
       Dest:   api.anthropic.com IP (unchanged)

  [17] Packet exits host via physical NIC (enp179s0f0np0)
       -> Datacenter network -> Internet -> api.anthropic.com
```

---

### Phase 5-ALT: vf-bridge -> DPU -> Internet (protected egress via eth1)

This is the **hardware-enforced path** — the architectural goal:

```
  [15] Packet arrives at guest eth1 (virtio-net via UNIX socket)

  [16] vf-bridge (host process) receives QEMU-framed Ethernet frame:
       +----------+----------------------------+
       | 4-byte   | Raw Ethernet frame         |
       | length   | (src MAC, dst MAC, IP, TCP)|
       | (BE u32) |                            |
       +----------+----------------------------+

  [17] vf-bridge strips 4-byte length header
       Writes raw frame to AF_PACKET socket on enp179s0f0v0 (host VF)

  [18] Frame exits VF -> BF3 NIC hardware (PCIe)

  [19] BF3 eSwitch steers frame to DPU representor port (pf0vf0)
       (Hardware steering — host kernel never sees this packet)

  [20] DPU OVS bridge (ovsbr1) receives frame on port pf0vf0
       Flow table evaluation:
       
       priority=100 tcp in_port=pf0vf0 nw_dst=X.X.X.X tp_dst=443 -> output:p0  [ALLOW]
       priority=50      in_port=pf0vf0                             -> drop       [DEFAULT DENY]
       priority=0                                                  -> NORMAL

  [21] If ALLOWED: frame exits via p0 (physical uplink) -> wire -> internet
       If DENIED:  frame dropped, counter incremented (auditable)
```

**Teaching moment:** This is the **second enforcement point** — hardware level.
Even if the sandbox proxy is compromised, the DPU still enforces:
- The host kernel **cannot modify** the eSwitch (it's owned by the DPU)
- The OVS flow table on the DPU is only configurable via rshim SSH (192.168.100.2)
- Every dropped packet increments a counter visible via `ovs-ofctl dump-flows`
- This is **defense in depth**: software policy (OPA) + hardware policy (DPU OVS)

---

### Phase 6: Response Returns

The return path is the reverse:

```
Internet -> BF3 p0 -> OVS ovsbr1 -> pf0vf0 -> eSwitch -> host VF
-> vf-bridge (AF_PACKET -> add QEMU header -> UNIX socket)
-> guest eth1 -> kernel routing -> pod network -> proxy
-> proxy decrypts TLS -> re-encrypts for curl -> curl receives response
```

---

## The Three Enforcement Points

```
                         ENFORCEMENT POINT 1          ENFORCEMENT POINT 2
                         (Software - OPA)             (Hardware - DPU OVS)
                              |                             |
                              v                             v
  +----------+    +------------------+    +---------+    +----------+    +--------+
  |          |    |                  |    |         |    |          |    |        |
  | curl in  |--->| Sandbox Proxy    |--->| microVM |--->| BF3 DPU  |--->| Wire   |
  | sandbox  |    | (OPA + TLS MITM) |    | kernel  |    | (OVS)   |    |        |
  |          |    |                  |    |         |    |          |    |        |
  +----------+    +------------------+    +---------+    +----------+    +--------+
                                               |
                                               v
                                     ENFORCEMENT POINT 3
                                     (Kernel - Landlock)
                                     Filesystem access control
```

| Point | Type | What it controls | Bypass risk |
|-------|------|-----------------|-------------|
| **1. OPA Proxy** | Software (L4+L7) | Which hosts/ports/HTTP methods are allowed per binary | Kernel escape from container |
| **2. DPU OVS** | Hardware (L3/L4) | Which destination IPs/ports can exit the NIC | Physical access to NIC |
| **3. Landlock** | Kernel (filesystem) | Which paths are readable/writable | Kernel vulnerability |

**Defense in depth:** An attacker would need to:
1. Escape the container (bypass Landlock + namespace isolation)
2. Bypass the sandbox proxy (modify iptables/nftables in the pod)
3. Escape the microVM (exploit virtio/libkrun)
4. Modify the host kernel's routing (redirect traffic from eth1)
5. Reprogram the BF3 eSwitch (requires DPU-side access via rshim)

Each layer is independent. Compromising one does not compromise the others.

---

## Packet Lifecycle Cheat Sheet

```
curl -> proxy (OPA check) -> TLS MITM -> pod network -> VM kernel
  -> eth0 (gvproxy NAT) -> host NIC -> internet          [management path]
  -> eth1 (vf-bridge) -> VF -> DPU OVS (flow check) -> wire  [protected path]
```

---

## Observability

| What to check | Command |
|---------------|---------|
| Proxy allow/deny decisions | Sandbox pod logs (OCSF events) |
| DPU flow counters | `ssh ubuntu@192.168.100.2 sudo ovs-ofctl dump-flows ovsbr1` |
| VF traffic stats | `ip -s link show enp179s0f0v0` |
| vf-bridge frame counters | `cat /var/log/openshell/vf-bridge.log` |
| microVM console | `cat ~/.local/share/openshell/.../rootfs-console.log` |
| Which policy matched | Enable verbose OPA logging (`-vvv` on openshell CLI) |

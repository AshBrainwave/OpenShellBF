#!/usr/bin/env python3
"""
Render the OpenShellBF packet lifecycle diagram as a PNG using graphviz.
"""
import subprocess
import os

DOT_SOURCE = r'''
digraph PacketLifecycle {
    rankdir=TB;
    bgcolor="#0a0a1a";
    fontname="Helvetica";
    fontcolor="#eeeeee";
    node [fontname="Helvetica", fontsize=11, style="filled,rounded", shape=box];
    edge [fontname="Helvetica", fontsize=9, color="#e94560", fontcolor="#cccccc"];
    newrank=true;

    // ═══════════════════════════════════════════════════════
    // SANDBOX POD
    // ═══════════════════════════════════════════════════════
    subgraph cluster_sandbox {
        label="SANDBOX POD  (inside microVM k3s)";
        labeljust=l;
        fontsize=14;
        fontcolor="#e94560";
        style="dashed,rounded";
        color="#e94560";
        bgcolor="#1a1a2e";

        curl [label="curl https://api.anthropic.com\n(user workload)", fillcolor="#4527a0", fontcolor=white];
        proxy_connect [label="CONNECT api.anthropic.com:443\nvia https_proxy=10.200.0.1:3128", fillcolor="#311b92", fontcolor=white, shape=note];

        subgraph cluster_opa {
            label="  ENFORCEMENT POINT 1\n  OPA Policy Engine  ";
            labeljust=l;
            fontsize=12;
            fontcolor="#ff5252";
            style="filled,rounded";
            fillcolor="#2a0a0a";
            color="#c62828";

            ep_check [label="Endpoint match?\napi.anthropic.com:443\nin policy endpoints?", shape=diamond, fillcolor="#b71c1c", fontcolor=white];
            bin_check [label="Binary match?\n/usr/bin/curl\nin policy binaries?", shape=diamond, fillcolor="#b71c1c", fontcolor=white];
            allow_decision [label="network_action = ALLOW", fillcolor="#2e7d32", fontcolor=white, shape=oval];
        }

        deny_403 [label="HTTP 403 Forbidden\ncurl exits with error 56", fillcolor="#880e4f", fontcolor=white, shape=octagon];

        tls_mitm [label="TLS MITM Termination\nProxy issues cert from\nOpenShell Sandbox CA\nInspects HTTP request (L7)", fillcolor="#4a148c", fontcolor=white];
    }

    // ═══════════════════════════════════════════════════════
    // MICROVM KERNEL
    // ═══════════════════════════════════════════════════════
    subgraph cluster_microvm {
        label="MICROVM KERNEL  (libkrun guest, 4 vCPU, 8 GiB)";
        labeljust=l;
        fontsize=14;
        fontcolor="#42a5f5";
        style="dashed,rounded";
        color="#42a5f5";
        bgcolor="#0f1a2e";

        pod_net [label="Pod Network (cni0)\n10.200.0.0/24", fillcolor="#00695c", fontcolor=white];
        routing [label="Kernel routing\ndecision", shape=diamond, fillcolor="#004d40", fontcolor=white];

        eth0 [label="eth0 (virtio-net)\nManagement path\n192.168.127.2", fillcolor="#1565c0", fontcolor=white];
        eth1 [label="eth1 (virtio-net)\nProtected egress\n10.99.2.2", fillcolor="#0d47a1", fontcolor=white];
    }

    // ═══════════════════════════════════════════════════════
    // HOST
    // ═══════════════════════════════════════════════════════
    subgraph cluster_host {
        label="HOST  (x86_64, lenny1)";
        labeljust=l;
        fontsize=14;
        fontcolor="#66bb6a";
        style="dashed,rounded";
        color="#66bb6a";
        bgcolor="#0a1a0a";

        gvproxy [label="gvproxy\nNAT gateway\nUNIX socket relay", fillcolor="#1b5e20", fontcolor=white];
        vf_bridge [label="vf-bridge\nQEMU frame relay\nUNIX socket ↔ AF_PACKET", fillcolor="#33691e", fontcolor=white];
        host_vf [label="enp179s0f0v0\nSR-IOV VF\nMAC: 52:54:00:aa:bb:cc", fillcolor="#1565c0", fontcolor=white];
        host_nic [label="enp179s0f0np0\nPhysical NIC (PF)", fillcolor="#0d47a1", fontcolor=white];
    }

    // ═══════════════════════════════════════════════════════
    // BLUEFIELD-3 DPU
    // ═══════════════════════════════════════════════════════
    subgraph cluster_dpu {
        label="BLUEFIELD-3 DPU  (ARM, 192.168.100.2 via rshim)";
        labeljust=l;
        fontsize=14;
        fontcolor="#ffa726";
        style="dashed,rounded";
        color="#ffa726";
        bgcolor="#1a150a";

        eswitch [label="BF3 eSwitch\nHardware packet steering\n(host CANNOT modify)", fillcolor="#e65100", fontcolor=white];

        subgraph cluster_ovs {
            label="  ENFORCEMENT POINT 2\n  OVS Flow Table (ovsbr1)  ";
            labeljust=l;
            fontsize=12;
            fontcolor="#ff5252";
            style="filled,rounded";
            fillcolor="#2a0a0a";
            color="#c62828";

            pf0vf0 [label="pf0vf0\nVF0 representor port", fillcolor="#bf360c", fontcolor=white];
            flow_check [label="Flow table match?\npri=100: allow dst:443 → output:p0\npri=50: DEFAULT DROP", shape=diamond, fillcolor="#b71c1c", fontcolor=white];
        }

        p0 [label="p0\nPhysical uplink\n(wire)", fillcolor="#e65100", fontcolor=white];
        dropped [label="DROPPED\nCounter incremented\nAuditable: ovs-ofctl dump-flows", fillcolor="#880e4f", fontcolor=white, shape=octagon];
    }

    // ═══════════════════════════════════════════════════════
    // INTERNET
    // ═══════════════════════════════════════════════════════
    internet [label="Internet\napi.anthropic.com", fillcolor="#263238", fontcolor=white, shape=cylinder];

    // ═══════════════════════════════════════════════════════
    // EDGES — Main flow
    // ═══════════════════════════════════════════════════════
    curl -> proxy_connect [label="1. resolve proxy\nfrom env", color="#7e57c2"];
    proxy_connect -> ep_check [label="2. CONNECT\nrequest", color="#7e57c2"];

    ep_check -> bin_check [label="YES", color="#66bb6a", fontcolor="#66bb6a"];
    ep_check -> deny_403 [label="NO", color="#ef5350", fontcolor="#ef5350"];
    bin_check -> allow_decision [label="YES", color="#66bb6a", fontcolor="#66bb6a"];
    bin_check -> deny_403 [label="NO", color="#ef5350", fontcolor="#ef5350"];

    allow_decision -> tls_mitm [label="3. 200 Connection\nEstablished", color="#66bb6a"];
    tls_mitm -> pod_net [label="4. Forward\nupstream", color="#42a5f5"];

    pod_net -> routing [color="#42a5f5"];

    // Two paths from routing
    routing -> eth0 [label="default route\n(current path)", color="#66bb6a", style=solid];
    routing -> eth1 [label="policy route\n(protected path)", color="#ffa726", style=bold];

    // Management path (eth0)
    eth0 -> gvproxy [label="5a. virtio-net\nUNIX socket", color="#66bb6a"];
    gvproxy -> host_nic [label="6a. NAT\nto host IP", color="#66bb6a"];
    host_nic -> internet [label="7a. wire", color="#66bb6a"];

    // Protected egress path (eth1)
    eth1 -> vf_bridge [label="5b. virtio-net\nUNIX socket", color="#ffa726"];
    vf_bridge -> host_vf [label="6b. AF_PACKET\nraw frame", color="#ffa726"];
    host_vf -> eswitch [label="7b. PCIe\nhw steering", color="#ffa726"];
    eswitch -> pf0vf0 [label="8b. representor\nport", color="#ffa726"];
    pf0vf0 -> flow_check [color="#ffa726"];
    flow_check -> p0 [label="ALLOW", color="#66bb6a", fontcolor="#66bb6a"];
    flow_check -> dropped [label="DROP", color="#ef5350", fontcolor="#ef5350"];
    p0 -> internet [label="9b. wire", color="#66bb6a"];

    // ═══════════════════════════════════════════════════════
    // LEGEND
    // ═══════════════════════════════════════════════════════
    subgraph cluster_legend {
        label="Legend";
        labeljust=l;
        fontsize=12;
        fontcolor="#eeeeee";
        style="rounded";
        color="#333333";
        bgcolor="#111122";

        leg_allow [label="  ALLOW  ", fillcolor="#2e7d32", fontcolor=white, shape=oval];
        leg_deny [label="  DENY  ", fillcolor="#880e4f", fontcolor=white, shape=octagon];
        leg_enforce [label="  Enforcement Point  ", fillcolor="#b71c1c", fontcolor=white, shape=diamond];
        leg_process [label="  Process  ", fillcolor="#4527a0", fontcolor=white];
        leg_hw [label="  Hardware  ", fillcolor="#1565c0", fontcolor=white];

        leg_allow -> leg_deny -> leg_enforce -> leg_process -> leg_hw [style=invis];
    }
}
'''

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    dot_path = os.path.join(script_dir, 'packet-lifecycle.dot')
    png_path = os.path.join(script_dir, 'packet-lifecycle.png')

    with open(dot_path, 'w') as f:
        f.write(DOT_SOURCE)

    print(f"Rendering {png_path}...")
    result = subprocess.run(
        ['dot', '-Tpng', '-Gdpi=150', '-o', png_path, dot_path],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"Error: {result.stderr}")
        return 1

    size = os.path.getsize(png_path)
    print(f"Done: {png_path} ({size:,} bytes)")
    return 0

if __name__ == '__main__':
    exit(main())

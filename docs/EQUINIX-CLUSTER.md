# The Kubernetes cluster at Equinix

## What changed: Equinix Metal is gone

Equinix Metal (bare metal as a service) reached **end of life on June 30, 2026**. Its product
documentation was retired on Sept 30, 2026, and the console goes offline on Jan 1, 2027. The
Equinix Terraform provider **v5 removed all `equinix_metal_*` resources**. For Ignite 2026, the
cluster has to run on hardware in an **Equinix IBX**:

- **Your own colocated servers** in a cage (the default assumption in this repo).
- **Equinix-managed servers** or a managed private-cloud offering.
- A **bare-metal partner** that operates in the same Equinix metro.

Terraform here manages only **Equinix Fabric** (`terraform/equinix`). The servers, cabling, the edge
router, and the OS are prerequisites.

## Minimum requirements

| Item | Requirement |
|---|---|
| Servers | 1–3 x86_64 servers, Ubuntu 24.04 LTS. For Online Boutique, Arc, and Fleet: 4+ vCPU and 8+ GiB in total (a single node is OK for the demo). |
| Network | A routed cage subnet (default `10.80.0.0/24`). The **default route** goes to the edge router or FCR leg. There's **no internet egress**, which is intentional. |
| Edge | An edge router with BGP (port origin) or an FCR. Use `artifacts/edge-router-bgp-*.conf` from `scripts/05`. |
| Reachability | Nodes must reach `10.50.1.10:3128` over ExpressRoute. During onboarding only, your workstation must reach the K3s API (`<node>:6443`). |
| Fleet member overhead | About 210 MB memory, 2% of one core, and 3 pods for the Fleet Arc extension. The `fleet-system` namespace is reserved. |

## Option A (default): K3s

Fleet lists K3s as a supported Arc distribution. It's lightweight and multi-node capable, and it has the
lowest stage risk of the options.

1. **Prove the path first** (after `make connect-er`). On any cage node:

   ```bash
   EGRESS_PROXY=http://10.50.1.10:3128 ./equinix/k3s/verify-egress.sh
   ```

2. **Install the first server**:

   ```bash
   sudo EGRESS_PROXY=http://10.50.1.10:3128 NODE_IP=10.80.0.11 ./equinix/k3s/install-k3s-server.sh
   ```

   The script does the following:
   - Writes the proxy to `/etc/systemd/system/k3s.service.env`, so K3s, the kubelet, and containerd all use it.
     The pod and service CIDRs, the cage subnet, `.svc`, and `.cluster.local` are excluded through NO_PROXY.
   - **Disables Traefik**, because port 80 must stay free for `frontend-external` on K3s ServiceLB.
   - Enables embedded etcd (`--cluster-init`), so more servers can join later.
   - If you're using the private ACR, set `PRIVATE_ACR=<name>.azurecr.io` to write the containerd mirrors.

3. **Add agents** (optional):

   ```bash
   sudo K3S_URL=https://10.80.0.11:6443 K3S_TOKEN=<token> EGRESS_PROXY=http://10.50.1.10:3128 NODE_IP=10.80.0.12 ./equinix/k3s/install-k3s-agent.sh
   ```

4. **Kubeconfig on your workstation.** The context name must match `EQUINIX_KUBE_CONTEXT` (default `equinix-demo`):

   ```bash
   sudo sed "s/127.0.0.1/10.80.0.11/" /etc/rancher/k3s/k3s.yaml > equinix-demo.kubeconfig   # on the node
   ```

   ```powershell
   # on the workstation (needs a route to 10.80.0.11:6443, for example over VPN or a jump host)
   $env:KUBECONFIG = "$HOME\.kube\config;$PWD\equinix-demo.kubeconfig"
   kubectl config view --flatten | Set-Content "$HOME\.kube\config.merged"; Move-Item -Force "$HOME\.kube\config.merged" "$HOME\.kube\config"
   Remove-Item Env:KUBECONFIG
   kubectl config rename-context default equinix-demo
   kubectl get nodes --context equinix-demo
   ```

   Delete the copied `equinix-demo.kubeconfig` afterward. It contains cluster-admin credentials, and the
   `.gitignore` excludes it.

5. **Storefront for the presenter.** K3s ServiceLB serves `frontend-external` on port 80 of every node. To
   publish it in a browser through Azure across the circuit, set `EQUINIX_STOREFRONT_UPSTREAMS=10.80.0.11:80,...`
   and `STOREFRONT_ALLOWED_CIDRS=<your public IP>/32`, then re-run `make plan apply`. The proxy VM's nginx is
   reconfigured in place. As an alternative, run `scripts/demo-arc-proxy.ps1 -PortForward`, which uses Arc
   Cluster Connect and needs no network path at all.

**MetalLB instead of ServiceLB?** Install MetalLB with an address pool from the cage subnet. Add
`metallb.io/address-pool: <pool>` to the **equinix** rule of `kubernetes/overrides/frontend-service-override.yaml`,
and set `EQUINIX_STOREFRONT_UPSTREAMS` to the VIP.

## Option B (Microsoft-first, preview): AKS on bare metal

[AKS on bare metal](https://learn.microsoft.com/azure/aks-hybrid-edge/bare-metal/aks-bare-metal-overview) deploys
AKS-managed Kubernetes directly on **Ubuntu 24.04.3/24.04.4** hosts that you own, and it's listed as a supported
Fleet Arc distribution. It's attractive for an Ignite stage, but note the **public preview limits** as of Sept 2026:

- Single-node clusters only, one cluster per host. There's no scaling.
- The Arc/AKS resources must be in **East US only**. That works with this demo: Fleet members can live in a different region from the hub.
- Clusters are created through the Azure CLI (Ubuntu path). Only patch upgrades are supported, and preview clusters may need to be recreated at GA.
- Cilium CNI is used. Preview meters are zero-rated, but the Arc-enabled machine and other services still bill.

**To use it:**
1. Follow the AKS on bare metal (Ubuntu) quickstart on a cage server, with the same egress proxy settings.
   Name the cluster `equinix-demo` in the demo resource group. Confirm in that quickstart which endpoints it
   needs, and add any extras to `PROXY_EXTRA_ALLOWED_DOMAINS` in `.env`.
2. In `.env`, set `EQUINIX_DISTRIBUTION=aks-baremetal`. This value is used only for the Fleet `provider` label.
   The cluster is already Arc-connected, so `make connect-arc` skips onboarding. If the connection doesn't
   use the Arc gateway yet, the script adds the gateway and proxy settings with `az connectedk8s update`.
3. Run `make join-fleet`. Every placement and override works unchanged.

Decide which option to use in advance: see [DECISIONS-REQUIRED.md](DECISIONS-REQUIRED.md).

## Rehearsal mode (before the cage is ready)

Set `ENABLE_EXPRESSROUTE=false` and point `EQUINIX_KUBE_CONTEXT` at any cluster you can reach:

- **k3d** on a laptop: `k3d cluster create equinix-demo -p "8081:80@loadbalancer"` then `kubectl config rename-context k3d-equinix-demo equinix-demo`
- **K3s on a small VM** in any cloud or lab.

`make connect-arc join-fleet deploy-workload` then onboards it with `connectivity=public-internet-rehearsal`,
and the storefront shows the **On-Premises** banner. Switch to the real cage later: disconnect the rehearsal
cluster (`az connectedk8s delete -n equinix-demo -g <rg>`), point the context at the cage cluster, set
`ENABLE_EXPRESSROUTE=true`, and continue from `make plan`.

# Networking: Equinix Fabric + Azure ExpressRoute + Azure Arc

This page follows the original plan for the demo: an ExpressRoute circuit, an Equinix Fabric
connection, private network access for Arc, and onboarding the cluster. For each step it shows
**what the repo automates**, the **equivalent portal clicks** (useful for slides and backup), and
**how to verify**.

> **Two corrections to the original plan, both based on current docs (Sept 2026):**
> 1. **Arc Private Link for Kubernetes is still preview.** It still requires internet access to Entra ID,
>    ARM, and MCR, and it doesn't support Cluster Connect. The supported path for an Arc cluster
>    behind a proxy, and the one **Fleet Manager requires**, is the **Azure Arc gateway** plus an
>    explicit *passthrough* proxy. This repo puts that proxy in the Azure hub VNet, where it's
>    reachable only over ExpressRoute.
> 2. **A DNS forwarder isn't needed for the Arc path.** With an explicit proxy, clients send hostnames
>    to the proxy, and the proxy resolves them in Azure. DNS forwarding of `privatelink.*` zones is only
>    needed for *routed* (proxy-less) access to private endpoints. That option is provided (`ENABLE_DNS_PRIVATE_RESOLVER`).

## Addressing plan (defaults)

| Item | Value | `.env` / variable |
|---|---|---|
| Equinix metro / ER peering location | `SV` / `Silicon Valley` (Equinix SV1, Zone 1) | `EQUINIX_METRO_CODE`, `ER_PEERING_LOCATION` |
| Circuit | Standard, MeteredData, 50 Mbps | `ER_BANDWIDTH_MBPS` |
| Private peering VLAN (C-tag) | 200 | `ER_VLAN_ID` |
| Primary / secondary peering /30 | 192.168.250.0/30, 192.168.250.4/30 (yours = .1/.5, Microsoft = .2/.6) | `ER_PRIMARY_PEER_PREFIX`, `ER_SECONDARY_PEER_PREFIX` |
| ASNs | Yours 65080 (port origin) or the FCR's Equinix ASN. Microsoft is 12076. | `EQUINIX_EDGE_ASN` |
| Port VLANs (port origin, DOT1Q) | 1010 primary, 1020 secondary | `EQUINIX_PRIMARY_VLAN_TAG`, `EQUINIX_SECONDARY_VLAN_TAG` |
| Equinix cage subnet (advertised to Azure) | 10.80.0.0/24 | `EQUINIX_ONPREM_PREFIXES` |
| Azure hub VNet (advertised to Equinix) | 10.50.0.0/16. GatewaySubnet 10.50.0.0/27, proxy 10.50.1.0/24 (proxy at **10.50.1.10:3128**) | terraform vars |
| AWS VPC | 10.60.0.0/16 (never routed to Equinix) | terraform var |

## Step 1: Create the ExpressRoute circuit (Azure)

**Automated** (`make apply` runs `terraform/azure/expressroute.tf`):
`azurerm_express_route_circuit` with `service_provider_name = "Equinix"`,
`peering_location = "Silicon Valley"`, a 50 Mbps bandwidth, and the `Standard`/`MeteredData` SKU. The
ExpressRoute **gateway** (`ErGwScale`, 1 scale unit) is created in the hub VNet's `GatewaySubnet` and takes
30–45 minutes.

**Portal equivalent:** Go to **Create a resource > ExpressRoute**, then set Provider = **Equinix**,
Peering location = **Silicon Valley**, Bandwidth = **50 Mbps**, SKU = **Standard**, and Billing = **Metered**.
When the circuit is created, copy the **Service key** from the circuit overview.

> ⚠️ **Billing starts when the service key is issued** (that is, when the circuit is created).

**Verify:**

```powershell
az network express-route show -g <rg> -n <circuit> --query "{provider:serviceProviderProvisioningState, circuit:circuitProvisioningState, location:serviceProviderProperties.peeringLocation}"
# provider: NotProvisioned  -> expected until Step 2 completes
```

## Step 2: Create the Equinix Fabric connection

**Automated** (`make connect-er` runs `scripts/05-connect-expressroute.ps1` with `terraform/equinix`):
- The script reads the service key from Azure state into a **process-scoped** `TF_VAR_expressroute_service_key`.
  It's never printed or stored.
- It orders a **redundant pair** of `equinix_fabric_connection` resources to the Azure ExpressRoute service
  profile `a1390b22-bbe0-4e93-ad37-85beef9d254d`, with `peering_type = "PRIVATE"`, a z-side
  `link_protocol { type = "QINQ", vlan_c_tag = 200 }` (this becomes the Azure peering VLAN), and
  your chosen **origin asset type**:

| `EQUINIX_FABRIC_ORIGIN` | A-side | Connection type | Who runs BGP with Microsoft |
|---|---|---|---|
| `port` (default) | Your primary and secondary Fabric ports (DOT1Q `vlan_tag`, or QinQ `vlan_s_tag` plus inner `vlan_c_tag` = the peering VLAN) | `EVPL_VC` | **Your edge router**. `scripts/05` renders `artifacts/edge-router-bgp-frr.conf` and `-iosxe.txt`. |
| `cloud_router` | An Equinix Fabric Cloud Router (created, or an existing UUID) | `IP_VC` | **The FCR**. Terraform adds the `DIRECT` (FCR = .1) and `BGP` (peer = .2, ASN 12076) routing protocols *after* Azure peering exists, following Equinix guidance. An optional FCR-to-cage leg gets its own Direct+BGP; `scripts/05` renders your cage router's half as `artifacts/edge-router-fcr-leg-frr.conf`. |
| `service_token` | An A-side token from a partner, Network Edge device, or another account | `EVPL_VC` | The token owner's device |

**Portal equivalent** (Equinix Customer Portal, **Fabric Dashboard**):
1. In the context switcher, pick your project. Go to **Connections > Create Connection**.
2. On the **A Service Provider** card, select **Connect to a Service Provider**. Then select **Microsoft Azure > Azure ExpressRoute > Quick Connect**.
3. Paste the **ExpressRoute service key**. Choose **Redundant** and peering type **Azure Private**.
4. Choose an **origin asset type**:
   - **Port**: select the primary and secondary ports and enter their VLAN IDs. You can optionally set the **Customer VLAN (C-Tag)** to 200.
   - **Cloud Router**: select the FCR and set the C-tag.
   - **Service Token**: enter the tokens.
5. Add notification emails, review the order, and select **Create Connection**.

**Status progression** (Equinix `equinixStatus` / `providerStatus`):
`PROVISIONING` → `PENDING_BGP_PEERING` / `PENDING_BGP` (Microsoft approved, waiting for peering) → `PROVISIONED`.
In Azure, the circuit's `serviceProviderProvisioningState` becomes **Provisioned**. `scripts/05` waits for
this state for up to 60 minutes.

**Verify:**

```powershell
make show-private-path        # step 1 of the proof panel shows the Equinix status of each connection
```

## Step 3: Azure private peering and BGP

**Automated:** After the circuit reports *Provisioned*, `scripts/05` regenerates the Azure tfvars with
`expressroute_private_peering_enabled = true` and applies them. That creates the following:
- `azurerm_express_route_circuit_peering` (`AzurePrivatePeering`) with the peer ASN, the two /30s, and VLAN 200.
- `azurerm_virtual_network_gateway_connection` (type `ExpressRoute`) that links the circuit to the hub gateway.

**Portal equivalent:** Open **Circuit > Peerings > Azure private**. Enter the peer ASN (65080, or the FCR ASN),
the primary subnet 192.168.250.0/30, the secondary subnet 192.168.250.4/30, and VLAN ID 200, then select **Save**.
Next, open **Hub VNet gateway > Connections > Add**, choose type **ExpressRoute**, and select the circuit.
In the Equinix portal, open the connection and use **Sync BGP Peering**, or wait for the periodic sync.

**Your edge router (port origin):** apply `artifacts/edge-router-bgp-frr.conf` (FRR) or
`artifacts/edge-router-bgp-iosxe.txt` (IOS-XE). Each config does three things:
- Brings up sub-interfaces on VLAN 1010 and 1020 with .1 and .5.
- Forms eBGP sessions with 192.168.250.2 and 192.168.250.6 (AS 12076).
- Advertises `10.80.0.0/24`.

The cage nodes' default route must point at this router. The router learns `10.50.0.0/16` from Azure.

**Verify:**

```powershell
az network express-route list-route-tables-summary -g <rg> -n <circuit> --path primary --peering-name AzurePrivatePeering
az network vnet-gateway list-learned-routes -g <rg> -n <gateway>   # expect 10.80.0.0/24, origin EBgp, AS path 65080
```

On the router, run `show bgp summary` and `show ip route 10.50.1.10`. `scripts/05` exits successfully only
after the gateway has learned **every** prefix in `EQUINIX_ONPREM_PREFIXES`.

## Step 4: Private network access for Arc (Arc gateway + egress proxy)

**Automated** (`terraform/azure/egress-proxy.tf`, `scripts/06-connect-arc.ps1`):
- The **egress proxy VM** (Ubuntu 24.04, Squid) runs at a static IP of `10.50.1.10:3128`. It accepts connections only from the
  Equinix prefixes (NSG plus Squid ACL) and passes through CONNECT tunnels **without TLS interception**.
  It allows only the allowlist described in [ARCHITECTURE.md](ARCHITECTURE.md#the-private-path-equinix-member).
  The VM gets outbound access from its own Standard public IP. Its subnet is private, with no default outbound access.
- The **Azure Arc gateway** (`az arcgateway create --gateway-type public --allowed-features *`) takes about 30 minutes
  the first time. It reduces the Arc agents' endpoint list to about 9 FQDNs.

**Optional "Private Link" extras** (from the original plan):
- `ENABLE_PRIVATE_ACR=true` creates a Premium ACR with **public access disabled**, anonymous pull, and a private
  endpoint in the hub, with `privatelink.azurecr.io` linked to the hub VNet. `scripts/08` imports the demo
  images (keeping their upstream paths). Run the K3s installers with `PRIVATE_ACR=<name>.azurecr.io` to
  configure containerd mirrors. Pulls go from the node through the proxy (over ER) to the private endpoint, so no
  public path is involved.
- `ENABLE_DNS_PRIVATE_RESOLVER=true` creates an inbound endpoint at `10.50.2.4`. Configure your cage DNS to forward
  `privatelink.*` zones there for routed, proxy-less access to private endpoints. For example, with a K3s CoreDNS
  `coredns-custom` ConfigMap:

  ```yaml
  apiVersion: v1
  kind: ConfigMap
  metadata: { name: coredns-custom, namespace: kube-system }
  data:
    privatelink.server: |
      privatelink.azurecr.io:53 {
        forward . 10.50.2.4
      }
  ```

  Don't add an outbound endpoint with **wildcard** forwarding rules to a VNet that hosts an ER gateway.

**Verify (on a cage node):** `EGRESS_PROXY=http://10.50.1.10:3128 ./equinix/k3s/verify-egress.sh` checks
four things: the route to the hub goes through the edge router, Azure endpoints return 200 through the proxy,
example.com gets a 403, and there's no direct egress.

## Step 5: Connect the Equinix cluster to Azure Arc

**Automated** (`make connect-arc`):

```powershell
az connectedk8s connect --name equinix-demo --resource-group <rg> --location <region> `
  --kube-context equinix-demo --distribution k3s --infrastructure generic `
  --gateway-resource-id <arc-gateway-id> `
  --proxy-https http://10.50.1.10:3128 --proxy-http http://10.50.1.10:3128 `
  --proxy-skip-range 10.42.0.0/16,10.43.0.0/16,10.80.0.0/24,kubernetes.default.svc,.svc.cluster.local,.svc,localhost,127.0.0.1
```

Container images for the agents are pulled by **containerd**, not by the agents. That's why K3s itself is
installed with `HTTP(S)_PROXY` set (`equinix/k3s/install-k3s-server.sh`).

**Verify:**

```powershell
az connectedk8s show -n equinix-demo -g <rg> --query "{status:connectivityStatus, gateway:gateway.enabled, version:agentVersion}"
kubectl get pods -n azure-arc --context equinix-demo                 # find the Arc Proxy pod (arc-proxy-*, agent >= 1.21.10)
kubectl logs -n azure-arc <arc-proxy-pod> --context equinix-demo --tail 20
make show-private-path   # step 4 shows Squid log lines: <equinix-node-ip> TCP_TUNNEL/200 CONNECT <prefix>.gw.arc.azure.com:443
```

## Production hardening checklist

- [ ] Replace the single proxy VM with **Azure Firewall (explicit proxy)** or a highly available proxy pair, and log to Log Analytics.
- [ ] **Exclude** `*.gw.arc.azure.com` from TLS inspection (an Arc gateway requirement).
- [ ] Use **ExpressRoute Metro** or two peering locations for maximum resiliency. Equinix supports Metro in Amsterdam, Atlanta, Chicago, Madrid, Milan, and Singapore.
- [ ] Add a BGP MD5 key (`shared_key` on the peering) and BFD.
- [ ] Use route filters and summarized advertisements (`summarizedGatewayPrefixes`) as the hub/spoke design grows.
- [ ] Consider a **private Fleet hub**. Arc members must use the Arc gateway, which this design already does.

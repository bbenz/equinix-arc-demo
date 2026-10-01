# Decisions required before a real (non-rehearsal) run

The repo runs end to end with the defaults. The items below are things only you (or Equinix) can
provide or decide. Until they're settled, use **rehearsal mode** (`ENABLE_EXPRESSROUTE=false`).

| # | Decision / input | Default in this repo | Where to set it |
|---|---|---|---|
| 1 | **Equinix origin asset type**: Fabric ports in your cage, a Fabric Cloud Router, or a partner/Network Edge service token | `port` (redundant DOT1Q pair, your edge router runs BGP) | `EQUINIX_FABRIC_ORIGIN` + the matching block in `.env` |
| 2 | **Compute at Equinix.** Equinix Metal ended on 2026-06-30, so who provides the servers, in which IBX, on which subnet? | 1–3 Ubuntu 24.04 servers in **SV**, `10.80.0.0/24` | `EQUINIX_ONPREM_PREFIXES`, [EQUINIX-CLUSTER.md](EQUINIX-CLUSTER.md) |
| 3 | **Distribution**: K3s (GA path) or AKS on bare metal (preview: single node, East US only) | K3s | `EQUINIX_DISTRIBUTION` |
| 4 | **Equinix credentials**: API client ID/secret, project ID, account number (FCR), notification emails | None (required) | Shell env vars + `.env` |
| 5 | **BGP and addressing**: your ASN, the two /30s, the peering VLAN, port VLANs. These must not overlap Equinix or corporate ranges. | 65080, 192.168.250.0/30 and .4/30, VLAN 200, VLANs 1010/1020 | `.env` (`ER_*`, `EQUINIX_*`) |
| 6 | **Metro and peering location** | SV / Silicon Valley (closest to Moscone) | `EQUINIX_METRO_CODE`, `ER_PEERING_LOCATION` |
| 7 | **Run window and budget**: the circuit bills from creation, and the gateway and Arc gateway each take 30–45 minutes. Keep the Arc gateway between rehearsals? That requires its own resource group, set before the first deploy. | Create at T-7 days, destroy after the event. Arc gateway in the demo group (deleted on teardown). | [DEMO-RUNSHEET.md](DEMO-RUNSHEET.md), `ARC_RESOURCE_GROUP` + `99-destroy-all.ps1 -KeepArcGateway` |
| 8 | **How the audience sees the Equinix storefront**: Azure-hub nginx (needs the presenter's IP) or Arc Cluster Connect port-forward | Both available | `STOREFRONT_ALLOWED_CIDRS`, `scripts/demo-arc-proxy.ps1` |
| 9 | **Fleet hub API**: public or private | Public (a private hub needs a jump box) | `terraform/azure/fleet.tf` |
| 10 | **Optional Private Link extras**: private ACR, DNS Private Resolver | Off | `ENABLE_PRIVATE_ACR`, `ENABLE_DNS_PRIVATE_RESOLVER` |

## Resolved by research (no action needed)

- **Arc path:** Arc gateway plus a passthrough proxy over ER private peering, not Arc Private Link
  (still preview) and not Microsoft peering. Fleet requires Arc gateway for proxied Arc members.
- **ExpressRoute gateway:** ErGwScale with 1 scale unit and an Azure-managed public IP.
- **Provider versions:** azurerm 5.7 (v5 breaking changes handled), azapi 2.13, aws 6.x, equinix 5.2.
- **Workload placement on Arc members** is GA. Fleet update runs remain AKS-only.

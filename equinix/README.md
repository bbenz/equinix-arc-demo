# equinix/ – assets that run at the Equinix site

Terraform can't create anything in this folder. Equinix Metal (bare metal as a service)
reached **end of life on June 30, 2026**, and the Equinix Terraform provider v5 removed every
`equinix_metal_*` resource. The Kubernetes cluster for this demo therefore runs on
**hardware in an Equinix IBX**: your colocated servers, Equinix-managed servers, or a
bare-metal partner in the same metro. Terraform (`terraform/equinix`) manages only the
**Equinix Fabric** side.

| Path | Run where | Purpose |
|---|---|---|
| `k3s/install-k3s-server.sh` | First cage server (Ubuntu 24.04, as root) | Installs K3s behind the Azure egress proxy. It disables Traefik, enables embedded etcd, and can optionally use a private ACR mirror. |
| `k3s/install-k3s-agent.sh` | Each additional cage server | Joins an agent node. |
| `k3s/verify-egress.sh` | Any cage server | Proves the egress posture: Azure works through the proxy over ExpressRoute, everything else is blocked, and there's no direct internet path (a direct path fails the check unless `ALLOW_DIRECT_EGRESS=1`). |
| `edge-router/frr-bgp.conf.template` | Rendered by `scripts/05-connect-expressroute.ps1` | BGP to Microsoft (port origin) for an FRR/Linux edge router. |
| `edge-router/cisco-iosxe-bgp.txt.template` | Same | Same configuration for Cisco IOS-XE. |

Expected cage layout (defaults, change them in `.env`):

```text
 Equinix SV cage                                 Equinix Fabric            Azure (westus2)
┌───────────────────────────────┐   primary  ┌───────────────┐   ┌──────────────────────────────┐
│ k3s nodes 10.80.0.0/24        │──VLAN1010──│ EVPL_VC pri ──┼──▶│ ExpressRoute "Silicon Valley" │
│   default gw = edge router    │            │               │   │  private peering (VLAN 200)   │
│ edge router  AS65080 ── BGP ──┼──VLAN1020──│ EVPL_VC sec ──┼──▶│  ER gateway ─ hub 10.50.0.0/16│
└───────────────────────────────┘ secondary  └───────────────┘   │   egress proxy 10.50.1.10:3128│
                                                                  └──────────────────────────────┘
```

See [docs/EQUINIX-CLUSTER.md](../docs/EQUINIX-CLUSTER.md) for the full cluster runbook,
including **AKS on bare metal (preview)** as a Microsoft-first alternative to K3s, and
[docs/NETWORKING-EXPRESSROUTE.md](../docs/NETWORKING-EXPRESSROUTE.md) for the network path.

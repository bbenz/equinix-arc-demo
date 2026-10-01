# Demo runsheet: Microsoft Ignite 2026 (Nov 17–20, Moscone, San Francisco)

**Story in one line:** *One Fleet Manager control plane deploys the same app to AKS, EKS, and Kubernetes
at Equinix. The Equinix cluster is managed through Azure Arc with no internet path at all: every byte to
Azure crosses Equinix Fabric and ExpressRoute.*

## Preparation timeline

| When | What | Commands / owner |
|---|---|---|
| **T-21 days** | Equinix side ordered: cage, servers racked (Ubuntu 24.04), cross-connects, **Fabric ports** (or FCR), routed subnet, edge router. BGP parameters agreed. Equinix API app created. | Equinix account team + you. See [DECISIONS-REQUIRED.md](DECISIONS-REQUIRED.md). |
| **T-14 days** | Rehearse the Fleet story in **rehearsal mode** (`ENABLE_EXPRESSROUTE=false`, k3d/K3s anywhere). | `make check-tools bootstrap-auth test-access select-regions plan apply connect-arc join-fleet deploy-workload validate` |
| **T-8 days** | Switch to the real path: `ENABLE_EXPRESSROUTE=true`, fill in the Equinix `.env` values. **Billing for the circuit starts now.** | `make plan apply` (ER gateway 30–45 min) |
| **T-8 days** | Order Fabric, wait for provisioning, enable private peering, configure BGP on the edge router. | `make connect-er` (re-run until it reports the path is UP) |
| **T-7 days** | Install K3s through the proxy, verify egress, onboard Arc (Arc gateway takes about 30 min the first time), join Fleet, deploy. | `verify-egress.sh`, `install-k3s-server.sh`, `make connect-arc join-fleet deploy-workload validate` |
| **T-7 days** | **Record the backup video** (silent, 5 min, see below) plus screenshots of every step. | OBS or Clipchamp |
| **T-2 days** | Dress rehearsal with the session owner. Run `make validate` and `make show-private-path`. | |
| **T-1 day** | Set `STOREFRONT_ALLOWED_CIDRS` to the **venue egress IP** (check it at Moscone), then run `make plan apply`. Confirm the hub URL loads from the venue network. | |
| **T-2 hours** | Fresh logins (`az login`, `aws sso login`), Equinix credentials in the shell, kubelogin token warm (`kubectl get memberclusters --context fleet-hub-demo`). Run `make validate`, then `scripts/demo-arc-proxy.ps1` (start the Arc session). Open the browser tabs (below). | |
| **After the event** | `make destroy` (it waits for Equinix to release the circuit). Delete or rotate the Equinix API app. | |

**Browser tabs, in order:** (1) the architecture slide, (2) Azure portal > Fleet Manager > **Member
clusters**, (3) Azure portal > ExpressRoute circuit > **Peerings**, (4) Azure portal > Arc
`equinix-demo` > **Overview**, (5) the AKS storefront, (6) the EKS storefront, (7) the Equinix storefront (hub URL),
(8) VS Code on `kubernetes/`.
**Terminal:** a large font with `$PWD` in the repo, and the `fleet-hub-demo` context warm.

## On-stage script (about 12 minutes)

| Time | Screen | Action | Talking point | Expected result | Fallback |
|---|---|---|---|---|---|
| 0:00–1:00 | Architecture slide | None | "Three footprints, one fleet. AKS in Azure and EKS in AWS reach Azure over the internet. The cluster in an Equinix cage in Silicon Valley, about 50 miles from here, has **no internet path at all**." | | |
| 1:00–2:30 | Portal: Fleet Manager > Member clusters | Click `equinix-demo` > **Labels** | "Arc-enabled clusters are first-class Fleet members, and workload placement is GA. Labels tell Fleet where each one lives: `cloud=equinix`, `connectivity=expressroute`." | 3 members, all *Succeeded* | Screenshot slide |
| 2:30–4:30 | Terminal | `make show-private-path` | "Here's the proof. Equinix Fabric reports PROVISIONED. Azure learned the cage subnet over BGP. The Equinix cluster is Connected through the **Arc gateway**. In the proxy log in Azure, every Arc tunnel comes **from an Equinix node IP**, across ExpressRoute." | Green lines: `10.80.0.0/24` learned, `gateway=True`, `CONNECT …gw.arc.azure.com` from `10.80.0.x` | Pre-captured output (screenshot) |
| 4:30–5:30 | Portal: ER circuit > Peerings (optional) | Show *Provider status: Provisioned*, Azure private peering | "Provisioned with Equinix Quick Connect, entirely as code. Terraform for both Azure and Equinix is in the repo." | | Skip |
| 5:30–6:30 | VS Code: `kubernetes/base` + `fleet/cluster-resource-placement.yaml` | Scroll | "One cloud-neutral app definition, with no cloud annotations. One placement: every member of this demo." | | |
| 6:30–7:30 | VS Code: `overrides/frontend-env-platform-override.yaml` | Highlight the three rules | "What differs is expressed as overrides selected by label: Azure, AWS, **On-Premises** for the Equinix cage, and load balancer settings per footprint." | | |
| 7:30–9:30 | Browser tabs 5–7 | Add an item to the cart in each | "Same app, three independent copies, each with its own Redis. Look at the banners: Azure, AWS, **On-Premises**. That's the override, not a fork. This Equinix storefront is served **from the cage through Azure over ExpressRoute**." | HTTP 200, a banner on each, independent carts | `scripts/demo-arc-proxy.ps1 -PortForward` then http://localhost:8080, or a screenshot |
| 9:30–11:00 | Terminal | Edit the equinix rule of `frontend-service-override.yaml` (add `demo.equinix-arc.io/ignite: "2026"`), run `kubectl apply -f <rendered file> --context fleet-hub-demo`, then `kubectl get svc frontend-external -n online-boutique -o jsonpath="{.metadata.annotations}" --kubeconfig artifacts\equinix-arc-proxy.kubeconfig --context equinix-demo` | "A change goes to the hub. Fleet reconciles it onto the Equinix cluster over the private path, and I'm reading it back through **Arc Cluster Connect**: no VPN, no inbound port on the cage." | The annotation appears within about 30 seconds | Show the CRP status in the portal |
| 11:00–12:00 | Closing slide | None | "Fleet for consistency, Arc for reach, Equinix Fabric plus ExpressRoute for a private path, and the code for all of it is public." | | |

**Rendered override file for the live edit:** `artifacts\rendered-overrides\frontend-service-override.yaml`.
Edit that copy on stage, because it already has the AWS subnets filled in. Afterward, copy the change back to
`kubernetes/overrides/` and re-run `make deploy-workload`.

### Q&A crib

- *What happens if ExpressRoute fails?* The Equinix storefront keeps serving locally. Arc shows the cluster as
  Offline, and Fleet changes queue until the link returns. For production, use two peering locations or ER Metro.
- *Why not Arc Private Link?* It's still preview for Kubernetes, still needs Entra ID, ARM, and MCR over the
  internet, and has no Cluster Connect. Arc gateway is the documented requirement for Fleet members behind a proxy.
- *Can Fleet upgrade the Equinix cluster?* Not today. Update runs are AKS-only. Placement and overrides
  are GA for Arc members.
- *Why not Equinix Metal?* It reached end of life in June 2026. This demo runs on colocated hardware, which is
  how most enterprises already use Equinix.
- *What does it cost?* About $0.89/hr for Azure and AWS, plus $55/month for the circuit. The Equinix side
  is quoted separately. See the README.

## Silent backup video (about 5 minutes)

| Timestamp | On screen | Caption |
|---|---|---|
| 0:00–0:20 | Architecture slide | One fleet: AKS, EKS, and Kubernetes at Equinix (private over ExpressRoute) |
| 0:20–0:50 | Fleet Manager > Member clusters, then the `equinix-demo` labels | Arc-enabled members are first-class, and labels drive placement |
| 0:50–1:40 | `make show-private-path` | Equinix Fabric PROVISIONED, BGP routes learned, Arc gateway enabled, proxy log shows Equinix IPs |
| 1:40–2:10 | ER circuit > Peerings; Arc `equinix-demo` overview | Provisioned with Equinix Quick Connect, with Terraform for Azure and Equinix |
| 2:10–2:50 | VS Code: base + CRP + overrides | One definition, label-selected overrides |
| 2:50–3:50 | Three storefronts and their carts | Azure / AWS / On-Premises banners, independent carts |
| 3:50–4:40 | Live override change, read back through Arc Cluster Connect | A change reconciles over the private path, with no VPN |
| 4:40–5:00 | Closing slide | Code: github.com/bbenz/equinix-arc-demo (proposed) |

## Reset between sessions

```powershell
make deploy-workload     # re-asserts base + overrides (undoes live edits once copied back)
make validate
scripts/demo-arc-proxy.ps1 -Stop; scripts/demo-arc-proxy.ps1
```

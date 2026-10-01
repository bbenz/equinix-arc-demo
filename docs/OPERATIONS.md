# Operations

## Idempotent re-runs

Every numbered script can be re-run. Fix the one blocked thing and then re-run the same step:

- `03-init-plan` regenerates tfvars from `.env`. The private peering flag comes from the **live circuit
  state**, so a re-plan never removes a working peering.
- `05-connect-expressroute` converges the Equinix root, waits for the provider, enables peering, and waits for BGP.
  Re-run it after you configure the edge router.
- `06-connect-arc` skips clusters that are already `Connected`. An Equinix cluster that's connected without the
  gateway is switched over with `az connectedk8s update --gateway-resource-id`.
- `07-join-fleet` uses create-or-update for members, which also re-applies labels. It assigns hub RBAC only if
  the assignment is missing.
- `08-deploy-workload` uses `kubectl apply` against the hub, so edits reconcile in place.
- `99-destroy-all` tolerates resources that are already gone.

## Pause and resume between rehearsals

| Component | Can pause? | How | Watch out for |
|---|---|---|---|
| Fleet hub | **No** | Leave it running | Stopping it stops management of all members |
| AKS `aks-demo` | Yes, fully (control plane + nodes) | `az aks stop` / `az aks start` (`-g <rg> -n eqarc-demo-aks`) | Wait 15–30 minutes between stop and start. Re-run `make validate` because the LB IP can change. |
| EKS `eks-demo` | Nodes only (the control plane still bills $0.10/hr) | `aws eks update-nodegroup-config --cluster-name eqarc-demo-eks --nodegroup-name eqarc-demo-nodes --scaling-config minSize=0,maxSize=0,desiredSize=0` | Arc shows *Offline* while scaled to 0, which is expected. Restore with `minSize=1,maxSize=3,desiredSize=2`. |
| Equinix cluster | Your hardware | Leave it running | |
| Egress proxy VM | Yes | `az vm deallocate` / `az vm start -g <rg> -n eqarc-demo-egress-proxy` | While it's stopped, the Equinix cluster is **cut off from Azure** (Arc goes Offline, and image pulls fail). The private IP is static, so it resumes cleanly. |
| ExpressRoute gateway | **No** | Delete and recreate only (30–45 min) | |
| ExpressRoute circuit | **No** | Delete and re-order only (needs Equinix deprovisioning and reprovisioning) | Billing runs from creation to deletion. Keep it for the whole event week. |
| Arc gateway | Not needed | No separate charge for the gateway resource was listed at the time of writing. Check the [Azure Arc pricing page](https://azure.microsoft.com/pricing/details/azure-arc/core-control-plane/) to confirm. | Recreating it takes about 30 minutes |

## Cost monitoring

- Everything Terraform creates is tagged with `project=equinix-arc-demo`, `owner=<OWNER>`, `demo=equinix-arc-online-boutique`,
  and `expiration_date`.
- In Azure, use **Cost Management** filtered by tag `project=equinix-arc-demo`. In AWS, use **Cost Explorer** with the same tag.
- For Equinix, use the Fabric billing in the Equinix portal. Fabric connections and FCRs are usually committed monthly,
  so confirm the term with your account team.

## Changes

| Change | How |
|---|---|
| Allow another egress FQDN | Add it to `PROXY_EXTRA_ALLOWED_DOMAINS` in `.env`, then `make plan apply`. Run Command updates Squid in place. |
| Publish or unpublish the Equinix storefront | Set `EQUINIX_STOREFRONT_UPSTREAMS` and `STOREFRONT_ALLOWED_CIDRS`, then `make plan apply` |
| Venue IP changed | Update `STOREFRONT_ALLOWED_CIDRS`, then `make plan apply` (it updates the NSG rule only) |
| Bump Online Boutique | Change the image tags in `kubernetes/base/*.yaml`, then `make deploy-workload validate`. Fleet rolls the change to all three members. |
| Bump K3s | Re-run `install-k3s-server.sh` with `K3S_VERSION=` (and do the same on the agents). Check the Arc validation matrix first. |
| Upgrade Arc agents | Auto-upgrade is on by default. To upgrade manually: `az connectedk8s upgrade -n equinix-demo -g <rg>`. |
| Rotate Equinix API credentials | Create a new app secret in the Developer Portal, update the shell environment variables, and delete the old secret |
| Add a 4th footprint | Arc-connect it, `az fleet member create ... --member-labels "cloud=<x> ..."`, and add one rule per override file. The base and the CRP don't change. |

## Teardown

```powershell
make destroy     # typed confirmation 'destroy'; add -KeepArcGateway to the script to keep the gateway
```

Teardown runs in this order:
1. The hub workload. Then the script waits for the EKS storefront load balancer to be released, because an
   orphaned NLB would block the VPC deletion later.
2. The Arc-backed Fleet members (the AKS member is Terraform-managed).
3. The Arc connections (EKS, Equinix) and the Arc gateway.
4. `terraform/equinix` destroy, where the provider waits until each connection is `DEPROVISIONED`.
5. A wait for the circuit to reach `NotProvisioned`, because Azure refuses to delete a circuit the provider still holds.
6. `terraform/aws` destroy, then `terraform/azure` destroy.

Teardown is driven by what exists (Terraform state, Azure resources, kube contexts), not by the `ENABLE_*`
flags, so changing `.env` after a deployment never leaves resources behind. Every delete is checked:
only a confirmed "not found" counts as already gone, and the script stops if the az CLI points at a
different subscription than the deployment. `-KeepArcGateway` works only when the gateway lives in its own
resource group (`ARC_RESOURCE_GROUP`, set before deploying), because step 6 deletes the Terraform-managed group.

These resources are **left in place on purpose**: the Equinix servers and K3s, your kube contexts,
resource-provider registrations, and anything you ordered from Equinix outside this repo (ports, cage).

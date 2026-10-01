# Troubleshooting

Entries marked 🧪 were reproduced and fixed during the `fleet-manager-arc-demo` runs (July 2026), and
their fixes are already built into this repo. The other entries are specific to the ExpressRoute and
Equinix path.

## Tooling and authentication

| Symptom | Cause | Fix |
|---|---|---|
| 🧪 `running scripts is disabled on this system` | Windows PowerShell 5.1 has a `Restricted` execution policy | Use `pwsh`, or run `powershell -ExecutionPolicy Bypass -File ...` (the Makefile already does this) |
| 🧪 `AttributeError ... NormalizedResponse` from every `az` command | Stale MSAL HTTP cache after a CLI upgrade | `Remove-Item "$env:USERPROFILE\.azure\msal_http_cache.bin"` (only this file) |
| 🧪 Azure CLI extension import errors after upgrading the CLI | Binary extension built against the old Python | Remove and re-add the extension (`az extension remove/add -n connectedk8s`) |
| 🧪 `aws: error: [-o] is not a valid option` | The AWS CLI accepts only `--output` | Scripts always use `--output json` |
| 🧪 `aws login` returns HTTP 400 | The IAM user lacks `SignInLocalDevelopmentAccess` | Use SSO (`aws configure sso`) or attach that policy |
| `kubectl` to `fleet-hub-demo` prompts for a device code or fails with `kubelogin not found` | The hub is protected by Entra ID | Install kubelogin, then run `kubelogin convert-kubeconfig -l azurecli --context fleet-hub-demo` (`scripts/07` does this) |
| 🧪 `Forbidden` on the hub even as subscription Owner | Owner doesn't grant Kubernetes data-plane access | Assign **Azure Kubernetes Fleet Manager RBAC Cluster Admin** on the fleet (`scripts/07` does this), then wait about 1 minute |
| `MissingSubscriptionRegistration` during `terraform apply` | azurerm 5.x no longer auto-registers resource providers | `pwsh scripts/01-test-cloud-access.ps1 -RegisterProviders` |
| `subscription ID could not be determined` from `terraform plan` in `terraform/azure` | You ran Terraform by hand. Since azurerm 4.0 the provider needs an explicit subscription, even with Azure CLI auth. | The scripts pass it for you. By hand, first run `$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv` |
| `ARM_SUBSCRIPTION_ID (...) differs from the Azure CLI subscription` | An `ARM_SUBSCRIPTION_ID` in your environment points at another subscription than `az account show` | `Remove-Item Env:ARM_SUBSCRIPTION_ID`, or `az account set --subscription <id>` |
| `Equinix token request failed` | Wrong client ID or secret, or the app is disabled | Re-create the secret in the Developer Portal, then reset the shell environment variables |

## ExpressRoute and Equinix Fabric

| Symptom | Cause | Fix |
|---|---|---|
| The circuit stays `NotProvisioned` | The Fabric order isn't placed or approved yet, or the service key was used in another **metro** or with a different **bandwidth** | Check the Equinix portal (**Connections**). `scripts/05` prints `equinixStatus` and `providerStatus`. Make sure `EQUINIX_METRO_CODE` matches `ER_PEERING_LOCATION` (`scripts/02` warns about mismatches). |
| Equinix shows `PENDING_BGP_PEERING` indefinitely | Azure private peering isn't configured yet, or the VLAN C-tag differs from the Azure peering VLAN | Re-run `make connect-er`. Check that `ER_VLAN_ID` equals the C-tag. Use **Sync BGP Peering** in the Equinix portal. |
| `list-route-tables-summary` shows the neighbor as `Idle` or `Active` (no prefix count) | BGP isn't established. Usual causes: the /30 addresses are swapped (you must use **.1** and **.5**), the ASN differs from `EQUINIX_EDGE_ASN`, the router uses the wrong VLAN, or there's an MD5 mismatch | Compare the router config with `artifacts/edge-router-bgp-*.conf`. For FCR origin, check the routing protocol state in the Equinix portal. |
| The gateway hasn't learned `10.80.0.0/24` | The router isn't advertising it (no `network` statement, or the prefix isn't in its RIB) | Add the network or a static route. Re-run `make connect-er`. |
| Nodes can't reach `10.50.1.10` | The nodes' default route doesn't point at the ER edge, or Azure routes weren't learned on the router | Run `ip route get 10.50.1.10` on a node, then check BGP received routes on the router |
| `terraform destroy` of `azure` fails on the circuit | Equinix still provisions the circuit | Destroy `terraform/equinix` first. `make destroy` does this and waits for `NotProvisioned`. |
| ER gateway creation takes more than 45 minutes or times out | Normal for ExpressRoute gateways | Re-run `make apply`. Terraform resumes. |

## Egress proxy, Arc, and Fleet (Equinix member)

| Symptom | Cause | Fix |
|---|---|---|
| `TCP_DENIED/403` in the Squid log (`make show-private-path`) | The FQDN isn't on the allowlist | Add it to `PROXY_EXTRA_ALLOWED_DOMAINS`, then `make plan apply` (Run Command updates Squid in place) |
| Arc or Fleet pods in `ImagePullBackOff` on the Equinix cluster | containerd has no proxy, because K3s was installed without `EGRESS_PROXY` | Fix `/etc/systemd/system/k3s.service.env` (HTTP_PROXY, HTTPS_PROXY, NO_PROXY), then `systemctl restart k3s` (and `k3s-agent` on agent nodes) |
| `az connectedk8s connect` hangs at the Helm step | The workstation can't reach the K3s API, or the agents can't reach Azure through the proxy | Run `kubectl get nodes --context equinix-demo` and `verify-egress.sh` on a node. After the fix, re-run `make connect-arc`. It checks the resource state before failing (🧪 a timeout after a successful onboarding is common). |
| `gateway.enabled` is false, or the cluster went *Offline* after moving from rehearsal mode to the cage | The connection was made without the Arc gateway and proxy settings | Re-run `make connect-arc`. It applies the gateway **and** the proxy settings together with `az connectedk8s update`. |
| `az arcgateway` isn't recognized | The extension is missing | `make check-tools` installs it (`az extension add -n arcgateway`) |
| `equinix-demo` is a Fleet member, but `Joined=False` | The Fleet member agent can't reach the hub API server (`*.azmk8s.io`) | Run `kubectl logs -n fleet-system --context equinix-demo deploy/<member-agent>`. Confirm `.azmk8s.io` is allowed (it is by default) and that the Squid log shows the CONNECT. |
| The cluster shows *Offline* in Arc | The proxy VM is stopped, the ER/BGP session is down, or the nodes are scaled to 0 | `make show-private-path` shows which hop is broken |
| A TLS error mentioning the proxy | Something in the path inspects TLS | The Arc gateway and Fleet don't support TLS-terminating proxies. Use passthrough only. |

## Workload

| Symptom | Cause | Fix |
|---|---|---|
| `frontend-external` is `Pending` on K3s | Traefik already owns port 80 through ServiceLB | Reinstall with `--disable traefik` (the installers do this), or remove the Traefik HelmChart |
| 🧪 The frontend crash-loops on v0.10.6 | `SHOPPING_ASSISTANT_SERVICE_ADDR` is missing | It's already set in `kubernetes/base/frontend.yaml` |
| 🧪 Singleton pods can't be scheduled on 2-node clusters during updates | A RollingUpdate holds the old pod's CPU | The frontend and load generator use `strategy: Recreate`, and the load generator requests only 50m CPU |
| 🧪 The AWS NLB resolves to private IPs, or no subnets are found | The LBC defaults to the `internal` scheme | The override sets `internet-facing` plus explicit subnets (rendered from Terraform by `scripts/08`) |
| 🧪 An EC2 security group rule fails to create | The description contains `>` | Avoided in `terraform/aws` |
| 🧪 AKS plans show drift right after creation | Node pool upgrade defaults | `upgrade_settings` is pinned in `terraform/azure/aks.tf` |
| The banner check in `make validate` fails but HTTP returns 200 | The `frontend-env-platform-override` rule didn't match | Check that the member labels include `cloud=azure`, `cloud=aws`, or `cloud=equinix` (`kubectl get memberclusters --show-labels --context fleet-hub-demo`) |
| `az vm run-command` is slow or reports a conflict | Only one Run Command runs per VM at a time (Terraform's run command may be running) | Wait and retry, or run `pwsh scripts/09-validate-demo.ps1 -SkipRunCommand` |

## Teardown

| Symptom | Cause | Fix |
|---|---|---|
| `make destroy` stops: `-KeepArcGateway can't work here` | The Arc gateway is in the Terraform-managed resource group, which step 6 deletes | Run without `-KeepArcGateway`. To keep the gateway across future teardowns, set `ARC_RESOURCE_GROUP` to a separate group **before** deploying (`scripts/06` creates it). |
| `make destroy` stops: `The Azure CLI is on subscription ...` | The az CLI points at another subscription than the deployment | `az account set --subscription <id>`, then re-run. (Teardown refuses to guess: in the wrong subscription every resource would look already deleted.) |
| `terraform destroy` of `aws` fails with `DependencyViolation` on a subnet, the internet gateway, or a security group | The storefront NLB (`k8s-*`) outlived the load balancer controller, usually because EKS wasn't reachable when `make destroy` ran | Delete the `k8s-*` load balancer and its `k8s-*` security groups in the EC2 console, then re-run `make destroy` |
| The circuit stays `Deprovisioning` and teardown times out | Equinix hasn't released the circuit yet | Check the Equinix portal, then re-run `make destroy` (it's idempotent and keeps waiting for `NotProvisioned`) |

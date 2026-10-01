# Authentication and permissions

## Principles

- Only **official, interactive logins** are used (`az login`, `aws sso login`, an Equinix Developer
  Portal app). Console credentials can never be turned into API credentials by a script, and this repo
  never tries.
- **No secrets in `.env`, tfvars, or git.** `.env` holds configuration only. `scripts/lib/secret-scan.ps1`
  (`make secret-scan`) and the CI workflow add a second line of defense on top of `.gitignore`.
- **Equinix API credentials** live only in your shell (`EQUINIX_API_CLIENTID` / `EQUINIX_API_CLIENTSECRET`,
  or `EQUINIX_API_TOKEN`).
- The **ExpressRoute service key** moves from Azure state to the Equinix root in a **process-scoped**
  `TF_VAR_expressroute_service_key`, which `scripts/05` sets and removes. It's never printed.
- **Terraform state is sensitive.** It contains the service key, the AKS kubeconfig, and the generated SSH key of the
  proxy VM (which has no inbound SSH). State is local and gitignored. Use an encrypted remote backend
  (`terraform/bootstrap`) beyond a single-operator demo.

## Azure

```powershell
az login
az account set --subscription "<name-or-id>"
```

Since azurerm 4.0, Terraform needs an explicit subscription even with Azure CLI auth. The scripts pass
the CLI's active subscription as a process-scoped `ARM_SUBSCRIPTION_ID` for each plan, apply, and destroy.
They stop if an `ARM_SUBSCRIPTION_ID` already in your environment points somewhere else. If you run `terraform`
by hand in `terraform/azure`, first run `$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv`.

| Need | Role / permission | Scope |
|---|---|---|
| Create everything (simplest) | **Owner** | Subscription or a pre-created resource group |
| Least-privilege alternative | **Contributor** + **User Access Administrator** (the latter only to grant the hub role below) | Resource group |
| Register resource providers (`scripts/01 -RegisterProviders`) | `*/register/action`, which Contributor at subscription scope includes | Subscription |
| Fleet hub Kubernetes API (`kubectl` to `fleet-hub-demo`) | **Azure Kubernetes Fleet Manager RBAC Cluster Admin**. `scripts/07` assigns it. Subscription Owner alone is **not** enough (lesson from the July 2026 runs). | Fleet resource |
| Arc onboarding | **Kubernetes Cluster - Azure Arc Onboarding** (or Contributor) | Resource group |
| Arc gateway | `Microsoft.HybridCompute/gateways/read+write`, `Microsoft.Kubernetes/connectedClusters/settings/default/write` | Resource group |
| Join Arc members to Fleet | `Microsoft.Kubernetes/connectedClusters/read`, `Microsoft.KubernetesConfiguration/extensions/read+write+delete` | Arc resources |
| ExpressRoute, VNet, gateway, proxy VM | Contributor, or Network Contributor plus Virtual Machine Contributor | Resource group |

**Resource providers:** Microsoft.ContainerService, Microsoft.Kubernetes, Microsoft.KubernetesConfiguration,
Microsoft.ExtendedLocation, Microsoft.Network, Microsoft.Compute, and Microsoft.HybridCompute (Arc gateway).
Add Microsoft.ContainerRegistry if you use the private ACR.

**Tooling:** the Fleet hub uses Entra ID, so `kubectl` needs **kubelogin**. `scripts/07` converts the hub
context to use your `az login` token (`kubelogin convert-kubeconfig -l azurecli`).

## AWS

```powershell
aws configure sso --profile equinix-arc-demo   # once
aws sso login --profile equinix-arc-demo        # each session; set AWS_PROFILE=equinix-arc-demo in .env
```

The profile needs permissions for VPC/EC2 networking, IAM (cluster role, node role, OIDC provider, and LBC IRSA
role and policy, plus `iam:PassRole`), EKS cluster and node group management, and `sts:GetCallerIdentity`.
`AdministratorAccess` covers this in a demo account. If your account has SCPs, translate the list
into a scoped policy. If `aws login` with IAM console credentials returns HTTP 400, the user is missing
the `SignInLocalDevelopmentAccess` managed policy (a July 2026 lesson). Use SSO instead.

**Cross-account role (`AWS_ASSUME_ROLE_ARN`, optional):** Terraform then creates EKS *as that role*, and the
cluster creator is the only principal with an EKS access entry. So the generated kubeconfig assumes the same
role (`aws eks update-kubeconfig --role-arn ...`), and `scripts/01` checks that your profile can assume it
(`sts:AssumeRole`) and that its account matches `AWS_EXPECTED_ACCOUNT_ID`.

## Equinix

1. In the **Equinix Developer Portal**, open **My Apps** and create an app. Copy the **Client ID** and **Client Secret**.
2. In Equinix IAM, give the app's user a role that can **create and delete Fabric connections** in the target project.
   If you use `cloud_router` origin, the role must also cover **Fabric Cloud Routers** and **routing protocols**.
   Your Equinix administrator assigns the Fabric role. Use a scoped role, not an org-wide admin.
3. In the shell that runs the scripts (the values aren't echoed or stored):

   ```powershell
   $env:EQUINIX_API_CLIENTID = Read-Host "Equinix client ID"
   $env:EQUINIX_API_CLIENTSECRET = (New-Object PSCredential "x", (Read-Host "Equinix client secret" -AsSecureString)).GetNetworkCredential().Password
   make bootstrap-auth    # validates them with an OAuth token request; prints nothing sensitive
   ```

   Optional: keep them in a SecretManagement vault and load them per session, for example with
   `$env:EQUINIX_API_CLIENTSECRET = Get-Secret equinix-api-secret -AsPlainText`.

4. Make sure you also have the **project ID**, **port UUIDs** (port origin), **account number** (to create an FCR),
   and the **notification emails** that Equinix requires on every order.

## Kubernetes

| Cluster | Requirement |
|---|---|
| Equinix (onboarding) | **cluster-admin** through the `equinix-demo` context. `az connectedk8s connect` installs the agents with Helm. `scripts/01` checks `kubectl auth can-i '*' '*'`. |
| Equinix (day 2) | **Arc Cluster Connect** with a `ClusterRoleBinding` to your Entra object ID (`kubernetes/equinix/arc-cluster-connect-rbac.yaml`, which `scripts/06` applies). It uses cluster-admin for demo simplicity. Use `view` or `edit` for least privilege. |
| EKS | The cluster creator's admin access (EKS access entries, `bootstrap_cluster_creator_admin_permissions`). |
| AKS | Local admin kubeconfig (`az aks get-credentials`). |

## After the event

- Run `make destroy`. Then remove the Fleet hub role assignment if you created it outside the Fleet scope.
- In the Equinix Developer Portal, delete or rotate the API app. Close the shell so the credential environment variables disappear.
- Run `kubectl config delete-context aks-demo eks-demo equinix-demo fleet-hub-demo`.

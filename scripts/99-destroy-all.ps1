#Requires -Version 5.1
<#
.SYNOPSIS
    Tears down everything this demo created, in dependency order:
      1. Fleet placement, overrides and workload on the hub; then waits for the
         EKS storefront load balancer to be released (an orphaned NLB would
         block the VPC deletion in step 6)
      2. Arc-backed Fleet members (eks-demo, equinix-demo). The AKS member is
         Terraform-managed and goes with terraform/azure.
      3. Arc connections (EKS, Equinix) and the Arc gateway
      4. Equinix Fabric connection(s) / FCR (terraform/equinix) - the provider
         waits until Equinix reports DEPROVISIONED
      5. Wait until the ExpressRoute circuit is NotProvisioned
         (Azure refuses to delete a circuit the provider still provisions)
      6. terraform destroy aws, then azure (circuit, gateway, proxy, AKS, Fleet)

.PARAMETER AutoApprove
    Skip the typed confirmation.

.PARAMETER KeepArcGateway
    Keep the Arc gateway (it takes ~30 minutes to recreate). Only possible when
    the gateway is in its own resource group (ARC_RESOURCE_GROUP in .env, set
    before deploying): the Terraform-managed group is deleted in step 6.

.DESCRIPTION
    Teardown is driven by what EXISTS (Terraform state, Azure resources, kube
    contexts), not by the ENABLE_* flags, so changing .env after a deployment
    never leaves billable resources behind. Every delete is checked: only a
    confirmed "not found" counts as already gone. The script is safe to re-run
    after an interrupted teardown. The Equinix cluster's hardware and K3s
    install are NOT touched (Arc agents are removed by `az connectedk8s delete`).
#>
[CmdletBinding()]
param(
    [switch]$AutoApprove,
    [switch]$KeepArcGateway,
    [int]$DeprovisionTimeoutMinutes = 45
)

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
$naming = Get-Naming -DotEnv $dotEnv
$k8sDir = Get-KubernetesDir

$azureRoot = Get-TfRootDir "azure"
$azureOutputs = Get-TfOutputs -RootDir $azureRoot
$rg = Get-TfOutputValue -Outputs $azureOutputs -Name "resource_group_name"
$fleetName = Get-TfOutputValue -Outputs $azureOutputs -Name "fleet_name"
$arcRg = Get-ArcResourceGroup -DotEnv $dotEnv -AzureOutputs $azureOutputs

if ($KeepArcGateway -and $arcRg -and $arcRg -eq $rg) {
    Write-ErrMsg "-KeepArcGateway can't work here: the Arc gateway is in '$arcRg', the resource group terraform/azure deletes."
    Write-Info "Run without -KeepArcGateway. To keep the gateway across future teardowns, set ARC_RESOURCE_GROUP in .env to a separate group before deploying (scripts/06 creates it)."
    exit 1
}

# Every az call below must target the subscription Terraform deployed to;
# otherwise a "not found" would wrongly read as "already deleted".
$expectedSub = Get-EnvValue -DotEnv $dotEnv -Key "AZURE_EXPECTED_SUBSCRIPTION_ID"
if (-not $expectedSub) { $expectedSub = [string](Get-TfOutputValue -Outputs $azureOutputs -Name "subscription_id") }
if ($expectedSub) {
    $currentSub = az account show --query id -o tsv 2>$null
    if (-not $currentSub) {
        Write-ErrMsg "The Azure CLI isn't logged in - run scripts/00-bootstrap-auth.ps1 (or az login), then re-run."
        exit 1
    }
    if ($currentSub -ne $expectedSub) {
        Write-ErrMsg "The Azure CLI is on subscription '$currentSub', but the demo was deployed to '$expectedSub'. Run: az account set --subscription $expectedSub"
        exit 1
    }
}

Write-Step "Destroy notice"
Write-Host "PERMANENTLY deletes everything this repo created: Fleet, AKS, EKS, Arc resources," -ForegroundColor Yellow
Write-Host "the ExpressRoute circuit and gateway, the egress proxy, and the Equinix Fabric connections." -ForegroundColor Yellow
if (-not (Confirm-BillableAction -ActionDescription "About to destroy ALL demo infrastructure." -AutoApprove:$AutoApprove.IsPresent -ConfirmationWord "destroy")) {
    Write-WarnMsg "Aborted - nothing changed."
    exit 1
}

# --- 1. Hub workload -------------------------------------------------------------
Write-Step "1. Removing placement, overrides and workload from the Fleet hub"
if (Test-KubeContext -Name $naming.HubContext) {
    kubectl delete -f (Join-Path (Join-Path $k8sDir "fleet") "cluster-resource-placement.yaml") --context $naming.HubContext --ignore-not-found=true 2>&1 | Out-Null
    kubectl delete -f (Join-Path $k8sDir "overrides") --context $naming.HubContext --ignore-not-found=true 2>&1 | Out-Null
    kubectl delete -k (Join-Path $k8sDir "base") --context $naming.HubContext --ignore-not-found=true 2>&1 | Out-Null
    Write-Ok "Hub workload removed (or already absent)"
} else { Write-WarnMsg "No '$($naming.HubContext)' context - skipping" }

# The AWS Load Balancer Controller deletes the storefront NLB when the
# frontend-external Service goes away. terraform/aws removes the controller, so
# the Service must be gone BEFORE step 6 - an orphaned NLB blocks VPC deletion.
if (Test-KubeContext -Name $naming.EksContext) {
    Write-Step "1b. Waiting for the EKS storefront load balancer to be released"
    $svcArgs = @("get", "svc", "frontend-external", "-n", "online-boutique", "--context", $naming.EksContext, "--ignore-not-found", "-o", "name", "--request-timeout=20s")
    $deadline = (Get-Date).AddMinutes(5)
    $svc = $null
    $reachable = $true
    do {
        $svc = kubectl @svcArgs 2>$null
        if ($LASTEXITCODE -ne 0) { $reachable = $false; break }
        if (-not $svc) { break }
        Write-Info "frontend-external still present on EKS (Fleet is removing it)..."
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    if (-not $reachable) {
        Write-WarnMsg "EKS isn't reachable through '$($naming.EksContext)'. If the cluster still exists, delete its 'k8s-*' load balancers in the EC2 console if terraform/aws destroy fails."
    } elseif ($svc) {
        Write-Info "Still present - deleting it directly (the controller then removes the NLB)"
        Invoke-Checked -Command "kubectl" -Arguments @("delete", "svc", "frontend-external", "-n", "online-boutique", "--context", $naming.EksContext, "--wait=true", "--timeout=5m") -ErrorContext "delete EKS frontend-external" | Out-Null
        Write-Ok "EKS storefront Service and its load balancer removed"
    } else { Write-Ok "No storefront load balancer left on EKS" }
}

# --- 2. Arc-backed Fleet members ----------------------------------------------------
if ($rg -and $fleetName) {
    Write-Step "2. Removing the Arc-backed Fleet members"
    $fleet = Get-AzResourceOrNull -Arguments @("resource", "show", "--resource-group", $rg, "--resource-type", "Microsoft.ContainerService/fleets", "--name", $fleetName)
    if (-not $fleet) { Write-Info "Fleet '$fleetName' not found - nothing to remove" }
    else {
        foreach ($member in @($naming.EquinixMember, $naming.EksMember)) {
            $found = Get-AzResourceOrNull -Arguments @("fleet", "member", "show", "--resource-group", $rg, "--fleet-name", $fleetName, "--name", $member)
            if (-not $found) { Write-Info "Fleet member '$member': not found"; continue }
            Invoke-Checked -Command "az" -Arguments @("fleet", "member", "delete", "--resource-group", $rg, "--fleet-name", $fleetName, "--name", $member, "--yes", "--output", "none") -ErrorContext "fleet member delete $member"
            Write-Ok "Fleet member '$member' removed"
        }
    }
}

# --- 3. Arc ------------------------------------------------------------------------
if ($arcRg) {
    Write-Step "3. Disconnecting Arc clusters (resource group $arcRg)"
    foreach ($pair in @(@($naming.EksMember, $naming.EksContext), @($naming.EquinixMember, $naming.EquinixContext))) {
        $name = $pair[0]; $context = $pair[1]
        $cc = Get-AzResourceOrNull -Arguments @("resource", "show", "--resource-group", $arcRg, "--resource-type", "Microsoft.Kubernetes/connectedClusters", "--name", $name)
        if (-not $cc) { Write-Info "Arc cluster '$name': not found"; continue }
        $reachable = $false
        if (Test-KubeContext -Name $context) {
            kubectl get namespace azure-arc --context $context --request-timeout=15s 2>$null | Out-Null
            $reachable = ($LASTEXITCODE -eq 0)
        }
        if ($reachable) {
            # Deletes the Azure resource AND removes the agents from the cluster.
            Invoke-Checked -Command "az" -Arguments @("connectedk8s", "delete", "--name", $name, "--resource-group", $arcRg, "--kube-context", $context, "--yes", "--output", "none") -ErrorContext "connectedk8s delete $name"
        } else {
            # Never fall back to the CURRENT kube context; delete only the Azure resource.
            Write-WarnMsg "'$context' isn't reachable - deleting only the Azure resource (any agents stay in that cluster)."
            Invoke-Checked -Command "az" -Arguments @("resource", "delete", "--ids", $cc.id) -ErrorContext "delete Arc resource $name"
        }
        Write-Ok "Arc cluster '$name' removed"
    }
    if (-not $KeepArcGateway) {
        $gw = Get-AzResourceOrNull -Arguments @("resource", "show", "--resource-group", $arcRg, "--resource-type", "Microsoft.HybridCompute/gateways", "--name", $naming.ArcGateway)
        if ($gw) {
            Invoke-Checked -Command "az" -Arguments @("resource", "delete", "--ids", $gw.id) -ErrorContext "delete Arc gateway"
            Write-Ok "Arc gateway '$($naming.ArcGateway)' deleted"
        } else { Write-Info "Arc gateway '$($naming.ArcGateway)': not found" }
    } else { Write-Info "Keeping Arc gateway '$($naming.ArcGateway)' in '$arcRg' (-KeepArcGateway)" }
}

# --- 4. Equinix Fabric -------------------------------------------------------------
$equinixRoot = Get-TfRootDir "equinix"
if (Test-TfStateExists -RootDir $equinixRoot) {
    Write-Step "4. Destroying Equinix Fabric connection(s)"
    if (-not (Test-EquinixCredentialsPresent)) {
        Write-ErrMsg "Equinix API credentials are not set - cannot delete the Fabric connections. Set them and re-run."
        exit 1
    }
    try {
        # The service key variable is only needed for planning; supply it if the circuit still exists.
        $key = $null
        Push-Location $azureRoot; try { $key = terraform output -raw expressroute_service_key 2>$null } finally { Pop-Location }
        if ($key) { $env:TF_VAR_expressroute_service_key = $key }
        Invoke-TerraformCommand -RootDir $equinixRoot -Arguments @("destroy", "-input=false", "-auto-approve") -ErrorContext "equinix destroy"
        Write-Ok "Equinix Fabric connection(s) deprovisioned"
    } finally {
        Remove-Item Env:TF_VAR_expressroute_service_key -ErrorAction SilentlyContinue
        $key = $null
    }
}

# --- 5. Wait for the circuit to be released by the provider --------------------------
# Get-ExpressRouteCircuitState returns $null only for a confirmed-absent circuit
# and throws when Azure can't be queried - so the wait can't end on a CLI hiccup.
$state = Get-ExpressRouteCircuitState -DotEnv $dotEnv
if ($state) {
    Write-Step "5. Waiting for the ExpressRoute circuit to be NotProvisioned (up to $DeprovisionTimeoutMinutes min)"
    $deadline = (Get-Date).AddMinutes($DeprovisionTimeoutMinutes)
    while ($state -and $state.ServiceProviderProvisioningState -ne "NotProvisioned") {
        if ((Get-Date) -ge $deadline) {
            Write-ErrMsg "The circuit is still '$($state.ServiceProviderProvisioningState)' at the provider, so Azure can't delete it yet (and it keeps billing). Check the Equinix portal, then re-run this script."
            exit 1
        }
        Write-Info "provider state: $($state.ServiceProviderProvisioningState)"
        Start-Sleep -Seconds 30
        try { $state = Get-ExpressRouteCircuitState -DotEnv $dotEnv } catch { Write-WarnMsg "Could not read the circuit (will retry): $($_.Exception.Message)" }
    }
    Write-Ok "Circuit released by the provider"
}

# --- 6. Terraform destroy: aws, then azure --------------------------------------------
function Invoke-DestroyRoot {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$RootDir)
    if (-not (Test-TfStateExists -RootDir $RootDir)) { Write-Info "$Label : nothing in state - skipping"; return }
    Write-Step "terraform destroy: $Label"
    Invoke-TerraformCommand -RootDir $RootDir -Arguments @("destroy", "-input=false", "-auto-approve") -ErrorContext "$Label destroy"
    Remove-Item (Join-Path $RootDir "tfplan") -Force -ErrorAction SilentlyContinue
    Write-Ok "$Label destroyed"
}

Write-Step "6. Terraform destroy"
Invoke-DestroyRoot -Label "aws" -RootDir (Get-TfRootDir "aws")
Invoke-DestroyRoot -Label "azure" -RootDir $azureRoot

$demoRoot = Get-TfRootDir "environments/demo"
if (Test-Path (Join-Path $demoRoot "terraform.tfstate")) {
    Push-Location $demoRoot
    try { terraform apply -input=false -auto-approve 2>&1 | Out-Null } finally { Pop-Location }
}

Write-Step "Summary"
Write-Ok "Teardown complete - every Terraform root and Arc/Fleet resource this repo manages is gone."
if ($KeepArcGateway) { Write-Info "Kept on purpose: Arc gateway '$($naming.ArcGateway)' in '$arcRg'." }
Write-Info "Left in place on purpose: the Equinix servers + K3s, your kubeconfig contexts (kubectl config delete-context <name>), and resource-provider registrations."
Write-Info "Check the Equinix portal for any port/FCR charges you ordered outside this repo."
exit 0

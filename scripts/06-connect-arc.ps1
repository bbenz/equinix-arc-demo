#Requires -Version 5.1
<#
.SYNOPSIS
    Arc-enables EKS and the Equinix-hosted cluster. AKS never goes through Arc
    (it joins Fleet natively in scripts/07-join-fleet.ps1).

.DESCRIPTION
    EKS: classic Arc onboarding over the public internet.

    Equinix (ExpressRoute path): the cage has no internet egress, so the Arc
    agents are onboarded with
      --gateway-resource-id  Azure Arc gateway (9 FQDNs instead of dozens)
      --proxy-https/-http    the Squid proxy in the Azure hub VNet, reached
                             over ExpressRoute private peering
      --proxy-skip-range     cluster/node CIDRs that must never use the proxy
    Fleet Manager REQUIRES Arc gateway for Arc members behind a passthrough
    proxy (and does not support TLS-terminating proxies).

    Equinix (rehearsal mode, ENABLE_EXPRESSROUTE=false): plain onboarding.

    Every step is idempotent. A cluster that is already Connected (through the
    Arc gateway, on the ExpressRoute path) is skipped. An existing connection
    that is missing the gateway, or is offline, is brought in line with
    `az connectedk8s update`, which applies the gateway AND the proxy settings
    together. That covers a cluster first onboarded in rehearsal mode over the
    internet that now sits behind the ExpressRoute proxy.

    The machine running this script must reach each cluster's API server
    (for Equinix: VPN/jump host into the cage, or run it from a cage host).
    After onboarding, day-2 access works through Arc Cluster Connect.
#>
[CmdletBinding()]
param(
    [int]$TimeoutMinutes = 15
)

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
$targets = Get-EnabledTargets -DotEnv $dotEnv
$naming = Get-Naming -DotEnv $dotEnv
$er = Test-ExpressRouteEnabled -DotEnv $dotEnv

$azureOutputs = Get-TfOutputs -RootDir (Get-TfRootDir "azure")
if (-not $azureOutputs) { Write-ErrMsg "terraform/azure is not applied - run scripts/04-apply.ps1 first."; exit 1 }
$rg = Get-ArcResourceGroup -DotEnv $dotEnv -AzureOutputs $azureOutputs
$location = Get-EnvValue -DotEnv $dotEnv -Key "ARC_REGION_OVERRIDE" -Default (Get-TfOutputValue -Outputs $azureOutputs -Name "location")
Write-Info "Arc resource group: $rg   region: $location"

# A separate ARC_RESOURCE_GROUP (needed to keep the Arc gateway across
# teardowns, see 99-destroy-all.ps1 -KeepArcGateway) is created here, not by Terraform.
if ($rg -ne (Get-TfOutputValue -Outputs $azureOutputs -Name "resource_group_name")) {
    $exists = az group exists --name $rg 2>$null
    if ($exists -ne "true") {
        Write-Info "Creating resource group $rg for the Arc resources"
        Invoke-Checked -Command "az" -Arguments @("group", "create", "--name", $rg, "--location", $location,
            "--tags", "demo=$($naming.DemoLabel)", "managed_by=scripts", "--output", "none") -ErrorContext "az group create"
    }
}

function Wait-ArcConnected {
    param([Parameter(Mandatory)][string]$Name)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $status = az connectedk8s show --name $Name --resource-group $rg --query "connectivityStatus" -o tsv 2>$null
        Write-Info "  $Name connectivityStatus: $status"
        if ($status -eq "Connected") { return $true }
        Start-Sleep -Seconds 20
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Connect-ArcCluster {
    # Returns ONLY $true/$false (CLI output goes to the host, never into the
    # return value). $AgentArgs = Arc gateway + proxy settings (ExpressRoute
    # path), used for both a new connection and an update of an existing one.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$KubeContext,
        [Parameter(Mandatory)][string]$Distribution,
        [Parameter(Mandatory)][string]$Infrastructure,
        [string[]]$AgentArgs = @(),
        [string]$GatewayId = ""
    )
    Write-Step "Arc-connecting $Name (context $KubeContext, distribution $Distribution)"
    $existing = Invoke-AzJson -Arguments @("connectedk8s", "show", "--name", $Name, "--resource-group", $rg)
    if ($existing) {
        $status = Get-Prop $existing "connectivityStatus"
        $gatewayOk = $true
        if ($GatewayId) {
            $gwId = "$(Get-Prop $existing 'gateway.resourceId')"
            $gatewayOk = ("$(Get-Prop $existing 'gateway.enabled')" -eq "True") -and (-not $gwId -or $gwId -ieq $GatewayId)
        }
        if ($status -eq "Connected" -and $gatewayOk) {
            $suffix = ""; if ($GatewayId) { $suffix = " through the Arc gateway" }
            Write-Ok "$Name already Connected$suffix - skipping onboarding"
            return $true
        }
        if ($GatewayId) {
            if (-not (Test-KubeContext -Name $KubeContext)) {
                Write-ErrMsg "kube context '$KubeContext' not found - it's needed to reconfigure the Arc agents on $Name."
                return $false
            }
            Write-Info "$Name exists (status '$status', gateway in place: $gatewayOk) - applying the Arc gateway + proxy settings..."
            & az connectedk8s update --name $Name --resource-group $rg --kube-context $KubeContext @AgentArgs --output none | Out-Host
            if ($LASTEXITCODE -ne 0) { Write-ErrMsg "az connectedk8s update failed for $Name."; return $false }
        } else {
            Write-WarnMsg "$Name exists but is '$status' - waiting for its agents to reconnect."
        }
    } else {
        if (-not (Test-KubeContext -Name $KubeContext)) {
            Write-ErrMsg "kube context '$KubeContext' not found."
            return $false
        }
        $azArgs = @(
            "connectedk8s", "connect",
            "--name", $Name,
            "--resource-group", $rg,
            "--location", $location,
            "--kube-context", $KubeContext,
            "--distribution", $Distribution,
            "--infrastructure", $Infrastructure,
            "--yes", "--output", "none"
        ) + $AgentArgs
        & az @azArgs | Out-Host
        if ($LASTEXITCODE -ne 0) {
            # Lesson from fleet-manager-arc-demo: the CLI can time out on Helm after
            # the agents were actually installed - check the resource before failing.
            Write-WarnMsg "az connectedk8s connect exited $LASTEXITCODE - checking whether onboarding actually succeeded..."
        }
    }
    if (Wait-ArcConnected -Name $Name) { Write-Ok "$Name : Connected"; return $true }
    Write-ErrMsg "$Name did not reach Connected within $TimeoutMinutes minutes. Diagnose: az connectedk8s troubleshoot -n $Name -g $rg"
    return $false
}

$results = @()

# --- EKS (public internet) ----------------------------------------------------------
if ($targets -contains "aws") {
    $results += Connect-ArcCluster -Name $naming.EksMember -KubeContext $naming.EksContext -Distribution "eks" -Infrastructure "aws"
}

# --- Equinix ---------------------------------------------------------------------
if ($targets -contains "equinix") {
    $distribution = Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_DISTRIBUTION" -Default "k3s"
    $extra = @()
    $gatewayId = $null

    if ($er) {
        # 1. Arc gateway (creation takes ~30 minutes the first time).
        Write-Step "Azure Arc gateway '$($naming.ArcGateway)'"
        $gateway = Invoke-AzJson -Arguments @("arcgateway", "show", "--name", $naming.ArcGateway, "--resource-group", $rg)
        if (-not $gateway) {
            Write-Info "Creating Arc gateway (typically ~30 minutes)..."
            Invoke-Checked -Command "az" -Arguments @("arcgateway", "create", "--name", $naming.ArcGateway, "--resource-group", $rg,
                "--location", $location, "--gateway-type", "public", "--allowed-features", "*") -ErrorContext "az arcgateway create" | Out-Null
            $gateway = Invoke-AzJson -Arguments @("arcgateway", "show", "--name", $naming.ArcGateway, "--resource-group", $rg)
        }
        $gatewayId = Get-Prop $gateway "id"
        $endpoint = Get-Prop $gateway "gatewayEndpoint"
        if (-not $endpoint) { $endpoint = Get-Prop $gateway "properties.gatewayEndpoint" }
        if (-not $gatewayId) { Write-ErrMsg "Arc gateway '$($naming.ArcGateway)' not found after create."; exit 1 }
        Write-Ok "Arc gateway ready: $endpoint"

        # 2. Proxy + skip range (never proxy in-cluster or cage-local traffic).
        $proxy = Get-TfOutputValue -Outputs $azureOutputs -Name "egress_proxy_url"
        $skip = @(Split-List (Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_CLUSTER_SKIP_RANGES" -Default "10.42.0.0/16,10.43.0.0/16")) +
        @(Split-List (Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_ONPREM_PREFIXES" -Default "10.80.0.0/24")) +
        @("kubernetes.default.svc", ".svc.cluster.local", ".svc", "localhost", "127.0.0.1")
        Write-Info "Proxy: $proxy   skip-range: $($skip -join ',')"
        $extra = @("--gateway-resource-id", $gatewayId, "--proxy-https", $proxy, "--proxy-http", $proxy, "--proxy-skip-range", ($skip -join ","))
    } else {
        Write-Info "Rehearsal mode (ENABLE_EXPRESSROUTE=false): onboarding the Equinix-labeled cluster over its own internet path."
    }

    $ok = Connect-ArcCluster -Name $naming.EquinixMember -KubeContext $naming.EquinixContext -Distribution $distribution -Infrastructure "generic" -AgentArgs $extra -GatewayId ([string]$gatewayId)
    $results += $ok

    if ($ok -and $er) {
        $enabled = az connectedk8s show --name $naming.EquinixMember --resource-group $rg --query "gateway.enabled" -o tsv 2>$null
        if ($enabled -eq "true") { Write-Ok "Arc gateway enabled on $($naming.EquinixMember)" }
        else { Write-ErrMsg "Arc gateway not enabled on $($naming.EquinixMember) - re-run this script (it re-applies the gateway + proxy settings)."; $results += $false }
    }

    # 3. Cluster Connect RBAC for the presenter (kubectl via Azure Arc, no VPN).
    if ($ok) {
        Write-Step "Cluster Connect RBAC for the signed-in user"
        $oid = az ad signed-in-user show --query id -o tsv 2>$null
        if ($oid) {
            $rbac = (Get-Content -Raw (Join-RepoPath "kubernetes" "equinix" "arc-cluster-connect-rbac.yaml")).Replace("__PRESENTER_OBJECT_ID__", $oid)
            $rbac | kubectl apply --context $naming.EquinixContext -f - | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok "ClusterRoleBinding equinix-arc-demo-presenter -> your Entra object ID" } else { Write-WarnMsg "Could not apply the Cluster Connect RBAC binding." }
        } else {
            Write-WarnMsg "Signed-in principal is not a user (or Graph is blocked) - skipping Cluster Connect RBAC."
        }
        $pods = kubectl get pods -n azure-arc --context $naming.EquinixContext --no-headers 2>$null
        $notRunning = @($pods | Where-Object { $_ -and $_ -notmatch "\s(Running|Completed)\s" })
        Write-Info "azure-arc pods: $(@($pods).Count) total, $($notRunning.Count) not Running"
    }
}

Write-Step "Summary"
if ($results.Count -eq 0) { Write-WarnMsg "Neither AWS nor Equinix is enabled - nothing to Arc-connect."; exit 0 }
if ($results -contains $false) { Write-ErrMsg "One or more clusters failed onboarding - fix and re-run (idempotent)."; exit 1 }
Write-Ok "Arc onboarding complete."
Write-Info "Next: scripts/07-join-fleet.ps1"
exit 0

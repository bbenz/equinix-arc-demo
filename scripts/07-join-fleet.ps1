#Requires -Version 5.1
<#
.SYNOPSIS
    Joins AKS (native), Arc-enabled EKS and the Arc-enabled Equinix cluster to
    Fleet Manager with one consistent label schema, grants you Fleet hub
    Kubernetes RBAC if missing, and fetches the hub kubeconfig
    (context fleet-hub-demo).

.DESCRIPTION
    Labels (kubernetes/fleet/member-labels-reference.yaml):
      cloud, provider, connectivity, site, location, demo, environment
    `--member-labels` is passed as ONE space-separated argument (passing pairs
    separately breaks the fleet extension - fleet-manager-arc-demo lesson).
    Only AKS gets an update group: Fleet update runs are AKS-only, and
    omitting it would clear the Terraform-managed group (another lesson).
#>
[CmdletBinding()]
param(
    [int]$TimeoutMinutes = 10
)

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
$targets = Get-EnabledTargets -DotEnv $dotEnv
$naming = Get-Naming -DotEnv $dotEnv
$er = Test-ExpressRouteEnabled -DotEnv $dotEnv
$selection = Read-RegionSelection

$azureOutputs = Get-TfOutputs -RootDir (Get-TfRootDir "azure")
if (-not $azureOutputs) { Write-ErrMsg "terraform/azure is not applied."; exit 1 }
$rg = Get-TfOutputValue -Outputs $azureOutputs -Name "resource_group_name"
$arcRg = Get-ArcResourceGroup -DotEnv $dotEnv -AzureOutputs $azureOutputs
$fleetName = Get-TfOutputValue -Outputs $azureOutputs -Name "fleet_name"
$fleetId = Get-TfOutputValue -Outputs $azureOutputs -Name "fleet_id"
$azureLocation = Get-TfOutputValue -Outputs $azureOutputs -Name "location"
Write-Info "Fleet: $fleetName (resource group $rg)"

function Add-FleetMember {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ClusterId,
        [Parameter(Mandatory)][hashtable]$Labels,
        [string]$UpdateGroup = ""
    )
    Write-Step "Joining $Name"
    $labelString = (($Labels.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join " ")
    Write-Info "labels: $labelString"
    $azArgs = @("fleet", "member", "create", "--resource-group", $rg, "--fleet-name", $fleetName,
        "--name", $Name, "--member-cluster-id", $ClusterId, "--member-labels", $labelString)
    if ($UpdateGroup) { $azArgs += @("--update-group", $UpdateGroup) }
    Invoke-Checked -Command "az" -Arguments $azArgs -ErrorContext "az fleet member create ($Name)" | Out-Null

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 10
        $state = az fleet member show --resource-group $rg --fleet-name $fleetName --name $Name --query "provisioningState" -o tsv 2>$null
        Write-Info "  provisioningState: $state"
    } while ($state -ne "Succeeded" -and $state -ne "Failed" -and (Get-Date) -lt $deadline)
    if ($state -eq "Succeeded") { Write-Ok "$Name joined"; return $true }
    Write-ErrMsg "$Name : $state - check: az fleet member show -g $rg -f $fleetName -n $Name"
    return $false
}

$common = @{ demo = $naming.DemoLabel; environment = $naming.Environment }
$results = @()

# --- AKS (native member; also created by Terraform - this (re)applies labels) ----
$aksLabels = $common.Clone()
$aksLabels.cloud = "azure"; $aksLabels.provider = "aks"; $aksLabels.connectivity = "azure-native"
$aksLabels.location = $azureLocation; $aksLabels.site = "azure-$azureLocation"
$results += Add-FleetMember -Name $naming.AksMember -ClusterId (Get-TfOutputValue -Outputs $azureOutputs -Name "aks_cluster_id") -Labels $aksLabels -UpdateGroup "azure"

# --- EKS (Arc) ---------------------------------------------------------------------
if ($targets -contains "aws") {
    $awsRegion = "us-west-2"
    if ($selection -and (Get-Prop $selection "aws.selected")) { $awsRegion = $selection.aws.selected }
    $eksId = az connectedk8s show --name $naming.EksMember --resource-group $arcRg --query "id" -o tsv 2>$null
    if (-not $eksId) { Write-ErrMsg "Arc cluster $($naming.EksMember) not found - run scripts/06-connect-arc.ps1"; $results += $false }
    else {
        $eksLabels = $common.Clone()
        $eksLabels.cloud = "aws"; $eksLabels.provider = "eks"; $eksLabels.connectivity = "public-internet"
        $eksLabels.location = $awsRegion; $eksLabels.site = "aws-$awsRegion"
        $results += Add-FleetMember -Name $naming.EksMember -ClusterId $eksId -Labels $eksLabels
    }
}

# --- Equinix (Arc over ExpressRoute) ------------------------------------------------
if ($targets -contains "equinix") {
    $metro = (Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_METRO_CODE" -Default "SV").ToLowerInvariant()
    $eqId = az connectedk8s show --name $naming.EquinixMember --resource-group $arcRg --query "id" -o tsv 2>$null
    if (-not $eqId) { Write-ErrMsg "Arc cluster $($naming.EquinixMember) not found - run scripts/06-connect-arc.ps1"; $results += $false }
    else {
        $connectivity = "expressroute"
        if (-not $er) { $connectivity = "public-internet-rehearsal" }
        $eqLabels = $common.Clone()
        $eqLabels.cloud = "equinix"
        $eqLabels.provider = (Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_DISTRIBUTION" -Default "k3s").Replace("_", "-")
        $eqLabels.connectivity = $connectivity
        $eqLabels.location = $metro
        $eqLabels.site = "equinix-$metro"
        $results += Add-FleetMember -Name $naming.EquinixMember -ClusterId $eqId -Labels $eqLabels
    }
}

# --- Fleet hub data-plane access -------------------------------------------------------
# Subscription Owner does NOT grant Kubernetes access to the hub (lesson learned).
Write-Step "Fleet hub Kubernetes RBAC"
$role = "Azure Kubernetes Fleet Manager RBAC Cluster Admin"
$oid = az ad signed-in-user show --query id -o tsv 2>$null
if ($oid) {
    $existing = Invoke-AzJson -Arguments @("role", "assignment", "list", "--assignee", $oid, "--scope", $fleetId, "--role", $role)
    if ($existing -and @($existing).Count -gt 0) {
        Write-Ok "'$role' already assigned on the fleet"
    } else {
        az role assignment create --assignee-object-id $oid --assignee-principal-type User --role $role --scope $fleetId -o none 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Ok "Assigned '$role' - waiting 60s for RBAC propagation"; Start-Sleep -Seconds 60 }
        else { Write-WarnMsg "Could not assign '$role' (needs Owner/User Access Administrator). Ask an admin to assign it on $fleetId." }
    }
} else {
    Write-WarnMsg "Signed-in principal is not a user - ensure it has '$role' on the fleet."
}

Write-Step "Fetching Fleet hub kubeconfig"
Invoke-Checked -Command "az" -Arguments @("fleet", "get-credentials", "--resource-group", $rg, "--name", $fleetName,
    "--context", $naming.HubContext, "--overwrite-existing") -ErrorContext "az fleet get-credentials"
if (Test-CommandExists "kubelogin") {
    # Reuse the az CLI login for the Entra ID-protected hub (no device-code prompt mid-demo).
    kubelogin convert-kubeconfig -l azurecli --context $naming.HubContext 2>$null | Out-Null
}
$members = kubectl get memberclusters --context $naming.HubContext -o custom-columns="NAME:.metadata.name,JOINED:.status.conditions[?(@.type=='Joined')].status,CLOUD:.metadata.labels.cloud,CONNECTIVITY:.metadata.labels.connectivity" 2>&1
if ($LASTEXITCODE -eq 0) { $members | ForEach-Object { Write-Info $_ } } else { Write-WarnMsg "Hub not readable yet (RBAC propagation can take a few minutes): $($members | Select-Object -First 1)" }

Write-Step "Summary"
if ($results -contains $false) { Write-ErrMsg "One or more members failed to join - fix and re-run (idempotent)."; exit 1 }
Write-Ok "Joined $($results.Count) member(s) to $fleetName"
Write-Info "Next: scripts/08-deploy-workload.ps1"
exit 0

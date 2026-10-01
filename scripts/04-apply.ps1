#Requires -Version 5.1
<#
.SYNOPSIS
    Applies the saved plans from scripts/03-init-plan.ps1. CREATES REAL,
    BILLABLE INFRASTRUCTURE: AKS + Fleet hub, EKS, and (ExpressRoute path)
    an ExpressRoute circuit + gateway + egress proxy VM.

.PARAMETER AutoApprove
    Skip the typed confirmation (CI / unattended runs only).

.DESCRIPTION
    ExpressRoute circuits bill from the moment the service key is issued -
    i.e. as soon as this script creates the circuit - not when Equinix
    provisions it. The ExpressRoute gateway typically takes 30-45 minutes.
#>
[CmdletBinding()]
param(
    [switch]$AutoApprove
)

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
$targets = Get-EnabledTargets -DotEnv $dotEnv
$er = Test-ExpressRouteEnabled -DotEnv $dotEnv

Write-Step "Cost notice"
Write-Host "Creates billable infrastructure (list prices, US West, 2026-09):" -ForegroundColor Yellow
Write-Host "  azure : AKS 2x D2s_v5 + Fleet hub 1x D2s_v5                     ~`$0.29/hr"
if ($er) {
    Write-Host "  azure : ExpressRoute 50 Mbps Standard Metered circuit          `$55/month (bills from creation!) + egress"
    Write-Host "  azure : ExpressRoute gateway ErGwScale (1 unit)                 ~`$0.21/hr  (30-45 min to create)"
    Write-Host "  azure : egress proxy VM B2s + public IP                         ~`$0.05/hr"
    Write-Host "  equinix: Fabric connections / ports / FCR - quoted by Equinix (created in step 05)"
}
if ($targets -contains "aws") { Write-Host "  aws   : EKS control plane + 2x t3.large                          ~`$0.27/hr" }
Write-Host "See README.md#cost. Tear down with scripts/99-destroy-all.ps1." -ForegroundColor Yellow

$scope = @("azure") + @($targets | Where-Object { $_ -eq "aws" })
if (-not (Confirm-BillableAction -ActionDescription "About to run 'terraform apply' for: $($scope -join ', ')." -AutoApprove:$AutoApprove.IsPresent)) {
    Write-WarnMsg "Aborted - no changes made."
    exit 1
}

# --- Azure (always) ----------------------------------------------------------------
$azureRoot = Get-TfRootDir "azure"
Invoke-TerraformApplyPlan -Label "azure" -RootDir $azureRoot
$azureOutputs = Get-TfOutputs -RootDir $azureRoot
$cmd = Get-TfOutputValue -Outputs $azureOutputs -Name "kubeconfig_command"
Write-Info "Fetching AKS kubeconfig (context aks-demo)"
Invoke-Expression $cmd
Write-Ok "kube context 'aks-demo' ready"

# --- AWS ---------------------------------------------------------------------------
if ($targets -contains "aws") {
    $awsRoot = Get-TfRootDir "aws"
    Invoke-TerraformApplyPlan -Label "aws" -RootDir $awsRoot
    $cmd = Get-TfOutputValue -Outputs (Get-TfOutputs -RootDir $awsRoot) -Name "kubeconfig_command"
    Write-Info "Fetching EKS kubeconfig (context eks-demo)"
    Invoke-Expression $cmd
    Write-Ok "kube context 'eks-demo' ready"
}

# --- Composition root: always re-plan (its earlier plan predates new state) --------
$demoRoot = Get-TfRootDir "environments/demo"
Remove-Item (Join-Path $demoRoot "tfplan") -Force -ErrorAction SilentlyContinue
Invoke-TerraformPlan -Label "environments/demo" -RootDir $demoRoot
Invoke-TerraformApplyPlan -Label "environments/demo" -RootDir $demoRoot

Write-Step "Summary"
Write-Ok "Applied: $($scope -join ', ')"
if ($er) {
    $circuit = Get-TfOutputValue -Outputs $azureOutputs -Name "expressroute_circuit_name"
    $proxy = Get-TfOutputValue -Outputs $azureOutputs -Name "egress_proxy_url"
    Write-Info "ExpressRoute circuit '$circuit' created (service key issued - billing has started)."
    Write-Info "Egress proxy for the Equinix nodes: $proxy (reachable once private peering is up)."
    Write-Info "Next: scripts/05-connect-expressroute.ps1 (orders the Equinix Fabric connection with the service key)."
} else {
    Write-Info "Next: scripts/06-connect-arc.ps1"
}
exit 0

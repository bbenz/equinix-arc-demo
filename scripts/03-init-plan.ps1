#Requires -Version 5.1
<#
.SYNOPSIS
    Generates terraform.tfvars for terraform/azure and terraform/aws from .env
    (+ region selection + live ExpressRoute state) and saves plans.

.DESCRIPTION
    Never applies anything. terraform/equinix is planned later by
    scripts/05-connect-expressroute.ps1 because it needs the service key of a
    circuit that only exists after terraform/azure is applied.
#>
[CmdletBinding()]
param()

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
$targets = Get-EnabledTargets -DotEnv $dotEnv
if (-not (Read-RegionSelection)) {
    Write-WarnMsg "artifacts/region-selection.json not found - run scripts/02-select-regions.ps1 first. Using variables.tf defaults."
}
if (-not (Get-EnvValue -DotEnv $dotEnv -Key "OWNER")) {
    Write-ErrMsg "OWNER is empty in .env - every resource is tagged with an owner."
    exit 1
}

# Azure is always planned: Fleet Manager, Arc resources and ExpressRoute live there.
$azureVars = Write-AzureTfVars -DotEnv $dotEnv
Invoke-TerraformPlan -Label "azure" -RootDir (Get-TfRootDir "azure")
if ($azureVars.enable_expressroute) {
    Write-Info "ExpressRoute path enabled: circuit '$($azureVars.expressroute_peering_location)' $($azureVars.expressroute_bandwidth_mbps) Mbps, private peering in this plan: $($azureVars.expressroute_private_peering_enabled)"
}

if ($targets -contains "aws") {
    [void](Write-AwsTfVars -DotEnv $dotEnv)
    Invoke-TerraformPlan -Label "aws" -RootDir (Get-TfRootDir "aws")
}

Invoke-TerraformPlan -Label "environments/demo" -RootDir (Get-TfRootDir "environments/demo")

Write-Step "Summary"
Write-Ok "Plans saved. Review with: terraform -chdir=terraform/azure show tfplan"
Write-Info "Next: scripts/04-apply.ps1 (BILLABLE)."
exit 0

#Requires -Version 5.1
<#
.SYNOPSIS
    Region discovery for Azure and AWS, plus a consistency check of the
    Equinix metro <-> ExpressRoute peering location. Writes
    artifacts/region-selection.json (selected + rejected candidates, reasons).

.DESCRIPTION
    Read-only. Overrides in .env (AZURE_REGION_OVERRIDE, AWS_REGION_OVERRIDE)
    win. Defaults favor the US West coast because the demo is presented at
    Microsoft Ignite 2026 in San Francisco (Equinix SV / "Silicon Valley").
#>
[CmdletBinding()]
param()

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
$targets = Get-EnabledTargets -DotEnv $dotEnv
$er = Test-ExpressRouteEnabled -DotEnv $dotEnv
$selection = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    azure        = $null
    aws          = $null
    equinix      = $null
}

# --- Azure -----------------------------------------------------------------------
Write-Step "Azure region discovery"
$override = Get-EnvValue -DotEnv $dotEnv -Key "AZURE_REGION_OVERRIDE"
$aksVmSize = Get-EnvValue -DotEnv $dotEnv -Key "AKS_NODE_VM_SIZE" -Default "Standard_D2s_v5"
if ($override) {
    Write-Ok "Using AZURE_REGION_OVERRIDE=$override"
    $selection.azure = [ordered]@{ selected = $override; reason = "user override (.env AZURE_REGION_OVERRIDE)"; considered = @() }
} else {
    # All candidates have availability zones (needed by zone-redundant ER gateways).
    $candidates = @("westus2", "westus3", "eastus2")
    $fleetLocations = @()
    $fleetDisplay = @(az provider show --namespace Microsoft.ContainerService --query "resourceTypes[?resourceType=='fleets'].locations[]" -o tsv 2>$null)
    $allLocations = Invoke-AzJson -Arguments @("account", "list-locations")
    foreach ($display in $fleetDisplay) {
        $match = @($allLocations | Where-Object { $_.displayName -eq $display }) | Select-Object -First 1
        if ($match) { $fleetLocations += $match.name }
    }
    $considered = @()
    $picked = $null
    foreach ($region in $candidates) {
        $aksOk = $null -ne (Invoke-AzJson -Arguments @("aks", "get-versions", "--location", $region))
        $fleetOk = ($fleetLocations.Count -eq 0) -or ($fleetLocations -contains $region)
        $skuOk = $true
        $skus = Invoke-AzJson -Arguments @("vm", "list-skus", "--location", $region, "--size", $aksVmSize, "--resource-type", "virtualMachines")
        if ($skus) {
            $sku = @($skus | Where-Object { $_.name -eq $aksVmSize }) | Select-Object -First 1
            if (-not $sku -or @($sku.restrictions | Where-Object { $_.type -eq "Location" }).Count -gt 0) { $skuOk = $false }
        }
        if ($aksOk -and $fleetOk -and $skuOk) {
            $considered += [ordered]@{ region = $region; aks = $aksOk; fleet = $fleetOk; vm_sku = $skuOk; result = "selected" }
            $picked = $region
            Write-Ok "$region : AKS + Fleet Manager + $aksVmSize available -> SELECTED"
            break
        }
        $why = @()
        if (-not $aksOk) { $why += "AKS versions query failed" }
        if (-not $fleetOk) { $why += "Fleet Manager not offered" }
        if (-not $skuOk) { $why += "$aksVmSize restricted/unavailable" }
        $considered += [ordered]@{ region = $region; aks = $aksOk; fleet = $fleetOk; vm_sku = $skuOk; result = "rejected"; reason = ($why -join "; ") }
        Write-WarnMsg "$region : rejected ($($why -join '; '))"
    }
    $reason = "automatic discovery (AKS + Fleet Manager + VM SKU availability)"
    if (-not $picked) { $picked = "westus2"; $reason = "no candidate verified - documented default"; Write-WarnMsg "Falling back to westus2" }
    $selection.azure = [ordered]@{ selected = $picked; reason = $reason; considered = $considered }
}

# --- AWS -------------------------------------------------------------------------
if ($targets -contains "aws") {
    Write-Step "AWS region discovery"
    $override = Get-EnvValue -DotEnv $dotEnv -Key "AWS_REGION_OVERRIDE"
    $awsProfile = Get-EnvValue -DotEnv $dotEnv -Key "AWS_PROFILE"
    $profileArgs = @()
    if ($awsProfile) { $profileArgs = @("--profile", $awsProfile) }
    if ($override) {
        Write-Ok "Using AWS_REGION_OVERRIDE=$override"
        $selection.aws = [ordered]@{ selected = $override; reason = "user override (.env AWS_REGION_OVERRIDE)"; considered = @() }
    } else {
        $considered = @()
        $picked = $null
        foreach ($region in @("us-west-2", "us-west-1", "us-east-1")) {
            $ok = $false
            try {
                $offers = (& aws ec2 describe-instance-type-offerings --region $region @profileArgs --location-type region `
                        --filters "Name=instance-type,Values=t3.large" --output json 2>$null | ConvertFrom-Json)
                $ok = ($null -ne $offers -and @($offers.InstanceTypeOfferings).Count -gt 0)
            } catch { $ok = $false }
            if ($ok) {
                $considered += [ordered]@{ region = $region; t3_large = $true; result = "selected" }
                $picked = $region
                Write-Ok "$region : t3.large offered -> SELECTED"
                break
            }
            $considered += [ordered]@{ region = $region; t3_large = $false; result = "rejected"; reason = "t3.large offering query failed (unauthenticated, denied or unavailable)" }
            Write-WarnMsg "$region : rejected"
        }
        $reason = "automatic discovery (t3.large offering)"
        if (-not $picked) { $picked = "us-west-2"; $reason = "no candidate verified - documented default" }
        $selection.aws = [ordered]@{ selected = $picked; reason = $reason; considered = $considered }
    }
}

# --- Equinix / ExpressRoute consistency --------------------------------------------
if ($targets -contains "equinix") {
    Write-Step "Equinix metro / ExpressRoute peering location"
    # Equinix metro code -> ExpressRoute peering location name (Equinix-served, US subset).
    $metroToPeering = @{
        SV = "Silicon Valley"; DC = "Washington DC"; CH = "Chicago"; DA = "Dallas"; SE = "Seattle"
        NY = "New York"; LA = "Los Angeles"; AT = "Atlanta"; TR = "Toronto"; DE = "Denver"; MI = "Miami"
    }
    $metro = (Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_METRO_CODE" -Default "SV").ToUpperInvariant()
    $peering = Get-EnvValue -DotEnv $dotEnv -Key "ER_PEERING_LOCATION" -Default "Silicon Valley"
    $expected = $metroToPeering[$metro]
    $consistent = (-not $expected) -or ($expected -eq $peering)
    if (-not $er) {
        Write-Info "ENABLE_EXPRESSROUTE=false (rehearsal mode) - no circuit will be created."
    } elseif ($consistent) {
        Write-Ok "Metro $metro <-> peering location '$peering'"
    } else {
        Write-WarnMsg "Metro $metro usually maps to '$expected' but ER_PEERING_LOCATION is '$peering' - the Fabric connection must be ordered in the circuit's peering metro."
    }
    $selection.equinix = [ordered]@{
        metro_code             = $metro
        er_peering_location    = $peering
        consistent             = $consistent
        expressroute_enabled   = $er
        note                   = "Ignite 2026 is at Moscone (San Francisco): SV / Silicon Valley (Equinix SV1) is the closest ExpressRoute location."
    }
}

$outPath = Get-RegionSelectionPath
$selection | ConvertTo-Json -Depth 10 | Set-Content -Path $outPath -Encoding utf8
Write-Step "Summary"
Write-Ok "Written to $outPath"
Write-Info "Azure: $($selection.azure.selected)"
if ($selection.aws) { Write-Info "AWS:   $($selection.aws.selected)" }
if ($selection.equinix) { Write-Info "Equinix: $($selection.equinix.metro_code) / '$($selection.equinix.er_peering_location)'" }
exit 0

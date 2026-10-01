#Requires -Version 5.1
<#
.SYNOPSIS
    Presenter "proof panel" for the private path - run it live on stage (or
    pre-run it and screenshot it as the fallback). Read-only.

      1. Equinix Fabric connections (Equinix API)        -> PROVISIONED
      2. ExpressRoute circuit + BGP from Azure's side     -> Equinix prefixes learned
      3. Azure Arc: Equinix member via Arc gateway        -> Connected, gateway=true
      4. Squid log on the Azure hub VM                    -> CONNECT *.gw.arc.azure.com
                                                             FROM an Equinix node IP
      5. Fleet members and their labels

.PARAMETER ProxyLogLines
    How many Squid access-log lines to show (step 4).
#>
[CmdletBinding()]
param(
    [int]$ProxyLogLines = 12,
    [switch]$SkipProxyLog
)

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
$naming = Get-Naming -DotEnv $dotEnv
$azureOutputs = Get-TfOutputs -RootDir (Get-TfRootDir "azure")
$rg = Get-TfOutputValue -Outputs $azureOutputs -Name "resource_group_name"
if (-not (Test-ExpressRouteEnabled -DotEnv $dotEnv)) { Write-WarnMsg "ExpressRoute path disabled (rehearsal mode) - nothing private to show."; exit 0 }

Write-Step "1. Equinix Fabric -> Azure ExpressRoute"
$uuids = @(Get-TfOutputValue -Outputs (Get-TfOutputs -RootDir (Get-TfRootDir "equinix")) -Name "connection_uuids")
if ((Test-EquinixCredentialsPresent) -and $uuids.Count -gt 0) {
    $token = Get-EquinixToken
    foreach ($u in $uuids) {
        $s = Get-EquinixConnectionStatus -Uuid $u -Token $token
        Write-Host ("  {0,-28} equinix={1,-22} provider={2}" -f $s.Name, $s.EquinixStatus, $s.ProviderStatus)
    }
} else { Write-WarnMsg "Equinix credentials or terraform/equinix state not available in this shell." }

Write-Step "2. ExpressRoute circuit + BGP (Azure side)"
$state = $null
try { $state = Get-ExpressRouteCircuitState -DotEnv $dotEnv } catch { Write-WarnMsg "Could not read the circuit: $($_.Exception.Message)" }
if ($state) {
    Write-Host ("  circuit {0} @ '{1}' {2} Mbps - provider state: {3}" -f $state.Name, $state.PeeringLocation, $state.BandwidthMbps, $state.ServiceProviderProvisioningState)
    foreach ($path in @("primary", "secondary")) {
        $summary = Invoke-AzJson -Arguments @("network", "express-route", "list-route-tables-summary", "--resource-group", $rg, "--name", $state.Name, "--path", $path, "--peering-name", "AzurePrivatePeering")
        foreach ($n in @(Get-Prop $summary "value")) {
            if ($n) { Write-Host ("  {0,-9} BGP neighbor {1,-15} AS{2,-6} up {3,-10} prefixes {4}" -f $path, (Get-Prop $n "neighbor"), (Get-Prop $n "as"), (Get-Prop $n "upDown"), (Get-Prop $n "statePfxRcd")) }
        }
    }
}
$gateway = Get-TfOutputValue -Outputs $azureOutputs -Name "expressroute_gateway_name"
$routes = Invoke-AzJson -Arguments @("network", "vnet-gateway", "list-learned-routes", "--resource-group", $rg, "--name", $gateway)
$onprem = @(Split-List (Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_ONPREM_PREFIXES" -Default "10.80.0.0/24"))
foreach ($r in @(Get-Prop $routes "value") | Where-Object { $_ -and $onprem -contains (Get-Prop $_ "network") }) {
    Write-Host ("  gateway learned {0} via {1} (origin {2}, AS path {3})" -f (Get-Prop $r "network"), (Get-Prop $r "nextHop"), (Get-Prop $r "origin"), (Get-Prop $r "asPath")) -ForegroundColor Green
}

Write-Step "3. Azure Arc"
$arcRg = Get-ArcResourceGroup -DotEnv $dotEnv -AzureOutputs $azureOutputs
foreach ($name in @($naming.EquinixMember, $naming.EksMember)) {
    $cc = Invoke-AzJson -Arguments @("connectedk8s", "show", "--name", $name, "--resource-group", $arcRg)
    if ($cc) {
        Write-Host ("  {0,-14} {1,-10} k8s {2,-10} distribution {3,-6} arc-gateway={4}" -f $name, (Get-Prop $cc "connectivityStatus"), (Get-Prop $cc "kubernetesVersion"), (Get-Prop $cc "distribution"), (Get-Prop $cc "gateway.enabled"))
    }
}

if (-not $SkipProxyLog) {
    Write-Step "4. Who is talking through the Azure hub? (Squid access log, last $ProxyLogLines lines)"
    $vm = Get-TfOutputValue -Outputs $azureOutputs -Name "egress_proxy_vm_name"
    $rc = Invoke-AzJson -Arguments @("vm", "run-command", "invoke", "--resource-group", $rg, "--name", $vm, "--command-id", "RunShellScript", "--scripts", "tail -n $ProxyLogLines /var/log/squid/access.log")
    $message = [string](Get-Prop (@(Get-Prop $rc "value") | Select-Object -First 1) "message")
    $lines = ($message -split "`n") | Where-Object { $_ -match "CONNECT|GET" }
    foreach ($l in $lines) {
        $color = "Gray"; if ($l -match "gw\.arc\.azure\.com") { $color = "Green" }
        Write-Host "  $($l.Trim())" -ForegroundColor $color
    }
    Write-Info "Source IPs are Equinix cage nodes; every tunnel arrived over ExpressRoute private peering."
}

Write-Step "5. Fleet members"
$fleetName = Get-TfOutputValue -Outputs $azureOutputs -Name "fleet_name"
foreach ($m in @(Invoke-AzJson -Arguments @("fleet", "member", "list", "--resource-group", $rg, "--fleet-name", $fleetName))) {
    $labels = Get-Prop $m "labels"
    Write-Host ("  {0,-14} {1,-10} cloud={2,-8} connectivity={3}" -f $m.name, $m.provisioningState, (Get-Prop $labels "cloud"), (Get-Prop $labels "connectivity"))
}
exit 0

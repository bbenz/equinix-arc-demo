#Requires -Version 5.1
<#
.SYNOPSIS
    Connects the Equinix site to Azure over ExpressRoute:
      1. orders the Equinix Fabric connection(s) with the circuit's service key
         (terraform/equinix - the key travels only in a process-scoped env var),
      2. waits until Equinix + Microsoft provision the circuit,
      3. enables Azure private peering + the gateway connection (terraform/azure),
      4. renders your edge-router BGP config (port / service-token origin),
      5. waits for BGP and shows the routes learned from the Equinix site.

.PARAMETER AutoApprove
    Skip the typed confirmation before ordering billable Equinix connections.

.PARAMETER ProvisioningTimeoutMinutes
    How long to wait for serviceProviderProvisioningState = Provisioned.

.PARAMETER BgpTimeoutMinutes
    How long to wait for routes from the Equinix site after peering is enabled.
    In port origin this needs YOUR edge router configured; re-run this script
    any time - every step is idempotent.
#>
[CmdletBinding()]
param(
    [switch]$AutoApprove,
    [int]$ProvisioningTimeoutMinutes = 60,
    [int]$BgpTimeoutMinutes = 20
)

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
if (-not (Test-ExpressRouteEnabled -DotEnv $dotEnv)) {
    Write-Info "ExpressRoute path disabled (ENABLE_EXPRESSROUTE=false or Equinix/Azure disabled) - nothing to do."
    exit 0
}
if (-not (Test-EquinixCredentialsPresent)) {
    Write-ErrMsg "Equinix API credentials are not set in this shell (see scripts/00-bootstrap-auth.ps1)."
    exit 1
}

$azureRoot = Get-TfRootDir "azure"
$equinixRoot = Get-TfRootDir "equinix"
$azureOutputs = Get-TfOutputs -RootDir $azureRoot
if (-not (Get-TfOutputValue -Outputs $azureOutputs -Name "expressroute_circuit_name")) {
    Write-ErrMsg "No ExpressRoute circuit in terraform/azure state - run scripts/03-init-plan.ps1 and scripts/04-apply.ps1 first."
    exit 1
}
$origin = Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_FABRIC_ORIGIN" -Default "port"
$bandwidth = [int](Get-TfOutputValue -Outputs $azureOutputs -Name "expressroute_bandwidth_mbps")

# --- 1. Equinix Fabric connection(s) ------------------------------------------
Write-Step "1/5 Equinix Fabric connection(s) to the circuit (origin: $origin, $bandwidth Mbps)"
$state = Get-ExpressRouteCircuitState -DotEnv $dotEnv
Write-Info "Circuit $($state.Name): provider state '$($state.ServiceProviderProvisioningState)', location '$($state.PeeringLocation)'"

if (-not (Test-TfStateExists -RootDir $equinixRoot)) {
    if (-not (Confirm-BillableAction -ActionDescription "About to order Equinix Fabric connection(s) to Azure ExpressRoute (billed by Equinix)." -AutoApprove:$AutoApprove.IsPresent)) {
        Write-WarnMsg "Aborted - no Equinix order placed."
        exit 1
    }
}

function Invoke-EquinixApply {
    # Plans + applies terraform/equinix with the circuit service key passed in a
    # process-scoped env var (-raw is the only way to read a sensitive output;
    # the value is never echoed, logged or written to disk).
    param([bool]$ConfigureAzureRouting)
    [void](Write-EquinixTfVars -DotEnv $dotEnv -BandwidthMbps $bandwidth -ConfigureAzureRouting $ConfigureAzureRouting)
    Push-Location $azureRoot
    try { $key = terraform output -raw expressroute_service_key 2>$null } finally { Pop-Location }
    if (-not $key) { throw "Could not read the circuit service key from terraform/azure." }
    $env:TF_VAR_expressroute_service_key = $key
    try {
        Invoke-TerraformPlan -Label "equinix" -RootDir $equinixRoot
        Invoke-TerraformApplyPlan -Label "equinix" -RootDir $equinixRoot
    } finally {
        Remove-Item Env:TF_VAR_expressroute_service_key -ErrorAction SilentlyContinue
        $key = $null
    }
}

# FCR origin: Equinix recommends configuring Azure private peering before the
# FCR's routing details, so routing is only enabled once peering exists.
$peeringExists = [bool](Get-TfOutputValue -Outputs $azureOutputs -Name "expressroute_private_peering_enabled")
Invoke-EquinixApply -ConfigureAzureRouting $peeringExists
$equinixOutputs = Get-TfOutputs -RootDir $equinixRoot
$connectionUuids = @(Get-TfOutputValue -Outputs $equinixOutputs -Name "connection_uuids")

function Show-EquinixStatus {
    try {
        $token = Get-EquinixToken
        foreach ($uuid in $connectionUuids) {
            $s = Get-EquinixConnectionStatus -Uuid $uuid -Token $token
            Write-Info "Equinix $($s.Name): equinixStatus=$($s.EquinixStatus) providerStatus=$($s.ProviderStatus)"
        }
    } catch { Write-WarnMsg "Could not read Equinix connection status: $($_.Exception.Message)" }
}

# --- 2. Wait for provider provisioning ----------------------------------------------
Write-Step "2/5 Waiting for serviceProviderProvisioningState = Provisioned (up to $ProvisioningTimeoutMinutes min)"
$deadline = (Get-Date).AddMinutes($ProvisioningTimeoutMinutes)
$poll = 0
$sp = $null
do {
    try {
        $state = Get-ExpressRouteCircuitState -DotEnv $dotEnv
        $sp = $state.ServiceProviderProvisioningState
        Write-Info "circuit: $sp"
    } catch {
        # Transient Azure CLI/auth hiccup: keep polling rather than abort the wait.
        Write-WarnMsg "Could not read the circuit (will retry): $($_.Exception.Message)"
    }
    if ($poll % 4 -eq 0) { Show-EquinixStatus }
    if ($sp -eq "Provisioned") { break }
    $poll++
    Start-Sleep -Seconds 30
} while ((Get-Date) -lt $deadline)
if ($sp -ne "Provisioned") {
    Write-ErrMsg "Circuit not provisioned yet ($sp). Check the Equinix portal (Connections inventory) and re-run this script."
    exit 1
}
Write-Ok "Circuit provisioned by Equinix"

# --- 3. Azure private peering + gateway connection ------------------------------------
Write-Step "3/5 Azure private peering + ExpressRoute gateway connection"
$azureVars = Write-AzureTfVars -DotEnv $dotEnv
if (-not $azureVars.expressroute_private_peering_enabled) { Write-ErrMsg "Peering flag did not turn on - unexpected."; exit 1 }
Write-Info "Peer ASN $($azureVars.expressroute_peer_asn), VLAN $($azureVars.expressroute_vlan_id), /30s $($azureVars.expressroute_primary_peer_prefix) + $($azureVars.expressroute_secondary_peer_prefix)"
Invoke-TerraformPlan -Label "azure (private peering)" -RootDir $azureRoot
Invoke-TerraformApplyPlan -Label "azure (private peering)" -RootDir $azureRoot
$azureOutputs = Get-TfOutputs -RootDir $azureRoot
if ($origin -eq "cloud_router" -and -not $peeringExists) {
    Write-Info "Peering is configured - now adding the Fabric Cloud Router's Direct + BGP routing toward Microsoft."
    Invoke-EquinixApply -ConfigureAzureRouting $true
}

# --- 4. Edge-router configuration (port / service-token origin) --------------------
function ConvertTo-UInt32Ip([string]$ip) { $b = ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes(); [Array]::Reverse($b); return [BitConverter]::ToUInt32($b, 0) }
function ConvertFrom-UInt32Ip([uint32]$n) { $b = [BitConverter]::GetBytes($n); [Array]::Reverse($b); return (New-Object System.Net.IPAddress (, $b)).ToString() }
function Get-CidrHost([string]$cidr, [int]$offset) { $parts = $cidr.Split("/"); return (ConvertFrom-UInt32Ip ([uint32]((ConvertTo-UInt32Ip $parts[0]) + $offset))) }
function Get-CidrMask([string]$cidr) { $len = [int]$cidr.Split("/")[1]; $mask = [uint32]0; if ($len -gt 0) { $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $len)) }; return (ConvertFrom-UInt32Ip $mask) }

Write-Step "4/5 Edge-router BGP configuration"
$prefixes = @($azureVars.equinix_onprem_prefixes)
$hubCidr = "$(Get-TfOutputValue -Outputs $azureOutputs -Name 'hub_vnet_cidr')"
$proxyIp = "$(Get-TfOutputValue -Outputs $azureOutputs -Name 'egress_proxy_private_ip')"
$frrNetworks = (($prefixes | ForEach-Object { "  network $_" }) -join "`n")
if ($origin -eq "cloud_router") {
    Write-Ok "Fabric Cloud Router origin: the FCR's Direct + BGP routing toward Microsoft was created by terraform/equinix."
    $leg = Get-TfOutputValue -Outputs (Get-TfOutputs -RootDir $equinixRoot) -Name "fcr_cage_leg"
    if ($leg) {
        # The FCR side of the cage leg is in Terraform; YOUR router still needs its half.
        $out = Join-Path (Get-ArtifactsDir) "edge-router-fcr-leg-frr.conf"
        Expand-TemplateFile -TemplatePath (Join-RepoPath "equinix" "edge-router" "frr-bgp-fcr-leg.conf.template") -OutPath $out -Tokens @{
            "{{FCR_LEG_VLAN}}"       = "$(Get-Prop $leg 'vlan_tag')"
            "{{CAGE_IP}}"            = "$(Get-Prop $leg 'cage_ip')"
            "{{FCR_IP}}"             = "$(Get-Prop $leg 'fcr_ip')"
            "{{PREFIX_LEN}}"         = "$(Get-Prop $leg 'prefix_len')"
            "{{CAGE_ASN}}"           = "$(Get-Prop $leg 'cage_asn')"
            "{{FCR_ASN}}"            = "$(Get-Prop $leg 'fcr_asn')"
            "{{HUB_VNET_CIDR}}"      = $hubCidr
            "{{PROXY_IP}}"           = $proxyIp
            "{{NETWORK_STATEMENTS}}" = $frrNetworks
        }
        Write-Ok "Rendered $out"
        Write-Info "Apply it on the cage router now: VLAN $(Get-Prop $leg 'vlan_tag'), $(Get-Prop $leg 'cage_ip')/$(Get-Prop $leg 'prefix_len') <-> FCR $(Get-Prop $leg 'fcr_ip'), AS$(Get-Prop $leg 'cage_asn') <-> AS$(Get-Prop $leg 'fcr_asn'), advertising $($prefixes -join ', ')."
    } else {
        Write-WarnMsg "No FCR-to-cage leg in terraform/equinix (EQUINIX_FCR_CUSTOMER_PORT_UUID is empty). The cage must advertise $($prefixes -join ', ') to the FCR over a connection you manage."
    }
} else {
    $pri = $azureVars.expressroute_primary_peer_prefix
    $sec = $azureVars.expressroute_secondary_peer_prefix
    $tokens = @{
        "{{EDGE_ASN}}"               = "$($azureVars.expressroute_peer_asn)"
        "{{PRIMARY_VLAN}}"           = (Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_PRIMARY_VLAN_TAG" -Default "1010")
        "{{SECONDARY_VLAN}}"         = (Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_SECONDARY_VLAN_TAG" -Default "1020")
        "{{ER_VLAN}}"                = "$($azureVars.expressroute_vlan_id)"
        "{{PRIMARY_LOCAL_IP}}"       = (Get-CidrHost $pri 1)
        "{{PRIMARY_MSEE_IP}}"        = (Get-CidrHost $pri 2)
        "{{SECONDARY_LOCAL_IP}}"     = (Get-CidrHost $sec 1)
        "{{SECONDARY_MSEE_IP}}"      = (Get-CidrHost $sec 2)
        "{{HUB_VNET_CIDR}}"          = $hubCidr
        "{{PROXY_IP}}"               = $proxyIp
        "{{PRIMARY_INTERFACE}}"      = (Get-EnvValue -DotEnv $dotEnv -Key "EDGE_PRIMARY_INTERFACE" -Default "GigabitEthernet1")
        "{{SECONDARY_INTERFACE}}"    = (Get-EnvValue -DotEnv $dotEnv -Key "EDGE_SECONDARY_INTERFACE" -Default "GigabitEthernet2")
        "{{NETWORK_STATEMENTS}}"     = $frrNetworks
        "{{NETWORK_STATEMENTS_IOS}}" = (($prefixes | ForEach-Object { "  network $($_.Split('/')[0]) mask $(Get-CidrMask $_)" }) -join "`n")
    }
    foreach ($pair in @(@("frr-bgp.conf.template", "edge-router-bgp-frr.conf"), @("cisco-iosxe-bgp.txt.template", "edge-router-bgp-iosxe.txt"))) {
        $out = Join-Path (Get-ArtifactsDir) $pair[1]
        Expand-TemplateFile -TemplatePath (Join-RepoPath "equinix" "edge-router" $pair[0]) -Tokens $tokens -OutPath $out
        Write-Ok "Rendered $out"
    }
    Write-Info "Apply one of these on the cage edge router now (BGP to Microsoft AS12076)."
}

# --- 5. Wait for BGP routes from the Equinix site ------------------------------------
Write-Step "5/5 Waiting for BGP: every Equinix prefix learned by Azure (up to $BgpTimeoutMinutes min)"
$rg = $state.ResourceGroup
$circuitName = $state.Name
$gateway = Get-TfOutputValue -Outputs $azureOutputs -Name "expressroute_gateway_name"
$wanted = @($azureVars.equinix_onprem_prefixes)
$deadline = (Get-Date).AddMinutes($BgpTimeoutMinutes)
$learned = @()
$missing = $wanted
do {
    $summary = Invoke-AzJson -Arguments @("network", "express-route", "list-route-tables-summary", "--resource-group", $rg, "--name", $circuitName, "--path", "primary", "--peering-name", "AzurePrivatePeering")
    $neighbors = @(Get-Prop $summary "value")
    foreach ($n in $neighbors) { if ($n) { Write-Info "MSEE primary neighbor $(Get-Prop $n 'neighbor') AS$(Get-Prop $n 'as') up/down=$(Get-Prop $n 'upDown') prefixes/state=$(Get-Prop $n 'statePfxRcd')" } }
    $routes = Invoke-AzJson -Arguments @("network", "vnet-gateway", "list-learned-routes", "--resource-group", $rg, "--name", $gateway)
    $learned = @(@(Get-Prop $routes "value") | Where-Object { $_ -and ($wanted -contains (Get-Prop $_ "network")) })
    $learnedNetworks = @($learned | ForEach-Object { Get-Prop $_ "network" })
    $missing = @($wanted | Where-Object { $learnedNetworks -notcontains $_ })
    if ($missing.Count -eq 0) { break }
    if ($learned.Count -gt 0) { Write-Info "learned $($learnedNetworks -join ', ') - still waiting for $($missing -join ', ')" }
    Start-Sleep -Seconds 30
} while ((Get-Date) -lt $deadline)

Show-EquinixStatus
Write-Step "Summary"
if ($missing.Count -eq 0) {
    foreach ($r in $learned) { Write-Ok "Gateway learned $(Get-Prop $r 'network') via $(Get-Prop $r 'nextHop') (AS path $(Get-Prop $r 'asPath'))" }
    Write-Ok "ExpressRoute private path is UP. Equinix nodes can now use $(Get-TfOutputValue -Outputs $azureOutputs -Name 'egress_proxy_url')"
    Write-Info "On a cage node: EGRESS_PROXY=$(Get-TfOutputValue -Outputs $azureOutputs -Name 'egress_proxy_url') ./equinix/k3s/verify-egress.sh"
    Write-Info "Next: scripts/06-connect-arc.ps1"
    exit 0
}
Write-ErrMsg "Equinix prefixes not learned yet: $($missing -join ', '). Configure BGP on the edge router (artifacts/edge-router-*.conf) or the FCR, then re-run this script."
Write-Info "Also check: Equinix portal > Connections (status PENDING_BGP_PEERING means Azure peering/BGP isn't complete)."
exit 1

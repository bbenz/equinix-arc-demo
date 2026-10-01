#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end validation of the demo; writes artifacts/validation-report.json
    and artifacts/validation-report.md.

.DESCRIPTION
    Per member (AKS, EKS, Equinix):
      - in-cluster smoke test Job (frontend HTTP, redis-cart, cartservice)
      - storefront HTTP 200 + the platform banner the Fleet override injected
        (azure-platform / aws-platform / onprem-platform)
    Equinix over ExpressRoute: the storefront is fetched FROM the Azure hub
    egress VM (az vm run-command) - proving the private path end to end - and
    from the published URL if STOREFRONT_ALLOWED_CIDRS is set.
    Platform: ExpressRoute circuit/peering/BGP routes, Arc connectivity +
    Arc gateway, Fleet members and the placement.
#>
[CmdletBinding()]
param(
    [int]$ExternalCheckTimeoutMinutes = 6,
    [switch]$SkipRunCommand
)

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
$targets = Get-EnabledTargets -DotEnv $dotEnv
$naming = Get-Naming -DotEnv $dotEnv
$er = Test-ExpressRouteEnabled -DotEnv $dotEnv
$azureOutputs = Get-TfOutputs -RootDir (Get-TfRootDir "azure")
$rg = Get-TfOutputValue -Outputs $azureOutputs -Name "resource_group_name"
$smokePath = Join-Path (Join-Path (Get-KubernetesDir) "validation") "smoke-test-job.yaml"
$allOk = $true
$report = [ordered]@{ generated_at = (Get-Date).ToUniversalTime().ToString("o"); members = @(); expressroute = $null; arc = @(); fleet = $null }

function Test-SmokeJob {
    param([Parameter(Mandatory)][string]$KubeContext)
    kubectl delete -f $smokePath --context $KubeContext --ignore-not-found=true 2>&1 | Out-Null
    kubectl apply -f $smokePath --context $KubeContext 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return [ordered]@{ status = "ApplyFailed"; logs = $null } }
    $deadline = (Get-Date).AddSeconds(180)
    $status = "Unknown"
    do {
        Start-Sleep -Seconds 5
        $job = kubectl get job equinix-arc-demo-smoke-test -n online-boutique --context $KubeContext -o json 2>$null | ConvertFrom-Json
        $succeeded = Get-Prop $job "status.succeeded"
        $failed = Get-Prop $job "status.failed"
        if ($succeeded -and $succeeded -ge 1) { $status = "Succeeded" } elseif ($failed -and $failed -ge 2) { $status = "Failed" }
    } while ($status -eq "Unknown" -and (Get-Date) -lt $deadline)
    $logs = kubectl logs job/equinix-arc-demo-smoke-test -n online-boutique --context $KubeContext 2>$null
    kubectl delete -f $smokePath --context $KubeContext --ignore-not-found=true 2>&1 | Out-Null
    return [ordered]@{ status = $status; logs = ($logs -join "`n") }
}

function Get-FrontendEndpoint {
    param([Parameter(Mandatory)][string]$KubeContext)
    $deadline = (Get-Date).AddMinutes($ExternalCheckTimeoutMinutes)
    do {
        $svc = kubectl get svc frontend-external -n online-boutique --context $KubeContext -o json 2>$null | ConvertFrom-Json
        $ingress = @(Get-Prop $svc "status.loadBalancer.ingress") | Where-Object { $_ } | Select-Object -First 1
        $ip = Get-Prop $ingress "ip"; if ($ip) { return $ip }
        $hostName = Get-Prop $ingress "hostname"; if ($hostName) { return $hostName }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Test-Storefront {
    # Retries until HTTP 200 AND the platform banner (new cloud LBs need a
    # warm-up, and the Fleet override can still be rolling out). Only both
    # together count as "OK".
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Banner)
    $deadline = (Get-Date).AddMinutes($ExternalCheckTimeoutMinutes)
    $lastError = $null
    $lastHttp = $null
    do {
        try {
            $r = Invoke-WebRequest -Uri $Url -TimeoutSec 15 -UseBasicParsing
            $lastHttp = [int]$r.StatusCode
            if ($lastHttp -eq 200 -and ($r.Content -match [regex]::Escape($Banner))) {
                return [ordered]@{ status = "OK"; url = $Url; http = 200; banner = $Banner; banner_found = $true }
            }
            if ($lastHttp -eq 200) { $lastError = "HTTP 200 but banner '$Banner' not found (check frontend-env-platform-override and the member's cloud label)" }
            else { $lastError = "HTTP $lastHttp" }
        } catch { $lastError = $_.Exception.Message }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    return [ordered]@{ status = "Failed"; url = $Url; http = $lastHttp; banner = $Banner; banner_found = $false; error = $lastError }
}

$members = @(
    @{ target = "azure"; context = $naming.AksContext; banner = "azure-platform" },
    @{ target = "aws"; context = $naming.EksContext; banner = "aws-platform" },
    @{ target = "equinix"; context = $naming.EquinixContext; banner = "onprem-platform" }
)

foreach ($m in $members) {
    if (-not ($targets -contains $m.target)) { continue }
    Write-Step "Validating $($m.target) (context $($m.context))"
    $entry = [ordered]@{ target = $m.target; context = $m.context; smoke = $null; storefront = @() }

    if (-not (Test-KubeContext -Name $m.context)) {
        Write-ErrMsg "context $($m.context) missing"; $allOk = $false; $report.members += $entry; continue
    }
    $entry.smoke = Test-SmokeJob -KubeContext $m.context
    if ($entry.smoke.status -eq "Succeeded") { Write-Ok "smoke test: Succeeded" } else { Write-ErrMsg "smoke test: $($entry.smoke.status)"; $allOk = $false }

    $endpoint = Get-FrontendEndpoint -KubeContext $m.context
    if (-not $endpoint) { Write-ErrMsg "frontend-external has no address"; $allOk = $false; $report.members += $entry; continue }

    if ($m.target -ne "equinix" -or -not $er) {
        $res = Test-Storefront -Url "http://$endpoint/" -Banner $m.banner
        $entry.storefront += $res
        if ($res.status -eq "OK") { Write-Ok "storefront http://$endpoint/ -> 200, banner '$($m.banner)' present (Fleet override applied)" }
        else { Write-ErrMsg "storefront http://$endpoint/ -> $($res.error)"; $allOk = $false }
        $report.members += $entry
        continue
    }

    # Equinix over ExpressRoute: fetch the storefront FROM Azure across the private path.
    if (-not $SkipRunCommand) {
        $vm = Get-TfOutputValue -Outputs $azureOutputs -Name "egress_proxy_vm_name"
        Write-Info "Fetching http://$endpoint/ from Azure VM $vm over ExpressRoute (az vm run-command, ~30-60s)..."
        $script = "curl -s -m 10 -o /tmp/sf.html -D /tmp/sf.hdr http://$endpoint/; head -n 1 /tmp/sf.hdr; grep -c $($m.banner) /tmp/sf.html"
        $rc = Invoke-AzJson -Arguments @("vm", "run-command", "invoke", "--resource-group", $rg, "--name", $vm, "--command-id", "RunShellScript", "--scripts", $script)
        $message = [string](Get-Prop (@(Get-Prop $rc "value") | Select-Object -First 1) "message")
        $httpMatch = [regex]::Match($message, "HTTP/\S+\s+(\d{3})")
        $countMatch = [regex]::Match($message, "(?m)^\s*(\d+)\s*$")
        $code = $null; if ($httpMatch.Success) { $code = [int]$httpMatch.Groups[1].Value }
        $bannerFound = $countMatch.Success -and [int]$countMatch.Groups[1].Value -gt 0
        $entry.storefront += [ordered]@{ status = $(if ($code -eq 200) { "OK" } else { "Failed" }); path = "azure-hub-vm-over-expressroute"; url = "http://$endpoint/"; http = $code; banner = $m.banner; banner_found = $bannerFound }
        if ($code -eq 200 -and $bannerFound) { Write-Ok "Azure hub -> ExpressRoute -> Equinix storefront: HTTP 200, 'On-Premises' banner present" }
        else { Write-ErrMsg "Azure hub could not fetch the Equinix storefront over ExpressRoute (HTTP $code)"; $allOk = $false }
    }
    $published = Get-TfOutputValue -Outputs $azureOutputs -Name "storefront_public_url"
    if ($published) {
        $res = Test-Storefront -Url $published -Banner $m.banner
        $res.path = "presenter-browser-via-hub-nginx"
        $entry.storefront += $res
        if ($res.status -eq "OK") { Write-Ok "published storefront $published -> 200 with banner '$($m.banner)' (served over ExpressRoute)" } else { Write-ErrMsg "published storefront $published -> $($res.error)"; $allOk = $false }
    }
    $report.members += $entry
}

# --- ExpressRoute -------------------------------------------------------------------
if ($er) {
    Write-Step "ExpressRoute path"
    $state = $null
    $stateError = $null
    try { $state = Get-ExpressRouteCircuitState -DotEnv $dotEnv } catch { $stateError = $_.Exception.Message }
    if (-not $state) {
        $reason = "circuit not found in terraform/azure state or in Azure"
        if ($stateError) { $reason = "could not read the circuit: $stateError" }
        Write-ErrMsg "ExpressRoute: $reason"
        $report.expressroute = [ordered]@{ circuit = $null; error = $reason }
        $allOk = $false
    } else {
        $peering = Invoke-AzJson -Arguments @("network", "express-route", "peering", "show", "--resource-group", $rg, "--circuit-name", $state.Name, "--name", "AzurePrivatePeering")
        $gateway = Get-TfOutputValue -Outputs $azureOutputs -Name "expressroute_gateway_name"
        $routes = Invoke-AzJson -Arguments @("network", "vnet-gateway", "list-learned-routes", "--resource-group", $rg, "--name", $gateway)
        $wanted = @(Split-List (Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_ONPREM_PREFIXES" -Default "10.80.0.0/24"))
        $learned = @(@(Get-Prop $routes "value") | Where-Object { $_ -and ($wanted -contains (Get-Prop $_ "network")) } | ForEach-Object { Get-Prop $_ "network" } | Sort-Object -Unique)
        $missing = @($wanted | Where-Object { $learned -notcontains $_ })
        $report.expressroute = [ordered]@{
            circuit = $state.Name; provider_state = $state.ServiceProviderProvisioningState; peering_location = $state.PeeringLocation
            private_peering_state = (Get-Prop $peering "state"); learned_equinix_prefixes = $learned; missing_equinix_prefixes = $missing
        }
        if ($state.ServiceProviderProvisioningState -eq "Provisioned") { Write-Ok "circuit $($state.Name): Provisioned by Equinix at '$($state.PeeringLocation)'" } else { Write-ErrMsg "circuit provider state: $($state.ServiceProviderProvisioningState)"; $allOk = $false }
        if ((Get-Prop $peering "state") -eq "Enabled") { Write-Ok "Azure private peering Enabled" } else { Write-ErrMsg "private peering state: $(Get-Prop $peering 'state')"; $allOk = $false }
        if ($missing.Count -eq 0) { Write-Ok "gateway learned every Equinix prefix: $($learned -join ', ')" } else { Write-ErrMsg "Equinix prefixes not learned over BGP: $($missing -join ', ')"; $allOk = $false }
    }
}

# --- Arc ---------------------------------------------------------------------------
Write-Step "Azure Arc"
$arcRg = Get-ArcResourceGroup -DotEnv $dotEnv -AzureOutputs $azureOutputs
foreach ($pair in @(@("aws", $naming.EksMember), @("equinix", $naming.EquinixMember))) {
    if (-not ($targets -contains $pair[0])) { continue }
    $cc = Invoke-AzJson -Arguments @("connectedk8s", "show", "--name", $pair[1], "--resource-group", $arcRg)
    $entry = [ordered]@{ name = $pair[1]; connectivity = (Get-Prop $cc "connectivityStatus"); agent_version = (Get-Prop $cc "agentVersion"); distribution = (Get-Prop $cc "distribution"); kubernetes_version = (Get-Prop $cc "kubernetesVersion"); gateway_enabled = (Get-Prop $cc "gateway.enabled") }
    $report.arc += $entry
    if ($entry.connectivity -eq "Connected") { Write-Ok "$($pair[1]): Connected (agent $($entry.agent_version), k8s $($entry.kubernetes_version), gateway=$($entry.gateway_enabled))" } else { Write-ErrMsg "$($pair[1]): $($entry.connectivity)"; $allOk = $false }
    if ($pair[0] -eq "equinix" -and $er -and "$($entry.gateway_enabled)" -ne "True") { Write-ErrMsg "Arc gateway not enabled on the Equinix member"; $allOk = $false }
}

# --- Fleet -------------------------------------------------------------------------
Write-Step "Fleet Manager"
$fleetName = Get-TfOutputValue -Outputs $azureOutputs -Name "fleet_name"
$fleetMembers = @(Invoke-AzJson -Arguments @("fleet", "member", "list", "--resource-group", $rg, "--fleet-name", $fleetName))
$crp = kubectl get clusterresourceplacement crp-online-boutique --context $naming.HubContext -o json 2>$null | ConvertFrom-Json
$availableCond = @(Get-Prop $crp "status.conditions") | Where-Object { $_ -and $_.type -eq "ClusterResourcePlacementAvailable" } | Select-Object -First 1
$report.fleet = [ordered]@{ name = $fleetName; members = @($fleetMembers | ForEach-Object { [ordered]@{ name = $_.name; state = $_.provisioningState; labels = (Get-Prop $_ "labels") } }); placement_available = [bool]($availableCond -and $availableCond.status -eq "True") }
foreach ($fm in $fleetMembers) { Write-Info "member $($fm.name): $($fm.provisioningState)" }
if ($report.fleet.placement_available) { Write-Ok "crp-online-boutique: Available" } else { Write-ErrMsg "crp-online-boutique not Available"; $allOk = $false }

# --- Reports ---------------------------------------------------------------------------
$report.overall = $(if ($allOk) { "PASS" } else { "FAIL" })
$jsonPath = Join-Path (Get-ArtifactsDir) "validation-report.json"
$report | ConvertTo-Json -Depth 12 | Set-Content -Path $jsonPath -Encoding utf8
$md = @("# Validation report", "", "Generated: $($report.generated_at)  ", "Overall: **$($report.overall)**", "", "| Member | Smoke test | Storefront checks |", "|---|---|---|")
foreach ($e in $report.members) {
    $checks = (@($e.storefront) | ForEach-Object { "$($_.status) $($_.url) banner=$($_.banner_found)" }) -join "<br>"
    $md += "| $($e.target) | $(Get-Prop $e.smoke 'status') | $checks |"
}
Set-Content -Path (Join-Path (Get-ArtifactsDir) "validation-report.md") -Value $md -Encoding utf8

Write-Step "Summary"
Write-Ok "Reports: $jsonPath (+ .md)"
if ($allOk) { Write-Ok "Demo validated end to end: $($targets -join ', ')"; exit 0 }
Write-ErrMsg "Validation found problems - see the report and docs/TROUBLESHOOTING.md."
exit 1

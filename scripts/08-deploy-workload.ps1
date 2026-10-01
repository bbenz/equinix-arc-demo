#Requires -Version 5.1
<#
.SYNOPSIS
    Applies the cloud-neutral Online Boutique base, the per-footprint
    ResourceOverrides and the ClusterResourcePlacement to the Fleet HUB.
    Fleet propagates everything to AKS, Arc-EKS and Arc-Equinix. Nothing is
    applied directly to a member cluster - that would bypass Fleet.

.DESCRIPTION
    1. (ENABLE_PRIVATE_ACR) imports the demo images into the private ACR.
    2. Renders kubernetes/overrides into artifacts/rendered-overrides
       (fills __AWS_PUBLIC_SUBNET_IDS__ from terraform/aws outputs).
    3. Server-side dry-run of every manifest against the hub, then apply.
    4. Waits for ClusterResourcePlacementAvailable and prints per-member status.
#>
[CmdletBinding()]
param(
    [int]$TimeoutMinutes = 15
)

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
$naming = Get-Naming -DotEnv $dotEnv
$hub = $naming.HubContext
$k8sDir = Get-KubernetesDir

if (-not (Test-KubeContext -Name $hub)) { Write-ErrMsg "kube context '$hub' not found - run scripts/07-join-fleet.ps1"; exit 1 }

# --- 1. Optional private ACR -------------------------------------------------------
if ((Test-ExpressRouteEnabled -DotEnv $dotEnv) -and (Get-EnvBool -DotEnv $dotEnv -Key "ENABLE_PRIVATE_ACR" -Default $false)) {
    $acr = Get-TfOutputValue -Outputs (Get-TfOutputs -RootDir (Get-TfRootDir "azure")) -Name "private_acr_name"
    if ($acr) {
        & (Join-Path (Join-Path $PSScriptRoot "lib") "Import-ImagesToAcr.ps1") -RegistryName $acr
        if ($LASTEXITCODE -ne 0) { Write-ErrMsg "Image import failed."; exit 1 }
    }
}

# --- 2. Render overrides -------------------------------------------------------------
Write-Step "Rendering overrides"
$renderDir = Join-Path (Get-ArtifactsDir) "rendered-overrides"
New-Item -ItemType Directory -Path $renderDir -Force | Out-Null
Get-ChildItem -Path $renderDir -Filter "*.yaml" | Remove-Item -Force
$subnets = @(Get-TfOutputValue -Outputs (Get-TfOutputs -RootDir (Get-TfRootDir "aws")) -Name "public_subnet_ids")
$subnetValue = ($subnets | Where-Object { $_ }) -join ","
if (-not $subnetValue) { Write-Info "No terraform/aws outputs - AWS subnet annotation left empty (no cloud=aws member to select)." }
foreach ($file in Get-ChildItem -Path (Join-Path $k8sDir "overrides") -Filter "*.yaml") {
    $text = (Get-Content -Raw -Path $file.FullName).Replace("__AWS_PUBLIC_SUBNET_IDS__", $subnetValue)
    Set-Content -Path (Join-Path $renderDir $file.Name) -Value $text -Encoding utf8
    Write-Ok "Rendered $($file.Name)"
}

# --- 3. Dry-run, then apply ---------------------------------------------------------
$baseDir = Join-Path $k8sDir "base"
$crpPath = Join-Path (Join-Path $k8sDir "fleet") "cluster-resource-placement.yaml"

Write-Step "Server-side dry run against the hub (advisory)"
# The namespace must exist before namespaced objects can be dry-run server-side.
kubectl create namespace online-boutique --context $hub --dry-run=client -o yaml | kubectl apply --context $hub -f - | Out-Null
$dryRunOk = $true
foreach ($set in @(@("-k", $baseDir), @("-f", $renderDir), @("-f", $crpPath))) {
    $out = kubectl apply $set[0] $set[1] --context $hub --dry-run=server 2>&1
    if ($LASTEXITCODE -ne 0) {
        $dryRunOk = $false
        Write-WarnMsg "dry-run rejected $($set[1]): $(($out | Select-Object -Last 1))"
    }
}
if ($dryRunOk) { Write-Ok "All manifests accepted by the hub API server" }
else { Write-WarnMsg "Continuing: some admission webhooks don't support dry-run; the real apply below is authoritative." }

Write-Step "Applying base workload, overrides and placement to the hub"
Invoke-Checked -Command "kubectl" -Arguments @("apply", "-k", $baseDir, "--context", $hub) -ErrorContext "apply base"
Invoke-Checked -Command "kubectl" -Arguments @("apply", "-f", $renderDir, "--context", $hub) -ErrorContext "apply overrides"
Invoke-Checked -Command "kubectl" -Arguments @("apply", "-f", $crpPath, "--context", $hub) -ErrorContext "apply CRP"

# --- 4. Wait for placement ------------------------------------------------------------
Write-Step "Waiting for crp-online-boutique (up to $TimeoutMinutes min)"
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$available = $false
$crp = $null
do {
    Start-Sleep -Seconds 15
    $raw = kubectl get clusterresourceplacement crp-online-boutique --context $hub -o json 2>$null
    if ($raw) {
        $crp = ($raw -join "`n") | ConvertFrom-Json
        $conditions = @(Get-Prop $crp "status.conditions")
        $availableCondition = $conditions | Where-Object { $_.type -eq "ClusterResourcePlacementAvailable" } | Select-Object -First 1
        $available = ($availableCondition -and $availableCondition.status -eq "True")
        Write-Info (($conditions | ForEach-Object { "$($_.type)=$($_.status)" }) -join ", ")
    }
} while (-not $available -and (Get-Date) -lt $deadline)

Write-Step "Per-member placement status"
foreach ($p in @(Get-Prop $crp "status.placementStatuses")) {
    if ($null -eq $p) { continue }
    $conds = (@($p.conditions) | ForEach-Object { "$($_.type)=$($_.status)" }) -join ", "
    Write-Info "$($p.clusterName): $conds"
}

Write-Step "Summary"
if ($available) {
    Write-Ok "Placement Available on every selected member."
    Write-Info "Next: scripts/09-validate-demo.ps1"
    exit 0
}
Write-ErrMsg "Placement not Available after $TimeoutMinutes min. Inspect: kubectl describe clusterresourceplacement crp-online-boutique --context $hub"
exit 1

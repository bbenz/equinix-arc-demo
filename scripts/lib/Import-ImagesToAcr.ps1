#Requires -Version 5.1
<#
.SYNOPSIS
    Imports every image referenced by kubernetes/base into the private ACR,
    keeping the upstream repository paths so K3s containerd mirrors
    (equinix/k3s/install-k3s-*.sh, PRIVATE_ACR=...) resolve them unchanged:
      us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/frontend:v0.10.6
        -> <acr>/online-boutique-ci/microservices-demo/frontend:v0.10.6
      redis:7.4-alpine -> <acr>/library/redis:7.4-alpine

.DESCRIPTION
    `az acr import` is a server-side copy (works with public network access
    disabled thanks to the trusted-services bypass). Docker Hub may rate-limit
    anonymous imports; re-run if that happens.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RegistryName
)

. (Join-Path $PSScriptRoot "common.ps1")

Write-Step "Importing demo images into $RegistryName"
$images = @()
foreach ($file in Get-ChildItem -Path (Join-Path (Get-KubernetesDir) "base") -Filter "*.yaml") {
    foreach ($m in [regex]::Matches((Get-Content -Raw $file.FullName), '(?m)^\s*image:\s*"?([^"\s]+)"?\s*$')) {
        $images += $m.Groups[1].Value
    }
}
$images = @($images | Sort-Object -Unique)
$failed = 0
foreach ($image in $images) {
    $digest = $null
    $ref = $image
    if ($ref.Contains("@")) { $digest = $ref.Split("@")[1]; $ref = $ref.Split("@")[0] }
    $firstSegment = $ref.Split("/")[0]
    $isRegistryHost = $firstSegment.Contains(".") -or $firstSegment.Contains(":")
    if ($isRegistryHost) {
        $source = $ref
        $target = $ref.Substring($firstSegment.Length + 1)
    } else {
        $repo = $ref
        if (-not $repo.Contains("/")) { $repo = "library/$repo" }
        $source = "docker.io/$repo"
        $target = $repo
    }
    if ($digest) { $source = ($source.Split(":")[0]) + "@" + $digest }
    Write-Info "$image -> $RegistryName/$target"
    az acr import --name $RegistryName --source $source --image $target --force -o none 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-ErrMsg "import failed: $image"; $failed++ }
}
if ($failed -gt 0) { exit 1 }
Write-Ok "Imported $($images.Count) image(s)"
exit 0

#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies local CLI tools and installs/updates the Azure CLI extensions the
    demo needs (connectedk8s, fleet, arcgateway). Touches only the local
    machine's tooling - never a cloud resource.

.DESCRIPTION
    Always required: git, terraform, kubectl, az.
    Required per target: helm + aws (ENABLE_AWS), arcgateway extension
    (ExpressRoute path). curl is checked for the Equinix-side scripts.
    Exits non-zero only if a tool needed by an enabled target is missing.
#>
[CmdletBinding()]
param(
    [switch]$SkipExtensionUpdate
)

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

Write-Step "Checking local tool versions"
$dotEnv = Get-DotEnv
$targets = Get-EnabledTargets -DotEnv $dotEnv
$er = Test-ExpressRouteEnabled -DotEnv $dotEnv
$missing = @()

function Test-Tool {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$VersionArgs, [bool]$Required = $true, [scriptblock]$Parser)
    if (Test-CommandExists $Name) {
        try {
            $raw = @(& $Name @VersionArgs 2>&1)
            if ($Parser) { $version = (& $Parser $raw) } else { $version = $raw | Select-Object -First 1 }
            Write-Ok "$Name found: $version"
        } catch {
            Write-Ok "$Name found (version not parsed)"
        }
        return $true
    }
    if ($Required) {
        Write-ErrMsg "$Name NOT found (required)"
        $script:missing += $Name
    } else {
        Write-WarnMsg "$Name NOT found (not required for the enabled targets)"
    }
    return $false
}

[void](Test-Tool -Name "git" -VersionArgs @("--version"))
[void](Test-Tool -Name "terraform" -VersionArgs @("version"))
[void](Test-Tool -Name "kubectl" -VersionArgs @("version", "--client"))
[void](Test-Tool -Name "az" -VersionArgs @("version", "-o", "json") -Parser {
        param($lines)
        try { "azure-cli " + ((($lines -join "`n") | ConvertFrom-Json).'azure-cli') } catch { $lines | Select-Object -First 1 }
    })
[void](Test-Tool -Name "helm" -VersionArgs @("version", "--short") -Required:($targets -contains "aws"))
[void](Test-Tool -Name "aws" -VersionArgs @("--version") -Required:($targets -contains "aws"))
# The Fleet hub API is Entra ID-protected: kubectl needs the kubelogin exec plugin.
[void](Test-Tool -Name "kubelogin" -VersionArgs @("--version"))
[void](Test-Tool -Name "curl" -VersionArgs @("--version") -Required:$false)

Write-Step "Azure CLI extensions"
if (Test-CommandExists "az") {
    $wanted = @("connectedk8s", "fleet")
    if ($er) { $wanted += "arcgateway" }
    $installed = @()
    $extList = Invoke-AzJson -Arguments @("extension", "list")
    if ($extList) { $installed = @($extList | ForEach-Object { $_.name }) }
    foreach ($ext in $wanted) {
        if ($installed -contains $ext) {
            if ($SkipExtensionUpdate) {
                Write-Ok "az extension '$ext' installed (update skipped)"
                continue
            }
            az extension update --name $ext 2>&1 | Out-Null
            # `update` exits non-zero when already latest on some CLI versions; re-check presence.
            Write-Ok "az extension '$ext' installed (updated if a newer version existed)"
        } else {
            Write-Info "Installing az extension '$ext'..."
            az extension add --name $ext --yes 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok "az extension '$ext' installed" }
            else { Write-ErrMsg "Could not install az extension '$ext' - run: az extension add --name $ext"; $missing += "az-ext:$ext" }
        }
    }
} else {
    Write-WarnMsg "az CLI not found - skipping extension checks"
}

Write-Step "Summary"
Write-Info "Enabled targets: $($targets -join ', ')   ExpressRoute path: $er"
if ($missing.Count -gt 0) {
    Write-ErrMsg "Missing: $($missing -join ', ')"
    Write-Host ""
    Write-Host "Install guidance (Windows):" -ForegroundColor Yellow
    Write-Host "  terraform - winget install HashiCorp.Terraform"
    Write-Host "  kubectl   - winget install Kubernetes.kubectl"
    Write-Host "  az        - winget install Microsoft.AzureCLI"
    Write-Host "  helm      - winget install Helm.Helm   (then open a new terminal so PATH refreshes)"
    Write-Host "  aws       - winget install Amazon.AWSCLI"
    Write-Host "  kubelogin - winget install Microsoft.Azure.Kubelogin   (or: az aks install-cli)"
    exit 1
}
Write-Ok "All tools required for the enabled targets are present."
exit 0

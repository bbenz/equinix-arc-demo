#Requires -Version 5.1
<#
.SYNOPSIS
    Checks (and, interactively, establishes) authentication for every enabled
    target: Azure CLI, AWS CLI, the Equinix Fabric API and the Equinix
    cluster's kubeconfig context.

.DESCRIPTION
    Console credentials can never be converted into CLI/API credentials
    programmatically. This script only detects state and launches each
    provider's OFFICIAL interactive login - it never scrapes, bypasses MFA or
    stores secrets. Equinix API credentials are read from the environment
    (EQUINIX_API_CLIENTID / EQUINIX_API_CLIENTSECRET or EQUINIX_API_TOKEN)
    and validated with a token request; nothing is printed or written.

.PARAMETER NonInteractive
    Report only; never launch a login flow. Exits non-zero if anything is missing.
#>
[CmdletBinding()]
param(
    [switch]$NonInteractive
)

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
$targets = Get-EnabledTargets -DotEnv $dotEnv
$naming = Get-Naming -DotEnv $dotEnv
$er = Test-ExpressRouteEnabled -DotEnv $dotEnv
$allOk = $true

# --- Azure (always needed: Fleet, Arc and ExpressRoute live in Azure) --------
Write-Step "Azure authentication"
$account = Invoke-AzJson -Arguments @("account", "show")
if (-not $account -and -not $NonInteractive) {
    Write-Info "Launching 'az login' (browser / device code)..."
    az login | Out-Null
    $account = Invoke-AzJson -Arguments @("account", "show")
}
if ($account) {
    Write-Ok "Logged in as $($account.user.name) - tenant $($account.tenantId), subscription '$($account.name)'"
    $expectedTenant = Get-EnvValue -DotEnv $dotEnv -Key "AZURE_EXPECTED_TENANT_ID"
    $expectedSub = Get-EnvValue -DotEnv $dotEnv -Key "AZURE_EXPECTED_SUBSCRIPTION_ID"
    if ($expectedTenant -and $account.tenantId -ne $expectedTenant) {
        Write-ErrMsg "Active tenant does not match AZURE_EXPECTED_TENANT_ID. Run: az login --tenant $expectedTenant"
        $allOk = $false
    }
    if ($expectedSub -and $account.id -ne $expectedSub) {
        if (-not $NonInteractive) {
            az account set --subscription $expectedSub
            Write-Ok "Switched to subscription $expectedSub"
        } else {
            Write-ErrMsg "Active subscription does not match AZURE_EXPECTED_SUBSCRIPTION_ID. Run: az account set --subscription $expectedSub"
            $allOk = $false
        }
    }
} else {
    Write-ErrMsg "Azure CLI is not authenticated."
    $allOk = $false
}

# --- AWS -------------------------------------------------------------------------
if ($targets -contains "aws") {
    Write-Step "AWS authentication"
    if (-not (Test-CommandExists "aws")) {
        Write-ErrMsg "aws CLI not installed - run scripts/00-check-tools.ps1"
        $allOk = $false
    } else {
        $awsProfile = Get-EnvValue -DotEnv $dotEnv -Key "AWS_PROFILE"
        $profileArgs = @()
        if ($awsProfile) { $profileArgs = @("--profile", $awsProfile) }
        $identity = $null
        try { $identity = (& aws sts get-caller-identity @profileArgs --output json 2>$null | ConvertFrom-Json) } catch { $identity = $null }
        if (-not $identity -and -not $NonInteractive) {
            Write-WarnMsg "Not authenticated to AWS. Console username/password cannot be converted to CLI credentials."
            $choice = Read-Host "Launch 'aws sso login'$(if ($awsProfile) { " --profile $awsProfile" }) now? (use 'aws configure sso' first if the profile doesn't exist) [y/N]"
            if ($choice -match '^[yY]') {
                & aws sso login @profileArgs
                try { $identity = (& aws sts get-caller-identity @profileArgs --output json 2>$null | ConvertFrom-Json) } catch { $identity = $null }
            }
        }
        if ($identity) {
            Write-Ok "Authenticated as $($identity.Arn) - account $($identity.Account)"
            $expectedAccount = Get-EnvValue -DotEnv $dotEnv -Key "AWS_EXPECTED_ACCOUNT_ID"
            if ($expectedAccount -and $identity.Account -ne $expectedAccount) {
                Write-ErrMsg "AWS account does not match AWS_EXPECTED_ACCOUNT_ID."
                $allOk = $false
            }
        } else {
            Write-ErrMsg "AWS CLI is not authenticated - see docs/AUTHENTICATION-AND-PERMISSIONS.md."
            $allOk = $false
        }
    }
}

# --- Equinix Fabric API (only needed for the ExpressRoute path) ----------------
if ($er) {
    Write-Step "Equinix Fabric API credentials"
    if (-not (Test-EquinixCredentialsPresent)) {
        Write-ErrMsg "EQUINIX_API_CLIENTID / EQUINIX_API_CLIENTSECRET (or EQUINIX_API_TOKEN) are not set in this shell."
        Write-Info "Create an app in the Equinix Developer Portal (My Apps), then in THIS shell:"
        Write-Info '  $env:EQUINIX_API_CLIENTID = Read-Host "Client ID"'
        Write-Info '  $env:EQUINIX_API_CLIENTSECRET = (New-Object PSCredential "x", (Read-Host "Client secret" -AsSecureString)).GetNetworkCredential().Password'
        Write-Info "Never put them in .env, tfvars or a commit."
        $allOk = $false
    } else {
        try {
            $token = Get-EquinixToken
            if ($token) { Write-Ok "Equinix OAuth token issued (credentials valid - token not displayed)" }
        } catch {
            Write-ErrMsg "Equinix token request failed: $($_.Exception.Message)"
            $allOk = $false
        }
    }
}

# --- Equinix cluster kubeconfig context ------------------------------------------
if ($targets -contains "equinix") {
    Write-Step "Equinix cluster access (kube context '$($naming.EquinixContext)')"
    if (Test-KubeContext -Name $naming.EquinixContext) {
        $nodes = kubectl get nodes --context $naming.EquinixContext --request-timeout=15s -o name 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Reachable - $(@($nodes).Count) node(s)"
        } else {
            Write-ErrMsg "Context exists but the API server is unreachable from this machine (VPN/jump host to the cage needed for onboarding - see docs/EQUINIX-CLUSTER.md)."
            $allOk = $false
        }
    } else {
        Write-ErrMsg "No kube context '$($naming.EquinixContext)'. Build the cluster with equinix/k3s/install-k3s-server.sh and merge its kubeconfig (docs/EQUINIX-CLUSTER.md)."
        $allOk = $false
    }
}

Write-Step "Summary"
if ($allOk) {
    Write-Ok "All enabled targets are authenticated: $($targets -join ', ')$(if ($er) { ' + Equinix Fabric API' })"
    exit 0
}
Write-ErrMsg "Something above needs attention. Fix it and re-run, or disable a target in .env (ENABLE_AWS / ENABLE_EQUINIX / ENABLE_EXPRESSROUTE)."
exit 1

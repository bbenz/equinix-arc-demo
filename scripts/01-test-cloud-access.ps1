#Requires -Version 5.1
<#
.SYNOPSIS
    Non-destructive preflight for every enabled target. Proves the active
    credentials can read real data and reports resource-provider state.

.PARAMETER RegisterProviders
    Register any missing Azure resource providers this demo needs (additive,
    subscription-scoped, never unregistered by teardown). Without this switch
    the script only reports.
#>
[CmdletBinding()]
param(
    [switch]$RegisterProviders
)

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
$targets = Get-EnabledTargets -DotEnv $dotEnv
$naming = Get-Naming -DotEnv $dotEnv
$er = Test-ExpressRouteEnabled -DotEnv $dotEnv
$allOk = $true

# --- Azure -------------------------------------------------------------------------
Write-Step "Azure: read-only access + resource providers"
$account = Invoke-AzJson -Arguments @("account", "show")
if (-not $account) {
    Write-ErrMsg "az account show failed - run 'az login' (scripts/00-bootstrap-auth.ps1)."
    $allOk = $false
} else {
    Write-Ok "Subscription '$($account.name)' ($($account.id))"
    $groups = Invoke-AzJson -Arguments @("group", "list", "--query", "[].name")
    if ($null -ne $groups) { Write-Ok "Resource group read OK ($(@($groups).Count) visible)" } else { Write-WarnMsg "Could not list resource groups." }

    $providers = @(
        "Microsoft.ContainerService",        # AKS + Fleet Manager
        "Microsoft.Kubernetes",              # Arc-enabled Kubernetes
        "Microsoft.KubernetesConfiguration", # Arc extensions (Fleet member agent)
        "Microsoft.ExtendedLocation",        # Arc custom locations dependency
        "Microsoft.Network",                 # VNet, ExpressRoute, gateway
        "Microsoft.Compute"                  # egress proxy VM
    )
    if ($er) { $providers += "Microsoft.HybridCompute" } # Arc gateway resource
    if (Get-EnvBool -DotEnv $dotEnv -Key "ENABLE_PRIVATE_ACR" -Default $false) { $providers += "Microsoft.ContainerRegistry" }

    foreach ($p in $providers) {
        $state = az provider show --namespace $p --query "registrationState" -o tsv 2>$null
        if ($state -eq "Registered") {
            Write-Ok "$p : Registered"
        } elseif ($RegisterProviders) {
            Write-Info "Registering $p ..."
            az provider register --namespace $p --wait 2>&1 | Out-Null
            $state = az provider show --namespace $p --query "registrationState" -o tsv 2>$null
            if ($state -eq "Registered") { Write-Ok "$p : Registered (just now)" } else { Write-ErrMsg "$p : $state"; $allOk = $false }
        } else {
            Write-WarnMsg "$p : $state - re-run with -RegisterProviders (azurerm 5.x does not auto-register)"
            $allOk = $false
        }
    }

    if ($er) {
        Write-Info "Checking that Equinix serves ExpressRoute at the configured peering location..."
        $location = Get-EnvValue -DotEnv $dotEnv -Key "ER_PEERING_LOCATION" -Default "Silicon Valley"
        $providersList = Invoke-AzJson -Arguments @("network", "express-route", "list-service-providers")
        $equinix = @($providersList | Where-Object { $_.name -eq "Equinix" }) | Select-Object -First 1
        if ($equinix -and (@($equinix.peeringLocations) -contains $location)) {
            Write-Ok "Equinix offers ExpressRoute at '$location'"
        } elseif ($equinix) {
            Write-ErrMsg "Equinix does not list '$location'. Valid examples: $((@($equinix.peeringLocations) | Select-Object -First 12) -join ', ')"
            $allOk = $false
        } else {
            Write-WarnMsg "Could not read ExpressRoute service providers - continuing."
        }
    }
}

# --- AWS -------------------------------------------------------------------------
if ($targets -contains "aws") {
    Write-Step "AWS: read-only access"
    $awsProfile = Get-EnvValue -DotEnv $dotEnv -Key "AWS_PROFILE"
    $profileArgs = @()
    if ($awsProfile) { $profileArgs = @("--profile", $awsProfile) }
    $identityRaw = (& aws sts get-caller-identity @profileArgs --output json 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $line = ($identityRaw | Where-Object { "$_".Trim() -ne "" } | Select-Object -First 1)
        Write-ErrMsg "aws sts get-caller-identity failed: $line"
        $allOk = $false
    } else {
        $identity = ((@($identityRaw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n") | ConvertFrom-Json)
        Write-Ok "Caller: $($identity.Arn)"
        $account = $identity.Account
        # With AWS_ASSUME_ROLE_ARN, Terraform builds EKS as that role, and only
        # that role gets an EKS access entry, so the kubeconfig assumes it too.
        # Prove the role can be assumed. Only the ARN is queried, so no
        # credentials are ever printed.
        $roleArn = Get-EnvValue -DotEnv $dotEnv -Key "AWS_ASSUME_ROLE_ARN"
        if ($roleArn) {
            $assumed = @(& aws sts assume-role --role-arn $roleArn --role-session-name "eqarc-preflight" @profileArgs --query "AssumedRoleUser.Arn" --output text 2>&1)
            if ($LASTEXITCODE -ne 0) {
                Write-ErrMsg "Cannot assume AWS_ASSUME_ROLE_ARN ($roleArn): $(($assumed | Where-Object { "$_".Trim() -ne '' } | Select-Object -First 1))"
                $allOk = $false
            } else {
                Write-Ok "Can assume $roleArn (as $(($assumed | Select-Object -First 1)))"
                $account = $roleArn.Split(":")[4]
            }
        }
        $expectedAccount = Get-EnvValue -DotEnv $dotEnv -Key "AWS_EXPECTED_ACCOUNT_ID"
        if ($expectedAccount -and $account -ne $expectedAccount) {
            Write-ErrMsg "Terraform would deploy to AWS account $account, but AWS_EXPECTED_ACCOUNT_ID is $expectedAccount."
            $allOk = $false
        } elseif ($expectedAccount) { Write-Ok "Target AWS account $account matches AWS_EXPECTED_ACCOUNT_ID" }
        & aws ec2 describe-regions @profileArgs --query "Regions[].RegionName" --output json 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "ec2:DescribeRegions OK" } else { Write-WarnMsg "ec2:DescribeRegions denied" }
        & aws eks list-clusters @profileArgs --output json 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "eks:ListClusters OK" } else { Write-WarnMsg "eks:ListClusters denied" }
    }
}

# --- Equinix Fabric ----------------------------------------------------------------
if ($er) {
    Write-Step "Equinix Fabric: API access + configured assets"
    if (-not (Test-EquinixCredentialsPresent)) {
        Write-ErrMsg "Equinix API credentials are not set in this shell - see scripts/00-bootstrap-auth.ps1."
        $allOk = $false
    } else {
        try {
            $token = Get-EquinixToken
            $origin = Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_FABRIC_ORIGIN" -Default "port"
            Write-Ok "Token OK. Origin asset type: $origin"
            if ($origin -eq "port") {
                foreach ($key in @("EQUINIX_PRIMARY_PORT_UUID", "EQUINIX_SECONDARY_PORT_UUID")) {
                    $uuid = Get-EnvValue -DotEnv $dotEnv -Key $key
                    if (-not $uuid) {
                        if ($key -eq "EQUINIX_SECONDARY_PORT_UUID" -and -not (Get-EnvBool -DotEnv $dotEnv -Key "EQUINIX_REDUNDANT" -Default $true)) { continue }
                        Write-ErrMsg "$key is empty in .env"; $allOk = $false; continue
                    }
                    $port = Invoke-EquinixApi -Path "/fabric/v4/ports/$uuid" -Token $token
                    Write-Ok "$key -> $(Get-Prop $port 'name') [$(Get-Prop $port 'state')] metro=$(Get-Prop $port 'location.metroCode') encapsulation=$(Get-Prop $port 'encapsulation.type')"
                }
            } elseif ($origin -eq "cloud_router" -and -not (Get-EnvBool -DotEnv $dotEnv -Key "EQUINIX_CREATE_CLOUD_ROUTER" -Default $false)) {
                $fcrUuid = Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_CLOUD_ROUTER_UUID"
                if (-not $fcrUuid) { Write-ErrMsg "EQUINIX_CLOUD_ROUTER_UUID is empty"; $allOk = $false }
                else {
                    $fcr = Invoke-EquinixApi -Path "/fabric/v4/routers/$fcrUuid" -Token $token
                    Write-Ok "Cloud Router $(Get-Prop $fcr 'name') [$(Get-Prop $fcr 'state')] ASN $(Get-Prop $fcr 'equinixAsn')"
                }
            }
            $serviceProfile = Invoke-EquinixApi -Path "/fabric/v4/serviceProfiles/a1390b22-bbe0-4e93-ad37-85beef9d254d" -Token $token
            Write-Ok "Azure ExpressRoute service profile visible: $(Get-Prop $serviceProfile 'name')"
            if (-not (Get-EnvValue -DotEnv $dotEnv -Key "EQUINIX_NOTIFICATION_EMAILS")) {
                Write-ErrMsg "EQUINIX_NOTIFICATION_EMAILS is empty (required by Equinix)."
                $allOk = $false
            }
        } catch {
            Write-ErrMsg "Equinix API check failed: $($_.Exception.Message)"
            $allOk = $false
        }
    }
}

# --- Equinix cluster -----------------------------------------------------------------
if ($targets -contains "equinix") {
    Write-Step "Equinix cluster: admin access via context '$($naming.EquinixContext)'"
    if (-not (Test-KubeContext -Name $naming.EquinixContext)) {
        Write-ErrMsg "kube context '$($naming.EquinixContext)' not found (docs/EQUINIX-CLUSTER.md)."
        $allOk = $false
    } else {
        $canI = kubectl auth can-i "*" "*" --all-namespaces --context $naming.EquinixContext --request-timeout=15s 2>$null
        if ($canI -eq "yes") { Write-Ok "cluster-admin confirmed (required by az connectedk8s connect)" } else { Write-ErrMsg "cluster-admin NOT confirmed ($canI)"; $allOk = $false }
        $notReady = @(kubectl get nodes --context $naming.EquinixContext -o json 2>$null | ConvertFrom-Json | ForEach-Object { $_.items } |
                Where-Object { -not (@($_.status.conditions) | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }) })
        if ($notReady.Count -eq 0) { Write-Ok "All nodes Ready" } else { Write-ErrMsg "$($notReady.Count) node(s) not Ready"; $allOk = $false }
    }
}

Write-Step "Summary"
if ($allOk) {
    Write-Ok "Preflight passed for: $($targets -join ', ')$(if ($er) { ' (+ ExpressRoute path)' })"
    exit 0
}
Write-ErrMsg "Preflight found blockers - fix them before scripts/03-init-plan.ps1."
exit 1

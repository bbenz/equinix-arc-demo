# scripts/lib/common.ps1
#
# Shared helpers dot-sourced by every scripts/NN-*.ps1 step. Not meant to be
# run directly:
#   . (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+ (Windows/Linux/macOS):
# no ternaries/null-coalescing, Join-Path everywhere (never hardcoded "\").

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# Native tools report failure through $LASTEXITCODE, which the scripts check
# explicitly. Keep PowerShell 7.3+ from also turning non-zero exits into
# errors, so behavior matches Windows PowerShell 5.1.
$PSNativeCommandUseErrorActionPreference = $false

# Windows PowerShell 5.1 turns *redirected* native stderr (2>$null, 2>&1) into
# a terminating error under "Stop". For example, `az ... show 2>$null` for a
# resource that doesn't exist yet would abort the script instead of returning
# nothing. PowerShell 7 doesn't do this. On 5.1 only, these shims run the real
# executables with "Continue" in their own scope, so redirection behaves the
# same in both versions. Exit codes still flow through $LASTEXITCODE.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    $script:NativeShimTargets = @{}
    foreach ($tool in @("az", "kubectl", "terraform", "aws", "kubelogin", "helm", "tflint", "git", "python", "python3", "taskkill")) {
        $app = Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $app) { continue }
        $script:NativeShimTargets[$tool] = $app.Source
        Set-Item -Path "function:script:$tool" -Value {
            $ErrorActionPreference = "Continue"
            $exe = $script:NativeShimTargets[$MyInvocation.MyCommand.Name]
            if ($MyInvocation.ExpectingInput) { $input | & $exe @args } else { & $exe @args }
        }
    }
}

$script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.FullName
$script:ArtifactsDir = Join-Path $RepoRoot "artifacts"
$script:TerraformDir = Join-Path $RepoRoot "terraform"
$script:KubernetesDir = Join-Path $RepoRoot "kubernetes"

function Get-RepoRoot { return $script:RepoRoot }
function Get-TerraformDir { return $script:TerraformDir }
function Get-KubernetesDir { return $script:KubernetesDir }
function Get-ArtifactsDir {
    if (-not (Test-Path $script:ArtifactsDir)) {
        New-Item -ItemType Directory -Path $script:ArtifactsDir -Force | Out-Null
    }
    return $script:ArtifactsDir
}
function Join-RepoPath {
    # Join-RepoPath "terraform" "environments" "demo" -> separator-agnostic path
    $path = $script:RepoRoot
    foreach ($segment in $args) { $path = Join-Path $path $segment }
    return $path
}

# --- Console output ------------------------------------------------------------
function Write-Step { param([Parameter(Mandatory)][string]$Message) Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([Parameter(Mandatory)][string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-WarnMsg { param([Parameter(Mandatory)][string]$Message) Write-Host "  [WARN] $Message" -ForegroundColor Yellow }
function Write-ErrMsg { param([Parameter(Mandatory)][string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }
function Write-Info { param([Parameter(Mandatory)][string]$Message) Write-Host "  - $Message" -ForegroundColor Gray }

# --- .env loading ------------------------------------------------------------
# Parses KEY=VALUE lines from .env (falls back to .env.example so scripts stay
# informative before setup). Returns a hashtable; never mutates $env:, never
# prints values. Secrets (Equinix API credentials, ER service key) are NOT
# read from .env at all - see docs/AUTHENTICATION-AND-PERMISSIONS.md.
function Get-DotEnv {
    $envPath = Join-Path $script:RepoRoot ".env"
    $usedExample = $false
    if (-not (Test-Path $envPath)) {
        $envPath = Join-Path $script:RepoRoot ".env.example"
        $usedExample = $true
    }
    $result = @{}
    if (Test-Path $envPath) {
        foreach ($line in Get-Content $envPath) {
            $trimmed = $line.Trim()
            if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
            $idx = $trimmed.IndexOf("=")
            if ($idx -lt 1) { continue }
            $key = $trimmed.Substring(0, $idx).Trim()
            $value = $trimmed.Substring($idx + 1).Trim()
            # Allow trailing "  # comment" after unquoted values ("KEY=  # note" = empty).
            if ($value.StartsWith("#")) { $value = "" }
            if (-not ($value.StartsWith('"') -or $value.StartsWith("'"))) {
                $hash = $value.IndexOf(" #")
                if ($hash -ge 0) { $value = $value.Substring(0, $hash).Trim() }
            }
            if ($value.Length -ge 2 -and (
                    ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                    ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $result[$key] = $value
        }
    }
    if ($usedExample) {
        Write-WarnMsg ".env not found - using .env.example defaults. Copy .env.example to .env and fill it in for a real run."
    }
    return $result
}

function Get-EnvValue {
    param([Parameter(Mandatory)][hashtable]$DotEnv, [Parameter(Mandatory)][string]$Key, [string]$Default = "")
    if ($DotEnv.ContainsKey($Key) -and $DotEnv[$Key] -ne "") { return $DotEnv[$Key] }
    return $Default
}

function Get-EnvBool {
    param([Parameter(Mandatory)][hashtable]$DotEnv, [Parameter(Mandatory)][string]$Key, [bool]$Default = $true)
    $raw = Get-EnvValue -DotEnv $DotEnv -Key $Key -Default ($Default.ToString())
    return $raw.Trim().ToLowerInvariant() -eq "true"
}

function Get-EnvInt {
    param([Parameter(Mandatory)][hashtable]$DotEnv, [Parameter(Mandatory)][string]$Key, [int]$Default = 0)
    $raw = Get-EnvValue -DotEnv $DotEnv -Key $Key -Default ($Default.ToString())
    $parsed = 0
    if ([int]::TryParse($raw.Trim(), [ref]$parsed)) { return $parsed }
    throw ".env value for $Key ('$raw') is not an integer."
}

function Split-List {
    # "a, b,,c" -> "a","b","c". Callers wrap with @() to always get an array:
    #   $list = @(Split-List $value)
    param([string]$Value)
    if (-not $Value) { return }
    return ($Value.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

# --- Targets -----------------------------------------------------------------
# Single source of truth for "which footprints are in scope" across 00-99.
function Get-EnabledTargets {
    param([Parameter(Mandatory)][hashtable]$DotEnv)
    $targets = @()
    if (Get-EnvBool -DotEnv $DotEnv -Key "ENABLE_AZURE" -Default $true) { $targets += "azure" }
    if (Get-EnvBool -DotEnv $DotEnv -Key "ENABLE_AWS" -Default $true) { $targets += "aws" }
    if (Get-EnvBool -DotEnv $DotEnv -Key "ENABLE_EQUINIX" -Default $true) { $targets += "equinix" }
    return $targets
}

# ExpressRoute path = Equinix member + Azure + ENABLE_EXPRESSROUTE. When false
# with ENABLE_EQUINIX=true you are in "rehearsal mode": the Equinix-labeled
# cluster joins over the public internet and no circuit is created.
function Test-ExpressRouteEnabled {
    param([Parameter(Mandatory)][hashtable]$DotEnv)
    $targets = Get-EnabledTargets -DotEnv $DotEnv
    return (($targets -contains "azure") -and ($targets -contains "equinix") -and
        (Get-EnvBool -DotEnv $DotEnv -Key "ENABLE_EXPRESSROUTE" -Default $true))
}

function Get-Naming {
    param([Parameter(Mandatory)][hashtable]$DotEnv)
    $prefix = Get-EnvValue -DotEnv $DotEnv -Key "NAME_PREFIX" -Default "eqarc"
    $environment = Get-EnvValue -DotEnv $DotEnv -Key "ENVIRONMENT" -Default "demo"
    $base = "$prefix-$environment"
    return [ordered]@{
        Prefix         = $prefix
        Environment    = $environment
        Base           = $base
        ArcGateway     = "$base-arcgw"
        EquinixMember  = "equinix-demo"
        EksMember      = "eks-demo"
        AksMember      = "aks-demo"
        DemoLabel      = "equinix-arc-online-boutique"
        HubContext     = "fleet-hub-demo"
        AksContext     = "aks-demo"
        EksContext     = "eks-demo"
        EquinixContext = (Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_KUBE_CONTEXT" -Default "equinix-demo")
    }
}

# --- Tool / command helpers ----------------------------------------------------
function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Checked {
    # Runs a native command; throws with context on non-zero exit.
    param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][string[]]$Arguments, [string]$ErrorContext = "")
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        $context = ""
        if ($ErrorContext) { $context = " ($ErrorContext)" }
        throw "Command failed with exit code $LASTEXITCODE${context}: $Command $($Arguments -join ' ')"
    }
}

function Invoke-AzJson {
    # Runs `az <args> -o json` quietly; returns parsed JSON or $null on failure.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $raw = & az @Arguments -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { return (($raw -join "`n") | ConvertFrom-Json) } catch { return $null }
}

function Get-AzResourceOrNull {
    # Like Invoke-AzJson, but tells "doesn't exist" ($null) apart from every
    # other failure (throws: auth, network, throttling, wrong subscription,
    # missing CLI extension). Use it wherever guessing would be unsafe, such
    # as teardown or deciding whether ExpressRoute peering should exist.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = @(& az @Arguments -o json 2>&1)
    $code = $LASTEXITCODE
    $stdout = @($result | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    if ($code -ne 0) {
        $text = (@($result | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_".Trim() }) -join " ")
        # An unregistered resource provider also means no resource of that type can exist.
        if ($text -notmatch "SubscriptionNotFound" -and
            $text -match "ResourceNotFound|ResourceGroupNotFound|ParentResourceNotFound|\(NotFound\)|Code: NotFound|could not be found|was not found|MissingSubscriptionRegistration|NoRegisteredProviderFound") {
            return $null
        }
        throw "az $($Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' ') failed (exit $code): $text"
    }
    if (-not ($stdout -join "").Trim()) { return $null }
    return (($stdout -join "`n") | ConvertFrom-Json)
}

# Resource group of the Arc-connected clusters and the Arc gateway:
# ARC_RESOURCE_GROUP, or by default the Terraform-managed demo resource group.
function Get-ArcResourceGroup {
    param([Parameter(Mandatory)][hashtable]$DotEnv, $AzureOutputs)
    return (Get-EnvValue -DotEnv $DotEnv -Key "ARC_RESOURCE_GROUP" -Default ([string](Get-TfOutputValue -Outputs $AzureOutputs -Name "arc_resource_group")))
}

# Replaces every {{TOKEN}} key of $Tokens in a template and writes the result.
function Expand-TemplateFile {
    param([Parameter(Mandatory)][string]$TemplatePath, [Parameter(Mandatory)][hashtable]$Tokens, [Parameter(Mandatory)][string]$OutPath)
    $text = Get-Content -Raw -Path $TemplatePath
    foreach ($key in $Tokens.Keys) { $text = $text.Replace($key, [string]$Tokens[$key]) }
    $left = [regex]::Matches($text, "\{\{[A-Z0-9_]+\}\}") | ForEach-Object { $_.Value } | Sort-Object -Unique
    if ($left) { throw "Template $TemplatePath has unreplaced tokens: $($left -join ', ')" }
    Set-Content -Path $OutPath -Value $text -Encoding utf8
}

function Get-Prop {
    # Null-safe nested property access under StrictMode: Get-Prop $obj "a.b.c"
    param($Object, [Parameter(Mandatory)][string]$Path)
    $current = $Object
    foreach ($segment in $Path.Split(".")) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if ($current.Contains($segment)) { $current = $current[$segment] } else { return $null }
        } else {
            $prop = $current.PSObject.Properties[$segment]
            if ($null -eq $prop) { return $null }
            $current = $prop.Value
        }
    }
    return $current
}

function Test-KubeContext {
    param([Parameter(Mandatory)][string]$Name)
    $contexts = @(kubectl config get-contexts -o name 2>$null)
    return ($contexts -contains $Name)
}

# --- Confirmation guard for billable / destructive actions --------------------
function Confirm-BillableAction {
    param([Parameter(Mandatory)][string]$ActionDescription, [Parameter(Mandatory)][bool]$AutoApprove, [string]$ConfirmationWord = "yes")
    if ($AutoApprove) {
        Write-WarnMsg "-AutoApprove supplied - skipping interactive confirmation for: $ActionDescription"
        return $true
    }
    Write-Host ""
    Write-Host $ActionDescription -ForegroundColor Yellow
    $response = Read-Host "Type '$ConfirmationWord' to proceed, anything else to abort"
    return $response -eq $ConfirmationWord
}

# --- Region selection artifact (written by 02, read by 03+) --------------------
function Get-RegionSelectionPath { return (Join-Path (Get-ArtifactsDir) "region-selection.json") }
function Read-RegionSelection {
    $path = Get-RegionSelectionPath
    if (-not (Test-Path $path)) { return $null }
    return (Get-Content $path -Raw | ConvertFrom-Json)
}

# --- Terraform helpers -----------------------------------------------------------
function Get-TfRootDir {
    param([Parameter(Mandatory)][ValidateSet("azure", "aws", "equinix", "environments/demo")][string]$Root)
    $path = $script:TerraformDir
    foreach ($segment in $Root.Split("/")) { $path = Join-Path $path $segment }
    return $path
}

# Terraform reads a root's state (local OR remote backend) only after the root
# is initialized. Local-state roots are readable as they are. A root that
# declares a remote backend (see terraform/bootstrap) is initialized on demand,
# for example on a teammate's fresh clone, so state checks never silently see
# "nothing deployed".
function Test-TfRootReadable {
    param([Parameter(Mandatory)][string]$RootDir)
    if ((Test-Path (Join-Path $RootDir ".terraform")) -or (Test-Path (Join-Path $RootDir "terraform.tfstate"))) { return $true }
    $remoteBackend = @(Get-ChildItem -Path $RootDir -Filter "*.tf" -File | Select-String -Pattern '^\s*backend\s+"').Count -gt 0
    if (-not $remoteBackend) { return $false }
    Push-Location $RootDir
    try {
        terraform init -input=false 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "terraform init failed in $RootDir, so its remote state can't be read. Run 'terraform init' there and fix the error." }
        return $true
    } finally { Pop-Location }
}

# Backend-agnostic "does this root manage anything?" (asks Terraform; works the
# same for local and remote state).
function Test-TfStateExists {
    param([Parameter(Mandatory)][string]$RootDir)
    if (-not (Test-TfRootReadable -RootDir $RootDir)) { return $false }
    Push-Location $RootDir
    try {
        $list = @(terraform state list 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $text = ($list | ForEach-Object { "$_" }) -join " "
            if ($text -match "No state file was found") { return $false }
            throw "Could not read the Terraform state in $RootDir (try 'terraform init' there): $text"
        }
        return (@($list | Where-Object { "$_".Trim() -ne "" }).Count -gt 0)
    } finally { Pop-Location }
}

# Returns all outputs of a root as a PSObject, or $null when nothing is deployed.
# Throws if Terraform can't read the state, so "unreadable" is never mistaken
# for "not deployed". Sensitive values are included in memory only: callers
# must never print the result wholesale.
function Get-TfOutputs {
    param([Parameter(Mandatory)][string]$RootDir)
    if (-not (Test-TfRootReadable -RootDir $RootDir)) { return $null }
    Push-Location $RootDir
    try {
        $raw = @(terraform output -json 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "Could not read the Terraform outputs in $RootDir (try 'terraform init' there)." }
        $outputs = (($raw -join "`n") | ConvertFrom-Json)
        if ($null -eq $outputs -or @($outputs.PSObject.Properties).Count -eq 0) { return $null }
        return $outputs
    } finally { Pop-Location }
}

function Get-TfOutputValue {
    param($Outputs, [Parameter(Mandatory)][string]$Name)
    return (Get-Prop -Object (Get-Prop -Object $Outputs -Path $Name) -Path "value")
}

# azurerm 4+ no longer falls back to the az CLI's active subscription: it needs
# subscription_id or ARM_SUBSCRIPTION_ID. For roots that use azurerm, the helpers
# below pass the CLI's subscription in ARM_SUBSCRIPTION_ID for the duration of
# each plan/apply/destroy only, so Terraform and the az commands around it
# always target the same subscription.
function Get-ArmSubscriptionForTerraform {
    $current = az account show --query id -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $current) { throw "The Azure CLI isn't logged in (az account show failed). Run scripts/00-bootstrap-auth.ps1." }
    if ($env:ARM_SUBSCRIPTION_ID -and $env:ARM_SUBSCRIPTION_ID -ne $current) {
        throw "ARM_SUBSCRIPTION_ID ($($env:ARM_SUBSCRIPTION_ID)) differs from the Azure CLI subscription ($current). Unset it or run 'az account set', so Terraform and the az commands target the same subscription."
    }
    return $current
}

function Invoke-TerraformCommand {
    # Runs terraform in $RootDir and throws on failure. Sets ARM_SUBSCRIPTION_ID
    # for this call only when the root uses azurerm.
    param([Parameter(Mandatory)][string]$RootDir, [Parameter(Mandatory)][string[]]$Arguments, [string]$ErrorContext = "")
    $usesAzurerm = @(Get-ChildItem -Path $RootDir -Filter "*.tf" -File | Select-String -Pattern '^\s*provider\s+"azurerm"').Count -gt 0
    $previous = $env:ARM_SUBSCRIPTION_ID
    Push-Location $RootDir
    try {
        if ($usesAzurerm) { $env:ARM_SUBSCRIPTION_ID = Get-ArmSubscriptionForTerraform }
        Invoke-Checked -Command "terraform" -Arguments $Arguments -ErrorContext $ErrorContext
    } finally {
        if ($usesAzurerm) {
            if ($previous) { $env:ARM_SUBSCRIPTION_ID = $previous } else { Remove-Item Env:ARM_SUBSCRIPTION_ID -ErrorAction SilentlyContinue }
        }
        Pop-Location
    }
}

function Invoke-TerraformPlan {
    # init + validate + plan -out tfplan. Extra -var arguments are optional.
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$RootDir, [string[]]$ExtraArgs = @())
    Write-Step "terraform init/validate/plan: $Label"
    Push-Location $RootDir
    try {
        terraform fmt | Out-Null
        Invoke-Checked -Command "terraform" -Arguments @("init", "-input=false") -ErrorContext "$Label init"
        Invoke-Checked -Command "terraform" -Arguments @("validate") -ErrorContext "$Label validate"
    } finally { Pop-Location }
    Invoke-TerraformCommand -RootDir $RootDir -Arguments (@("plan", "-input=false", "-out=tfplan") + $ExtraArgs) -ErrorContext "$Label plan"
    Write-Ok "$Label : plan saved to $(Join-Path $RootDir 'tfplan')"
}

function Invoke-TerraformApplyPlan {
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$RootDir)
    $planPath = Join-Path $RootDir "tfplan"
    if (-not (Test-Path $planPath)) { throw "$Label : no saved plan at $planPath - run the plan step first." }
    Write-Step "terraform apply: $Label"
    Invoke-TerraformCommand -RootDir $RootDir -Arguments @("apply", "-input=false", "tfplan") -ErrorContext "$Label apply"
    Remove-Item $planPath -Force -ErrorAction SilentlyContinue
    Write-Ok "$Label : apply complete"
}

# --- tfvars generation -----------------------------------------------------------
function ConvertTo-HclValue {
    param($Value)
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return "$Value" }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @($Value | ForEach-Object { ConvertTo-HclValue $_ })
        return "[" + ($items -join ", ") + "]"
    }
    $escaped = ([string]$Value).Replace('\', '\\').Replace('"', '\"')
    return "`"$escaped`""
}

function Write-TfVarsFile {
    # Null and empty-string values are skipped (Terraform default applies);
    # lists are always written (an explicit [] is meaningful).
    param([Parameter(Mandatory)][string]$RootDir, [Parameter(Mandatory)]$Vars)
    $content = @(
        "# Auto-generated by scripts/lib/common.ps1 from .env (+ region selection / live state)."
        "# Gitignored and regenerated on every run - edit .env, not this file. No secrets here."
        ""
    )
    foreach ($key in $Vars.Keys) {
        $value = $Vars[$key]
        if ($null -eq $value) { continue }
        if ($value -is [string] -and $value -eq "") { continue }
        $content += "$key = $(ConvertTo-HclValue $value)"
    }
    $path = Join-Path $RootDir "terraform.tfvars"
    Set-Content -Path $path -Value $content -Encoding utf8
    Write-Ok "Wrote $path"
}

# Live state of the ExpressRoute circuit. Returns $null only when the circuit is
# confirmed absent (not in terraform/azure state, or Azure reports it missing).
# Any other query failure THROWS. Treating a transient CLI or auth error as
# "no circuit" would make Write-AzureTfVars plan the removal of working peering.
function Get-ExpressRouteCircuitState {
    param([Parameter(Mandatory)][hashtable]$DotEnv)
    $outputs = Get-TfOutputs -RootDir (Get-TfRootDir "azure")
    $rg = Get-TfOutputValue -Outputs $outputs -Name "resource_group_name"
    $name = Get-TfOutputValue -Outputs $outputs -Name "expressroute_circuit_name"
    if (-not $rg -or -not $name) { return $null }
    $circuit = Get-AzResourceOrNull -Arguments @("network", "express-route", "show", "--resource-group", $rg, "--name", $name)
    if (-not $circuit) { return $null }
    return [ordered]@{
        ResourceGroup                    = $rg
        Name                             = $name
        ServiceProviderProvisioningState = (Get-Prop $circuit "serviceProviderProvisioningState")
        CircuitProvisioningState         = (Get-Prop $circuit "circuitProvisioningState")
        PeeringLocation                  = (Get-Prop $circuit "serviceProviderProperties.peeringLocation")
        BandwidthMbps                    = (Get-Prop $circuit "serviceProviderProperties.bandwidthInMbps")
    }
}

# Peer ASN for Azure private peering: the FCR's Equinix ASN when the Equinix
# root used a Fabric Cloud Router, else the edge router ASN from .env.
function Get-AzurePeeringPeerAsn {
    param([Parameter(Mandatory)][hashtable]$DotEnv)
    $fromEquinix = Get-TfOutputValue -Outputs (Get-TfOutputs -RootDir (Get-TfRootDir "equinix")) -Name "azure_peering_peer_asn"
    if ($fromEquinix) { return [int]$fromEquinix }
    return (Get-EnvInt -DotEnv $DotEnv -Key "EQUINIX_EDGE_ASN" -Default 65080)
}

function Write-AzureTfVars {
    param([Parameter(Mandatory)][hashtable]$DotEnv, [switch]$ForcePeeringOff)
    $selection = Read-RegionSelection
    $region = $null
    if ($selection -and (Get-Prop $selection "azure.selected")) { $region = $selection.azure.selected }

    $er = Test-ExpressRouteEnabled -DotEnv $DotEnv
    $peering = $false
    if ($er -and -not $ForcePeeringOff) {
        # Private peering can only exist once Equinix has provisioned the
        # circuit; deriving the flag from live state keeps re-runs idempotent.
        # If Azure can't be queried this throws: the flag must never fall
        # back to "off", because that would plan the removal of working peering.
        $state = Get-ExpressRouteCircuitState -DotEnv $DotEnv
        if ($state -and $state.ServiceProviderProvisioningState -eq "Provisioned") { $peering = $true }
    }

    $onprem = @(Split-List (Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_ONPREM_PREFIXES" -Default "10.80.0.0/24"))
    $vars = [ordered]@{
        name_prefix                          = (Get-Naming $DotEnv).Prefix
        environment                          = (Get-Naming $DotEnv).Environment
        project                              = Get-EnvValue -DotEnv $DotEnv -Key "PROJECT" -Default "equinix-arc-demo"
        owner                                = Get-EnvValue -DotEnv $DotEnv -Key "OWNER"
        expiration_date                      = Get-EnvValue -DotEnv $DotEnv -Key "EXPIRATION_DATE"
        location                             = $region
        expected_tenant_id                   = Get-EnvValue -DotEnv $DotEnv -Key "AZURE_EXPECTED_TENANT_ID"
        expected_subscription_id             = Get-EnvValue -DotEnv $DotEnv -Key "AZURE_EXPECTED_SUBSCRIPTION_ID"
        enable_expressroute                  = $er
        expressroute_peering_location        = Get-EnvValue -DotEnv $DotEnv -Key "ER_PEERING_LOCATION" -Default "Silicon Valley"
        expressroute_bandwidth_mbps          = Get-EnvInt -DotEnv $DotEnv -Key "ER_BANDWIDTH_MBPS" -Default 50
        expressroute_gateway_sku             = Get-EnvValue -DotEnv $DotEnv -Key "ER_GATEWAY_SKU" -Default "ErGwScale"
        expressroute_private_peering_enabled = $peering
        expressroute_peer_asn                = Get-AzurePeeringPeerAsn -DotEnv $DotEnv
        expressroute_primary_peer_prefix     = Get-EnvValue -DotEnv $DotEnv -Key "ER_PRIMARY_PEER_PREFIX" -Default "192.168.250.0/30"
        expressroute_secondary_peer_prefix   = Get-EnvValue -DotEnv $DotEnv -Key "ER_SECONDARY_PEER_PREFIX" -Default "192.168.250.4/30"
        expressroute_vlan_id                 = Get-EnvInt -DotEnv $DotEnv -Key "ER_VLAN_ID" -Default 200
        equinix_onprem_prefixes              = $onprem
        storefront_allowed_cidrs             = @(Split-List (Get-EnvValue -DotEnv $DotEnv -Key "STOREFRONT_ALLOWED_CIDRS"))
        equinix_storefront_upstreams         = @(Split-List (Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_STOREFRONT_UPSTREAMS"))
        proxy_extra_allowed_domains          = @(Split-List (Get-EnvValue -DotEnv $DotEnv -Key "PROXY_EXTRA_ALLOWED_DOMAINS"))
        aks_node_vm_size                     = Get-EnvValue -DotEnv $DotEnv -Key "AKS_NODE_VM_SIZE"
        enable_private_acr                   = Get-EnvBool -DotEnv $DotEnv -Key "ENABLE_PRIVATE_ACR" -Default $false
        enable_dns_private_resolver          = Get-EnvBool -DotEnv $DotEnv -Key "ENABLE_DNS_PRIVATE_RESOLVER" -Default $false
    }
    Write-TfVarsFile -RootDir (Get-TfRootDir "azure") -Vars $vars
    return $vars
}

function Write-AwsTfVars {
    param([Parameter(Mandatory)][hashtable]$DotEnv)
    $selection = Read-RegionSelection
    $region = $null
    if ($selection -and (Get-Prop $selection "aws.selected")) { $region = $selection.aws.selected }
    $vars = [ordered]@{
        name_prefix         = (Get-Naming $DotEnv).Prefix
        environment         = (Get-Naming $DotEnv).Environment
        project             = Get-EnvValue -DotEnv $DotEnv -Key "PROJECT" -Default "equinix-arc-demo"
        owner               = Get-EnvValue -DotEnv $DotEnv -Key "OWNER"
        expiration_date     = Get-EnvValue -DotEnv $DotEnv -Key "EXPIRATION_DATE"
        region              = $region
        aws_profile         = Get-EnvValue -DotEnv $DotEnv -Key "AWS_PROFILE"
        aws_assume_role_arn = Get-EnvValue -DotEnv $DotEnv -Key "AWS_ASSUME_ROLE_ARN"
        expected_account_id = Get-EnvValue -DotEnv $DotEnv -Key "AWS_EXPECTED_ACCOUNT_ID"
    }
    Write-TfVarsFile -RootDir (Get-TfRootDir "aws") -Vars $vars
    return $vars
}

function Write-EquinixTfVars {
    param([Parameter(Mandatory)][hashtable]$DotEnv, [int]$BandwidthMbps = 0, [bool]$ConfigureAzureRouting = $true)
    if ($BandwidthMbps -le 0) { $BandwidthMbps = Get-EnvInt -DotEnv $DotEnv -Key "ER_BANDWIDTH_MBPS" -Default 50 }
    $vars = [ordered]@{
        name_prefix                  = (Get-Naming $DotEnv).Prefix
        environment                  = (Get-Naming $DotEnv).Environment
        metro_code                   = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_METRO_CODE" -Default "SV"
        bandwidth_mbps               = $BandwidthMbps
        expressroute_vlan_c_tag      = Get-EnvInt -DotEnv $DotEnv -Key "ER_VLAN_ID" -Default 200
        configure_azure_routing      = $ConfigureAzureRouting
        fabric_origin                = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_FABRIC_ORIGIN" -Default "port"
        redundant                    = Get-EnvBool -DotEnv $DotEnv -Key "EQUINIX_REDUNDANT" -Default $true
        notification_emails          = @(Split-List (Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_NOTIFICATION_EMAILS"))
        project_id                   = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_PROJECT_ID"
        purchase_order_number        = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_PURCHASE_ORDER"
        primary_port_uuid            = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_PRIMARY_PORT_UUID"
        secondary_port_uuid          = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_SECONDARY_PORT_UUID"
        port_link_protocol           = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_PORT_LINK_PROTOCOL" -Default "DOT1Q"
        primary_vlan_tag             = Get-EnvInt -DotEnv $DotEnv -Key "EQUINIX_PRIMARY_VLAN_TAG" -Default 1010
        secondary_vlan_tag           = Get-EnvInt -DotEnv $DotEnv -Key "EQUINIX_SECONDARY_VLAN_TAG" -Default 1020
        edge_asn                     = Get-EnvInt -DotEnv $DotEnv -Key "EQUINIX_EDGE_ASN" -Default 65080
        create_cloud_router          = Get-EnvBool -DotEnv $DotEnv -Key "EQUINIX_CREATE_CLOUD_ROUTER" -Default $false
        cloud_router_uuid            = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_CLOUD_ROUTER_UUID"
        account_number               = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_ACCOUNT_NUMBER"
        expressroute_primary_peer_prefix   = Get-EnvValue -DotEnv $DotEnv -Key "ER_PRIMARY_PEER_PREFIX" -Default "192.168.250.0/30"
        expressroute_secondary_peer_prefix = Get-EnvValue -DotEnv $DotEnv -Key "ER_SECONDARY_PEER_PREFIX" -Default "192.168.250.4/30"
        fcr_customer_port_uuid       = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_FCR_CUSTOMER_PORT_UUID"
        fcr_customer_vlan_tag        = Get-EnvInt -DotEnv $DotEnv -Key "EQUINIX_FCR_CUSTOMER_VLAN_TAG" -Default 1030
        fcr_customer_peer_prefix     = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_FCR_CUSTOMER_PEER_PREFIX" -Default "192.168.251.0/30"
        fcr_customer_asn             = Get-EnvInt -DotEnv $DotEnv -Key "EQUINIX_EDGE_ASN" -Default 65080
        primary_service_token_uuid   = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_PRIMARY_SERVICE_TOKEN"
        secondary_service_token_uuid = Get-EnvValue -DotEnv $DotEnv -Key "EQUINIX_SECONDARY_SERVICE_TOKEN"
    }
    Write-TfVarsFile -RootDir (Get-TfRootDir "equinix") -Vars $vars
    return $vars
}

# --- Equinix API ---------------------------------------------------------------
function Test-EquinixCredentialsPresent {
    return ([bool]$env:EQUINIX_API_TOKEN) -or ([bool]$env:EQUINIX_API_CLIENTID -and [bool]$env:EQUINIX_API_CLIENTSECRET)
}

# Returns a bearer token (never printed). Uses EQUINIX_API_TOKEN if set,
# otherwise the OAuth2 client-credentials flow with EQUINIX_API_CLIENTID/SECRET.
function Get-EquinixToken {
    if ($env:EQUINIX_API_TOKEN) { return $env:EQUINIX_API_TOKEN }
    if (-not ($env:EQUINIX_API_CLIENTID -and $env:EQUINIX_API_CLIENTSECRET)) {
        throw "Equinix API credentials not found. Set EQUINIX_API_CLIENTID and EQUINIX_API_CLIENTSECRET (or EQUINIX_API_TOKEN) in your shell - see docs/AUTHENTICATION-AND-PERMISSIONS.md."
    }
    $endpoint = "https://api.equinix.com"
    if ($env:EQUINIX_API_ENDPOINT) { $endpoint = $env:EQUINIX_API_ENDPOINT.TrimEnd("/") }
    $body = @{ grant_type = "client_credentials"; client_id = $env:EQUINIX_API_CLIENTID; client_secret = $env:EQUINIX_API_CLIENTSECRET } | ConvertTo-Json
    $response = Invoke-RestMethod -Method Post -Uri "$endpoint/oauth2/v1/token" -ContentType "application/json" -Body $body
    return $response.access_token
}

function Invoke-EquinixApi {
    param([Parameter(Mandatory)][string]$Path, [string]$Method = "Get", $Body = $null, [string]$Token = "")
    if (-not $Token) { $Token = Get-EquinixToken }
    $endpoint = "https://api.equinix.com"
    if ($env:EQUINIX_API_ENDPOINT) { $endpoint = $env:EQUINIX_API_ENDPOINT.TrimEnd("/") }
    $params = @{ Method = $Method; Uri = "$endpoint$Path"; Headers = @{ Authorization = "Bearer $Token" }; ContentType = "application/json" }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 20) }
    return (Invoke-RestMethod @params)
}

# Equinix-side status of a Fabric connection: equinixStatus/providerStatus.
function Get-EquinixConnectionStatus {
    param([Parameter(Mandatory)][string]$Uuid, [string]$Token = "")
    $c = Invoke-EquinixApi -Path "/fabric/v4/connections/$Uuid" -Token $Token
    return [ordered]@{
        Name           = (Get-Prop $c "name")
        EquinixStatus  = (Get-Prop $c "operation.equinixStatus")
        ProviderStatus = (Get-Prop $c "operation.providerStatus")
        State          = (Get-Prop $c "state")
    }
}

#Requires -Version 5.1
<#
.SYNOPSIS
    terraform fmt -check + validate for every root, a kustomize build of the
    base, YAML parsing of all manifests, a PowerShell parse check of every
    script, and bash -n for the Equinix-side shell scripts plus the rendered
    egress-proxy template. tflint runs too if installed (optional).
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot "common.ps1")

$failures = @()
$env:CHECKPOINT_DISABLE = "1"

# --- Terraform -------------------------------------------------------------------
$roots = @("azure", "aws", "equinix", "environments/demo", "bootstrap/azure", "bootstrap/aws")
foreach ($root in $roots) {
    $dir = Get-TerraformDir
    foreach ($segment in $root.Split("/")) { $dir = Join-Path $dir $segment }
    if (-not (Test-Path $dir)) { continue }
    Write-Step "terraform: $root"
    Push-Location $dir
    try {
        terraform fmt -check -diff | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-ErrMsg "$root : fmt (run 'terraform fmt')"; $failures += "$root fmt" } else { Write-Ok "$root : fmt" }
        if (-not (Test-Path ".terraform")) { terraform init -backend=false -input=false 2>&1 | Out-Null }
        terraform validate -no-color | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-ErrMsg "$root : validate"; $failures += "$root validate" } else { Write-Ok "$root : validate" }
        if (Test-CommandExists "tflint") {
            tflint 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-WarnMsg "$root : tflint findings" } else { Write-Ok "$root : tflint" }
        }
    } finally { Pop-Location }
}

# --- Kubernetes ----------------------------------------------------------------------
Write-Step "kubernetes: kustomize build + manifest parse"
kubectl kustomize (Join-Path (Get-KubernetesDir) "base") 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-ErrMsg "kustomize build failed"; $failures += "kustomize" } else { Write-Ok "kustomize build (base)" }
# Parse with PyYAML (offline; `kubectl --dry-run=client` needs a live API server for CRD kinds).
$python = $null
foreach ($candidate in @("python", "python3")) { if (Test-CommandExists $candidate) { $python = $candidate; break } }
if ($python) {
    $parse = @'
import glob, sys, yaml
bad = 0
for f in glob.glob(sys.argv[1] + "/**/*.yaml", recursive=True):
    try:
        list(yaml.safe_load_all(open(f, encoding="utf-8")))
    except Exception as e:
        print(f"{f}: {e}"); bad += 1
sys.exit(bad)
'@
    $result = $parse | & $python - (Get-KubernetesDir) 2>&1
    if ($LASTEXITCODE -ne 0) { Write-ErrMsg "YAML parse errors: $result"; $failures += "yaml" } else { Write-Ok "all manifests parse (PyYAML)" }
} else {
    Write-WarnMsg "python not found - skipping YAML parse"
}

# --- PowerShell ------------------------------------------------------------------------
Write-Step "PowerShell parse check"
foreach ($file in Get-ChildItem -Path (Join-Path (Get-RepoRoot) "scripts") -Recurse -Filter "*.ps1") {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { Write-ErrMsg "$($file.Name): $($errors[0].Message)"; $failures += $file.Name }
}
Write-Ok "scripts parse"

# --- Shell scripts (run on the cage nodes and, rendered, on the hub VM) ---------
Write-Step "bash -n: Equinix-side scripts + rendered egress-proxy template"
$bash = $null
if ($env:OS -eq "Windows_NT") {
    # Git Bash, not System32\bash.exe (that one needs WSL).
    $gitBash = Join-Path $env:ProgramFiles "Git\bin\bash.exe"
    if (Test-Path $gitBash) { $bash = $gitBash }
} elseif (Test-CommandExists "bash") { $bash = "bash" }
if ($bash) {
    Push-Location (Get-RepoRoot)
    try {
        foreach ($file in Get-ChildItem -Path (Join-Path "equinix" "k3s") -Filter "*.sh") {
            & $bash -n ("equinix/k3s/" + $file.Name)
            if ($LASTEXITCODE -ne 0) { Write-ErrMsg "$($file.Name): bash syntax error"; $failures += $file.Name } else { Write-Ok "$($file.Name)" }
        }
    } finally { Pop-Location }
    # Render the Run Command script exactly as Terraform would, then syntax-check it.
    Push-Location (Join-Path (Get-TerraformDir) "azure")
    try {
        $expr = 'templatefile("templates/configure-egress-proxy.sh.tftpl", { allowed_domains = [".gw.arc.azure.com", "management.azure.com"], proxy_port = 3128, onprem_prefixes = ["10.80.0.0/24"], hub_vnet_cidr = "10.50.0.0/16", storefront_upstreams = ["10.80.0.11:80"] })'
        $rendered = @($expr | terraform console)
        if ($LASTEXITCODE -ne 0 -or $rendered.Count -lt 3) { Write-ErrMsg "configure-egress-proxy.sh.tftpl: render failed"; $failures += "proxy template render" }
        else {
            # terraform console prints multi-line strings as a <<EOT ... EOT heredoc.
            $tmpScript = Join-Path ([IO.Path]::GetTempPath()) "eqarc-configure-egress-proxy.sh"
            [IO.File]::WriteAllText($tmpScript, (($rendered[1..($rendered.Count - 2)] | ForEach-Object { "$_" }) -join "`n") + "`n")
            & $bash -n $tmpScript
            if ($LASTEXITCODE -ne 0) { Write-ErrMsg "configure-egress-proxy.sh.tftpl: bash syntax error (rendered)"; $failures += "proxy template" } else { Write-Ok "configure-egress-proxy.sh.tftpl (rendered)" }
            Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
        }
    } finally { Pop-Location }
} else {
    Write-WarnMsg "bash not found - skipping shell syntax checks (Windows: install Git for Windows)"
}

Write-Step "Summary"
if ($failures.Count -gt 0) { Write-ErrMsg "Failures: $($failures -join ', ')"; exit 1 }
Write-Ok "All checks passed."
exit 0

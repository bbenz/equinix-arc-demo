#Requires -Version 5.1
<#
.SYNOPSIS
    Opens an Azure Arc Cluster Connect session to the Equinix cluster - no VPN,
    no inbound firewall rule, no public IP on the cage - and runs kubectl
    through it. Optionally port-forwards the Equinix storefront to
    http://localhost:8080 as a browser fallback.

.DESCRIPTION
    Starts `az connectedk8s proxy` as a background process that writes its own
    kubeconfig to artifacts/equinix-arc-proxy.kubeconfig (gitignored), so your
    direct 'equinix-demo' context is never overwritten. Requires the
    Cluster Connect RBAC binding created by scripts/06-connect-arc.ps1.

.PARAMETER PortForward
    Also run `kubectl port-forward svc/frontend 8080:80` through the Arc session.

.PARAMETER Stop
    Stop a proxy started earlier by this script.
#>
[CmdletBinding()]
param(
    [switch]$PortForward,
    [switch]$Stop,
    [int]$LocalPort = 8080
)

. (Join-Path (Join-Path $PSScriptRoot "lib") "common.ps1")

$dotEnv = Get-DotEnv
$naming = Get-Naming -DotEnv $dotEnv
$rg = Get-ArcResourceGroup -DotEnv $dotEnv -AzureOutputs (Get-TfOutputs -RootDir (Get-TfRootDir "azure"))
$kubeconfig = Join-Path (Get-ArtifactsDir) "equinix-arc-proxy.kubeconfig"
$pidFile = Join-Path (Get-ArtifactsDir) "equinix-arc-proxy.pid"
$onWindows = ($env:OS -eq "Windows_NT")

function Stop-ArcProxy {
    if (-not (Test-Path $pidFile)) { return $false }
    foreach ($p in (Get-Content $pidFile)) {
        # az is a .cmd wrapper on Windows: kill the whole process tree by PID.
        if ($onWindows) { taskkill /PID ([int]$p) /T /F 2>&1 | Out-Null }
        else { Stop-Process -Id ([int]$p) -ErrorAction SilentlyContinue }
    }
    Remove-Item $pidFile -Force
    return $true
}

if ($Stop) {
    if (Stop-ArcProxy) { Write-Ok "Arc proxy session stopped" } else { Write-Info "No proxy session recorded." }
    exit 0
}

Write-Step "Starting Azure Arc Cluster Connect to $($naming.EquinixMember)"
if (Stop-ArcProxy) { Write-Info "Stopped the previous proxy session first." }
# The real az executable (on Windows PowerShell 5.1, `az` is also a function shim).
$azPath = (Get-Command az -CommandType Application | Select-Object -First 1).Source
$startArgs = @{
    FilePath     = $azPath
    ArgumentList = @("connectedk8s", "proxy", "--name", $naming.EquinixMember, "--resource-group", $rg,
        "--file", "`"$kubeconfig`"", "--kube-context", $naming.EquinixMember)
    PassThru     = $true
}
if ($onWindows) { $startArgs.WindowStyle = "Hidden" }
$proc = Start-Process @startArgs
Set-Content -Path $pidFile -Value $proc.Id
Write-Info "az connectedk8s proxy started (PID $($proc.Id)) - waiting for the session..."

$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 3
    if (Test-Path $kubeconfig) {
        kubectl get ns online-boutique --kubeconfig $kubeconfig --context $naming.EquinixMember --request-timeout=10s 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    }
}
if (-not $ready) {
    [void](Stop-ArcProxy)
    Write-ErrMsg "Arc session not ready (proxy process stopped) - check RBAC (scripts/06-connect-arc.ps1) and 'az connectedk8s show -n $($naming.EquinixMember) -g $rg'."
    exit 1
}

Write-Ok "kubectl is now talking to the Equinix cage THROUGH Azure Arc:"
kubectl get pods -n online-boutique -o wide --kubeconfig $kubeconfig --context $naming.EquinixMember

if ($PortForward) {
    Write-Step "Port-forwarding the Equinix storefront to http://localhost:$LocalPort (Ctrl+C to stop)"
    kubectl port-forward svc/frontend "$($LocalPort):80" -n online-boutique --kubeconfig $kubeconfig --context $naming.EquinixMember
}
Write-Info "Reuse: kubectl --kubeconfig $kubeconfig --context $($naming.EquinixMember) <command>"
Write-Info "Stop:  scripts/demo-arc-proxy.ps1 -Stop"
exit 0

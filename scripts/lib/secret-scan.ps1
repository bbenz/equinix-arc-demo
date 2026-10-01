#Requires -Version 5.1
<#
.SYNOPSIS
    Scans every committable file (tracked + untracked-but-not-ignored) for
    high-confidence secret patterns: AWS access keys, private keys, Google API
    keys/tokens, JWTs, Azure storage connection strings and SAS signatures.
    A safety net on top of .gitignore - exits non-zero on any match.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot "common.ps1")

$root = Get-RepoRoot
$files = @()
Push-Location $root
try {
    if ((Test-CommandExists "git") -and (Test-Path (Join-Path $root ".git"))) {
        $files = @(git ls-files --others --cached --exclude-standard | Where-Object { $_ -ne "" })
    }
} finally { Pop-Location }
if ($files.Count -eq 0) {
    Write-WarnMsg "Not a git repository yet - scanning all files except .terraform/ and state."
    $files = @(Get-ChildItem -Recurse -File -Path $root |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]|[\\/]\.terraform[\\/]|\.tfstate|[\\/]artifacts[\\/]' } |
            ForEach-Object { $_.FullName.Substring($root.Length + 1) })
}

$patterns = @(
    @{ Name = "AWS access key ID"; Regex = "AKIA[0-9A-Z]{16}" },
    @{ Name = "Private key block"; Regex = "-----BEGIN (RSA |EC |OPENSSH |DSA |)PRIVATE KEY-----" },
    @{ Name = "Google API key"; Regex = "AIza[0-9A-Za-z\-_]{35}" },
    @{ Name = "Google OAuth token"; Regex = "ya29\.[0-9A-Za-z\-_]+" },
    @{ Name = "JWT"; Regex = "eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}" },
    @{ Name = "Azure storage connection string"; Regex = "AccountKey=[A-Za-z0-9+/=]{40,}" },
    @{ Name = "Azure SAS signature"; Regex = "sig=[A-Za-z0-9%]{30,}" }
)

$findings = @()
foreach ($rel in $files) {
    $full = Join-Path $root $rel
    if (-not (Test-Path $full -PathType Leaf)) { continue }
    if ($rel -match '\.(png|jpg|jpeg|gif|ico|zip|gz|exe|dll|pdf|pptx|docx|mp4)$') { continue }
    try { $content = Get-Content -Path $full -Raw -ErrorAction Stop } catch { continue }
    if ($null -eq $content) { continue }
    foreach ($p in $patterns) {
        if ($content -match $p.Regex) { $findings += [pscustomobject]@{ File = $rel; Pattern = $p.Name } }
    }
}

Write-Step "Secret scan"
if ($findings.Count -eq 0) {
    Write-Ok "No matches for $($patterns.Count) patterns across $($files.Count) files."
    exit 0
}
foreach ($f in $findings) { Write-ErrMsg "$($f.File): $($f.Pattern)" }
exit 1

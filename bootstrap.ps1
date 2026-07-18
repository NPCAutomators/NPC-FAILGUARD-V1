# NPC FailGuard - one-command installer for Windows (irm entrypoint).
#
#   irm https://raw.githubusercontent.com/NPCAutomators/NPC-FAILGUARD-V1/main/bootstrap.ps1 | iex
#
# If you publish under a different GitHub org/repo, change $GithubRepo below
# (or set NPC_FAILGUARD_GITHUB_REPO) and the matching line in README.md.
$ErrorActionPreference = "Stop"

# --- identity (edit when the public GitHub repo changes) --------------------
$GithubRepo   = if ($env:NPC_FAILGUARD_GITHUB_REPO) { $env:NPC_FAILGUARD_GITHUB_REPO }
                else { "NPCAutomators/NPC-FAILGUARD-V1" }
$GithubBranch = if ($env:NPC_FAILGUARD_GITHUB_BRANCH) { $env:NPC_FAILGUARD_GITHUB_BRANCH }
                else { "main" }
# ---------------------------------------------------------------------------

$TarballUrl = if ($env:NPC_FAILGUARD_TARBALL) { $env:NPC_FAILGUARD_TARBALL }
              else { "https://github.com/$GithubRepo/archive/refs/heads/$GithubBranch.zip" }
$InstallDir = if ($env:NPC_FAILGUARD_INSTALL_DIR) { $env:NPC_FAILGUARD_INSTALL_DIR }
              else { Join-Path $env:USERPROFILE ".npc-failguard\app" }
$KeepFiles = @("keys.json", "state.json", "provider.json", "api.txt",
               "stats.json", "pricing.json")

Write-Host "==> NPC FailGuard bootstrap (Windows)"
Write-Host "    source: github.com/$GithubRepo@$GithubBranch"

$Tmp = Join-Path $env:TEMP ("npc-failguard-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $Tmp | Out-Null
try {
    Write-Host "==> Downloading..."
    $Zip = Join-Path $Tmp "app.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $TarballUrl -OutFile $Zip
    Expand-Archive -Path $Zip -DestinationPath (Join-Path $Tmp "x") -Force
    $Src = Get-ChildItem (Join-Path $Tmp "x") -Recurse -Depth 2 -Filter "install.ps1" |
           Select-Object -First 1 -ExpandProperty DirectoryName
    if (-not $Src) {
        Write-Host "[!] install.ps1 not found inside the archive (wrong zip?)."
        exit 1
    }

    $Keep = Join-Path $Tmp "keep"
    if (Test-Path $InstallDir) {
        Write-Host "==> Existing install found - upgrading (keys/state preserved)"
        New-Item -ItemType Directory -Force $Keep | Out-Null
        foreach ($f in $KeepFiles) {
            $p = Join-Path $InstallDir "core\$f"
            if (Test-Path $p) { Copy-Item $p (Join-Path $Keep $f) -Force }
        }
        # Stop the daemon so the venv isn't file-locked during removal
        try { Stop-ScheduledTask -TaskName "NPC FailGuard" -ErrorAction SilentlyContinue } catch {}
        Remove-Item -Recurse -Force $InstallDir
    }
    New-Item -ItemType Directory -Force (Split-Path $InstallDir) | Out-Null
    Move-Item $Src $InstallDir
    if (Test-Path $Keep) {
        foreach ($f in $KeepFiles) {
            $p = Join-Path $Keep $f
            if (Test-Path $p) { Move-Item $p (Join-Path $InstallDir "core\$f") -Force }
        }
    }

    Write-Host "==> Running installer..."
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir "install.ps1")
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host ""
    Write-Host "==================================================================="
    Write-Host "  Bootstrap complete."
    Write-Host "  1. Open a NEW terminal and run:  claude"
    Write-Host "  2. Inside Claude, type:"
    Write-Host "     /npc-failguard:setup <base-url> <key1 key2 ... or C:\path\keys.txt>"
    Write-Host "==================================================================="
} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

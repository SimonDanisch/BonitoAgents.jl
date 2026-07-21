<#
.SYNOPSIS
    BonitoAgents desktop installer (Windows).

.DESCRIPTION
    Downloads the prebuilt release bundle, installs it under %LOCALAPPDATA%
    (no admin), exposes a `bonito-agents` command, and starts the desktop app:
    a local dashboard server + a worker for this machine, opened in your
    browser. Re-run any time to auto-update; it skips the download when you are
    already on the newest release.

    Per-user state (chats, projects, depot cache) lives under
    %LOCALAPPDATA%\BonitoAgents and is never touched by install/update/uninstall.

    Run it with:
        irm https://raw.githubusercontent.com/SimonDanisch/BonitoAgents.jl/main/install.ps1 | iex

    When piped through `iex`, options are taken from environment variables
    (the -Parameters only bind when you run the saved .ps1 directly):
        $env:BONITOAGENTS_RELEASE  release tag to install, or "latest" (default)
        $env:BONITOAGENTS_TARBALL  install a local *.tar.gz instead of downloading
        $env:BONITOAGENTS_NORUN=1  install/update only; do not start afterwards
        $env:BONITOAGENTS_FORCE=1  reinstall even if already up to date
        $env:BONITOAGENTS_UNINSTALL=1  remove the app + command (state kept)

.PARAMETER NoRun
    Install/update only; do not start the app afterwards.
.PARAMETER Force
    Reinstall even if already on the latest version.
.PARAMETER Uninstall
    Remove the app + command (per-user state is left intact).
#>
[CmdletBinding()]
param(
    [switch] $NoRun,
    [switch] $Force,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Piped through `iex`, param() switches don't bind — honour env fallbacks too.
if ($env:BONITOAGENTS_NORUN)     { $NoRun     = $true }
if ($env:BONITOAGENTS_FORCE)     { $Force     = $true }
if ($env:BONITOAGENTS_UNINSTALL) { $Uninstall = $true }

$Repo    = if ($env:BONITOAGENTS_REPO)    { $env:BONITOAGENTS_REPO }    else { 'SimonDanisch/BonitoAgents.jl' }
$Release = if ($env:BONITOAGENTS_RELEASE) { $env:BONITOAGENTS_RELEASE } else { 'latest' }

$AppName = 'bonitoagents'        # launcher name inside the bundle (.bat on Windows)
$CmdName = 'bonito-agents'       # the command we put on PATH

$DataHome = $env:LOCALAPPDATA
# Install dir is DISTINCT from the app's state dir (%LOCALAPPDATA%\BonitoAgents),
# so replacing the app never touches chats or projects.
$Prefix  = Join-Path $DataHome 'BonitoAgents-app'
$BinDir  = Join-Path $DataHome 'BonitoAgents-bin'
$Launcher = Join-Path $Prefix "bin\$AppName.bat"
$RelMark  = Join-Path $Prefix '.release'
$Shim     = Join-Path $BinDir "$CmdName.cmd"
$ShimAlt  = Join-Path $BinDir "$AppName.cmd"

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "warning: $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "error: $m" -ForegroundColor Red; exit 1 }

# ── Uninstall ─────────────────────────────────────────────────────────────────
if ($Uninstall) {
    Info "Removing BonitoAgents from $Prefix"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Prefix, $Shim, $ShimAlt
    Write-Host "Done. (Per-user state under $DataHome\BonitoAgents was left intact.)"
    return
}

# ── Platform detection ────────────────────────────────────────────────────────
$archRaw = $env:PROCESSOR_ARCHITECTURE
switch ($archRaw) {
    'AMD64' { $arch = 'x86_64' }
    'x86'   { $arch = 'x86_64' }   # 32-bit shell on a 64-bit OS
    default { Die "unsupported architecture: $archRaw (only x86_64 Windows bundles are published)" }
}
$asset = "bonitoagents-windows-$arch.tar.gz"

if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    Die "tar.exe not found. Windows 10 (1803+) and 11 ship it; otherwise install it and re-run."
}

# Resolve the newest release tag via the GitHub API (tokenless, version-free).
function Resolve-LatestTag {
    try {
        $r = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'bonitoagents-installer' } `
             -Uri "https://api.github.com/repos/$Repo/releases/latest"
        return $r.tag_name
    } catch { return $null }
}

# ── Resolve target version + URL ──────────────────────────────────────────────
if ($env:BONITOAGENTS_TARBALL) {
    $targetTag = 'local'
} elseif ($Release -eq 'latest') {
    $targetTag = Resolve-LatestTag
    $url = "https://github.com/$Repo/releases/latest/download/$asset"
} else {
    $targetTag = $Release
    $url = "https://github.com/$Repo/releases/download/$Release/$asset"
}

# ── Already up to date? ───────────────────────────────────────────────────────
$installedTag = if (Test-Path $RelMark) { (Get-Content $RelMark -Raw).Trim() } else { '' }

if (-not $Force -and (Test-Path $Launcher) -and $targetTag -and $targetTag -ne 'local' -and $installedTag -eq $targetTag) {
    Info "BonitoAgents $installedTag is already up to date."
} else {
    $stage   = Join-Path $DataHome ".bonitoagents-stage.$PID"
    $tarball = Join-Path $DataHome ".bonitoagents-dl.$PID.tar.gz"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage, $tarball

    try {
        if ($env:BONITOAGENTS_TARBALL) {
            Info "Using local bundle: $($env:BONITOAGENTS_TARBALL)"
            if (-not (Test-Path $env:BONITOAGENTS_TARBALL)) { Die "no such file: $($env:BONITOAGENTS_TARBALL)" }
            Copy-Item $env:BONITOAGENTS_TARBALL $tarball
        } else {
            if ($installedTag) {
                Info "Updating BonitoAgents $installedTag -> $targetTag (windows-$arch)"
            } else {
                Info "Downloading BonitoAgents $targetTag (windows-$arch)"
            }
            $ProgressPreference = 'Continue'
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tarball
        }

        Info "Extracting"
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        tar.exe -xzf $tarball -C $stage
        if ($LASTEXITCODE -ne 0) { Die "extraction failed (corrupt download?)" }

        $bundle = Get-ChildItem -Directory $stage | Where-Object { $_.Name -like 'bonitoagents-*' } | Select-Object -First 1
        if (-not $bundle -or -not (Test-Path (Join-Path $bundle.FullName "bin\$AppName.bat"))) {
            Die "bundle is missing bin\$AppName.bat — aborting"
        }

        Info "Installing to $Prefix"
        Set-Content -Path (Join-Path $bundle.FullName '.release') -Value $targetTag -NoNewline
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Prefix
        Move-Item $bundle.FullName $Prefix
    }
    finally {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $stage, $tarball
    }

    # ── Command on PATH ───────────────────────────────────────────────────────
    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    $shimBody = "@echo off`r`n`"$Launcher`" %*`r`n"
    Set-Content -Path $Shim    -Value $shimBody -Encoding ascii
    Set-Content -Path $ShimAlt -Value $shimBody -Encoding ascii

    Info "Installed BonitoAgents $targetTag — command: $CmdName"
}

# ── Ensure BinDir is on the user PATH for future shells ────────────────────────
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if (($userPath -split ';') -notcontains $BinDir) {
    $newPath = if ($userPath) { "$userPath;$BinDir" } else { $BinDir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Warn "added $BinDir to your user PATH — open a new terminal to use '$CmdName'."
}
# Make it usable in THIS session too.
if (($env:Path -split ';') -notcontains $BinDir) { $env:Path = "$env:Path;$BinDir" }

# ── Launch ────────────────────────────────────────────────────────────────────
if (-not $NoRun) {
    Info "Starting BonitoAgents — the dashboard will open in your browser (Ctrl+C to stop)."
    & $Launcher
} else {
    Write-Host ""
    Write-Host "Start it any time with:  $CmdName"
}

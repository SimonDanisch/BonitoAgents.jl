# BonitoAgents worker bootstrap (Windows).
#
#   irm {{SERVER_URL}}/install.ps1 | iex
#
# Tiny shim around the cross-platform Julia installer. We don't pipe the .jl
# directly into `julia -` because PowerShell pipelines pass objects (not a raw
# byte stream) and `julia -` mis-decodes the UTF-16 stdin — so we download to a
# temp file and run `julia <file>` instead. {{SERVER_URL}} is templated by the
# server.
$ErrorActionPreference = 'Stop'
if (-not (Get-Command julia -ErrorAction SilentlyContinue)) {
    Write-Error "julia not on PATH. Install Julia first: https://julialang.org/install/"
    exit 1
}
$tmp = New-TemporaryFile
try {
    Invoke-RestMethod -Uri '{{SERVER_URL}}/install.jl' -OutFile $tmp.FullName
    & julia $tmp.FullName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
}

#!/usr/bin/env sh
# BonitoAgents worker bootstrap (Linux / macOS).
#
#   curl -fsSL {{SERVER_URL}}/install.sh | sh
#
# Tiny shim around the cross-platform Julia installer: verify `julia` is on
# PATH (we don't bootstrap juliaup — install Julia separately), then fetch
# and execute the real installer. {{SERVER_URL}} is templated by the server.
set -eu
if ! command -v julia >/dev/null 2>&1; then
    echo "error: julia not on PATH. Install Julia first: https://julialang.org/install/" >&2
    exit 1
fi
curl -fsSL '{{SERVER_URL}}/install.jl' | julia -

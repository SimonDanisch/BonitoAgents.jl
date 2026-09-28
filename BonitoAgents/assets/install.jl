#!/usr/bin/env julia
# BonitoAgents worker installer — cross-platform (Linux / macOS / Windows).
#
#   curl -fsSL {{SERVER_URL}}/install.jl | BONITOAGENTS_WORKER_CREDENTIAL='<from Add worker>' julia -
#
# Windows 10 1803+ ships curl.exe, so the same one-liner works everywhere.
# The server templates {{SERVER_URL}} and its git revision into this file
# before serving it from the /install.jl route. The file holds no secret: the
# worker's credential ("Add worker" on the dashboard issues one per machine)
# arrives in BONITOAGENTS_WORKER_CREDENTIAL, and a server without the login
# proxy (localhost only) needs none.
#
# What it does:
#   1. Installs BonitoWorker + BonitoMCP from the public repo into the
#      SHARED `@bonito-agents` environment (Pkg url+subdir — no tar bundle,
#      no per-package source trees, cross-platform by construction).
#   2. Hands off to `BonitoWorker.install!` which records the config in a
#      Scratch space and starts the worker process.
#
# Node and the agent adapters (claude-agent-acp, codex-acp) are the worker's to
# install and update, at the versions the server declares; only logging in to
# the agents (`claude login`, …) stays with the machine's user.
#
# No OS service — it just launches the Julia worker process (per request).
import Pkg

const REPO   = "https://github.com/SimonDanisch/BonitoAgents.jl"
# Templated by the server (`render_install_script`) to whatever branch /
# tag / sha the server is itself running from — so a dev iterating on a
# feature branch can `curl … | sh` workers onto the same code without
# users needing to know its name. See server.jl :: current_repo_rev.
const REV    = "{{REV}}"
const SOURCE_ID = "{{SOURCE_ID}}"
const SERVER = "{{SERVER_URL}}"
const CREDENTIAL = get(ENV, "BONITOAGENTS_WORKER_CREDENTIAL", "")
# Bonito (the UI / proxy library) is pinned to the SERVER's version so
# remote-app frames / dial-back / id_prefix all match across the wire.
# Templated from the server's `[sources]` Bonito = {url, rev} entry —
# see server.jl :: current_bonito_install_spec.
const BONITO_URL = "{{BONITO_URL}}"
const BONITO_REV = "{{BONITO_REV}}"

# Guard against running the raw template (the `{{ }}` are intact only if this
# file wasn't fetched through the server's rendering route).
if startswith(SERVER, "{{") ||
        startswith(REV, "{{") || startswith(SOURCE_ID, "{{") || startswith(BONITO_URL, "{{") ||
        startswith(BONITO_REV, "{{")
    error("install.jl must be fetched from a running BonitoAgents server: " *
          "`curl -fsSL <server-url>/install.jl | julia -`")
end

println("==> BonitoAgents worker installer")
println("    server : ", SERVER)
println("    repo   : ", REPO, " @ ", REV)
println("    workdir: ", pwd())
println("    login  : ", isempty(CREDENTIAL) ? "none (a server on this machine)" :
                        "worker credential " * first(split(CREDENTIAL, ':')))
# The agents log in as this machine's user; the worker installs them but cannot
# log in for anyone.
isdir(joinpath(homedir(), ".claude")) ||
    println("    note   : Claude Code was never used here. Chats with it need its login: install it and " *
            "run `claude` once (https://claude.com/claude-code).")

# ── Shared @bonito-agents environment ──────────────────────────────────────────
# RemoteSync is an unregistered package and a dependency of BonitoWorker.
# Pkg does NOT consult a dependency package's own `[sources]`, so we add
# RemoteSync explicitly (url+subdir) — that puts it in the env, and
# BonitoWorker's `[deps] RemoteSync` then resolves against it by UUID.
# All three come from the same repo/rev so they resolve as one set. The
# monorepo packages listed here are what the "Debug BonitoAgents" chat later
# `Pkg.develop`s from a clone on the worker — keep the list in step with
# `WORKER_REPO_PACKAGES` in BonitoAgents/src/server.jl.
println("\n==> Installing into shared @bonito-agents env")
Pkg.activate("bonito-agents"; shared = true)
const SPECS = [
    Pkg.PackageSpec(name = "RemoteSync",   url = REPO, subdir = "RemoteSync",   rev = REV),
    Pkg.PackageSpec(name = "WorkerLink",   url = REPO, subdir = "WorkerLink",   rev = REV),
    Pkg.PackageSpec(name = "BonitoWorker", url = REPO, subdir = "BonitoWorker", rev = REV),
    Pkg.PackageSpec(name = "BonitoMCP",    url = REPO, subdir = "BonitoMCP",    rev = REV),
    Pkg.PackageSpec(name = "AgentProviders", url = REPO, subdir = "AgentProviders", rev = REV),
    Pkg.PackageSpec(name = "Bonito", rev = BONITO_REV),
]

# Capture the pre-install tree-shas for the three packages so we can detect
# whether re-running the installer actually moved them forward. `Pkg.add` on
# an already-installed package is a no-op against the manifest-pinned sha;
# `Pkg.update` is the call that fetches the current HEAD of `rev`. We run
# both — `add` for the fresh-install path, `update` to force a refresh on
# re-install. Without the explicit `update` the installer silently keeps the
# user on the manifest's frozen sha forever.
#
# The update is UNSCOPED on purpose. Passing `SPECS` only re-pins those
# packages and whatever their resolve drags along, so a registry dep the env
# already holds stays frozen even when it should move — including when a
# dependency tightens its compat (Bonito requiring CommonMark 1.0.4 is what
# surfaced this). An installer's job is to leave the env current, so update
# the whole thing.
function _tree_shas()
    deps = Pkg.dependencies()
    Dict(p.name => p.tree_hash for p in values(deps)
         if p.name in ("RemoteSync", "WorkerLink", "BonitoWorker", "BonitoMCP", "Bonito"))
end
before = _tree_shas()
Pkg.add(SPECS)        # idempotent: handles the fresh-install path
Pkg.update()          # whole env: re-pins `rev` HEADs AND moves registry deps
Pkg.precompile()
after = _tree_shas()

# Diff: which packages actually moved? Used by `BonitoWorker.install!` to
# decide whether a live background worker / running service needs to be
# restarted to pick up the new code.
code_changed = any(get(before, k, nothing) != get(after, k, nothing)
                   for k in keys(after))
if code_changed
    bumped = [k for k in sort(collect(keys(after)))
              if get(before, k, nothing) != get(after, k, nothing)]
    println("    code updated   : ", join(bumped, ", "))
else
    println("    code unchanged : already at $(REV) HEAD")
end

# ── Configure + launch ───────────────────────────────────────────────────────
import BonitoWorker
BonitoWorker.install!(; server_url    = SERVER,
                         credential    = CREDENTIAL,
                         projects_root = pwd(),
                         update_spec   = Dict("repo"       => REPO,
                                              "rev"        => REV,
                                              "source_id"  => SOURCE_ID,
                                              "bonito_url" => BONITO_URL,
                                              "bonito_rev" => BONITO_REV),
                         code_changed  = code_changed)

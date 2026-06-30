#!/usr/bin/env julia
# BonitoAgents worker installer — cross-platform (Linux / macOS / Windows).
#
#   curl -fsSL {{SERVER_URL}}/install.jl | julia -
#
# Windows 10 1803+ ships curl.exe, so the same one-liner works everywhere.
# The server templates {{SERVER_URL}} / {{WORKER_SECRET}} into this file
# before serving it from the /install.jl route.
#
# What it does:
#   1. Verifies the Claude Code prerequisites are on PATH.
#   2. Installs BonitoWorker + BonitoMCP from the public repo into the
#      SHARED `@bonito-agents` environment (Pkg url+subdir — no tar bundle,
#      no per-package source trees, cross-platform by construction).
#   3. Hands off to `BonitoWorker.install!` which records the config in a
#      Scratch space and starts the worker process.
#
# No OS service — it just launches the Julia worker process (per request).
import Pkg

const REPO   = "https://github.com/SimonDanisch/BonitoAgents.jl"
# Templated by the server (`render_install_script`) to whatever branch /
# tag / sha the server is itself running from — so a dev iterating on a
# feature branch can `curl … | sh` workers onto the same code without
# users needing to know its name. See server.jl :: current_repo_rev.
const REV    = "{{REV}}"
const SERVER = "{{SERVER_URL}}"
const SECRET = "{{WORKER_SECRET}}"
# Bonito (the UI / proxy library) is pinned to the SERVER's version so
# remote-app frames / dial-back / id_prefix all match across the wire.
# Templated from the server's `[sources]` Bonito = {url, rev} entry —
# see server.jl :: current_bonito_install_spec.
const BONITO_URL = "{{BONITO_URL}}"
const BONITO_REV = "{{BONITO_REV}}"

# Guard against running the raw template (the `{{ }}` are intact only if this
# file wasn't fetched through the server's rendering route).
if startswith(SERVER, "{{") || startswith(SECRET, "{{") ||
        startswith(REV, "{{") || startswith(BONITO_URL, "{{") ||
        startswith(BONITO_REV, "{{")
    error("install.jl must be fetched from a running BonitoAgents server: " *
          "`curl -fsSL <server-url>/install.jl | julia -`")
end

println("==> BonitoAgents worker installer")
println("    server : ", SERVER)
println("    repo   : ", REPO, " @ ", REV)
println("    workdir: ", pwd())

# ── Prerequisites ────────────────────────────────────────────────────────────
# Claude Code itself is user-managed (install + `claude login` once). The
# installer only checks they're reachable. npm and claude-agent-acp are
# installed by npm as `.cmd` shims on Windows; `Sys.which` only walks the
# raw name + .exe there, so we fall back to .cmd/.bat explicitly.
@static if Sys.iswindows()
    which_executable(name) = something(Sys.which(name),
                                       Sys.which(name * ".cmd"),
                                       Sys.which(name * ".bat"),
                                       Some(nothing))
else
    which_executable(name) = Sys.which(name)
end
let missing = filter(b -> which_executable(b) === nothing, ["node", "npm", "claude", "claude-agent-acp"])
    if !isempty(missing)
        error("missing prerequisite(s) on PATH: $(join(missing, ", ")).\n" *
              "    Install Node.js 20+ and Claude Code first:\n" *
              "      Node 22 LTS: https://nodejs.org/  (or `winget install OpenJS.NodeJS.LTS`)\n" *
              "      npm install -g @anthropic-ai/claude-code @agentclientprotocol/claude-agent-acp\n" *
              "      claude login")
    end
end
# claude-agent-acp uses `import attributes` syntax which lands in Node 20.10+
# (or the Node 18.20 backport). On older Node the agent dies on first spawn
# with `SyntaxError: Unexpected token 'with'`, which surfaces in the dashboard
# as the opaque "ACP connection closed". Catch it here instead.
let ver = try
        strip(read(`$(which_executable("node")) --version`, String))  # e.g. "v18.17.1"
    catch; "" end
    m = match(r"^v(\d+)\.(\d+)", ver)
    if m === nothing
        error("could not determine node version (got: $(repr(ver)))")
    end
    major, minor = parse(Int, m.captures[1]), parse(Int, m.captures[2])
    too_old = major < 18 || (major == 18 && minor < 20)
    too_old && error("Node $ver is too old; claude-agent-acp needs Node 20+ " *
                     "(or 18.20+). Install Node 22 LTS:\n" *
                     "      https://nodejs.org/  (or `winget install OpenJS.NodeJS.LTS`)")
    println("    prereqs: node $(ver), npm, claude, claude-agent-acp ok")
end

# ── Shared @bonito-agents environment ──────────────────────────────────────────
# RemoteSync is an unregistered package and a dependency of BonitoWorker.
# Pkg does NOT consult a dependency package's own `[sources]`, so we add
# RemoteSync explicitly (url+subdir) — that puts it in the env, and
# BonitoWorker's `[deps] RemoteSync` then resolves against it by UUID.
# All three come from the same repo/rev so they resolve as one set.
println("\n==> Installing into shared @bonito-agents env")
Pkg.activate("bonito-agents"; shared = true)
const SPECS = [
    Pkg.PackageSpec(name = "RemoteSync",   url = REPO, subdir = "RemoteSync",   rev = REV),
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
function _tree_shas()
    deps = Pkg.dependencies()
    Dict(p.name => p.tree_hash for p in values(deps)
         if p.name in ("RemoteSync", "BonitoWorker", "BonitoMCP", "Bonito"))
end
before = _tree_shas()
Pkg.add(SPECS)        # idempotent: handles the fresh-install path
Pkg.update(SPECS)     # forces a re-pin against `rev`'s current HEAD
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
                         secret        = SECRET,
                         projects_root = pwd(),
                         code_changed  = code_changed)

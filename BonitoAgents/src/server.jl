# Path to the BonitoAgents package's assets/ (install.jl, bonitoagents.js)
const ASSETS_DIR    = normpath(joinpath(@__DIR__, "..", "assets"))
# Monorepo root (sibling of BonitoAgents/) — contains BonitoMCP/, BonitoWorker/, AgentClientProtocol/.
const MONOREPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

# The worker installer is a cross-platform Julia script (`curl … | julia -`).
# It Pkg.add's BonitoWorker + BonitoMCP from the public GitHub repo into a
# shared `@bonito-agents` env — no tar bundle, no per-package source trees, runs
# identically on Linux / macOS / Windows. See assets/install.jl.
#
# Around it sit two tiny per-shell bootstraps so the install one-liner mirrors
# the familiar `curl URL | sh` shape on each OS. They only check that `julia`
# is on PATH and then hand off to install.jl — they do NOT install juliaup
# (Julia is a prerequisite the user installs separately).
const INSTALL_SCRIPT = read(joinpath(ASSETS_DIR, "install.jl"), String)
const INSTALL_SH     = read(joinpath(ASSETS_DIR, "install.sh"),  String)
const INSTALL_PS1    = read(joinpath(ASSETS_DIR, "install.ps1"), String)

"""
    serve(; host, port, public_url, worker_secret, state_dir, working_dir) → Bonito.Server

Start the BonitoAgents dashboard server. Workers dial back to this server, so
only port `port` (default 8038) needs to be open in the server's firewall.

Routes:
  /                       — dashboard (workers + projects)
  /p/<project_id>         — chat UI for one project
  /install                — OS-sniffing bootstrap (`curl … | sh` / `irm … | iex`)
  /install.sh             — bash wrapper (Linux / macOS)
  /install.ps1            — PowerShell wrapper (Windows)
  /install.jl             — cross-platform worker installer (used by the wrappers)
  /worker-ws    (WS)      — control channel each worker holds open after install
  /worker-acp   (WS)      — per-session ACP relay; one connection per project session
  /transfer-ws  (WS)      — librsync directional transfer; dialed on demand by a
                            worker in response to an `open_transfer` command

`worker_secret` is the shared secret used by every worker. `public_url` is the
base URL workers see (and what the install script tells them to dial back).

`state_dir`   overrides where workers.json / projects.json are persisted
              (default: `~/.local/share/bonitoagents-server`).
`working_dir` overrides where canonical project copies live on the server.
              Each project lives at `<working_dir>/<name>` and is mirrored
              onto the worker at `<worker.projects_root>/<name>`.
              (default: `~/bonitoagents-server`)
"""
function serve(; host::String        = "0.0.0.0",
                 port::Int           = 8038,
                 public_url::Union{String,Nothing}   = nothing,
                 worker_secret::String,
                 state_dir::Union{String,Nothing}   = nothing,
                 working_dir::Union{String,Nothing} = nothing)
    # `nothing` OR `""` (env-var roundtrip) → use the platform default. Anything
    # else is taken as an absolute override.
    isvalid(s) = s !== nothing && !isempty(String(s))
    sd = isvalid(state_dir)   ? String(state_dir)   :
         joinpath(homedir(), ".local", "share", "bonitoagents-server")
    wd = isvalid(working_dir) ? String(working_dir) :
         joinpath(homedir(), "bonitoagents-server")

    state = ServerState(; state_dir = sd, working_dir = wd, worker_secret = worker_secret)

    # Mark all loaded workers offline; they'll flip online when they re-dial.
    for w in values(state.workers[])
        w.status = :offline
    end

    # Survive long browser disconnects (phone goes into pocket, laptop sleeps,
    # network blip) by keeping SOFT_CLOSED sessions alive for an hour, so the
    # browser can reconnect to the SAME session with all of its Observable
    # state — current view, popup geometry, chat consumer task — intact.
    # The new-tab case still falls back to the localStorage last-route memory
    # wired in the sidebar onload.
    Bonito.set_cleanup_time!(1.0)   # hours

    # Single-page app: sidebar + dashboard/chat swap. No per-project routes.
    srv = Bonito.Server(unified_app(state), host, port; proxy_url = ".")
    state.srv = srv

    # online_url uses the post-start srv.port — handles port=0 → ephemeral
    # AND EADDRINUSE → port+1 retry without us tracking the actual port.
    # An EMPTY public_url counts as unset too (the CLI entry point passes ""
    # when --public-url was omitted; `something("", …)` would have kept the
    # empty string and templated install scripts with a blank SERVER_URL).
    base_url = (public_url === nothing || isempty(public_url)) ?
        Bonito.online_url(srv, "") : public_url
    # The dashboard's install snippet renders the SAME url the install routes
    # are templated with — never a "<your-server>" placeholder.
    state.base_url[] = rstrip(base_url, '/')
    add_install_routes!(srv, base_url, worker_secret)
    add_acp_log_routes!(srv, state)
    add_worker_ws_routes!(srv, state)

    # The background-output poller is no longer a server-wide loop — it's
    # per-ChatModel now, spawned in `start_chat_client!` and torn down
    # when the chat goes away. Closes the "global loop forever walking
    # every chat's msgs_store" mismatch with the taskbar's per-chat
    # mental model. See `start_background_poller!` in chat.jl.

    # Show the SAME canonical url the UI + worker-install snippet use (`base_url`
    # = the configured --public-url, or the detected address) — not the bind-based
    # `online_url(srv)` (0.0.0.0/localhost), which mismatched the dashboard's
    # "add worker" url whenever --public-url was set.
    @info "BonitoAgents dashboard running" url=base_url state=sd
    @info "Worker install — run on each agent machine" *
          "\n    Linux / macOS  : curl -fsSL $base_url/install.sh | sh" *
          "\n    Windows (PS)   : irm $base_url/install.ps1 | iex"
    return state
end

# ── Package entry point ──────────────────────────────────────────────────────
# `julia --project=<monorepo root> -m BonitoAgents [flags]` starts the server and
# blocks. No env vars: defaults are baked in (port 8038, host 0.0.0.0) and the
# worker secret is generated + persisted in the state dir on first run, so
# workers keep authenticating across restarts. Override any default with a flag:
#
#   julia --project=. -m BonitoAgents
#   julia --project=. -m BonitoAgents --port 8080
#   julia --project=. -m BonitoAgents --public-url https://team.example.com --secret <hex>
#
# Flags: --port --host --public-url --secret --state-dir --working-dir
function (@main)(args::Vector{String})
    opts = parse_server_args(args)
    sd_arg = get(opts, "state-dir", "")
    state_dir = isempty(sd_arg) ?
        joinpath(homedir(), ".local", "share", "bonitoagents-server") : sd_arg
    secret = get(opts, "secret", "")
    isempty(secret) && (secret = persisted_worker_secret(state_dir))
    serve(;
        worker_secret = secret,
        host          = get(opts, "host", "0.0.0.0"),
        port          = parse(Int, get(opts, "port", "8038")),
        public_url    = get(opts, "public-url", ""),
        state_dir     = state_dir,
        working_dir   = get(opts, "working-dir", ""),
    )
    wait()
    return 0
end

# Tiny CLI parser: accepts `--key value` and `--key=value`; errors on anything
# else so a typo fails loudly instead of silently using a default.
function parse_server_args(args::Vector{String})
    opts = Dict{String,String}()
    i = 1
    while i <= length(args)
        a = args[i]
        startswith(a, "--") ||
            error("unexpected argument `$a` (use --key value or --key=value)")
        body = a[3:end]
        if occursin('=', body)
            k, v = split(body, '='; limit = 2)
            opts[String(k)] = String(v); i += 1
        else
            i < length(args) || error("missing value for --$body")
            opts[body] = args[i + 1]; i += 2
        end
    end
    return opts
end

# Read the persisted worker secret, generating + storing one (mode 600) on first
# run so workers keep authenticating across restarts with no env vars to manage.
function persisted_worker_secret(state_dir::AbstractString)
    mkpath(state_dir)
    f = joinpath(state_dir, "worker_secret")
    if isfile(f)
        s = strip(read(f, String)); isempty(s) || return String(s)
    end
    s = bytes2hex(rand(UInt8, 32))
    write(f, s); chmod(f, 0o600)
    @info "BonitoAgents: generated a new worker secret" file = f
    return s
end

# HTTP routes
#
# /install        — sniffs `User-Agent` and serves either the bash or PS1
#                   wrapper. PowerShell's Invoke-RestMethod sets a UA that
#                   contains the literal "PowerShell"; curl/wget/everything
#                   else falls through to the bash wrapper.
# /install.sh     — always bash wrapper. Useful when /install's sniff guesses
#                   wrong, or when fetched from a browser to inspect.
# /install.ps1    — always PowerShell wrapper. Same.
# /install.jl     — the cross-platform Julia installer the wrappers fetch.
function add_install_routes!(srv::Bonito.Server, public_url::String, worker_secret::String)
    Bonito.route!(srv, "/install.jl" => function(context)
        script = render_install_script(INSTALL_SCRIPT, public_url, worker_secret)
        HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body=script)
    end)
    Bonito.route!(srv, "/install.sh" => function(context)
        body = render_install_script(INSTALL_SH, public_url, worker_secret)
        HTTP.Response(200, ["Content-Type" => "text/x-shellscript; charset=utf-8"], body=body)
    end)
    Bonito.route!(srv, "/install.ps1" => function(context)
        body = render_install_script(INSTALL_PS1, public_url, worker_secret)
        HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body=body)
    end)
    Bonito.route!(srv, "/install" => function(context)
        ua   = String(HTTP.header(context.request, "User-Agent", ""))
        is_ps = occursin("PowerShell", ua)
        body = render_install_script(is_ps ? INSTALL_PS1 : INSTALL_SH,
                                     public_url, worker_secret)
        ctype = is_ps ? "text/plain; charset=utf-8" :
                        "text/x-shellscript; charset=utf-8"
        HTTP.Response(200, ["Content-Type" => ctype], body=body)
    end)
end

# ── ACP wire-frame log routes ────────────────────────────────────────────────
#
# /acp-log            — HTML index of projects that have an acp.jsonl
# /acp-log/<pid>      — the raw JSONL (one {"ts","dir","msg"} envelope per
#                       line), append-only, written by `acp_frame_logger`.
#                       Refresh the tab to see new frames.
#
# Served straight from disk (state_dir/chats/<pid>/acp.jsonl) so logs are
# readable even when no live ChatModel exists for the project. Legacy
# project-id-less chats (<cwd>/.bonitoAgents) are deliberately NOT exposed.
function add_acp_log_routes!(srv::Bonito.Server, state::ServerState)
    index_handler = function(context)
        chats_root = joinpath(state.state_dir, "chats")
        ids = isdir(chats_root) ?
            filter(id -> isfile(joinpath(chats_root, id, "acp.jsonl")),
                   sort!(readdir(chats_root))) :
            String[]
        items = map(ids) do id
            p = get(state.projects[], id, nothing)
            label = esc_html(p === nothing ? id : "$(p.name) ($id)")
            "<li><a href=\"/acp-log/$id\">$label</a></li>"
        end
        body = isempty(items) ?
            "<p>No ACP logs yet — open a chat and send a message.</p>" :
            "<ul>" * join(items) * "</ul>"
        html = "<!doctype html><html><head><meta charset=\"utf-8\">" *
               "<title>ACP wire logs</title></head>" *
               "<body><h1>ACP wire logs</h1>$body</body></html>"
        HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], body=html)
    end
    # Both slash variants — String routes match the URI path exactly, so
    # "/acp-log/" (what a browser autocompletes to) needs its own entry.
    Bonito.route!(srv, "/acp-log"  => index_handler)
    Bonito.route!(srv, "/acp-log/" => index_handler)
    Bonito.route!(srv, ACP_LOG_ROUTE_RE => function(context)
        acp_log_response(state, String(context.match.captures[1]))
    end)
end

# `request.target` includes the query string, hence the `($|\?)` arm; the
# `/?` tolerates a trailing slash after the id. The charset (no `.`, no `/`)
# makes path traversal impossible.
const ACP_LOG_ROUTE_RE = r"^/acp-log/([A-Za-z0-9_-]+)/?(?:$|\?)"

# Plain function (no live HTTP server needed) so tests can call it directly.
function acp_log_response(state::ServerState, project_id::AbstractString)
    # Defense-in-depth: the route regex already constrains the charset, but
    # never join an unvalidated id into a filesystem path.
    occursin(r"^[A-Za-z0-9_-]+$", project_id) ||
        return HTTP.Response(404, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "invalid project id\n")
    path = joinpath(state.state_dir, "chats", String(project_id), "acp.jsonl")
    isfile(path) ||
        return HTTP.Response(404, ["Content-Type" => "text/plain; charset=utf-8"],
                             body = "no ACP log for project '$project_id'\n")
    return HTTP.Response(200,
        ["Content-Type"  => "text/plain; charset=utf-8",
         "Cache-Control" => "no-cache"],
        body = read(path, String))
end

esc_html(s::AbstractString) = replace(s,
    "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

# Substitute the server URL + shared secret + git rev into a templated install
# script. install.jl guards against being run with the `{{ }}` placeholders
# intact, so a raw fetch of any asset (bypassing these routes) fails loudly.
function render_install_script(template::AbstractString,
                                 public_url::String, worker_secret::String)
    bonito_url, bonito_rev = current_bonito_install_spec()
    replace(template,
        "{{SERVER_URL}}"    => public_url,
        "{{WORKER_SECRET}}" => worker_secret,
        "{{REV}}"           => current_repo_rev(),
        "{{BONITO_URL}}"    => bonito_url,
        "{{BONITO_REV}}"    => bonito_rev,
    )
end

"""
    current_repo_rev() -> String

Branch (or sha) the server is currently running from, used to template the
worker `install.jl` so a fresh `curl … | sh` lands the workers on the exact
same revision the server is serving. Lets a dev iterate on a feature branch
without users needing to know its name — they just re-run the curl one-liner.

Resolves in order:

  1. `BONITOAGENTS_INSTALL_REV` env var (escape hatch for ops who want to pin
     workers to a stable tag while running the server from `main`).
  2. The monorepo's checked-out branch (best-effort via `git rev-parse
     --abbrev-ref HEAD`; falls back to the exact sha when the repo is in
     detached-HEAD state).
  3. Fallback `"main"` if we can't locate the monorepo (e.g. the package
     was installed via `Pkg.add` from the registry — no git working tree).

Called per request so a `git checkout` on the server side propagates to the
next worker install without restarting.
"""
function current_repo_rev()
    override = get(ENV, "BONITOAGENTS_INSTALL_REV", "")
    isempty(override) || return override

    pkg = pkgdir(@__MODULE__)
    pkg === nothing && return "main"
    # `pkgdir` returns `<monorepo>/BonitoAgents`; the monorepo (where `.git`
    # lives) is one level up. `.git` may be a directory (normal clone) or a
    # file (submodule / worktree); both count.
    repo_root = abspath(pkg, "..")
    return _git_head_ref_of(repo_root, "main")
end

# Helper: best-effort `(branch | sha)` for a working-tree path. Returns
# `default` when the path isn't a git checkout or git refuses to answer.
function _git_head_ref_of(path::AbstractString, default::AbstractString)
    ispath(joinpath(path, ".git")) || return default
    try
        branch = strip(read(`git -C $path rev-parse --abbrev-ref HEAD`, String))
        branch == "HEAD" && return strip(read(`git -C $path rev-parse HEAD`, String))
        return String(branch)
    catch e
        @debug "_git_head_ref_of: git resolve failed" path exception=e
        return default
    end
end

"""
    current_bonito_install_spec() -> (url::String, rev::String)

The `(url, rev)` pair the worker should pin Bonito at, so the worker's eval
sessions (which `BonitoMCP` proxies through) use the SAME Bonito version
the server ships its dashboard with — without that, a fresh worker installed
via `curl … | sh` resolves Bonito off the registry and the remote-app
protocol (proxy frames, dial-back, `id_prefix`) drifts vs. the server's.

Resolution order, mirroring `current_repo_rev`:

  1. `BONITOAGENTS_BONITO_URL` + `BONITOAGENTS_BONITO_REV` env vars
     (ops can pin workers to a published tag while the server itself
     dev-tracks a path).
  2. The active project's `[sources]` `Bonito = {url, rev}` literal
     (the normal case when the monorepo's Project.toml pins a feature
     branch).
  3. `[sources]` `Bonito = {path = "..."}` (the dev case where Bonito is
     dev'd next to the monorepo): walk into the path and derive
     `url = remote.origin.url`, `rev = current branch | sha`. This is
     what makes `git checkout` on the dev's Bonito propagate to workers.
  4. Fallback `(github.com/SimonDanisch/Bonito.jl, "main")`.
"""
function current_bonito_install_spec()
    url_env = get(ENV, "BONITOAGENTS_BONITO_URL", "")
    rev_env = get(ENV, "BONITOAGENTS_BONITO_REV", "")
    (!isempty(url_env) && !isempty(rev_env)) && return (url_env, rev_env)

    default_url = "https://github.com/SimonDanisch/Bonito.jl.git"
    default_rev = "master"
    bonito_uuid = Base.UUID("824d6782-a2ef-11e9-3a09-e5662e0c26f8")

    # 1. Project file `[sources]` literal — the common monorepo case.
    project_file = Base.active_project()
    if project_file !== nothing
        try
            proj = Pkg.Types.read_project(project_file)
            src = get(proj.sources, "Bonito", nothing)
            if src !== nothing && haskey(src, "url")
                return (String(src["url"]),
                        String(get(src, "rev", default_rev)))
            elseif src !== nothing && haskey(src, "path")
                p = String(src["path"])
                abs_p = isabspath(p) ? p :
                        normpath(joinpath(dirname(project_file), p))
                got = _spec_from_git_path(abs_p, default_url, default_rev)
                got === nothing || return got
            end
        catch e
            @debug "current_bonito_install_spec: read_project failed" exception=e
        end
    end

    # 2. Manifest's resolved Bonito entry. Covers two cases the `[sources]`
    # path above misses: (a) the outer dev project Pkg.develop'd Bonito so
    # there's no project-level `[sources]` block, only a path in the
    # manifest; (b) Bonito is `Pkg.add`'d directly from a git url+rev (so
    # `git_source` / `git_revision` come through populated). For path-tracked,
    # walk the working tree the same way as the `[sources]` path branch.
    try
        deps = Pkg.dependencies()
        if haskey(deps, bonito_uuid)
            info = deps[bonito_uuid]
            if info.git_source !== nothing && info.git_revision !== nothing
                return (String(info.git_source), String(info.git_revision))
            end
            if info.is_tracking_path && info.source isa AbstractString
                got = _spec_from_git_path(String(info.source),
                                          default_url, default_rev)
                got === nothing || return got
            end
        end
    catch e
        @debug "current_bonito_install_spec: dependencies probe failed" exception=e
    end

    return (default_url, default_rev)
end

# Resolve a working-tree path into a `(remote_url, branch_or_sha)` pair.
# Returns `nothing` if the path isn't a usable git checkout — callers fall
# back to their own defaults.
function _spec_from_git_path(path::AbstractString,
                              default_url::AbstractString,
                              default_rev::AbstractString)
    isdir(path) || return nothing
    try
        remote = strip(read(`git -C $path config --get remote.origin.url`, String))
        rev    = _git_head_ref_of(path, default_rev)
        url    = isempty(remote) ? default_url : String(remote)
        return (url, rev)
    catch e
        @debug "_spec_from_git_path: probe failed" path exception=e
        return nothing
    end
end

# WebSocket routes (worker-side connection terminus). Each closure captures
# `state` so the route handler picks up the same instance the dashboard reads
# from / the chat writes into.
function add_worker_ws_routes!(srv::Bonito.Server, state::ServerState)
    Bonito.HTTPServer.websocket_route!(srv, "/worker-ws"   => (_ctx, ws) ->
        handle_worker_control(state, ws))
    Bonito.HTTPServer.websocket_route!(srv, "/worker-acp"  => (_ctx, ws) ->
        handle_worker_acp(state, ws))
    Bonito.HTTPServer.websocket_route!(srv, "/transfer-ws" => (_ctx, ws) ->
        handle_transfer_ws(state, ws))
    # Eval workers (BonitoMCP) dial here to be driven for interactive app proxying.
    Bonito.HTTPServer.websocket_route!(srv, "/eval-ws" => (_ctx, ws) ->
        handle_eval_ws(state, ws))
    # The BonitoMCP stdio process itself dials here — the control channel the
    # per-tool eval interrupt rides on (see remote_app.jl `MCP_CTRL`).
    Bonito.HTTPServer.websocket_route!(srv, "/mcp-ws" => (_ctx, ws) ->
        handle_mcp_ctrl_ws(state, ws))
end

# ── Shared links ─────────────────────────────────────────────────────────────
# A file on a worker, for anyone with the link, for as long as the worker is
# online: `https://<server>/s/<token>/`.
#
#   * A markdown file becomes a page: the server reads it from the worker and
#     renders it (the chat's renderer); the images and videos it embeds come
#     from the worker the same way, under the link (`/s/<token>/<relative path>`,
#     so the file's own relative references resolve). Only files the markdown
#     references are served, never the rest of its folder. Scripts are off
#     (Content-Security-Policy), so raw HTML in the file cannot run code.
#   * Any other file: a page with the chat's viewer for it (`file_viewer`) and a
#     Download button (`share_bar`). Under the link are the file and what it
#     names inside its project (`file_references`), nothing else; opened alone,
#     a file runs sandboxed (`share_file_response`).
#   * A Julia file whose value is a Bonito app (or any value an eval would show
#     live: a plot, a DataFrame, `App() do … md"…$(slider)…" end`) becomes a live
#     page: a SHARE HOST on the worker (an eval host under the pseudo chat
#     `SHARES_PROJECT`, one per worker, spawned on first use) evaluates the file
#     in its project's environment and parks the value like an eval result
#     (`RemoteProxy.share_value`); every viewer mounts their own render of it
#     through that session's live-render bridge (`RemoteRef`), the way a chat
#     shows an eval result. The file is evaluated again when it changed.
#
# The token is the permission; a password can be added on top. Behind a tunnel
# the login gate lets through `/s/…`, and for an open app page its websocket and
# the assets it registered, nothing else (`is_share_target`). Behind the Caddy
# login proxy only `/s/…` is open (Caddy cannot tell a share page's websocket
# from the dashboard's): there an app link needs a logged-in viewer, and a file
# link serves the file itself (`serves_viewer`).

const SHARES_PROJECT = "__shares__"
const SHARE_ROUTE_RE = r"^/s/([0-9a-f]{32})(/[^?#]*)?(?:$|\?)"
const SHARE_TARGET_RE = r"^/s/[0-9a-f]{32}(?:/[^?#]*)?$"
# The first open of an app link may start Julia on its worker, then load the
# app's packages (WGLMakie takes a minute on its own).
const SHARE_APP_TIMEOUT_S = 600.0
const SHARE_MARKDOWN_MAX_BYTES = 5 * 1024 * 1024

shares_file(s::ServerState) = joinpath(s.state_dir, "shares.json")

ShareLink(d::AbstractDict) = ShareLink(String(d["id"]), String(d["owner"]), String(d["worker_id"]),
    String(d["path"]), String(get(d, "env_path", "")), String(d["title"]),
    String(get(d, "password_salt", "")), String(get(d, "password_hash", "")), DateTime(d["created"]),
    String(get(d, "project_id", "")), String(get(d, "result_ref", "")))

Base.Dict(l::ShareLink) = Dict("id" => l.id, "owner" => l.owner, "worker_id" => l.worker_id,
    "path" => l.path, "env_path" => l.env_path, "title" => l.title,
    "password_salt" => l.password_salt, "password_hash" => l.password_hash,
    "created" => string(l.created), "project_id" => l.project_id, "result_ref" => l.result_ref)

record_key(l::ShareLink) = l.id

share_token(state::ServerState, id::AbstractString) =
    bytes2hex(SHA.hmac_sha256(state.url_key, codeunits("share\0" * id)))[1:32]

"The link to a share, as the server's public address names it."
share_url(state::ServerState, l::ShareLink) = root_state(state).base_url[] * "/s/" * share_token(state, l.id) * "/"

function load_shares!(s::ServerState)
    reg = s.shares
    lock(reg.lock) do
        load_records!(reg.links[], shares_file(s), "shares.json", ShareLink)
        empty!(reg.tokens)
        for id in keys(reg.links[])
            reg.tokens[share_token(s, id)] = id
        end
    end
    return nothing
end

save_shares!(s::ServerState) = lock(s.shares.lock) do
    atomic_write_json(shares_file(s), [Dict(l) for l in values(s.shares.links[])]; mode = 0o600)
end

share_by_token(state::ServerState, token::AbstractString) = lock(state.shares.lock) do
    id = get(state.shares.tokens, String(token), nothing)
    id === nothing ? nothing : get(state.shares.links[], id, nothing)
end

# What a file is shared as, by its extension.
abstract type ShareKind end
struct MarkdownShare <: ShareKind end
struct AppShare <: ShareKind end
struct ViewShare <: ShareKind end

function share_kind(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    ext in (".md", ".markdown") && return MarkdownShare()
    ext == ".jl" && return AppShare()
    return ViewShare()
end

share_kind(l::ShareLink) = isempty(l.result_ref) ? share_kind(l.path) : AppShare()

kind_label(::MarkdownShare) = "markdown page"
kind_label(::AppShare) = "app"
kind_label(::ViewShare) = "viewer page"

# ── Passwords ────────────────────────────────────────────────────────────────
# PBKDF2-HMAC-SHA256: a leaked shares.json must not give the passwords away cheaply.

function share_password_hash(password::AbstractString, salt::AbstractString; rounds::Int = 100_000)
    key = Vector{UInt8}(codeunits(password))
    u = SHA.hmac_sha256(key, vcat(hex2bytes(salt), UInt8[0, 0, 0, 1]))
    t = copy(u)
    for _ in 2:rounds
        u = SHA.hmac_sha256(key, u)
        t .⊻= u
    end
    return bytes2hex(t)
end

function password_fields(password::AbstractString)
    isempty(password) && return ("", "")
    salt = bytes2hex(rand(Random.RandomDevice(), UInt8, 16))
    return (salt, share_password_hash(password, salt))
end

# The cookie a correct password leaves, for this link and this password only.
unlock_cookie_name(l::ShareLink) = "bt_share_" * l.id[1:12]
unlock_cookie_value(state::ServerState, l::ShareLink) =
    bytes2hex(SHA.hmac_sha256(state.url_key, codeunits("unlock\0" * l.id * "\0" * l.password_hash)))

function share_unlocked(state::ServerState, l::ShareLink, request::HTTP.Request)
    isempty(l.password_hash) && return true
    want = unlock_cookie_name(l) * "=" * unlock_cookie_value(state, l)
    for (k, v) in request.headers
        lowercase(k) == "cookie" || continue
        any(part -> strip(part) == want, split(v, ';')) && return true
    end
    return false
end

# ── Making, changing and ending links ───────────────────────────────────────

"""
    create_share!(state, owner, worker_id, path; env_path = "", title = "", password = "") -> ShareLink

Share `path` on the worker. A markdown file is checked to exist; a Julia file is
evaluated once, so a broken app is an error here rather than for the first
viewer. `env_path` is the project an app runs in; by default the nearest folder
above the file with a Project.toml.
"""
function create_share!(state::ServerState, owner::AbstractString, worker_id::AbstractString,
                       path::AbstractString; env_path::AbstractString = "",
                       title::AbstractString = "", password::AbstractString = "",
                       project_id::AbstractString = "")
    w = get(state.workers[], String(worker_id), nothing)
    (w === nothing || !isopen(w)) && error("the worker is offline")
    kind = share_kind(path)
    info = stat_worker_path(state, w.worker_id, path)
    info.isfile || error("$(path) is not a file on $(w.name)")
    salt, hash = password_fields(password)
    env = kind isa AppShare && isempty(env_path) ? project_env_of(state, w.worker_id, path) : String(env_path)
    l = ShareLink(bytes2hex(rand(Random.RandomDevice(), UInt8, 16)), String(owner), w.worker_id,
                  String(path), env, isempty(title) ? splitext(basename(path))[1] : String(title),
                  salt, hash, now(UTC), String(project_id), "")
    check_share(kind, state, l, info)
    reg = state.shares
    lock(reg.lock) do
        reg.links[][l.id] = l
        reg.tokens[share_token(state, l.id)] = l.id
        save_shares!(state)
    end
    notify(reg.links)
    @info "shared link created" owner worker = w.name path kind = kind_label(kind) password = !isempty(hash)
    return l
end

check_share(::MarkdownShare, state::ServerState, l::ShareLink, info) =
    info.size <= SHARE_MARKDOWN_MAX_BYTES ||
        error("$(basename(l.path)) is $(format_bytes(info.size)); a shared page can be at most $(format_bytes(SHARE_MARKDOWN_MAX_BYTES))")

check_share(::ViewShare, state::ServerState, l::ShareLink, info) = nothing

function check_share(::AppShare, state::ServerState, l::ShareLink, info)
    share_app!(state, l)
    return nothing
end

# The nearest folder above `path` that holds a Project.toml ("" if none does).
function project_env_of(state::ServerState, worker_id::AbstractString, path::AbstractString)
    dir = dirname(path)
    for _ in 1:12
        isempty(dir) && break
        stat_worker_path(state, String(worker_id), joinpath(dir, "Project.toml")).isfile && return dir
        up = dirname(dir)
        up == dir && break
        dir = up
    end
    return ""
end

function revoke_share!(state::ServerState, id::AbstractString)
    reg = state.shares
    gone = lock(reg.lock) do
        haskey(reg.links[], id) || return false
        delete!(reg.links[], id)
        delete!(reg.tokens, share_token(state, id))
        save_shares!(state)
        true
    end
    gone && notify(reg.links)
    return gone
end

function set_share_password!(state::ServerState, id::AbstractString, password::AbstractString)
    reg = state.shares
    lock(reg.lock) do
        l = get(reg.links[], id, nothing)
        l === nothing && error("that link is gone")
        salt, hash = password_fields(password)
        reg.links[][id] = ShareLink(l.id, l.owner, l.worker_id, l.path, l.env_path, l.title,
                                  salt, hash, l.created, l.project_id, l.result_ref)
        save_shares!(state)
    end
    notify(reg.links)
    return nothing
end

# Who may change a link: its owner, and admins.
may_manage(::Nothing, l::ShareLink) = true
may_manage(user::User, l::ShareLink) = is_admin(user) || l.owner == user.name

# ── The login gate ──────────────────────────────────────────────────────────

"""
    is_share_target(shares, target) -> Bool

May `target` pass the login gate for a shared link: `/s/<token>…` (the route
checks the token), the websocket of an open app page, or an asset one of those
pages or a share host's bridge registered.
"""
function is_share_target(reg::ShareRegistry, target::AbstractString)
    path = String(first(split(target, '?'; limit = 2)))
    if startswith(path, "/s/")
        occursin(SHARE_TARGET_RE, path) || return false
        # No way out of the link: no `.`/`..` segments, spelled or escaped.
        return !any(seg -> seg in (".", ".."), split(HTTP.unescapeuri(path), '/'))
    end
    startswith(path, "/assets/") && return share_asset(reg, path)
    sid = path[2:end]
    (isempty(sid) || occursin('/', sid)) && return false
    return lock(() -> haskey(reg.pages, sid), reg.lock)
end

function share_asset(reg::ShareRegistry, path::AbstractString)
    sessions, hosts, checks = lock(reg.lock) do
        (collect(values(reg.pages)), [b.assets for b in values(reg.bridges)],
         collect(values(reg.asset_checks)))
    end
    any(s -> registers_asset(s, path), sessions) && return true
    any(a -> registers_asset(a, path), hosts) && return true
    return any(check -> check(path), checks)
end

function registers_asset(s::Bonito.Session, path::AbstractString)
    registers_asset(s.asset_server, path) && return true
    # Subsessions are made (and dropped) under the root's deletion lock.
    children = lock(() -> collect(values(s.children)), Bonito.deletion_lock(Bonito.root_session(s)))
    return any(c -> registers_asset(c, path), children)
end
registers_asset(a::Bonito.ChildAssetServer, path::AbstractString) =
    lock(() -> haskey(a.files, path), a.parent.lock)
registers_asset(::Bonito.AbstractAssetServer, ::AbstractString) = false

# ── The route ────────────────────────────────────────────────────────────────

function add_share_routes!(srv::Bonito.Server, state::ServerState)
    Bonito.route!(srv, SHARE_ROUTE_RE => context -> share_response(state, context))
end

function share_response(state::ServerState, context)
    token, rest = context.match.captures
    request = context.request
    l = share_by_token(state, token)
    l === nothing && return share_notice(404, "Link not found", "This link does not exist, or it was revoked.")
    if !share_unlocked(state, l, request)
        request.method == "POST" && return unlock_share(state, l, request, String(token))
        return password_page(l, "")
    end
    # Relative references resolve against the directory the page is in.
    rest === nothing && return HTTP.Response(302, ["Location" => "/s/$(token)/", "Cache-Control" => "no-store"])
    w = get(state.workers[], l.worker_id, nothing)
    (w === nothing || !isopen(w)) && return share_notice(503, l.title,
        "The computer this is shared from is offline right now. Try again later.")
    # A worker read or a file that will not parse is the viewer's error page,
    # never a stack trace for whoever has the link.
    try
        rest == "/" && return share_root(share_kind(l), state, l, request, context)
        return share_file(state, l, request, HTTP.unescapeuri(String(rest[2:end])))
    catch e
        e isa InterruptException && rethrow()
        @warn "shared link failed" path = l.path rest exception = (e, catch_backtrace())
        return share_notice(502, l.title, "This link could not be served right now. Try again later.")
    end
end

# The link itself: its page, or the file when another page loads it as an
# image, a clip or a sound (`Sec-Fetch-Dest`), or where no viewer page can work.
share_root(kind::ShareKind, state::ServerState, l::ShareLink, request::HTTP.Request, context) =
    share_page(kind, state, l, context)

function share_root(kind::ViewShare, state::ServerState, l::ShareLink, request::HTTP.Request, context)
    embedded = HTTP.header(request, "Sec-Fetch-Dest", "document") in ("image", "video", "audio")
    response = embedded || !serves_viewer(state.auth) ?
        share_file_response(state, request, l.worker_id, normpath(l.path)) :
        share_page(kind, state, l, context)
    HTTP.setheader(response, "Vary" => "Sec-Fetch-Dest")
    return response
end

# A viewer page is a Bonito app, so its websocket and assets must reach the
# server. Caddy opens only `/s/…` to people without a login: there the link
# serves the file, and the browser shows it as it shows any file.
serves_viewer(::AuthMode) = true
serves_viewer(::ProxyAuth) = false

function unlock_share(state::ServerState, l::ShareLink, request::HTTP.Request, token::String)
    given = get(form_fields(String(request.body)), "password", "")
    if share_password_hash(given, l.password_salt) != l.password_hash
        sleep(1.0)                     # guessing stays slow
        return password_page(l, "That password is not right.")
    end
    # SameSite=None where it can be (it needs Secure): a shared HTML page runs in
    # a frame with an origin of its own, and a Lax cookie is not sent with the
    # requests for its pictures and styles.
    site = startswith(root_state(state).base_url[], "https://") ? "SameSite=None; Secure" : "SameSite=Lax"
    cookie = "$(unlock_cookie_name(l))=$(unlock_cookie_value(state, l)); Path=/s/$(token)/; HttpOnly; $(site)"
    return HTTP.Response(303, ["Location" => "/s/$(token)/", "Set-Cookie" => cookie, "Cache-Control" => "no-store"])
end

password_page(l::ShareLink, error_message::AbstractString) = share_notice(isempty(error_message) ? 200 : 403,
    l.title, (isempty(error_message) ? "" : "<p class=\"err\">$(esc_html(error_message))</p>") * """
    <form method="post"><label>Password<input type="password" name="password" autofocus></label>
    <button type="submit">Open</button></form>""")

share_notice(status::Int, title::AbstractString, body::AbstractString) =
    invite_page(status, title, startswith(body, "<") ? body : "<p>$(esc_html(body))</p>")

# A file under the link: one the page uses, from the worker.
share_file(state::ServerState, l::ShareLink, request::HTTP.Request, rel::String) =
    share_file(share_kind(l), state, l, request, rel)

share_file(::AppShare, state::ServerState, l::ShareLink, request::HTTP.Request, rel::String) =
    share_notice(404, "Not found", "This link shares only its result.")

# The markdown file itself (its Download button) and what it references.
function share_file(::MarkdownShare, state::ServerState, l::ShareLink, request::HTTP.Request, rel::String)
    allowed = markdown_references(read_share_markdown(state, l))
    push!(allowed, basename(l.path))
    normpath(rel) in allowed || return not_used()
    return share_file_response(state, request, l.worker_id, normpath(joinpath(dirname(l.path), rel)))
end

function share_file(::ViewShare, state::ServerState, l::ShareLink, request::HTTP.Request, rel::String)
    root, file = link_root(state, l), normpath(l.path)
    path = normpath(joinpath(root, rel))
    link_serves(root, file, file_references(state, l.worker_id, file), path) || return not_used()
    return share_file_response(state, request, l.worker_id, path)
end

not_used() = share_notice(404, "Not found", "The page does not use this file.")

# A file under a link, from the worker. Opened as a page of its own, it must not
# run code on the server's origin, where the dashboard is: an HTML file's
# scripts run in an origin of their own, nothing else runs at all. The header
# changes nothing for a file the page loads as a picture, a clip or data.
function share_file_response(state::ServerState, request::HTTP.Request, worker_id::String, path::String)
    response = serve_worker_file(state, request, worker_id, path)
    HTTP.setheader(response, "X-Content-Type-Options" => "nosniff")
    csp = share_file_policy(MIME(Bonito.file_mimetype(path)))
    csp === nothing || HTTP.setheader(response, "Content-Security-Policy" => csp)
    return response
end

share_file_policy(::MIME) = "sandbox"
share_file_policy(::MIME"text/html") = "sandbox allow-scripts"
# Chromium's PDF viewer refuses a sandboxed document; a PDF runs no page script.
share_file_policy(::MIME"application/pdf") = nothing

# A shared page's header: the file's name and a Download button for `url`.
share_bar(l::ShareLink, url::AbstractString) =
    FileToolbar(isempty(l.title) ? basename(l.path) : l.title;
        metadata=basename(l.path),
        actions=(DOM.a("Download"; href=url,download=basename(l.path),
                    class="bw-btn bw-btn-secondary bw-btn-sm bt-share-download"),
            share_media_actions(file_kind(l.path))), class="bt-share-bar")

share_media_actions(::FileKind) = ()
share_media_actions(kind::Union{ImageFile,VideoFile}) =
    Menu(media_menu_items(kind isa VideoFile;download=false);title="File actions")

# A file's path under its link, relative to the page.
share_href(rel::AbstractString) = join(HTTP.escapeuri.(splitpath(rel)), "/")

# ── Markdown pages ───────────────────────────────────────────────────────────

# The start of a worker file, at most `max_bytes` of it; `info` is its stat.
function read_worker_bytes(state::ServerState, worker_id::AbstractString, info; max_bytes::Integer)
    info.isfile || error("$(info.path) is gone")
    info.range_reads || error("the worker is too old to serve shared pages; update it")
    n = min(info.size, max_bytes)
    bytes = UInt8[]
    while length(bytes) < n
        append!(bytes, read_worker_file_range(state, worker_id, info.path, length(bytes),
                                              min(256 * 1024, n - length(bytes))))
    end
    return bytes
end

function read_share_markdown(state::ServerState, l::ShareLink)
    info = stat_worker_path(state, l.worker_id, l.path)
    info.size <= SHARE_MARKDOWN_MAX_BYTES || error("$(l.path) grew over the limit for a shared page")
    return String(read_worker_bytes(state, l.worker_id, info; max_bytes = info.size))
end

# A file an HTML tag names: its `src`, `href` or `poster`.
const HTML_REFERENCE_RE = r"\b(?:src|href|poster)\s*=\s*[\"']([^\"']+)[\"']"i

"""
    markdown_references(text) -> Set{String}

The files a markdown text embeds or links to by relative path (normalized, with
no query or fragment): its images and links, and the `src`/`href`/`poster` of
raw HTML (a `<video>`, say). What a shared page may serve from its folder.
"""
function markdown_references(text::AbstractString)
    refs = Set{String}()
    add(url) = begin
        path = relative_reference(url)
        path === nothing && return
        p = normpath(path)
        startswith(p, "..") || push!(refs, p)
    end
    ast = lock(() -> MARKDOWN_PARSER(defuse_table_rule(String(text))), MARKDOWN_LOCK)
    for (node, entering) in ast
        entering || continue
        t = node.t
        if t isa CM.Image || t isa CM.Link
            add(t.destination)
        elseif t isa CM.HtmlBlock || t isa CM.HtmlInline
            for m in eachmatch(HTML_REFERENCE_RE, node.literal)
                add(m[1])
            end
        end
    end
    return refs
end

# A page without scripts, so the bar is the viewer pages' one, written out.
function share_page(::MarkdownShare, state::ServerState, l::ShareLink, context)
    body = markdown_html(read_share_markdown(state, l), no_link)
    css = read(Bonito.local_path(Bonito.MarkdownCSS), String)
    bar = sprint(show, MIME"text/html"(), file_toolbar_node(share_bar(l, share_href(basename(l.path)))))
    html = """<!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>$(esc_html(l.title))</title><style>$(css)
        $(css_text(ShareStyles))
        body { margin: 0; background: #fff; }
        main.bt-share-page { max-width: 52rem; padding: 1.5rem 1.25rem 4rem; }
        img, video { max-width: 100%; }
        </style></head><body><main class="bt-share-page">$(bar)$(body)</main></body></html>"""
    return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8",
        # No scripts: raw HTML in the file is for layout and media only.
        # `font-src data:`: the inlined markdown CSS embeds its link-anchor
        # font as a data URL, which `default-src 'self'` refused on every page.
        "Content-Security-Policy" => "default-src 'self'; script-src 'none'; object-src 'none'; " *
                                     "style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; " *
                                     "base-uri 'self'; form-action 'none'; frame-ancestors 'none'",
        "Cache-Control" => "no-cache", "Referrer-Policy" => "no-referrer"]; body = html)
end

# ── Viewer pages ─────────────────────────────────────────────────────────────

# What a viewer link serves files under: the chat's project folder (as the chat
# allows references within it), or the file's own folder for a link without one.
# The file sits at its path there, so its relative references resolve.
function link_root(state::ServerState, l::ShareLink)
    file = normpath(l.path)
    p = get(state.projects[], l.project_id, nothing)
    (p === nothing || p.worker_id != l.worker_id) && return dirname(file)
    return reference_folder(p, file)
end

# Whether a viewer link may serve `path`: the shared file, or a file it names,
# and only inside the root (a model may name `../../.ssh/id_ed25519`).
link_serves(root::AbstractString, file::AbstractString, refs, path::AbstractString) =
    Bonito.is_path_contained(root, path) && (path == file || path in refs)

# The local files a reference list names, next to `from` (a scheme, an absolute
# path or a `data:` uri names none).
local_references(from::AbstractString, refs) =
    String[normpath(joinpath(dirname(from), r)) for r in (relative_reference(String(u)) for u in refs) if r !== nothing]

# Files the browser fetches next to this one: a glTF's buffers and images, an
# OBJ's material libraries and their textures, an HTML page's sources and links.
file_references(state::ServerState, worker_id::AbstractString, path::AbstractString) =
    file_references(Val(Symbol(lstrip(lowercase(splitext(path)[2]), '.'))), state, worker_id, path)

file_references(::Val, ::ServerState, ::AbstractString, ::AbstractString) = String[]

# A file that names others, whole; `nothing` if it is gone or too big (a glTF
# that size embeds its data).
function read_naming_file(state::ServerState, worker_id::AbstractString, path::AbstractString)
    info = stat_worker_path(state, worker_id, path)
    (info.isfile && info.size <= SHARE_MARKDOWN_MAX_BYTES) || return nothing
    return String(read_worker_bytes(state, worker_id, info; max_bytes = info.size))
end

function file_references(::Val{:gltf}, state::ServerState, worker_id::AbstractString, path::AbstractString)
    text = read_naming_file(state, worker_id, path)
    text === nothing && return String[]
    gltf = JSON.parse(text)
    uris = [String(x["uri"]) for key in ("buffers", "images") for x in get(gltf, key, Any[])
            if x isa AbstractDict && haskey(x, "uri")]
    return local_references(path, uris)
end

# An HTML page's sources and links: its pictures, styles and scripts.
function file_references(::Val{:html}, state::ServerState, worker_id::AbstractString, path::AbstractString)
    text = read_naming_file(state, worker_id, path)
    text === nothing && return String[]
    return local_references(path, [m[1] for m in eachmatch(HTML_REFERENCE_RE, text)])
end
file_references(::Val{:htm}, state::ServerState, worker_id::AbstractString, path::AbstractString) =
    file_references(Val(:html), state, worker_id, path)

# `mtllib` comes first in an OBJ, which can be hundreds of megabytes of vertices.
function file_references(::Val{:obj}, state::ServerState, worker_id::AbstractString, path::AbstractString)
    info = stat_worker_path(state, worker_id, path)
    info.isfile || return String[]
    head = String(read_worker_bytes(state, worker_id, info; max_bytes = 64 * 1024))
    libs = [strip(l[8:end]) for l in eachline(IOBuffer(head)) if startswith(l, "mtllib ")]
    mtls = local_references(path, libs)
    return [mtls; (t for mtl in mtls for t in mtl_textures(state, worker_id, mtl))...]
end

# The texture maps a material library names (the file is the last word of a
# `map_Kd`, `bump`, `disp`, `decal`, `norm` or `refl` line, after its options).
function mtl_textures(state::ServerState, worker_id::AbstractString, mtl::AbstractString)
    text = read_naming_file(state, worker_id, mtl)
    text === nothing && return String[]
    names = [last(split(l)) for l in eachline(IOBuffer(text))
             if occursin(r"^\s*(map_\w+|bump|disp|decal|norm|refl)\s+\S", l)]
    return local_references(mtl, names)
end

# The page: the file's name, a download button and the file's viewer. The
# browser reads the file at its path under the link, relative to this page.
function share_page(::ViewShare, state::ServerState, l::ShareLink, context)
    url = share_href(relpath(normpath(l.path), link_root(state, l)))
    kind = file_kind(l.path)
    # Read here, on the request's task: a parsed kind is a worker round-trip.
    viewer = viewer_or_error(() -> file_viewer(kind, share_input(kind, state, l, url), l.path, PanelView()), l.path)
    app = App(; title = l.title) do session
        open_share_page!(state, Bonito.root_session(session))
        # Bonito.MarkdownCSS: a notebook's markdown cells.
        return DOM.div(Bonito.MarkdownCSS, ShareStyles, share_bar(l, url),
                       DOM.div(viewer; class = "bt-share-viewer");
                       class = "bt-share-page")
    end
    return Bonito.HTTPServer.apply_handler(app, context)
end

# What the page's viewer is given: the file's url under the link, or its
# content, read from the worker. HTML written into it is left out (`FileContent`).
share_input(::StreamedKind, state::ServerState, l::ShareLink, url::AbstractString) = url

function share_input(kind::ParsedKind, state::ServerState, l::ShareLink, url::AbstractString)
    info = stat_worker_path(state, l.worker_id, l.path)
    bytes = read_worker_bytes(state, l.worker_id, info; max_bytes = share_read_bytes(kind, info.size))
    return FileContent(bytes; size = info.size, raw_html = false)
end

# All of it, if its kind can show that much; of a binary only what its dump shows.
share_read_bytes(kind::ParsedKind, size::Integer) = check_view_size(kind, size)
share_read_bytes(::BinaryFile, size::Integer) = min(size, HEXDUMP_BYTES)

# A page the login gate lets through, with its websocket and the assets its
# session registered (`is_share_target`), until it closes.
function open_share_page!(state::ServerState, root::Bonito.Session)
    reg = state.shares
    lock(() -> (reg.pages[root.id] = root), reg.lock)
    on(root.on_close) do _
        lock(reg.lock) do
            delete!(reg.pages, root.id)
            delete!(reg.asset_checks, root.id)
        end
    end
    return root
end

# ── App pages ────────────────────────────────────────────────────────────────

const ShareStyles = Bonito.Styles(
    BASE_STYLES, FILE_TOOLBAR_CSS...,
    # Light, as the viewers in them are: Bonito's own theme follows a dark
    # desktop otherwise (see `html:root` in styles.jl BASE_STYLES for why `html:`).
    CSS("html:root", "color-scheme" => "light"),
    CSS(".bt-share-page", "max-width" => "1200px", "margin" => "0 auto", "padding" => "var(--bw-space-4)",
        "font-family" => "system-ui, sans-serif", "color" => "var(--bw-text)"),
    CSS(".bt-share-note", "color" => "var(--bw-text-muted)", "padding" => "2rem 0"),
    CSS(".bt-share-bar", "border"=>"1px solid var(--bw-border)",
        "border-radius"=>"var(--bw-radius) var(--bw-radius) 0 0"),
    # The viewer fills the window below the bar.
    CSS(".bt-share-viewer", "display" => "flex", "flex-direction" => "column",
        "height" => "calc(100vh - 96px)", "min-height" => "320px",
        "border" => "1px solid var(--bw-border)", "border-top"=>"0",
        "border-radius" => "0 0 var(--bw-radius) var(--bw-radius)", "overflow" => "hidden"))

# A style sheet as CSS text, for a page without Bonito (`share_page(::MarkdownShare)`).
# Sheets with an `Asset` in them need a session to name its url.
css_text(styles::Bonito.Styles) =
    sprint(io -> foreach(css -> Bonito.render_style(io, nothing, "", css), values(styles.styles)))

function share_page(::AppShare, state::ServerState, l::ShareLink, context)
    app = App(; title = l.title) do session
        root = open_share_page!(state, Bonito.root_session(session))
        content = Observable{Any}(DOM.div("Starting the app…"; class = "bt-share-note"))
        Base.errormonitor(@async content[] = share_app_content(state, l, root))
        return DOM.div(ShareStyles,FileToolbar(l.title;metadata="Live result"),content; class = "bt-share-page")
    end
    return Bonito.HTTPServer.apply_handler(app, context)
end

function share_app_content(state::ServerState, l::ShareLink, root::Bonito.Session)
    try
        if !isempty(l.result_ref)
            eb = shared_result_bridge(state, l.project_id, l.result_ref)
            call_ctrl(eb, "has_result"; sub = l.result_ref) === true ||
                error("This shared result was closed or its Julia session ended.")
            prefix = ensure_page_root!(root, eb)
            # Never publish the chat bridge's entire asset registry: other evals
            # on it may contain private data. Only this viewer's mounted tree.
            check = path -> shared_result_asset(eb, prefix, path)
            lock(() -> (state.shares.asset_checks[root.id] = check), state.shares.lock)
            return RemoteRef(eb, l.result_ref, "", false)
        end
        return share_app!(state, l)
    catch e
        e isa InterruptException && rethrow()
        @warn "shared app did not start" path = l.path worker = l.worker_id exception = (e, catch_backtrace())
        return DOM.div("The app could not start: " * first(split(sprint(showerror, e), '\n'));
                       class = "bt-share-note")
    end
end

share_bridge_key(prefix::AbstractString) = "share\0" * prefix

"""
    share_app!(state, l) -> RemoteRef

The app of link `l`, live: its worker's share host evaluates the file (again,
if it changed) and parks the value; the reference mounts it for a viewer.
"""
function share_app!(state::ServerState, l::ShareLink)
    w = get(state.workers[], l.worker_id, nothing)
    (w === nothing || !isopen(w)) && error("the worker is offline")
    ws = ensure_eval_host!(state, SHARES_PROJECT, "shared links", w)
    resp = host_rpc(state, ws, "share_app", Dict{String,Any}("path" => l.path, "env_path" => l.env_path);
                    timeout = SHARE_APP_TIMEOUT_S)
    prefix = String(resp["prefix"])
    eb = eval_bridge_for(state, share_bridge_key(prefix))
    eb === nothing && error("the app's live connection from $(w.name) is not up")
    reg = state.shares
    lock(() -> (reg.bridges[prefix] = ShareBridge(w.worker_id, eb.asset_host)), reg.lock)
    return RemoteRef(eb, String(resp["holder"]), "", false)
end

# A channel a worker's share host opened (`accept_worker_channel`): its control
# channel, or one of its sessions' live-render bridges, filed by prefix so the
# apps of several environments coexist.
function accept_share_host_channel(state::ServerState, worker_id::String, ch::WorkerLink.LinkChannel,
                                   header::AbstractDict)
    get(header, "host", false) === true ||
        return WorkerLink.abort(ch, "only a share host speaks for shared links")
    kind = get(header, "kind", "")
    if kind == "mcp"
        accept_channel(ch)
        serve_mcp_channel(state, MCPChannel(state, ch, SHARES_PROJECT, worker_id))
    elseif kind == "eval"
        prefix = String(get(header, "prefix", ""))
        serve_eval_bridge(state, ch, share_bridge_key(prefix), prefix)
    else
        WorkerLink.abort(ch, "a share host opens no '$(kind)' channels")
    end
    return nothing
end

share_bridge_keys(state::ServerState, worker_id::AbstractString) =
    lock(state.shares.lock) do
        [share_bridge_key(p) for (p, b) in state.shares.bridges if b.worker_id == worker_id]
    end

"""
    share_project_file!(state, project_id, path) -> String

The file panel's share button: a link to `path` on the chat's worker, made by
whoever clicked. Returns the link.
"""
function share_project_file!(state::ServerState, project_id::AbstractString, path::AbstractString)
    p = get(state.projects[], String(project_id), nothing)
    p === nothing && error("the chat is gone")
    path = worker_isabspath(path) ? normalize_worker_path(path) : worker_join(p.worker_path, path)
    return share_url(state, create_share!(state, acting_owner(state), p.worker_id, path; project_id = p.id))
end

function shared_result_bridge(state::ServerState, project_id::AbstractString, ref::AbstractString)
    eb = bridge_for_ref(state, project_id, ref)
    (eb === nothing || eb.ws === nothing || eb.prefix != first(split(ref, '/'; limit = 2))) &&
        error("This result is no longer live. Run it again to share it.")
    return eb
end

function shared_result_asset(eb::EvalBridge, prefix::String, path::AbstractString)
    eb.ws === nothing && return false
    registers_asset(eb.asset_host, path) || return false
    try
        return call_ctrl(eb, "has_asset"; root = prefix, key = String(path[9:end]),
                         timeout = 5.0, redial_grace = 0.0) === true
    catch e
        e isa InterruptException && rethrow()
        @warn "could not verify shared result asset" path exception = (e, catch_backtrace())
        return false
    end
end

"""
    share_result!(state, project_id, payload) -> String

Share the already displayed eval result, without executing its code again.
The link lasts while that Julia session and its result remain alive.
"""
function share_result!(state::ServerState, project_id::AbstractString, payload::AbstractString)
    p = get(state.projects[], String(project_id), nothing)
    p === nothing && error("the chat is gone")
    desc = result_descriptor(payload)
    (desc === nothing || desc.errored) && error("There is no successful live result to share.")
    eb = shared_result_bridge(state, project_id, desc.ref)
    call_ctrl(eb, "has_result"; sub = desc.ref) === true ||
        error("This result was closed. Run it again to share it.")
    # Remote evals live under <project>\0<worker>; use the bridge's worker,
    # including for bt_julia_continue, whose inputs need not name one.
    parts = split(eb.project_id, '\0'; limit = 2)
    wid = length(parts) == 2 ? String(parts[2]) : p.worker_id
    l = ShareLink(bytes2hex(rand(Random.RandomDevice(), UInt8, 16)), acting_owner(state),
                  wid, "", "", "Julia result", "", "", now(UTC), String(project_id), desc.ref)
    reg = state.shares
    lock(reg.lock) do
        reg.links[][l.id] = l
        reg.tokens[share_token(state, l.id)] = l.id
        save_shares!(state)
    end
    notify(reg.links)
    return share_url(state, l)
end

const ShareControlStyles = Bonito.Styles(
    # Output controls also travel with detached results. Carry the shared
    # tokens and button rules rather than depending on the dashboard sheet.
    BASE_STYLES,
    CSS(".bt-share-control", "display" => "flex", "align-items" => "center",
        "gap" => "var(--bw-space-2)", "flex-wrap" => "wrap",
        "font-size" => "var(--bw-font-size-ui)"),
    CSS(".bt-share-control [hidden]", "display" => "none"),
    CSS(".bt-share-error", "white-space" => "pre-wrap", "overflow-wrap" => "anywhere",
        "color" => "var(--bw-error)"),
    CSS(".bt-share-error:empty", "display" => "none"))

struct ShareControl{F}
    create::F
    hint::String
    progress::Union{Nothing,Observable}
end
ShareControl(create::F; hint::String, progress = nothing) where F = ShareControl(create, hint, progress)

# Render as a component so a result arriving AFTER the tool body mounted gets
# its own session/onload, rather than adding onload to an already ready session.
# Each browser owns its click and resulting link.
function Bonito.jsrender(session::Bonito.Session, control::ShareControl)
    progress = control.progress
    request = Observable(0)
    answer = Observable("")
    pending = Ref(false)
    on(session, request) do _
        pending[] && return
        if progress !== nothing && is_busy_running(progress[])
            safe_set!(answer, "error:Something else is running in this window. Wait for it to finish.")
            return
        end
        pending[] = true
        progress === nothing || busy_start!(progress, "Sharing result")
        Base.errormonitor(@async try
            safe_set!(answer, "link:" * control.create())
            progress === nothing || busy_done!(progress, "Shared link created")
        catch e
            e isa InterruptException && rethrow()
            detail = sprint(showerror, e)
            @warn "sharing result failed" exception = (e, catch_backtrace())
            safe_set!(answer, "error:" * detail)
            progress === nothing || busy_fail!(progress, "Could not share result", detail)
        finally
            pending[] = false
        end)
    end
    button = DOM.button("Share"; type = "button", disabled = true,
                        class = "bw-btn bw-btn-sm bw-btn-secondary bt-share-result",
                        title = control.hint, ariaLabel = "Share this output")
    link = DOM.a("Open shared link"; class = "bw-menu-item bt-share-link",
                 hidden = true, target = "_blank", rel = "noopener noreferrer")
    copy = DOM.button("Copy link"; type = "button", hidden = true,
                      class = "bw-menu-item bt-share-copy")
    menu = Menu([link,copy];title="Sharing options",label="Share")
    options = DOM.div(menu;class="bt-share-options",hidden=true)
    error = DOM.span(; class = "bt-share-error", role = "status")
    node = DOM.div(ShareControlStyles, button, options, error; class = "bt-share-control")
    Bonito.onload(session, node, js"""root => {
        const button = $(button), link = $(link), copy = $(copy), error = $(error), options=$(options);
        const request = $(request), answer = $(answer), menu_open = $(menu.open);
        button.addEventListener('click', e => {
            e.preventDefault(); e.stopPropagation();
            button.disabled = true; error.textContent = '';
            request.notify(request.value + 1);
        });
        copy.addEventListener('click', e => {
            e.preventDefault(); e.stopPropagation();
            menu_open.notify(false);
            ($(COPY_TEXT_JS))(link.href).catch(() => {
                error.textContent = 'Could not copy automatically. Open the link and copy its address.';
            });
        });
        answer.on(value => {
            if (value.startsWith('link:')) {
                link.href = value.slice(5); link.title = value.slice(5);
                link.hidden = false; copy.hidden = false; button.hidden = true; options.hidden=false;
                menu_open.notify(true);
            } else if (value.startsWith('error:')) {
                error.textContent = value.slice(6); button.disabled = false;
            }
        });
        button.disabled = false;
    }""")
    return Bonito.jsrender(session, node)
end

# ── bt_share ─────────────────────────────────────────────────────────────────

# An absolute path on a worker of either kind (`/home/…`, `C:/…`, `C:\…`).
worker_isabspath(p::AbstractString) = startswith(p, '/') || occursin(r"^[A-Za-z]:[\\/]", p)

function dev_op(state::ServerState, ::Val{:share}, args::AbstractDict, caller::String)
    p = get(state.projects[], caller, nothing)
    p === nothing && error("sharing a file needs a chat (this control channel carries no project id)")
    path = String(strip(String(get(args, "path", ""))))
    isempty(path) && error("`path` (the file to share) is required")
    path = worker_isabspath(path) ? normalize_worker_path(path) : worker_join(p.worker_path, path)
    l = create_share!(state, p.owner, p.worker_id, path; project_id = p.id,
                      env_path = String(get(args, "env_path", "")),
                      title = String(get(args, "title", "")),
                      password = String(get(args, "password", "")))
    return Dict{String,Any}("url" => share_url(state, l), "kind" => kind_label(share_kind(l.path)),
                            "path" => l.path, "title" => l.title, "env_path" => l.env_path,
                            "password" => !isempty(l.password_hash))
end

# ── Settings ─────────────────────────────────────────────────────────────────

"""
    shares_section(session, state)

The Settings page's shared links: whoever made them sees their own (admins all),
opens or copies a link, sets or removes its password, or ends it.
"""
function shares_section(session::Bonito.Session, state::ServerState)
    status = Observable("")
    revoke = Observable("")
    password = Observable(["", ""])
    on(session, revoke) do id
        isempty(id) && return
        admin_action!(status, () -> revoke_share!(state, id) ? "link ended" : "the link was already gone")
    end
    on(session, password) do (id, pw)
        isempty(id) && return
        admin_action!(status, () -> (set_share_password!(state, id, pw);
                                     isempty(pw) ? "password removed" : "password set"))
    end
    table = map(session, state.shares.links, state.workers) do links, workers
        mine = sort!([l for l in values(links) if may_manage(state.user, l)]; by = l -> l.created, rev = true)
        isempty(mine) && return DOM.div("No shared links. Use Share on a file or Julia result, " *
                                        "or ask an agent to share a file with bt_share.";
                                        class = "bt-admin-muted")
        rows = map(mine) do l
            url = share_url(state, l)
            w = get(workers, l.worker_id, nothing)
            where_ = (w === nothing ? l.worker_id : w.name) * (w !== nothing && isopen(w) ? "" : " (offline)")
            DOM.tr(DOM.td(DOM.a(l.title; href = url, target = "_blank", class = "bt-account-name"),
                          DOM.div(kind_label(share_kind(l)), " · ", where_, ": ",
                                  isempty(l.result_ref) ? l.path : "live result (until its Julia session ends)";
                                  class = "bt-account-detail bt-admin-muted")),
                   DOM.td(Dates.format(l.created, "yyyy-mm-dd")),
                   DOM.td(DOM.input(type = "password",
                                    placeholder = isempty(l.password_hash) ? "no password" : "password set",
                                    class = "bt-share-password"),
                          DOM.button("Set"; class = "bw-btn bw-btn-sm bw-btn-secondary",
                                     onclick = js"""event => {
                                         const f = event.target.parentElement.querySelector('.bt-share-password');
                                         $(password).notify([$(l.id), f.value]); f.value = ''; }""")),
                   DOM.td(DOM.button("Copy link"; class = "bw-btn bw-btn-sm bw-btn-secondary",
                                     onclick = js"event => navigator.clipboard.writeText($(url))"),
                          DOM.button("End"; class = "bw-btn bw-btn-sm bw-btn-secondary",
                                     onclick = js"event => $(revoke).notify($(l.id))")))
        end
        DOM.table(DOM.tr(DOM.th("Link"), DOM.th("Made"), DOM.th("Password (empty: none)"), DOM.th("")),
                  rows; class = "bt-admin-table bt-shares-table")
    end
    return DOM.div(
        AdminStyles,
        DOM.div(DOM.h2("Shared links"); class = "bt-section"),
        DOM.div(
            DOM.div("Anyone with a link sees the shared file or app while its computer is online. " *
                    "Live result links also require the original Julia session and result to stay open.";
                    class = "bt-admin-muted"),
            admin_line(status, "bt-admin-status"),
            table;
            class = "bt-card"))
end

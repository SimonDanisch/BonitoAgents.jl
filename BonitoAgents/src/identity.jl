# ── Who is on the other end ──────────────────────────────────────────────────
# Four ways to run a server, from least to most set up:
#   * one machine (`LocalAuth`: the desktop app, `bonito-agents server`): it
#     listens on localhost, and whoever reaches it is the local user, the one
#     account, an admin; so is every worker (they run on this machine too);
#   * a network it trusts (`NetworkAuth`: `bonito-agents server --host 0.0.0.0`):
#     still no login, whoever reaches it is that one admin, but a worker comes
#     in with a credential "Add worker" issued, which the server checks itself;
#   * behind a tunnel (`TunnelAuth`, install_server.sh): something else brings
#     HTTPS to 127.0.0.1 (cloudflared for one), and people log in through
#     Authelia, which the server asks about every request itself (tunnel.jl);
#   * behind the login proxy (`ProxyAuth`, install_server.sh): Caddy brings
#     HTTPS and asks Authelia.
# The last two are a `LoginAuth`: logins, accounts and groups.
#
# Behind the proxy BonitoAgents does no authentication itself. The installer
# sets up Caddy + Authelia, the server listens on 127.0.0.1 and every request
# reaches it through Caddy, which has already authenticated it:
#   * people through Authelia's login (password + second factor), which
#     forwards who they are as `Remote-User`/`-Email`/`-Name`/`-Groups`;
#   * workers through the Basic credential "Add worker" issued them, which Caddy
#     checks on `/w` and forwards as `Remote-User`.
# Caddy strips those headers from whatever a client sends, so only it can set
# them. Listening on localhost is not enough to make them Caddy's: any process on
# the machine reaches localhost, an agent on a worker there included. So Caddy
# also adds a key only it and the server know (`PROXY_KEY_HEADER`, from the
# server's state dir into the Caddyfile, both readable by the service user
# alone), and a request without it carries no identity, whatever it claims.
# Caddy's own admin API is off for the same reason: it would hand out the key.
#
# The types live here, ahead of state.jl; what acts on a ServerState is in
# accounts.jl.

"A person using the dashboard."
struct User
    name::String
    email::String
    display_name::String
    groups::Vector{String}
end

is_admin(u::User) = "admins" in u.groups

abstract type AuthMode end

"No login: whoever reaches the server is `user`, the one account, an admin."
abstract type OpenAuth <: AuthMode end

"A server only this machine can reach (it listens on localhost): everyone is `user`, and every worker is let in."
struct LocalAuth <: OpenAuth
    user::User
end

"""
A server on a network it trusts, without the login proxy: everyone who reaches it
is `user`, as on one machine, and a worker comes in with a credential "Add worker"
issued, which the server checks itself. Nothing is encrypted (plain HTTP) and
nobody logs in; for more than a trusted network, the proxy (install_server.sh).
"""
struct NetworkAuth <: OpenAuth
    user::User
end

"The account of whoever runs the server."
function local_user()
    name = get(ENV, "USER", get(ENV, "USERNAME", "local"))
    return User(name, "", name, ["admins"])
end

LocalAuth() = LocalAuth(local_user())
NetworkAuth() = NetworkAuth(local_user())

"""
    ProxyConfig

What the installer set up in front of the server (`<state_dir>/proxy.json`). The
server owns the login's configuration: Authelia's users database, which the
accounts page edits; Authelia's own configuration, with the secrets it keeps in
its state dir; and behind the proxy the Caddyfile, where it adds and revokes
worker credentials (`apply_proxy!`). Authelia's files live together in
`dirname(users_file)`.
"""
Base.@kwdef struct ProxyConfig
    domain::String                          # the dashboard, e.g. team.example.com
    # Authelia's login portal behind the proxy, e.g. auth.team.example.com;
    # behind a tunnel it is under the dashboard's own name (`PORTAL_PATH`).
    auth_domain::String = ""
    admin::String                           # the installer's account: owns what predates owners
    # Where the server listens on 127.0.0.1: what Caddy, or the tunnel, forwards to.
    port::Int = 8038
    authelia_port::Int = 9091
    caddy_bin::String = "caddy"
    authelia_bin::String = "authelia"
    caddyfile::String = ""                  # behind the proxy only
    users_file::String
    acme_email::String = ""
    # Where HTTPS comes from: "acme" (Caddy, with Let's Encrypt: what a public
    # server wants), "internal" (Caddy's own certificate authority: a LAN, or a
    # test on one machine; browsers and workers must be told to trust it), or
    # "tunnel" (something in front of this machine, e.g. cloudflared; no Caddy).
    tls::String = "acme"
    # Another ACME directory, e.g. Let's Encrypt's staging one while trying an
    # install out, so repeated attempts don't run into its rate limits.
    acme_ca::String = ""
    # The port browsers use for HTTPS: Caddy's, or behind a tunnel the tunnel's.
    https_port::Int = 443
    http_port::Int = 80
    # Where workers reach the proxy when not under `domain`, e.g. an address on
    # the LAN; it answers `/w` and the installer there, nothing else.
    worker_address::String = ""
    # Authelia can send mail (`<state_dir>/smtp.json`): the one-time code that
    # confirms someone's new second factor reaches them directly. Without it
    # Authelia writes that code to a file (`notifications_file`), which admins
    # read on the dashboard.
    smtp::Bool = false
    function ProxyConfig(domain, auth_domain, admin, port, authelia_port, caddy_bin, authelia_bin,
                         caddyfile, users_file, acme_email, tls, acme_ca, https_port, http_port,
                         worker_address, smtp)
        tls in ("acme", "internal", "tunnel") ||
            error("proxy.json: tls is \"acme\", \"internal\" or \"tunnel\" (got \"$(tls)\")")
        return new(domain, auth_domain, admin, port, authelia_port, caddy_bin, authelia_bin,
                   caddyfile, users_file, acme_email, tls, acme_ca, https_port, http_port,
                   worker_address, smtp)
    end
end

function ProxyConfig(d::AbstractDict)
    kw = Dict{Symbol,Any}()
    for f in fieldnames(ProxyConfig)
        haskey(d, String(f)) && (kw[f] = d[String(f)])
    end
    return ProxyConfig(; kw...)
end

"`https://host`, with the port when it is not HTTPS's own."
public_origin(cfg::ProxyConfig, host::AbstractString) =
    "https://" * host * (cfg.https_port == 443 ? "" : ":$(cfg.https_port)")

"""
    ProxyWriter()

How the server writes the proxy's files (`apply_proxy!`): one writer at a time,
so the last file written is the last state rendered, and when Authelia's users
database last changed. Authelia ignores a change to it within half a second of
its last reread (its watcher's cooldown), so writes to it keep `spacing` seconds
apart.
"""
mutable struct ProxyWriter
    const lock::ReentrantLock
    const spacing::Float64
    users_written::Float64
end

ProxyWriter(; spacing::Real = 1.0) = ProxyWriter(ReentrantLock(), Float64(spacing), 0.0)

"People log in through Authelia (`config`): accounts, groups, invites."
abstract type LoginAuth <: AuthMode end

"A server behind the Caddy + Authelia proxy the installer set up."
struct ProxyAuth <: LoginAuth
    config::ProxyConfig
    # What Caddy adds to every request it forwards: the proof it came through Caddy.
    key::String
    function ProxyAuth(config::ProxyConfig, key::AbstractString)
        isempty(key) && error("a proxy key is required: without it anyone on this machine could claim any identity")
        config.tls == "tunnel" && error("proxy.json: behind a tunnel there is no Caddy (tls \"tunnel\")")
        (isempty(config.auth_domain) || isempty(config.caddyfile)) &&
            error("proxy.json: behind the proxy auth_domain and caddyfile are required")
        return new(config, String(key))
    end
end

"""
A server behind a tunnel, which brings HTTPS to it on 127.0.0.1 (cloudflared, or
anything that forwards `https://<domain>` there): no Caddy. The server asks
Authelia about every request itself, and serves Authelia's login page under
its own name (`PORTAL_PATH`), so the tunnel needs one host name and one port.
Workers come in with a credential "Add worker" issued, which the server checks
itself, as on a trusted network. See tunnel.jl.
"""
struct TunnelAuth <: LoginAuth
    config::ProxyConfig
    function TunnelAuth(config::ProxyConfig)
        config.tls == "tunnel" || error("proxy.json: a tunnel is tls \"tunnel\" (got \"$(config.tls)\")")
        isempty(config.worker_address) ||
            error("proxy.json: worker_address is for Caddy; behind a tunnel workers come through it")
        return new(config)
    end
end

# Where Authelia's login page is behind a tunnel: under the dashboard's own name.
const PORTAL_PATH = "/authelia"

"The dashboard's address, as browsers and workers reach it."
dashboard_url(auth::LoginAuth) = public_origin(auth.config, auth.config.domain)

"Authelia's login page."
portal_url(auth::ProxyAuth) = public_origin(auth.config, auth.config.auth_domain)
portal_url(auth::TunnelAuth) = dashboard_url(auth) * PORTAL_PATH

# The login cookie has to cover the dashboard and the portal: behind the proxy
# the portal's parent domain, behind a tunnel the one name both share.
cookie_domain(auth::ProxyAuth) = String(split(auth.config.auth_domain, '.'; limit = 2)[end])
cookie_domain(auth::TunnelAuth) = auth.config.domain

# Where Authelia listens, and under which path it serves.
authelia_address(auth::ProxyAuth) = "tcp://127.0.0.1:$(auth.config.authelia_port)/"
authelia_address(auth::TunnelAuth) = "tcp://127.0.0.1:$(auth.config.authelia_port)$(PORTAL_PATH)"

const PROXY_KEY_HEADER = "X-BonitoAgents-Proxy"

"""
    auth_mode(state_dir; host = "127.0.0.1") -> AuthMode

How the server at `state_dir` runs, decided by how it is started: listening on
more than localhost, for a trusted network (`NetworkAuth`); otherwise behind the
proxy the installer set up, if it did (`proxy.json`), or for this machine alone
(`LocalAuth`). The proxy's settings stay where they are when it is not used, so
going back to it is starting the server without `--host` again.
"""
function auth_mode(state_dir::AbstractString; host::AbstractString = "127.0.0.1")
    f = joinpath(state_dir, "proxy.json")
    if !is_loopback(host)
        isfile(f) && @info "Listening on $(host), for a trusted network: the login proxy's settings " *
                           "($(f)) are not used; start without --host to run behind it again."
        return NetworkAuth()
    end
    isfile(f) || return LocalAuth()
    d = JSON.parsefile(f)
    d["smtp"] = isfile(smtp_file(state_dir))
    cfg = ProxyConfig(d)
    cfg.tls == "tunnel" && return TunnelAuth(cfg)
    return ProxyAuth(cfg, bytes2hex(load_or_create_secret(state_dir, "proxy_key")))
end

# Authelia's mail settings, written by the installer (mode 600): address, username,
# password, sender.
smtp_file(state_dir::AbstractString) = joinpath(state_dir, "smtp.json")

"Did `request` come through Caddy? Only then do its identity headers mean anything."
from_proxy(auth::ProxyAuth, request) = HTTP.header(request, PROXY_KEY_HEADER, "") == auth.key

"The one the records from before owners existed belong to."
default_owner(auth::OpenAuth) = auth.user.name
default_owner(auth::LoginAuth) = auth.config.admin

# What Authelia says about who someone is, as Caddy (or the tunnel's gate) passes it on.
const IDENTITY_HEADERS = ("Remote-User", "Remote-Groups", "Remote-Email", "Remote-Name")

"""
    request_user(auth, request) -> Union{User,Nothing}

Who sent `request`: the local user, or whoever Authelia says it is. `nothing`
behind the proxy or a tunnel when the request carries no identity, i.e. it did
not come through Authelia.
"""
request_user(auth::OpenAuth, request) = auth.user

request_user(auth::ProxyAuth, request) = from_proxy(auth, request) ? identity_of(request) : nothing

# Behind a tunnel the gate in front of every route (tunnel.jl) drops whatever a
# client sent under these names and sets them from Authelia's answer alone.
request_user(::TunnelAuth, request) = identity_of(request)

function identity_of(request)
    name = String(strip(HTTP.header(request, "Remote-User", "")))
    isempty(name) && return nothing
    display = String(strip(HTTP.header(request, "Remote-Name", "")))
    groups = String[strip(g) for g in split(HTTP.header(request, "Remote-Groups", ""), ',')
                    if !isempty(strip(g))]
    return User(name, String(strip(HTTP.header(request, "Remote-Email", ""))),
                isempty(display) ? name : display, groups)
end

"""
    WorkerCredential

A worker's admission to `/w` ("Add worker"), and who issued it. `hash` is what
Caddy's `basic_auth` checks behind the proxy (bcrypt; `""` when issued without
the proxy, where there is no Caddy to make one); `digest` is what the server
checks itself on a trusted network or behind a tunnel (SHA-256 of the password: a random 24 bytes,
so no slow hash is needed; `""` on credentials from before it existed).
"""
struct WorkerCredential
    name::String
    hash::String
    owner::String
    created::DateTime
    digest::String
end

WorkerCredential(name, hash, owner, created) = WorkerCredential(name, hash, owner, created, "")

WorkerCredential(d::AbstractDict) =
    WorkerCredential(String(d["name"]), String(d["hash"]), String(d["owner"]), DateTime(d["created"]),
                     String(get(d, "digest", "")))

Base.Dict(c::WorkerCredential) = Dict("name" => c.name, "hash" => c.hash, "owner" => c.owner,
                                     "created" => string(c.created), "digest" => c.digest)

credential_digest(password::AbstractString) = bytes2hex(SHA.sha256(String(password)))

"""
    worker_credential(auth, request, credentials) -> Union{String,Nothing}

The credential a worker connection was admitted with: `""` on a local server
(nothing but this machine reaches it), the name the server checked itself on a
trusted network or behind a tunnel, the name Caddy checked behind the proxy, or
`nothing` when the connection names none the server still knows.
"""
worker_credential(::LocalAuth, request, credentials) = ""

# On a trusted network and behind a tunnel nothing checks a worker before the
# server does.
function worker_credential(::Union{NetworkAuth,TunnelAuth}, request, credentials::AbstractDict)
    given = basic_credential(request)
    given === nothing && return nothing
    c = get(credentials, given.name, nothing)
    (c === nothing || isempty(c.digest)) && return nothing
    return same_bytes(c.digest, credential_digest(given.password)) ? c.name : nothing
end

# The `name:password` a client sent as Basic auth (a worker's credential rides as
# its URL's userinfo), or `nothing`.
function basic_credential(request)
    header = HTTP.header(request, "Authorization", "")
    startswith(header, "Basic ") || return nothing
    decoded = try
        String(Base64.base64decode(strip(header[7:end])))
    catch e
        e isa ArgumentError || rethrow()   # not base64: no credential
        return nothing
    end
    name, sep, password = partition(decoded, ':')
    isempty(sep) && return nothing
    return (name = name, password = password)
end

# `split` into what is before and after the first `sep`, keeping empty parts.
function partition(s::AbstractString, sep::Char)
    i = findfirst(sep, s)
    i === nothing && return (String(s), "", "")
    return (String(s[1:prevind(s, i)]), string(sep), String(s[nextind(s, i):end]))
end

# Compares in time independent of where the two first differ.
same_bytes(a::AbstractString, b::AbstractString) =
    ncodeunits(a) == ncodeunits(b) &&
    reduce(|, (x ⊻ y for (x, y) in zip(codeunits(a), codeunits(b))); init = 0x00) == 0x00

function worker_credential(auth::ProxyAuth, request, credentials::AbstractDict)
    from_proxy(auth, request) || return nothing
    name = String(strip(HTTP.header(request, "Remote-User", "")))
    return haskey(credentials, name) ? name : nothing
end

"""
    Account

Someone who can log in: an entry of Authelia's users database, which the server
owns and renders from `accounts.json` (`render_users_yaml`). `password_hash` is
argon2id, the form Authelia checks.
"""
mutable struct Account
    name::String
    display_name::String
    email::String
    groups::Vector{String}
    disabled::Bool
    password_hash::String
end

Account(d::AbstractDict) = Account(String(d["name"]), String(d["display_name"]), String(d["email"]),
                                   Vector{String}(d["groups"]), d["disabled"] === true,
                                   String(d["password_hash"]))

Base.Dict(a::Account) = Dict("name" => a.name, "display_name" => a.display_name, "email" => a.email,
                             "groups" => a.groups, "disabled" => a.disabled,
                             "password_hash" => a.password_hash)

is_admin(a::Account) = "admins" in a.groups

"""
    Invite

A link that lets someone create their own account, once, before `expires`
(`/invite/<token>`). The server keeps only the token's SHA-256 (`id`), so the
link exists nowhere but with the admin who made it and the person it was sent to.
"""
struct Invite
    id::String
    groups::Vector{String}      # the new account's groups ("admins" makes an admin)
    created_by::String
    created::DateTime
    expires::DateTime
end

Invite(d::AbstractDict) = Invite(String(d["id"]), Vector{String}(d["groups"]), String(d["created_by"]),
                                 DateTime(d["created"]), DateTime(d["expires"]))

Base.Dict(i::Invite) = Dict("id" => i.id, "groups" => i.groups, "created_by" => i.created_by,
                            "created" => string(i.created), "expires" => string(i.expires))

invite_id(token::AbstractString) = bytes2hex(SHA.sha256(String(token)))

# What a persisted record is filed under.
record_key(c::WorkerCredential) = c.name
record_key(a::Account) = a.name
record_key(i::Invite) = i.id

# Account and group names: what Authelia, Caddy and a URL all take unquoted.
valid_name(name::AbstractString) = occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", name)

"Groups from what an admin typed: comma-separated names."
function parse_groups(text::AbstractString)
    groups = unique!(String[strip(g) for g in split(text, ',') if !isempty(strip(g))])
    for g in groups
        valid_name(g) || error("a group name is letters, digits, '.', '_' and '-' (got '$(g)')")
    end
    return groups
end

yaml_quote(s::AbstractString) = "'" * replace(String(s), "'" => "''") * "'"

"Authelia's users database for `accounts`."
function render_users_yaml(accounts)
    io = IOBuffer()
    println(io, "# Rendered by BonitoAgents from accounts.json; edits here are overwritten.")
    list = sort!(collect(accounts); by = a -> a.name)
    isempty(list) && (println(io, "users: {}"); return String(take!(io)))
    println(io, "users:")
    for a in list
        println(io, "  ", yaml_quote(a.name), ":")
        println(io, "    disabled: ", a.disabled)
        println(io, "    displayname: ", yaml_quote(a.display_name))
        println(io, "    password: ", yaml_quote(a.password_hash))
        println(io, "    email: ", yaml_quote(a.email))
        if isempty(a.groups)
            println(io, "    groups: []")
        else
            println(io, "    groups:")
            foreach(g -> println(io, "      - ", yaml_quote(g)), a.groups)
        end
    end
    return String(take!(io))
end

"""
    render_caddyfile(auth::ProxyAuth, credentials) -> String

The whole Caddy configuration: the dashboard behind Authelia, `/w` behind the
worker credentials, the installer and invite routes open, Authelia's portal.
Rendered by the server (`apply_proxy!`) whenever a credential is added or
revoked; Caddy rereads it when it changes (`caddy run --watch`).
"""
function render_caddyfile(auth::ProxyAuth, credentials)
    cfg = auth.config
    # A credential issued without the proxy has no hash Caddy could check: it
    # has to be issued again behind it.
    creds = sort!([c for c in credentials if !isempty(c.hash)]; by = c -> c.name)
    io = IOBuffer()
    println(io, "# Rendered by BonitoAgents from proxy.json and the worker credentials;")
    println(io, "# edits here are overwritten.")
    println(io, "{")
    println(io, "\t# Off: it would reconfigure Caddy for anyone on this machine, and show the proxy key.")
    println(io, "\tadmin off")
    isempty(cfg.acme_email) || println(io, "\temail ", cfg.acme_email)
    isempty(cfg.acme_ca) || println(io, "\tacme_ca ", cfg.acme_ca)
    cfg.https_port == 443 || println(io, "\thttps_port ", cfg.https_port)
    cfg.http_port == 80 || println(io, "\thttp_port ", cfg.http_port)
    # Caddy's own CA is trusted by whoever is told to, never installed system-wide.
    cfg.tls == "internal" && println(io, "\tskip_install_trust")
    println(io, "}")
    println(io)
    println(io, cfg.domain, " {")
    site_preamble(io, cfg)
    worker_routes(io, auth, creds)
    println(io)
    println(io, "\t# People: Authelia's login (password + second factor) in front of everything else.")
    println(io, "\thandle {")
    println(io, "\t\tforward_auth 127.0.0.1:", cfg.authelia_port, " {")
    println(io, "\t\t\turi /api/authz/forward-auth")
    println(io, "\t\t\tcopy_headers Remote-User Remote-Groups Remote-Email Remote-Name")
    println(io, "\t\t}")
    reverse_proxy(io, auth)
    println(io, "\t}")
    println(io, "}")
    println(io)
    println(io, cfg.auth_domain, " {")
    cfg.tls == "internal" && println(io, "\ttls internal")
    println(io, "\treverse_proxy 127.0.0.1:", cfg.authelia_port)
    println(io, "}")
    if !isempty(cfg.worker_address) && cfg.worker_address != cfg.domain
        println(io)
        println(io, "# Workers that reach the proxy under another name: `/w` and the installer only.")
        println(io, cfg.worker_address, " {")
        site_preamble(io, cfg)
        worker_routes(io, auth, creds)
        println(io, "\thandle {")
        println(io, "\t\trespond 404")
        println(io, "\t}")
        println(io, "}")
    end
    return String(take!(io))
end

function site_preamble(io::IO, cfg::ProxyConfig)
    cfg.tls == "internal" && println(io, "\ttls internal")
    println(io, "\t# Who a request is from: only Caddy may say.")
    for h in IDENTITY_HEADERS
        println(io, "\trequest_header -", h)
    end
    println(io)
end

# To the server, adding the key that proves the request came through Caddy (a
# client's own is replaced), plus `extra` header lines.
function reverse_proxy(io::IO, auth::ProxyAuth, extra::String...)
    println(io, "\t\treverse_proxy 127.0.0.1:", auth.config.port, " {")
    foreach(line -> println(io, "\t\t\t", line), extra)
    println(io, "\t\t\theader_up ", PROXY_KEY_HEADER, " ", auth.key)
    # A reload (every credential issued or revoked) would otherwise close every
    # WebSocket: each worker's link and each open dashboard tab. A revoked
    # worker is cut off by the server itself.
    println(io, "\t\t\tstream_close_delay 24h")
    println(io, "\t\t}")
end

function worker_routes(io::IO, auth::ProxyAuth, creds)
    println(io, "\t# Workers: one Basic credential each (\"Add worker\"); deleting one revokes it.")
    println(io, "\thandle /w {")
    if isempty(creds)
        println(io, "\t\trespond \"no worker credentials issued\" 403")
    else
        println(io, "\t\tbasic_auth {")
        foreach(c -> println(io, "\t\t\t", c.name, " ", c.hash), creds)
        println(io, "\t\t}")
        reverse_proxy(io, auth, "header_up Remote-User {http.auth.user.id}")
    end
    println(io, "\t}")
    println(io)
    println(io, "\t# Open to anyone: the worker installer holds no secret (a new machine fetches it")
    println(io, "\t# before it has a credential), and an invite link is its own proof.")
    println(io, "\t@public path /install /install.sh /install.ps1 /install.jl /invite/*")
    println(io, "\thandle @public {")
    reverse_proxy(io, auth)
    println(io, "\t}")
end

"""
    render_authelia_config(auth, secrets, smtp) -> String

Authelia's `configuration.yml`: the login for the dashboard's domain (a password
and a second factor), its users database in `users_file`, and nothing it could
change behind the server's back (its own password reset and change are off; the
server hands passwords out). `secrets` holds `jwt`, `session` and `storage`
(`authelia_secrets`); `smtp` is the mail settings, or `nothing` for none.
"""
function render_authelia_config(auth::LoginAuth, secrets, smtp::Union{AbstractDict,Nothing})
    cfg = auth.config
    q = yaml_quote
    dir = dirname(cfg.users_file)
    notifier = if smtp === nothing
        """
        notifier:
          filesystem:
            filename: $(q(notifications_file(cfg)))
        """
    else
        # Authelia would refuse to start while the mail server is unreachable,
        # which locks everyone out of the dashboard over a mail outage. Mail is
        # only needed to confirm a new second factor; that one action fails
        # instead.
        """
        notifier:
          disable_startup_check: true
          smtp:
            address: $(q("submission://$(smtp["host"]):$(smtp["port"])"))
            username: $(q(smtp["username"]))
            password: $(q(smtp["password"]))
            sender: $(q(smtp["sender"]))
        """
    end
    return """
        # Rendered by BonitoAgents from proxy.json; edits here are overwritten.
        server:
          address: $(q(authelia_address(auth)))
        log:
          level: 'info'
        totp:
          issuer: $(q(cfg.domain))
        webauthn:
          display_name: 'BonitoAgents'
        identity_validation:
          reset_password:
            jwt_secret: $(q(secrets.jwt))
        authentication_backend:
          file:
            path: $(q(cfg.users_file))
            watch: true
          # Every request sees the account as it is now: a disabled account or
          # changed groups take effect at once, not at the next login.
          refresh_interval: 'always'
          # Passwords are the server's (it owns the users file); these would write
          # it behind its back.
          password_reset:
            disable: true
          password_change:
            disable: true
        access_control:
          default_policy: 'deny'
          rules:
            - domain: $(q(cfg.domain))
              policy: 'two_factor'
        regulation:
          max_retries: 5
          find_time: '2 minutes'
          ban_time: '10 minutes'
        session:
          secret: $(q(secrets.session))
          cookies:
            - domain: $(q(cookie_domain(auth)))
              authelia_url: $(q(portal_url(auth)))
              default_redirection_url: $(q(dashboard_url(auth)))
        storage:
          encryption_key: $(q(secrets.storage))
          local:
            path: $(q(joinpath(dir, "db.sqlite3")))
        """ * notifier
end

# bcrypt, the form Caddy's `basic_auth` checks. The password goes in on stdin,
# never on a command line.
function caddy_hash(cfg::ProxyConfig, password::AbstractString)
    out = open(`$(cfg.caddy_bin) hash-password`, "r+") do io
        write(io, password, "\n")
        close(io.in)
        read(io, String)
    end
    hash = strip(last(split(strip(out), '\n')))
    startswith(hash, "\$2") || error("`caddy hash-password` answered: $(out)")
    return String(hash)
end

# Caddy's own reading of a Caddyfile: a file it would reject never replaces the
# one it serves.
function check_caddyfile(cfg::ProxyConfig, path::AbstractString)
    err = IOBuffer()
    success(pipeline(`$(cfg.caddy_bin) adapt --config $path --adapter caddyfile`; stdout = devnull, stderr = err)) ||
        error("Caddy rejects the new configuration: $(strip(last(split(strip(String(take!(err))), '\n'))))")
    return nothing
end

# A new random password and its argon2id digest, the form Authelia checks.
# Authelia generates both, so no password ever crosses a command line.
function authelia_random_password(cfg::ProxyConfig)
    out = read(`$(cfg.authelia_bin) crypto hash generate argon2 --random --random.length 20`, String)
    pw = match(r"Random Password:\s*(\S+)", out)
    digest = match(r"Digest:\s*(\S+)", out)
    (pw === nothing || digest === nothing) &&
        error("`authelia crypto hash generate` printed no password and digest: $(out)")
    return (password = String(pw[1]), hash = String(digest[1]))
end

is_loopback(host::AbstractString) = host in ("127.0.0.1", "::1", "localhost")

# A secret the server keeps in its state dir (mode 600), created on first use.
function load_or_create_secret(state_dir::AbstractString, name::AbstractString)
    mkpath(state_dir)
    f = joinpath(state_dir, name)
    if isfile(f)
        s = strip(read(f, String))
        isempty(s) || return hex2bytes(s)
    end
    key = rand(Random.RandomDevice(), UInt8, 32)
    atomic_write(io -> write(io, bytes2hex(key)), f; mode = 0o600)   # never readable by others
    return key
end

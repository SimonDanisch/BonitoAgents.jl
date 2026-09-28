# ── Who is on the other end ──────────────────────────────────────────────────
# BonitoAgents does no authentication itself. Behind the proxy the installer
# sets up (Caddy + Authelia, install_server.sh), the server listens on 127.0.0.1
# and every request reaches it through Caddy, which has already authenticated
# it:
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
# Without the proxy (the desktop app, the dev server, one machine) the server
# also listens on 127.0.0.1 only, and whoever can reach it is the local user:
# the one account, an admin.
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

"A server only this machine can reach: everyone is `user`."
struct LocalAuth <: AuthMode
    user::User
end

function LocalAuth()
    name = get(ENV, "USER", get(ENV, "USERNAME", "local"))
    return LocalAuth(User(name, "", name, ["admins"]))
end

"""
    ProxyConfig

What the installer set up in front of the server (`<state_dir>/proxy.json`). The
server owns the proxy's configuration: the Caddyfile, where it adds and revokes
worker credentials; Authelia's users database, which the accounts page edits;
and Authelia's own configuration, with the secrets it keeps in its state dir
(`apply_proxy!`). Authelia's files live together in `dirname(users_file)`.
"""
Base.@kwdef struct ProxyConfig
    domain::String                          # the dashboard, e.g. team.example.com
    auth_domain::String                     # Authelia's login portal, e.g. auth.team.example.com
    admin::String                           # the installer's account: owns what predates owners
    port::Int = 8038                        # where the server listens on 127.0.0.1
    authelia_port::Int = 9091
    caddy_bin::String = "caddy"
    authelia_bin::String = "authelia"
    caddyfile::String
    users_file::String
    acme_email::String = ""
    # Certificates: "acme" (Let's Encrypt, what a public server wants) or
    # "internal" (Caddy's own certificate authority: a LAN, or a test on one
    # machine; browsers and workers must be told to trust it).
    tls::String = "acme"
    # Another ACME directory, e.g. Let's Encrypt's staging one while trying an
    # install out, so repeated attempts don't run into its rate limits.
    acme_ca::String = ""
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
        tls in ("acme", "internal") || error("proxy.json: tls is \"acme\" or \"internal\" (got \"$(tls)\")")
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

"A server behind the Caddy + Authelia proxy the installer set up."
struct ProxyAuth <: AuthMode
    config::ProxyConfig
    # What Caddy adds to every request it forwards: the proof it came through Caddy.
    key::String
    function ProxyAuth(config::ProxyConfig, key::AbstractString)
        isempty(key) && error("a proxy key is required: without it anyone on this machine could claim any identity")
        return new(config, String(key))
    end
end

const PROXY_KEY_HEADER = "X-BonitoAgents-Proxy"

"The proxy the installer set up in front of the server at `state_dir`, if any."
function auth_mode(state_dir::AbstractString)
    f = joinpath(state_dir, "proxy.json")
    isfile(f) || return LocalAuth()
    d = JSON.parsefile(f)
    d["smtp"] = isfile(smtp_file(state_dir))
    return ProxyAuth(ProxyConfig(d), bytes2hex(load_or_create_secret(state_dir, "proxy_key")))
end

# Authelia's mail settings, written by the installer (mode 600): address, username,
# password, sender.
smtp_file(state_dir::AbstractString) = joinpath(state_dir, "smtp.json")

"Did `request` come through Caddy? Only then do its identity headers mean anything."
from_proxy(auth::ProxyAuth, request) = HTTP.header(request, PROXY_KEY_HEADER, "") == auth.key

"The one the records from before owners existed belong to."
default_owner(auth::LocalAuth) = auth.user.name
default_owner(auth::ProxyAuth) = auth.config.admin

"""
    request_user(auth, request) -> Union{User,Nothing}

Who sent `request`: the local user, or whoever the proxy says it is. `nothing`
behind the proxy when the request carries no identity, i.e. it did not come
through Authelia.
"""
request_user(auth::LocalAuth, request) = auth.user

function request_user(auth::ProxyAuth, request)
    from_proxy(auth, request) || return nothing
    name = String(strip(HTTP.header(request, "Remote-User", "")))
    isempty(name) && return nothing
    display = String(strip(HTTP.header(request, "Remote-Name", "")))
    groups = String[strip(g) for g in split(HTTP.header(request, "Remote-Groups", ""), ',')
                    if !isempty(strip(g))]
    return User(name, String(strip(HTTP.header(request, "Remote-Email", ""))),
                isempty(display) ? name : display, groups)
end

"A worker's admission to `/w`: which credential Caddy checked, and who issued it."
struct WorkerCredential
    name::String
    hash::String        # bcrypt, the form Caddy's `basic_auth` checks
    owner::String
    created::DateTime
end

WorkerCredential(d::AbstractDict) =
    WorkerCredential(String(d["name"]), String(d["hash"]), String(d["owner"]), DateTime(d["created"]))

Base.Dict(c::WorkerCredential) = Dict("name" => c.name, "hash" => c.hash, "owner" => c.owner,
                                     "created" => string(c.created))

"""
    worker_credential(auth, request, credentials) -> Union{String,Nothing}

The credential a worker connection was admitted with: `""` on a local server
(nothing but this machine reaches it), the name Caddy checked behind the proxy,
or `nothing` when the connection names none the server still knows.
"""
worker_credential(::LocalAuth, request, credentials) = ""

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
    creds = sort!(collect(credentials); by = c -> c.name)
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
    for h in ("Remote-User", "Remote-Groups", "Remote-Email", "Remote-Name")
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
    render_authelia_config(cfg, secrets, smtp) -> String

Authelia's `configuration.yml`: the login for `cfg.domain` (a password and a
second factor), its users database in `cfg.users_file`, and nothing it could
change behind the server's back (its own password reset and change are off; the
server hands passwords out). `secrets` holds `jwt`, `session` and `storage`
(`authelia_secrets`); `smtp` is the mail settings, or `nothing` for none.
"""
function render_authelia_config(cfg::ProxyConfig, secrets, smtp::Union{AbstractDict,Nothing})
    q = yaml_quote
    dir = dirname(cfg.users_file)
    # The login cookie has to cover the dashboard and the portal: the portal's
    # parent domain.
    cookie_domain = split(cfg.auth_domain, '.'; limit = 2)[end]
    notifier = if smtp === nothing
        """
        notifier:
          filesystem:
            filename: $(q(notifications_file(cfg)))
        """
    else
        """
        notifier:
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
          address: $(q("tcp://127.0.0.1:$(cfg.authelia_port)/"))
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
            - domain: $(q(cookie_domain))
              authelia_url: $(q(public_origin(cfg, cfg.auth_domain)))
              default_redirection_url: $(q(public_origin(cfg, cfg.domain)))
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

# ── Behind a tunnel: the login gate ──────────────────────────────────────────
# With `TunnelAuth` nothing of ours stands in front of the server: a tunnel
# (cloudflared, for one) brings `https://<domain>` to 127.0.0.1:<port>, and that
# is all it does. What Caddy does behind the proxy happens here instead, in the
# one place every request passes before any route, websocket upgrades included
# (Bonito's server gate):
#   * whatever a client sent as `Remote-User` & co. is dropped: only this gate
#     says who someone is;
#   * `/authelia/…`, Authelia's own login page and API, is passed through to
#     Authelia, so the tunnel needs one host name and one port;
#   * the few routes open to anyone are let through as they are: `/w` (a worker
#     proves itself with its credential, which the server checks), the worker
#     installer (a new machine fetches it before it has a credential) and invite
#     links (the token is the proof). Only these exact targets, without a query,
#     so nothing can ride on them to another route;
#   * so are shared links (shares.jl): `/s/<token>…`, where the token is the
#     proof, and for an app link's open page its websocket and the assets it
#     registered, nothing else (`is_share_target`);
#   * everything else is Authelia's decision, asked the way Caddy asks it
#     (`/api/authz/forward-auth`): 200 names who it is, anything else goes back
#     to the client as it is (the redirect to the login page, for a browser).
# Responses leave marked `private`: a tunnel may put a shared cache in front
# (Cloudflare's keeps what looks like a static file), and what is behind the
# login may only stay in the browser that fetched it. The gate's own answers are
# not stored at all.

# The login cookie a device last got through with: a short digest of it (never
# the cookie itself, which IS the login), whose it was, and when.
struct AcceptedCookie
    cookie::String
    user::String
    at::Float64
end

struct TunnelGate
    auth::TunnelAuth
    # Per browser (`client_address`): the cookie last let
    # through. Read only when a request is turned away, to say whether it still
    # carried that cookie (Authelia forgot the login) or another one (something
    # replaced it). Logins that ended every few minutes left no other trace.
    accepted::Dict{String,AcceptedCookie}
    lock::ReentrantLock
    shares::ShareRegistry
end
TunnelGate(auth::TunnelAuth, shares::ShareRegistry = ShareRegistry()) =
    TunnelGate(auth, Dict{String,AcceptedCookie}(), ReentrantLock(), shares)

"What stands before every route of the server: behind a tunnel the login gate."
server_gate(::AuthMode, ::ShareRegistry) = nothing
server_gate(auth::TunnelAuth, shares::ShareRegistry) = TunnelGate(auth, shares)

const OPEN_TARGETS = ("/w", "/install", "/install.sh", "/install.ps1", "/install.jl")
const INVITE_TARGET = r"^/invite/[0-9a-f]{64}/?$"

is_open_target(target::AbstractString) = target in OPEN_TARGETS || occursin(INVITE_TARGET, target)

function is_portal_target(target::AbstractString)
    path = first(split(target, '?'; limit = 2))
    return path == PORTAL_PATH || startswith(path, PORTAL_PATH * "/")
end

function Bonito.HTTPServer.gate_request(g::TunnelGate, request::HTTP.Request)
    foreach(h -> HTTP.removeheader(request, h), IDENTITY_HEADERS)
    target = request.target
    startswith(target, "/") || return gate_answer(400, "bad request target\n")
    is_portal_target(target) && return pass_to_authelia(g.auth, request)
    is_open_target(target) && return nothing
    is_share_target(g.shares, target) && return nothing
    return admit!(g, request)
end

Bonito.HTTPServer.gate_response(::TunnelGate, request, response) =
    (HTTP.setheader(response, "Cache-Control" => private_cache(HTTP.header(response, "Cache-Control", ""))); response)

# `public` becomes `private`, and a response that says nothing says `private`.
# One that is `private` or `no-store` already stays as it is.
function private_cache(value::AbstractString)
    directives = [String(strip(d)) for d in split(value, ',') if !isempty(strip(d))]
    any(d -> lowercase(d) in ("private", "no-store"), directives) && return String(value)
    return join(["private"; filter(d -> lowercase(d) != "public", directives)], ", ")
end

"""
    admit!(gate, request) -> Union{Nothing,HTTP.Response}

Ask Authelia whether `request` may go on. If so it carries who it is from
(`IDENTITY_HEADERS`, read by `request_user`) and `nothing` lets it through;
otherwise Authelia's answer goes back to the client, a browser's being the
redirect to the login page.
"""
function admit!(g::TunnelGate, request::HTTP.Request)
    headers = authelia_headers(g.auth, request)
    push!(headers, "X-Forwarded-Method" => request.method, "X-Forwarded-URI" => request.target)
    answer = ask_authelia(g.auth, "GET", PORTAL_PATH * "/api/authz/forward-auth", headers, UInt8[])
    name = HTTP.header(answer, "Remote-User", "")
    cookies = session_cookies(request)
    client = client_address(request)
    if answer.status == 200 && !isempty(name)
        for h in IDENTITY_HEADERS
            HTTP.setheader(request, h => HTTP.header(answer, h, ""))
        end
        lock(g.lock) do
            g.accepted[client] = AcceptedCookie(join(cookies, ","), name, time())
            # A long-running server meets many addresses; a day of them is plenty.
            length(g.accepted) > 1000 && filter!(kv -> time() - kv.second.at < 86400, g.accepted)
        end
        return nothing
    end
    refusal = relayed(answer)
    HTTP.setheader(refusal, "Cache-Control" => "no-store")
    log_refusal(g, client, request, cookies, refusal)
    return refusal
end

# One line per request turned away: which login cookie it came with, the one
# this device last got through with, and whether a new cookie goes back to it.
# (Only the refusals of devices that were let through before: an idle tab's
# periodic check after its login ended is not news.)
function log_refusal(g::TunnelGate, client::AbstractString, request::HTTP.Request,
                     cookies::Vector{String}, refusal::HTTP.Response)
    last = lock(() -> get(g.accepted, client, nothing), g.lock)
    last === nothing && return nothing
    sent = join(cookies, ",")
    handed = [cookie_digest(first(split(v, ';'))) for (k, v) in refusal.headers
              if lowercase(k) == "set-cookie" && startswith(v, SESSION_COOKIE * "=")]
    @info "login gate: turned away a device that was logged in" client target = request.target status = refusal.status cookie = (isempty(sent) ? "none" : sent) cookies_sent = length(cookies) last_accepted = last.cookie last_user = last.user seconds_since = round(Int, time() - last.at) same_cookie = (sent == last.cookie) new_cookie_to_browser = (isempty(handed) ? "none" : join(handed, ","))
    # Logged once: until it gets through again, the device's next refusals repeat this.
    lock(() -> delete!(g.accepted, client), g.lock)
    return nothing
end

const SESSION_COOKIE = "authelia_session"

# Short digests of the login cookies a request carries. More than one means the
# browser holds two (a stale one beside the live one) and sends both, and which
# one Authelia reads is not up to us.
function session_cookies(request::HTTP.Request)
    out = String[]
    for (k, v) in request.headers
        lowercase(k) == "cookie" || continue
        for part in split(v, ';')
            part = strip(part)
            startswith(part, SESSION_COOKIE * "=") && push!(out, cookie_digest(part))
        end
    end
    return out
end

cookie_digest(pair::AbstractString) = bytes2hex(sha256(String(pair)))[1:8]

# The browser a request comes from: its address as the tunnel says (Cloudflare
# names it in `Cf-Connecting-Ip`, other tunnels in `X-Forwarded-For`) and its
# user agent, so two browsers on one machine (or behind one router) stay apart.
function client_address(request::HTTP.Request)
    cf = HTTP.header(request, "Cf-Connecting-Ip", "")
    xff = HTTP.header(request, "X-Forwarded-For", "")
    ip = !isempty(cf) ? String(cf) : isempty(xff) ? "unknown" : String(strip(first(split(xff, ','))))
    return ip * " " * first(HTTP.header(request, "User-Agent", "no user agent"), 60)
end

# Authelia's login page and API, under the dashboard's own name.
pass_to_authelia(auth::TunnelAuth, request::HTTP.Request) =
    relayed(ask_authelia(auth, request.method, request.target, authelia_headers(auth, request),
                         request_bytes(request.body)))

request_bytes(body::HTTP.BytesBody) = Vector{UInt8}(body)
request_bytes(::HTTP.EmptyBody) = UInt8[]

# Headers that belong to one connection, not to the request: never passed on.
const HOP_HEADERS = ("connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
                     "trailer", "transfer-encoding", "upgrade", "host", "content-length")

# The client's headers for Authelia, with what the tunnel stands for stated by the
# server rather than taken from the client: the request came over HTTPS, to the
# dashboard's name.
function authelia_headers(auth::TunnelAuth, request::HTTP.Request)
    headers = Pair{String,String}[]
    for (k, v) in request.headers
        key = lowercase(k)
        (key in HOP_HEADERS || startswith(key, "sec-websocket-") ||
         (startswith(key, "x-forwarded-") && key != "x-forwarded-for") || startswith(key, "x-original-")) && continue
        push!(headers, String(k) => String(v))
    end
    cfg = auth.config
    push!(headers, "X-Forwarded-Proto" => "https",
          "X-Forwarded-Host" => cfg.domain * (cfg.https_port == 443 ? "" : ":$(cfg.https_port)"))
    return headers
end

# One request to Authelia. Its cookies are the browser's, passed on as they
# came: the client keeps none of its own (a shared cookie jar would hand one
# person's session to the next), follows no redirect and goes through no proxy.
#
# A connection per request (`Connection: close`), never a pooled one: Authelia
# closes an idle keep-alive connection after a while, and the next request on it
# failed with "Broken pipe" or "unexpected EOF". Without retries (a login POST
# must not be sent twice) that was a 500 for whatever the browser had asked for,
# after every quiet minute. Authelia is on localhost; a connection costs nothing.
function ask_authelia(auth::TunnelAuth, method::AbstractString, target::AbstractString, headers, body)
    headers = [headers; "Connection" => "close"]
    try
        return HTTP.request(method, "http://127.0.0.1:$(auth.config.authelia_port)$(target)", headers, body;
                            cookies = false, redirect = false, status_exception = false, retry = false,
                            decompress = false, proxy = nothing, connect_timeout = 5, request_timeout = 30)
    catch e
        e isa HTTP.ConnectError || rethrow()
        @warn "the login service (Authelia) is not answering; refusing the request" port = auth.config.authelia_port
        return gate_answer(502, "the login service is not answering\n")
    end
end

# Authelia's answer, for the client: without what belonged to our connection.
relayed(answer::HTTP.Response) =
    HTTP.Response(answer.status, [String(k) => String(v) for (k, v) in answer.headers
                                  if !(lowercase(k) in HOP_HEADERS)], answer.body)

gate_answer(status::Int, text::AbstractString) =
    HTTP.Response(status, ["Content-Type" => "text/plain; charset=utf-8", "Cache-Control" => "no-store"], text)

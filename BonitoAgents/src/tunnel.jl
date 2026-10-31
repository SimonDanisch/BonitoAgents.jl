# Tunnel requests are authenticated by Authelia before reaching Bonito's
# routes, including WebSocket upgrades. Identity headers from clients are ignored.

# The login cookie a device last got through with: a short digest of it (never
# the cookie itself, which IS the login), whose it was, and when.
struct AcceptedCookie
    cookie::String
    user::String
    at::Float64
end

struct TunnelAuthentication{Handler}
    handler::Handler
    auth::TunnelAuth
    # Per browser (`client_address`): the cookie last let
    # through. Read only when a request is turned away, to say whether it still
    # carried that cookie (Authelia forgot the login) or another one (something
    # replaced it). Logins that ended every few minutes left no other trace.
    accepted::Dict{String,AcceptedCookie}
    lock::ReentrantLock
    shares::ShareRegistry
    # The server's (`bt_dev_timings`): when each page's live connection arrived.
    timings::Timings
end
TunnelAuthentication(auth::TunnelAuth, shares::ShareRegistry = ShareRegistry(), timings::Timings = Timings();
                     handler = Bonito.HTTPServer.delegate) =
    TunnelAuthentication(handler, auth, Dict{String,AcceptedCookie}(), ReentrantLock(), shares, timings)

authenticated_handler(::AuthMode, ::ShareRegistry, ::Timings) = Bonito.HTTPServer.delegate
authenticated_handler(auth::TunnelAuth, shares::ShareRegistry, timings::Timings) =
    TunnelAuthentication(auth, shares, timings)

function Bonito.HTTPServer.apply_handler(authentication::TunnelAuthentication, context)
    request = context.request
    refusal = authenticate!(authentication, request)
    refusal === nothing || return refusal
    response = Bonito.HTTPServer.apply_handler(authentication.handler, context)
    # WebSocket upgrades write their handshake directly to the stream.
    response === nothing && return nothing
    return authenticated_response!(authentication, request, response)
end

# assets/login.js, for Authelia's login page (`with_login_script`), which is
# shown to whoever is not logged in.
const LOGIN_SCRIPT_ROUTE = "/login.js"
const OPEN_TARGETS = ("/w", "/install", "/install.sh", "/install.ps1", "/install.jl", LOGIN_SCRIPT_ROUTE)
const INVITE_TARGET = r"^/invite/[0-9a-f]{64}/?$"

is_open_target(target::AbstractString) = target in OPEN_TARGETS || occursin(INVITE_TARGET, target)

function is_portal_target(target::AbstractString)
    path = first(split(target, '?'; limit = 2))
    return path == PORTAL_PATH || startswith(path, PORTAL_PATH * "/")
end

function authenticate!(g::TunnelAuthentication, request::HTTP.Request)
    request.context[:authentication_started] = time()      # for `log_slow_request`
    foreach(h -> HTTP.removeheader(request, h), IDENTITY_HEADERS)
    target = request.target
    startswith(target, "/") || return authentication_error(400, "bad request target\n")
    is_portal_target(target) && return pass_to_authelia(g.auth, request)
    is_open_target(target) && return nothing
    is_share_target(g.shares, target) && return nothing
    answer = admit!(g, request)
    # A page's live connection: when it reached the server, and how long the
    # login check took. A phone waited 6 to 15 s for its socket while its page
    # loaded fast, and nothing said whether those seconds passed before the
    # request reached the server or in it.
    HTTP.WebSockets.isupgrade(request) &&
        record_timing!(g.timings, :ws_upgrade, time() - request.context[:authentication_started];
                       tab = first(lstrip(first(split(target, '?'; limit = 2)), '/'), 8),
                       client = client_address(request), status = answer === nothing ? 101 : answer.status)
    return answer
end

function authenticated_response!(::TunnelAuthentication, request, response)
    HTTP.setheader(response, "Cache-Control" => private_cache(HTTP.header(response, "Cache-Control", "")))
    for cookie in get(request.context, :login_cookies, String[])
        push!(response.headers, "Set-Cookie" => cookie)
    end
    log_slow_request(request, response)
    return response
end

# A request the server took long to answer: from authentication starting to the
# answer leaving its route (a streamed body's transfer comes after), with the
# part of it spent waiting for Authelia. A browser left waiting this long looks
# like a hung server, and nothing else said where the time went.
function log_slow_request(request::HTTP.Request, response::HTTP.Response; slow::Real = 2.0)
    t0 = get(request.context, :authentication_started, nothing)
    t0 === nothing && return nothing
    took = time() - t0
    took < slow && return nothing
    phases = phase_summary(get(request.context, :page_phases, Dict{Symbol,Float64}()))
    @warn "slow request: the browser waited on the server" target = first(request.target, 120) status = response.status seconds = round(took; digits = 1) login_seconds = round(get(request.context, :login_s, 0.0); digits = 1) phases client = client_address(request)
    return nothing
end

# The timed parts of a page, slowest first: "render=13.2s handler=0.1s …", the
# ones under `min_s` left out. Parts nest (the handler holds the dashboard), so
# they don't add up. `render` is what Bonito spent after the handler returned:
# rendering the components to HTML and serializing them.
phase_summary(phases::AbstractDict; min_s::Real = 0.05) =
    join(("$(k)=$(round(v; digits = 3))s" for (k, v) in sort!(collect(phases); by = last, rev = true) if v >= min_s), " ")

"""
    page_phase(f, name) -> f()

Add the time `f` takes to the current page request's `name` (shown by the slow
request warning). Outside a page request it just calls `f`. A phone waited
minutes on the page, and a desktop 14 s for its HTML, with no line saying
where the server spent it.
"""
function page_phase(f, name::Symbol)
    phases = get(task_local_storage(), :bt_page_phases, nothing)
    phases === nothing && return f()
    t0 = time()
    try
        return f()
    finally
        phases[name] = get(phases, name, 0.0) + (time() - t0)
    end
end

# `public` becomes `private`, and a response that says nothing says `private`.
# One that is `private` or `no-store` already stays as it is.
function private_cache(value::AbstractString)
    directives = [String(strip(d)) for d in split(value, ',') if !isempty(strip(d))]
    any(d -> lowercase(d) in ("private", "no-store"), directives) && return String(value)
    return join(["private"; filter(d -> lowercase(d) != "public", directives)], ", ")
end

"""
    admit!(authentication, request) -> Union{Nothing,HTTP.Response}

Ask Authelia whether `request` may go on. If so it carries who it is from
(`IDENTITY_HEADERS`, read by `request_user`) and `nothing` lets it through;
otherwise Authelia's answer goes back to the client, a browser's being the
redirect to the login page.
"""
function admit!(g::TunnelAuthentication, request::HTTP.Request)
    headers = authelia_headers(g.auth, request)
    push!(headers, "X-Forwarded-Method" => request.method, "X-Forwarded-URI" => request.target)
    asked = time()
    answer = ask_authelia(g.auth, "GET", PORTAL_PATH * "/api/authz/forward-auth", headers, UInt8[])
    request.context[:login_s] = time() - asked
    name = HTTP.header(answer, "Remote-User", "")
    cookies = session_cookies(request)
    client = client_address(request)
    if answer.status == 200 && !isempty(name)
        for h in IDENTITY_HEADERS
            HTTP.setheader(request, h => HTTP.header(answer, h, ""))
        end
        # A login cookie Authelia hands out while letting the request through is
        # the one it keeps the login under from now on: the browser must get it,
        # or its next request carries one Authelia no longer knows. The answer
        # goes out with the route's response (`authenticated_response!`).
        handed = session_cookies(answer)
        if !isempty(handed) && handed != cookies
            request.context[:login_cookies] = [String(v) for (k, v) in answer.headers if lowercase(k) == "set-cookie"]
            @info "login gate: Authelia renewed the login cookie" client target = first(request.target, 120) cookie = join(cookies, ",") new_cookie = join(handed, ",") user = name
        end
        lock(g.lock) do
            g.accepted[client] = AcceptedCookie(join(isempty(handed) ? cookies : handed, ","), name, time())
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
function log_refusal(g::TunnelAuthentication, client::AbstractString, request::HTTP.Request,
                     cookies::Vector{String}, refusal::HTTP.Response)
    last = lock(() -> get(g.accepted, client, nothing), g.lock)
    last === nothing && return nothing
    sent = join(cookies, ",")
    handed = session_cookies(refusal)
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

# Short digests of the login cookies a response hands the browser.
session_cookies(response::HTTP.Response) =
    [cookie_digest(first(split(v, ';'))) for (k, v) in response.headers
     if lowercase(k) == "set-cookie" && startswith(v, SESSION_COOKIE * "=")]

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

# Authelia's login page and API, under the dashboard's own name. A page the
# browser navigates to gets assets/login.js: shown while the browser was logged
# out, it leaves once the browser is logged in in another tab. A login made
# there anyway would drop the session the other tabs of the browser are using.
function pass_to_authelia(auth::TunnelAuth, request::HTTP.Request)
    page = request.method == "GET" && HTTP.header(request, "Sec-Fetch-Dest", "") == "document"
    headers = authelia_headers(auth, request)
    page && filter!(h -> lowercase(first(h)) != "accept-encoding", headers)   # HTML as text, to add to
    answer = relayed(ask_authelia(auth, request.method, request.target, headers, request_bytes(request.body)))
    log_login_event(request, answer)
    return page ? with_login_script(answer) : answer
end

# Every login and logout, and whatever else gives the browser another login
# cookie, with the cookie before and after. Authelia logs none of them, and a
# login that ended minutes after it was made left nothing to say what ended it.
function log_login_event(request::HTTP.Request, answer::HTTP.Response)
    path = first(split(request.target, '?'; limit = 2))
    sent = session_cookies(request)
    handed = session_cookies(answer)
    login_call = request.method != "GET" && occursin(r"^/authelia/api/(firstfactor|secondfactor|logout)", path)
    (login_call || (!isempty(handed) && handed != sent)) || return nothing
    @info "login: Authelia" method = request.method path status = answer.status cookie = (isempty(sent) ? "none" : join(sent, ",")) new_cookie = (isempty(handed) ? "none" : join(handed, ",")) client = client_address(request)
    return nothing
end

function with_login_script(page::HTTP.Response)
    startswith(HTTP.header(page, "Content-Type", ""), "text/html") || return page
    html = String(copy(page.body))   # `String` takes the vector it is given
    head_end = findfirst("</head>", html)
    head_end === nothing && return page
    tag = "<script type=\"module\" src=\"$(LOGIN_SCRIPT_ROUTE)\"></script>"
    return HTTP.Response(page.status, page.headers,
                         Vector{UInt8}(html[1:prevind(html, first(head_end))] * tag * html[first(head_end):end]))
end

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
        return authentication_error(502, "the login service is not answering\n")
    end
end

# Authelia's answer, for the client: without what belonged to our connection.
relayed(answer::HTTP.Response) =
    HTTP.Response(answer.status, [String(k) => String(v) for (k, v) in answer.headers
                                  if !(lowercase(k) in HOP_HEADERS)], answer.body)

authentication_error(status::Int, text::AbstractString) =
    HTTP.Response(status, ["Content-Type" => "text/plain; charset=utf-8", "Cache-Control" => "no-store"], text)

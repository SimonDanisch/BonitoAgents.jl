# ── Base: tokens, reset and the controls every surface shares ────────────────
# Included by BOTH `ChatStyles` and `DashboardStyles` (each can be mounted on
# its own), so a token, a button or a menu is defined exactly once and the chat
# and the dashboard cannot drift apart. Bonito renders each unique CSS object
# once per session, so the overlap costs nothing.
#
# The design language, in short — see CONVENTIONS.md "Design language":
#   • buttons: ONE family, BonitoWidgets' `.bw-btn` (+ `-secondary`, `-ghost`,
#     `-danger`, `-sm`);
#   • related pickers sit in ONE segmented group (the chat header's session group);
#   • one-shot actions go into a BonitoWidgets `Menu`, not into a row of buttons;
#     a form opens in a BonitoWidgets `Modal`;
#   • outcomes are reported by a toast, never by rewriting a button's label;
#   • colors, spacing and radii from BonitoWidgets' `--bw-*` variables, set by
#     `APP_THEME`.
# The browser's localStorage, for what a page only keeps for convenience (the
# sidebar's width, the route to restore, drafts). Storage can be switched off
# (SecurityError) or full (QuotaExceededError): those warn in the console and act
# as "nothing stored". Anything else throws. Interpolate it:
# `const store = $(STORAGE_JS);`.
const STORAGE_JS = js"""(() => {
    const refused = (error, key) => {
        if (!(error instanceof DOMException) ||
            !['SecurityError', 'QuotaExceededError'].includes(error.name)) throw error;
        console.warn(`browser storage refused (${key}):`, error.message);
    };
    return {
        get(key) { try { return localStorage.getItem(key); } catch (e) { refused(e, key); return null; } },
        set(key, value) { try { localStorage.setItem(key, value); } catch (e) { refused(e, key); } },
        remove(key) { try { localStorage.removeItem(key); } catch (e) { refused(e, key); } },
    };
})()"""

# `text` onto the clipboard: resolves once it is there, rejects when it is not.
# The async clipboard needs a secure context; a LAN http:// page falls back to a
# selected textarea (iOS ignores `select()` without `setSelectionRange`, and
# `readonly` keeps the keyboard shut). Interpolate it: `($(COPY_TEXT_JS))(text)`.
const COPY_TEXT_JS = js"""(text) => {
    const legacy = () => {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.setAttribute('readonly', '');
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        ta.setSelectionRange(0, text.length);
        const ok = document.execCommand('copy');
        ta.remove();
        return ok ? Promise.resolve() : Promise.reject(new Error('copy refused'));
    };
    return navigator.clipboard && window.isSecureContext ?
        navigator.clipboard.writeText(text).catch(legacy) : legacy();
}"""


"""
    connection_guard(session) -> Node

The browser↔server websocket's status, made impossible to miss when it matters.

Two parts, one JS object registered with Bonito's connection machinery (it has a
single indicator slot, so this replaces the stock LED rather than sitting next
to it). The LED: 8px, bottom-LEFT over the sidebar, in OUR status palette
(`--bt-status-*`), so one glance reads the same as every other liveness dot in
the window. The default top-right spot lands on the chat header's ⋯ button.

The guard: the moment the socket drops, an overlay covers the window and the
composer is locked, and both stay until the socket is back. The overlay turns
visible only once the drop has lasted longer than a blink, so the routine
sub-second reconnect on a healthy link does not flash a modal. Anything typed
or sent while Bonito is reconnecting is at risk, so a small dot changing colour
was not a warning, it was a way to lose work. "connecting" is the retry phase,
shown as reconnecting; "disconnected" is Bonito's retries running out, shown
with a reload button while Bonito goes on trying in the background. Before the
first successful connection the page looks loaded and takes clicks that go
nowhere (a chat opened from the sidebar shows an empty area: the server renders
its loading card), so the card shows
then too, once the first connection has taken longer than `first_connect`
seconds or Bonito gave up on it. "expired" is final: the server has no
session for this page (it restarted, or dropped the page after an hour away), so
the page reloads itself, or asks first when a reload would lose unsent text (text
kept as a chat's draft comes back after the reload, so it does not count).

NOT the same signal as the in-chat status dot: that one is the AGENT session's
liveness, this one is whether this browser tab can still talk to the server at
all. Both matter, and they fail independently.
"""
function connection_guard(session::Bonito.Session; first_connect::Real = 4)
    css = Styles(
        CSS(".bt-conn-led",
            "position" => "fixed", "bottom" => "10px", "left" => "10px",
            "width" => "8px", "height" => "8px", "border-radius" => "50%",
            "background" => "var(--bw-text-faint)",
            "box-shadow" => "0 0 0 3px var(--bw-bg), 0 0 0 4px rgba(15,23,42,0.08)",
            "opacity" => "0.85", "z-index" => "9999", "pointer-events" => "none",
            "transition" => "background 200ms"),
        CSS(".bt-conn-led[data-status=\"connected\"]",  "background" => "var(--bt-status-online)"),
        CSS(".bt-conn-led[data-status=\"connecting\"]", "background" => "var(--bw-warning)"),
        CSS(".bt-conn-led[data-status=\"disconnected\"]", "background" => "var(--bt-status-offline)"),
        CSS(".bt-conn-led[data-status=\"expired\"]", "background" => "var(--bt-status-offline)"),
        # The overlay blocks from the first millisecond of a drop but only BECOMES
        # VISIBLE if the drop outlasts a blink: Bonito reconnects a healthy local
        # link within milliseconds, and a modal flashing on every such blip would
        # be noise. `animation-delay` keeps it fully transparent until then.
        CSS(".bt-conn-modal",
            "display" => "none", "position" => "fixed", "inset" => "0", "z-index" => "10050",
            "align-items" => "center", "justify-content" => "center",
            "background" => "rgba(15,23,42,0.35)", "backdrop-filter" => "blur(2px)",
            "opacity" => "0"),
        CSS(".bt-conn-modal.bt-conn-open",
            "display" => "flex", "animation" => "bt-conn-appear 120ms ease-out 350ms forwards"),
        CSS("@keyframes bt-conn-appear", CSS("to", "opacity" => "1")),
        # The card: a status glyph, a title, one plain sentence, a live "for N s"
        # line, and a reload button that is always there. Reloading is the one
        # thing a user can do about a dead link, so it never hides behind a state.
        CSS(".bt-conn-card",
            "display" => "flex", "flex-direction" => "column", "align-items" => "center",
            "text-align" => "center", "gap" => "6px",
            "width" => "min(380px, calc(100vw - 32px))", "padding" => "28px 28px 24px",
            "background" => "var(--bw-bg-panel)", "color" => "var(--bw-text)",
            "border" => "1px solid var(--bw-border)", "border-radius" => "14px",
            "box-shadow" => "0 24px 60px rgba(15,23,42,0.28), 0 2px 8px rgba(15,23,42,0.12)",
            "font-family" => "'Inter', system-ui, -apple-system, sans-serif"),
        CSS(".bt-conn-glyph",
            "position" => "relative", "width" => "44px", "height" => "44px", "margin-bottom" => "8px",
            "border-radius" => "50%", "border" => "3px solid var(--bw-border)",
            "border-top-color" => "var(--bw-warning)",
            "animation" => "bt-conn-spin 0.9s steps(8) infinite"),
        CSS("@keyframes bt-conn-spin", CSS("to", "transform" => "rotate(360deg)")),
        # Given up, or nothing left to reconnect to: the ring stops, turns red and
        # shows an exclamation mark.
        CSS(".bt-conn-modal[data-status=\"disconnected\"] .bt-conn-glyph, .bt-conn-modal[data-status=\"expired\"] .bt-conn-glyph",
            "animation" => "none", "border-color" => "var(--bt-status-offline)",
            "background" => "color-mix(in srgb, var(--bt-status-offline) 12%, transparent)"),
        CSS(".bt-conn-modal[data-status=\"disconnected\"] .bt-conn-glyph::after, .bt-conn-modal[data-status=\"expired\"] .bt-conn-glyph::after",
            "content" => "\"!\"", "position" => "absolute", "inset" => "0",
            "display" => "flex", "align-items" => "center", "justify-content" => "center",
            "font-weight" => "700", "font-size" => "22px", "color" => "var(--bt-status-offline)"),
        CSS(".bt-conn-title",
            "font-size" => "var(--bw-font-size-lg)", "font-weight" => "600", "line-height" => "1.3"),
        CSS(".bt-conn-msg",
            "font-size" => "var(--bw-font-size-ui)", "line-height" => "1.5", "color" => "var(--bw-text-muted)",
            "max-width" => "32ch"),
        CSS(".bt-conn-elapsed",
            "font-size" => "var(--bw-font-size-sm)", "color" => "var(--bw-text-faint)",
            "font-variant-numeric" => "tabular-nums", "min-height" => "16px"),
        CSS(".bt-conn-reload", "margin-top" => "12px", "padding" => "8px 16px"),
        CSS(".bt-conn-reload svg", "width" => "14px", "height" => "14px", "flex-shrink" => "0"))
    led = DOM.div(; class = "bt-conn-led", dataStatus = "connecting", title = "Connecting to the server…")
    refresh_icon = Bonito.SVG.svg(
        Bonito.SVG.path(d = "M13.5 8a5.5 5.5 0 1 1-1.6-3.9"),
        Bonito.SVG.path(d = "M13.5 2.5v2.4h-2.4");
        viewBox = "0 0 16 16", fill = "none", stroke = "currentColor",
        var"stroke-width" = "1.8", var"stroke-linecap" = "round", var"stroke-linejoin" = "round",
        var"aria-hidden" = "true")
    modal = DOM.div(
        DOM.div(
            DOM.div(; class = "bt-conn-glyph"),
            DOM.div("Reconnecting to the server"; class = "bt-conn-title"),
            DOM.div("The link to the server dropped. The composer is locked until it is back, so nothing you type is lost."; class = "bt-conn-msg"),
            DOM.div(""; class = "bt-conn-elapsed"),
            DOM.button(refresh_icon, "Reload page"; class = "bw-btn bt-conn-reload", type = "button",
                       onclick = js"() => window.location.reload()");
            class = "bt-conn-card", role = "alertdialog", var"aria-live" = "assertive");
        class = "bt-conn-modal", dataStatus = "connecting")
    root = DOM.div(css, led, modal; class = "bt-conn-guard")
    Bonito.onload(session, root, js"""(root) => {
        const led     = root.querySelector('.bt-conn-led');
        const modal   = root.querySelector('.bt-conn-modal');
        const title   = modal.querySelector('.bt-conn-title');
        const msg     = modal.querySelector('.bt-conn-msg');
        const elapsed = modal.querySelector('.bt-conn-elapsed');
        const titles = {connected: 'Connected to the server', connecting: 'Reconnecting to the server…',
                        disconnected: 'Disconnected from the server', no_connection: 'No server connection',
                        expired: 'This page has to be reloaded'};
        const copy = {
            first:        ['Connecting to the server',
                           'This page has not reached the server yet, so nothing on it works until it does. It keeps trying; reloading often helps.'],
            first_failed: ['Could not reach the server',
                           'This page never reached the server, so nothing on it works. Reload it to try again.'],
            connecting:   ['Reconnecting to the server',
                           'The link to the server dropped. The composer is locked until it is back, so nothing you type is lost.'],
            disconnected: ['Connection lost',
                           'Reconnecting has not worked yet. The page keeps trying by itself; reloading it may be quicker.'],
            expired:      ['This page has to be reloaded',
                           'The server restarted, or this page sat unused for over an hour, so it cannot reconnect. Copy what you typed, then reload.'],
        };
        // Text typed into a chat composer that a reload would throw away: not
        // sent, and not kept as the chat's draft either (bonitoagents.js keeps one
        // per chat in localStorage and puts it back after a reload, unless the
        // storage is full or off). What the page rendered into it (the yolo
        // reminders) the server keeps.
        const store = $(STORAGE_JS);
        const draftOf = t => {
            const pid = t.closest('.bt-chatpane')?.dataset.panePid;
            return pid ? store.get('bt-draft:' + pid) : null;
        };
        const unsent = () => Array.from(document.querySelectorAll('textarea.bt-text-input'))
            .some(t => t.value.trim() !== '' && t.value !== t.defaultValue && t.value !== draftOf(t));
        function reloadWhenShown() {
            if (document.visibilityState === 'visible') { window.location.reload(); return; }
            const onShow = () => {
                if (document.visibilityState !== 'visible') return;
                document.removeEventListener('visibilitychange', onShow);
                window.location.reload();
            };
            document.addEventListener('visibilitychange', onShow);
        }
        // While the guard is up, a keystroke aimed at an editable element goes
        // nowhere: the overlay stops clicks, this stops the textarea that still
        // had focus when the socket dropped.
        const swallow = e => { const t = e.target; if (t && t.closest && t.closest('input, textarea, [contenteditable]')) { e.preventDefault(); e.stopPropagation(); } };
        let wasConnected = false, blocking = false, since = 0, ticker = null;
        function tick() {
            const s = Math.max(0, Math.round((Date.now() - since) / 1000));
            const st = modal.dataset.status;
            elapsed.textContent = st === 'expired' ? ''
                : st === 'disconnected' ? 'Offline for ' + s + ' s'
                : (s < 1 ? 'Trying again…' : 'Trying again for ' + s + ' s');
        }
        // `key` picks the words (the first connection has its own), `status`
        // the look.
        function setBlocked(on, status, key = status) {
            modal.dataset.status = status;
            if (on && copy[key]) { title.textContent = copy[key][0]; msg.textContent = copy[key][1]; }
            if (on === blocking) { on && tick(); return; }
            blocking = on;
            modal.classList.toggle('bt-conn-open', on);
            if (on) {
                since = Date.now(); tick();
                ticker = setInterval(tick, 1000);
                const a = document.activeElement;
                a && a.closest && a.closest('input, textarea, [contenteditable]') && a.blur();
                document.addEventListener('keydown', swallow, true);
                document.addEventListener('paste', swallow, true);
            } else {
                clearInterval(ticker); ticker = null;
                document.removeEventListener('keydown', swallow, true);
                document.removeEventListener('paste', swallow, true);
            }
        }
        // A connection that does not come back may be a login that ended: the
        // login gate turns the websocket away, which a browser reports as
        // nothing but a failed connection, and the card said "Reconnecting"
        // forever, a hung server to anyone looking. Asked once per drop, after a
        // moment (a blip is back by then): if so, the login card says so, over
        // this one, and the page goes on once the login is back.
        // Back from the login, the page reconnects at once. Bonito ignores that
        // while its own retries still run, and they can run out before their
        // next attempt: one more round when they give up.
        let loginAsked = false, reviveOnGiveUp = false;
        const revive = () => window.WEBSOCKET && window.WEBSOCKET.retry_connection();
        const askLogin = () => {
            if (loginAsked) return;
            loginAsked = true;
            setTimeout(() => {
                if (!blocking) return;
                $(LoginLib).then(login => login.check().then(s => s === 'ended' &&
                    login.logged_in().then(() => { reviveOnGiveUp = true; revive(); })));
            }, 2000);
        };
        // The first connection is normally up well within a second.
        const firstWait = setTimeout(() => { if (!wasConnected) { setBlocked(true, 'connecting', 'first'); askLogin(); } },
                                     $(round(Int, 1000 * first_connect)));
        Bonito.register_connection_indicator({ onStatusChange(status) {
            led.dataset.status = status; led.title = titles[status] || titles.disconnected;
            if (status === 'connected') {
                wasConnected = true; loginAsked = false; reviveOnGiveUp = false;
                clearTimeout(firstWait); setBlocked(false, status); return;
            }
            if (status === 'disconnected' && reviveOnGiveUp) { reviveOnGiveUp = false; revive(); return; }
            if (status === 'no_connection') { clearTimeout(firstWait); setBlocked(false, status); return; }
            // The server has no session for this page (Bonito: close code 4404).
            // Nothing will reconnect it, and before the first connection too:
            // a page restored from the back/forward cache never connects at all.
            if (status === 'expired') {
                clearTimeout(firstWait);          // it has its own way out
                $(ChatLib).then(lib => {
                    lib.flushDrafts();            // text typed just now counts as kept
                    if (unsent()) { setBlocked(true, status); return; }
                    // Its login ended too (the server restarted with Authelia),
                    // a reload lands on the login page, and a login made there
                    // drops the one the other tabs have meanwhile: this tab
                    // waits for the login, with its card, and reloads after.
                    $(LoginLib).then(login => login.check()
                        .then(s => s === 'ended' ? login.logged_in() : null)
                        .then(reloadWhenShown));
                });
                return;
            }
            if (!wasConnected) {
                // Still loading: `firstWait` shows the card if it takes too long,
                // and giving up shows it at once.
                if (status === 'disconnected') { clearTimeout(firstWait); setBlocked(true, status, 'first_failed'); askLogin(); }
                return;
            }
            setBlocked(true, status);
            askLogin();
        }});
    }""")
    return root
end

# Where a page reports how its load went (`page_load_report`).
const PAGE_TIMING_ROUTE = "/page-timing"

"""
    page_load_report(session) -> Node

The page's own account of its load, for the server log (`PAGE_TIMING_ROUTE`):
when its HTML arrived, its scripts ran, its connection came up and the chat it
opened showed its rows, and its slowest downloads. Sent once the page is usable,
or after `give_up` seconds if it never gets there, as a plain HTTP request, which
gets through when the page's own connection does not. A phone that took minutes
left no trace on the server before.
"""
function page_load_report(session::Bonito.Session; give_up::Real = 60)
    node = DOM.div(; class = "bt-page-load-report", style = "display:none")
    Bonito.onload(session, node, js"""() => {
        const t = {hidden: document.visibilityState !== 'visible'};
        const mark = k => { if (!(k in t)) { t[k] = Math.round(performance.now()); check(); } };
        let sent = false;
        const send = why => {
            if (sent) return;
            sent = true;
            const n = performance.getEntriesByType('navigation')[0];
            const slow = performance.getEntriesByType('resource')
                .filter(e => e.duration > 1000).sort((a, b) => b.duration - a.duration).slice(0, 5)
                .map(e => [e.name.replace(location.origin, '').slice(0, 100), Math.round(e.duration), Math.round(e.transferSize / 1024), {
                    before_request_ms: e.requestStart ? Math.round(e.requestStart - e.startTime) : null,
                    response_wait_ms: e.responseStart ? Math.round(e.responseStart - e.requestStart) : null,
                    download_ms: e.responseStart ? Math.round(e.responseEnd - e.responseStart) : null,
                    protocol: e.nextHopProtocol, initiator: e.initiatorType
                }]);
            navigator.sendBeacon($(PAGE_TIMING_ROUTE), JSON.stringify(Object.assign({
                why, view: document.querySelector('.bt-main-views')?.dataset.activeView || '',
                html: Math.round(n ? n.responseEnd : 0), scripts: Math.round(n ? n.domContentLoadedEventEnd : 0),
                waited: Math.round(performance.now()),
                status: document.querySelector('.bt-conn-led')?.dataset.status || '', slow}, t)));
        };
        // Usable: connected, and a chat on screen shows its rows.
        const check = () => {
            const view = document.querySelector('.bt-main-views')?.dataset.activeView || '';
            const onChat = view !== '' && view !== $(SETTINGS_VIEW);
            if ('connected' in t && (!onChat || 'chat_settled' in t)) send('ready');
        };
        const led = document.querySelector('.bt-conn-led');
        const watch = () => led && led.dataset.status === 'connected' && mark('connected');
        led && new MutationObserver(watch).observe(led, {attributes: true, attributeFilter: ['data-status']});
        window.addEventListener('bt-chat-settled', () => mark('chat_settled'));
        watch();
        setTimeout(() => send('gave_up'), $(round(Int, 1000 * give_up)));
    }""")
    return node
end

# Answers only through the login: what `login_guard` asks.
const LOGIN_CHECK_ROUTE = "/session"

# The login as the tabs of one browser share it. Served on its own route too,
# for Authelia's login page (`LOGIN_SCRIPT_ROUTE`).
const LOGIN_JS = joinpath(@__DIR__, "..", "assets", "login.js")
const LoginLib = Bonito.ES6Module(LOGIN_JS)

"""
    login_guard(session, auth)

Behind a login, an open tab checks every few minutes (and when it becomes
visible again) that its login still lets requests through: that keeps the login
alive while the tab is open, and when it has ended anyway (its time was up, an
admin disabled the account) the tab says so, with a way to log in again, instead
of failing on the next thing it loads. A chat opened meanwhile comes up once the
login is back. Uses the connection guard's card.
"""
login_guard(::Bonito.Session, ::OpenAuth) = DOM.div()

function login_guard(session::Bonito.Session, ::LoginAuth)
    modal = DOM.div(
        DOM.div(
            DOM.div(; class = "bt-conn-glyph"),
            DOM.div("Your login has ended"; class = "bt-conn-title"),
            # Never a reload: that took whatever was typed with it. The login
            # happens in a new tab, and this page goes on once it is back.
            DOM.div("Log in again in a new tab. This page stays as it is and goes on by itself " *
                    "once you are logged in."; class = "bt-conn-msg"),
            DOM.button("Log in (new tab)"; class = "bw-btn bt-conn-reload", type = "button",
                       onclick = js"() => window.open(window.location.origin + '/', '_blank')");
            class = "bt-conn-card", role = "alertdialog", var"aria-live" = "assertive");
        class = "bt-conn-modal bt-login-ended", dataStatus = "disconnected")
    Bonito.onload(session, modal, js"(modal) => $(LoginLib).then(login => login.guard(modal))")
    return modal
end


# The app's palette, on BonitoWidgets' `--bw-*` variables: BonitoWidgets'
# buttons, menus, modals and workspace read them, and so does every rule here.
# Every sheet that can be mounted on its own carries it (`BASE_STYLES`, and the
# viewer sheets below).
const APP_THEME = BonitoWidgets.Theme(scheme = :light;
    bg            = "#fafaf9",
    bg_panel      = "#ffffff",
    bg_subtle     = "#f8fafc",
    bg_bar        = "var(--bw-bg-subtle)",
    bg_hover      = "rgba(15,23,42,0.05)",
    border        = "rgba(15,23,42,0.08)",
    border_strong = "rgba(15,23,42,0.14)",
    text          = "#0f172a",
    text_muted    = "#64748b",
    text_faint    = "#94a3b8",
    accent        = "#3b82f6",
    accent_hover  = "#2563eb",
    accent_bg     = "rgba(59,130,246,0.10)",
    accent_fg     = "#ffffff",
    success       = "#10b981",
    error         = "#ef4444",
    warning       = "#f59e0b",
    shadow_sm     = "0 1px 2px rgba(15,23,42,0.05)",
    shadow_md     = "0 4px 12px rgba(15,23,42,0.08)",
    backdrop      = "rgba(15,23,42,0.45)",
    radius        = "8px",
    radius_sm     = "6px",
    font          = "'Inter', system-ui, -apple-system, sans-serif")

# The app's own tokens (`--bt-*`): its liveness colors.
const THEME_TOKENS = CSS(":root",
        # ── Status colors — ONE source of truth for every liveness indicator
        #    (sidebar LED, in-chat dot, dashboard dot). Online = idle-healthy,
        #    active = a turn is in flight (pulses), offline = worker down.
        "--bt-status-online"  => "#16a34a",
        "--bt-status-active"  => "#16a34a",
        "--bt-status-offline" => "#dc2626",
        "--bt-status-update"  => "#f59e0b")

const BASE_STYLES = Styles(APP_THEME, BonitoWidgets.BUTTON_STYLES, THEME_TOKENS,

    # ── Reset ────────────────────────────────────────────────────────────────
    # This is a LIGHT app, and it has to SAY so. Without `color-scheme`, a user
    # whose desktop is in dark mode gets the UA's DARK defaults for every native
    # control that doesn't set its own colour: the "new project" worker dropdown
    # rendered white-on-white and read as an empty box, with nothing in any
    # stylesheet to blame for the white text. It fixes that whole class at once —
    # selects, inputs, scrollbars, the native pickers — rather than one
    # hard-coded colour per control (which is what forcing Monaco's "vs" theme in
    # chat.jl already had to do).
    #
    # `html:root` rather than plain `:root`: BonitoWidgets ships
    # `@media (prefers-color-scheme: dark) { :root { color-scheme: dark } }`, which
    # has the SAME specificity and lands later in the cascade, so a plain `:root`
    # here silently loses. The extra type selector wins on specificity instead of
    # on source order, which no amount of include-order shuffling can undo.
    CSS("html:root", "color-scheme" => "light"),
    # Class-toggle helper: collapses an element without removing it from the
    # DOM, so interactive state (a folder selection, scan results, focus)
    # survives while it is hidden.
    CSS(".bt-hidden", "display" => "none !important"),
    # The form inside a `Modal` brings its own layout, not its own chrome: the
    # card is the surface.
    CSS(".bw-modal-card .bt-form",
        "background" => "transparent", "border" => "0",
        "padding" => "0", "margin-top" => "12px"),

    # ── The one progress card (progress.jl::progress_overlay) ────────────────
    # Top-centered and fixed, because it must be findable from anywhere and must
    # not sit where the user is typing (the toast it replaces hovered over the
    # composer). It is one line tall while work runs and only grows for an
    # error, which is the one state that is worth reading.
    CSS(".bt-prog",
        "position" => "fixed",
        "top" => "10px", "left" => "50%",
        "transform" => "translateX(-50%)",
        "z-index" => "9998",
        "display" => "flex", "flex-direction" => "column",
        "gap" => "var(--bw-space-2)",
        # One fixed width, not a range: sized to its content, the card changed
        # width with every file path it showed (hundreds a second in a copy).
        # The path is cut with an ellipsis instead (`.bt-prog-msg`).
        "width" => "min(600px, 92vw)", "box-sizing" => "border-box",
        "padding" => "8px 10px 8px 12px",
        "background" => "var(--bw-bg-panel)",
        "border" => "1px solid var(--bw-border-strong)",
        "border-radius" => "var(--bw-radius)",
        "box-shadow" => "var(--bw-shadow-md)",
        "font-size" => "var(--bw-font-size-ui)",
        "color" => "var(--bw-text)"),
    CSS(".bt-prog.bt-prog-idle", "display" => "none"),
    CSS(".bt-prog.bt-prog-run", "border-color" => "var(--bw-accent)"),
    # An OUTCOME fades itself out, with no timer anywhere in Julia or JS: the
    # root's className is re-assigned on every state change, so entering :ok
    # starts this animation and leaving it removes the rule outright.
    CSS(".bt-prog.bt-prog-ok",
        "border-color" => "var(--bw-success)",
        "animation" => "bt-prog-fade 4.5s ease-in forwards"),
    CSS("@keyframes bt-prog-fade",
        CSS("0%",   "opacity" => "1"),
        CSS("80%",  "opacity" => "1"),
        CSS("100%", "opacity" => "0", "visibility" => "hidden")),
    CSS(".bt-prog.bt-prog-err", "border-color" => "var(--bw-error)"),
    CSS(".bt-prog-row",
        "display" => "flex", "align-items" => "center",
        "gap" => "var(--bw-space-2)", "min-width" => "0"),
    # Wraps rather than overflowing the fixed width: an outcome ("New chat on
    # …, with the agent's memory. …") can be longer than a line.
    CSS(".bt-prog-title",
        "font-weight" => "600", "flex" => "0 1 auto", "min-width" => "0"),
    CSS(".bt-prog-pct",
        "font-variant-numeric" => "tabular-nums",
        "color" => "var(--bw-text-muted)",
        "flex" => "0 0 auto"),
    # The only elastic part: a scrolling file path must never widen the card or
    # push the buttons out of reach.
    CSS(".bt-prog-msg",
        "color" => "var(--bw-text-muted)",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "var(--bw-font-size-xs)",
        "flex" => "1 1 0", "min-width" => "0",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),
    # Spinner only while something is actually in flight — a still card with a
    # spinning dot is how "stuck" and "working" become indistinguishable.
    CSS(".bt-prog-spin", "display" => "none"),
    CSS(".bt-prog-run .bt-prog-spin",
        "display" => "block",
        "width" => "11px", "height" => "11px", "flex" => "0 0 auto",
        "border" => "2px solid var(--bw-border-strong)",
        "border-top-color" => "var(--bw-accent)",
        "border-radius" => "50%",
        "animation" => "bt-prog-spin 0.7s steps(8) infinite"),
    CSS("@keyframes bt-prog-spin",
        CSS("from", "transform" => "rotate(0deg)"),
        CSS("to",   "transform" => "rotate(360deg)")),
    # Determinate bar, only for transfers that know their total.
    CSS(".bt-prog-bar", "display" => "none"),
    CSS(".bt-prog-run .bt-prog-bar",
        "display" => "block",
        "height" => "3px",
        "background" => "var(--bw-border)",
        "border-radius" => "999px",
        "overflow" => "hidden"),
    CSS(".bt-prog-fill",
        "height" => "100%", "width" => "0%",
        "background" => "var(--bw-accent)",
        "transition" => "width 0.12s linear"),
    # The error body: selectable, scrollable, and shown for :err only. `Copy`
    # is next to it for when selecting in a moving card is not the point.
    CSS(".bt-prog-detail", "display" => "none"),
    CSS(".bt-prog-err .bt-prog-detail",
        "display" => "block",
        "margin" => "0",
        "max-height" => "min(40vh, 320px)",
        "overflow" => "auto",
        "white-space" => "pre-wrap",
        "word-break" => "break-word",
        "user-select" => "text",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "var(--bw-font-size-xs)",
        "color" => "var(--bw-text-muted)",
        "background" => "var(--bw-bg-subtle)",
        "border-radius" => "var(--bw-radius-sm)",
        "padding" => "6px 8px"),
    # Copy belongs to the error state; dismissing a running transfer would only
    # hide it (the work keeps going), so ✕ is for the states that have ended.
    CSS(".bt-prog-copy", "display" => "none"),
    CSS(".bt-prog-err .bt-prog-copy", "display" => "inline-flex"),
    CSS(".bt-prog-close", "flex" => "0 0 auto"),
    CSS(".bt-prog-run .bt-prog-close", "display" => "none"),
)

# What each file kind shows (file_view.jl `file_viewer`): in the chat's bubbles
# and file tabs, and on a shared link's page (shares.jl).
const FILE_VIEW_CSS = [
    CSS(".bt-fv-badge",
        "font-size" => "var(--bw-font-size-2xs)", "text-transform" => "uppercase",
        "letter-spacing" => "0.04em",
        "color" => "var(--bw-text-faint)",
        "border" => "1px solid var(--bw-border)",
        "border-radius" => "999px", "padding" => "1px 7px",
        "flex-shrink" => "0", "white-space" => "nowrap"),
    CSS(".bt-fv-error", "margin" => "12px"),
    CSS(".bt-fv-loading",
        "padding" => "16px", "font-size" => "var(--bw-font-size-ui)",
        "color" => "var(--bw-text-faint)", "font-style" => "italic"),
    CSS(".bt-fv-error-title", "font-weight" => "600"),
    CSS(".bt-fv-error-detail",
        "font-family" => "ui-monospace, monospace", "font-size" => "var(--bw-font-size-sm)",
        "margin-top" => "4px", "opacity" => "0.85"),

    # Image stage: a checkerboard so transparency reads as transparency, and the
    # image centred + contained rather than pinned to the top-left.
    CSS(".bt-fv-image-stage",
        "flex" => "1 1 auto", "min-height" => "0",
        "display" => "flex", "align-items" => "center", "justify-content" => "center",
        "padding" => "12px", "overflow" => "auto",
        "background-color" => "var(--bw-bg-panel)",
        "background-image" => string(
            "linear-gradient(45deg, rgba(15,23,42,0.06) 25%, transparent 25%),",
            "linear-gradient(-45deg, rgba(15,23,42,0.06) 25%, transparent 25%),",
            "linear-gradient(45deg, transparent 75%, rgba(15,23,42,0.06) 75%),",
            "linear-gradient(-45deg, transparent 75%, rgba(15,23,42,0.06) 75%)"),
        "background-size" => "18px 18px",
        "background-position" => "0 0, 0 9px, 9px -9px, -9px 0"),
    # An IMAGE is shown at its own size, shrunk to fit. `max-height: 100%` on the
    # <img> ALONE does nothing: the percentage resolves against `.bt-media-wrap`,
    # whose own height comes from its content, so a 1500px-tall image kept every
    # pixel and ran off the bottom of the tab. The wrap has to be a flex box
    # that is allowed to shrink (`min-height: 0`) before the image inside it can.
    CSS(".bt-fv-image-stage .bt-media-wrap",
        "max-height" => "100%", "min-height" => "0", "display" => "flex"),
    CSS(".bt-fv-image-stage img.bt-media",
        "max-height" => "100%", "min-height" => "0", "object-fit" => "contain"),
    # A VIDEO instead FILLS its stage and letterboxes, the way every video player
    # behaves. Left at its intrinsic size a small clip renders as a handful of
    # pixels with the browser's controls collapsed into nothing: you can see the
    # file but you cannot play it, which is the one thing a video tab is for.
    # Sized on the WRAP (whose containing block is the stage, and so has a real
    # size) rather than by a minimum on the video — a percentage minimum there
    # resolves against the shrink-to-fit wrapper and comes out as zero.
    CSS(".bt-fv-video-stage .bt-media-wrap", "width" => "100%", "height" => "100%"),
    CSS(".bt-fv-video-stage video.bt-media",
        "width" => "100%", "height" => "100%", "object-fit" => "contain"),

    # Video gets a stage of its own: centred, on a dark backdrop (the neutral
    # surround every video player uses), and CONTAINED — `media_element` caps
    # width only, so without the max-height here a portrait or 4K clip pushes its
    # own controls off the bottom of the tab.
    CSS(".bt-fv-video-stage",
        "flex" => "1 1 auto", "min-height" => "0",
        "display" => "flex", "align-items" => "center", "justify-content" => "center",
        "padding" => "12px", "overflow" => "auto",
        "background" => "#1b1d21"),
    CSS(".bt-fv-audio-wrap",
        "display" => "flex", "flex-direction" => "column", "gap" => "8px",
        "align-items" => "center", "justify-content" => "center",
        "padding" => "24px", "flex" => "1 1 auto"),
    CSS(".bt-fv-audio", "width" => "min(520px, 100%)"),
    CSS(".bt-fv-audio-name",
        "font-size" => "var(--bw-font-size-sm)", "color" => "var(--bw-text-muted)",
        "font-family" => "ui-monospace, monospace"),

    CSS(".bt-fv-markdown",
        "padding" => "16px 22px", "overflow" => "auto",
        "flex" => "1 1 auto", "min-height" => "0"),
    # Inside a chat bubble the preview is one block among many — no pane padding,
    # and capped so a 900-line README doesn't bury the rest of the turn.
    CSS(".bt-tool-body .bt-fv-markdown",
        "padding" => "0", "max-height" => "420px"),

    # Frames (pdf / html). `border:none` + a surface background so a page that
    # doesn't set its own doesn't render as a grey void.
    CSS(".bt-fv-frame-wrap",
        "flex" => "1 1 auto", "min-height" => "0", "display" => "flex"),
    CSS(".bt-fv-frame",
        "flex" => "1 1 auto", "width" => "100%", "border" => "none",
        "background" => "#fff", "min-height" => "0"),
    CSS(".bt-tool-body .bt-fv-frame-wrap", "height" => "480px"),

    # ── Table (csv / tsv) ────────────────────────────────────────────────────
    CSS(".bt-fv-table-wrap",
        "display" => "flex", "flex-direction" => "column",
        "flex" => "1 1 auto", "min-height" => "0"),
    CSS(".bt-fv-table-bar",
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        "padding" => "6px 10px", "flex-shrink" => "0",
        "border-bottom" => "1px solid var(--bw-border)"),
    CSS(".bt-fv-table-filter",
        "flex" => "0 1 260px", "font-size" => "var(--bw-font-size-sm)",
        "padding" => "3px 8px", "border" => "1px solid var(--bw-border)",
        "border-radius" => "var(--bw-radius-sm)",
        "background" => "var(--bw-bg-panel)", "color" => "var(--bw-text)"),
    CSS(".bt-fv-table-note", "font-size" => "var(--bw-font-size-xs)", "color" => "var(--bw-text-faint)"),
    CSS(".bt-fv-table-scroll",
        "flex" => "1 1 auto", "min-height" => "0", "overflow" => "auto"),
    CSS(".bt-tool-body .bt-fv-table-scroll", "max-height" => "420px"),
    CSS(".bt-fv-table",
        "border-collapse" => "separate", "border-spacing" => "0",
        "font-size" => "var(--bw-font-size-sm)", "font-family" => "ui-monospace, monospace",
        "width" => "max-content", "min-width" => "100%"),
    CSS(".bt-fv-table th",
        # Sticky header: scrolling a 5000-row table without losing the column
        # names is most of what makes this better than looking at the raw text.
        "position" => "sticky", "top" => "0", "z-index" => "1",
        "background" => "var(--bw-bg-subtle)",
        "border-bottom" => "1px solid var(--bw-border)",
        "padding" => "5px 10px", "text-align" => "left",
        "white-space" => "nowrap", "font-weight" => "600"),
    CSS(".bt-fv-table td",
        "padding" => "3px 10px", "white-space" => "nowrap",
        "border-bottom" => "1px solid var(--bw-border)"),
    CSS(".bt-fv-table tbody tr:hover td", "background" => "var(--bw-bg-subtle)"),
    CSS(".bt-fv-table .bt-fv-num", "text-align" => "right"),
    CSS(".bt-fv-table .bt-fv-rownum",
        "color" => "var(--bw-text-faint)", "text-align" => "right",
        "user-select" => "none",
        "position" => "sticky", "left" => "0",
        "background" => "var(--bw-bg-panel)"),
    CSS(".bt-fv-table th.bt-fv-rownum", "background" => "var(--bw-bg-subtle)", "z-index" => "2"),
    CSS(".bt-fv-sortable", "cursor" => "pointer", "user-select" => "none"),
    CSS(".bt-fv-sort-arrow", "opacity" => "0.35", "margin-left" => "6px"),
    CSS(".bt-fv-sortable:hover .bt-fv-sort-arrow", "opacity" => "0.8"),

    # ── Notebook ─────────────────────────────────────────────────────────────
    CSS(".bt-fv-notebook",
        "flex" => "1 1 auto", "min-height" => "0", "overflow" => "auto",
        "padding" => "12px 16px", "display" => "flex", "flex-direction" => "column",
        "gap" => "10px"),
    # Cells keep their height: the notebook scrolls. Shrinkable cells squeezed
    # every cell of a notebook taller than its panel and clipped their outputs.
    CSS(".bt-fv-nb-cell",
        "flex-shrink" => "0",
        "border" => "1px solid var(--bw-border)",
        "border-radius" => "var(--bw-radius-sm)", "overflow" => "hidden"),
    CSS(".bt-fv-nb-md", "padding" => "2px 14px", "background" => "var(--bw-bg-panel)"),
    CSS(".bt-fv-nb-source", "background" => "var(--bw-bg-subtle)", "padding" => "6px 8px"),
    CSS(".bt-fv-nb-outputs",
        "border-top" => "1px solid var(--bw-border)", "padding" => "8px 12px",
        "background" => "var(--bw-bg-panel)"),
    CSS(".bt-fv-nb-text",
        "margin" => "0", "font-family" => "ui-monospace, monospace",
        "font-size" => "var(--bw-font-size-sm)", "white-space" => "pre-wrap",
        "max-height" => "320px", "overflow" => "auto"),
    CSS(".bt-fv-nb-image", "max-width" => "100%", "display" => "block"),
    CSS(".bt-fv-more",
        "font-size" => "var(--bw-font-size-xs)", "color" => "var(--bw-text-faint)",
        "font-style" => "italic", "padding" => "4px 2px"),

    # ── Hex dump ─────────────────────────────────────────────────────────────
    CSS(".bt-fv-hex-wrap",
        "display" => "flex", "flex-direction" => "column",
        "flex" => "1 1 auto", "min-height" => "0"),
    CSS(".bt-fv-hex-bar",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "padding" => "6px 10px", "flex-shrink" => "0"),
    CSS(".bt-fv-hex-note", "font-size" => "var(--bw-font-size-xs)", "color" => "var(--bw-text-faint)"),
    CSS(".bt-fv-hex",
        "margin" => "0", "padding" => "0 12px 12px",
        "font-family" => "ui-monospace, monospace", "font-size" => "var(--bw-font-size-sm)",
        "line-height" => "1.5", "color" => "var(--bw-text-muted)",
        "overflow" => "auto", "flex" => "1 1 auto", "min-height" => "0"),
    CSS(".bt-tool-body .bt-fv-hex", "max-height" => "360px"),
    # Read-only code that fills its box and scrolls itself (a shared link's page);
    # in a chat bubble it is static code as tall as the text (`CodeView`).
    CSS(".bt-fv-code", "flex" => "1 1 auto", "min-height" => "0", "height" => "100%"),
    CSS(".bt-fv-code > div, .bt-fv-code .monaco-editor-div", "height" => "100%", "min-height" => "0"),
]

# The 3D viewer (file_view.jl `MeshViewer`), in the chat and on shared pages.
const MESH_VIEW_CSS = [
    CSS(".bt-mesh-view",
        "position" => "relative", "flex" => "1 1 auto",
        "min-height" => "0", "display" => "flex"),
    # Inline (chat bubble) has no panel to fill, so it needs an explicit box.
    CSS(""".bt-mesh-view[data-mode="inline"]""", "height" => "360px"),
    CSS(".bt-mesh-canvas",
        "flex" => "1 1 auto", "width" => "100%", "height" => "100%",
        "display" => "block", "touch-action" => "none", "cursor" => "grab"),
    CSS(".bt-mesh-canvas:active", "cursor" => "grabbing"),
    CSS(".bt-mesh-toolbar",
        "position" => "absolute", "top" => "8px", "right" => "8px",
        "display" => "flex", "gap" => "4px"),
    CSS(".bt-mesh-btn",
        "border" => "1px solid var(--bw-border)", "background" => "var(--bw-bg-panel)",
        "color" => "var(--bw-text-muted)", "cursor" => "pointer",
        "border-radius" => "var(--bw-radius-sm)", "padding" => "4px", "line-height" => "0"),
    CSS(".bt-mesh-btn svg", "width" => "14px", "height" => "14px", "display" => "block"),
    CSS(".bt-mesh-btn:hover", "color" => "var(--bw-text)"),
    CSS(""".bt-mesh-btn[data-on="1"]""",
        "background" => "var(--bw-accent)", "color" => "#fff", "border-color" => "var(--bw-accent)"),
    CSS(".bt-mesh-btn:disabled", "opacity" => "0.4", "cursor" => "default"),
    CSS(".bt-mesh-status",
        "position" => "absolute", "left" => "10px", "bottom" => "8px",
        "font-size" => "var(--bw-font-size-xs)", "color" => "var(--bw-text-faint)",
        "pointer-events" => "none"),
]

# Pictures and clips (chat.jl `media_element`) with their hover actions and the
# click-to-enlarge lightbox: in the chat, and on a shared link's page.
const MEDIA_CSS = [
    # Media (bt_show / Read image & video) + click-to-enlarge lightbox. The wrap
    # is the hover target for the ⤢ button; the fullscreen overlay holds a clone
    # of the media and closes on backdrop click or Esc.
    # `vertical-align: top`: an inline-block sits on the text baseline, with the
    # descender gap of the line below it; at the top the line is the picture's
    # height exactly, the height a placeholder reserves for it (`bodyReserve`).
    CSS(".bt-media-wrap",
        "position" => "relative", "display" => "inline-flex", "flex-direction"=>"column", "max-width" => "100%",
        "vertical-align" => "top"),
    # Hover action row (enlarge · copy · download), top-right of the media.
    CSS(".bt-media-actions",
        "position" => "absolute", "top" => "6px", "right" => "6px",
        "display" => "flex", "gap" => "4px",
        "opacity" => "0", "transition" => "opacity 80ms"),
    CSS(".bt-media-wrap:hover .bt-media-actions", "opacity" => "1"),
    CSS(".bt-media-action",
        "appearance" => "none", "border" => "none",
        "background" => "rgba(0,0,0,0.55)", "color" => "#fff",
        "font-size" => "14px", "line-height" => "1",
        "padding" => "4px 7px", "border-radius" => "6px",
        "cursor" => "pointer"),
    CSS(".bt-media-action:hover", "background" => "rgba(0,0,0,0.8)"),
    CSS(".bt-media-enlarge", "cursor" => "zoom-in"),
    # Without hover (touch screens) the actions would stay invisible yet take
    # the taps that land on them: show them. Specific enough to win wherever it
    # lands: `Styles` merges every "@media (hover: none)" of a sheet into the
    # place of the first one, which can be before the rule it overrides.
    CSS("@media (hover: none)", CSS(".bt-media-wrap .bt-media-actions", "opacity" => "1")),
    CSS(".bt-lightbox-overlay",
        "position" => "fixed", "inset" => "0", "z-index" => "9999",
        "background" => "rgba(0,0,0,0.85)", "cursor" => "zoom-out",
        "display" => "flex", "align-items" => "center", "justify-content" => "center"),
    CSS(".bt-lightbox-media",
        "max-width" => "95vw", "max-height" => "95vh",
        "box-shadow" => "0 8px 40px rgba(0,0,0,0.6)"),
]

# Each viewer carries its own sheet, so it renders outside the dashboard too.
# Bonito renders a CSS object once per session: in the dashboard they cost nothing.
const MeshViewStyles = Bonito.Styles(APP_THEME, THEME_TOKENS, MESH_VIEW_CSS...)
const MediaStyles    = Bonito.Styles(APP_THEME, THEME_TOKENS, MEDIA_CSS...)
const FileViewStyles = Bonito.Styles(APP_THEME, THEME_TOKENS, FILE_VIEW_CSS...)

const ChatStyles = Bonito.Styles(
    BASE_STYLES,
    CSS("html, body",
        "height" => "100%", "margin" => "0", "padding" => "0",
        "overflow" => "hidden"),

    # ── App shell — flex column that fills its container ────────────────────
    # The chat is always mounted inside the unified shell's `.bt-main` slot
    # (a flex column with defined height). `width/height: 100%` + `min-height: 0`
    # makes us a well-behaved flex child: we fill the slot, and `.bt-messages`
    # below can shrink past content height to enable its internal scroll.
    CSS(".bt-app",
        "width" => "100%", "height" => "100%", "min-height" => "0",
        # position:relative so the absolutely-positioned new-message
        # pill (below) anchors to .bt-app rather than the document.
        "position" => "relative",
        "display" => "flex", "flex-direction" => "column",
        "font-family" => "'Inter', system-ui, -apple-system, sans-serif",
        "font-size" => "var(--bw-font-size)",
        "background" => "var(--bw-bg)",
        "color" => "var(--bw-text)",
        "box-sizing" => "border-box",
        "overscroll-behavior" => "none",
        "-webkit-font-smoothing" => "antialiased"),

    # ── Header ───────────────────────────────────────────────────────────────
    # Outer spans full width (border-bottom looks correct); inner row caps at
    # the same content width as messages/input on desktop.
    # Column: the main title/sync row, plus an optional session-config meta
    # line below it (see `header_meta_line`).
    CSS(".bt-header",
        "display" => "flex", "flex-direction" => "column",
        "justify-content" => "center",
        "padding" => "10px 16px",
        "background" => "var(--bw-bg-panel)",
        "border-bottom" => "1px solid var(--bw-border)",
        "flex-shrink" => "0",
        "min-height" => "44px",
        "box-sizing" => "border-box"),
    CSS(".bt-session-notice",
        "display" => "flex", "justify-content" => "space-between", "align-items" => "start",
        "gap" => "var(--bw-space-2)", "padding" => "var(--bw-space-2) var(--bw-space-4)",
        "background" => "var(--bw-bg-panel)", "border-bottom" => "1px solid var(--bw-border)",
        "flex-shrink" => "0", "max-height" => "25vh", "overflow" => "auto"),
    CSS(".bt-session-notice[hidden]", "display" => "none"),
    CSS(".bt-session-notice-body", "flex" => "1", "min-width" => "0"),
    CSS(".bt-session-notice-title", "color" => "var(--bw-warning)",
        "white-space" => "nowrap", "overflow" => "hidden", "text-overflow" => "ellipsis",
        "cursor" => "pointer"),
    CSS(".bt-session-notice-body[open] .bt-session-notice-title",
        "white-space" => "pre-wrap", "overflow-wrap" => "anywhere"),
    CSS(".bt-session-notice[data-severity='error'] .bt-session-notice-title",
        "color" => "var(--bw-error)"),
    CSS(".bt-session-notice-text", "white-space" => "pre-wrap", "overflow-wrap" => "anywhere"),
    CSS(".bt-header-row",
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        # Wrap instead of clip when the pane gets tight: the right-anchored
        # action cluster drops to its own line as a unit (and the expanded
        # collapse panel lands on its own full-width row).
        "flex-wrap" => "wrap", "row-gap" => "6px",
        "width" => "100%"),

    # ── Responsive header ────────────────────────────────────────────────────
    # The CHAT header is a size container so all breakpoints below query the
    # CHAT PANE's width — a docked plot pane can squeeze the chat on a huge
    # desktop, and a phone is just the same thing smaller. Scoped under
    # `.bt-chatpane`: the dashboard's landing header shares the `.bt-header`
    # class but has none of the collapsible elements.
    CSS(".bt-chatpane .bt-header", "container-type" => "inline-size"),
    # Collapse toggle (⋯). A checkbox in a label; checking it puts
    # `bt-header-open` on the header (`more_toggle`, chat.jl), which the rules
    # below key on. Not `:has(input:checked)`: Chrome checks a `:has()` on every
    # DOM change under its anchor, and a header rule anchored up there restyled
    # every button in the chat on each one. Hidden on wide panes.
    CSS(".bt-header-collapse-toggle",
        "display" => "none", "align-items" => "center",
        "justify-content" => "center",
        # Positioning context for the hidden checkbox below: keyboard-focusing
        # an absolutely-positioned input scrolls to where it RESOLVES, so it
        # must resolve inside its own label.
        "position" => "relative",
        "border" => "1px solid var(--bw-border)",
        "background" => "var(--bw-bg-panel)",
        "border-radius" => "6px",
        "font-size" => "var(--bw-font-size-ui)", "line-height" => "1.4",
        "padding" => "3px 9px",
        "cursor" => "pointer", "user-select" => "none",
        "flex" => "0 0 auto"),
    # The checkbox covers its label, invisible but for its own keyboard focus
    # ring, drawn around the whole toggle.
    CSS(".bt-header-collapse-toggle input",
        "position" => "absolute", "inset" => "0", "margin" => "0",
        "appearance" => "none", "background" => "transparent",
        "border-radius" => "inherit", "cursor" => "pointer"),
    CSS(".bt-header-collapse-toggle input:focus-visible",
        "outline" => "2px solid var(--bw-accent)", "outline-offset" => "1px"),
    CSS(".bt-header-collapse-toggle:hover",
        "background" => "var(--bw-bg-subtle)"),
    CSS(".bt-header.bt-header-open .bt-header-collapse-toggle",
        "background" => "var(--bw-bg-subtle)",
        "border-color" => "var(--bw-accent)"),
    # Glyph swap: ⋯ while closed, ✕ while open — the open toggle IS the
    # close button for the panel it revealed.
    CSS(".bt-header-collapse-toggle .bt-toggle-open", "display" => "none"),
    CSS(".bt-header.bt-header-open .bt-header-collapse-toggle .bt-toggle-open",
        "display" => "inline"),
    CSS(".bt-header.bt-header-open .bt-header-collapse-toggle .bt-toggle-closed",
        "display" => "none"),
    # Medium panes: the category prefixes ("model:" / "permissions:" /
    # "effort:") go — the values carry the meaning and each pill keeps its
    # long-form tooltip.
    CSS("@container (max-width: 900px)",
        CSS(".bt-header-meta-cat", "display" => "none")),
    # Narrow panes: EVERYTHING (action cluster, env path line, lens search
    # bar) collapses behind the single ⋯ toggle. Checking it expands the
    # header in flow — the action cluster wraps onto its own full-width row
    # directly under the toggle (the row is flex-wrap), then the env line and
    # the lens bar follow — so the ✕ sits right on top of the panel it closes
    # and the rest of the pane is simply pushed down (hamburger-menu style,
    # no floating dropdown).
    # The hide rules carry a `.bt-header` prefix: the base
    # `.bt-header-actions` / `.bt-lens-bar` / `.bt-header-env` rules are
    # defined LATER in this stylesheet at equal specificity and would win the
    # cascade otherwise.
    CSS("@container (max-width: 660px)",
        CSS(".bt-header-collapse-toggle",
            "display" => "inline-flex", "margin-left" => "auto"),
        CSS(".bt-header .bt-header-actions", "display" => "none"),
        CSS(".bt-header .bt-header-env", "display" => "none"),
        CSS(".bt-header .bt-lens-bar", "display" => "none"),
        # `nowrap` + `flex-start` undo the wide strip's wrapping: this is a
        # single vertical stack, and in column direction those two would wrap
        # into extra COLUMNS / bottom-align the stack.
        CSS(".bt-header.bt-header-open .bt-header-row .bt-header-actions",
            "display" => "flex", "flex-direction" => "column",
            "align-items" => "stretch", "gap" => "8px",
            "flex-wrap" => "nowrap", "justify-content" => "flex-start",
            "flex-basis" => "100%", "margin" => "6px 0 0 0"),
        # The session group stacks too: one cell per row, hairlines between them
        # now on top instead of on the left, labels centered.
        CSS(".bt-header.bt-header-open .bt-header-row .bt-header-session",
            "flex-direction" => "column", "align-items" => "stretch"),
        # The cells by class. (As `:has(...) .bt-header-session > *` this rule
        # made Chrome restyle the whole chat, 15k elements, 65 ms, on every
        # timer tick, streamed token and Monaco render, even on wide panes where
        # the container query does not apply: see e2e:style_invalidation.)
        CSS(".bt-header.bt-header-open .bt-header-row .bt-header-session :is(.bt-header-usage, .bt-header-meta-item)",
            "border-left" => "0", "margin-left" => "0",
            "border-top" => "1px solid var(--bw-border)", "margin-top" => "-1px",
            "justify-content" => "center"),
        # No menu inside the menu: the expanded panel IS the ⋯ menu. The
        # actions menu's own ⋯ trigger goes, and its popover list lays out in
        # flow as part of the stack, so every action is one tap away.
        CSS(".bt-header.bt-header-open .bt-header-row .bt-header-menu",
            "display" => "flex", "flex-direction" => "column"),
        CSS(".bt-header.bt-header-open .bt-header-row .bt-header-menu > .bw-menu-trigger",
            "display" => "none"),
        CSS(".bt-header.bt-header-open .bt-header-row .bt-header-menu > .bw-menu-list",
            "display" => "block", "position" => "static", "min-width" => "0",
            "padding" => "0", "border" => "0", "box-shadow" => "none",
            "background" => "transparent"),
        # Stacked controls all span the panel with centered labels — the Sync
        # button's compact `max-width` cap and the provider select's start
        # alignment only make sense in the wide control strip. Descendant
        # selector on purpose: the provider select / meta pills sit inside
        # `display:contents` sub-session fragments, so `> *` can't reach them.
        CSS(".bt-header.bt-header-open .bt-header-row .bt-header-actions :is(select, button)",
            "max-width" => "none", "text-align" => "center"),
        # Inside the expanded panel the config pills stack like the buttons.
        CSS(".bt-header.bt-header-open .bt-header-row .bt-header-meta",
            "flex-direction" => "column", "align-items" => "stretch",
            "white-space" => "normal"),
        # Stacked pills center their content (the pick pills are inline-flex,
        # the static ones plain text — cover both) and bring the category
        # prefixes BACK: the medium-width rule drops "model:"/"permissions:"/
        # "effort:" to save strip space, but in a stacked menu a bare
        # "default" row is ambiguous and there is plenty of width.
        CSS(".bt-header.bt-header-open .bt-header-row .bt-header-meta-item",
            "justify-content" => "center", "text-align" => "center"),
        CSS(".bt-header.bt-header-open .bt-header-row .bt-header-meta-cat",
            "display" => "inline"),
        CSS(".bt-header.bt-header-open .bt-header-env",
            "display" => "block"),
        CSS(".bt-header.bt-header-open .bt-lens-bar",
            "display" => "flex")),

    # ── Lens search bar (header) ─────────────────────────────────────────────
    # Always visible, directly under the control row.
    CSS(".bt-lens-bar",
        "display" => "flex", "flex-direction" => "column", "gap" => "6px",
        "margin-top" => "8px", "width" => "100%"),
    CSS(".bt-lens-row",
        "display" => "flex", "align-items" => "center", "gap" => "6px"),
    CSS(".bt-lens-field",
        "position" => "relative", "flex" => "1 1 auto", "display" => "flex",
        "align-items" => "center", "flex-wrap" => "wrap", "gap" => "5px",
        "padding" => "3px 30px 3px 6px",
        "border" => "1px solid var(--bw-border)", "border-radius" => "8px",
        "background" => "var(--bw-bg-subtle)"),
    CSS(".bt-lens-bar.bt-lens-on .bt-lens-field",
        "border-color" => "var(--bw-accent)",
        "background" => "rgba(59,130,246,0.06)"),
    # The input is now borderless — the .bt-lens-field is the visible box that
    # holds the committed pills + the inline input together.
    CSS("input.bt-lens-input",
        "flex" => "1 1 120px", "min-width" => "120px",
        "padding" => "3px 4px",
        "border" => "none", "background" => "transparent",
        "color" => "var(--bw-text)",
        "font-size" => "var(--bw-font-size-ui)", "box-sizing" => "border-box",
        "font-family" => "inherit"),
    # Committed clause pills.
    CSS(".bt-lens-pills",
        "display" => "inline-flex", "align-items" => "center",
        "flex-wrap" => "wrap", "gap" => "5px"),
    CSS(".bt-lens-pill",
        "display" => "inline-flex", "align-items" => "center", "gap" => "4px",
        "padding" => "2px 4px 2px 8px", "border-radius" => "6px",
        "background" => "rgba(59,130,246,0.16)",
        "border" => "1px solid rgba(59,130,246,0.35)",
        "color" => "var(--bw-text)", "font-size" => "var(--bw-font-size-sm)",
        "font-family" => "ui-monospace, monospace", "cursor" => "pointer",
        "max-width" => "260px", "white-space" => "nowrap"),
    CSS(".bt-lens-pill:hover", "border-color" => "var(--bw-accent)"),
    # Exclude pills read as "remove this" — red-tinted.
    CSS(".bt-lens-pill-ex",
        "background" => "rgba(239,68,68,0.14)",
        "border-color" => "rgba(239,68,68,0.4)"),
    CSS(".bt-lens-pill-sign", "color" => "var(--bw-error)", "font-weight" => "700"),
    CSS(".bt-lens-pill-key", "font-weight" => "600"),
    CSS(".bt-lens-pill-q",
        "color" => "var(--bw-text-muted)", "overflow" => "hidden",
        "text-overflow" => "ellipsis", "max-width" => "130px"),
    CSS(".bt-lens-pill-act",
        "font-size" => "var(--bw-font-size-2xs)", "text-transform" => "uppercase",
        "letter-spacing" => "0.04em", "padding" => "0 5px",
        "border-radius" => "999px", "background" => "var(--bw-accent)",
        "color" => "#fff"),
    CSS(".bt-lens-pill-x",
        "opacity" => "0.55", "padding" => "0 3px", "border-radius" => "4px",
        "font-size" => "9px"),
    CSS(".bt-lens-pill-x:hover", "opacity" => "1", "background" => "rgba(0,0,0,0.18)"),
    # While composing an exclude clause, tint the input box red.
    CSS(".bt-lens-bar.bt-lens-pending-ex input.bt-lens-input::placeholder",
        "color" => "var(--bw-error)"),
    CSS("input.bt-lens-input:focus", "outline" => "none"),
    CSS(".bt-lens-save",
        "position" => "absolute", "right" => "6px",
        "background" => "transparent", "border" => "none",
        "color" => "var(--bw-text-faint)", "cursor" => "pointer",
        "font-size" => "15px", "padding" => "0 2px", "line-height" => "1"),
    CSS(".bt-lens-save:hover", "color" => "var(--bw-accent)"),
    CSS(".bt-lens-go",
        "padding" => "6px 14px", "border" => "none", "border-radius" => "8px",
        "background" => "var(--bw-accent)", "color" => "#fff",
        "font-size" => "var(--bw-font-size-ui)", "cursor" => "pointer", "flex-shrink" => "0"),
    CSS(".bt-lens-go:hover", "background" => "var(--bw-accent-hover)"),
    CSS(".bt-lens-clear",
        "padding" => "6px 10px", "border" => "1px solid var(--bw-border)",
        "border-radius" => "8px", "background" => "var(--bw-bg-panel)",
        "color" => "var(--bw-text-muted)", "cursor" => "pointer",
        "font-size" => "var(--bw-font-size-sm)", "flex-shrink" => "0"),
    CSS(".bt-lens-clear:hover", "border-color" => "var(--bw-error)",
        "color" => "var(--bw-error)"),
    # Autocomplete dropdown.
    CSS(".bt-lens-autocomplete",
        "position" => "absolute", "top" => "calc(100% + 4px)", "left" => "0",
        "min-width" => "200px", "z-index" => "30",
        "background" => "var(--bw-bg-panel)",
        "border" => "1px solid var(--bw-border)", "border-radius" => "8px",
        "box-shadow" => "var(--bw-shadow-md, 0 4px 16px rgba(0,0,0,0.18))",
        "overflow" => "hidden", "padding" => "4px"),
    CSS(".bt-lens-ac-item",
        "display" => "flex", "align-items" => "baseline", "gap" => "8px",
        "padding" => "5px 10px", "border-radius" => "5px",
        "font-size" => "var(--bw-font-size-ui)", "cursor" => "pointer",
        "font-family" => "ui-monospace, monospace", "color" => "var(--bw-text)"),
    CSS(".bt-lens-ac-item.bt-ac-sel, .bt-lens-ac-item:hover",
        "background" => "var(--bw-accent)", "color" => "#fff"),
    CSS(".bt-lens-ac-label", "flex" => "0 0 auto"),
    CSS(".bt-lens-ac-hint",
        "margin-left" => "auto", "font-size" => "var(--bw-font-size-xs)",
        "opacity" => "0.6", "font-family" => "inherit"),
    CSS(".bt-lens-ac-item.bt-ac-sel .bt-lens-ac-hint", "opacity" => "0.85"),
    # Saved-lens chips.
    CSS(".bt-lens-chips",
        "display" => "flex", "flex-wrap" => "wrap", "gap" => "6px"),
    CSS(".bt-lens-chip",
        "display" => "inline-flex", "align-items" => "center", "gap" => "5px",
        "padding" => "3px 4px 3px 9px", "border-radius" => "999px",
        "background" => "var(--chip, var(--bw-bg-subtle))",
        "color" => "#fff", "font-size" => "var(--bw-font-size-xs)", "cursor" => "pointer",
        "max-width" => "180px"),
    CSS(".bt-lens-chip-label",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),
    CSS(".bt-lens-chip-x",
        "opacity" => "0.7", "padding" => "0 4px", "border-radius" => "999px",
        "font-size" => "10px"),
    CSS(".bt-lens-chip-x:hover",
        "opacity" => "1", "background" => "rgba(0,0,0,0.2)"),
    CSS(".bt-header-back",
        "color" => "var(--bw-text)", "text-decoration" => "none",
        "font-size" => "20px", "line-height" => "1",
        "padding" => "4px 10px", "border-radius" => "6px",
        "transition" => "background 80ms, color 80ms",
        "flex-shrink" => "0"),
    CSS(".bt-header-back:hover",
        "background" => "var(--bw-bg-subtle)",
        "color" => "var(--bw-accent)"),
    # Title shrinks to fit but doesn't grow — keeps the Sync button right next
    # to the title rather than pushed to the far edge.
    CSS(".bt-header-title",
        "font-weight" => "600", "font-size" => "var(--bw-font-size)",
        # A floor so the path next to it can never squeeze the chat's name to
        # nothing; the path yields first (`flex: 0 100 auto` on `.bt-header-env`).
        "min-width" => "4rem", "overflow" => "hidden",
        "text-overflow" => "ellipsis", "white-space" => "nowrap",
        "flex" => "0 1 auto"),
    # Inline-editable variant (an <input> over ProjectInfo.title). Reads as
    # plain title text until clicked; hover/focus surface a soft field so the
    # editability is discoverable. Same pattern as the worker-name edit on
    # the dashboard cards. Needs an explicit flex-grow + cap: an input has no
    # intrinsic text width, so without it the field collapses/overflows.
    CSS("input.bt-header-title-edit",
        "appearance" => "none",
        "border" => "none",
        "background" => "transparent",
        "color" => "inherit",
        "font" => "inherit",
        "font-weight" => "600",
        "outline" => "none",
        "padding" => "2px 6px",
        "margin" => "-2px -6px",
        "border-radius" => "var(--bw-radius-sm)",
        # Sized to its TEXT, not to the space available. It used to be
        # `flex: 1 1 auto` with a 420px cap, which was invisible while the title
        # sat alone before a wide gap — but the path moved onto this row, and a
        # 420px box of transparent input left it stranded mid-header. `max-width`
        # stays as the cap for a very long title; a browser without
        # `field-sizing` falls back to an input's default width, which is a
        # sensible box rather than a collapse.
        "field-sizing" => "content",
        "flex" => "0 1 auto",
        "min-width" => "4rem",
        "max-width" => "420px",
        "cursor" => "text",
        "transition" => "background 80ms, box-shadow 80ms"),
    CSS("input.bt-header-title-edit:hover",
        "background" => "var(--bw-bg-subtle)"),
    CSS("input.bt-header-title-edit:focus",
        "background" => "var(--bw-bg-subtle)",
        "box-shadow" => "inset 0 0 0 1px var(--bw-border-strong)"),
    CSS(".bt-header-cwd",
        "font-family" => "ui-monospace, monospace", "font-size" => "var(--bw-font-size-sm)",
        "color" => "var(--bw-text-muted)", "font-weight" => "400",
        "margin-left" => "6px"),
    # Project-env sub-line under the title row. Muted monospace, single line
    # with ellipsis so a long absolute path never widens the header.
    # Inline on the title row now, not a row of its own — a full-width line for
    # one short path spent a third of the header's height on nothing. It yields
    # before the title does (shrink 100 vs the title's 1, same reasoning as the
    # tool row) and ellipsizes from the LEFT, because the tail of a path is the
    # part that identifies it.
    CSS(".bt-header-env",
        "font-family" => "ui-monospace, monospace", "font-size" => "var(--bw-font-size-xs)",
        "color" => "var(--bw-text-muted)", "font-weight" => "400",
        "flex" => "0 100 auto", "min-width" => "0",
        "direction" => "rtl", "text-align" => "left",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),
    # `direction: rtl` moves the ellipsis to the front; this keeps the path
    # itself reading left-to-right inside it.
    CSS(".bt-header-env", "unicode-bidi" => "plaintext"),
    # ── Reconnect chip ───────────────────────────────────────────────────────
    # Shown next to the title only when the agent session has died (hidden via
    # `bt-hidden` otherwise): the one failure the user must notice without
    # opening anything. Danger-tinted with a gentle pulse; the error text rides
    # on its title attribute. ~1.4 s loop reads as "needs attention" rather
    # than "everything is broken".
    CSS(".bt-header-reconnect",
        "appearance" => "none",
        "border" => "1px solid #fca5a5",
        "background" => "#fee2e2",
        "color" => "#b91c1c",
        "font" => "inherit", "font-size" => "var(--bw-font-size-sm)", "font-weight" => "600",
        "padding" => "4px 10px",
        "border-radius" => "var(--bw-radius-sm)",
        "cursor" => "pointer",
        "white-space" => "nowrap",
        "flex" => "0 0 auto"),
    # The pulse is a ring on its own layer whose opacity animates (no repaint;
    # see bt-pulse-glow).
    CSS(".bt-header-restart-dead", "position" => "relative"),
    CSS(".bt-header-restart-dead::after",
        "content" => "\"\"", "position" => "absolute", "inset" => "0",
        "border-radius" => "inherit", "pointer-events" => "none",
        "box-shadow" => "0 0 0 6px rgba(220,38,38,0.15)",
        "animation" => "bt-restart-pulse 1.4s steps(4, jump-none) infinite"),
    CSS(".bt-header-restart-dead:hover",
        "background" => "#fecaca"),
    CSS("@keyframes bt-restart-pulse",
        CSS("0%, 100%", "opacity" => "0"),
        CSS("50%",      "opacity" => "1")),
    # While a restart is running the chip shows this "working" state instead of
    # the red pulse — it reads as "restarting…", not as a failure to click
    # again; the handler ignores clicks meanwhile.
    CSS(".bt-header-restart-busy",
        "background" => "var(--bw-bg-panel)",
        "border-color" => "var(--bw-border-strong)",
        "color" => "var(--bw-text-muted)",
        "font-weight" => "500",
        "cursor" => "progress",
        "animation" => "bt-restart-working 1s steps(3, jump-none) infinite"),
    CSS("@keyframes bt-restart-working",
        CSS("0%, 100%", "opacity" => "0.5"),
        CSS("50%",      "opacity" => "0.9")),
    # ── Session group ────────────────────────────────────────────────────────
    # The context meter, the config pills (model · permissions · effort) and the
    # provider switcher as ONE segmented control: a single border around the
    # group, hairlines between the cells. Each cell brings its own left border,
    # pulled 1px outside the group, so the first VISIBLE cell's line is clipped
    # by the group's `overflow: hidden` — no stray line no matter which cells are
    # hidden (the meter until the first turn, the pills mid-switch). The pills
    # keep their own classes (and tests); the `.bt-header-actions` prefix gives
    # these rules the specificity to override the pill chrome regardless of
    # source order.
    CSS(".bt-header-session",
        "display" => "inline-flex", "align-items" => "stretch",
        "border" => "1px solid var(--bw-border-strong)",
        "border-radius" => "var(--bw-radius-sm)",
        "background" => "var(--bw-bg-panel)",
        "overflow" => "hidden",
        "max-width" => "100%",
        "flex" => "0 1 auto", "min-width" => "0"),
    # `display: contents` dissolves the wrapper so its CHILD becomes the flex
    # cell. `.bt-header-meta` always needed this; `.bt-msearch` started needing
    # it when every pill became a `dropdown_pill`, which wraps its trigger in
    # one. Without it the visible pill sits at `.bt-header-session > .bt-msearch
    # > .bt-msearch-trigger` — one level deeper than the reset below reaches —
    # so it kept `.bt-header-meta-item`'s own border, background and 6px radius
    # INSIDE the group's border: every pill drawn twice, which is what "what on
    # earth happened to the buttons" looked like.
    # (Safe now: `.bt-msearch-list` is `position: fixed` and placed by JS from
    # the trigger's rect, so it no longer needs `.bt-msearch` as its containing
    # block.)
    CSS(".bt-header-actions .bt-header-session > *, " *
        ".bt-header-actions .bt-header-session .bt-header-meta > *, " *
        ".bt-header-actions .bt-header-session .bt-msearch > .bt-msearch-trigger",
        "border" => "0", "border-left" => "1px solid var(--bw-border)",
        "margin-left" => "-1px",
        "border-radius" => "0", "background" => "transparent",
        "padding" => "4px 10px",
        "font-size" => "var(--bw-font-size-sm)", "line-height" => "18px",
        "display" => "inline-flex", "align-items" => "center",
        "white-space" => "nowrap", "cursor" => "default"),
    # AFTER the reset above, and that ORDER is the whole point. The reset sets
    # `display: inline-flex` on every cell it matches; this selector has the
    # SAME specificity (0,3,0), so declared earlier it silently lost and the
    # wrapper kept a box — with its own `border-left` sitting 0.7px from the
    # trigger's, which is the doubled `[ |` at the group's left edge. Dissolving
    # the wrapper leaves exactly one cell, and one hairline, per pill.
    CSS(".bt-header-actions .bt-header-session .bt-header-meta, " *
        ".bt-header-actions .bt-header-session .bt-msearch",
        "display" => "contents"),
    CSS(".bt-header-actions .bt-header-session .bt-header-meta-pick, " *
        ".bt-header-actions .bt-header-session .bt-msearch",
        "cursor" => "pointer"),
    # The caret: its own span so it can sit on the pill's centre line instead of
    # the text baseline, muted so the VALUE is what the eye lands on.
    CSS(".bt-msearch-caret",
        "font-size" => "9px", "line-height" => "1",
        "margin-left" => "5px",
        "color" => "var(--bw-text-faint)",
        "flex" => "0 0 auto",
        "transform" => "translateY(0.5px)"),
    CSS(".bt-msearch-value", "font-weight" => "500"),
    CSS(".bt-header-actions .bt-header-session .bt-header-meta-pick:hover",
        "background" => "var(--bw-bg-subtle)"),
    # The context meter ("21.8k/200k · 11% · $0.42", usage_update telemetry):
    # the one thing the user reads all the time, so it stays in the strip. Mono
    # digits; the colour follows how full the window is (see `usage_class`), so
    # "nearly out of context" is visible without reading the number.
    CSS(".bt-header-usage",
        "font-family" => "ui-monospace, monospace",
        "font-variant-numeric" => "tabular-nums",
        "color" => "var(--bw-text-muted)"),
    CSS(".bt-header-actions .bt-header-session .bt-header-usage-warn",
        "color" => "#b45309", "background" => "rgba(245,158,11,0.10)"),
    CSS(".bt-header-actions .bt-header-session .bt-header-usage-high",
        "color" => "#b91c1c", "background" => "rgba(239,68,68,0.10)", "font-weight" => "600"),
    # No usage reported yet: an empty label (`usage_class`).
    CSS(".bt-header-usage-empty", "display" => "none !important"),
    # (The provider switcher's own rules are gone with its native <select>: it
    # is a `dropdown_pill` now, styled by the `.bt-msearch` / `.bt-header-meta`
    # rules above like every other pill in the strip.)
    # The ⋯ trigger turns red while dev mode is on: that this chat's agent can
    # drive the whole server should be legible without opening the menu.
    CSS(".bw-menu-trigger",
        "font-weight" => "700", "padding-left" => "8px", "padding-right" => "8px"),
    CSS(".bt-menu-trigger-danger",
        "border-color" => "rgba(239,68,68,0.5)", "color" => "var(--bw-error)"),
    # ── Per-chat capability switches (chat.jl::capability_item) ──────────────
    # The state is rendered from the CLASS and nothing else — no text
    # Observable aimed at a node a pruned pane may have taken with it. Every
    # state is spelled out, including OFF: an item that just reads "Dev mode"
    # tells you nothing about whether your click did anything.
    CSS(".bt-cap-item::after", "content" => "\": off\"", "opacity" => "0.7"),
    CSS(".bt-cap-item.bt-cap-on::after", "content" => "\": on\"", "opacity" => "1"),
    # In flight (dev mode restarts the session, which takes seconds). The item
    # also stops accepting clicks while this is set — see `capability_item`.
    CSS(".bt-cap-item.bt-cap-busy::after", "content" => "\": …\""),
    CSS(".bt-cap-item.bt-cap-busy", "opacity" => "0.6", "cursor" => "default"),
    # ON is an accent, not a warning: running Julia on another of YOUR machines
    # is a normal thing to want. Dev mode is `bw-menu-danger` on top of this,
    # because it hands the agent the whole server.
    CSS(".bt-cap-item.bt-cap-on", "font-weight" => "600"),
    CSS(".bt-cap-item.bt-cap-on:not(.bw-menu-danger)", "color" => "var(--bw-accent)"),
    # Transient status of a long-running header action ("Switching to…",
    # "Continuing on MacBook: Sending 12/40…"). Lives in the flexible left
    # area (before the auto-margin), capped + ellipsized so it never reflows
    # the control cluster; the full text rides on the tooltip.
    CSS(".bt-header-status",
        "font-size" => "var(--bw-font-size-sm)",
        "color" => "var(--bw-text-muted)",
        "white-space" => "nowrap",
        "flex" => "0 1 auto",
        "min-width" => "0",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis",
        "max-width" => "320px"),
    # ── Session-config meta line (model / mode / effort — `header_meta_line`).
    # Plain muted text below the title row; items joined with " · ", full
    # descriptions in the per-item tooltip.
    # Sits inline in the control row (the session-config "model" picks). Shrinks
    # and ellipsizes before the fixed buttons do; pushed to the right by the
    # title's flex-grow.
    # A pill-less session (`session_meta` empty) renders the meta div with no
    # children — drop it from the flex flow entirely, or its zero-width box
    # still costs a gap slot (a phantom extra gap before the provider select
    # in the strip AND in the collapsed-header panel). The rule un-applies by
    # itself the moment pills arrive.
    CSS(".bt-header-meta:empty", "display" => "none !important"),
    CSS(".bt-header-meta",
        "font-size" => "var(--bw-font-size-sm)",
        "color" => "var(--bw-text-muted)",
        # ONE inline row of config pills (model · mode · effort), kept to the LEFT
        # of the provider/sync/restart buttons. A flex row (not a text block) so
        # the interactive <select> pills — which are block-level <div>s — line up
        # horizontally instead of stacking vertically. No max-width/ellipsis: all
        # three stay fully visible on a single line.
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "flex" => "0 1 auto", "min-width" => "0",
        "white-space" => "nowrap"),
    # The right-anchored control cluster (provider switcher · sync · restart).
    # `margin-left:auto` pushes it to the right edge; because the model pill and
    # status text live OUTSIDE it (to its left), their width changes are absorbed
    # by the gap and never move these buttons.
    # Wraps onto further lines rather than spilling. With `flex: 0 0 auto` and
    # the default `nowrap` the cluster was ONE unshrinkable row item ~1124px
    # wide, so every pane between the 660px collapse breakpoint and ~1140px ran
    # it past the header edge — and `html,body {overflow:hidden}` cut it there
    # with no scrollbar to reach the rest (measured: 440px lost at a 700px pane,
    # which ate the Restart button).
    CSS(".bt-header-actions",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "flex-wrap" => "wrap", "justify-content" => "flex-end", "row-gap" => "6px",
        "margin-left" => "auto", "flex" => "0 1 auto",
        "min-width" => "0", "max-width" => "100%"),
    # Config pills (model · mode · effort) share the SAME chrome as the
    # provider/sync/restart buttons — a bordered pill on `--bw-bg-panel`, 12px,
    # 4px/10px padding, 6px radius — so the whole header reads as one uniform
    # control strip. Interactive pills (`-pick`) wrap a chrome-stripped <select>
    # (the pill carries the border, exactly like the bare provider <select>);
    # static single-choice pills (`-item`) are the same pill without a select.
    CSS(".bt-header-meta-item",
        "appearance" => "none",
        "border" => "1px solid var(--bw-border)",
        "background" => "var(--bw-bg-panel)",
        "color" => "var(--bw-text)",
        "font-size" => "var(--bw-font-size-sm)", "padding" => "4px 10px",
        "border-radius" => "6px",
        "white-space" => "nowrap",
        "cursor" => "default"),
    CSS(".bt-header-meta-pick",
        # inline-flex so a prefix label ("mode:"/"effort:") and its <select> sit
        # on the same baseline within the pill.
        "display" => "inline-flex", "align-items" => "center",
        "border" => "1px solid var(--bw-border)",
        "background" => "var(--bw-bg-panel)",
        "color" => "var(--bw-text)",
        "font-size" => "var(--bw-font-size-sm)", "padding" => "4px 10px",
        "border-radius" => "6px",
        "white-space" => "nowrap",
        "cursor" => "pointer",
        "transition" => "background 80ms"),
    CSS(".bt-header-meta-pick:hover",
        "background" => "var(--bw-bg-subtle)"),
    CSS(".bt-header-meta-pick:focus-within",
        "outline" => "2px solid var(--bw-accent)",
        "outline-offset" => "1px"),
    # A provider switch in flight: the pill reads "switching to X…" in the
    # accent colour, a spinner replaces the caret, and clicks are ignored until
    # the new session is up (a failure surfaces as a toast).
    CSS(".bt-msearch-busy", "pointer-events" => "none", "color" => "var(--bw-accent)"),
    CSS(".bt-msearch-busy .bt-msearch-caret", "display" => "none"),
    CSS(".bt-msearch-busy::after",
        "content" => "\"\"", "display" => "inline-block", "flex" => "0 0 auto",
        "width" => "10px", "height" => "10px", "margin-left" => "6px",
        "border" => "2px solid var(--bw-border-strong)",
        "border-top-color" => "var(--bw-accent)", "border-radius" => "50%",
        "animation" => "bt-prog-spin 0.7s steps(8) infinite"),
    # The <select> is chrome-stripped — the pill wrapper carries the
    # border/background, matching the bare provider <select> (which has no arrow
    # either, so they stay identical).
    CSS(".bt-header-meta-select",
        "appearance" => "none",
        "-webkit-appearance" => "none",
        "-moz-appearance" => "none",
        "background" => "transparent",
        "border" => "0",
        "outline" => "0",
        "color" => "inherit",
        "font" => "inherit",
        "padding" => "0",
        "margin" => "0",
        "cursor" => "pointer"),
    # Muted category prefix ("model:" / "permissions:" / "effort:") on each pill.
    CSS(".bt-header-meta-cat",
        "color" => "var(--bw-text-muted)",
        "user-select" => "none"),

    # ── Searchable config dropdown (model search) ────────────────────────────
    # Appears when a ConfigOption has more choices than MODEL_SEARCH_THRESHOLD.
    CSS(".bt-msearch",
        "position" => "relative", "display" => "inline-block"),
    CSS(".bt-msearch-trigger",
        "cursor" => "pointer", "user-select" => "none"),
    # `fixed`, and placed by `msearchOpen` from the trigger's rect: the pill sits
    # inside the header's segmented session group, which CLIPS (`overflow:hidden`
    # keeps the group's own left border off the first visible cell). An
    # absolutely-positioned list would be cut off at the group's edge.
    CSS(".bt-msearch-list",
        "display" => "none",
        "position" => "fixed", "top" => "0", "left" => "0",
        "z-index" => "200",
        "min-width" => "240px", "max-height" => "320px",
        "background" => "var(--bw-bg-panel)",
        "border" => "1px solid var(--bw-border)",
        "border-radius" => "6px",
        "box-shadow" => "0 4px 16px rgba(0,0,0,0.15)",
        "flex-direction" => "column", "overflow" => "hidden"),
    CSS(".bt-msearch-open > .bt-msearch-list", "display" => "flex"),
    CSS(".bt-msearch-input",
        "flex" => "0 0 auto",
        "border" => "none", "border-bottom" => "1px solid var(--bw-border)",
        "background" => "transparent", "color" => "var(--bw-text)",
        "font" => "inherit", "font-size" => "var(--bw-font-size-sm)",
        "padding" => "6px 10px", "outline" => "none"),
    CSS(".bt-msearch-items",
        "overflow-y" => "auto", "flex" => "1"),
    CSS(".bt-msearch-item",
        "padding" => "5px 10px",
        "cursor" => "pointer", "font-size" => "var(--bw-font-size-sm)",
        "white-space" => "nowrap", "overflow" => "hidden",
        "text-overflow" => "ellipsis", "color" => "var(--bw-text)"),
    CSS(".bt-msearch-item:hover", "background" => "var(--bw-bg-subtle)"),
    CSS(".bt-msearch-item-cur",
        "font-weight" => "600", "color" => "var(--bw-accent)"),

    # ── Home "Defaults" control ───────────────────────────────────────────────
    # A labelled row of the same config pills, wired to the server-wide defaults.
    # Lives in the home "Defaults" section; the pills reuse `.bt-header-meta*`.
    CSS(".bt-defaults",
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        "flex-wrap" => "wrap"),
    CSS(".bt-defaults-label",
        "font-size" => "var(--bw-font-size-ui)", "color" => "var(--bw-text-muted)",
        "user-select" => "none"),
    # The pill row: same flex chrome as the header meta strip, but allowed to wrap
    # (the home has room, unlike the single-line chat header).
    CSS(".bt-defaults-bar",
        "flex-wrap" => "wrap"),

    # ── Home "Debug BonitoAgents" control ────────────────────────────────────
    # The worker picker and its button on one row; the picker borrows the
    # secondary button's chrome so the pair reads as one control.
    CSS(".bt-debug-row",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "flex-wrap" => "wrap"),
    CSS(".bt-debug-worker",
        "font-size" => "var(--bw-font-size-ui)", "padding" => "5px 8px",
        "border" => "1px solid var(--bw-border)", "border-radius" => "6px",
        "background" => "var(--bw-bg-panel)", "color" => "var(--bw-text)"),
    CSS(".bt-debug-noworker",
        "font-size" => "var(--bw-font-size-sm)", "color" => "var(--bw-text-muted)"),

    # ── Status dot (online/offline/streaming) ────────────────────────────────
    # Shared liveness dot (chat header, dashboard). Same status palette as the
    # sidebar LED. `vertical-align: middle` keeps it centered against the title
    # text it sits next to (it used to ride high / look detached in the header).
    CSS(".bt-dot",
        "display" => "inline-block",
        "width" => "8px", "height" => "8px",
        "border-radius" => "50%", "flex-shrink" => "0",
        "vertical-align" => "middle"),
    CSS(".bt-dot-online",
        "background" => "var(--bt-status-online)"),
    CSS(".bt-dot-offline", "background" => "var(--bt-status-offline)"),
    CSS(".bt-dot-update", "background" => "var(--bt-status-update)"),
    # No side margin: the card pads its rows, and these line up with the title.
    CSS(".bt-worker-update-note",
        "display" => "block", "font-size" => "var(--bw-font-size-sm)", "color" => "#92400e"),
    # An update running by itself: nothing to act on.
    CSS(".bt-worker-update-note-info", "color" => "var(--bw-text-muted)"),
    CSS(".bt-worker-update-note-error", "color" => "var(--bw-error)"),
    # The step's elapsed time in its badge; fixed-width digits so it does not jitter.
    CSS(".bt-update-elapsed",
        "font-variant-numeric" => "tabular-nums", "opacity" => "0.8"),
    CSS(".bt-worker-adapters",
        "display" => "block", "font-size" => "var(--bw-font-size-sm)", "color" => "var(--bw-text-muted)"),
    # npm's reason comes as several lines; keep them apart.
    CSS(".bt-worker-adapters-error",
        "display" => "block", "color" => "var(--bw-error)", "white-space" => "pre-line"),

    # (The old `.bt-banner-error` / `.bt-banner-detail` session-ended banner
    # has been removed: the reconnect chip next to the title is the failure
    # indicator — see `.bt-header-reconnect` above; the error text rides on
    # its title attribute, set reactively from `model.last_error`.)

    # ── Messages container ───────────────────────────────────────────────────
    # Fills `.bt-main` (no centered 880px column) — the user complained that a
    # centered messages column left a dead band of empty space between its
    # right scrollbar and the shell border. Individual bubbles still cap their
    # own width (see `.bt-user-msg`/`.bt-agent-msg` `max-width: min(…)`) so a
    # very wide viewport doesn't sprawl any single message.
    # overflow-anchor: NONE — the transcript owns scroll anchoring (rows
    # loaded above the reader, rows changing height above the viewport).
    # With the browser's native anchoring on as well, two systems would
    # correct the same scroll position: jumpy, and not deterministic.
    # No native scrollbar: it only knows the loaded block of messages. The
    # rail below stands in for it, by message count over the whole chat.
    CSS(".bt-messages",
        "flex" => "1 1 0", "min-height" => "0",
        "overflow-y" => "auto", "overflow-x" => "hidden",
        "-webkit-overflow-scrolling" => "touch",
        "overscroll-behavior-y" => "contain",
        "overflow-anchor" => "none",
        "scrollbar-width" => "none",
        "padding" => "16px",
        "display" => "flex", "flex-direction" => "column",
        "gap" => "10px",
        "width" => "100%",
        "box-sizing" => "border-box"),
    CSS(".bt-messages::-webkit-scrollbar", "display" => "none"),
    CSS(".bt-rows-end", "flex-shrink" => "0", "overflow-anchor" => "none"),
    # The rail (bonitoagents.js `setupRail`): a thin thumb at the right edge of
    # the messages, wider while hovered or dragged, with a label naming the
    # message a drag would land on. The hit area is wider than the thumb, for
    # a finger on a phone.
    CSS(".bt-rail",
        "position" => "absolute", "top" => "6px", "bottom" => "6px", "right" => "0",
        "width" => "16px", "z-index" => "5",
        "touch-action" => "none", "cursor" => "pointer", "user-select" => "none"),
    CSS(".bt-rail.bt-rail-hidden", "display" => "none"),
    CSS(".bt-rail-thumb",
        "position" => "absolute", "top" => "0", "right" => "4px",
        "width" => "6px", "height" => "40px",
        "border-radius" => "3px",
        "background" => "var(--bw-border-strong)",
        "transition" => "width 120ms ease, background 120ms ease"),
    CSS(".bt-rail:hover .bt-rail-thumb, .bt-rail.bt-rail-active .bt-rail-thumb",
        "width" => "9px", "background" => "var(--bw-text-faint)"),
    CSS(".bt-rail-label",
        "position" => "absolute", "top" => "8px", "right" => "20px",
        "white-space" => "nowrap", "font-size" => "var(--bw-font-size-sm)",
        "padding" => "4px 8px", "border-radius" => "var(--bw-radius-sm)",
        "background" => "var(--bw-bg-panel)", "color" => "var(--bw-text)",
        "border" => "1px solid var(--bw-border)", "box-shadow" => "var(--bw-shadow-sm)",
        "font-variant-numeric" => "tabular-nums",
        "pointer-events" => "none", "opacity" => "0", "transition" => "opacity 120ms ease"),
    CSS(".bt-rail.bt-rail-active .bt-rail-label", "opacity" => "1"),

    # Rubberband for the grab-to-pan handler (bonitoagents.js): when the
    # user drags past either edge, JS accumulates an overscroll distance
    # into `--bt-overscroll` on the container; each direct child of
    # `.bt-messages` mirrors that translateY so the content rubberbands
    # while the container box (and its scrollbar) stay put. Identity
    # `translateY(0)` is the resting state so the rule is always live and
    # paints aren't gated on JS having ever set the var. Native scrolling
    # is untouched — overscroll-behavior-y: contain (above) just stops
    # the bounce from leaking to the parent; rubberband is exclusively
    # the pan handler's affordance.
    # Rubberband translateY, applied ONLY while actively overscrolling
    # (`bt-overscrolling` is toggled by the pan handler's setOverscroll). A
    # non-`none` transform on every child promotes each to its own stacking
    # context and defeats native scroll compositing — so we keep it off for
    # steady-state scrolling and switch it on only for the brief rubberband.
    CSS(".bt-messages.bt-overscrolling > *",
        "transform" => "translateY(var(--bt-overscroll, 0px))"),
    # While the user is panning, the cursor lands as grabbing on any
    # child (text bubbles included): the gesture has hijacked the
    # selection cursor for the duration. Cleared on pointerup so reading
    # cursors snap back without ghost-state.
    CSS(".bt-messages-grabbing, .bt-messages-grabbing *",
        "cursor" => "grabbing !important",
        "user-select" => "none"),

    # ── User message ─────────────────────────────────────────────────────────
    # max-width caps the bubble at a comfortable reading width on wide screens.
    # `flex-shrink: 0` is defensive (see .bt-tool-msg note) — even though
    # this rule has no `overflow` today, future styling shouldn't be able to
    # make message bubbles collapse when the column is over-full.
    CSS(".bt-user-msg",
        "flex-shrink" => "0",
        "align-self" => "flex-end",
        "max-width" => "min(80%, 640px)",
        "background" => "var(--bw-accent)", "color" => "#fff",
        "border-radius" => "12px 12px 2px 12px",
        "padding" => "10px 14px",
        "font-size" => "var(--bw-font-size)", "line-height" => "1.5",
        "white-space" => "pre-wrap", "word-break" => "break-word",
        "box-shadow" => "var(--bw-shadow-sm)",
        "position" => "relative",
        "transition" => "opacity 160ms ease"),
    # Pending messages occupy one line each; details/actions expand on demand.
    CSS(".bt-message-queue", "align-self" => "stretch", "max-height" => "24vh", "overflow-y" => "auto",
        "border" => "1px solid var(--bw-border)", "border-radius" => "var(--bw-radius-sm)"),
    CSS(".bt-message-queue:empty, .bt-queue-delivery:empty, .bt-message-queue[hidden], .bt-send-mode-menu[hidden]",
        "display" => "none"),
    CSS(".bt-queue-item + .bt-queue-item", "border-top" => "1px solid var(--bw-border)"),
    CSS(".bt-queue-summary", "display" => "flex", "align-items" => "center",
        "gap" => "var(--bw-space-2)", "padding" => "var(--bw-space-2)", "cursor" => "pointer",
        "min-height" => "36px", "box-sizing" => "border-box", "list-style" => "none"),
    CSS(".bt-queue-summary::-webkit-details-marker", "display" => "none"),
    CSS(".bt-queue-summary::before", "content" => "'▸'", "color" => "var(--bw-text-muted)"),
    CSS(".bt-queue-item[open] > .bt-queue-summary::before", "content" => "'▾'"),
    CSS(".bt-queue-preview", "flex" => "1", "min-width" => "0", "overflow" => "hidden",
        "text-overflow" => "ellipsis", "white-space" => "nowrap", "font-size" => "var(--bw-font-size-ui)"),
    CSS(".bt-queue-badge, .bt-queue-status", "font-size" => "var(--bw-font-size-sm)", "color" => "var(--bw-text-muted)"),
    CSS(".bt-queue-badge", "flex-shrink" => "0", "white-space" => "nowrap"),
    CSS(".bt-queue-item[data-status=paused] .bt-queue-badge, .bt-queue-item[data-status=offline] .bt-queue-badge",
        "color" => "var(--bw-warning)"),
    CSS(".bt-queue-text", "white-space" => "pre-wrap", "overflow-wrap" => "anywhere",
        "max-height" => "5em", "overflow-y" => "auto"),
    CSS(".bt-queue-detail", "padding" => "0 var(--bw-space-2) var(--bw-space-2)",
        "display" => "flex", "flex-direction" => "column", "gap" => "var(--bw-space-1)"),
    CSS(".bt-queue-actions, .bt-send-mode", "display" => "flex",
        "align-items" => "center"),
    CSS(".bt-queue-actions", "gap" => "var(--bw-space-2)"),
    CSS(".bt-cancel-status", "display" => "flex", "align-self" => "stretch", "align-items" => "center",
        "justify-content" => "space-between", "gap" => "var(--bw-space-2)",
        "padding" => "var(--bw-space-2)", "color" => "var(--bw-text-muted)",
        "font-size" => "var(--bw-font-size-ui)"),
    CSS(".bt-cancel-status[hidden]", "display" => "none"),
    # Announce delivery to screen readers; the delivered message itself is
    # visible in history. No separate receipt control in the composer.
    CSS(".bt-queue-delivery", "position" => "absolute", "width" => "1px", "height" => "1px",
        "overflow" => "hidden", "clip-path" => "inset(50%)", "white-space" => "nowrap"),
    CSS(".bt-send-mode", "position" => "relative"),
    CSS(".bt-send-mode-trigger", "min-height" => "36px", "padding" => "0",
        "font-size" => "var(--bw-font-size-xs)", "white-space" => "nowrap", "gap" => "var(--bw-space-1)",
        "justify-content" => "center"),
    CSS(".bt-send-mode-trigger::after", "content" => "'▾'", "flex-shrink" => "0"),
    # A narrow phone with a wide font has no room for the whole label: it ends
    # in an ellipsis instead of running out of the button.
    CSS(".bt-send-mode-label", "overflow" => "hidden", "text-overflow" => "ellipsis"),
    CSS(".bt-send-mode-menu", "position" => "absolute", "bottom" => "calc(100% + var(--bw-space-2))",
        "right" => "0", "max-width" => "calc(100vw - 2 * var(--bw-space-4))",
        "z-index" => "40", "display" => "flex", "flex-direction" => "column",
        "background" => "var(--bw-bg-panel)", "border" => "1px solid var(--bw-border)",
        "border-radius" => "var(--bw-radius-sm)", "box-shadow" => "var(--bw-shadow-sm)"),
    CSS(".bt-send-mode-option", "white-space" => "nowrap", "text-align" => "left", "min-height" => "40px"),
    CSS(".bt-send-mode-option[aria-checked=true]", "color" => "var(--bw-accent)"),
    # Yolo auto-continue nudge: an app-generated (not user) bubble. Muted so it
    # reads as a system message — dimmer, desaturated accent, lighter weight.
    CSS(".bt-user-msg.bt-user-msg-auto",
        "opacity" => "0.6",
        "background" => "color-mix(in srgb, var(--bw-accent) 45%, var(--bw-bg-subtle))",
        "font-style" => "italic"),
    # Inline attachment gallery under the user's text (createNode's `user`
    # case builds it from the wire `attachments` list). Thumbs are bounded —
    # the lightbox is the full-size view — and sit on the accent bubble, so a
    # translucent white seam separates image edges from the blue.
    CSS(".bt-user-attachments",
        "display" => "flex", "flex-wrap" => "wrap", "gap" => "6px",
        "margin-top" => "8px"),
    # One height for every thumbnail, known before the picture loads: the row
    # has its final height from the start (a max-height grew it from 40 px to
    # the picture's height when the bytes arrived, under the reader's feet).
    # Only the width follows the picture. `scale-down` shows a tiny one (a
    # pasted icon) at its own size, centered, never stretched.
    CSS(".bt-user-att-img",
        "box-sizing" => "border-box",     # the same box as the fallback below
        "height" => "120px", "width" => "auto", "max-width" => "220px",
        "min-width" => "40px",
        "object-fit" => "scale-down",
        "background" => "rgba(255,255,255,0.15)",
        "border-radius" => "8px",
        "border" => "1px solid rgba(255,255,255,0.35)",
        "cursor" => "zoom-in",
        "display" => "block"),
    # Fallback when the file is gone (project moved / cleaned): the name in
    # small type instead of a broken-image icon.
    CSS(".bt-user-att-missing",
        "display" => "inline-flex", "align-items" => "center", "box-sizing" => "border-box",
        "height" => "120px", "max-width" => "220px", "padding" => "0 10px",
        "border-radius" => "8px", "border" => "1px dashed rgba(255,255,255,0.35)",
        "overflow" => "hidden", "text-overflow" => "ellipsis", "white-space" => "nowrap",
        "font-size" => "var(--bw-font-size-xs)", "opacity" => "0.8",
        "font-family" => "ui-monospace, monospace"),
    # A file that is not an image: its name as a link on the bubble.
    CSS(".bt-user-att-file",
        "display" => "inline-block", "max-width" => "260px",
        "overflow" => "hidden", "text-overflow" => "ellipsis", "white-space" => "nowrap",
        "padding" => "4px 10px", "border-radius" => "8px",
        "background" => "rgba(255,255,255,0.15)",
        "border" => "1px solid rgba(255,255,255,0.35)",
        "color" => "inherit", "font-size" => "var(--bw-font-size-sm)", "text-decoration" => "none"),
    CSS(".bt-user-att-file:hover", "background" => "rgba(255,255,255,0.25)"),

    # ── Agent message ────────────────────────────────────────────────────────
    CSS(".bt-agent-msg",
        "flex-shrink" => "0",
        "align-self" => "flex-start",
        "max-width" => "min(85%, 760px)",
        "background" => "var(--bw-bg-panel)",
        "border" => "1px solid var(--bw-border)",
        "border-radius" => "2px 12px 12px 12px",
        "padding" => "10px 14px",
        "font-size" => "var(--bw-font-size)", "line-height" => "1.55",
        "word-break" => "break-word",
        "box-shadow" => "var(--bw-shadow-sm)"),

    # While a bubble streams we show the raw text (markdown isn't parsed
    # until finalize). `pre-wrap` keeps the agent's newlines visible —
    # without it `white-space: normal` collapses every `\n` to a space and
    # the whole message renders as one run-on paragraph until finalize.
    CSS(".bt-stream-text",
        "white-space" => "pre-wrap", "word-break" => "break-word"),
    # Streaming cursor blink
    CSS(".bt-stream-text::after",
        "content" => "\"▋\"",
        "animation" => "bt-cursor 0.8s step-end infinite",
        "color" => "var(--bw-accent)",
        "margin-left" => "1px"),
    CSS("@keyframes bt-cursor",
        CSS("0%, 100%", "opacity" => "1"),
        CSS("50%", "opacity" => "0")),

    # ── Thought (extended thinking) ──────────────────────────────────────────
    CSS(".bt-thought-msg",
        "flex-shrink" => "0",
        "align-self" => "flex-start",
        "max-width" => "min(85%, 760px)",
        "border" => "1px dashed var(--bw-border-strong)",
        "border-radius" => "10px",
        "background" => "transparent",
        "color" => "var(--bw-text-muted)"),
    CSS(".bt-thought-details", "padding" => "0"),
    CSS(".bt-thought-summary",
        "padding" => "8px 12px",
        "cursor" => "pointer",
        "list-style" => "none",
        "font-size" => "var(--bw-font-size-ui)",
        "display" => "flex", "align-items" => "center", "gap" => "6px"),
    CSS(".bt-thought-summary::-webkit-details-marker", "display" => "none"),
    CSS(".bt-thought-summary::before",
        "content" => "\"▸\"",
        "color" => "var(--bw-text-faint)",
        "transition" => "transform 120ms"),
    CSS("details[open] > .bt-thought-summary::before",
        "transform" => "rotate(90deg)"),
    CSS(".bt-thought-body",
        "padding" => "0 12px 10px 28px",
        "white-space" => "pre-wrap", "word-break" => "break-word",
        "font-size" => "var(--bw-font-size-ui)", "line-height" => "1.5",
        "color" => "var(--bw-text-muted)"),
    CSS(".bt-thought-loading, .bt-tool-loading",
        "color" => "var(--bw-text-faint)",
        "font-style" => "italic", "font-size" => "var(--bw-font-size-sm)",
        "padding" => "4px 0"),

    # ── Tool call card ───────────────────────────────────────────────────────
    # NOTE: `flex-shrink: 0` is load-bearing. `.bt-messages` is a flex column
    # container, and per the CSS Flexbox spec, a flex item with any
    # `overflow` keyword set has its default `min-height` switch from `auto`
    # (content height) to `0`. Combined with a scroll container whose content
    # outgrows it (the old virtual scroll's spacer ran into the thousands of
    # px), that lets every tool card shrink down to a 1px slit (border only).
    # Same trap would catch any
    # other bubble that grows an `overflow: hidden`, so we apply the same
    # `flex-shrink: 0` to the other message types defensively below.
    CSS(".bt-tool-msg",
        "flex-shrink" => "0",
        "align-self" => "flex-start",
        "max-width" => "min(92%, 800px)",
        "background" => "var(--bw-bg-panel)",
        "border" => "1px solid var(--bw-border)",
        "border-radius" => "var(--bw-radius-sm)",
        "font-size" => "var(--bw-font-size-ui)",
        "box-shadow" => "var(--bw-shadow-sm)",
        "overflow" => "hidden",
        "position" => "relative",
        # Transition so a content-driven width change (e.g. a wide embed
        # mounting) animates smoothly rather than snapping and tearing layout.
        "transition" => "max-width 160ms ease, align-self 160ms ease"),
    # Live app embeds get a wider default cap than text pills: the visuals ARE
    # the content, and a responsive (resize_to = :parent) canvas will actually
    # use the room. `bt-tool-embed` is put on the card by its embed
    # (`wrap_for_detach`).
    CSS(".bt-tool-msg.bt-tool-embed",
        "max-width" => "min(98%, 1100px)"),
    # Full-chat-width toggle (`»` header button): span the ENTIRE message
    # column so wide content — the result embed, a plot, a table, a long diff —
    # gets all the room. Declared AFTER `.bt-tool-embed` so it wins at equal
    # specificity (source order): an embed card's 1100px cap was exactly why
    # the toggle looked "not functional" — it clicked, but the cap held it.
    # `!important` on the width so it also out-ranks any per-element inline cap.
    CSS(".bt-tool-msg.bt-tool-wide-active",
        "align-self" => "stretch",
        "max-width" => "100% !important"),
    # Detach button in the tool header (rendered only for bonito_app tools).
    # ⤢ is the conventional "open in a window" glyph; clicking pops the embed
    # into the floating window. Small, neutral, sits at the right of the header.
    CSS(".bt-tool-detach",
        "margin-left" => "4px",
        "background" => "transparent",
        "border" => "none",
        "padding" => "2px 6px",
        "cursor" => "pointer",
        "color" => "var(--bw-text-faint)",
        "font-size" => "var(--bw-font-size-ui)",
        "line-height" => "1",
        "border-radius" => "var(--bw-radius-sm)",
        "transition" => "background 80ms, color 80ms"),
    CSS(".bt-tool-detach:hover",
        "background" => "var(--bw-bg-subtle)",
        "color" => "var(--bw-accent)"),
    # Full-chat-width toggle — a slim, quiet header button (same chrome as ⤢).
    # Hidden by default; revealed only while the body is expanded — there is
    # nothing to widen on a collapsed header.
    CSS(".bt-tool-fullwidth",
        "display" => "none",
        "background" => "transparent",
        "border" => "none",
        "padding" => "2px 6px",
        "cursor" => "pointer",
        "color" => "var(--bw-text-faint)",
        "font-size" => "var(--bw-font-size-ui)", "line-height" => "1",
        "border-radius" => "var(--bw-radius-sm)",
        "flex-shrink" => "0",
        "user-select" => "none",
        "transition" => "background 80ms, color 80ms"),
    CSS(".bt-tool-fullwidth:hover",
        "background" => "var(--bw-bg-subtle)",
        "color" => "var(--bw-accent)"),
    CSS(".bt-tool-header[data-expanded=\"true\"] .bt-tool-fullwidth",
        "display" => "inline-flex"),
    # NOTE: deliberately NO `user-select: none` here — every piece of text in
    # the app should be selectable + copyable (file paths especially). The
    # browser treats a drag-select as a drag (not a click), so the
    # expand-on-click handler still fires only on real clicks.
    CSS(".bt-tool-header",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "padding" => "8px 12px",
        "cursor" => "pointer",
        # Backstop. Every elastic child above is allowed to shrink, so this
        # should never engage — but if a future child forgets to, it clips
        # inside the card instead of pushing the duration off the screen.
        "overflow" => "hidden",
        "transition" => "background 80ms"),
    # Container for the width-dependent rules below. The tool row's room is
    # decided by the message column, not the viewport: the same phone shows a
    # roomy row with the sidebar collapsed and a cramped one without.
    CSS(".bt-messages", "container-type" => "inline-size"),
    # Phone-width message column: the summary goes entirely (the expanded body
    # says the same thing, at length) and the full-width toggle with it — that
    # button only makes sense where there is width to expand INTO. What is left
    # is what the row is for: which tool, how long, and how it ended.
    CSS("@container (max-width: 560px)",
        CSS(".bt-tool-summary", "display" => "none"),
        # Matching the `[data-expanded="true"]` rule above selector-for-selector
        # on purpose: a container query adds NO specificity, so a bare
        # `.bt-tool-fullwidth` here loses to it and the button stays put. "Expand
        # to full chat width" is a no-op where the chat already IS the width, so
        # the ~28px it costs the title is better spent on the title.
        CSS(".bt-tool-header[data-expanded=\"true\"] .bt-tool-fullwidth",
            "display" => "none"),
        CSS(".bt-tool-title", "min-width" => "0")),
    # The title / summary / server badge carry the actual content the user
    # wants to grab — show a text cursor there so the affordance is obvious.
    CSS(".bt-tool-title, .bt-tool-summary, .bt-tool-server",
        "cursor" => "text"),
    CSS(".bt-tool-header:hover",
        "background" => "var(--bw-bg-subtle)"),
    # The expand/collapse glyph (`▶` / `▼`) is swapped directly in JS
    # (wireToolToggle). No `transform: rotate()` here — rotating the
    # already-swapped `▼` produced a sideways arrow.
    CSS(".bt-tool-toggle",
        "color" => "var(--bw-text-faint)", "font-size" => "var(--bw-font-size-xs)",
        "flex-shrink" => "0",
        # The disclosure glyph is chrome, not content — keep it out of
        # drag-selections (the header text itself IS selectable).
        "user-select" => "none",
        # While EXPANDED this glyph is the ONLY collapse control (see
        # Collapsable's click handler) — give it a real hit area.
        "padding" => "6px 8px",
        "margin" => "-6px -2px -6px -8px",
        "border-radius" => "var(--bw-radius-sm)"),
    CSS(".bt-tool-header[data-expanded=\"true\"] .bt-tool-toggle:hover",
        "background" => "var(--bw-bg-subtle)",
        "color" => "var(--bw-accent)"),
    CSS(".bt-tool-kind",
        "font-size" => "var(--bw-font-size-ui)", "flex-shrink" => "0"),
    # MCP server badge — dim pill before the tool name (e.g. "btworker").
    CSS(".bt-tool-server",
        "flex-shrink" => "0",
        "font-size" => "var(--bw-font-size-xs)", "font-weight" => "600",
        "letter-spacing" => "0.02em",
        "color" => "var(--bw-text-faint)",
        "background" => "var(--bw-bg-subtle)",
        "border-radius" => "999px",
        "padding" => "1px 7px"),
    # ── What yields when the header runs out of room ─────────────────────────
    # The order is deliberate, and it is the one thing this row has to get
    # right on a narrow pane: the TIMER and the STATUS never move (both
    # `flex-shrink: 0`, and they sit after everything elastic), the summary
    # collapses first, the title keeps a readable stub.
    #
    # It used to be the other way round. `.bt-tool-summary` was `flex-shrink: 0`
    # with `nowrap`, so it could not yield an inch: the title shrank away to a
    # single character and then the summary shoved the timer and the status
    # clean out of the card. Measured on a 392px phone viewport, header 70→382:
    # a 20-character summary overflowed by 52px and put the status pill at
    # 335→407; at 80 characters it was at 700→772. That is the "you cannot see
    # how long a tool ran on mobile" bug — the duration was rendered, just
    # outside the box.
    CSS(".bt-tool-title",
        # A floor, not zero: a title ellipsized to "B" identifies nothing.
        "flex" => "1 1 auto", "min-width" => "3.5rem",
        "font-family" => "ui-monospace, monospace", "font-size" => "var(--bw-font-size-sm)",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),
    CSS(".bt-tool-summary",
        "color" => "var(--bw-text-muted)", "font-size" => "var(--bw-font-size-sm)",
        # Shrink factor 100 against the title's 1: flex weights shrinkage by
        # base size, and the title's base (a long path) dwarfs the summary's, so
        # an equal factor would take it out of the title first. This makes the
        # summary give way while the title still reads.
        "flex" => "0 100 auto", "min-width" => "0",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),

    # Tool status — slim pill, harmonized with dashboard
    CSS(".bt-tool-status",
        "display" => "inline-flex", "align-items" => "center",
        "gap" => "4px",
        "font-size" => "var(--bw-font-size-xs)", "font-weight" => "500",
        "padding" => "1px 8px",
        "border-radius" => "999px",
        "white-space" => "nowrap", "flex-shrink" => "0"),
    CSS(".bt-status-pending",
        "background" => "rgba(245,158,11,0.12)", "color" => "#92400e"),
    CSS(".bt-status-in_progress",
        "background" => "rgba(59,130,246,0.12)", "color" => "#1d4ed8"),
    CSS(".bt-status-completed",
        "background" => "rgba(16,185,129,0.12)", "color" => "#047857"),
    CSS(".bt-status-failed",
        "background" => "rgba(239,68,68,0.12)", "color" => "#b91c1c"),

    # ── Live tool/todo pulse ─────────────────────────────────────────────────
    # A softly breathing ring while a tool is mid-flight. The ring is drawn once,
    # on a layer of its own, and only that layer's opacity animates: the
    # compositor does that without repainting. Animating the box-shadow itself
    # repainted the card on every frame (three live cards cost the browser 45%
    # of a core). Inside the border, since the card clips what lies outside it.
    # `prefers-reduced-motion` leaves the card still.
    CSS("@keyframes bt-pulse-glow",
        CSS("0%, 100%", "opacity" => "0"),
        CSS("50%", "opacity" => "1")),
    CSS(".bt-tool-msg.bt-tool-live, .bt-plan-msg.bt-plan-live",
        "position" => "relative",
        "border-color" => "rgba(59,130,246,0.42)"),
    CSS(".bt-tool-msg.bt-tool-live::after, .bt-plan-msg.bt-plan-live::after",
        "content" => "\"\"", "position" => "absolute", "inset" => "0",
        "border-radius" => "inherit", "pointer-events" => "none",
        "box-shadow" => "inset 0 0 0 2px rgba(59,130,246,0.35)",
        "animation" => "bt-pulse-glow 1.6s steps(4, jump-none) infinite"),
    CSS("@media (prefers-reduced-motion: reduce)",
        CSS(".bt-tool-msg.bt-tool-live::after, .bt-plan-msg.bt-plan-live::after",
            "animation" => "none", "opacity" => "0")),

    # ── Tool elapsed timer ───────────────────────────────────────────────────
    # Small monospace span next to the status pill. JS sets `data-tool-started`
    # on the bubble; a 1-second ticker writes `data-tool-elapsed-ms` and only
    # renders text once we cross > 1s (so a fast Read never flashes "0s").
    CSS(".bt-tool-timer",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "var(--bw-font-size-xs)",
        "color" => "var(--bw-text-muted)",
        "flex-shrink" => "0",
        "min-width" => "20px",
        "text-align" => "right"),
    CSS(".bt-tool-msg.bt-tool-live .bt-tool-timer",
        "color" => "var(--bw-accent)"),

    # ── Taskbar ──────────────────────────────────────────────────────────────
    # Floats over the messages area, anchored top-left of the chat panel.
    # `position: absolute` (NOT fixed and NOT sticky-in-scroll): it stays put
    # relative to `.bt-app` while the messages scroll underneath, but doesn't
    # poke out of the chat panel when other panels (sidebar, plotpane) resize.
    # No background or border on the container — each slot is a free-floating
    # capsule with its own surface, so multiple slots read as a stack rather
    # than a bordered widget.
    # Positioning context shared by the messages area and the floating
    # taskbar: the wrapper takes over the messages' flex role so the taskbar
    # anchors below the (variable-height) header, over the messages.
    CSS(".bt-messages-wrap",
        "position" => "relative",
        "flex" => "1 1 0", "min-height" => "0",
        "display" => "flex", "flex-direction" => "column"),
    CSS(".bt-taskbar",
        "position" => "absolute",
        "top" => "8px", "left" => "8px",
        "z-index" => "6",
        "pointer-events" => "none",   # slots re-enable so we don't catch the messages scroll
        # Never wider than the pane leaves room for — on a phone the fixed
        # 280px was most of the message column.
        "max-width" => "min(280px, calc(100% - 16px))"),
    CSS(".bt-taskbar-slots",
        "display" => "flex", "flex-direction" => "column",
        "gap" => "6px"),
    # One slot per live tool. Capsule shape, accent-tinted; click jumps back
    # to the source bubble (virtual-scroller index jump in bonitoagents.js).
    CSS(".bt-taskbar-slot",
        "pointer-events" => "auto",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "padding" => "4px 6px 4px 10px",
        "border-radius" => "999px",
        "background" => "var(--bw-bg-panel)",
        "border" => "1px solid rgba(59,130,246,0.42)",
        "box-shadow" => "var(--bw-shadow-sm)",
        "font-size" => "var(--bw-font-size-sm)",
        "color" => "var(--bw-text)",
        "cursor" => "pointer",
        "max-width" => "100%",
        "white-space" => "nowrap",
        "transition" => "background 80ms, transform 80ms"),
    CSS(".bt-taskbar-slot:hover",
        "background" => "var(--bw-bg-subtle)",
        "transform" => "translateX(2px)"),
    CSS(".bt-taskbar-slot-icon",
        "flex-shrink" => "0", "font-size" => "13px"),
    CSS(".bt-taskbar-slot-label",
        "flex" => "1 1 auto", "min-width" => "0",
        "overflow" => "hidden", "text-overflow" => "ellipsis"),
    CSS(".bt-taskbar-slot-timer",
        "flex-shrink" => "0",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "var(--bw-font-size-xs)",
        "color" => "var(--bw-accent)"),

    # The live-todo panel: a left-aligned CARD, not a capsule — selector
    # carries both classes so these rules outweigh the base slot rules
    # regardless of order. Every item gets a ✓/▸/○ marker; finished entries
    # crossed out, the active one accented.
    CSS(".bt-taskbar-slot.bt-taskbar-todo",
        "flex-direction" => "column",
        "align-items" => "stretch",
        "text-align" => "left",
        "gap" => "4px",
        "border-radius" => "10px",
        "padding" => "7px 10px",
        "min-width" => "210px",
        "cursor" => "default"),
    CSS(".bt-taskbar-slot.bt-taskbar-todo:hover",
        "background" => "var(--bw-bg-panel)",
        "transform" => "none"),
    CSS(".bt-taskbar-todo-head",
        "display" => "flex", "align-items" => "center", "gap" => "6px",
        "font-weight" => "600"),
    # The rows live in their own reactive wrapper (re-derived from the live
    # message each clock tick), so the 4px inter-item spacing the outer slot's
    # `gap` used to give the items when they were direct children now lives here.
    CSS(".bt-taskbar-todo-rows",
        "display" => "flex", "flex-direction" => "column", "gap" => "4px",
        # A long plan must never bury the chat under the floating card —
        # cap the rows and scroll them internally.
        "max-height" => "min(40vh, 320px)", "overflow-y" => "auto"),
    # Done/total counter in the todo head.
    CSS(".bt-taskbar-todo-count",
        "flex-shrink" => "0",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "var(--bw-font-size-xs)",
        "font-weight" => "400",
        "color" => "var(--bw-text-muted)"),
    # Collapse chevron. The collapsed state is the `bt-todo-collapsed` class
    # on the PERSISTENT `.bt-taskbar` element (not the slot — slots are 1 Hz
    # KeyedList re-renders that would wipe any state; see setupLiveTicker in
    # bonitoagents.js, which also persists the choice in localStorage and
    # defaults phones to collapsed).
    CSS(".bt-taskbar-todo-toggle",
        "flex-shrink" => "0",
        "appearance" => "none", "border" => "none", "background" => "none",
        "cursor" => "pointer",
        "padding" => "0 2px",
        "font-size" => "var(--bw-font-size-xs)", "line-height" => "1",
        "color" => "var(--bw-text-muted)",
        "transition" => "transform 120ms"),
    CSS(".bt-taskbar-todo-toggle:hover", "color" => "var(--bw-text)"),
    CSS(".bt-taskbar.bt-todo-collapsed .bt-taskbar-todo-rows",
        "display" => "none"),
    CSS(".bt-taskbar.bt-todo-collapsed .bt-taskbar-todo-toggle",
        "transform" => "rotate(-90deg)"),
    CSS(".bt-taskbar-todo-item",
        "font-size" => "var(--bw-font-size-sm)",
        "color" => "var(--bw-text-muted)",
        "white-space" => "nowrap",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis"),
    CSS(".bt-taskbar-todo-item::before",
        "content" => "'○ '",
        "display" => "inline-block",
        "width" => "15px",
        "color" => "var(--bw-text-faint)"),
    CSS(".bt-taskbar-todo-item.bt-todo-active",
        "color" => "var(--bw-text)",
        "font-weight" => "600"),
    CSS(".bt-taskbar-todo-item.bt-todo-active::before",
        "content" => "'▸ '",
        "color" => "var(--bw-accent)"),
    CSS(".bt-taskbar-todo-item.bt-todo-done",
        "text-decoration" => "line-through",
        "opacity" => "0.55"),
    CSS(".bt-taskbar-todo-item.bt-todo-done::before",
        "content" => "'✓ '",
        "color" => "var(--bw-success, #16a34a)"),

    # Subagent Task pills: the current-activity one-liner between the label and
    # the elapsed clock (taskbar.jl re-renders it via the KeyedList key as new
    # feed frames land) — a fact off the wire, no staleness tint.
    CSS(".bt-taskbar-activity",
        "flex" => "0 1 auto", "min-width" => "0",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "font-size" => "var(--bw-font-size-xs)",
        "color" => "var(--bw-text-faint)"),
    CSS(".bt-taskbar-activity:empty", "display" => "none"),

    # Mini stop button — the composer stop button's little sibling, shared
    # by taskbar slots and live tool pills: bordered circle, red rounded
    # square drawn via ::before. ALWAYS visible (no hover reveal — a stop
    # affordance you have to hunt for is not an affordance).
    CSS(".bt-stop-mini",
        "display" => "inline-flex",
        "align-items" => "center", "justify-content" => "center",
        "width" => "20px", "height" => "20px",
        "box-sizing" => "border-box",
        "flex-shrink" => "0",
        "padding" => "0",
        "border-radius" => "50%",
        "background" => "var(--bw-bg-panel)",
        "border" => "1px solid var(--bw-border-strong)",
        "cursor" => "pointer",
        "transition" => "background 120ms, border-color 120ms"),
    CSS(".bt-stop-mini::before",
        "content" => "''",
        "width" => "8px", "height" => "8px",
        "border-radius" => "2px",
        "background" => "var(--bw-error)"),
    CSS(".bt-task-dismiss::before", "display" => "none"),
    CSS(".bt-stop-mini:hover",
        "background" => "rgba(239,68,68,0.08)",
        "border-color" => "var(--bw-error)"),

    # ── Eval extras (bt_julia_eval family) ──────────────────────────────────
    # Timeout badge: small mono hint next to the timer so the soft-checkpoint
    # cadence is visible at a glance.
    CSS(".bt-tool-timeout",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "var(--bw-font-size-xs)",
        "color" => "var(--bw-text-faint)",
        "flex-shrink" => "0",
        "white-space" => "nowrap"),
    # "On another worker" badge (`bt_julia_eval(worker = …)`): filled accent
    # pill right after the tool name — code running on a different machine is
    # the one thing about an eval card the user must see without reading it.
    CSS(".bt-tool-worker",
        "display" => "inline-flex", "align-items" => "center",
        "background" => "var(--bw-accent)", "color" => "#fff",
        "font-size" => "var(--bw-font-size-xs)", "font-weight" => "600", "letter-spacing" => "0.02em",
        "padding" => "1px 8px", "border-radius" => "999px",
        "flex-shrink" => "0", "white-space" => "nowrap"),
    # ↑ chips on a card that waits on an eval (bt_julia_continue /
    # bt_julia_wait): the eval's run id, a click away from its card. Outlined,
    # so they don't compete with the filled worker badge.
    CSS(".bt-tool-jump",
        "display" => "inline-flex", "align-items" => "center",
        "background" => "var(--bw-bg-panel)", "color" => "var(--bw-accent)",
        "border" => "1px solid var(--bw-accent)", "cursor" => "pointer",
        "font-size" => "var(--bw-font-size-xs)", "font-weight" => "600", "font-family" => "inherit",
        "padding" => "0 7px", "border-radius" => "999px", "line-height" => "16px",
        "flex-shrink" => "0", "white-space" => "nowrap"),
    CSS(".bt-tool-jump:hover", "background" => "var(--bw-accent)", "color" => "#fff"),
    # The card a jump landed on lights up briefly, so the eye finds it.
    CSS("@keyframes bt-jump-flash",
        CSS("0%",   "box-shadow" => "0 0 0 0 rgba(59,130,246,0.0)"),
        CSS("20%",  "box-shadow" => "0 0 0 4px rgba(59,130,246,0.45)"),
        CSS("100%", "box-shadow" => "0 0 0 0 rgba(59,130,246,0.0)")),
    CSS(".bt-jump-flash", "animation" => "bt-jump-flash 1.6s ease-out"),
    # Per-pill stop (shares .bt-stop-mini for the look). Hidden until the
    # pill is live — stopping a finished tool is meaningless.
    CSS(".bt-tool-stop",
        "display" => "none",
        "user-select" => "none"),
    CSS(".bt-tool-msg.bt-tool-live .bt-tool-stop",
        "display" => "inline-flex"),
    # File-path links — tool titles with a file, diff headers, search hits,
    # path-looking code spans in agent messages. Quiet dotted underline as
    # the standing affordance; full link treatment on hover. One delegated
    # listener in bonitoagents.js opens them in the plotpane editor.
    CSS(".bt-path-link",
        "cursor" => "pointer",
        "text-decoration" => "underline dotted",
        "text-decoration-color" => "var(--bw-text-faint)",
        "text-underline-offset" => "3px"),
    CSS(".bt-path-link:hover",
        "color" => "var(--bw-accent)",
        "text-decoration" => "underline",
        "text-decoration-color" => "var(--bw-accent)"),

    # ── File view panel (workspace tab) ──────────────────────────────────────
    # `FilePanel` (file_view.jl): one chrome for every file kind. The header
    # carries the kind glyph, the WORKER path, a size/kind badge, a save status
    # line and the actions; the body holds the rendered view and (for text-backed
    # files) an editable Monaco, with `data-view` deciding which is on screen.
    CSS(".bt-file-editor",
        "display" => "flex", "flex-direction" => "column",
        "height" => "100%", "min-height" => "0",
        "background" => "var(--bw-bg-panel)"),
    CSS(".bt-fv-icon",
        "color" => "var(--bw-text-faint)", "font-size" => "13px",
        "flex-shrink" => "0", "line-height" => "1"),
    CSS(".bt-file-editor-path",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "var(--bw-font-size-sm)",
        "color" => "var(--bw-text-muted)",
        "flex" => "1 1 auto", "min-width" => "0",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap",
        # Path truncates from the LEFT so the filename (the part that
        # matters) stays visible. Needs `.bt-path-ltr` around the text —
        # see `path_span`.
        "direction" => "rtl", "text-align" => "left"),
    # The inner half of the left-truncation trick. `direction: rtl` on the box
    # is what puts the ellipsis on the left, but it also makes the bidi
    # algorithm treat the text as RTL, and a leading "/" is a NEUTRAL character
    # — so `/tmp/x.png` renders as `tmp/x.png/`, a wrong path on every file
    # header. Isolating the text as its own LTR run fixes the order while the
    # box keeps truncating from the left. `isolate` rather than `bidi-override`
    # so a genuinely RTL filename still reads correctly inside.
    CSS(".bt-path-ltr", "direction" => "ltr", "unicode-bidi" => "isolate"),
    # A shortcut rendered ON its button. Quiet enough not to compete with the
    # verb, present enough to be learnable without hovering for a tooltip.
    CSS(".bt-btn-kbd",
        "margin-left" => "6px", "opacity" => "0.7",
        "font-size" => "var(--bw-font-size-xs)", "font-family" => "ui-monospace, monospace",
        "letter-spacing" => "0.02em"),
    CSS(".bt-fv-size, .bt-fv-dims",
        "font-size" => "var(--bw-font-size-xs)", "color" => "var(--bw-text-faint)",
        "flex-shrink" => "0", "white-space" => "nowrap"),
    CSS(".bt-file-editor-status",
        "font-size" => "var(--bw-font-size-xs)",
        "color" => "var(--bw-text-faint)",
        "flex-shrink" => "0",
        "white-space" => "nowrap",
        "max-width" => "40%", "overflow" => "hidden", "text-overflow" => "ellipsis"),
    # Segmented Preview|Source switch. The active half is filled, so which view
    # you're in is readable without hunting for a highlight.
    CSS(".bt-fv-segmented",
        "display" => "inline-flex", "border" => "1px solid var(--bw-border)",
        "border-radius" => "var(--bw-radius-sm)", "overflow" => "hidden",
        "margin-right" => "4px"),
    CSS(".bt-fv-seg",
        "border" => "none", "background" => "transparent", "cursor" => "pointer",
        "font-size" => "var(--bw-font-size-xs)", "padding" => "3px 9px",
        "color" => "var(--bw-text-muted)"),
    CSS(".bt-fv-seg + .bt-fv-seg", "border-left" => "1px solid var(--bw-border)"),
    CSS(".bt-fv-seg:hover", "background" => "var(--bw-bg-panel)"),
    CSS(""".bt-fv-seg[data-active="1"]""",
        "background" => "var(--bw-accent)", "color" => "#fff"),

    CSS(".bt-file-editor-body",
        "flex" => "1 1 auto", "min-height" => "0",
        "overflow" => "hidden", "display" => "flex", "flex-direction" => "column"),
    # `data-view` picks the half on screen. Both stay MOUNTED: toggling must not
    # lose the editor's cursor/scroll/unsaved edits or re-run a mesh upload.
    CSS(""".bt-file-view[data-view="preview"] > .bt-file-editor-body > .bt-fv-source""",
        "display" => "none"),
    CSS(""".bt-file-view[data-view="source"] > .bt-file-editor-body > .bt-fv-rendered""",
        "display" => "none"),
    CSS(".bt-fv-rendered, .bt-fv-source",
        "flex" => "1 1 auto", "min-height" => "0", "min-width" => "0",
        "display" => "flex", "flex-direction" => "column", "overflow" => "auto"),
    # The source half holds only Monaco, which scrolls itself. A scrolling parent
    # makes a resize loop: at a fractional pane size (1201.81px) Monaco lays out
    # at the rounded 1202px, the 0.19px overflow brings in scrollbars, Monaco
    # shrinks by their 15px, they go away, and so on every frame. The editor
    # flickered and lost every click and selection.
    CSS(".bt-fv-source", "overflow" => "hidden"),
    # The Monaco wrapper chain must pass full height down to the editor div —
    # EVERY link of it. BonitoBook's editor component brings its own unclassed
    # wrapper between `.bt-fv-editor` and `.monaco-editor-div`, and that div was
    # not covered here: it collapsed to its content height (5px), Monaco's own
    # `height: 100%` resolved against those 5px, and the source view of every
    # text file rendered as a single clipped line with empty space under it.
    #
    # It survived because nothing measured the editor: the panel, the body and the
    # `.bt-fv-editor` above it are all full height, `getValue()` returns the file
    # regardless, and the e2e assertion checks `.bt-file-editor-body` — all of
    # which are fine while the thing you actually read is 5px tall.
    CSS(".bt-fv-source > div, .bt-fv-editor, .bt-fv-editor > div, .bt-fv-source .monaco-editor-div",
        "height" => "100%", "min-height" => "0"),
    # The kinds' bodies (file_view.jl `file_viewer`).
    FILE_VIEW_CSS...,

    # ── 3D geometry ──────────────────────────────────────────────────────────
    MESH_VIEW_CSS...,

    # ── Change review tab (review.jl) ────────────────────────────────────────
    CSS(".bt-review",
        "display" => "flex", "flex-direction" => "column",
        "height" => "100%", "min-height" => "0",
        "background" => "var(--bw-bg-panel)"),
    CSS(".bt-rv-repo", "flex" => "0 1 auto"),
    CSS(".bt-rv-stat",
        "font-size" => "var(--bw-font-size-xs)", "color" => "var(--bw-text-muted)",
        "white-space" => "nowrap"),
    CSS(".bt-rv-base",
        "width" => "130px", "font-size" => "var(--bw-font-size-xs)", "padding" => "3px 8px",
        "border" => "1px solid var(--bw-border)", "border-radius" => "var(--bw-radius-sm)",
        "background" => "var(--bw-bg-panel)", "color" => "var(--bw-text)",
        "font-family" => "ui-monospace, monospace"),
    # Which folder's repository is on screen. Sized to fit `dev/SomePackage`
    # without growing the header — the full path is in the option's `title`.
    # `color` explicitly, like every other control here: a select that paints its
    # own background and leaves the text to the UA gets `fieldtext`, which follows
    # the OS scheme. See the `html:root { color-scheme: light }` note above.
    CSS(".bt-rv-folder",
        "max-width" => "180px", "font-size" => "var(--bw-font-size-xs)", "padding" => "3px 6px",
        "border" => "1px solid var(--bw-border)", "border-radius" => "var(--bw-radius-sm)",
        "background" => "var(--bw-bg-panel)", "color" => "var(--bw-text)",
        "font-family" => "ui-monospace, monospace"),
    CSS(".bt-rv-hint",
        "font-size" => "var(--bw-font-size-xs)", "color" => "var(--bw-text-faint)",
        "padding" => "4px 12px", "flex-shrink" => "0",
        "border-bottom" => "1px solid var(--bw-border)"),
    CSS(".bt-rv-body",
        "flex" => "1 1 auto", "min-height" => "0", "overflow" => "auto",
        "padding" => "8px 10px 24px"),
    CSS(".bt-rv-empty, .bt-rv-binary",
        "padding" => "14px", "font-size" => "var(--bw-font-size-ui)", "color" => "var(--bw-text-muted)"),
    CSS(".bt-rv-error", "margin" => "12px"),

    # Pending-comment tray. Hidden entirely when empty (and in ask mode, where
    # nothing ever collects) so the diff gets the space.
    CSS(".bt-rv-tray-wrap", "flex-shrink" => "0"),
    CSS(".bt-rv-tray",
        "display" => "flex", "flex-wrap" => "wrap", "gap" => "6px",
        "padding" => "8px 12px", "background" => "var(--bw-bg-subtle)",
        "border-bottom" => "1px solid var(--bw-border)"),
    # Hidden only when EMPTY. Deliberately NOT hidden in ask mode: comments you
    # collected in feedback mode are still pending, and hiding them while
    # leaving the Send button live would mean sending something you can't see.
    CSS(""".bt-rv-tray[data-empty="1"]""", "display" => "none"),
    CSS(".bt-rv-chip",
        "display" => "inline-flex", "align-items" => "center", "gap" => "6px",
        "max-width" => "320px", "cursor" => "pointer",
        "border" => "1px solid var(--bw-border)", "border-radius" => "999px",
        "background" => "var(--bw-bg-panel)", "padding" => "2px 4px 2px 9px",
        "font-size" => "var(--bw-font-size-sm)"),
    CSS(".bt-rv-chip:hover", "border-color" => "var(--bw-accent)"),
    CSS(".bt-rv-chip-n", "color" => "var(--bw-text-faint)"),
    CSS(".bt-rv-chip-loc",
        "font-family" => "ui-monospace, monospace", "color" => "var(--bw-accent)",
        "white-space" => "nowrap"),
    CSS(".bt-rv-chip-text",
        "color" => "var(--bw-text-muted)", "overflow" => "hidden",
        "text-overflow" => "ellipsis", "white-space" => "nowrap"),
    CSS(".bt-rv-chip-drop",
        "border" => "none", "background" => "transparent", "cursor" => "pointer",
        "color" => "var(--bw-text-faint)", "font-size" => "var(--bw-font-size-xs)",
        "padding" => "2px 5px", "border-radius" => "999px"),
    CSS(".bt-rv-chip-drop:hover", "color" => "var(--bw-error)", "background" => "var(--bw-bg-subtle)"),

    # Per-file section.
    CSS(".bt-rv-file",
        "border" => "1px solid var(--bw-border)", "border-radius" => "var(--bw-radius-sm)",
        "margin-bottom" => "10px", "overflow" => "hidden", "background" => "var(--bw-bg-panel)"),
    CSS(".bt-rv-file > summary",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "padding" => "6px 10px", "cursor" => "pointer", "user-select" => "none",
        "background" => "var(--bw-bg-subtle)", "font-size" => "var(--bw-font-size-sm)",
        "position" => "sticky", "top" => "0", "z-index" => "2"),
    CSS(".bt-rv-file-status",
        "font-size" => "var(--bw-font-size-2xs)", "text-transform" => "uppercase",
        "letter-spacing" => "0.04em", "color" => "var(--bw-text-faint)",
        "border" => "1px solid var(--bw-border)", "border-radius" => "999px",
        "padding" => "1px 7px", "flex-shrink" => "0"),
    CSS(""".bt-rv-file-status[data-status="added"]""",
        "color" => "var(--bw-success)", "border-color" => "var(--bw-success)"),
    CSS(""".bt-rv-file-status[data-status="deleted"]""",
        "color" => "var(--bw-error)", "border-color" => "var(--bw-error)"),
    # Left-truncating like `.bt-file-editor-path`, and with the same `.bt-path-ltr`
    # requirement on its text.
    CSS(".bt-rv-file-path",
        "font-family" => "ui-monospace, monospace", "flex" => "1 1 auto",
        "min-width" => "0", "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap", "direction" => "rtl", "text-align" => "left"),
    # Send with an empty tray: still clickable (pressing it is how you learn what
    # it does — it answers "no comments to send"), just not dressed as the thing
    # you came here to press.
    CSS(""".bt-rv-send[data-empty="1"]""",
        "background" => "var(--bw-bg-panel)", "color" => "var(--bw-text-faint)",
        "border" => "1px solid var(--bw-border)"),
    CSS(""".bt-rv-send[data-empty="1"]:hover""",
        "background" => "var(--bw-bg-subtle)", "color" => "var(--bw-text-muted)"),
    CSS(".bt-rv-plus-count", "color" => "var(--bw-success)", "font-size" => "var(--bw-font-size-xs)"),
    CSS(".bt-rv-minus-count", "color" => "var(--bw-error)", "font-size" => "var(--bw-font-size-xs)"),
    # "Open the whole file" — revealed on section hover so a long diff's headers
    # stay quiet.
    CSS(".bt-rv-open",
        "border" => "1px solid transparent", "background" => "transparent",
        "color" => "var(--bw-text-faint)", "cursor" => "pointer",
        "font-size" => "var(--bw-font-size-sm)", "line-height" => "1", "padding" => "2px 6px",
        "border-radius" => "var(--bw-radius-sm)", "opacity" => "0"),
    CSS(".bt-rv-file > summary:hover .bt-rv-open", "opacity" => "1"),
    CSS(".bt-rv-open:hover",
        "color" => "var(--bw-accent)", "border-color" => "var(--bw-border)",
        "background" => "var(--bw-bg-panel)"),

    CSS(".bt-rv-hunk-head",
        "font-family" => "ui-monospace, monospace", "font-size" => "var(--bw-font-size-xs)",
        "color" => "var(--bw-text-faint)", "background" => "var(--bw-bg-subtle)",
        "padding" => "3px 10px", "border-top" => "1px solid var(--bw-border)",
        "white-space" => "pre", "overflow" => "hidden", "text-overflow" => "ellipsis"),

    # One diff row: two gutter numbers, the code, and the + affordance.
    CSS(".bt-rv-line",
        "display" => "flex", "align-items" => "flex-start",
        "font-family" => "ui-monospace, monospace", "font-size" => "var(--bw-font-size-sm)",
        "line-height" => "1.5", "position" => "relative"),
    CSS(".bt-rv-line:hover", "background" => "rgba(59,130,246,0.06)"),
    CSS(".bt-rv-num",
        "flex" => "0 0 44px", "text-align" => "right", "padding" => "0 8px 0 0",
        "color" => "var(--bw-text-faint)", "user-select" => "none",
        "white-space" => "nowrap"),
    CSS(".bt-rv-code",
        "flex" => "1 1 auto", "min-width" => "0", "white-space" => "pre-wrap",
        "word-break" => "break-word", "padding-right" => "28px"),
    CSS(".bt-rv-add", "background" => "rgba(16,185,129,0.10)"),
    CSS(".bt-rv-del", "background" => "rgba(239,68,68,0.10)"),
    CSS(".bt-rv-note", "color" => "var(--bw-text-faint)", "font-style" => "italic"),
    # `+` is FAINT on every line and full-strength on row hover. It used to be
    # `display: none` until hover, on the reasoning that a visible button on every
    # line of a thousand-line diff is pure noise — which is right, and is why this
    # is a low-opacity glyph with no chrome rather than a button per line. But
    # hidden-until-hover also means nothing on screen says the diff is
    # commentable, and that is the one thing this tab is for: you have to already
    # know, or brush a line by accident. Faint-always reads as texture in the
    # gutter and still answers "can I click here?".
    #
    # Opacity rather than `display`, so the element keeps its box and hovering
    # can't shift the row.
    CSS(".bt-rv-plus",
        "position" => "absolute", "right" => "4px", "top" => "1px",
        "display" => "block", "opacity" => "0.25",
        "border" => "1px solid transparent", "background" => "transparent",
        "color" => "var(--bw-accent)", "transition" => "opacity 80ms",
        "border-radius" => "var(--bw-radius-sm)", "cursor" => "pointer",
        "font-size" => "var(--bw-font-size-xs)", "line-height" => "1", "padding" => "2px 6px"),
    CSS(".bt-rv-line:hover .bt-rv-plus",
        "opacity" => "1", "border-color" => "var(--bw-border)",
        "background" => "var(--bw-bg-panel)"),
    CSS(".bt-rv-plus:hover",
        "opacity" => "1", "background" => "var(--bw-accent)", "color" => "#fff"),
    # A line you already commented on keeps a marker, so a long pass shows where
    # you've been.
    CSS(""".bt-rv-line[data-commented="1"]""",
        "box-shadow" => "inset 3px 0 0 var(--bw-accent)"),
    # While the composer is open, the lines the comment will cover are lit up —
    # otherwise a shift-click range is invisible until after you've sent it.
    # Attribute + class outranks the plain `.bt-rv-add` / `.bt-rv-del` tints.
    CSS(""".bt-rv-line[data-selected="1"]""",
        "background" => "rgba(59,130,246,0.16)"),
    CSS(".bt-rv-flash", "animation" => "bt-rv-flash 1.2s ease-out"),
    CSS("@keyframes bt-rv-flash",
        CSS("0%",   "background" => "rgba(59,130,246,0.35)"),
        CSS("100%", "background" => "transparent")),

    # Inline comment composer, inserted under the row it belongs to.
    CSS(".bt-rv-form",
        "display" => "flex", "flex-direction" => "column", "gap" => "6px",
        "padding" => "8px 10px 10px 52px",
        "background" => "var(--bw-bg-subtle)",
        "border-top" => "1px solid var(--bw-border)",
        "border-bottom" => "1px solid var(--bw-border)"),
    CSS(".bt-rv-input",
        "width" => "100%", "min-height" => "62px", "resize" => "vertical",
        "font-family" => "inherit", "font-size" => "var(--bw-font-size-ui)",
        "padding" => "6px 8px", "border" => "1px solid var(--bw-border)",
        "border-radius" => "var(--bw-radius-sm)",
        "background" => "var(--bw-bg-panel)", "color" => "var(--bw-text)"),
    CSS(".bt-rv-form-actions", "display" => "flex", "gap" => "8px", "align-items" => "center"),
    CSS(".bt-rv-form-cancel",
        "border" => "none", "background" => "transparent", "cursor" => "pointer",
        "color" => "var(--bw-text-muted)", "font-size" => "var(--bw-font-size-sm)"),
    # The command a Bash tool ran — ALWAYS visible (unlike the eval preview there
    # is no Monaco "Code" section afterwards to fall back on), same dark code look,
    # scrolls for long scripts. "What ran" must never be hidden behind a tooltip.
    CSS(".bt-cmd-preview",
        "border-top" => "1px solid var(--bw-border)",
        "background" => "#0f172a",
        "max-height" => "180px",
        "overflow-y" => "auto"),
    CSS(".bt-cmd-preview pre",
        "margin" => "0",
        "padding" => "8px 12px",
        "font-family" => "ui-monospace, SFMono-Regular, Menlo, monospace",
        "font-size" => "var(--bw-font-size-sm)", "line-height" => "1.5",
        "color" => "#e2e8f0",
        "white-space" => "pre-wrap", "word-break" => "break-word"),

    # Subagent activity feed inside a Task tool bubble: a second collapsible
    # section between the header and the lazy body (bonitoagents.js builds it
    # from the header's `task_feed` snapshot + live `task_activity` events).
    # Most-recent-last, auto-scrolled, bounded like the server-side window.
    CSS(".bt-task-feed",
        "border-top" => "1px solid var(--bw-border)"),
    CSS(".bt-task-feed-head",
        "display" => "flex", "align-items" => "center", "gap" => "6px",
        "padding" => "3px 12px",
        "font-size" => "var(--bw-font-size-xs)",
        "color" => "var(--bw-text-muted)",
        "user-select" => "none"),
    CSS(".bt-task-feed-count",
        "color" => "var(--bw-text-faint)",
        "font-family" => "ui-monospace, monospace"),
    CSS(".bt-task-feed-list",
        "max-height" => "180px",
        "overflow-y" => "auto",
        "padding" => "2px 12px 8px",
        "display" => "flex", "flex-direction" => "column", "gap" => "2px"),
    CSS(".bt-task-feed-entry",
        "font-size" => "var(--bw-font-size-sm)",
        "color" => "var(--bw-text-muted)",
        "white-space" => "nowrap",
        # The list is a flex column with a 180px max-height. Flex items default
        # to `flex-shrink: 1`, so once the entries overflow that cap the browser
        # SQUISHES each row toward 0px instead of letting the list scroll — a
        # long subagent feed collapsed to ~2px rows and rendered blank. Pin the
        # rows to their content height so the list scrolls (overflow-y: auto).
        "flex-shrink" => "0",
        "overflow" => "hidden", "text-overflow" => "ellipsis"),
    CSS(".bt-task-feed-entry.bt-task-feed-tool",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "var(--bw-font-size-xs)",
        "color" => "var(--bw-text)"),
    CSS(".bt-task-feed-entry.bt-task-feed-thought",
        "font-style" => "italic",
        "color" => "var(--bw-text-faint)"),
    CSS(".bt-task-feed-entry.bt-feed-failed",
        "color" => "var(--bw-error)"),

    CSS(".bt-tool-body",
        "padding" => "0 12px 10px",
        "border-top" => "1px solid var(--bw-border)"),
    # A collapsed tool keeps an EMPTY `.bt-tool-body` placeholder (the body is
    # only rendered into it on expand). Without this it still drew its border-top
    # + bottom padding — a stray ~11px box under every collapsed tool header.
    # Zero it out until it actually has content.
    CSS(".bt-tool-body:empty",
        "padding" => "0", "border-top" => "none"),
    CSS(".bt-tool-empty",
        "padding" => "8px 0",
        "color" => "var(--bw-text-faint)",
        "font-style" => "italic", "font-size" => "var(--bw-font-size-sm)"),

    # Live eval embed (RemoteRef). `position:relative` anchors the ✕ close/free
    # button, which appears on hover (top-right) so it never covers the plot.
    # Clicking it unmounts the render AND evicts the worker-side value (frees
    # memory) — see `jsrender(::RemoteRef)`.
    CSS(".bt-remote-ref", "position" => "relative"),
    CSS(".bt-embed-close",
        "position" => "absolute", "top" => "4px", "right" => "4px", "z-index" => "5",
        "width" => "20px", "height" => "20px", "padding" => "0",
        "display" => "flex", "align-items" => "center", "justify-content" => "center",
        "border" => "1px solid var(--bw-border)", "border-radius" => "var(--bw-radius-sm)",
        "background" => "var(--bw-bg-panel)", "color" => "var(--bw-text-muted)",
        "font-size" => "12px", "line-height" => "1", "cursor" => "pointer",
        "opacity" => "0", "transition" => "opacity 80ms"),
    CSS(".bt-remote-ref:hover .bt-embed-close", "opacity" => "0.85"),
    CSS(".bt-embed-close:hover",
        "opacity" => "1", "color" => "var(--bw-text)", "background" => "var(--bw-bg-subtle)"),

    MEDIA_CSS...,

    # Code-block hover actions (copy · download), top-right of a fenced <pre>.
    CSS(".bt-code-wrap", "position" => "relative"),
    CSS(".bt-code-actions",
        "position" => "absolute", "top" => "6px", "right" => "6px",
        "display" => "flex", "gap" => "4px",
        "opacity" => "0", "transition" => "opacity 80ms"),
    CSS(".bt-code-wrap:hover .bt-code-actions", "opacity" => "1"),
    CSS(".bt-code-action",
        "appearance" => "none", "border" => "none",
        "background" => "rgba(0,0,0,0.55)", "color" => "#fff",
        "font-size" => "var(--bw-font-size-ui)", "line-height" => "1",
        "padding" => "3px 6px", "border-radius" => "5px", "cursor" => "pointer"),
    CSS(".bt-code-action:hover", "background" => "rgba(0,0,0,0.8)"),
    # Without hover (touch screens) the actions would stay invisible yet take
    # the taps that land on them: show them. Merged into MEDIA_CSS's query, which
    # comes earlier in ChatStyles, so it wins by specificity (see there).
    CSS("@media (hover: none)",
        CSS(".bt-code-wrap .bt-code-actions", "opacity" => "1")),
    CSS(".bt-tool-md",
        "font-size" => "var(--bw-font-size-ui)", "line-height" => "1.5",
        "padding-top" => "8px"),

    # Tool-body sub-section collapsibles (`<details>`). Used by bt_julia_eval
    # bodies to split Code / Output into two independently foldable blocks.
    # The disclosure marker is a `::before` glyph swapped on `[open]` — a
    # content swap, never a `transform: rotate()` (that compounds badly and
    # is unreliable in the offscreen renderer; see the tool-toggle fix).
    CSS(".bt-eval-body",
        "display" => "flex", "flex-direction" => "column", "gap" => "6px",
        "padding-top" => "4px"),
    # Outdated-worker banner: amber notice above a mangled pre-v3 eval card.
    CSS(".bt-worker-stale",
        "border" => "1px solid var(--bw-warning)",
        "border-radius" => "var(--bw-radius-sm)",
        "background" => "color-mix(in srgb, var(--bw-warning) 12%, var(--bw-bg-panel))",
        "padding" => "8px 10px",
        "display" => "flex", "flex-direction" => "column", "gap" => "3px"),
    CSS(".bt-worker-stale-title",
        "color" => "var(--bw-warning)", "font-weight" => "600"),
    CSS(".bt-worker-stale-body",
        "color" => "var(--bw-text-muted)", "font-size" => "var(--bw-font-size-ui)"),
    # [Update env] button on the version-mismatch card — amber accent.
    CSS(".bt-worker-upgrade-btn",
        "align-self" => "flex-start",
        "border-color" => "var(--bw-warning)",
        "background" => "color-mix(in srgb, var(--bw-warning) 16%, var(--bw-bg-panel))",
        "color" => "var(--bw-warning)", "font-weight" => "600"),
    CSS(".bt-worker-upgrade-btn:hover",
        "background" => "color-mix(in srgb, var(--bw-warning) 26%, var(--bw-bg-panel))"),
    CSS(".bt-subsection",
        "border" => "1px solid var(--bw-border)",
        "border-radius" => "var(--bw-radius-sm)",
        "overflow" => "hidden"),
    CSS(".bt-subsection-summary",
        "display" => "flex", "align-items" => "baseline", "gap" => "8px",
        "padding" => "6px 10px",
        "cursor" => "pointer",
        "list-style" => "none",
        "background" => "var(--bw-bg-subtle)"),
    CSS(".bt-subsection-summary::-webkit-details-marker", "display" => "none"),
    # THREE distinct disclosure markers, one per state of the cycle
    # (collapsed → full → summary): the amount of "ink" tracks how much
    # content is shown. ▸ closed (nothing), ▿ hollow = summary preview (some),
    # ▾ filled = full (all). Base rule is the collapsed marker; the two
    # `[open]` rules (more specific) override it while open.
    CSS(".bt-subsection-summary::before",
        "content" => "\"▸\"",
        "color" => "var(--bw-text-faint)", "font-size" => "10px",
        "flex-shrink" => "0"),
    CSS("details.bt-subsection[open][data-state=\"summary\"] > .bt-subsection-summary::before",
        "content" => "\"▿\""),
    CSS("details.bt-subsection[open][data-state=\"full\"] > .bt-subsection-summary::before",
        "content" => "\"▾\""),
    CSS(".bt-subsection-summary:hover",
        "background" => "var(--bw-bg-panel)"),
    CSS(".bt-subsection-label",
        "font-size" => "var(--bw-font-size-xs)", "font-weight" => "600",
        "letter-spacing" => "0.04em", "text-transform" => "uppercase",
        "color" => "var(--bw-text-muted)", "flex-shrink" => "0"),
    CSS(".bt-subsection-preview",
        "font-family" => "ui-monospace, SFMono-Regular, Menlo, monospace",
        "font-size" => "var(--bw-font-size-sm)",
        "color" => "var(--bw-text-faint)",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap", "min-width" => "0"),
    # THE scrollbar lives HERE, on the Collapsable body — not on the content
    # inside it. So a section behaves identically whether it holds a live
    # stdout stream or the same text after completion: capped height, its own
    # scrollbar, pinned to the newest line (`data-pin-end`, driven from JS).
    # A single line-height unit (console 12px/1.5 = 18px; Monaco ~ same) makes
    # `summary_lines` mean exactly what it says.
    CSS(".bt-subsection-body",
        "padding" => "8px 10px",
        "overflow" => "auto"),
    # A console body paints the terminal surface on the BODY, not on the
    # `.bt-console` inside it (see the chrome reset below) — so the padding
    # gutter the scrollbar lives in is the same colour as the text area, and
    # the bar reads as the section's own rather than as a strip floating
    # between two nested boxes.
    CSS(".bt-subsection-console",
        "background" => "var(--bw-bg-subtle)"),
    # SUMMARY state: the restricted preview — `summary_lines` tall, scrolls.
    # Sizing is content-box, so `max-height` bounds the CONTENT box and the
    # body's own 8px padding is added on top by the layout: the cap is exactly
    # N line-heights, no padding term. (It used to carry a `+ 16px` "for the
    # body's padding", which double-counted it and — together with the nested
    # console's padding+border — left 3.92 lines visible instead of 4, slicing
    # the last row mid-glyph.) The cap lives on the SECTION, never on the tool
    # card — every section (and the result embed below them) stays reachable in
    # the card's default state.
    CSS("""details.bt-subsection[data-state="summary"] > .bt-subsection-body""",
        "max-height" => "calc(var(--bt-summary-lines, 4) * 18px)"),
    # FULL state: the whole content, still capped generously so one huge
    # output can't blow up the card — the body scrolls past that. Whole lines
    # here too (`full_lines`, 26 × 18px = 468px unless the section says), so no
    # state ever ends on a half row.
    CSS("""details.bt-subsection[data-state="full"] > .bt-subsection-body""",
        "max-height" => "calc(var(--bt-full-lines, 26) * 18px)"),

    # Console block — wraps a `Bonito.RichText` terminal pane (ANSI → styled
    # HTML). Captured stdout / stderr / error backtraces render here instead
    # of in a Monaco editor: lighter, ANSI-aware. NO own scroll cap — the
    # Collapsable body owns height + scrollbar (see `.bt-subsection-body`), so
    # the console looks and scrolls the same streaming or done.
    CSS(".bt-console",
        "background" => "var(--bw-bg-subtle)",
        "border" => "1px solid var(--bw-border)",
        "border-radius" => "var(--bw-radius-sm)",
        "padding" => "8px 10px",
        # Streaming writes the live stdout tail as a raw text node straight into
        # `.bt-console` (see bonitoagents.js `evalOutputConsole`), so it needs
        # its own `pre-wrap` — otherwise newlines collapse and the tail renders
        # as one wrapped line, unlike the completed `.terminal-output` <pre>.
        "white-space" => "pre-wrap", "word-break" => "break-word",
        "font-family" => "ui-monospace, SFMono-Regular, Menlo, monospace",
        "font-size" => "var(--bw-font-size-sm)", "line-height" => "1.5"),
    # …but inside a Collapsable the section ALREADY draws that box (border,
    # radius, surface) and owns the scrollbar, so the console's own chrome is a
    # second, smaller rounded box nested in the first. That nesting is what made
    # the scrollbar look detached: the bar belongs to `.bt-subsection-body`, so
    # it rendered in the 25.8px channel BETWEEN the console's border and the
    # section's — reading as a scrollbar sitting outside the bubble. Drop the
    # chrome (the body carries the surface) and the bar sits against the text,
    # clipped by the section's radius. Standalone `.bt-console` (a generic tool
    # text block, no section around it) keeps the box above.
    CSS(".bt-subsection-body > .bt-console",
        "background" => "transparent",
        "border" => "none",
        "border-radius" => "0",
        "padding" => "0"),
    CSS(".bt-console .terminal-output",
        "font-family" => "ui-monospace, SFMono-Regular, Menlo, monospace",
        "font-size" => "var(--bw-font-size-sm)", "line-height" => "1.5",
        # Match the streaming tail exactly (the completed pane is a <pre>, which
        # defaults to `white-space: pre` — force `pre-wrap` so long lines wrap
        # the same streaming or done).
        "white-space" => "pre-wrap", "word-break" => "break-word",
        "margin" => "0"),

    # ── Edit-tool body ───────────────────────────────────────────────────────
    # One section per diff (`diff_section`), headed by its file. Collapsed, the
    # card shows each at its summary height; expanded, at its full height
    # (`--bt-full-lines`): the card arrow sizes all of them, every mount path
    # included, with no script.
    CSS(".bt-edit-tool-body",
        "padding-top" => "8px",
        "display" => "flex", "flex-direction" => "column", "gap" => "8px"),
    CSS(""".bt-tool-header[data-expanded="true"] ~ .bt-tool-body .bt-edit-tool-body > details.bt-subsection[data-state="summary"] > .bt-subsection-body""",
        "max-height" => "calc(var(--bt-full-lines, 26) * 18px)"),
    CSS(".bt-subsection-path",
        "font-family" => "ui-monospace, monospace", "font-size" => "var(--bw-font-size-sm)",
        "color" => "var(--bw-text-muted)",
        "overflow" => "hidden", "text-overflow" => "ellipsis", "white-space" => "nowrap",
        "min-width" => "0"),

    # ── Static code views (code_view.jl) ─────────────────────────────────────
    # One row per line, built in the browser and highlighted by Monaco's
    # tokenizer. The 18px line is the console's and the section caps' unit, so
    # a cap of N lines ends between rows. Rows are as wide as the longest, so a
    # tint spans it when scrolled sideways.
    CSS(".bt-code",
        "font-family" => "ui-monospace, SFMono-Regular, Menlo, monospace",
        "font-size" => "var(--bw-font-size-sm)", "line-height" => "18px",
        "overflow-x" => "auto"),
    # In a section the section's body scrolls, both ways, with its own bar.
    CSS(".bt-subsection-body > .bt-code", "overflow" => "visible"),
    CSS(".bt-code-src",
        "margin" => "0", "font" => "inherit", "white-space" => "pre", "tab-size" => "4"),
    CSS(".bt-code-lines", "width" => "max-content", "min-width" => "100%",
        "content-visibility" => "auto",
        "contain-intrinsic-block-size" => "auto var(--bt-code-height, 0px)"),
    CSS(".bt-code-chunk", "content-visibility" => "auto",
        "contain-intrinsic-block-size" => "auto var(--bt-code-height, 0px)"),
    CSS(".bt-l", "white-space" => "pre", "tab-size" => "4", "min-height" => "18px"),
    # A diff's gutter: both line numbers and the sign, from `data-g`. Not text,
    # so copying a diff copies code. It scrolls sideways with the code: a sticky
    # gutter is a compositor layer per row, and layerizing hundreds of them
    # took 15 ms of every scroll frame.
    CSS(".bt-code-diff .bt-l::before",
        "content" => "attr(data-g)",
        "padding-right" => "10px",
        "color" => "var(--bw-text-faint)"),
    CSS(".bt-l-del", "background" => "rgba(255, 0, 0, 0.12)"),
    CSS(".bt-l-add", "background" => "rgba(155, 185, 85, 0.22)"),
    # The characters a changed line changed in.
    CSS(".bt-l-del .bt-ch", "background" => "rgba(255, 0, 0, 0.22)"),
    CSS(".bt-l-add .bt-ch", "background" => "rgba(156, 204, 44, 0.45)"),

    # ── Search results ───────────────────────────────────────────────────────
    CSS(".bt-search-results",
        "padding" => "8px 0",
        "font-size" => "var(--bw-font-size-sm)",
        "max-height" => "400px",
        "overflow-y" => "auto"),
    CSS(".bt-search-row",
        "padding" => "3px 0",
        "display" => "flex", "align-items" => "baseline", "gap" => "4px",
        "min-width" => "0"),
    CSS(".bt-search-path",
        "color" => "var(--bw-accent)", "font-weight" => "600",
        "font-family" => "ui-monospace, monospace",
        "flex-shrink" => "0"),
    CSS(".bt-search-line",
        "color" => "var(--bw-text-muted)",
        "font-family" => "ui-monospace, monospace",
        "flex-shrink" => "0"),
    CSS(".bt-search-snippet",
        "color" => "var(--bw-text)",
        "background" => "none", "padding" => "0",
        "font-family" => "ui-monospace, monospace", "font-size" => "var(--bw-font-size-sm)",
        "flex" => "1 1 auto", "min-width" => "0",
        "overflow" => "hidden",
        "white-space" => "nowrap",
        "text-overflow" => "ellipsis"),
    CSS(".bt-search-raw",
        "color" => "var(--bw-text-muted)",
        "font-family" => "ui-monospace, monospace", "font-size" => "var(--bw-font-size-xs)",
        "padding" => "2px 0",
        "white-space" => "pre-wrap"),

    # ── Plan ─────────────────────────────────────────────────────────────────
    CSS(".bt-plan-msg",
        "align-self" => "flex-start",
        "max-width" => "min(88%, 760px)",
        "border" => "1px solid var(--bw-border)",
        "border-radius" => "var(--bw-radius-sm)",
        "background" => "var(--bw-bg-panel)",
        "padding" => "10px 14px",
        "font-size" => "var(--bw-font-size-ui)",
        "box-shadow" => "var(--bw-shadow-sm)"),
    CSS(".bt-plan-entry",
        "display" => "flex", "align-items" => "flex-start",
        "gap" => "8px", "padding" => "3px 0",
        "color" => "var(--bw-text)"),
    CSS(".bt-plan-status",
        "width" => "16px", "flex-shrink" => "0",
        "text-align" => "center",
        "color" => "var(--bw-text-muted)",
        "font-weight" => "600"),

    # ── Compact-summary separator ────────────────────────────────────────────
    # `/compact` boundary — rendered as a centered, muted, narrower block with
    # subtle horizontal rules on each side so it visually reads "session
    # continued here." Not a bubble: no alignment, no border, no shadow.
    CSS(".bt-summary-msg",
        "align-self" => "center",
        "max-width" => "min(80%, 720px)",
        "margin" => "8px 0",
        "padding" => "10px 18px",
        "text-align" => "center",
        "color" => "var(--bw-text-muted)",
        "font-size" => "var(--bw-font-size-ui)",
        "font-style" => "italic",
        "border-top" => "1px solid var(--bw-border)",
        "border-bottom" => "1px solid var(--bw-border)"),
    CSS(".bt-summary-msg .bt-summary-body",
        "display" => "block",
        # Tighten the markdown render so the centered block reads like a
        # caption, not a wall of body text.
        "line-height" => "1.5"),
    CSS(".bt-summary-msg .bt-summary-body > *:first-child", "margin-top" => "0"),
    CSS(".bt-summary-msg .bt-summary-body > *:last-child",  "margin-bottom" => "0"),

    # ── Markdown inside agent bubble ─────────────────────────────────────────
    CSS(".bt-agent-msg .markdown-body, .bt-agent-msg .markdown",
        "background" => "none", "border" => "none", "padding" => "0",
        "font-size" => "inherit", "font-family" => "inherit",
        "color" => "inherit", "line-height" => "1.55"),
    CSS(".bt-agent-msg .markdown-body > *:first-child, .bt-agent-msg .markdown > *:first-child",
        "margin-top" => "0"),
    CSS(".bt-agent-msg .markdown-body > *:last-child, .bt-agent-msg .markdown > *:last-child",
        "margin-bottom" => "0"),
    # The doubled `.bt-agent-msg .markdown-body …` arms are deliberate: they
    # out-rank Bonito's markdown.css (`.markdown-body pre`, specificity 0,1,1)
    # regardless of stylesheet order. Without them, markdown.css's GitHub
    # light-gray pre background (#f6f8fa) could win the tie while our light
    # `color` (meant for the dark block) still applied → near-invisible code
    # ("opacity overlay" bug).
    CSS(".bt-agent-msg pre, .bt-agent-msg .markdown-body pre",
        "background" => "#0f172a", "color" => "#e2e8f0",
        "border-radius" => "var(--bw-radius-sm)",
        "padding" => "10px 14px",
        "overflow-x" => "auto",
        "font-size" => "var(--bw-font-size-sm)", "line-height" => "1.5",
        "margin" => "8px 0"),
    CSS(".bt-agent-msg code, .bt-agent-msg .markdown-body code",
        "background" => "rgba(15,23,42,0.06)",
        "border-radius" => "3px",
        "padding" => "1px 5px",
        "font-size" => "var(--bw-font-size-ui)",
        "font-family" => "ui-monospace, monospace"),
    CSS(".bt-agent-msg pre code, .bt-agent-msg .markdown-body pre code",
        "background" => "none", "padding" => "0",
        "color" => "inherit"),

    # Overscroll tail — empty space below the last message the user can
    # scroll into (sized to ~30% of the pane by `sizeTail`). All "bottom"
    # math (atBottom / scrollToBottom / pins) targets the CONTENT bottom,
    # treating the tail as beyond-the-end.
    CSS(".bt-messages-tail",
        "flex-shrink" => "0", "overflow-anchor" => "none"),

    # (The per-chat mount curtain used to live here — the dashboard's load
    # overlay now covers the pane until its first rows show; see
    # `ChatWaitingView` in sidebar.jl and `markReady` in bonitoagents.js.)

    # ── Busy indicator ───────────────────────────────────────────────────────
    # Lives inside `.bt-messages` (after the rows, before the overscroll
    # tail) so it shows directly under the last message. The container
    # already pads 16px, so no own horizontal padding; opted out of scroll
    # anchoring like the tail (the chase owns scrollTop). margin-top -10px
    # cancels the flex row gap that precedes each of the three indicator
    # children (zero-height or not, every flex item costs a gap slot: three
    # indicators after the rows would push the visible one 30px under the
    # last message).
    CSS(".bt-busy",
        "flex-shrink" => "0", "height" => "0", "overflow" => "hidden",
        "overflow-anchor" => "none", "margin-top" => "-10px",
        "display" => "flex", "gap" => "4px", "align-items" => "center",
        "padding" => "0",
        "transition" => "height 150ms ease, padding 150ms ease"),
    CSS(".bt-busy.bt-busy-active",
        "height" => "28px", "padding" => "4px 0"),
    # While a thought is streaming, the "reasoning…" line is the liveness
    # indicator — showing the dots too is redundant. The suppress class is
    # toggled from `onThinking` (bonitoagents.js); declared AFTER the active
    # rule so the tie at equal specificity resolves to suppressed.
    CSS(".bt-busy.bt-busy-suppressed",
        "height" => "0", "padding" => "0"),
    CSS(".bt-busy-dot",
        "width" => "7px", "height" => "7px", "border-radius" => "50%",
        "background" => "var(--bw-accent)",
        "animation" => "bt-pulse 1.2s steps(3, jump-none) infinite"),
    CSS(".bt-busy-dot:nth-child(2)", "animation-delay" => "0.2s"),
    CSS(".bt-busy-dot:nth-child(3)", "animation-delay" => "0.4s"),
    CSS("@keyframes bt-pulse",
        CSS("0%, 100%", "opacity" => "0.3", "transform" => "scale(0.8)"),
        CSS("50%",      "opacity" => "1",   "transform" => "scale(1.2)")),

    # ── Idle "waiting" indicator ─────────────────────────────────────────────
    # Visible when the busy dots are NOT (keyed off `.bt-busy`'s class via
    # the adjacent-sibling rule — busy_start/busy_end flips and the
    # server-rendered remount class drive both elements in lockstep) AND
    # the chat has agent replies on display: `bt-waiting-on` is toggled by
    # `updateWaiting` in bonitoagents.js — set once an agent message exists
    # and the Agent filter shows them. An empty chat (nothing asked yet) or
    # a filtered-out agent stream gets no dangling "waiting" line. Same
    # placement rules as `.bt-busy` above (inside `.bt-messages`).
    CSS(".bt-waiting",
        "flex-shrink" => "0", "height" => "0", "overflow" => "hidden",
        "overflow-anchor" => "none", "margin-top" => "-10px",
        "display" => "flex", "align-items" => "center",
        "padding" => "0", "font-size" => "var(--bw-font-size-ui)", "font-style" => "italic",
        "color" => "var(--bw-text-muted)",
        "transition" => "height 150ms ease, padding 150ms ease"),
    CSS(".bt-busy:not(.bt-busy-active) + .bt-waiting.bt-waiting-on",
        "height" => "22px", "padding" => "2px 0"),

    # ── Transient "reasoning…" indicator ──────────────────────────────────────
    # Shown for the lifetime of an agent thought (most are redacted/empty, so
    # this is usually the only visible trace of the model thinking). Collapsed
    # to zero height until `.bt-thinking-active` is toggled by the JS.
    # Same placement rules as `.bt-busy` above (inside `.bt-messages`).
    CSS(".bt-thinking",
        "flex-shrink" => "0", "height" => "0", "overflow" => "hidden",
        "overflow-anchor" => "none", "margin-top" => "-10px",
        "display" => "flex", "align-items" => "center",
        "padding" => "0", "font-size" => "var(--bw-font-size-ui)", "font-style" => "italic",
        "color" => "var(--bw-text-muted)",
        "transition" => "height 150ms ease, padding 150ms ease"),
    CSS(".bt-thinking.bt-thinking-active",
        "height" => "22px", "padding" => "2px 0"),
    # Running chunk count tacked onto the reasoning indicator. Tabular figures
    # so the width doesn't jitter as the number climbs; empty until the first
    # chunk lands (no leading gap when there's nothing to show).
    CSS(".bt-thinking-count",
        "margin-left" => "6px", "font-style" => "normal",
        "font-variant-numeric" => "tabular-nums",
        "color" => "var(--bw-text-faint)"),
    CSS(".bt-thinking-count:empty", "margin-left" => "0"),
    CSS(".bt-collapsable-loading",
        "color" => "var(--bw-text-faint)",
        "font-style" => "italic", "font-size" => "var(--bw-font-size-sm)",
        "padding" => "4px 0"),

    # ── Permission / question card ───────────────────────────────────────────
    # Interactive card for `session/request_permission` (AskUserQuestion, plan
    # approval, …): the question + one real button per option. Plain scroll
    # content under the last message (see onPermission in bonitoagents.js).
    CSS(".bt-permission-card",
        "flex-shrink" => "0",
        "align-self" => "flex-start",
        "max-width" => "min(85%, 760px)",
        "background" => "var(--bw-bg-panel)",
        "border" => "1px solid var(--bw-accent)",
        "border-radius" => "var(--bw-radius)",
        "padding" => "12px 14px",
        "box-shadow" => "var(--bw-shadow-md)",
        "display" => "flex", "flex-direction" => "column", "gap" => "10px"),
    CSS(".bt-permission-question",
        "font-size" => "var(--bw-font-size)", "line-height" => "1.5",
        "font-weight" => "500",
        "color" => "var(--bw-text)"),
    CSS(".bt-permission-options",
        "display" => "flex", "flex-wrap" => "wrap", "gap" => "8px"),
    CSS(".bt-permission-btn",
        "appearance" => "none",
        "border" => "1px solid var(--bw-border-strong)",
        "background" => "var(--bw-bg-panel)",
        "color" => "var(--bw-text)",
        "font-size" => "var(--bw-font-size-ui)", "font-weight" => "500",
        "padding" => "6px 14px",
        "border-radius" => "999px",
        "cursor" => "pointer",
        "transition" => "background 80ms, border-color 80ms, color 80ms"),
    CSS(".bt-permission-btn:hover",
        "border-color" => "var(--bw-accent)",
        "color" => "var(--bw-accent)",
        "background" => "rgba(59,130,246,0.06)"),
    CSS(".bt-permission-btn.bt-perm-allow:hover",
        "border-color" => "var(--bw-success)", "color" => "#047857",
        "background" => "rgba(16,185,129,0.08)"),
    CSS(".bt-permission-btn.bt-perm-reject:hover",
        "border-color" => "var(--bw-error)", "color" => "#b91c1c",
        "background" => "rgba(239,68,68,0.08)"),
    CSS(".bt-permission-btn:disabled",
        "opacity" => "0.5", "cursor" => "default"),
    CSS(".bt-permission-btn.bt-perm-chosen",
        "opacity" => "1",
        "border-color" => "var(--bw-accent)",
        "background" => "rgba(59,130,246,0.12)",
        "color" => "var(--bw-accent-hover)"),
    # Question-form extras (AskUserQuestion): per-question label for
    # multi-question forms, the free-text "Other" box, and the action row.
    CSS(".bt-question-field-label",
        "font-size" => "var(--bw-font-size-ui)",
        "color" => "var(--bw-text-muted)",
        "margin-top" => "2px"),
    CSS("input.bt-question-text",
        "border" => "1px solid var(--bw-border-strong)",
        "border-radius" => "var(--bw-radius-sm)",
        "background" => "var(--bw-bg)",
        "color" => "var(--bw-text)",
        "font" => "inherit", "font-size" => "var(--bw-font-size-ui)",
        "padding" => "7px 10px",
        "outline" => "none",
        "transition" => "border-color 120ms, box-shadow 120ms"),
    CSS("input.bt-question-text:focus",
        "border-color" => "var(--bw-accent)",
        "box-shadow" => "0 0 0 3px rgba(59,130,246,0.18)"),
    CSS(".bt-permission-actions",
        "display" => "flex", "gap" => "8px",
        "justify-content" => "flex-end",
        "border-top" => "1px solid var(--bw-border)",
        "padding-top" => "8px"),
    CSS(".bt-question-skip",
        "color" => "var(--bw-text-muted)"),
    # Question identity: a round accent "?" badge beside the prompt so an
    # AskUserQuestion reads as the agent asking YOU (vs a generic panel /
    # permission ask). The prompt row aligns the badge to the first text line.
    CSS(".bt-question-prompt",
        "display" => "flex", "align-items" => "flex-start", "gap" => "9px"),
    CSS(".bt-question-icon",
        "flex" => "0 0 auto",
        "width" => "22px", "height" => "22px",
        "display" => "inline-flex", "align-items" => "center", "justify-content" => "center",
        "border-radius" => "50%",
        "background" => "var(--bw-accent)", "color" => "#fff",
        "font-size" => "13px", "font-weight" => "700", "line-height" => "1",
        "margin-top" => "1px"),

    # ── New-messages pill ────────────────────────────────────────────────────
    # Floats above the input area when followMode is off and new content
    # arrived in scrollback. Click → re-engage follow + scroll to bottom.
    # Hidden by default; .bt-new-msg-pill-visible toggles display. The slow
    # 2.5s pulse is via box-shadow so the button geometry doesn't shift.
    CSS(".bt-new-msg-pill",
        "display" => "none",
        "position" => "absolute",
        "left" => "50%",
        # Anchor to the actual composer, including its queue and attachments.
        "bottom" => "calc(100% + var(--bw-space-2))",
        "transform" => "translateX(-50%)",
        "z-index" => "20",
        "align-items" => "center", "gap" => "8px",
        "padding" => "8px 16px",
        "border" => "none", "border-radius" => "999px",
        "background" => "linear-gradient(135deg, #10b981 0%, #059669 100%)",
        "color" => "#fff",
        "font-family" => "inherit", "font-size" => "var(--bw-font-size-ui)",
        "font-weight" => "500",
        "cursor" => "pointer",
        "box-shadow" => "0 4px 14px rgba(16, 185, 129, 0.45)"),
    CSS(".bt-new-msg-pill.bt-new-msg-pill-visible",
        "display" => "inline-flex"),
    # The pulse glow is a NEW-MESSAGES nudge only; the plain "Move to bottom"
    # form (shown whenever scrolled away from the last message) stays static.
    # The glow is a layer of its own whose opacity animates (no repaint; see
    # bt-pulse-glow).
    CSS(".bt-new-msg-pill.bt-new-msg-pill-glow::after",
        "content" => "\"\"", "position" => "absolute", "inset" => "0",
        "border-radius" => "inherit", "pointer-events" => "none",
        "box-shadow" => "0 4px 28px rgba(16, 185, 129, 0.85)",
        "animation" => "bt-new-msg-pulse 2.5s steps(5, jump-none) infinite"),
    CSS(".bt-new-msg-pill:hover",
        "filter" => "brightness(1.08)"),
    CSS(".bt-new-msg-pill:active",
        "transform" => "translateX(-50%) scale(0.96)"),
    CSS(".bt-new-msg-pill-arrow",
        "font-size" => "16px", "line-height" => "1"),
    CSS("@keyframes bt-new-msg-pulse",
        CSS("0%, 100%", "opacity" => "0"),
        CSS("50%", "opacity" => "1")),

    # ── Input area ───────────────────────────────────────────────────────────
    # Outer area spans full width (so the top border + background look right);
    # inner row is centered with the same max-width as the messages column.
    # Column flex so the thumbnail strip (.bt-attachments) sits above the
    # input row when an attachment is queued.
    CSS(".bt-input-area",
        "flex-shrink" => "0",
        "border-top" => "1px solid var(--bw-border)",
        "padding" => "12px 14px",
        "padding-bottom" => "max(12px, env(safe-area-inset-bottom))",
        "display" => "flex", "flex-direction" => "column", "align-items" => "center",
        "gap" => "8px",
        # Anchor for the slash-command autocomplete popup (.bt-cmd-ac).
        "position" => "relative",
        "background" => "var(--bw-bg-panel)"),
    # Slash-command autocomplete: floats ABOVE the composer while the input
    # holds a lone "/partial" token (built/driven in bonitoagents.js
    # setupInputs; fed by available_commands_update via the 'commands' comm
    # event + the connect-time init snapshot).
    CSS(".bt-cmd-ac",
        "position" => "absolute", "bottom" => "100%",
        "left" => "14px", "right" => "14px",
        "display" => "none", "flex-direction" => "column",
        "margin-bottom" => "6px", "padding" => "4px",
        "background" => "var(--bw-bg-panel)",
        "border" => "1px solid var(--bw-border)",
        "border-radius" => "10px",
        "box-shadow" => "var(--bw-shadow-md)",
        "z-index" => "40",
        "max-height" => "40vh", "overflow-y" => "auto"),
    CSS(".bt-cmd-ac.bt-cmd-ac-open", "display" => "flex"),
    CSS(".bt-cmd-ac-item",
        "display" => "flex", "align-items" => "baseline", "gap" => "8px",
        "padding" => "5px 9px", "border-radius" => "6px",
        "cursor" => "pointer",
        "white-space" => "nowrap", "overflow" => "hidden"),
    CSS(".bt-cmd-ac-item:hover", "background" => "var(--bw-bg-subtle)"),
    CSS(".bt-cmd-ac-item.bt-cmd-ac-sel", "background" => "var(--bw-bg-subtle)"),
    CSS(".bt-cmd-ac-name",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "var(--bw-font-size-ui)", "font-weight" => "600",
        "flex" => "0 0 auto"),
    CSS(".bt-cmd-ac-hint",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "var(--bw-font-size-xs)", "color" => "var(--bw-text-faint)",
        "flex" => "0 0 auto"),
    CSS(".bt-cmd-ac-desc",
        "font-size" => "var(--bw-font-size-sm)", "color" => "var(--bw-text-muted)",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "flex" => "1 1 auto"),
    CSS(".bt-input-row",
        "display" => "flex", "gap" => "8px", "align-items" => "flex-end",
        "width" => "100%"),
    # Controls share one row on both desktop and phone.
    CSS(".bt-input-controls",
        "display" => "flex", "flex-direction" => "row",
        "gap" => "var(--bw-space-2)", "align-items" => "center",
        "flex-shrink" => "0"),
    CSS(".bt-input-btn-row",
        "display" => "flex", "gap" => "8px", "align-items" => "flex-end"),
    # Yolo toggle bar: quiet chrome when off; an armed amber accent when on so
    # it's obvious the composer is in reminders mode and autonomy is engaged.
    CSS(".bt-yolo-bar",
        "appearance" => "none",
        "border" => "1px solid var(--bw-border)",
        "background" => "var(--bw-bg-panel)",
        "color" => "var(--bw-text-muted)",
        "font-size" => "var(--bw-font-size-xs)", "line-height" => "1", "flex-shrink" => "0",
        "padding" => "6px",
        "border-radius" => "8px",
        "cursor" => "pointer",
        "white-space" => "nowrap",
        "transition" => "background 80ms, color 80ms, border-color 80ms"),
    CSS(".bt-yolo-bar:hover", "background" => "var(--bw-bg-subtle)"),
    CSS(".bt-yolo-bar-on",
        "border-color" => "var(--bw-warning)",
        "background" => "color-mix(in srgb, var(--bw-warning) 18%, var(--bw-bg-panel))",
        "color" => "var(--bw-warning)",
        "font-weight" => "600"),
    CSS(".bt-yolo-bar-on:hover",
        "background" => "color-mix(in srgb, var(--bw-warning) 26%, var(--bw-bg-panel))"),

    # ── Chat toolbar (below the composer) ───────────────────────────────────
    # Hosts the message-type filter checkboxes (populated client-side by
    # `noteType` in bonitoagents.js) and future per-chat options. Deliberately
    # roomy (min-height) so it doesn't jump when the first checkbox appears.
    # Two rows: the dynamic message-filter checkboxes (top) and static
    # display options (bottom, e.g. "Depict Images Natively in Chat").
    CSS(".bt-chat-toolbar",
        "flex-shrink" => "0",
        "min-height" => "38px",
        "box-sizing" => "border-box",
        "display" => "flex", "flex-direction" => "column",
        # Roomy row separation so the display options read as their own
        # group, distinct from the filter checkboxes above.
        "gap" => "10px",
        "padding" => "8px 14px",
        "border-top" => "1px solid var(--bw-border)",
        "background" => "var(--bw-bg-panel)",
        "font-size" => "var(--bw-font-size-sm)",
        "color" => "var(--bw-text-muted)"),
    CSS(".bt-toolbar-filters",
        "display" => "flex", "align-items" => "center", "flex-wrap" => "wrap",
        "gap" => "14px", "min-height" => "18px"),
    CSS(".bt-toolbar-options",
        "display" => "flex", "align-items" => "center", "flex-wrap" => "wrap",
        "gap" => "14px"),
    CSS(".bt-filter-toggle",
        "display" => "inline-flex", "align-items" => "center", "gap" => "5px",
        "cursor" => "pointer",
        "white-space" => "nowrap"),
    CSS(".bt-filter-toggle input",
        "cursor" => "pointer", "margin" => "0"),
    CSS(".bt-filter-toggle:hover",
        "color" => "var(--bw-text)"),
    # "Tools:" group separator before the per-tool checkboxes. (Hiding itself
    # is inline display:none managed by bonitoagents.js `setKeyHidden` — the
    # per-tool key set is open, so no static rules.)
    CSS(".bt-filter-group-label",
        "margin-left" => "8px",
        "font-weight" => "600"),

    # ── Native media display (bt_show + "Native Images" / "Native Videos") ──
    # The bt-tool-native class strips the pill chrome so the body's <img> or
    # <video> sits bare in the chat flow like an agent reply; bonitoagents.js
    # applies it (and auto-mounts the body) when the matching toggle is on
    # and the tool's show_mime is image/* / video/*.
    CSS(".bt-tool-msg.bt-tool-native",
        "background" => "none",
        "border" => "none",
        "box-shadow" => "none",
        "overflow" => "visible"),
    # Its header stays as the picture's caption: what it shows (the agent's
    # title, or the file's name) and the summary beside it, the full path on
    # hover; the title opens the file. Only the title takes the pointer: a
    # click anywhere else on the row would fold the picture away.
    CSS(".bt-tool-native .bt-tool-header",
        "background" => "none", "border" => "none", "min-height" => "0",
        "padding" => "0 0 var(--bw-space-1) 0", "pointer-events" => "none"),
    # This must be in the initial chat sheet, before the lazy body (and its
    # FileToolbarStyles) arrives, or every restored picture loses a header row.
    CSS(".bt-tool-native.bt-output-framed > .bt-tool-header", "display"=>"none"),
    CSS(".bt-tool-native .bt-tool-header > :not(.bt-tool-title):not(.bt-tool-summary)",
        "display" => "none"),
    CSS(".bt-tool-native .bt-tool-title.bt-path-link", "pointer-events" => "auto"),
    # A caption is prose (often the agent's own words), not a tool name.
    CSS(".bt-tool-native .bt-tool-title", "font-family" => "inherit", "font-size" => "var(--bw-font-size-ui)"),
    # Keep the fullwidth toggle hidden even if a future layout moves it out of
    # the header.
    CSS(".bt-tool-native .bt-tool-fullwidth, " *
        ".bt-tool-native .bt-tool-header[data-expanded=\"true\"] .bt-tool-fullwidth",
        "display" => "none"),
    CSS(".bt-tool-native .bt-tool-body",
        "border-top" => "none",
        "padding" => "0"),
    CSS(".bt-tool-native .bt-tool-body img",
        "border-radius" => "var(--bw-radius-sm)",
        "box-shadow" => "var(--bw-shadow-sm)",
        # Subtle hover lift: barely-there zoom + deeper shadow. transform
        # doesn't reflow the layout, so the virtual-scroll heights are
        # untouched by hovering.
        "transition" => "transform 150ms ease, box-shadow 150ms ease"),
    CSS(".bt-tool-native .bt-tool-body img:hover",
        "transform" => "scale(1.015)",
        "box-shadow" => "var(--bw-shadow-md)"),
    # Videos get the same dressing but NOT the hover lift — a zoom under
    # the pointer while scrubbing/watching reads as jitter, not polish.
    CSS(".bt-tool-native .bt-tool-body video",
        "border-radius" => "var(--bw-radius-sm)",
        "box-shadow" => "var(--bw-shadow-sm)"),

    # ── Attachment thumbnail strip ──────────────────────────────────────────
    # Sits above .bt-input-row. Hidden (display:none) when there's nothing
    # queued so the empty div doesn't add stray spacing. Thumbnails scroll
    # horizontally on overflow rather than wrapping — keeps the input row
    # in the same screen position regardless of attachment count.
    CSS(".bt-attachments",
        "display" => "none",
        "width" => "100%"),
    CSS(".bt-attachments.bt-attachments-active",
        "display" => "flex",
        "gap" => "8px",
        "flex-wrap" => "wrap",
        "align-items" => "flex-start"),
    CSS(".bt-attachment-thumb",
        "position" => "relative",
        "width" => "64px", "height" => "64px",
        "border" => "1px solid var(--bw-border-strong)",
        "border-radius" => "8px",
        "overflow" => "hidden",
        "background" => "var(--bw-bg)",
        "flex-shrink" => "0"),
    CSS(".bt-attachment-thumb img",
        "width" => "100%", "height" => "100%",
        "object-fit" => "cover",
        "display" => "block"),
    # A file being uploaded (or done): name, size or progress, and a bar.
    CSS(".bt-attachment-file",
        "position" => "relative",
        "width" => "180px", "height" => "64px",
        "padding" => "8px 28px 8px 10px", "box-sizing" => "border-box",
        "border" => "1px solid var(--bw-border-strong)", "border-radius" => "8px",
        "background" => "var(--bw-bg)", "overflow" => "hidden", "flex-shrink" => "0",
        "display" => "flex", "flex-direction" => "column", "justify-content" => "center", "gap" => "2px"),
    CSS(".bt-attachment-file-name",
        "font-size" => "var(--bw-font-size-sm)", "font-weight" => "500",
        "overflow" => "hidden", "text-overflow" => "ellipsis", "white-space" => "nowrap"),
    CSS(".bt-attachment-file-status",
        "font-size" => "var(--bw-font-size-xs)", "color" => "var(--bw-text-muted)",
        "overflow" => "hidden", "text-overflow" => "ellipsis", "white-space" => "nowrap"),
    CSS(".bt-attachment-file[data-state=error] .bt-attachment-file-status", "color" => "var(--bw-error)"),
    CSS(".bt-attachment-file-bar",
        "position" => "absolute", "left" => "0", "bottom" => "0", "height" => "3px",
        "background" => "var(--bw-accent)", "transition" => "width 120ms linear"),
    CSS(".bt-attachment-file[data-state=done] .bt-attachment-file-bar", "opacity" => "0"),
    CSS(".bt-attachment-remove",
        "position" => "absolute",
        "top" => "2px", "right" => "2px",
        "width" => "20px", "height" => "20px",
        "border" => "none", "border-radius" => "50%",
        "background" => "rgba(0,0,0,0.6)", "color" => "#fff",
        "font-size" => "16px", "line-height" => "20px",
        "padding" => "0", "cursor" => "pointer",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "center"),
    CSS(".bt-attachment-remove:hover",
        "background" => "rgba(220,38,38,0.85)"),
    CSS(".bt-attach-error",
        "color" => "var(--bw-error)",
        "font-size" => "var(--bw-font-size-sm)",
        "padding" => "4px 8px",
        "border-radius" => "6px",
        "background" => "rgba(239,68,68,0.08)",
        "border" => "1px solid rgba(239,68,68,0.3)",
        "flex-basis" => "100%",
        "box-sizing" => "border-box"),

    # Drag-over highlight on .bt-app: subtle inset ring so it's clear the
    # drop zone is "the whole chat", not just one nested element.
    CSS(".bt-app.bt-drag-over",
        "box-shadow" => "inset 0 0 0 3px var(--bw-accent)"),
    CSS(".bt-text-input, .bt-input-measure",
        "flex" => "1 1 auto", "min-width" => "0", "width" => "0",
        "border" => "1px solid var(--bw-border-strong)",
        "border-radius" => "20px",
        "padding" => "10px 14px",
        "font-size" => "16px",                          # iOS no-zoom threshold
        # Let the browser size text without collapsing the focused editor on
        # every keystroke. The JS mirror is only for older browsers.
        "field-sizing" => "content",
        "min-height" => "44px", "max-height" => "min(320px, 45dvh)",
        "font-family" => "inherit",
        "color" => "var(--bw-text)",
        "background" => "var(--bw-bg)",
        "outline" => "none", "box-sizing" => "border-box",
        "resize" => "none", "overflow-y" => "auto",
        "line-height" => "1.4",
        "transition" => "border-color 120ms, box-shadow 120ms"),
    CSS(".bt-text-input[data-bt-sizing-fallback]", "field-sizing" => "fixed"),
    CSS(".bt-input-measure",
        "position" => "fixed", "left" => "0", "top" => "0",
        "visibility" => "hidden", "pointer-events" => "none",
        "height" => "0", "min-height" => "0", "max-height" => "none",
        "border" => "0", "overflow" => "hidden", "field-sizing" => "fixed",
        "contain" => "layout style paint"),
    CSS(".bt-text-input::placeholder",
        "color" => "var(--bw-text-faint)"),
    CSS(".bt-text-input:focus",
        "border-color" => "var(--bw-accent)",
        "box-shadow" => "0 0 0 3px rgba(59,130,246,0.18)"),
    # Yolo mode: the composer is the REMINDERS editor — a red-ish border +
    # focus ring replaces the blue accent so the mode is unmistakable. Declared
    # AFTER the base rules: same specificity, later wins.
    CSS(".bt-text-input-yolo",
        "border-color" => "color-mix(in srgb, var(--bw-error) 60%, var(--bw-border-strong))"),
    CSS(".bt-text-input-yolo:focus",
        "border-color" => "var(--bw-error)",
        "box-shadow" => "0 0 0 3px rgba(239,68,68,0.18)"),
    # Thin, modern scrollbar instead of the Linux/Electron default with up/down
    # arrow buttons. EVERY element we let scroll needs to opt in — the default
    # is the 15px native bar with arrow buttons, which is what a Collapsable
    # body (tool Output/Code sections) used to get. Chromium honours
    # `scrollbar-width`/`scrollbar-color` and then IGNORES the `::-webkit-`
    # pseudo-elements, so the webkit rules are the fallback for older engines,
    # not dead weight. On the text input it's only visible when the textarea
    # grows past max-height.
    CSS(".bt-text-input, .bt-subsection-body",
        "scrollbar-width" => "thin",
        "scrollbar-color" => "var(--bw-border-strong) transparent"),
    CSS(".bt-text-input::-webkit-scrollbar, .bt-subsection-body::-webkit-scrollbar",
        "width" => "6px"),
    CSS(".bt-text-input::-webkit-scrollbar-thumb, .bt-subsection-body::-webkit-scrollbar-thumb",
        "background" => "var(--bw-border-strong)",
        "border-radius" => "3px"),
    CSS(".bt-text-input::-webkit-scrollbar-button, .bt-subsection-body::-webkit-scrollbar-button",
        "display" => "none"),

    # Keep Send and Stop equally sized circles despite Stop's border.
    CSS(".bt-send-btn, .bt-stop-btn",
        "border" => "none", "border-radius" => "50%",
        "width" => "36px", "height" => "36px",
        "box-sizing" => "border-box",
        "font-size" => "18px",                       # larger glyph fills the circle
        "line-height" => "1",
        "cursor" => "pointer", "flex-shrink" => "0",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "center", "padding" => "0",
        "transition" => "background 120ms, transform 80ms, opacity 120ms"),
    CSS(".bt-send-btn",
        "background" => "var(--bw-accent)", "color" => "#fff"),
    CSS(".bt-send-btn:hover",  "background" => "var(--bw-accent-hover)"),
    CSS(".bt-send-btn:active", "transform" => "scale(0.95)"),
    CSS(".bt-send-btn:disabled",
        "opacity" => "0.4", "cursor" => "not-allowed"),
    # Lock-in variant while Yolo is armed: same circle, amber accent + check
    # glyph — pressing it locks in the composer text as the reminders. Both
    # rules AFTER their blue counterparts so they win at equal specificity.
    CSS(".bt-send-btn-yolo",
        "background" => "var(--bw-warning)"),
    CSS(".bt-send-btn-yolo:hover",
        "background" => "#d97706"),
    CSS(".bt-stop-btn",
        "background" => "var(--bw-bg-panel)",
        "color" => "var(--bw-error)",
        "border" => "1px solid var(--bw-border-strong)"),
    CSS(".bt-stop-btn:hover",
        "background" => "rgba(239,68,68,0.08)",
        "border-color" => "var(--bw-error)"),

    # ── Attach ───────────────────────────────────────────────────────────────
    # Sits at the START of the input row, left of the text field, where every
    # chat app puts it. Keep its square target aligned with Send and Stop;
    # phones use this picker instead of desktop paste and drag-drop.
    CSS(".bt-attach-btn",
        "flex" => "0 0 auto", "align-self" => "flex-end",
        "width" => "36px", "height" => "36px",
        "display" => "flex", "align-items" => "center", "justify-content" => "center",
        "background" => "transparent", "border" => "1px solid transparent",
        "border-radius" => "999px", "cursor" => "pointer", "padding" => "0",
        "transition" => "background 80ms, border-color 80ms"),
    CSS(".bt-attach-btn:hover",
        "background" => "var(--bw-bg-subtle)",
        "border-color" => "var(--bw-border)"),
    # `display: none` would make the input unclickable in some browsers even
    # via `.click()`; keep it in the layout but out of sight and out of the tab
    # order (the button is the real control).
    CSS(".bt-attach-input",
        "position" => "absolute", "width" => "1px", "height" => "1px",
        "opacity" => "0", "pointer-events" => "none"),

    # ── Spinner (used by bt_show preview while streaming from worker) ────────
    # Per-side borders, never the `border` shorthand plus `border-top-color`:
    # a rule's properties come out in no fixed order, and with the shorthand
    # last it repainted the top grey. Every spinner in the app was a still grey
    # ring (this rule loads after the dashboard's, which it overrode).
    CSS(".bt-spinner",
        "width" => "14px", "height" => "14px",
        "border-radius" => "50%", "box-sizing" => "border-box",
        "border-top" => "2px solid var(--bw-accent)",
        "border-right" => "2px solid var(--bw-border)",
        "border-bottom" => "2px solid var(--bw-border)",
        "border-left" => "2px solid var(--bw-border)",
        "will-change" => "transform",   # compositor-driven; survives main-thread jank
        "animation" => "bt-spin 0.7s steps(8) infinite",
        "flex-shrink" => "0",
        "display" => "inline-block"),
    # Explicit `from` so it's an angle interpolation (0°→360°); `to` alone
    # interpolates matrix→identity and never turns. See dashboard.jl bt-spin.
    CSS("@keyframes bt-spin",
        CSS("from", "transform" => "rotate(0deg)"),
        CSS("to", "transform" => "rotate(360deg)")),

    # ── Responsive ───────────────────────────────────────────────────────────
    CSS("@media (max-width: 480px)",
        # Tighter padding on very small screens
        CSS(".bt-messages", "padding" => "12px"),
        CSS(".bt-input-area", "padding" => "10px 12px",
            "padding-bottom" => "max(10px, env(safe-area-inset-bottom))"),
        # Slightly tighter bubbles
        CSS(".bt-user-msg, .bt-agent-msg", "max-width" => "88%"),
        CSS(".bt-tool-msg",                "max-width" => "100%"),
        CSS(".bt-plan-msg",                "max-width" => "100%"),
        CSS(".bt-summary-msg",             "max-width" => "92%"),
        # Hide the cwd path in the header — not enough room
        CSS(".bt-header-cwd", "display" => "none"),
        # Title takes the available horizontal space and ellipsizes; the
        # status line gives way first (it truncates with an ellipsis), so a
        # long "Continuing on …: Sending 12/40: path" never covers the title
        # on a 360-414px phone column.
        CSS(".bt-header-title", "flex" => "1 1 auto"),
        CSS(".bt-header-status", "max-width" => "40%"),
        # Tool/message hide-toggles toolbar: on desktop the two `flex-wrap:
        # wrap` rows are fine; on mobile, 10–20 filter checkboxes at ~80px
        # each wrap into 4–6 stacked rows, growing the toolbar to ~120px
        # tall and eating the message column. Confine each row to a single
        # horizontally-scrollable strip — the user swipes to reach the
        # off-screen toggles, but the vertical footprint stays at one row.
        CSS(".bt-chat-toolbar",
            "padding" => "6px 10px",
            "gap" => "6px",
            "min-height" => "0"),
        CSS(".bt-toolbar-filters, .bt-toolbar-options",
            "flex-wrap" => "nowrap",
            "overflow-x" => "auto",
            "-webkit-overflow-scrolling" => "touch",
            "gap" => "10px",
            "padding-bottom" => "2px"),
        # Composer: the textarea gets the full first row and the attach +
        # Yolo/send/stop controls drop to a second row. In the single wrapped
        # row the flex-shrink:0 button column (~110px) squeezed a 390px phone's
        # textarea to ~200px — an awkward typing target.
        CSS(".bt-input-row", "flex-wrap" => "wrap", "gap" => "var(--bw-space-1)", "row-gap" => "8px"),
        CSS(".bt-input-controls, .bt-input-btn-row", "min-width" => "0", "gap" => "var(--bw-space-1)"),
        CSS(".bt-input-btn-row", "flex" => "1"),
        CSS(".bt-send-mode", "flex" => "1", "min-width" => "0"),
        CSS(".bt-send-mode-trigger", "width" => "100%"),
        CSS(".bt-text-input", "flex" => "1 1 100%"),
        # DOM order is attach, input, controls; wrap puts the 100%-basis input
        # on its own row but strands attach ABOVE it. order fixes the rows:
        # input, then attach + Yolo/send/stop together.
        CSS(".bt-attach-btn", "order" => "1", "flex" => "0 0 auto"),
        CSS(".bt-input-controls",
            "order" => "2",
            "flex" => "1 1 0",
            "flex-direction" => "row",
            "align-items" => "center",
            "justify-content" => "flex-end",
            "gap" => "var(--bw-space-1)")),
    CSS("@media (max-width: 360px)",
        CSS(".bt-input-area", "padding-left" => "var(--bw-space-2)", "padding-right" => "var(--bw-space-2)"),
        CSS(".bt-input-row, .bt-input-controls, .bt-input-btn-row", "gap" => "2px"),
        CSS(".bt-attach-btn, .bt-stop-btn, .bt-send-btn", "width" => "32px", "height" => "32px"),
        CSS(".bt-yolo-bar", "padding" => "6px"),
        CSS(".bt-send-mode-trigger", "font-size" => "var(--bw-font-size-2xs)", "min-height" => "32px", "gap" => "2px")),
)

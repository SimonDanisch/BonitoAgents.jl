// The login, as the tabs of one browser share it. Behind Authelia a login ends
// for all of them at once and is back for all of them with one login in any tab.
// Every login hands out a new session and drops the old one on the spot, so a
// login the browser does not need throws its other tabs out mid-request. So no
// tab asks for one while the browser has it: a page that loaded behind the login
// tells the other tabs (`announce`); a tab whose login ended waits for that
// (`logged_in`) instead of reloading into the login page, and the login page
// itself leaves for where it was going (`watch_login_page`).

const CHECK_ROUTE = "/session";   // 204 behind the login (`LOGIN_CHECK_ROUTE`)
const PORTAL_PATH = "/authelia";  // Authelia's pages (`PORTAL_PATH`)
const channel = typeof BroadcastChannel === "function" ? new BroadcastChannel("bonitoagents-login") : null;

// What the login lets through now: "ok", "ended", or "unreachable" (the server
// is out of reach: the connection guard's business).
export async function check() {
    let r;
    try {
        r = await fetch(CHECK_ROUTE, { redirect: "manual", cache: "no-store", credentials: "same-origin" });
    } catch (e) {
        return "unreachable";
    }
    if (r.status === 204) return "ok";
    return r.type === "opaqueredirect" || r.status === 401 || r.status === 403 ? "ended" : "unreachable";
}

export function announce() {
    channel && channel.postMessage("logged-in");
}

// ── A dashboard page ─────────────────────────────────────────────────────────
let card = null;        // "Your login has ended" (`login_guard`)
let ended = false;
let waiting = [];       // resolvers of `logged_in`

async function recheck() {
    const status = await check();
    if (status === "ok") {
        card && card.classList.remove("bt-conn-open");
        if (ended) { ended = false; announce(); }
        const resolvers = waiting;
        waiting = [];
        resolvers.forEach((r) => r());
    } else if (status === "ended") {
        ended = true;
        card && card.classList.add("bt-conn-open");
    }
    return status;
}

// Resolves once the login lets requests through, at once if it does now; until
// then the card says the login ended.
export function logged_in() {
    const p = new Promise((resolve) => waiting.push(resolve));
    recheck();
    return p;
}

// Behind a login: checks every few minutes (that keeps it alive while the tab
// is open), when the tab is looked at again and when another tab got through.
// A payload the gate turned away is asked for again once the login is back,
// so a chat opened meanwhile comes up instead of staying empty.
export function guard(card_node) {
    card = card_node;
    setInterval(recheck, 5 * 60 * 1000);
    document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && recheck());
    // Back from the login tab: the window gets focus without a visibility change.
    window.addEventListener("focus", () => ended && recheck());
    channel && channel.addEventListener("message", () => (ended || waiting.length) && recheck());
    window.Bonito.on_refused(() => logged_in());
    announce();
}

// ── Authelia's login page ────────────────────────────────────────────────────
// The gate adds this file to it (`with_login_script`). Shown while the browser
// was logged out, it leaves for the page it was asked for once the browser is
// logged in, here or in another tab. Shown to a browser that is logged in, it
// is Authelia's own page (settings, logout) and stays.
export async function watch_login_page() {
    if ((await check()) !== "ended") return;
    const target = () => {
        const rd = new URLSearchParams(location.search).get("rd");
        try {
            const url = new URL(rd || "/", location.origin);
            return url.origin === location.origin ? url.href : "/";
        } catch (e) {
            return "/";
        }
    };
    let leaving = false;
    const leave = async () => {
        if (leaving || (await check()) !== "ok") return;
        leaving = true;
        location.replace(target());
    };
    channel && channel.addEventListener("message", leave);
    document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && leave());
    window.addEventListener("focus", leave);
}

if (location.pathname === PORTAL_PATH || location.pathname.startsWith(PORTAL_PATH + "/")) watch_login_page();

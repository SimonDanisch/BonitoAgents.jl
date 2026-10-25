// deno-fmt-ignore-file
// deno-lint-ignore-file
// This code was bundled using `deno bundle` and it's not recommended to edit it manually

const CHECK_ROUTE = "/session";
const PORTAL_PATH = "/authelia";
const channel = typeof BroadcastChannel === "function" ? new BroadcastChannel("bonitoagents-login") : null;
async function check() {
    let r;
    try {
        r = await fetch(CHECK_ROUTE, {
            redirect: "manual",
            cache: "no-store",
            credentials: "same-origin"
        });
    } catch (e) {
        return "unreachable";
    }
    if (r.status === 204) return "ok";
    return r.type === "opaqueredirect" || r.status === 401 || r.status === 403 ? "ended" : "unreachable";
}
function announce() {
    channel && channel.postMessage("logged-in");
}
let card = null;
let ended = false;
let waiting = [];
async function recheck() {
    const status = await check();
    if (status === "ok") {
        card && card.classList.remove("bt-conn-open");
        if (ended) {
            ended = false;
            announce();
        }
        const resolvers = waiting;
        waiting = [];
        resolvers.forEach((r)=>r());
    } else if (status === "ended") {
        ended = true;
        card && card.classList.add("bt-conn-open");
    }
    return status;
}
function logged_in() {
    const p = new Promise((resolve)=>waiting.push(resolve));
    recheck();
    return p;
}
function guard(card_node) {
    card = card_node;
    setInterval(recheck, 5 * 60 * 1000);
    document.addEventListener("visibilitychange", ()=>document.visibilityState === "visible" && recheck());
    window.addEventListener("focus", ()=>ended && recheck());
    channel && channel.addEventListener("message", ()=>(ended || waiting.length) && recheck());
    window.Bonito.on_refused(()=>logged_in());
    announce();
}
async function watch_login_page() {
    if (await check() !== "ended") return;
    const target = ()=>{
        const rd = new URLSearchParams(location.search).get("rd");
        try {
            const url = new URL(rd || "/", location.origin);
            return url.origin === location.origin ? url.href : "/";
        } catch (e) {
            return "/";
        }
    };
    let leaving = false;
    const leave = async ()=>{
        if (leaving || await check() !== "ok") return;
        leaving = true;
        location.replace(target());
    };
    channel && channel.addEventListener("message", leave);
    document.addEventListener("visibilitychange", ()=>document.visibilityState === "visible" && leave());
    window.addEventListener("focus", leave);
}
if (location.pathname === PORTAL_PATH || location.pathname.startsWith(PORTAL_PATH + "/")) watch_login_page();
export { check as check };
export { announce as announce };
export { logged_in as logged_in };
export { guard as guard };
export { watch_login_page as watch_login_page };


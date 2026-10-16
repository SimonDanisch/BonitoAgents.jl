# ── Passkeys, on our own pages ───────────────────────────────────────────────
# Behind a tunnel Authelia's API is under the dashboard's own name, so our pages
# talk to it directly (`PASSKEY_JS`): a new account's page signs it in and makes
# its passkey in one step, and the account card lists, adds and removes them.
# Nobody is sent to Authelia's settings page, which is generic ("WebAuthn
# Credentials", "Default Method") and has no way back. Behind the proxy Authelia
# is under another name, which our pages cannot call, so the card links there.

# The browser half, shared by the account card (a Bonito page) and a new
# account's page (plain HTML). Authelia's API wants and gives WebAuthn's binary
# fields as base64url, like its own pages send them (@simplewebauthn/browser).
const PASSKEY_JS = replace(raw"""
window.btPasskeys = window.btPasskeys || (() => {
    const API = 'PORTAL_PATH/api';
    const b64u = buf => {
        const bytes = new Uint8Array(buf);
        let s = '';
        for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
        return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    };
    const unb64u = str => {
        let s = str.replace(/-/g, '+').replace(/_/g, '/');
        while (s.length % 4) s += '=';
        return Uint8Array.from(atob(s), c => c.charCodeAt(0)).buffer;
    };
    // One call to Authelia; its refusals carry a message worth showing.
    async function call(method, path, body) {
        const r = await fetch(API + path, {method, credentials: 'same-origin', cache: 'no-store',
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: body === undefined ? undefined : JSON.stringify(body)});
        let data = null;
        try { data = await r.json(); } catch (e) { data = null; }
        if (!r.ok || (data && data.status === 'KO'))
            throw new Error((data && data.message) || ('the login service answered ' + r.status));
        return data ? data.data : null;
    }
    // An authenticator app's code (RFC 6238: 30 s steps, 6 digits, SHA-1).
    async function code(secret) {
        const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
        let bits = '';
        for (const c of secret) bits += abc.indexOf(c).toString(2).padStart(5, '0');
        const key = new Uint8Array(Math.floor(bits.length / 8));
        for (let i = 0; i < key.length; i++) key[i] = parseInt(bits.slice(8 * i, 8 * i + 8), 2);
        const msg = new ArrayBuffer(8);
        new DataView(msg).setUint32(4, Math.floor(Date.now() / 30000));
        const k = await crypto.subtle.importKey('raw', key, {name: 'HMAC', hash: 'SHA-1'}, false, ['sign']);
        const h = new Uint8Array(await crypto.subtle.sign('HMAC', k, msg));
        const o = h[h.length - 1] & 15;
        const n = ((h[o] & 127) << 24 | h[o + 1] << 16 | h[o + 2] << 8 | h[o + 3]) % 1000000;
        return String(n).padStart(6, '0');
    }
    // Sign in with a password and an authenticator's secret, as the login page would.
    async function signIn(username, password, secret) {
        await call('POST', '/firstfactor', {username, password, keepMeLoggedIn: false});
        await call('POST', '/secondfactor/totp', {token: await code(secret)});
    }
    // Make a passkey (the browser asks the password manager or the device) and
    // register it with Authelia. Needs someone signed in with a second factor.
    async function add(description) {
        const options = (await call('PUT', '/secondfactor/webauthn/credential/register', {description})).publicKey;
        options.challenge = unb64u(options.challenge);
        options.user.id = unb64u(options.user.id);
        (options.excludeCredentials || []).forEach(c => { c.id = unb64u(c.id); });
        const cred = await navigator.credentials.create({publicKey: options});
        const res = cred.response;
        await call('POST', '/secondfactor/webauthn/credential/register', {
            id: cred.id, rawId: b64u(cred.rawId), type: cred.type,
            response: {clientDataJSON: b64u(res.clientDataJSON), attestationObject: b64u(res.attestationObject),
                       transports: res.getTransports ? res.getTransports() : []},
            clientExtensionResults: cred.getClientExtensionResults ? cred.getClientExtensionResults() : {},
            authenticatorAttachment: cred.authenticatorAttachment || undefined});
    }
    const list = async () => (await call('GET', '/secondfactor/webauthn/credentials')) || [];
    const remove = id => call('DELETE', '/secondfactor/webauthn/credential/' + encodeURIComponent(id));
    // What a passkey is called when nobody named it (its list shows when it was added).
    const defaultName = () => 'Passkey';
    // Why making one failed, in words: the browser's reasons are terse.
    const why = e => e && e.name === 'NotAllowedError' ? 'it was cancelled, or took too long'
                   : e && e.name === 'InvalidStateError' ? 'this password manager or device has one for this account already'
                   : (e && e.message) || String(e);
    return {signIn, add, list, remove, defaultName, why};
})();
""", "PORTAL_PATH" => PORTAL_PATH)

const PasskeyStyles = Bonito.Styles(
    CSS(".bt-account-head", "display" => "flex", "align-items" => "center",
        "justify-content" => "space-between", "gap" => "12px"),
    CSS(".bt-card a.bt-btn", "text-decoration" => "none"),
    CSS(".bt-passkeys", "margin-top" => "12px"),
    CSS(".bt-passkeys-title", "font-weight" => "600", "font-size" => "13px", "margin-bottom" => "2px"),
    CSS(".bt-account-fallback", "margin-top" => "14px", "padding-top" => "12px",
        "border-top" => "1px solid var(--bt-border)"),
    CSS(".bt-account-sub", "color" => "var(--bt-text-muted)", "font-size" => "13px"),
    CSS(".bt-passkey-row", "display" => "flex", "align-items" => "center", "gap" => "10px",
        "padding" => "6px 0", "font-size" => "13px"),
    CSS(".bt-passkey-row .bt-passkey-name", "font-weight" => "600"),
    CSS(".bt-passkey-row .bt-passkey-meta", "color" => "var(--bt-text-muted)", "flex" => "1"))

"""
    passkeys_block(auth, session)

The account card's passkeys. Behind a tunnel: listed, added and removed right
here. Behind the proxy: a link to Authelia's settings, where they are made.
"""
passkeys_block(auth::ProxyAuth, ::Bonito.Session) =
    DOM.a("Add a passkey"; href = portal_url(auth) * "/settings/two-factor-authentication",
          class = "bt-btn bt-btn-sm bt-btn-secondary")

function passkeys_block(::TunnelAuth, session::Bonito.Session)
    root = DOM.div(
        DOM.div("Passkeys"; class = "bt-passkeys-title"),
        DOM.div("A passkey (Proton Pass, your phone or computer, a security key) signs you in " *
                "on its own: no password, no code."; class = "bt-admin-muted"),
        DOM.div(; class = "bt-passkey-list"),
        DOM.div(DOM.input(type = "text", placeholder = "name, e.g. Proton Pass", class = "bt-passkey-name-input"),
                DOM.button("Add a passkey"; class = "bt-btn bt-btn-sm bt-passkey-add", type = "button");
                class = "bt-admin-form"),
        DOM.div(; class = "bt-admin-status bt-passkey-status");
        class = "bt-passkeys")
    Bonito.onload(session, root, js"""(root) => {
        $(Bonito.JSCode(PASSKEY_JS))
        const P = window.btPasskeys;
        const listEl = root.querySelector('.bt-passkey-list');
        const status = root.querySelector('.bt-passkey-status');
        const nameEl = root.querySelector('.bt-passkey-name-input');
        const day = t => t ? new Date(t).toISOString().slice(0, 10) : '';
        async function refresh() {
            let creds;
            try { creds = await P.list(); }
            catch (e) { status.textContent = 'Could not list your passkeys: ' + P.why(e); return; }
            listEl.replaceChildren(...(creds.length ? creds.map(c => {
                const row = document.createElement('div');
                row.className = 'bt-passkey-row';
                const name = document.createElement('span');
                name.className = 'bt-passkey-name';
                name.textContent = c.description;
                const meta = document.createElement('span');
                meta.className = 'bt-passkey-meta';
                meta.textContent = 'added ' + day(c.created_at) +
                    (c.last_used_at ? ', last used ' + day(c.last_used_at) : ', not used yet') +
                    (c.verified ? '' : '; asks for a code as well');
                const rm = document.createElement('button');
                rm.className = 'bt-btn bt-btn-sm bt-btn-secondary';
                rm.type = 'button';
                rm.textContent = 'Remove';
                rm.onclick = async () => {
                    if (!confirm('Remove the passkey "' + c.description + '"? It no longer signs you in.')) return;
                    try { await P.remove(c.id); status.textContent = 'passkey removed'; }
                    catch (e) { status.textContent = 'Could not remove it: ' + P.why(e); }
                    refresh();
                };
                row.append(name, meta, rm);
                return row;
            }) : [Object.assign(document.createElement('div'),
                   {className: 'bt-admin-muted', textContent: 'No passkey yet.'})]));
        }
        root.querySelector('.bt-passkey-add').onclick = async () => {
            status.textContent = 'Your password manager or device asks to make the passkey…';
            try {
                await P.add(nameEl.value.trim() || P.defaultName());
                nameEl.value = '';
                status.textContent = 'passkey added: from now on it signs you in';
            } catch (e) {
                status.textContent = 'The passkey was not added: ' + P.why(e);
            }
            refresh();
        };
        refresh();
    }""")
    return root
end

"""
    account_ready_page(auth, name, login)

What someone sees once their account exists (from an invite or a setup link):
behind a tunnel, one button that signs them in and makes their passkey, with the
password and authenticator folded away for whoever cannot use one; behind the
proxy, the password and authenticator to log in with.
"""
function account_ready_page(auth::TunnelAuth, name::AbstractString, login)
    a = login.authenticator
    # Our own values (a checked account name, Authelia's password and secret),
    # made safe for a <script> all the same.
    js(x) = replace(JSON.json(x), "<" => "\\u003c")
    return invite_page(200, "Your account is ready", """
        <p>Account <b>$(esc_html(name))</b>. One step left: a passkey, from your password manager
        (Proton Pass, 1Password, ...), your phone or computer, or a security key. It signs you in from now on.</p>
        <p><button id="create-passkey" type="button">Create my passkey</button></p>
        <p id="passkey-status" class="status"></p>
        <details><summary>No passkey? Use a password and an authenticator instead</summary>
        <p>Shown only now. Store both in your password manager.</p>
        <p><code class="pw">$(esc_html(login.password))</code></p>
        <p><img class="qr" src="$(qr_data_uri(a))" alt="authenticator QR code"></p>
        <p>$(AUTHENTICATOR_HELP)<br><code class="uri">$(esc_html(a.uri))</code></p>
        <p>Then <a href="$(esc_html(dashboard_url(auth)))">log in</a> with the password and a code from it.</p>
        </details>
        <script>
        $(PASSKEY_JS)
        (() => {
            const account = $(js(String(name))), password = $(js(login.password));
            const secret = $(js(match(r"[?&]secret=([A-Z2-7]+)", a.uri)[1]));
            const status = document.getElementById('passkey-status');
            document.getElementById('create-passkey').onclick = async () => {
                status.textContent = 'Signing you in...';
                try {
                    await btPasskeys.signIn(account, password, secret);
                    status.textContent = 'Your password manager or device asks to make the passkey...';
                    await btPasskeys.add(btPasskeys.defaultName());
                    status.textContent = 'Done. Opening the dashboard...';
                    location.href = $(js(dashboard_url(auth)));
                } catch (e) {
                    status.textContent = 'That did not work: ' + btPasskeys.why(e) +
                        '. Try again, or use the password and authenticator below.';
                }
            };
        })();
        </script>""")
end

function account_ready_page(auth::ProxyAuth, name::AbstractString, login)
    a = login.authenticator
    return invite_page(200, "Your account is ready", """
        <p>Account <b>$(esc_html(name))</b>. Your password and your authenticator, shown only now.</p>
        <p><code class="pw">$(esc_html(login.password))</code></p>
        <p><img class="qr" src="$(qr_data_uri(a))" alt="authenticator QR code"></p>
        <p>$(AUTHENTICATOR_HELP)<br><code class="uri">$(esc_html(a.uri))</code></p>
        <p>Store both in your password manager, then <a href="$(esc_html(dashboard_url(auth)))">log in</a>
        with the password and a code from the authenticator. Once in, you can add a passkey (Your account,
        "Add a passkey"), which then signs you in on its own.</p>""")
end

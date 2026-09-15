# The browser↔server socket drops; the guard must lock the composer at once and
# lift only when the socket is back. Real dev server, real Electron, the drop
# made the way a network blip makes it: the page's own websocket closes and
# Bonito's client reconnects by itself. Only the rendered DOM is asserted.
using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

function run_suite(server)
    server.agent_fn[] = _ -> [TK.text("echo back"), TK.end_turn()]
    modal = "document.querySelector('.bt-conn-modal')"
    led   = "document.querySelector('.bt-conn-led')"
    @testset "a dropped socket locks the composer until the connection is back" begin
        TK.new_chat(server; cwd = mktempdir(), title = "connguard")
        @test TK.wait_for(server, "the LED reads connected", "$(led)?.dataset.status === 'connected'"; timeout = 20) == true
        @test TK.eval_js(server, "!!$(modal) && !$(modal).classList.contains('bt-conn-open')") == true

        # Typing, then the drop. On a local link Bonito reconnects within
        # milliseconds, too fast to observe the locked phase from outside, so
        # the drop is announced the way the socket's own `onclose` announces
        # it (`Bonito.on_connection_connecting()`), the state is inspected, and
        # only then the socket is really closed so the real reconnect lifts it.
        TK.eval_js(server, "[...document.querySelectorAll('.bt-text-input')].find(e => e.offsetParent)?.focus(); true")
        @test TK.eval_js(server, "!!document.activeElement?.closest('.bt-text-input')") == true
        TK.eval_js(server, "Bonito.on_connection_connecting(); true")
        @test TK.wait_for(server, "the guard opens", "$(modal).classList.contains('bt-conn-open')"; timeout = 10) == true
        @test TK.eval_js(server, "$(led)?.dataset.status") == "connecting"
        @test TK.wait_for(server, "and becomes visible once the drop has lasted",
            "getComputedStyle($(modal)).opacity === '1'"; timeout = 5) == true
        # The reload button is reachable straight away, and the card counts.
        @test TK.eval_js(server, """(() => { const b = $(modal).querySelector('.bt-conn-reload'); if (!b) return 'none';
            const r = b.getBoundingClientRect(); return document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2) === b ||
                b.contains(document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2)) ? 'reachable' : 'blocked'; })()""") == "reachable"
        @test TK.wait_for(server, "the card counts the seconds",
            "/for \\d+ s/.test($(modal).querySelector('.bt-conn-elapsed')?.textContent || '')"; timeout = 5) == true
        TK.screenshot(server, joinpath(tempdir(), "connection_guard.png"))
        @test occursin("lost", TK.eval_js(server, "document.querySelector('.bt-conn-msg')?.textContent || ''"))
        # The composer is unreachable: focus was taken away, the send button sits
        # under the overlay, and a keystroke aimed at the textarea is swallowed.
        @test TK.eval_js(server, "!document.activeElement?.closest?.('.bt-text-input')") == true
        @test TK.eval_js(server, """(() => {
            const b = [...document.querySelectorAll('.bt-send-btn')].find(e => e.offsetParent); if (!b) return 'no button';
            const r = b.getBoundingClientRect();
            const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
            return hit && hit.closest('.bt-conn-modal') ? 'covered' : 'exposed'; })()""") == "covered"
        @test TK.eval_js(server, """(() => {
            const t = [...document.querySelectorAll('.bt-text-input')].find(e => e.offsetParent); if (!t) return 'no input';
            const ev = new KeyboardEvent('keydown', {key: 'a', bubbles: true, cancelable: true});
            const delivered = t.dispatchEvent(ev);          // false when the guard preventDefault-ed it
            return delivered ? 'typed' : 'swallowed'; })()""") == "swallowed"

        # Now the real drop: Bonito reconnects on its own; the guard lifts and
        # the chat is usable.
        TK.eval_js(server, "window.WEBSOCKET.close(); true")
        @test TK.wait_for(server, "the guard lifts on reconnect",
            "!$(modal).classList.contains('bt-conn-open') && $(led)?.dataset.status === 'connected'"; timeout = 45) == true
        TK.send_message(server, "after the blip")
        @test TK.wait_for(server, "the chat works after reconnecting",
            "(document.body.innerText || '').includes('echo back')"; timeout = 60) == true
        @test TK.eval_js(server, """(() => {
            const t = [...document.querySelectorAll('.bt-text-input')].find(e => e.offsetParent); if (!t) return 'no input';
            return t.dispatchEvent(new KeyboardEvent('keydown', {key: 'a', bubbles: true, cancelable: true})) ? 'typed' : 'swallowed'; })()""") == "typed"
    end
    return server
end

if abspath(PROGRAM_FILE) == @__FILE__
    server = TK.dev_server(agent = _ -> [TK.text("echo back"), TK.end_turn()])
    try
        TK.open_browser(server)
        run_suite(server)
    finally
        close(server)
    end
end

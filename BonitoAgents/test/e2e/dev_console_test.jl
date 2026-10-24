# The dev tools' view of a real browser tab (diagnostics.jl), through
# `dev_request`, the entry point the bt_dev_* MCP tools call: the tab as the
# server holds it, the time its page took to build and where, and what its
# console said, asked live and from what the page beaconed when hidden.
@testitem "e2e:dev_console" setup = [SharedServer] tags = [:e2e] begin
    const TK = SharedServer.TK
    const BT = TK.BT
    s = SharedServer.server()
    st = s.h.state
    # A fresh page, so its build is timed by the code under test.
    TK.eval_js(s, "window.__before_reload = true; location.reload(); true")
    @test TK.wait_for(s, "the page back", "window.__before_reload === undefined && !!window.__btConsole"; timeout = 60) == true
    @test TK.wait_for(s, "connected", "document.querySelector('.bt-conn-led')?.dataset.status === 'connected'"; timeout = 60) == true

    # The page knows which tab it is.
    rec = st.tabs.open[TK.eval_js(s, "window.__btConsole.tab")]
    tab = first(rec.id, 8)
    report = only(BT.dev_request(st, "inspect", Dict{String,Any}("section" => "tabs", "tab" => tab))["open"])
    @test report["connected"] == true
    @test !(report["status"] in ("SOFT_CLOSED", "CLOSED"))
    @test report["subsessions"] > 0

    # Its page build was timed, with the parts.
    page = BT.dev_request(st, "timings", Dict{String,Any}("kind" => "page", "limit" => 50))["timings"]["page"]
    mine = [r for r in page["recent"] if r["tab"] == tab]
    @test length(mine) == 1
    # Parts under 0.05 s are left out of `phases`; a page that slow lists its handler.
    @test only(mine)["seconds"] < 0.05 || occursin("handler=", only(mine)["phases"])

    # The console, asked live.
    marker = "dev-console-probe-$(time_ns())"
    TK.eval_js(s, "console.warn($(TK.json(marker)), {n: 1}); true")
    live = BT.dev_request(st, "console", Dict{String,Any}("tab" => tab, "contains" => marker))
    @test live["source"] == "live"
    @test only(live["entries"])["level"] == "warn"
    @test only(live["entries"])["text"] == "$(marker) {\"n\":1}"

    # Hidden or shown, the page sends what is new; that is what a tab that went
    # to sleep still has on the server.
    TK.eval_js(s, "document.dispatchEvent(new Event('visibilitychange')); true")
    @test timedwait(() -> any(e -> occursin(marker, e.text), rec.console), 10.0) === :ok
    beacons = BT.dev_request(st, "console", Dict{String,Any}("tab" => tab, "contains" => marker, "live" => false))
    @test beacons["source"] == "beacons"
    @test only(beacons["entries"])["text"] == "$(marker) {\"n\":1}"
    @test rec.visibility == "visible"

    # The warning was this test's.
    @test any(e -> occursin(marker, e["message"]), TK.js_errors(s))
    TK.clear_js_errors(s)

    # A page that looks frozen while the server is fine waits for something:
    # everything from the server queues behind the task that holds Bonito's
    # loading lock, and the page says which once it took 3 s. Its own thread
    # busy for over a second is noted too. Both as info: a measurement.
    TK.eval_js(s, "Bonito.lock_loading(() => new Promise(r => setTimeout(r, 3500)), 'a test wait'); true")
    held = "window.__btConsole.entries().some(e => e.text.includes('a test wait held everything from the server for 3.'))"
    @test TK.wait_for(s, "the hold reported", held; timeout = 15) == true
    @test TK.eval_js(s, "window.__btConsole.entries().some(e => e.level === 'info' && e.text.includes('everything from the server waits for a test wait (3 s so far)'))") == true
    TK.eval_js(s, "setTimeout(() => { const t = Date.now(); while (Date.now() - t < 1200) {} }, 0); true")
    @test TK.wait_for(s, "the busy page reported",
        "window.__btConsole.entries().some(e => /the page was busy for 1[0-9]{3} ms/.test(e.text))"; timeout = 15) == true
    @test isempty(TK.js_errors(s))      # info, not a warning
end

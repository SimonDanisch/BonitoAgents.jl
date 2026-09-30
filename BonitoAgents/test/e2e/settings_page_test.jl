# The Settings page: what configures rather than runs (chat defaults, Copy
# project, Debug BonitoAgents, the agent instructions, accounts) lives there,
# reached from the sidebar and from the dashboard's header. The dashboard keeps
# the workers and how to add one.
@testitem "e2e:settings_page" setup = [SharedServer] tags = [:e2e] begin
    const TestKit = SharedServer.TestKit
    using .TestKit
    const TK = TestKit
    server = SharedServer.server()

    shown(view) = "(() => { const v = document.querySelector('.bt-view-$(view)'); return !!v && getComputedStyle(v).display !== 'none'; })()"
    in_view(view, text) = "document.querySelector('.bt-view-$(view)').textContent.includes($(TK.json(text)))"
    active_entry = "(document.querySelector('.bt-side-item.bt-side-active .bt-side-name') || {}).textContent"

    TK.to_dashboard(server)
    @test TK.wait_for(server, "the dashboard", shown("dash"); timeout = 20) == true

    @testset "the dashboard keeps workers, not settings" begin
        @test TK.eval_js(server, in_view("dash", "Workers")) == true
        @test TK.eval_js(server, "!!document.querySelector('.bt-view-dash .bt-install-details')") == true
        for moved in ("Agent instructions", "Copy project", "Debug BonitoAgents")
            @test TK.eval_js(server, in_view("dash", moved)) == false
        end
    end

    @testset "Settings from the dashboard's header, Home from the sidebar" begin
        TK.click(server, ".bt-view-dash .bt-open-settings")
        @test TK.wait_for(server, "the Settings page", shown("settings"); timeout = 10) == true
        @test TK.eval_js(server, shown("dash")) == false
        @test TK.eval_js(server, active_entry) == "Settings"
        for here in ("General", "Agent instructions", "Copy project…", "Debug BonitoAgents")
            @test TK.eval_js(server, in_view("settings", here)) == true
        end
        TK.to_dashboard(server)
        @test TK.wait_for(server, "back on the dashboard", shown("dash"); timeout = 10) == true
        @test TK.eval_js(server, shown("settings")) == false
        @test TK.eval_js(server, active_entry) == "Home"
    end

    @testset "the sidebar entry, and a reload stays on Settings" begin
        TK.to_settings(server)
        @test TK.eval_js(server, active_entry) == "Settings"
        @test TK.reload!(server) == :dashboard
        @test TK.wait_for(server, "Settings again after the reload", shown("settings"); timeout = 20) == true
        TK.to_dashboard(server)
    end

    @test isempty(TK.js_errors(server))
end

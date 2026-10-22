@testitem "e2e:login_devices" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    store = get(ENV, "BT_TEST_SESSION_STORE_BIN",
                something(Sys.which("valkey-server"), Sys.which("redis-server"), ""))
    isempty(store) && error("login_devices needs valkey-server or redis-server (or BT_TEST_SESSION_STORE_BIN)")
    z = TK.dev_server(; tunnel = true, session_store_bin = store)
    b = nothing
    try
        TK.open_browser(z)
        TK.login!(z)
        TK.to_settings(z)
        TK.add_passkey_device!(z)
        TK.add_passkey!(z; name = "Phone")
        b = TK.another_browser(z)
        TK.login!(b)
        TK.to_settings(b)
        TK.add_passkey_device!(b)
        TK.add_passkey!(b; name = "Laptop")

        function still_signed_in(browser)
            @test TK.reload!(browser) == :dashboard
            @test TK.signed_in_as(browser) == "Signed in as admin (admin); groups: admins."
        end
        still_signed_in(z)
        TK.logout!(z)
        TK.passkey_login!(z)
        still_signed_in(b)
        TK.logout!(b)
        TK.passkey_login!(b)
        still_signed_in(z)
        TK.screenshot(z, "/tmp/bt-login-devices-phone.png")
        TK.screenshot(b, "/tmp/bt-login-devices-laptop.png")

        # A service restart must not turn the browsers' unchanged cookies into
        # anonymous sessions, nor force either person through another login.
        TK.restart_login!(z)
        still_signed_in(z)
        still_signed_in(b)

        TK.restart_session_store!(z)
        still_signed_in(z)
        still_signed_in(b)

        # Logging out remains local to the browser that asked for it.
        TK.to_settings(b)
        TK.logout!(b)
        still_signed_in(z)
        @test TK.wait_for(b, "second device logged out", "!!document.querySelector('#username-textfield')")
        @test isempty(TK.js_errors(z))
        @test isempty(TK.js_errors(b))
    finally
        b === nothing || TK.close_browser!(b)
        close(z)
    end
end

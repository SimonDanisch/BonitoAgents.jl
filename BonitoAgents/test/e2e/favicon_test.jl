@testitem "e2e:favicon" setup = [SharedServer] tags = [:e2e] begin
    using Test
    const TK = SharedServer.TestKit
    server = TK.dev_server()
    try
        TK.open_browser(server)
        TK.wait_for(server, "app loaded", "document.querySelector('.bt-shell') !== null")
        @test TK.eval_js(server, "document.head.querySelectorAll('link[rel=icon]').length") == 1
        @test TK.eval_js(server, "document.head.querySelectorAll('link[rel=apple-touch-icon]').length") == 1
        @test TK.eval_js(
            server, """(async () => {
                const link = document.head.querySelector('link[rel=icon]');
                const image = new Image(); image.src = link.href;
                await image.decode();
                return image.naturalWidth > 0 && link.href.includes('bonitoagents-light.svg');
            })()"""
        )
    finally
        close(server)
    end
end

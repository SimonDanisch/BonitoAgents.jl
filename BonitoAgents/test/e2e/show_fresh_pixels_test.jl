@testitem "e2e:show_fresh_pixels" setup = [SharedServer] tags = [:e2e] begin
    TK = SharedServer.TK
    using Base64
    root = mktempdir()
    path = joinpath(root, "preview.png")
    red = base64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")
    green = base64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNg+M8AAAICAQB7CYF4AAAAAElFTkSuQmCC")
    blue = base64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC")
    s = TK.dev_server(agent = p -> startswith(p,"read ") ?
        [TK.tool(; kind="read", tool_name="Read", title="Read preview.png",
            raw_input=Dict("file_path"=>path),content=[TK.image_block(read(path),"image/png")],id=replace(p," "=>"-")),TK.end_turn()] :
        [TK.mcp_call("bt_show";real_process=true,path,id=p),TK.end_turn()])
    pane = "document.querySelector('.bt-chatpane[aria-hidden=false]')"
    img(id) = "$pane.querySelector('.bt-tool-body[data-tool-id=\"$id\"] img.bt-media')"
    function pixel(id)
        return """(() => {
            const img=$(img(id)); if(!img?.complete || !img.naturalWidth) return null;
            const cv=document.createElement('canvas');cv.width=1;cv.height=1;
            const ctx=cv.getContext('2d');ctx.drawImage(img,0,0,1,1);
            return [...ctx.getImageData(0,0,1,1).data].slice(0,3).join(',');
        })()"""
    end
    try
        write(path, red)
        TK.open_browser(s)
        pid = TK.new_chat(s;cwd=root)
        TK.send_message(s,"read original")
        TK.wait_for(s,"Read tool ready","!!$pane.querySelector('.bt-tool-msg[data-msg-id*=read-original]')";timeout=60)
        TK.eval_js(s,"(() => {const h=$pane.querySelector('.bt-tool-msg[data-msg-id*=read-original] .bt-tool-header');if(h.dataset.expanded!=='true') h.click();return true;})()")
        @test TK.wait_for(s,"Read displays original red PNG","$(pixel("read-original"))==='255,0,0'";timeout=60)
        write(path,green)
        TK.send_message(s,"show-green")
        @test TK.wait_for(s,"bt_show reads new pixels after Read warmed the cache","$(pixel("show-green"))==='0,255,0'";timeout=20,
            describe=pixel("show-green"))
        write(path,blue)
        TK.send_message(s,"show-blue")
        @test TK.wait_for(s,"repeated bt_show reads new pixels at the same path","$(pixel("show-blue"))==='0,0,255'";timeout=20,
            describe=pixel("show-blue"))
        TK.send_message(s,"read current")
        TK.wait_for(s,"new Read tool ready","!!$pane.querySelector('.bt-tool-msg[data-msg-id*=read-current]')";timeout=30)
        TK.eval_js(s,"(() => {const h=$pane.querySelector('.bt-tool-msg[data-msg-id*=read-current] .bt-tool-header');if(h.dataset.expanded!=='true') h.click();return true;})()")
        @test TK.wait_for(s,"Read also refreshes after other previews","$(pixel("read-current"))==='0,0,255'";timeout=30)
        TK.reload!(s)
        @test TK.wait_for(s,"reloaded preview uses current worker bytes","$(pixel("show-blue"))==='0,0,255'";timeout=30)
        TK.screenshot(s,joinpath(tempdir(),"bonitoagents-fresh-preview-pixels.png"))
        @test isempty(TK.js_errors(s))
    finally
        close(s)
        rm(root;recursive=true,force=true)
    end
end

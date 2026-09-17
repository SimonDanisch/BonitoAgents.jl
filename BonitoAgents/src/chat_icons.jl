# A chat icon is an identity, not a preview of its latest output. The first
# picture a chat shows becomes its icon and its bytes are copied into chat
# storage; only "Set as chat icon" on a picture in the chat replaces it.
chat_icon_dir(state, p) = joinpath(state.state_dir, "chats", p.id, "icon")

function chat_icon_state(state::ServerState, p::ProjectInfo)
    lock(state.lock) do
        get!(state.chat_icons, p.id) do
            dir = chat_icon_dir(state, p)
            selection = joinpath(dir, "selected")
            path = if isfile(selection)
                name = strip(read(selection, String))
                name == basename(name) && isfile(joinpath(dir, name)) ? joinpath(dir, name) : nothing
            else
                nothing
            end
            ChatIconState(; path)
        end
    end
end

# Every file-backed picture in the chat, latest first: (worker file?, path).
function chat_icon_candidates(state, p, msgs, chat_dir)
    candidates = Tuple{Bool,String}[]
    for (i, m) in enumerate(Iterators.reverse(msgs))
        i % 100 == 0 && yield()
        if m isa UserMsg
            _, rels = split_attachment_suffix(m.text)
            for rel in Iterators.reverse(rels)
                lowercase(splitext(rel)[2]) in SHOW_IMAGE_EXTS || continue
                push!(candidates, (false, joinpath(p.server_path, rel)))
            end
        elseif m isa ToolMsg && tool_key(m) == "bt_show"
            content = tool_content_for_render(m, chat_dir)
            ref = find_show_reference(content)
            ref === nothing && continue
            path = parse_show_path(ref)
            path === nothing && continue
            lowercase(splitext(path)[2]) in SHOW_IMAGE_EXTS || continue
            push!(candidates, (true, show_worker_path(ShowTool(state, p.id, p.server_path, path))))
        end
    end
    return unique(candidates)
end

# Stores the first readable candidate as the icon and returns its path in chat
# storage, or `nothing` when none could be read. Without `force` an existing
# selection wins and the candidates are not touched. Serialized per chat, so
# an existing selection stays visible while a worker transfer runs.
function select_chat_icon!(state, p, candidates::Vector{Tuple{Bool,String}}; force::Bool = false)
    icon = chat_icon_state(state, p)
    lock(icon.lock) do
        current = lock(() -> icon.path, state.lock)
        !force && current !== nothing && return current
        isempty(candidates) && return nothing
        dir = chat_icon_dir(state, p)
        mkpath(dir)
        for (worker, source) in candidates
            tmp = tempname(dir)
            try
                if worker
                    # Snapshot directly from the worker. The normal bt_show
                    # route no longer populates a server mirror as a side effect.
                    if haskey(state.worker_control_ws, p.worker_id)
                        fetch_file_from_worker(state, p.worker_id, source, tmp)
                    else
                        local_path = show_server_path(ShowTool(state, p.id, p.server_path, source))
                        isfile(local_path) || continue
                        cp(local_path, tmp)
                    end
                else
                    isfile(source) || continue
                    cp(source, tmp)
                end
                filesize(tmp) > 0 || continue
                name = bytes2hex(open(sha256, tmp)) * lowercase(splitext(source)[2])
                path = joinpath(dir, name)
                path == current && return current  # already the icon
                mv(tmp, path; force = true)
                selection = joinpath(dir, "selected")
                write(selection * ".partial", name)
                mv(selection * ".partial", selection; force = true)
                lock(state.lock) do; icon.path = path; end
                # The previous picture is unreferenced now; every tab re-renders
                # its rows on the notify that follows.
                for f in readdir(dir)
                    f in (name, "selected") || rm(joinpath(dir, f); force = true)
                end
                return path
            catch e
                (e isa Base.IOError || e isa SystemError || e isa ErrorException ||
                 e isa EOFError || e isa WorkerUnreachableError) || rethrow()
                @debug "chat icon: image unavailable" project = p.id source exception = e
            finally
                rm(tmp; force = true)
                rm(tmp * ".partial"; force = true)
            end
        end
        return nothing
    end
end

select_chat_icon!(state, p, msgs::AbstractVector, chat_dir) =
    select_chat_icon!(state, p, chat_icon_candidates(state, p, msgs, chat_dir))

# The automatic pick for a chat without an icon. Network work runs in the
# background; a chat that has never shown a picture is rescanned only when its
# history changes or its worker comes back.
function request_chat_icon!(state::ServerState, p::ProjectInfo)
    state = root_state(state)
    icon = chat_icon_state(state, p)
    lock(state.lock) do
        icon.task !== nothing && !istaskdone(icon.task) && return
        icon.path !== nothing && return
        history = joinpath(state.state_dir, "chats", p.id, "chat.md")
        info = stat(history)
        stamp = (info.mtime, info.size, haskey(state.worker_control_ws, p.worker_id))
        icon.stamp == stamp && return
        icon.stamp = stamp
        icon.task = @async begin
            try
                msgs, chat_dir = overview_msgs(state, p)
                select_chat_icon!(state, p, msgs, chat_dir)
            catch e
                @warn "could not choose chat icon" project = p.id exception = (e, catch_backtrace())
            finally
                # Clear before notifying so listeners can request another scan
                # if a message arrived while a worker file was being fetched.
                lock(state.lock) do; icon.task = nothing; end
                lock(() -> icon.path, state.lock) === nothing || notify_chats!(state)
                request_chat_icon!(state, p)
            end
        end
    end
    return nothing
end

# The user's explicit pick from the chat. `path` is the worker-side path a
# bt_show or Read result carries on its media wrap, or the bare file name of a
# user attachment. Returns the background task; the sidebar and overview
# refresh once the bytes are stored.
function set_chat_icon!(state::ServerState, p::ProjectInfo, worker::Bool, path::AbstractString)
    state = root_state(state)
    lowercase(splitext(path)[2]) in SHOW_IMAGE_EXTS ||
        throw(ArgumentError("not a picture the chat can show: $path"))
    candidate = if worker
        isabspath(path) || throw(ArgumentError("worker path must be absolute: $path"))
        (true, String(path))
    else
        is_attachment_name(path) || throw(ArgumentError("invalid attachment name: $path"))
        (false, joinpath(p.server_path, ATTACHMENT_DIR_NAME, path))
    end
    icon = chat_icon_state(state, p)
    return @async begin
        old = lock(() -> icon.path, state.lock)
        stored = try
            select_chat_icon!(state, p, [candidate]; force = true)
        catch e
            @warn "could not set chat icon" project = p.id worker path exception = (e, catch_backtrace())
            nothing
        end
        if stored === nothing
            @warn "chat icon: picture unavailable" project = p.id worker path
        elseif stored != old
            notify_chats!(state)
        end
    end
end

function chat_icon_image(state::ServerState, p::ProjectInfo)
    icon = chat_icon_state(state, p)
    request_chat_icon!(state, p)
    path = lock(() -> icon.path, state.lock)
    return path === nothing ? nothing : Bonito.Asset(path)
end

# Right-click on a picture in the chat. bt_show and Read results carry their
# worker path on the media wrap, user attachments their file name (see
# msg_to_dict(::UserMsg) and the gallery in bonitoagents.js). Opening the menu
# changes nothing; only its one action does.
function chat_icon_contextmenu(session, model::ChatModel)
    choose = Observable(Dict{String,Any}())
    on(session, choose) do pick
        p = get(model.state.projects[], model.project_id, nothing)
        p === nothing && return
        set_chat_icon!(model.state, p, pick["worker"]::Bool, String(pick["path"]))
    end
    return js"""event => {
        const img = event.target.closest('img.bt-media, img.bt-user-att-img');
        if (!img) return;
        const wrap = img.closest('[data-worker-path]');
        const pick = wrap ? {worker: true, path: wrap.dataset.workerPath}
                          : {worker: false, path: img.dataset.attachmentName};
        if (!pick.path) return;
        event.preventDefault(); event.stopPropagation();
        document.querySelector('.bt-chat-icon-menu')?.closeMenu();
        const menu = document.createElement('div');
        menu.className = 'bt-menu-list bt-chat-icon-menu'; menu.setAttribute('role', 'menu');
        const button = document.createElement('button');
        button.textContent = 'Set as chat icon'; button.setAttribute('role', 'menuitem');
        button.className = 'bt-menu-item';
        menu.appendChild(button);
        (img.closest('.bt-shell, .bt-app, .bt-dash') || document.body).appendChild(menu);
        menu.style.left = Math.min(event.clientX, innerWidth - menu.offsetWidth) + 'px';
        menu.style.top = Math.min(event.clientY, innerHeight - menu.offsetHeight) + 'px';
        const listeners = new AbortController();
        menu.closeMenu = () => { listeners.abort(); menu.remove(); };
        document.addEventListener('pointerdown', e => {
            if (!menu.contains(e.target)) menu.closeMenu();
        }, {capture:true, signal:listeners.signal});
        document.addEventListener('keydown', e => {
            if (e.key === 'Escape') menu.closeMenu();
        }, {signal:listeners.signal});
        button.onclick = () => { $(choose).notify(pick); menu.closeMenu(); };
        button.focus();
    }"""
end

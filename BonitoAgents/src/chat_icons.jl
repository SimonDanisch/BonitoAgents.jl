# A chat icon is an identity, not a preview of its latest output. Select once,
# copy the bytes into chat storage, and replace the selection only on request.
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

function chat_icon_candidates(state, p, msgs, chat_dir)
    candidates = Tuple{Bool,String}[]  # worker file?, path
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

# Serializes initialization and explicit shuffles across every tab. Network
# work runs in the background; an existing selection remains visible throughout.
function select_chat_icon!(state, p, msgs, chat_dir; shuffle::Bool = false)
    icon = chat_icon_state(state, p)
    lock(icon.lock) do
        current = lock(() -> icon.path, state.lock)
        !shuffle && current !== nothing && return current
        candidates = chat_icon_candidates(state, p, msgs, chat_dir)
        dir = chat_icon_dir(state, p)
        # Previously selected pictures remain shuffle choices even after the
        # worker deletes or overwrites their original files.
        if shuffle && isdir(dir)
            append!(candidates, [(false, joinpath(dir, f)) for f in readdir(dir)
                if lowercase(splitext(f)[2]) in SHOW_IMAGE_EXTS])
        end
        isempty(candidates) && return current
        if shuffle
            offset = rand(0:length(candidates)-1)
            candidates = circshift(candidates, offset)
        end
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
                path == current && continue  # shuffle must actually change the picture
                mv(tmp, path; force = true)
                selection = joinpath(dir, "selected")
                write(selection * ".partial", name)
                mv(selection * ".partial", selection; force = true)
                lock(state.lock) do; icon.path = path; end
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
        return current
    end
end

function request_chat_icon!(state::ServerState, p::ProjectInfo; shuffle::Bool = false)
    state = root_state(state)
    icon = chat_icon_state(state, p)
    lock(state.lock) do
        icon.task !== nothing && !istaskdone(icon.task) && return
        !shuffle && icon.path !== nothing && return
        history = joinpath(state.state_dir, "chats", p.id, "chat.md")
        info = stat(history)
        stamp = (info.mtime, info.size, haskey(state.worker_control_ws, p.worker_id))
        !shuffle && icon.stamp == stamp && return
        icon.stamp = stamp
        icon.task = @async begin
            old = lock(() -> icon.path, state.lock)
            try
                msgs, chat_dir = overview_msgs(state, p)
                select_chat_icon!(state, p, msgs, chat_dir; shuffle)
            catch e
                @warn "could not choose chat icon" project = p.id exception = (e, catch_backtrace())
            finally
                # Clear before notifying so listeners can request another scan
                # if a message arrived while a worker file was being fetched.
                lock(state.lock) do; icon.task = nothing; end
                old == lock(() -> icon.path, state.lock) || notify_chats!(state)
                request_chat_icon!(state, p)
            end
        end
    end
    return nothing
end

function chat_icon_image(state::ServerState, p::ProjectInfo)
    icon = chat_icon_state(state, p)
    request_chat_icon!(state, p)
    path = lock(() -> icon.path, state.lock)
    return path === nothing ? nothing : Bonito.Asset(path)
end

# Shared by sidebar icons and dashboard thumbnails. Opening the menu does not
# change the identity; only clicking its explicit action does.
function chat_icon_contextmenu(session, state, selector)
    shuffle = Observable("")
    on(session, shuffle) do pid
        p = get(state.projects[], pid, nothing)
        p === nothing || request_chat_icon!(state, p; shuffle = true)
    end
    return js"""event => {
        const image = event.target.closest($(selector));
        const row = image?.closest('[data-project-id]');
        if (!row?.dataset.projectId) return;
        event.preventDefault(); event.stopPropagation();
        document.querySelector('.bt-chat-icon-menu')?.closeMenu();
        const menu = document.createElement('div');
        menu.className = 'bt-menu-list bt-chat-icon-menu'; menu.setAttribute('role', 'menu');
        const button = document.createElement('button');
        button.textContent = 'Shuffle chat image'; button.setAttribute('role', 'menuitem');
        button.className = 'bt-menu-item';
        menu.appendChild(button);
        (row.closest('.bt-shell, .bt-app, .bt-dash') || document.body).appendChild(menu);
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
        button.onclick = () => { $(shuffle).notify(row.dataset.projectId); menu.closeMenu(); };
        button.focus();
    }"""
end

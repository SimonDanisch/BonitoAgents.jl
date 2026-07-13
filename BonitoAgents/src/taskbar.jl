# ── TaskBar: the live-task board for long-running work ───────────────────────
# A Bonito component, state-first: the `TaskBar` owns ONE list of the live task
# MESSAGES (`items`) and renders them as plain Julia DOM. Nothing here scans the
# chat's (virtually scrolled) DOM — scrolling, node recycling and remounts
# cannot affect the bar, because the bar never looks at them.
#
# Membership IS liveness: a task is live iff it's in `items`. The two mutators
# (`push!(bar, task)` / `finished!(task)`, defined over the message types in
# chat.jl) are the ONLY way in and out, and the bar runs its OWN poll loop
# (`run_taskbar!`) that asks each task `isdone(task)` and `finished!`es it. No
# `pin_task!`/`unpin_task!`, no external `background_poll_loop`.

struct TaskbarItem
    id        :: String
    kind      :: Symbol                       # :tool | :todo
    icon      :: String
    label     :: String
    started   :: Float64
    stoppable :: Bool
    # 0-based index of the source message in the chat store (stable: the
    # store is append-only). Lets a slot click scroll the chat there
    # DETERMINISTICALLY via the virtual scroller's geometry — a node-based
    # scrollIntoView only works when the pill happens to be rendered.
    msg_index :: Int                          # -1 = no chat anchor
    # Todo lists only: every entry, rendered in full — finished ones are
    # crossed out, the in-progress one highlighted.
    entries   :: Vector{Tuple{String,String}} # (content, status)
    # Live-source handle for pills that expose a current-activity line
    # (the subagent `TaskToolMsg` feed — see `taskbar_activity` below and its
    # chat.jl overloads). `Any` because the message types live in chat.jl,
    # which is included AFTER this file. `nothing` for everything else.
    source    :: Any
end

TaskbarItem(id, kind, icon, label; started = time(), stoppable = false,
            msg_index = -1, entries = Tuple{String,String}[], source = nothing) =
    TaskbarItem(String(id), kind, String(icon), String(label),
                Float64(started), stoppable, Int(msg_index),
                collect(Tuple{String,String}, entries), source)

# Current-activity affordance for slot sources with a live subagent feed.
# chat.jl overloads both for `TaskToolMsg`; the fallbacks keep every other
# slot unchanged. `taskbar_activity(source, now)` returns the feed's latest
# one-liner (a `String`) or `nothing` (no line to show).
has_activity_feed(::Any) = false
taskbar_activity(::Any, ::Float64) = nothing

# Live todo rows for a `:todo` slot. chat.jl overloads it for `TodoListMsg` to
# read the message's CURRENT entries (they mutate in-place); the fallback keeps
# non-todo slots out. Returns `Vector{Tuple{content,status}}` or `nothing`.
taskbar_todo_rows(::Any) = nothing

# Live slot label. chat.jl overloads it for tool messages so a bash's
# human-readable description (which streams in AFTER the pill is pinned)
# replaces the raw command on the next clock tick — a KeyedList slot is never
# rebuilt by key, so the label can't come from a render-time snapshot. The
# fallback returns the snapshot label unchanged.
taskbar_slot_label(::Any, fallback) = fallback

"""
    TaskBar() -> TaskBar

The chat's live-task board and the SINGLE source of truth for what's live: a
task IS live iff it's in `items`. The bar OWNS everything — the two mutators
(`push!`/`finished!`, defined in chat.jl over the message types) and its OWN
poll loop (`run_taskbar!`): once a second it asks each task `isdone(task)` (each
message type answers for itself — a background bash/subagent's output-file
fd-close, a todo's all-done) and `finished!`es the ones that are. No
`pin_task!`/`unpin_task!`, no `background_poll_loop` scanning `msgs_store`.

`items` holds the task MESSAGES themselves (`Any` only because their types live
in chat.jl, included after this file). `clock` drives the elapsed-time labels
(ticked by the loop while live). `stop_request` fires with a task id on ⊗.
"""
mutable struct TaskBar
    items        :: Observable{Vector{Any}}
    clock        :: Observable{Float64}
    stop_request :: Observable{String}
    open         :: Base.RefValue{Bool}
    poll         :: Base.RefValue{Union{Task,Nothing}}
    lock         :: ReentrantLock
end

TaskBar() = TaskBar(Observable(Any[]), Observable(time()), Observable(""),
                    Ref(true), Ref{Union{Task,Nothing}}(nothing), ReentrantLock())

Base.isopen(tb::TaskBar) = tb.open[]
# Close the bar: stops its poll loop and drops every task (chat teardown).
function Base.close(tb::TaskBar)
    tb.open[] = false
    lock(tb.lock) do; tb.items[] = Any[]; end
    return nothing
end

# The bar's OWN poll loop — the whole "who leaves" story. `isdone`/`finished!`
# dispatch on the message type (chat.jl); a per-task throw can't take the loop
# down. Once a second it also RE-EMITS `items` (a copy) so the KeyedList re-diffs:
# a slot whose `taskbar_dyn_key` changed (label / activity / todo entries) gets a
# clean remove+insert, unchanged slots are survivors (no DOM op). This is what
# drives live content now that the slots hold no observable bindings (only the
# elapsed timer is updated in JS). Started lazily by the first `push!`.
function run_taskbar!(tb::TaskBar)
    while isopen(tb)
        tasks = lock(() -> copy(tb.items[]), tb.lock)
        for task in tasks
            try
                isdone(task) && finished!(task)
            catch e
                @warn "taskbar poll: isdone/finished! threw" exception = (e, catch_backtrace())
            end
        end
        lock(tb.lock) do
            isempty(tb.items[]) || (tb.items[] = copy(tb.items[]))
        end
        sleep(1.0)
    end
    return nothing
end

# Start the loop once (idempotent) — called from `push!`.
function ensure_running!(tb::TaskBar)
    tb.poll[] === nothing || return nothing
    tb.poll[] = Base.errormonitor(@async run_taskbar!(tb))
    return nothing
end

# "12s" / "3m" / "3m20s" — same shape the old JS ticker produced.
function elapsed_str(sec::Real)
    sec <= 1 && return ""
    sec < 60 && return string(round(Int, sec), "s")
    m = floor(Int, sec / 60); s = round(Int, sec - 60m)
    s == 0 ? string(m, "m") : string(m, "m", s, "s")
end

# A slot renders ENTIRELY STATIC — no `map(session, obs)` anywhere. Nested
# observable DOM inside a KeyedList item leaks and, worse, its callback tries to
# update a node the KeyedList already removed ("Cannot set properties of null" /
# "Timeout waiting for DOM node"). Instead:
#   • the elapsed timer is driven by ONE `setInterval` in the bar (reads
#     `data-started` off the DOM — no Julia binding, self-cleans via a
#     MutationObserver);
#   • everything else (label, activity text, todo rows) is a snapshot, and CHANGES
#     re-render through the KeyedList KEY: the key embeds `taskbar_dyn_key(task)`,
#     so when the label/activity/entries change the key changes and KeyedList does
#     a clean remove+insert (the bar's poll loop re-emits `items` once a second to
#     drive that diff). No survivor ever holds a live binding.
function render_taskbar_item(session::Bonito.Session, bar::TaskBar, item::TaskbarItem)
    timer = DOM.span(elapsed_str(time() - item.started);
                     class = "bt-taskbar-slot-timer", dataStarted = string(item.started))
    label = DOM.span(taskbar_slot_label(item.source, item.label);
                     class = "bt-taskbar-slot-label")
    head = Any[
        DOM.span(item.icon; class = "bt-taskbar-slot-icon"),
        label,
        timer,
    ]
    if has_activity_feed(item.source)
        # The feed's latest one-liner, computed NOW (static, a fact off the wire).
        # It re-renders via the KeyedList key (`taskbar_dyn_key` embeds the latest
        # label), so the bar's 1 Hz re-emit swaps it as new frames land.
        act_label = taskbar_activity(item.source, time())
        act_label === nothing ||
            insert!(head, 3, DOM.span(act_label; class = "bt-taskbar-activity"))
    end                         # between the label and the elapsed timer
    item.stoppable && push!(head, DOM.button(;
        type = "button", class = "bt-taskbar-slot-stop bt-stop-mini",
        title = "Stop",
        onclick = js"event => { event.stopPropagation(); $(bar.stop_request).notify($(item.id)); }"))
    if item.kind === :todo
        ents = taskbar_todo_rows(item.source)
        ents === nothing && (ents = item.entries)
        rows = DOM.div((begin
                cls = status == "completed"   ? "bt-taskbar-todo-item bt-todo-done" :
                      status == "in_progress" ? "bt-taskbar-todo-item bt-todo-active" :
                                                "bt-taskbar-todo-item"
                DOM.div(content; class = cls)
            end for (content, status) in ents)...;
                class = "bt-taskbar-todo-rows")
        DOM.div(DOM.div(head...; class = "bt-taskbar-todo-head"), rows;
                class = "bt-taskbar-slot bt-taskbar-todo",
                dataTaskId = item.id, dataMsgIndex = string(item.msg_index))
    else
        DOM.div(head...; class = "bt-taskbar-slot",
                dataTaskId = item.id, dataMsgIndex = string(item.msg_index))
    end
end

# `taskbar_dyn_key(task)` — a snapshot of the slot's CHANGING content (label /
# latest activity / staleness / todo entries), NOT the elapsed time. It's folded
# into the KeyedList key so a content change re-renders the slot; the fallback
# keeps non-dynamic slots stable. Overloaded per message type in chat.jl.
taskbar_dyn_key(::Any) = ""

struct TaskbarSlot
    bar  :: TaskBar
    task :: Any
end
Bonito.jsrender(session::Bonito.Session, s::TaskbarSlot) =
    Bonito.jsrender(session, render_taskbar_item(session, s.bar, taskbar_item_for(s.task)))

function Bonito.jsrender(session::Bonito.Session, bar::TaskBar)
    # KeyedList keyed by `id#<dyn-content-hash>`: add/remove/move AND content
    # changes are all clean DOM ops, no survivor holds a live binding. Fresh
    # `TaskbarSlot`s each emit (cheap); KeyedList keeps a survivor's DOM by key.
    slots = map(session, bar.items) do tasks
        [TaskbarSlot(bar, t) for t in tasks]
    end
    list = KeyedList(slots; key = s -> string(s.task.id, "#", hash(taskbar_dyn_key(s.task))))
    container = DOM.div(list; class = "bt-taskbar bt-taskbar-slots")
    # ONE ticker for ALL slots: just the elapsed labels, read off `data-started`
    # (too fast for a Julia re-render). Staleness + all other content are
    # Julia-driven via the key. Self-cleans when the bar leaves the document.
    ticker = js"""
        (host => {
            const es = sec => sec<=1 ? "" : sec<60 ? Math.round(sec)+"s"
                : (()=>{const m=Math.floor(sec/60), s=Math.round(sec-60*m);
                        return s===0 ? m+"m" : m+"m"+s+"s";})();
            const tick = () => {
                const now = Date.now()/1000;
                host.querySelectorAll('.bt-taskbar-slot-timer[data-started]').forEach(el => {
                    el.textContent = es(now - parseFloat(el.dataset.started)); });
            };
            const iv = setInterval(tick, 1000); tick();
            const mo = new MutationObserver(() => {
                if (!host.isConnected) { clearInterval(iv); mo.disconnect(); } });
            mo.observe(document.body, { childList: true, subtree: true });
        })($(container))
    """
    return Bonito.jsrender(session, DOM.div(container, ticker; class = "bt-taskbar-host"))
end

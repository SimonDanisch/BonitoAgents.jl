# ── TaskBar: the pin-board for long-running work ─────────────────────────────
# A Bonito component, state-first: Julia owns ONE list of pinned items on the
# shared ChatModel (`taskbar_items`); the widget renders it as plain Julia
# DOM. Nothing here scans the chat's (virtually scrolled) DOM — scrolling,
# node recycling and remounts cannot affect the bar, because the bar never
# looks at them.
#
# Items are pinned/unpinned by the SAME Julia code that drives the tool
# lifecycle (`process!` / `process_update!` / the bg poller / the todo
# lifecycle) — see `pin_task!` / `unpin_task!` in chat.jl.

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
# slot unchanged. `taskbar_activity(source, now)` returns
# `(label = <one-liner>, stale = <Bool>)` or `nothing` (no line).
has_activity_feed(::Any) = false
taskbar_activity(::Any, ::Float64) = nothing

"""
    TaskBar(items, clock) -> TaskBar

The chat's pin-board. State-first, ALL polling in Julia: `clock` is an
`Observable{Float64}` ticked once per second by a Julia `Timer` (see
`ensure_taskbar_clock!` in chat.jl) while items are live; the elapsed-time
labels are `map(clock)` text bindings, so Bonito updates exactly those text
nodes — there is NO JS poller and nothing ever scans the DOM. `stop_request`
fires with the item id when the user clicks an item's ⊗.
"""
struct TaskBar
    items        :: Observable{Vector{TaskbarItem}}
    clock        :: Observable{Float64}
    stop_request :: Observable{String}
end

TaskBar(items::Observable{Vector{TaskbarItem}}, clock::Observable{Float64}) =
    TaskBar(items, clock, Observable(""))

# "12s" / "3m" / "3m20s" — same shape the old JS ticker produced.
function elapsed_str(sec::Real)
    sec <= 1 && return ""
    sec < 60 && return string(round(Int, sec), "s")
    m = floor(Int, sec / 60); s = round(Int, sec - 60m)
    s == 0 ? string(m, "m") : string(m, "m", s, "s")
end

function render_taskbar_item(session::Bonito.Session, bar::TaskBar, item::TaskbarItem)
    # Elapsed label: a Julia-driven text binding. Ticks come from `bar.clock`
    # (a Julia Timer), NOT a browser setInterval — Bonito updates just this
    # text node when the clock advances.
    timer = DOM.span(map(now -> elapsed_str(now - item.started), session, bar.clock);
                     class = "bt-taskbar-slot-timer")
    head = Any[
        DOM.span(item.icon; class = "bt-taskbar-slot-icon"),
        DOM.span(item.label; class = "bt-taskbar-slot-label"),
        timer,
    ]
    if has_activity_feed(item.source)
        # Subagent current-activity one-liner + staleness, re-derived on the
        # SAME 1 Hz Julia clock tick that drives the elapsed labels: while the
        # feed moves it shows the latest entry; once it goes quiet past the
        # staleness window the span turns amber (`bt-task-stale`, and the
        # whole pill via the :has() rule) and reads "no activity Xm" — the
        # "dead or just slow?" answer.
        activity = map(session, bar.clock) do now
            st = taskbar_activity(item.source, now)
            st === nothing && return DOM.span(""; class = "bt-taskbar-activity")
            DOM.span(st.label; class = st.stale ?
                "bt-taskbar-activity bt-task-stale" : "bt-taskbar-activity")
        end
        insert!(head, 3, activity)   # between the label and the elapsed timer
    end
    # Always-visible stop, styled like the composer's stop button
    # (.bt-stop-mini draws the red square).
    item.stoppable && push!(head, DOM.button(;
        type = "button", class = "bt-taskbar-slot-stop bt-stop-mini",
        title = "Stop",
        onclick = js"event => { event.stopPropagation(); $(bar.stop_request).notify($(item.id)); }"))
    if item.kind === :todo
        rows = map(item.entries) do (content, status)
            cls = status == "completed"   ? "bt-taskbar-todo-item bt-todo-done" :
                  status == "in_progress" ? "bt-taskbar-todo-item bt-todo-active" :
                                            "bt-taskbar-todo-item"
            DOM.div(content; class = cls)
        end
        DOM.div(DOM.div(head...; class = "bt-taskbar-todo-head"), rows...;
                class = "bt-taskbar-slot bt-taskbar-todo")
    else
        # data-msg-index feeds the chat module's click-to-scroll (jump the
        # virtual scroller to the source pill).
        DOM.div(head...; class = "bt-taskbar-slot",
                dataTaskId = item.id, dataMsgIndex = string(item.msg_index))
    end
end

function Bonito.jsrender(session::Bonito.Session, bar::TaskBar)
    # Whole-bar re-render per update is fine: a handful of pinned items,
    # plain DOM (AGENTS.md §5 — small bounded region). Per-render click
    # handlers + the per-item clock bindings live in the map's sub-session,
    # freed on the next render. NO JS poller — the elapsed labels tick from
    # `bar.clock`, a Julia Timer.
    slots = map(session, bar.items) do items
        isempty(items) ?
            DOM.div(; class = "bt-taskbar-slots",
                    style = Styles("display" => "none")) :
            DOM.div((render_taskbar_item(session, bar, it) for it in items)...;
                    class = "bt-taskbar-slots")
    end
    return Bonito.jsrender(session, DOM.div(slots; class = "bt-taskbar"))
end

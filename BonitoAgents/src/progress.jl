# Shared progress callback contract used by the long-running operations
# (sync, project import, GitHub clone). RemoteSync already emits structured
# `(stage::Symbol, info::NamedTuple)` events; we mirror that signature for
# the rest of the stack so the dashboard's busy card can render structured
# progress (percent + recent files) instead of free-form strings.
#
# Stages we emit / consume:
#   :phase             — generic free-text update.   info = (msg=String,)
#   :walk_done         — manifest scan done.          info = (count=Int,)
#   :manifest_received — receiver got manifest.       info = (count=Int,)
#   :plan_received     — sender got plan.             info = (planned=Int, work=Int)
#   :file_start        — sender starts a file.        info = (idx=Int, total=Int, rel=String)
#   :apply_start       — receiver starts a file.      info = (idx=Int, total=Int, rel=String)
#   :transfer_done     — directory transfer done.     info = (files=Int,) | (written=Int, deleted=Int, skipped=Int)
#   :file_done, :file_chunk, :wait_manifest, :walk_start — informational, ignored by the UI
#
# Callbacks have signature `(stage::Symbol, info::NamedTuple) -> Any`.
# Errors raised from inside the callback are swallowed so a UI hiccup
# (e.g. a stale browser observable update) can never abort the transfer.

notify_progress(::Nothing, ::Symbol, ::NamedTuple) = nothing
function notify_progress(cb, stage::Symbol, info::NamedTuple)
    try
        cb(stage, info)
    catch err
        @debug "progress callback threw" stage exception=err
    end
    return nothing
end

# ── BusyState — what the window's ONE progress card renders ────────────────
# A NamedTuple snapshot of the current operation, rendered by
# `progress_overlay` and by nothing else: there is exactly one of these per
# window, top-centered, and every long-running operation in the app reports
# into it. It replaced a second, parallel channel (a 3.2s auto-dismissing
# toast) that the chat's "continue on worker" used to report into — which is
# why a move looked like a random popup that flashed the same word over and
# over: each of the thousands of per-file progress events flashed its own
# toast for 3.2s instead of updating one line in place.
#
# `kind` is what the card does, and it is the reason this is not just a
# string:
#   :idle — nothing running, card hidden.
#   :run  — an operation is in flight. The card STAYS UP until the operation
#           ends; `msg` is its current line, `done`/`total` drive the bar.
#   :ok   — it finished. Shown briefly, then faded out by the card's own JS.
#   :err  — it failed. The card stays until the user dismisses it, shows
#           `detail` (the full error, selectable) and offers a Copy button.
#           A failure the user cannot read or copy is the one state that must
#           never expire on a timer.
#
# The card updates by *deriving Observable{String}s* off this one snapshot and
# binding each to its own <span>. That hits Bonito's fast-path
# `Observable{String}` jsrender (innerText swap, no DOM replacement), so it
# updates in place without re-mounting — which matters: a librsync transfer
# fires thousands of file events and a fresh DOM tree per event would flash.

const BUSY_IDLE = (
    kind   = :idle,
    title  = "",
    msg    = "",
    detail = "",
    done   = 0,
    total  = 0,
)

# The ONE predicate the "don't pile up two of these" guards ask. Deliberately
# not an `is_busy_idle` twin: a finished-or-failed card is still ON SCREEN (that
# is the point of :ok and :err) and must not stop the user from starting the
# next operation, so there is no "idle?" question worth asking.
is_busy_running(s) = s.kind === :run

# Begin a new operation. Clears any prior progress (including a failure the
# user never dismissed — starting the next thing is the dismissal).
function busy_start!(obs::Observable, title::AbstractString, msg::AbstractString = "")
    BUSY_LAST_FILE_NS[] = UInt64(0)   # reset throttle so the very first file event lands
    safe_set!(obs, (
        kind   = :run,
        title  = String(title),
        msg    = String(msg),
        detail = "",
        done   = 0,
        total  = 0,
    ))
end

"""
    busy_done!(obs, msg)

The operation finished. The card shows `msg` and fades itself out after a few
seconds (the JS owns the timer, see `progress_overlay`).
"""
busy_done!(obs::Observable, msg::AbstractString) = safe_set!(obs, (
    kind = :ok, title = String(msg), msg = "", detail = "", done = 0, total = 0))

"""
    busy_fail!(obs, title, detail)

The operation failed. Unlike every other state this one has NO timer: it stays
until the user dismisses it, renders `detail` as selectable text and offers a
Copy button. Use [`error_detail`](@ref) to build `detail` from an exception.
"""
busy_fail!(obs::Observable, title::AbstractString, detail::AbstractString) =
    safe_set!(obs, (kind = :err, title = String(title), msg = "",
                    detail = String(detail), done = 0, total = 0))

busy_clear!(obs::Observable) = safe_set!(obs, BUSY_IDLE)

"""
    refuse_if_busy(busy, error_obs, what) -> Bool

The "one long operation per window at a time" guard. Returns `true` (and says so
in `error_obs`) when something is already running, so the caller can `&& return`.

Refusing SILENTLY is what makes a control look broken: the user presses Create,
nothing happens, and the only evidence is a card at the top of the screen that
names a different operation. Naming the one in the way turns a dead button into
an explanation.
"""
function refuse_if_busy(busy::Observable, error_obs::Observable, what::AbstractString)
    s = busy[]
    is_busy_running(s) || return false
    safe_set!(error_obs, "$what — \"$(s.title)\" is still running.")
    return true
end

"""
    error_detail(e, bt = nothing) -> String

The text the progress card shows (and copies) for a failed operation: the
exception as `showerror` renders it, plus the top of its stack. Copyable text is
the whole point — "Could not continue on Bosgame: SystemError" with the frames
thrown away is exactly the report that can't be acted on.
"""
function error_detail(e, bt = nothing; frames::Int = 12)
    io = IOBuffer()
    showerror(io, e)
    if bt !== nothing
        st = stacktrace(bt)
        isempty(st) || println(io)
        for f in first(st, frames)
            println(io, "  @ ", f)
        end
    end
    return String(take!(io))
end

# Per-file events arrive at librsync's pace (often 100s/sec); without a
# throttle we'd push thousands of WS frames per sync. 60ms ≈ 16fps which is
# plenty to read scrolling file paths and avoids saturating the channel.
const BUSY_FILE_THROTTLE_NS = 60_000_000  # 60 ms
const BUSY_LAST_FILE_NS = Ref{UInt64}(UInt64(0))

# Apply a structured progress event from RemoteSync / our :phase events.
function busy_event!(obs::Observable, stage::Symbol, info::NamedTuple)
    cur = obs[]
    # A late event from a transfer that already ended (or failed) must not put
    # the card back up — progress callbacks outlive the call that made them.
    is_busy_running(cur) || return nothing
    next = if stage === :phase
        merge(cur, (msg = String(get(info, :msg, "")),))
    elseif stage === :walk_done
        merge(cur, (msg = "Scanning files: $(info.count) found",))
    elseif stage === :manifest_received
        merge(cur, (msg = "Receiving manifest: $(info.count) files",))
    elseif stage === :plan_received
        merge(cur, (msg = "Planning: $(info.work) of $(info.planned) need transfer",))
    elseif stage === :file_start || stage === :apply_start
        idx   = Int(info.idx)
        total = Int(info.total)
        # Always emit the last file event; throttle in between.
        if idx != total
            now = time_ns()
            (now - BUSY_LAST_FILE_NS[]) < BUSY_FILE_THROTTLE_NS && return nothing
            BUSY_LAST_FILE_NS[] = now
        end
        verb = stage === :file_start ? "sending" : "receiving"
        rel  = String(info.rel)
        merge(cur, (
            done  = idx,
            total = total,
            msg   = "$verb $idx/$total · $rel",
        ))
    elseif stage === :transfer_done
        merge(cur, (msg = "Transfer complete", done = max(cur.total, cur.done)))
    else
        cur   # ignore informational stages (:walk_start, :file_chunk, etc.)
    end
    safe_set!(obs, next)
    return nothing
end

# ── The window's ONE progress card ────────────────────────────────────────────
"""
    progress_overlay(session, busy) -> DOM

The single top-centered card every long-running operation reports into. Mounted
ONCE per window (the shell in sidebar.jl) or once per standalone dashboard —
never both, or two cards would render the same snapshot.

Why one: the app used to have two, a dashboard-only pill and a window toast, so
where a failure showed up depended on which view happened to be open, and the
chat's move reported through the toast — a bubble over the composer that expired
after 3.2 s. Progress that expires is not progress; an error that expires cannot
be read, let alone copied.

The card is built once and mutated through derived `Observable{String}`s, which
is what keeps it cheap under a librsync transfer's thousands of per-file events.
"""
# One JSON payload per snapshot — the card's whole visual state in one message.
# NOT six node-bound `Observable{String}`s (the shape the dashboard pill used):
# every node-bound observable makes the browser resolve a `data-jscall-id`, and
# an update that lands while the page is rebuilding itself blocks Bonito's
# message pump for 30 s per lookup before throwing. A move does exactly that to
# the pane it was started from, which took the whole session down with it. This
# is also the house rule — see CONVENTIONS.md, "Observables as typed channels,
# not render units": Julia owns the data, JS owns the DOM.
progress_payload(s) = JSON.json(Dict{String,Any}(
    "kind"   => String(s.kind),
    "title"  => s.title,
    "msg"    => s.msg,
    "detail" => s.detail,
    "pct"    => s.total > 0 ? round(Int, 100 * s.done / max(s.total, 1)) : -1))

function progress_overlay(session::Bonito.Session, busy::Observable)
    dismiss = Observable("")
    on(session, dismiss) do v
        isempty(v) && return
        dismiss[] = ""
        busy_clear!(busy)
    end

    # Copy takes the headline AND the detail: the headline names the operation
    # ("Could not continue on Bosgame"), the detail is the exception and its
    # stack. Pasting one without the other loses half the report.
    copy_btn = DOM.button("Copy";
        class = "bt-btn bt-btn-secondary bt-btn-sm bt-prog-copy",
        title = "Copy this message to the clipboard",
        onclick = js"""event => {
            const card = event.currentTarget.closest('.bt-prog');
            const head = card.querySelector('.bt-prog-title')?.innerText || '';
            const body = card.querySelector('.bt-prog-detail')?.innerText || '';
            const btn  = event.currentTarget;
            navigator.clipboard.writeText((head + '\n' + body).trim()).then(() => {
                btn.textContent = 'Copied';
                setTimeout(() => { btn.textContent = 'Copy'; }, 1400);
            });
        }""")
    close_btn = DOM.button("✕";
        class = "bt-btn bt-btn-ghost bt-btn-sm bt-prog-close",
        title = "Dismiss",
        onclick = js"event => $(dismiss).notify('x')")

    # Rendered from the CURRENT snapshot, not from `BUSY_IDLE`: a browser that
    # connects (or reconnects) while a transfer is running must show it, and
    # `onjs` only fires on later updates.
    now = busy[]
    card = DOM.div(
        DOM.div(
            DOM.span(; class = "bt-prog-spin"),
            DOM.span(now.title; class = "bt-prog-title"),
            DOM.span(""; class = "bt-prog-pct"),
            DOM.span(now.msg; class = "bt-prog-msg"),
            copy_btn, close_btn;
            class = "bt-prog-row"),
        DOM.div(DOM.div(; class = "bt-prog-fill"); class = "bt-prog-bar"),
        DOM.pre(now.detail; class = "bt-prog-detail");
        class = "bt-prog bt-prog-" * String(now.kind))

    # There is ONE card per window by construction, so the class IS its address.
    # No node is interpolated into this handler for the same reason as above.
    #
    # The :ok fade is a CSS animation (`.bt-prog-ok` in styles.jl), not a timer
    # here: re-assigning className restarts it on the way in and removes it on
    # the way out, with nothing to cancel.
    Bonito.onjs(session, map(progress_payload, session, busy), js"""(payload) => {
        const s  = JSON.parse(payload);
        const el = document.querySelector('.bt-prog');
        if (!el) return;
        el.className = 'bt-prog bt-prog-' + s.kind;
        el.querySelector('.bt-prog-title').textContent  = s.title;
        el.querySelector('.bt-prog-msg').textContent    = s.msg;
        el.querySelector('.bt-prog-detail').textContent = s.detail;
        el.querySelector('.bt-prog-pct').textContent    = s.pct >= 0 ? s.pct + '%' : '';
        el.querySelector('.bt-prog-fill').style.width   = (s.pct >= 0 ? s.pct : 0) + '%';
    }""")
    return card
end

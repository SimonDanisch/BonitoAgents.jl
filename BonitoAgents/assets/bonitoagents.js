// BonitoAgents.js — client-side chat: virtual scroll, DOM windowing, streaming.
//
// All Julia↔JS traffic flows through ONE Bonito Observable: `comm`.
// Julia → JS:  Bonito propagates `model.comm[] = {type, ...}` writes; we
//              dispatch by `msg.type` in `dispatch()` below.
// JS → Julia:  `comm.notify({type: "...", ...})` lands in `chat_dispatch!`
//              on the Julia side. Bonito's `update_nocycle!` keeps Julia
//              writes from echoing back to JS as JS-originated events.
//
// Tool-body lazy renders still go through `Bonito.dom_in_js` (Monaco editors
// inside need a live session) — Julia ships the rendered DOM into the
// `[data-tool-id]` slot directly. Everything else (counts, ranges, message
// pushes, status pings) is on `comm`.

// Android keyboard fix (runs once per page, on module import): Chrome 108+
// defaults to `interactive-widget=resizes-visual` — the on-screen keyboard
// shrinks only the VISUAL viewport, so the 100dvh app layout keeps the
// composer behind the keyboard and the browser pans to the focused caret
// instead (the input ends up floating mid-screen over dead space).
// `resizes-content` makes the LAYOUT viewport track the keyboard, pinning
// the composer right above it. Set dynamically because Bonito owns the
// served <meta name=viewport>; Chromium honours runtime viewport changes.
if (typeof document !== 'undefined') {
    const vp = document.querySelector('meta[name="viewport"]');
    if (vp && !vp.content.includes('interactive-widget'))
        vp.content += ', interactive-widget=resizes-content';
}

// One reusable collapsible-section behaviour, shared by tool rows and thought
// bubbles (and any future lazy section). It owns the expand/collapse plus the
// lazy-body lifecycle that used to be duplicated across wireToolToggle /
// setToolExpanded / wireThoughtToggle:
//   • a header click (or, in `native` mode, a <details> `toggle`) flips expanded
//   • the first expand of a lazy section shows a "loading…" placeholder and
//     fires `onExpand` once; the owner fills the body (via dom_in_js or a comm
//     reply) and `fill()` marks it loaded so a re-expand doesn't refetch
//   • `fetchEachExpand` (most tools) refetches on every expand and
//     `discardOnCollapse` empties the body on collapse (frees the mounted
//     Monaco editors)
//   • `editMode` (edit tools): the body stays mounted ALWAYS — collapse just
//     shrinks Monaco's `max_height` via its own `setMaxHeight` API; expand
//     grows it. No re-fetch, no display:none. The eager body mount itself is
//     triggered from `createNode` so the user sees the compact diff under the
//     header immediately. Implies !fetchEachExpand && !discardOnCollapse.
// A token count the way a reader takes it in: 950, 1.2k, 48k, 1.3M.
// localStorage for what the page only keeps for convenience (drafts, the todo
// card's state). Storage can be off (SecurityError) or full
// (QuotaExceededError): those warn and act as "nothing stored", anything else
// throws. styles.jl's STORAGE_JS is the same for the server-rendered pieces.
const storage = (() => {
    const refused = (error, key) => {
        if (!(error instanceof DOMException) ||
            !['SecurityError', 'QuotaExceededError'].includes(error.name)) throw error;
        console.warn(`browser storage refused (${key}):`, error.message);
    };
    return {
        get(key) { try { return localStorage.getItem(key); } catch (e) { refused(e, key); return null; } },
        set(key, value) { try { localStorage.setItem(key, value); } catch (e) { refused(e, key); } },
        remove(key) { try { localStorage.removeItem(key); } catch (e) { refused(e, key); } },
    };
})();

function formatTokens(n) {
    if (n < 1000) return String(Math.round(n));
    if (n < 10000) return (n / 1000).toFixed(1) + 'k';
    if (n < 1000000) return Math.round(n / 1000) + 'k';
    return (n / 1000000).toFixed(1) + 'M';
}

// Badge text for a queued bubble: position when known, plain "queued" when not
// (an older wire dict, or a bubble restored from history).
function queueLabel(pos) {
    if (!Number.isInteger(pos) || pos < 1) return 'queued';
    if (pos === 1) return 'next up';
    return `queued \u00b7 #${pos}`;
}

export class Collapsable {
    constructor(headerEl, bodyEl, opts = {}) {
        this.header  = headerEl;
        this.body    = bodyEl;
        this.toggle  = opts.toggleEl || null;
        this.native  = opts.native || false;          // hosted in <details>/<summary>
        this.editMode = opts.editMode || false;
        // Eval cards: the body stays MOUNTED across collapse (live embeds /
        // Monaco survive) but collapse hides it via display — the height
        // clamping happens per SUB-SECTION inside the body (see styles.jl
        // .bt-clamped), never on the card body as a whole.
        this.hideBodyOnCollapse = opts.hideBodyOnCollapse || false;
        this.compactHeight  = opts.compactHeight  || 240;
        this.expandedHeight = opts.expandedHeight || 2000;
        this.fetchEachExpand   = this.editMode ? false : (opts.fetchEachExpand || false);
        this.discardOnCollapse = this.editMode ? false : (opts.discardOnCollapse || false);
        this.onExpand = opts.onExpand || null;
        // The height the body last rendered at (px, 0 when unknown); the
        // loading placeholder holds it until the body replaces it.
        this.reserve  = opts.reserve || null;
        this.onToggle = opts.onToggle || null;      // the reader's own clicks
        this.lazy     = !!this.onExpand;
        this.loaded   = !this.lazy;                    // eager bodies start loaded
        // A diff created after the state was set takes the current height.
        if (this.editMode && !this.hideBodyOnCollapse) {
            bodyEl.addEventListener('monaco-diff-editor-ready', (e) => {
                e.target.__btMonacoDiff.setMaxHeight(
                    this.expanded ? this.expandedHeight : this.compactHeight);
            });
        }

        // Everything starts collapsed: edit diffs compact (240px), compact eval
        // bodies capped by the CSS clamp (styles.jl).
        this.expanded = false;

        if (this.native) {
            this.details = headerEl.closest('details') || bodyEl.closest('details');
            this.details && this.details.addEventListener(
                'toggle', () => this.applyExpanded(this.details.open));
        } else {
            headerEl.style.cursor = 'pointer';
            headerEl.addEventListener('click', (e) => {
                // Collapsed → the WHOLE header is the expand target (big,
                // forgiving). Expanded → only the ▼ arrow collapses:
                // the header is dense with small buttons (⊗ ⤢ »), and a
                // near-miss on any of them used to slam the body shut.
                if (this.expanded && this.toggle && e.target !== this.toggle &&
                    !this.toggle.contains(e.target)) return;
                this.applyExpanded(!this.expanded);
                this.onToggle && this.onToggle(this.expanded);
            });
        }
    }

    setExpanded(expanded) {
        if (this.native) { if (this.details) this.details.open = expanded; return; }
        this.applyExpanded(expanded);
    }

    applyExpanded(expanded) {
        if (expanded === this.expanded) return;        // idempotent
        this.expanded = expanded;
        if (!this.native) {
            this.header.dataset.expanded = expanded ? 'true' : 'false';
            if (this.toggle) this.toggle.textContent = expanded ? '▼' : '▶';
            if (this.editMode && !this.hideBodyOnCollapse) {
                // Edit tools: body stays visible; size via Monaco's own API
                // so the resize is animated by Monaco itself instead of CSS
                // clip.
                this.body.style.display = '';
                this.applyEditHeight(expanded ? this.expandedHeight : this.compactHeight);
            } else {
                // Plain lazy bodies AND eval compact bodies hide on collapse;
                // for the latter the node stays mounted (editMode skips the
                // discard below), so re-expanding is instant and live embeds
                // keep their sessions.
                this.body.style.display = expanded ? '' : 'none';
            }
        }
        // Lazy body fetch. editMode pills normally keep their streamed-in
        // body across toggles and only resize Monaco — but a HISTORY-REPLAYED
        // edit pill starts with an EMPTY body (its diff lives server-side
        // until a tool.render round trip), so gating the fetch on
        // `!editMode` alone made replayed Edit pills permanently
        // unexpandable: the arrow flipped, `applyEditHeight` sized zero
        // Monaco divs, and nothing ever appeared. Fetch whenever the body
        // has nothing to show.
        const editBodyEmpty = this.editMode && this.body.childElementCount === 0;
        if (expanded && (!this.editMode || editBodyEmpty)) {
            if (this.lazy && (!this.loaded || this.fetchEachExpand)) {
                // Reserve this mount before notifying. Deferred auto-mount
                // and completion updates can arrive before the body does;
                // a second render would replace an initializing editor.
                this.loaded = true;
                this.showPlaceholder();
                this.onExpand && this.onExpand();
            }
        } else if (!expanded && this.discardOnCollapse) {
            this.body.innerHTML = '';
            this.loaded = false;
        }
    }

    // Look up the Monaco DiffEditor inside our body and resize via its API.
    // Querying every toggle handles both "Monaco wasn't ready on first
    // construction" (the body has the .monaco-diff-editor-div but no
    // __btMonacoDiff yet) and multi-diff bodies (just resize the first; the
    // sibling diffs are sized by the same body wrapper). No-op if the
    // editor finished tearing down or never mounted — and for compact-body
    // EVAL tools, whose plain Code editor has no such API: their ~4-line cap
    // is a pure CSS clamp on the body wrapper keyed off
    // `[data-compact-body] .bt-tool-header[data-expanded] ~ .bt-tool-body`
    // (see styles.jl), so it holds for EVERY mount path (eager mount,
    // terminal re-render, history reload) with no lifecycle hook.
    applyEditHeight(h) {
        const divs = this.body.querySelectorAll('.monaco-diff-editor-div');
        divs.forEach(div => {
            const monaco = div.__btMonacoDiff;
            if (monaco && typeof monaco.setMaxHeight === 'function') monaco.setMaxHeight(h);
        });
    }

    // "loading…" until the body arrives, in the shape the body will have
    // (`reserve`): the row is its final size from the start, and nothing
    // below it moves when the body replaces the placeholder.
    showPlaceholder() {
        showLoading(this.body, this.reserve ? this.reserve() : null);
    }

    // Owner finished loading the lazy body: set its html + mark loaded so a
    // subsequent expand shows it without another round-trip.
    fill(html) {
        if (html != null) this.body.innerHTML = html;
        this.loaded = true;
    }
}

// Message filter: human labels + a fixed display order so toolbar checkboxes
// don't reshuffle based on which type happens to arrive first. Tool calls are
// NOT one type — each tool name gets its own key/checkbox in a trailing
// "Tools:" group (alphabetical), keyed `tool:<name>` from the wire `tool`
// field (the ACP tool name, threaded through by tool_header_dict).
const TYPE_LABELS = { user: 'User', agent: 'Agent', thought: 'Thoughts',
                      plan: 'Todos', summary: 'Summaries' };
const TYPE_ORDER  = ['user', 'agent', 'thought', 'plan', 'summary'];
const filterKey = (msg) =>
    msg.type === 'tool' ? 'tool:' + (msg.tool || 'other') : msg.type;
// Filter keys that start HIDDEN: their checkbox appears unchecked when the
// key first occurs. ToolSearch calls are tool-discovery noise — opt-in.
const DEFAULT_HIDDEN = ['tool:ToolSearch'];
// Rows of subagent activity the DOM holds per Task bubble. Mirrors the server's
// TASK_FEED_WIRE_LIMIT so a remount and a live run show the same window; the
// subagent's full history lives on the server either way.
const TASK_FEED_ROWS = 300;

// "512 KB", "3.4 MB", "1.2 GB": a file's size in the composer and its errors.
function formatBytes(n) {
    if (n < 1024 * 1024) return `${Math.max(1, Math.round(n / 1024))} KB`;
    if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
    return `${(n / 1024 / 1024 / 1024).toFixed(1)} GB`;
}

// A body waiting for its render: "loading…", in `shape` (styles for the
// placeholder) when the body's size is known. The reply empties the slot.
function showLoading(body, shape) {
    body.innerHTML = '<div class="bt-collapsable-loading">loading…</div>';
    if (shape) Object.assign(body.firstElementChild.style, {boxSizing: 'border-box'}, shape);
}

class BonitoChat {
    constructor(container, comm, init = {}) {
        this.container = container;
        this.comm      = comm;
        this.destroyed = false;

        // ── The loaded block ─────────────────────────────────────────────
        // The transcript holds ONE contiguous block of messages: positions
        // [plo, phi] of the current sequence (every store index, or the lens
        // matches under a lens, `seq`), all of them in the DOM in order
        // between the two marker divs. Nothing outside the block is in the
        // page, and nothing is estimated: the scroll container is exactly as
        // tall as what it shows. Scrolling near an end of the block loads the
        // next CHUNK on that side (`ensureWindow`), a block grown past
        // MAX_WINDOW drops rows on the side away from the viewport, and the
        // rail (`setupRail`) shows where the block sits in the conversation.
        this.cache    = new Map();  // idx (0-based) → DOMNode, the block's rows only
        // Tool id → expanded, as the reader last left it. A row the block
        // drops is built again from its data when the reader comes back, and
        // comes back the way they left it.
        this.expandState = new Map();
        this.order    = [];         // the block's store indices, ascending (= DOM order)
        this.nodeById = new Map();  // msg_id → DOMNode  (for streaming updates)
        this.totalCount = 0;
        this.seq      = null;       // lens matches (store indices, ascending); null = all
        this.plo      = 0;          // block = sequence positions [plo, phi]
        this.phi      = -1;
        this.CHUNK      = 40;       // rows per load at an end of the block
        this.MAX_WINDOW = 160;      // rows kept before the far side is dropped
        this.reqSeq   = 0;
        this.pending  = {};         // kind ('older' | 'newer' | 'block') → in-flight request
        // Bumped whenever the block is replaced or the server SPLICED history
        // (msgs.reload: every index shifted). Every msgs.request carries it
        // and the server echoes it on msgs.range, so a reply for a block that
        // is gone is dropped instead of placed among the wrong rows.
        this.epoch        = 0;
        this.STREAM_APPLY_MS = 100; // min interval between streaming innerHTML applies

        // ONE ResizeObserver over the block's rows, for two jobs. A row ABOVE
        // the viewport that changes height (an image or editor reaching its
        // real size, a body mounting) would move everything the reader sees
        // by the difference: the scroll position absorbs it here, before the
        // frame paints. And in follow mode any growth chases the bottom: an
        // image reaching its height after the last message has no chunk
        // coming to chase it. Heights are the fractional BORDER BOX,
        // recorded at adoption (`adoptRows`).
        this.rowObserver = new ResizeObserver((entries) => {
            if (this.destroyed) return;
            // A hidden pane (display:none on a chat switch) reports every row
            // at 0. That is no change of the content: skip it, keeping the
            // heights the rows really have, so showing the pane again (which
            // reports those same heights) reads as no change either.
            // `onShown` restores the reading position.
            const c = this.container;
            if (c.clientHeight === 0) return;
            const st = c.scrollTop;
            const sb = st + c.clientHeight;
            const last = this.cache.get(this.order[this.order.length - 1]);
            // In page order, so each row's place BEFORE this batch is its place
            // now minus what the changed rows above it grew by (`shift`).
            const rows = entries.map(e => [e.target, (e.borderBoxSize && e.borderBoxSize.length)
                    ? e.borderBoxSize[0].blockSize : e.target.offsetHeight])
                .sort(([a], [b]) => (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1);
            let above = 0;
            let shift = 0;
            let grew = false;
            for (const [node, h] of rows) {
                const prev = node.__btH;
                node.__btH = h;
                if (prev === undefined || prev === h) continue;
                grew = true;
                if (node.collapsable && node.classList.contains('bt-tool-msg')) {
                    this.scheduleBodyReport(node);
                    this.onBodyMounted(node);        // an editor built far away
                }
                const top = node.offsetTop - shift;
                shift += h - prev;
                if (node.offsetParent === null) continue;   // no box, no place
                // The reader keeps the first row that STARTS in the viewport
                // where it is, so every row starting above it absorbs its
                // change: one entirely above, and one reaching in from above
                // (the sliver of a video row over the message being read).
                // A row covering the whole viewport, or the last one, is
                // what is read, and keeps its own top instead.
                if (top < st - 1 && (top + prev <= st + 1 || (top + prev < sb && node !== last))) {
                    above += h - prev;
                }
            }
            if (above !== 0 && !this.followMode && !this.railDrag) {
                c.scrollTop = st + above;
                this.prevScrollTop = c.scrollTop;
            }
            if (grew && this.followMode) this.queueScrollToBottom();
            // The thumb follows what is painted. This frame's scroll handler
            // placed it with the new heights laid out but not yet corrected for
            // (a row above the reader), or with the read row's old height, and
            // the next scroll event comes a frame late: placed only then, the
            // thumb jumped back and forth for a frame at every row that changed.
            // Observers run before paint, so placing it here shows it right.
            if (grew) this.updateRail();
        });

        // ── Live-app keep-alive ──────────────────────────────────────────
        // App embeds (msg.kind === 'bonito_app' or a live eval result, marked
        // data-bt-app) host a live Bonito sub-session + WGLMakie WebGL context.
        // While their row is in the block they stay in the page and alive;
        // on-demand rendering means an off-screen app costs ~0. But the
        // browser hard-caps live WebGL contexts (~16, varies) and DESTROYS the
        // oldest beyond that, so at most APP_KEEPALIVE apps outside the
        // viewport stay live: the least-recently-visible one beyond that
        // SPILLS to a snapshot + Reload button (`spillApp`). An optional
        // window.BT_APP_KEEPALIVE override (set before connect) is clamped
        // too: asking for 100 silently gives 10, never the danger zone.
        const wantKeepalive = (typeof window !== 'undefined' && Number.isFinite(window.BT_APP_KEEPALIVE))
            ? window.BT_APP_KEEPALIVE : 6;
        this.APP_KEEPALIVE = Math.min(10, Math.max(0, wantKeepalive));
        this.appLru = [];             // live app idxs, least-recently-visible first
        this.visibleApps = new Set(); // app idxs intersecting the viewport
        this.appObserver = new IntersectionObserver((entries) => {
            if (this.destroyed) return;
            for (const e of entries) {
                const idx = e.target.__btIdx;
                if (idx === undefined) continue;
                if (e.isIntersecting) this.visibleApps.add(idx);
                else this.visibleApps.delete(idx);
                this.touchApp(idx);
            }
            this.enforceAppLru();
        }, { root: container });

        // ── Far bodies ───────────────────────────────────────────────────
        // A tool body is the heavy part of a row: one Monaco diff is some 450
        // elements and its editors' memory, and the block keeps up to
        // MAX_WINDOW rows, so a turn of 60 edits held 60 live diffs (69 MB of
        // heap, 27k elements). A heavy body more than three screens from the
        // view is freed: a placeholder at its exact height takes its place,
        // nothing moves, and Bonito frees its session (the editors with it).
        // Back within a screen and a half, it is rendered again. Two
        // distances, so a row at the edge does not flip back and forth.
        this.freeObserver = new IntersectionObserver((entries) => {
            if (this.destroyed || this.container.clientHeight === 0) return;
            for (const e of entries) if (!e.isIntersecting) this.freeBody(e.target);
        }, { root: container, rootMargin: '300% 0px' });
        // The same distance decides when a body is fetched the FIRST time
        // (`requestBody`): a chat opened on 40 edits built 40 diff editors,
        // one after another, before the last one showed.
        this.mountObserver = new IntersectionObserver((entries) => {
            if (this.destroyed || this.container.clientHeight === 0) return;
            for (const e of entries) {
                if (!e.isIntersecting) continue;
                const n = e.target;
                if (n.dataset.btFreed) {
                    this.unfreeBody(n);
                } else if (n.dataset.btWantsBody) {
                    delete n.dataset.btWantsBody;
                    this.comm.notify({type: 'tool.render', id: n.dataset.msgId});
                }
            }
        }, { root: container, rootMargin: '150% 0px' });
        // A diff editor finished building: its row may be far by now.
        container.addEventListener('monaco-diff-editor-ready', (e) => {
            const row = e.target.closest && e.target.closest('.bt-tool-msg');
            if (row) this.onBodyMounted(row);
        });

        // ── Scroll UX state ────────────────────────────────────────────
        // followMode: when true, new messages auto-scroll the viewport
        // to the bottom. When false, the viewport stays where the user
        // left it and an "↓ New messages" pill appears that jumps them
        // back when clicked. Toggled by:
        //   - user scrolls away from bottom → followMode = false
        //   - user scrolls to the bottom (within AT_BOTTOM_PX) → true
        //   - user sends a message → true
        //   - user clicks the pill → true
        // We do NOT toggle followMode from a layout-induced scroll: if
        // a viewport resize shifts the geometry, we stay in whatever
        // mode the user last chose.
        this.followMode = true;
        this.unreadCount = 0;
        // Cached shown/hidden state of the jump pill. Scroll + resize
        // handlers re-derive pill visibility constantly (every composer
        // autosize fires one), so show/hide only touch the DOM on an
        // actual flip — see showNewMessagePill/hideNewMessagePill.
        this.pillShown = false;
        // "At bottom" is intentionally tight here (20px) — the loose
        // 200px threshold the old code used was a workaround for
        // chunked-text-during-burst race conditions. With explicit
        // followMode there's no race: chase scrolls to scrollHeight
        // unconditionally, so being "at the bottom" means actually
        // there, not "near enough".
        this.AT_BOTTOM_PX = 20;
        // Last processed scroll position — the delta against it gives a user
        // scroll its DIRECTION (re-engage is downward-only, see
        // applyUserScroll). Kept fresh by the scroll handler and by every
        // programmatic scrollTop write that may not fire a scroll event
        // (offscreen renderers): scrollToBottom, the re-pin in updateVisible,
        // onShown's restore, the lens reset, and the pan/momentum writes.
        this.prevScrollTop = container.scrollTop;

        this.rowsEnd = container.querySelector('.bt-rows-end');   // rows go before it
        // ── Filter / lens state ────────────────────────────────────────
        // The per-tool filter toolbar is GONE — the header lens bar
        // (`setupLens`) replaces it. `keyByIdx` drives the type filter; the
        // lens narrows the sequence the block is loaded from to the indices
        // the server matched (`seq`). Native-media toggles live in the lens
        // bar now.
        this.toolbarEl   = (container.closest('.bt-app') || container.parentElement)
            .querySelector('.bt-chat-toolbar');
        if (this.toolbarEl) this.toolbarEl.style.display = 'none';
        this.hiddenTypes = new Set(DEFAULT_HIDDEN);   // kept for DEFAULT_HIDDEN
        this.seenTypes   = new Set();   // keys seen (drives the waiting line)
        this.keyByIdx    = new Map();   // idx → filter key, for the block's rows
        this.filterRow   = null;        // no per-tool checkboxes anymore
        this.nativeImages = true;       // bt_show image results: bare by default
        this.nativeVideos = true;       // bt_show video results: ditto
        // Lens: server returns the VISIBLE 0-based indices for the current
        // query (+ per-index actions). `lensActive=false` shows all.
        this.lensActive  = false;
        this.lensActions = null;        // Map<idx, action>
        this.lensQuery   = '';          // the query this tab currently applies
        this.lensVocab   = [];          // autocomplete keys (from the server)
        this.savedLenses = [];          // global favorites (from the server)
        this.lensClauses = [];          // committed pills: [{sign:'+'|'-', text}]
        this.lensPendingSign = '+';     // sign for the clause being composed
        // Busy dots + thinking indicator are scroll CONTENT: they sit after
        // the rows and before the overscroll tail, so they appear directly
        // under the last message (not below the tail, down by the composer).
        this.busyEl       = container.querySelector('.bt-busy');
        // Idle "waiting for your next instruction" text: pure CSS — visible
        // exactly when .bt-busy is NOT active (adjacent-sibling rule). The
        // JS only holds it for the RO chase below.
        this.waitingEl    = container.querySelector('.bt-waiting');
        // Transient "reasoning…" indicator: shown for the lifetime of an agent
        // thought, then removed. Most thoughts are redacted (empty) so this is
        // usually all the user sees of the model's thinking.
        this.thinkingEl   = container.querySelector('.bt-thinking');
        // Live chunk counter rendered next to the reasoning indicator — ticks
        // per streamed (redacted) thought chunk so a long think visibly moves.
        this.thinkingCountEl = container.querySelector('.bt-thinking-count');
        // A thinking-token estimate is on the reasoning line (`onThinkingTokens`).
        this.thinkingEstimate = false;
        // Overscroll tail: empty space below the last message the user can
        // scroll into (~30% of the pane; sized in the container RO).
        this.tailEl       = container.querySelector('.bt-messages-tail');
        this.sizeTail();

        // Single subscription. `comm` is a Bonito Observable bridged via
        // WS; every message Julia sets via `model.comm[] = {...}` arrives here.
        comm.on((msg) => {
            // Returning `false` deregisters the callback (Observable.notify
            // contract) — a destroyed instance must not stay subscribed.
            if (this.destroyed) return false;
            if (msg && typeof msg === 'object') this.dispatch(msg);
        });

        // Track the last user input on the container. A scroll event
        // within ~400ms of a wheel/touch/keydown is treated as
        // user-initiated; outside that window, it's a layout shift
        // (viewport resize, container RO re-render, attachment-bar
        // pop-in). Only user-initiated scrolls toggle followMode —
        // a layout shift never disengages chase.
        //
        // ALSO synchronously cancels any pending chase rAF. A chunk that
        // landed milliseconds before the gesture queues a chase rAF for
        // the NEXT frame; the scroll event from the wheel/touch fires
        // ASYNCHRONOUSLY (next task), so without an early cancel the
        // chase rAF wins the race and snaps the viewport back to the
        // bottom — the user sees "wheel did nothing" or "jumped back to
        // bottom" while an agent/tool/thinking turn is running. The
        // gesture is the authoritative signal; the chase queued under
        // stale followMode must yield to it.
        // The recency window alone has a hole: a single SLOW main-thread
        // frame (forced layout when a scroll suddenly needs a fresh
        // virtual-scroll range full of Monaco editors can run ~1s) eats
        // the whole 400ms between the user's wheel and the resulting
        // scroll event — the genuine gesture then classifies as a layout
        // shift and the chase yanks the viewport back ("wheel did
        // nothing"). `pendingUserScroll` closes it: the FIRST scroll
        // event after a gesture is user-driven no matter how long the
        // intervening frame took. Consumed on use; wall-clock can't
        // expire it because a blocked main thread can't deliver an
        // unrelated scroll event in between anyway.
        // No input yet. Not 0: `performance.now()` counts from navigation
        // start, so with 0 every scroll in the page's first 400ms looked like
        // the user's, and a fast reload opened the chat off the bottom with
        // follow mode off.
        this.lastUserInputT = -Infinity;
        this.pendingUserScroll = false;
        const markUserInput = () => {
            this.lastUserInputT = performance.now();
            this.pendingUserScroll = true;
            this.cancelPendingScroll();
        };
        // Capture: BonitoBook stops wheels over editors on the way down.
        container.addEventListener('wheel',      markUserInput, { passive: true, capture: true });
        container.addEventListener('touchstart', markUserInput, { passive: true });
        container.addEventListener('touchmove',  markUserInput, { passive: true });
        container.addEventListener('keydown',    markUserInput, { passive: true });
        this.markUserInput = markUserInput;

        // A picture or a clip reports its natural size once its bytes are in.
        // The server sends it back as the element's width/height with later
        // renders (measured_sizes.jl), so the element has its size before the
        // bytes arrive. Capture: neither event bubbles.
        this.onMediaSized = (e) => {
            const el = e.target;
            if (!(el instanceof HTMLElement) || !el.classList.contains('bt-media')) return;
            const path = el.closest('.bt-media-wrap')?.dataset.workerPath;
            const video = el.tagName === 'VIDEO';
            const w = video ? el.videoWidth : el.naturalWidth;
            const h = video ? el.videoHeight : el.naturalHeight;
            if (!path || !w || !h) return;
            if (+el.getAttribute('width') === w && +el.getAttribute('height') === h) return;
            // Unknown, or the file changed since: right now, and next time.
            el.setAttribute('width', w);
            el.setAttribute('height', h);
            this.comm.notify({type: 'media.size', path, w, h});
        };
        container.addEventListener('load', this.onMediaSized, true);
        container.addEventListener('loadedmetadata', this.onMediaSized, true);

        // File-path links: ONE delegated listener for every `.bt-path-link`
        // in the chat (tool titles, diff headers, search hits, linkified
        // paths in agent messages) → open the file in the plotpane editor.
        // Capture phase, so a click on a linked TOOL TITLE opens the editor
        // instead of toggling the pill's expand state (the Collapsable
        // listener sits on the header, below us on the capture path).
        // ↑ chips on a card that waits on an eval (bt_julia_continue /
        // bt_julia_wait): bring that eval's card into view. Capture phase for
        // the same reason as path links: the chip sits in a header whose
        // click toggles the card.
        container.addEventListener('click', (e) => {
            const chip = e.target.closest('.bt-tool-jump');
            if (!chip || !container.contains(chip)) return;
            e.preventDefault();
            e.stopPropagation();
            this.jumpToMessage(parseInt(chip.dataset.jumpIndex ?? '-1', 10), chip.dataset.jumpId);
        }, { capture: true });
        container.addEventListener('click', (e) => {
            const link = e.target.closest('.bt-path-link');
            if (!link || !container.contains(link)) return;
            const path = link.dataset.path || link.textContent.trim();
            if (!path) return;
            e.preventDefault();
            e.stopPropagation();
            this.comm.notify({ type: 'edit_file', path });
        }, { capture: true });

        container.addEventListener('click', e => {
            const img = e.target.closest('.bt-agent-msg img, .bt-tool-md img');
            if (!img || img.closest('a, .bt-media-wrap')) return;
            e.stopPropagation();
            openLightbox(img);
        });

        // A rail drag (`setupRail`) owns the position outright: chases and
        // anchor corrections stand down while it is held. The native
        // scrollbar is hidden, so nothing else can be a scrollbar drag.
        this.scrollbarDrag = false;
        this.railDrag = null;
        // Window-level listener: a pane whose subtree was unmounted above the
        // direct parent (the MutationObserver in `connect` can't see that)
        // self-destroys lazily here.
        this.onWindowMouseUp = () => {
            if (!this.container.isConnected) this.lazyDestroy();
        };
        window.addEventListener('mouseup', this.onWindowMouseUp, { passive: true });

        // ── Grab-to-pan with fling momentum + rubberband ──────────────
        // Click and drag anywhere in the messages area pans the viewport
        // like a camera: pointer delta → scrollTop delta. Release with
        // motion → momentum (rAF deceleration). Overscroll past either
        // edge accumulates rubberband distance (CSS var translates the
        // content) with resistance and springs back on release.
        //
        // Disambiguation from text selection + clicks: pan engages ONLY
        // after the pointer has moved ≥ PAN_THRESHOLD px AND no text was
        // selected during the gesture. So a static click still selects
        // text / triggers buttons, and a short text-select-drag still
        // selects text without hijacking. Touch input is left to native
        // scrolling (mobile / trackpad already have momentum + bounce).
        const PAN_THRESHOLD       = 6;    // px; preserves click + small selects
        const PAN_RESIST          = 0.55; // 0..1; lower = more rubberband resistance
        const PAN_BOUNCE_RESIST   = 0.40; // fling-bounce: stronger than drag-bounce
        const PAN_FRICTION        = 0.94; // momentum velocity decay / frame
        const PAN_MIN_VELOCITY    = 0.03; // px/ms; below this momentum stops
        const PAN_SPRING_DAMPING  = 0.72; // overscroll spring-back decay / frame
        const PAN_FLING_THRESHOLD = 0.10; // px/ms; below this no fling on release

        this.overscroll  = 0;
        this.panState    = null;
        this.momentumRaf = null;
        this.springRaf   = null;

        const setOverscroll = (v) => {
            this.overscroll = v;
            this.container.style.setProperty('--bt-overscroll', v + 'px');
            // The rubberband translateY is applied to EVERY rendered child;
            // a non-`none` transform on each child turns one composited scroll
            // layer into N stacking contexts, hurting steady-state scroll
            // smoothness. Gate it behind a class so the transform exists ONLY
            // during an active overscroll gesture (the only time it's needed),
            // and normal scrolling composites natively.
            this.container.classList.toggle('bt-overscrolling', v !== 0);
        };
        this.setOverscroll = setOverscroll;   // so onHidden can clear it

        this.cancelMomentum = () => {
            if (this.momentumRaf !== null) {
                cancelAnimationFrame(this.momentumRaf);
                this.momentumRaf = null;
            }
            if (this.springRaf !== null) {
                cancelAnimationFrame(this.springRaf);
                this.springRaf = null;
            }
        };

        const springStep = () => {
            this.springRaf = null;
            if (this.destroyed) return;
            if (Math.abs(this.overscroll) < 0.5) { setOverscroll(0); return; }
            setOverscroll(this.overscroll * PAN_SPRING_DAMPING);
            this.springRaf = requestAnimationFrame(springStep);
        };

        const startSpring = () => {
            if (this.springRaf !== null || this.overscroll === 0) return;
            this.springRaf = requestAnimationFrame(springStep);
        };

        const momentumStep = (vel) => {
            this.momentumRaf = null;
            if (this.destroyed) return;
            // vel is px/ms in the direction of pointer travel.
            // dy > 0 means pointer moved down ⇒ content goes down ⇒
            // scrollTop decreases. Same sign convention as the drag.
            const dt = 16;
            const delta = vel * dt;
            const maxScroll = this.container.scrollHeight - this.container.clientHeight;
            const prevTop = this.container.scrollTop;
            let newTop = prevTop - delta;
            let hitEdge = false;
            if (newTop < 0) {
                setOverscroll(this.overscroll + (-newTop) * PAN_BOUNCE_RESIST);
                this.container.scrollTop = 0;
                hitEdge = true;
            } else if (newTop > maxScroll) {
                setOverscroll(this.overscroll - (newTop - maxScroll) * PAN_BOUNCE_RESIST);
                this.container.scrollTop = maxScroll;
                hitEdge = true;
            } else {
                this.container.scrollTop = newTop;
            }
            // The fling is the user's own gesture: classify the follow-mode
            // transition at the write — offscreen renderers fire no scroll
            // event for programmatic scrollTop writes, and when the event
            // DOES fire it sees a zero delta against the synced
            // prevScrollTop and skips (never classified twice).
            if (this.container.scrollTop !== prevTop) this.applyUserScroll(prevTop);
            this.prevScrollTop = this.container.scrollTop;
            // Keep the user-input timestamp fresh so the scroll handler
            // continues classifying these programmatic scrollTop writes
            // as user-driven (= the fling the user threw). Without this
            // the 400 ms recency window lapses mid-fling and a stray
            // layout shift re-engages chase, snapping to bottom in the
            // middle of the user's read.
            this.lastUserInputT = performance.now();
            // Edge-hit: absorb the remaining velocity into the bounce
            // and let the spring carry the rest. Otherwise decay.
            vel = hitEdge ? 0 : vel * PAN_FRICTION;
            if (Math.abs(vel) < PAN_MIN_VELOCITY) { startSpring(); return; }
            this.momentumRaf = requestAnimationFrame(() => momentumStep(vel));
        };

        const onPanDown = (e) => {
            if (e.pointerType === 'touch') return;
            if (e.button !== 0) return;
            if (this.scrollbarDrag) return;
            // Don't engage on form controls / buttons / links — let their
            // native semantics own the gesture. Closest is cheap.
            if (e.target.closest('input, textarea, button, a, select, [contenteditable]')) return;
            this.cancelMomentum();
            this.panState = {
                pointerId: e.pointerId,
                startY:    e.clientY,
                lastY:     e.clientY,
                lastT:     performance.now(),
                velocity:  0,
                engaged:   false,
            };
        };

        const onPanMove = (e) => {
            const p = this.panState;
            if (!p || e.pointerId !== p.pointerId) return;
            if (!p.engaged) {
                if (Math.abs(e.clientY - p.startY) < PAN_THRESHOLD) return;
                // The user started a text selection during the threshold
                // window: yield. Pan only fires when the gesture was
                // intended as a pan.
                const sel = window.getSelection();
                if (sel && sel.toString().length > 0) { this.panState = null; return; }
                p.engaged = true;
                p.lastY = e.clientY;
                p.lastT = performance.now();
                // A pointer that is not live (a scripted event) can't be captured.
                try { this.container.setPointerCapture(e.pointerId); }
                catch (error) { if (error.name !== 'NotFoundError') throw error; }
                this.container.classList.add('bt-messages-grabbing');
                // Pan acts like a wheel: cancels pending chase + marks
                // user input so the scroll handler treats subsequent
                // scrollTop writes as user-driven.
                this.lastUserInputT = performance.now();
                this.cancelPendingScroll();
            }
            e.preventDefault();
            const now = performance.now();
            const stepDy = e.clientY - p.lastY;
            const stepDt = now - p.lastT;
            const maxScroll = this.container.scrollHeight - this.container.clientHeight;
            const prevTop = this.container.scrollTop;
            const newTop = prevTop - stepDy;
            if (newTop < 0) {
                setOverscroll(this.overscroll + (-newTop) * PAN_RESIST);
                this.container.scrollTop = 0;
            } else if (newTop > maxScroll) {
                setOverscroll(this.overscroll - (newTop - maxScroll) * PAN_RESIST);
                this.container.scrollTop = maxScroll;
            } else {
                if (this.overscroll !== 0) setOverscroll(0);
                this.container.scrollTop = newTop;
            }
            // A drag step is the user's own gesture — classify it at the
            // write, exactly like the momentum step above (offscreen: no
            // scroll event; onscreen: the trailing event is a zero-delta
            // no-op). A downward re-engage never yanks mid-drag: the chase
            // rAF re-arms while the input timestamp stays fresh.
            if (this.container.scrollTop !== prevTop) this.applyUserScroll(prevTop);
            this.prevScrollTop = this.container.scrollTop;
            if (stepDt > 0) {
                // Exponentially-smoothed velocity (px/ms): noise-resistant
                // and recency-biased so the release-instant velocity
                // approximates the last ~30 ms of motion.
                const instant = stepDy / stepDt;
                p.velocity = 0.65 * instant + 0.35 * p.velocity;
            }
            p.lastY = e.clientY;
            p.lastT = now;
            this.lastUserInputT = now;
        };

        const onPanUp = (e) => {
            const p = this.panState;
            if (!p || e.pointerId !== p.pointerId) return;
            const engaged = p.engaged;
            const vel     = p.velocity;
            this.panState = null;
            if (!engaged) return;
            if (this.container.hasPointerCapture(e.pointerId)) this.container.releasePointerCapture(e.pointerId);
            this.container.classList.remove('bt-messages-grabbing');
            if (Math.abs(vel) > PAN_FLING_THRESHOLD) {
                this.momentumRaf = requestAnimationFrame(() => momentumStep(vel));
            } else if (this.overscroll !== 0) {
                startSpring();
            }
        };

        container.addEventListener('pointerdown',   onPanDown);
        container.addEventListener('pointermove',   onPanMove);
        container.addEventListener('pointerup',     onPanUp);
        container.addEventListener('pointercancel', onPanUp);
        this.onPanDown = onPanDown;
        this.onPanMove = onPanMove;
        this.onPanUp   = onPanUp;

        this.onScroll = () => {
            // A scroll event on a zero-height container carries no user intent:
            // hiding the pane (display:none on a chat switch) collapses
            // scrollTop to 0 and fires this handler. `atBottom()` is then
            // trivially true (0 - 0 - 0 < AT_BOTTOM_PX), so a switch made
            // within 400ms of a real scroll (still "userDriven") would flip
            // followMode back to true and chase the pane to the bottom on the
            // next onShown — the user's read position lost. Ignore it: the pane
            // has no viewport, so there is nothing to classify.
            if (this.container.clientHeight === 0) return;
            // Last position seen with a real layout box. `restoreAfterMove`
            // puts this back when the workspace re-inserts our panel and the
            // browser silently drops scrollTop to 0.
            this.lastGoodTop = this.container.scrollTop;
            const userDriven = this.scrollbarDrag ||
                this.pendingUserScroll ||
                (performance.now() - this.lastUserInputT) < 400;
            this.pendingUserScroll = false;
            const atBot      = this.atBottom();
            // Direction comes from the delta since the last processed
            // position. A zero-delta event carries no movement — nothing to
            // classify. That also makes the async scroll event trailing a
            // pan/momentum scrollTop write (already classified at the write,
            // which synced prevScrollTop) a no-op instead of a double count.
            const prevTop = this.prevScrollTop;
            this.prevScrollTop = this.container.scrollTop;
            if (userDriven) {
                // User-driven movement → the follow-mode transition lives in
                // applyUserScroll (razor-thin disengage; generous,
                // downward-only re-engage at the pill's boundary).
                if (this.container.scrollTop !== prevTop) {
                    this.applyUserScroll(prevTop);
                }
            } else if (this.followMode && !atBot) {
                // Layout shift moved us off the bottom while in
                // follow mode (viewport resize / attachment-bar
                // pop-in). Re-anchor.
                this.queueScrollToBottom();
            }
            // The jump-to-bottom pill tracks the read position directly: shown
            // once the last message is completely out of view (plain), glowing
            // only when unread. atBot still owns the unread-clear.
            this.updateScrollAffordance(atBot);
            this.ensureWindow();
        };
        container.addEventListener('scroll', this.onScroll, { passive: true });

        // Re-scroll whenever the messages container changes size
        // while in follow mode. Covers: mobile soft-keyboard
        // slide-in/out, browser address bar collapse, window resize,
        // attachment bar growing. Without this, the last message +
        // input area slide below the fold and the user has no way
        // back without manual scroll.
        // ALSO observes the busy/thinking indicators: they live inside
        // the scroll content, so their 150ms height transition changes
        // scrollHeight — not the container's box — and the container
        // observation alone would miss it. Observing them keeps the
        // chase pinned to the bottom across every frame of the grow.
        this.viewportObserver = new ResizeObserver(() => {
            if (this.destroyed) return;
            // A zero-height (hidden) container has nothing to chase — and the
            // re-show / restore is owned by onShown(), so don't fight it here.
            if (this.container.clientHeight === 0) return;
            this.sizeTail();
            if (this.followMode) this.queueScrollToBottom();
        });
        this.viewportObserver.observe(this.container);
        this.setupMoveObserver();
        if (this.busyEl)     this.viewportObserver.observe(this.busyEl);
        if (this.waitingEl)  this.viewportObserver.observe(this.waitingEl);
        if (this.thinkingEl) this.viewportObserver.observe(this.thinkingEl);

        if (window.visualViewport) {
            // Last height we WROTE onto .bt-app, so a resize event that reports
            // the same geometry costs nothing (see onViewportResize).
            this.lastViewportHeight = null;
            this.onVisualViewportResize = () => this.onViewportResize();
            window.visualViewport.addEventListener('resize', this.onVisualViewportResize);
        }

        // Image attachments (paste / drag-drop). Wired AFTER the input area
        // is in the DOM, on a microtask so .bt-app's children are queryable.
        Promise.resolve().then(() => {
            this.setupInputs();
            this.setupLiveTicker();
            this.setupLens();
        });
        this.setupRail();

        // The pane arrives with the newest messages (`transcript_tail` on the
        // server): they show now, with no round trip. `init` still asks for
        // the count, which may have moved on since the pane was rendered, and
        // for the lens and queue state. Without a tail (a server that sends
        // none) the count's reply loads it.
        const tail = init.tail;
        if (tail && Number.isInteger(tail.n)) this.applyTail(tail);
        comm.notify({type: 'init'});
    }

    destroy() {
        this.destroyed = true;
        if (this.elapsedTimer) {
            clearInterval(this.elapsedTimer);
            this.elapsedTimer = null;
        }
        if (this.onScroll) {
            this.container.removeEventListener('scroll', this.onScroll);
        }
        if (this.markUserInput) {
            this.container.removeEventListener('wheel',    this.markUserInput, { capture: true });
            this.container.removeEventListener('touchstart', this.markUserInput);
            this.container.removeEventListener('touchmove',  this.markUserInput);
            this.container.removeEventListener('keydown',  this.markUserInput);
        }
        if (this.onMediaSized) {
            this.container.removeEventListener('load', this.onMediaSized, true);
            this.container.removeEventListener('loadedmetadata', this.onMediaSized, true);
        }
        if (this.onWindowMouseUp) {
            window.removeEventListener('mouseup', this.onWindowMouseUp);
        }
        if (this.onPanDown) {
            this.container.removeEventListener('pointerdown',   this.onPanDown);
            this.container.removeEventListener('pointermove',   this.onPanMove);
            this.container.removeEventListener('pointerup',     this.onPanUp);
            this.container.removeEventListener('pointercancel', this.onPanUp);
        }
        if (this.cancelMomentum) this.cancelMomentum();
        if (this.scrollRafId !== null && this.scrollRafId !== undefined) {
            cancelAnimationFrame(this.scrollRafId);
        }
        if (this.onVisualViewportResize && window.visualViewport) {
            window.visualViewport.removeEventListener('resize', this.onVisualViewportResize);
        }
        if (this.viewportObserver) {
            this.viewportObserver.disconnect();
        }
        if (this.rowObserver) this.rowObserver.disconnect();
        if (this.appObserver) this.appObserver.disconnect();
        if (this.freeObserver) this.freeObserver.disconnect();
        if (this.mountObserver) this.mountObserver.disconnect();
        if (this.moveObserver) this.moveObserver.disconnect();
        this.teardownRail();
        if (this.onPaste && this.textInput) {
            this.textInput.removeEventListener('paste', this.onPaste);
        }
        if (this.onTextInputKeyCapture && this.textInput) {
            this.textInput.removeEventListener('keydown', this.onTextInputKeyCapture, true);
        }
        if (this.textInput) {
            this.onCmdInput && this.textInput.removeEventListener('input', this.onCmdInput);
            this.onCmdBlur  && this.textInput.removeEventListener('blur',  this.onCmdBlur);
        }
        if (this.cmdAc) { this.cmdAc.remove(); this.cmdAc = null; }
        if (this.onAppClickCapture && this.app) {
            this.app.removeEventListener('click', this.onAppClickCapture, true);
        }
        if (this.onDraftInput && this.textInput) {
            this.flushDraft();
            this.textInput.removeEventListener('input', this.onDraftInput);
            this.textInput.removeEventListener('blur', this.flushDraft);
            window.removeEventListener('pagehide', this.flushDraft);
            document.removeEventListener('visibilitychange', this.onDraftVisibility);
        }
        if (this.textInput) {
            this.textInput.removeEventListener('compositionstart', this.onCompositionStart);
            this.textInput.removeEventListener('compositionend', this.onCompositionEnd);
            if (this.onInputResize) {
                this.textInput.removeEventListener('input', this.onInputResize);
                this.textInput.removeEventListener('bt-composer-resize', this.onInputResize);
            }
        }
        if (this.inputResizeFrame) cancelAnimationFrame(this.inputResizeFrame);
        this.inputWidthObserver?.disconnect();
        this.inputMeasure?.remove();
        if (this.onAppChange && this.app) {
            this.app.removeEventListener('change', this.onAppChange);
        }
        if (this.onEscapeKey) {
            document.removeEventListener('keydown', this.onEscapeKey, true);
        }
        if (this.app) {
            this.onDragOver  && this.app.removeEventListener('dragover',  this.onDragOver);
            this.onDragLeave && this.app.removeEventListener('dragleave', this.onDragLeave);
            this.onDrop      && this.app.removeEventListener('drop',      this.onDrop);
        }
        clearTimeout(this.attachErrorTimer);
        if (this.tickerId) {
            clearInterval(this.tickerId);
            this.tickerId = null;
        }
        if (this.taskbarEl && this.onTaskbarClick) {
            this.taskbarEl.removeEventListener('click', this.onTaskbarClick);
        }
        if (this.onLensDocClick) {
            document.removeEventListener('click', this.onLensDocClick);
        }
    }

    // Backstop teardown for an instance whose container left the document
    // without the `connect` MutationObserver seeing it (that observer only
    // watches the DIRECT parent's childList; an ancestor-level unmount slips
    // past). Document/window-level handlers call this when they notice
    // `container.isConnected === false`, so leaked instances clean up on the
    // next global event instead of reacting forever.
    lazyDestroy() {
        if (this.destroyed) return;
        try { this.destroy(); } finally { CHAT_INSTANCES.delete(this); }
    }

    // Single dispatch table. Julia sends `{type, ...}`; we route here.
    dispatch(msg) {
        // Track incrementally-arriving counts: every message-creation event
        // includes `n`, the new total. We avoid a separate `msgs.count`
        // broadcast for the steady-state stream.
        if (typeof msg.n === 'number' && msg.n > this.totalCount) {
            this.totalCount = msg.n;
        }
        // The model's output, or the turn's end, ends a thinking estimate
        // (`onThinkingTokens`).
        if (this.thinkingEstimate && ['chunk', 'agent', 'thought', 'tool', 'tool_update',
                'plan', 'summary', 'agent_final', 'thinking', 'busy_end', 'session_reset']
                .includes(msg.type))
            this.endThinkingEstimate();

        switch (msg.type) {
            case 'queue.state': return this.renderQueue(msg);
            case 'queue.delivered': return this.queueDelivered(msg);
            case 'msgs.count':   return this.applyCount(msg.n);
            case 'msgs.reload':  return this.onMsgsReload(msg.n);
            case 'turn_begin':   this.turnSeq = msg.seq; return;
            case 'commands':     this.slashCommands = msg.items || []; return;
            case 'lens.vocab':   this.lensVocab = msg.keys || []; return;
            case 'lens.saved':   return this.onLensSaved(msg);
            case 'lens.result':  return this.onLensResult(msg);
            case 'msgs.range':   return this.onRange(msg);
            case 'session_reset':return this.onSessionReset();
            case 'busy_start':
                this.busyEl?.classList.add('bt-busy-active');
                // bt-busy grows from 0 to 28px over 150ms; its own RO
                // (it's observed alongside the container) re-scrolls on
                // each frame, but only if followMode is on — which it
                // should be when a turn starts.
                if (this.followMode) this.queueScrollToBottom();
                return;
            case 'busy_end':
                this.busyEl?.classList.remove('bt-busy-active');
                if (this.followMode) this.queueScrollToBottom();
                return;
            case 'agent_final':  return this.onAgentFinal(msg);
            case 'thinking':     return this.onThinking(msg);
            case 'thinking_tokens': return this.onThinkingTokens(msg.tokens);
            case 'permission':      return this.onPermission(msg);
            case 'permission_done': return this.onPermissionDone(msg);
            case 'question':        return this.onQuestion(msg);
            case 'question_done':   return this.onPermissionDone(msg);
            case 'thought_final':return this.onThoughtFinal(msg);
            case 'thought.body': return this.onThoughtBody(msg);
            case 'tool_update':  return this.onToolUpdate(msg);
            case 'task_activity':return this.onTaskActivity(msg);
            case 'plan_update':  return this.onPlanUpdate(msg);
            case 'chunk':        return this.appendChunk(msg);
            case 'user_chunk':   return this.appendUserChunk(msg.text);
            case 'user_unqueue': return this.unqueueUser(msg);
            case 'user_requeue': return this.requeueUser(msg);
            case 'summary_final':return this.onSummaryFinal(msg);
            case 'attach_error':
                return this.showAttachError(msg.error || 'Attachment failed');
            // (formerly `send_ack` — JS now clears the input widget
            // unconditionally on submit, so no server ack is needed.)
            case 'user':
            case 'agent':
            case 'thought':
            case 'tool':
            case 'plan':
            case 'summary':
                return this.appendNewMessage(msg);
        }
    }

    // ── The loaded block ──────────────────────────────────────────────────
    // (The model is described in the constructor.)

    // Positions run over every store index, or over the lens matches while a
    // lens is on (`seq`).
    seqLength() { return this.seq ? this.seq.length : this.totalCount; }
    seqIndex(p) { return this.seq ? this.seq[p] : p; }
    // Position of store index `idx` in the sequence, or -1.
    seqPos(idx) {
        if (!this.seq) return (idx >= 0 && idx < this.totalCount) ? idx : -1;
        let lo = 0, hi = this.seq.length - 1;
        while (lo <= hi) {
            const mid = (lo + hi) >> 1;
            const v = this.seq[mid];
            if (v === idx) return mid;
            if (v < idx) lo = mid + 1; else hi = mid - 1;
        }
        return -1;
    }
    blockEmpty() { return this.phi < this.plo; }
    // Does the block end at the last message of the sequence?
    atTail() { return this.phi === this.seqLength() - 1; }

    // The tail the pane was rendered with ({n, start, msgs}, see the
    // server's `transcript_tail`).
    applyTail(tail) {
        this.totalCount = Math.max(this.totalCount, tail.n);
        if (tail.n === 0) { this.markReady(); this.updateRail(); return; }
        const items = (tail.msgs || []).map((m, i) => [tail.start + i, m]);
        this.replaceBlock(items, { kind: 'tail' });
    }

    // The count, as `init` and the server's resyncs report it. Growth means
    // more at the end: fetched when the block reaches the end. A count that
    // SHRANK means the indices moved: start over.
    applyCount(n) {
        if (n < this.totalCount) { this.onMsgsReload(n); return; }
        this.totalCount = n;
        if (n === 0) { this.markReady(); this.updateRail(); return; }
        if (this.blockEmpty()) {
            if (!this.pending.block) this.loadTail();
            return;
        }
        this.ensureWindow();
    }

    // Full re-sync: the server SPLICED or rebuilt the history (a resumed
    // session's reconcile inserted messages mid-store), so every index the
    // block holds is invalid. Start over from the tail, pinned to the bottom:
    // the newest messages are what a sync is for. A lens's matches are
    // indices too, so its query runs again.
    onMsgsReload(n) {
        this.totalCount = n;
        this.seq = null;
        if (this.lensActive) this.runLens(this.lensQuery);
        this.clearBlock();
        this.setFollowMode(true);
        this.unreadCount = 0;
        this.loadTail();
    }

    loadTail() {
        const len = this.seqLength();
        if (len === 0) {
            this.clearBlock();
            this.markReady();
            this.updateRail();
            return;
        }
        this.requestBlock(Math.max(0, len - this.CHUNK), len - 1, { kind: 'tail' });
    }

    // Ask for a whole new block, positions [pa, pb]. `opts.kind` says where
    // the view goes when it lands: 'tail' the bottom; 'jump' position
    // `opts.target` near the top; 'lens' the top; 'restore' store index
    // `opts.idx` back at viewport offset `opts.off`.
    requestBlock(pa, pb, opts) {
        this.epoch++;            // replies for the old block are dead
        this.pending = {};
        this.request('block', pa, pb, opts);
    }

    request(slot, pa, pb, opts = {}) {
        if (pa > pb) return;
        const id = ++this.reqSeq;
        this.pending[slot] = { ...opts, id, slot, pa, pb };
        const msg = { type: 'msgs.request', epoch: this.epoch, req: id };
        if (this.seq) msg.indices = this.seq.slice(pa, pb + 1);
        else msg.range = [pa, pb];
        this.comm.notify(msg);
    }

    onRange(msg) {
        if (msg.epoch !== undefined && msg.epoch !== null && msg.epoch !== this.epoch) return;
        const req = Object.values(this.pending).find(r => r.id === msg.req);
        if (!req) return;                     // superseded
        delete this.pending[req.slot];
        const msgs = msg.msgs ?? [];
        const items = Array.isArray(msg.indices)
            ? msg.indices.map((idx, i) => [idx, msgs[i]])
            : msgs.map((m, i) => [msg.start + i, m]);
        if (req.slot === 'older') this.prependItems(items);
        else if (req.slot === 'newer') this.appendItems(items);
        else this.replaceBlock(items, req);
        this.ensureWindow();
    }

    // A row for store index `idx` from its wire dict. Not yet in the page.
    makeRow(idx, data) {
        const node = this.createNode(data);
        node.__btIdx = idx;
        node.__btId = data.id;
        this.cache.set(idx, node);
        this.keyByIdx.set(idx, filterKey(data));
        if (data.id) this.nodeById.set(data.id, node);
        this.applyVisibility(idx, node);
        // A lens can ask for its matches expanded: done once the row is in
        // the page, so the body has a slot to mount into (`mountDeferred`).
        if (this.lensActions?.get(idx) === 'expand') node.dataset.btAutoExpand = '1';
        return node;
    }

    // New rows are in the page: mount what waited for a document, then
    // record the height each row has now and watch it. Recording here, not
    // on the observer's first report, matters: a body arriving before the
    // next frame (a bt_show video expanding) would otherwise be that first
    // report, recorded as the start and never compensated. A row without a
    // box (hidden pane, filtered type) records on its first report instead.
    adoptRows(nodes) {
        for (const node of nodes) {
            this.mountDeferred(node);
            if (this.lensActions?.get(node.__btIdx) === 'collapse') {
                node.collapsable?.setExpanded(false);
            }
        }
        for (const node of nodes) {
            if (node.offsetParent !== null) node.__btH = node.getBoundingClientRect().height;
            this.rowObserver.observe(node);
            if (node.classList.contains('bt-tool-msg')) {
                this.freeObserver.observe(node);
                this.mountObserver.observe(node);
            }
            if (node.dataset.btApp) {
                this.appObserver.observe(node);
                this.touchApp(node.__btIdx);
            }
        }
    }

    removeRow(idx) {
        const node = this.cache.get(idx);
        if (!node) return;
        this.rowObserver.unobserve(node);
        this.freeObserver.unobserve(node);
        this.mountObserver.unobserve(node);
        clearTimeout(node.__btBodyTimer);
        if (node.dataset.btApp) {
            this.appObserver.unobserve(node);
            this.visibleApps.delete(idx);
            const li = this.appLru.indexOf(idx);
            if (li !== -1) this.appLru.splice(li, 1);
        }
        if (node.__btId && this.nodeById.get(node.__btId) === node) this.nodeById.delete(node.__btId);
        this.cache.delete(idx);
        this.keyByIdx.delete(idx);
        this.clearPendingStream(node);
        node.remove();
    }

    clearBlock() {
        for (const idx of this.order) this.removeRow(idx);
        this.order = [];
        this.plo = 0;
        this.phi = -1;
    }

    // Insert `items` ([[idx, dict], ...], ascending) as rows before `before`.
    insertRows(items, before) {
        const frag = document.createDocumentFragment();
        const nodes = [];
        for (const [idx, data] of items) {
            const node = this.makeRow(idx, data);
            frag.appendChild(node);
            nodes.push(node);
        }
        this.container.insertBefore(frag, before);
        return nodes;
    }

    replaceBlock(items, req) {
        this.clearBlock();
        const rows = items.filter(([, d]) => d != null);
        const nodes = this.insertRows(rows, this.rowsEnd);
        this.order = rows.map(([idx]) => idx);
        if (this.order.length) {
            this.plo = this.seqPos(this.order[0]);
            this.phi = this.seqPos(this.order[this.order.length - 1]);
        }
        this.adoptRows(nodes);
        this.placeView(req);
        this.markReady();
    }

    // Older rows, above the block. Everything new is above the reader, so
    // the scroll position grows by exactly what was inserted.
    prependItems(items) {
        const rows = items.filter(([idx, d]) => d != null && !this.cache.has(idx));
        if (rows.length === 0) return;
        if (this.seqPos(rows[rows.length - 1][0]) !== this.plo - 1) return;   // block moved on
        const c = this.container;
        const before = c.scrollHeight;
        const top = c.scrollTop;
        const first = this.cache.get(this.order[0]) || this.rowsEnd;
        const nodes = this.insertRows(rows, first);
        this.order = rows.map(([idx]) => idx).concat(this.order);
        this.plo = this.seqPos(rows[0][0]);
        // Adopted first: what mounting expands is part of what was inserted.
        this.adoptRows(nodes);
        const grown = c.scrollHeight - before;
        if (grown !== 0 && !this.railDrag) {
            c.scrollTop = top + grown;
            this.prevScrollTop = c.scrollTop;
        }
    }

    // Newer rows, below the block. Rows that streamed in meanwhile are
    // already there and skipped.
    appendItems(items) {
        const rows = items.filter(([idx, d]) => d != null && !this.cache.has(idx));
        if (rows.length === 0) return;
        if (this.seqPos(rows[0][0]) !== this.phi + 1) return;   // block moved on
        const nodes = this.insertRows(rows, this.rowsEnd);
        this.order = this.order.concat(rows.map(([idx]) => idx));
        this.phi = this.seqPos(rows[rows.length - 1][0]);
        this.adoptRows(nodes);
        if (this.followMode) this.queueScrollToBottom();
    }

    // Where the view goes once a new block is in (see `requestBlock`).
    placeView(req) {
        const c = this.container;
        const kind = req.kind || 'tail';
        if (kind === 'tail') {
            this.setFollowMode(true);
            c.scrollTop = c.scrollHeight;
        } else if (kind === 'lens') {
            this.setFollowMode(false);
            c.scrollTop = 0;
        } else if (kind === 'restore') {
            this.setFollowMode(false);
            this.restoreAnchor({ idx: req.idx, off: req.off });
        } else if (kind === 'jump') {
            this.setFollowMode(false);
            const node = this.cache.get(this.seqIndex(req.target));
            if (node && node.offsetParent !== null) {
                c.scrollTop = Math.max(0, node.offsetTop - (req.offset ?? 8));
            }
            if (req.flashId) this.flash(req.flashId);
        }
        this.prevScrollTop = c.scrollTop;
        this.updateScrollAffordance(this.atBottom());
    }

    // Load more at whichever end of the block the viewport is near, and
    // keep the block bounded. Runs on every scroll and after every insert,
    // so it stops by itself once the viewport is a margin away from both ends.
    ensureWindow() {
        if (this.destroyed) return;
        const c = this.container;
        if (this.railDrag || c.clientHeight === 0) { this.updateRail(); return; }
        const len = this.seqLength();
        if (this.pending.block || len === 0) { this.updateRail(); return; }
        if (this.blockEmpty()) { this.loadTail(); return; }
        const margin = Math.max(800, 2 * c.clientHeight);
        if (this.plo > 0 && !this.pending.older && c.scrollTop < margin) {
            this.request('older', Math.max(0, this.plo - this.CHUNK), this.plo - 1);
        }
        if (this.phi < len - 1 && !this.pending.newer &&
            c.scrollHeight - c.scrollTop - c.clientHeight < margin) {
            this.request('newer', this.phi + 1, Math.min(len - 1, this.phi + this.CHUNK));
        }
        this.trimBlock();
        this.updateRail();
    }

    // Rows of the block whose box meets the viewport, as positions in
    // `order`: [first, last], or [-1, -1]. Hidden rows have no box.
    visibleSpan() {
        const st = this.container.scrollTop;
        const sb = st + this.container.clientHeight;
        let first = -1, last = -1;
        for (let i = 0; i < this.order.length; i++) {
            const node = this.cache.get(this.order[i]);
            if (!node || node.offsetParent === null) continue;
            const top = node.offsetTop;
            if (top + node.offsetHeight <= st + 1) continue;
            if (top >= sb) break;
            if (first < 0) first = i;
            last = i;
        }
        return [first, last];
    }

    // Keep the block at MAX_WINDOW rows: past that, drop rows on the side
    // farther from the viewport, down to MAX_WINDOW - CHUNK, leaving half a
    // chunk beyond the viewport on that side. Rows dropped above the reader
    // take the scroll position down with them. A row held fullscreen stays.
    trimBlock() {
        const n = this.order.length;
        if (n <= this.MAX_WINDOW) return;
        const [first, last] = this.visibleSpan();
        if (first < 0) return;
        const c = this.container;
        const excess = n - (this.MAX_WINDOW - this.CHUNK);
        const keepBeyond = Math.floor(this.CHUNK / 2);
        const above = first, below = n - 1 - last;
        const holds = (ids) => ids.some(idx => this.holdsFullscreen(this.cache.get(idx)));
        if (above >= below) {
            const d = Math.min(excess, above - keepBeyond);
            if (d <= 0 || holds(this.order.slice(0, d))) return;
            const before = c.scrollHeight;
            const top = c.scrollTop;
            for (const idx of this.order.splice(0, d)) this.removeRow(idx);
            this.plo = this.seqPos(this.order[0]);
            const shrunk = before - c.scrollHeight;
            if (shrunk !== 0) {
                c.scrollTop = top - shrunk;
                this.prevScrollTop = c.scrollTop;
            }
        } else {
            const d = Math.min(excess, below - keepBeyond);
            if (d <= 0 || holds(this.order.slice(n - d))) return;
            for (const idx of this.order.splice(n - d)) this.removeRow(idx);
            this.phi = this.seqPos(this.order[this.order.length - 1]);
        }
    }

    // Go to sequence position `p`: scrolled into view when the block has
    // it, else a new block around it. The last position is the bottom, in
    // follow mode. `offset` is the gap above the target row.
    jumpToPosition(p, { flashId = null, offset = 8 } = {}) {
        const len = this.seqLength();
        if (len === 0) return;
        p = Math.max(0, Math.min(len - 1, p));
        if (p === len - 1) {
            this.setFollowMode(true);
            this.scrollToBottom();
            if (flashId) this.flash(flashId);
            return;
        }
        this.setFollowMode(false);
        const node = this.cache.get(this.seqIndex(p));
        if (node && p >= this.plo && p <= this.phi && node.offsetParent !== null) {
            this.container.scrollTop = Math.max(0, node.offsetTop - offset);
            this.prevScrollTop = this.container.scrollTop;
            if (flashId) this.flash(flashId);
            this.ensureWindow();
            return;
        }
        const back = Math.floor(this.CHUNK / 2);
        this.requestBlock(Math.max(0, p - back), Math.min(len - 1, p + this.CHUNK),
                          { kind: 'jump', target: p, offset, flashId });
    }

    flash(id) {
        const node = this.nodeById.get(id);
        if (!node) return;
        node.classList.remove('bt-jump-flash');
        void node.offsetWidth;            // restart the animation on a repeat click
        node.classList.add('bt-jump-flash');
        setTimeout(() => node.classList.remove('bt-jump-flash'), 1800);
    }

    // The load card (sidebar.jl ChatWaitingView) waits for this: the
    // transcript shows its rows. Once per instance.
    markReady() {
        if (this.ready) return;
        this.ready = true;
        this.paneEl = this.container.closest('.bt-chatpane');
        if (this.paneEl) this.paneEl.dataset.btSettled = '1';
        this.announceSettle('bt-chat-settled');
    }

    announceSettle(name) {
        const pid = this.paneEl?.dataset.panePid || '';
        window.dispatchEvent(new CustomEvent(name, { detail: pid }));
    }

    // THE one owner of a row's `display`: the type filter (hiddenTypes)
    // hides rows in place. The lens does not hide rows; it chooses which
    // rows the block holds.
    applyVisibility(idx, node = this.cache.get(idx)) {
        if (!node) return;
        node.style.display = this.hiddenTypes.has(this.keyByIdx.get(idx)) ? 'none' : '';
    }

    // The reading position: the first visible row (not of `excludeKey`, a
    // type about to be hidden) at or below the viewport top, and its offset
    // from it. A row hanging only a few pixels into the viewport is not
    // what anyone is reading.
    captureAnchor(excludeKey = null) {
        const st = this.container.scrollTop;
        for (const idx of this.order) {
            const n = this.cache.get(idx);
            if (!n || n.offsetParent === null) continue;
            if (excludeKey && n.dataset.filterKey === excludeKey) continue;
            if (n.offsetTop + n.offsetHeight > st + 4) return { idx, off: n.offsetTop - st };
        }
        return null;
    }

    restoreAnchor(a) {
        if (!a) return;
        const n = this.cache.get(a.idx);
        if (!n || n.offsetParent === null) return;
        const want = Math.max(0, n.offsetTop - a.off);
        if (Math.abs(this.container.scrollTop - want) > 1) {
            this.container.scrollTop = want;
            this.prevScrollTop = this.container.scrollTop;
        }
    }

    // Record the heights rows have now, so the row observer sees a
    // deliberate reflow (a filter toggle, already anchored) as no change.
    // The observer's own measure: the fractional border box. `offsetHeight`
    // rounds, and the rounding read as growth, half a pixel per row.
    syncRowHeights() {
        for (const idx of this.order) {
            const node = this.cache.get(idx);
            if (node) node.__btH = node.getBoundingClientRect().height;
        }
    }

    // The shape of this row's body placeholder (`showLoading`), or null. The
    // height the body rendered at, at the transcript's width now (within
    // 2 px): what the server sent with the row (`body_h`) and what the row
    // reported since. Keyed by the transcript's width, not the body's: a body
    // can shrink to fit its content (native media), so its own width before
    // the content arrives says nothing.
    //
    // Not measured at this width, but one picture of known size (`media`):
    // the picture's shape, laid out like `media_element` lays out the picture
    // (its width, at most the body's, and its aspect ratio), so even a chat
    // opened for the first time holds the row's size when the picture
    // arrives. Not a height computed here: a native row shrinks to fit its
    // body, so before the picture is in it nothing here knows the width it
    // will get. Above it, as padding, what the body holds besides the picture
    // (`media_extra`, a bt_show's Share row), as measured at another width.
    // `overflow: hidden` drops the automatic minimum height, so "loading…"
    // can't stretch a small picture's placeholder.
    bodyReserve(node) {
        if (!node.collapsable) return null;
        const map = node.__btBodyH;
        const w = this.bodyWidth();
        if (map) for (const [k, h] of Object.entries(map))
            if (Math.abs(+k - w) <= 2) return {height: h + 'px'};
        const m = node.__btMedia;
        if (m && m[0] > 0 && m[1] > 0)
            return {boxSizing: 'content-box', padding: (node.__btMediaExtra || 0) + 'px 0 0',
                    width: m[0] + 'px', maxWidth: '100%', aspectRatio: m[0] + ' / ' + m[1], overflow: 'hidden'};
        return null;
    }

    bodyWidth() { return Math.round(this.container.clientWidth); }

    // A tool row changed size: once it holds still, its body reports the
    // height it settled at, for the placeholder of the next render. An exact
    // reservation changes nothing, so a known body never reports again.
    scheduleBodyReport(node) {
        clearTimeout(node.__btBodyTimer);
        node.__btBodyTimer = setTimeout(() => this.reportBody(node), 800);
    }

    reportBody(node) {
        node.__btBodyTimer = null;
        if (this.destroyed || !node.isConnected || this.container.clientHeight === 0) return;
        const body = node.collapsable?.body;
        const id = node.dataset.msgId;
        if (!id || !body || body.offsetParent === null || body.childElementCount === 0) return;
        if (body.querySelector(':scope > .bt-collapsable-loading')) return;
        const content = this.bodyContentHeight(body);
        const h = Math.round(content);
        const w = this.bodyWidth();
        if (w < 1 || h < 1) return;
        const map = node.__btBodyH || {};
        for (const k of Object.keys(map)) {
            if (Math.abs(+k - w) > 2) continue;
            if (Math.abs(map[k] - h) <= 1) return;
            delete map[k];
        }
        map[w] = h;
        node.__btBodyH = map;
        // Of that, what is not its one picture (`bodyReserve`).
        const pics = body.querySelectorAll('.bt-media-wrap');
        const extra = pics.length === 1
            ? Math.min(h, Math.max(0, Math.round(content - pics[0].getBoundingClientRect().height))) : 0;
        node.__btMediaExtra = extra;
        this.comm.notify({type: 'tool.size', id, w, h, extra});
    }

    // A body's CONTENT box height: what a placeholder inside it has to fill
    // for the body to keep its size. Fractional, like the row heights.
    bodyContentHeight(body) {
        const cs = getComputedStyle(body);
        return body.getBoundingClientRect().height -
            parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom) -
            parseFloat(cs.borderTopWidth) - parseFloat(cs.borderBottomWidth);
    }

    // Free a row's body far from the view (see `freeObserver`). Only a heavy
    // one: editors, or a big tree of elements. A live app has its own
    // keep-alive, a running tool streams into its body, a clip may be
    // playing, and a picture or a small body costs less than rendering it
    // again would.
    freeBody(node) {
        if (!node.isConnected || node.dataset.btFreed || node.dataset.btApp) return;
        if (node.classList.contains('bt-tool-live') || this.holdsFullscreen(node)) return;
        const c = node.collapsable;
        const body = c?.body;
        if (!body || !c.loaded || body.offsetParent === null || body.childElementCount === 0) return;
        if (body.querySelector(':scope > .bt-collapsable-loading')) return;
        // Not `canvas`: Monaco draws its overview ruler on one. A live app's
        // canvas is excluded by `btApp` above.
        if (body.querySelector('img, video, audio')) return;
        if (!body.querySelector('.monaco-editor') && body.getElementsByTagName('*').length < 300) return;
        const h = this.bodyContentHeight(body);
        node.dataset.btFreed = '1';
        // Out of the document, the body's session ends and BonitoBook
        // disposes its editors; `bodyDied` leaves a freed row alone.
        body.innerHTML = '<div class="bt-collapsable-loading bt-body-freed">loading…</div>';
        const ph = body.firstElementChild;
        ph.style.boxSizing = 'border-box';
        ph.style.height = h + 'px';
    }

    // Back within reach: render the body again. The reply replaces the
    // placeholder, which held the body's height in the meantime.
    unfreeBody(node) {
        delete node.dataset.btFreed;
        this.comm.notify({type: 'tool.render', id: node.dataset.msgId});
    }

    // A body arrived from the server (the tool.render reply, `bodyMounted`
    // below). Its row may be far from the view by now: a burst of edits
    // streams faster than their bodies render. Observing it again makes the
    // observer report where the row is now.
    onBodyMounted(node) {
        this.freeObserver.unobserve(node);
        this.freeObserver.observe(node);
    }

    // ── The rail ─────────────────────────────────────────────────────────
    // A scrollbar by message count, since the native one knows only the
    // loaded block. The thumb sits at the position of the top visible
    // message (plus how far it has scrolled past) in the whole sequence, so
    // wheel and swipe move it too. Dragging it names the message it would
    // land on and jumps there when the pointer rests or lets go; a click on
    // the track jumps straight there.
    setupRail() {
        const wrap = this.container.parentElement;
        if (!wrap) return;
        const rail = document.createElement('div');
        rail.className = 'bt-rail bt-rail-hidden';
        const thumb = document.createElement('div');
        thumb.className = 'bt-rail-thumb';
        const label = document.createElement('div');
        label.className = 'bt-rail-label';
        rail.append(thumb, label);
        wrap.appendChild(rail);
        this.railEl = rail;
        this.railThumb = thumb;
        this.railLabel = label;
        const fracAt = (clientY) => {
            const r = rail.getBoundingClientRect();
            const th = thumb.offsetHeight;
            return Math.min(1, Math.max(0, (clientY - r.top - th / 2) / Math.max(1, r.height - th)));
        };
        this.onRailDown = (e) => {
            if (e.button !== 0) return;
            e.preventDefault();
            e.stopPropagation();
            rail.setPointerCapture(e.pointerId);
            this.markUserInput();
            this.cancelMomentum();
            // Grabbing the thumb keeps it under the pointer where it was
            // grabbed; a press on the track centers it there.
            const tr = thumb.getBoundingClientRect();
            const grab = e.target === thumb ? e.clientY - (tr.top + tr.height / 2) : 0;
            this.railDrag = { pointerId: e.pointerId, grab, pos: null, timer: null };
            this.scrollbarDrag = true;
            rail.classList.add('bt-rail-active');
            this.railMove(fracAt(e.clientY - grab));
        };
        this.onRailMove = (e) => {
            const d = this.railDrag;
            if (!d || e.pointerId !== d.pointerId) return;
            e.preventDefault();
            this.railMove(fracAt(e.clientY - d.grab));
        };
        this.onRailUp = (e) => {
            const d = this.railDrag;
            if (!d || e.pointerId !== d.pointerId) return;
            if (rail.hasPointerCapture(e.pointerId)) rail.releasePointerCapture(e.pointerId);
            clearTimeout(d.timer);
            this.railDrag = null;
            this.scrollbarDrag = false;
            rail.classList.remove('bt-rail-active');
            if (d.pos !== null && d.pos !== d.jumped) this.jumpToPosition(d.pos);
            this.updateRail();
        };
        // The rail sits over the transcript's edge: a wheel there scrolls the
        // transcript, as it would over a native scrollbar.
        this.onRailWheel = (e) => {
            e.preventDefault();
            this.markUserInput();
            const line = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? this.container.clientHeight : 1;
            this.container.scrollTop += e.deltaY * line;
        };
        rail.addEventListener('pointerdown', this.onRailDown);
        rail.addEventListener('pointermove', this.onRailMove);
        rail.addEventListener('pointerup', this.onRailUp);
        rail.addEventListener('pointercancel', this.onRailUp);
        rail.addEventListener('wheel', this.onRailWheel, { passive: false });

        // Home and End go to the ends of the conversation; the browser's own
        // keys stop at the ends of the loaded block. For the transcript the
        // pointer last pressed in, as the browser's keyboard scrolling does
        // (a split shows several), and never while typing.
        this.keyScope = false;
        this.onScopePointer = (e) => { this.keyScope = wrap.contains(e.target); };
        this.onEndsKey = (e) => {
            if (e.key !== 'Home' && e.key !== 'End') return;
            if (e.altKey || e.metaKey || e.shiftKey || e.defaultPrevented) return;
            if (this.destroyed || this.container.clientHeight === 0) return;
            const t = e.target;
            const page = t === document.body || t === document.documentElement;
            if (!(wrap.contains(t) || (page && this.keyScope))) return;
            if (t.isContentEditable || (t.closest && t.closest('input, textarea, select, .monaco-editor'))) return;
            const len = this.seqLength();
            if (len === 0) return;
            e.preventDefault();
            this.markUserInput();
            // Home: up to the very top, the padding above the first row too.
            if (e.key === 'Home') this.jumpToPosition(0, { offset: Infinity });
            else this.jumpToPosition(len - 1);
        };
        document.addEventListener('pointerdown', this.onScopePointer, true);
        document.addEventListener('keydown', this.onEndsKey);
    }

    teardownRail() {
        if (this.railDrag) clearTimeout(this.railDrag.timer);
        document.removeEventListener('pointerdown', this.onScopePointer, true);
        document.removeEventListener('keydown', this.onEndsKey);
        this.railEl?.remove();
        this.railEl = null;
    }

    railMove(f) {
        const d = this.railDrag;
        const len = this.seqLength();
        if (!d || len === 0) return;
        const p = Math.round(f * (len - 1));
        this.placeThumb(f);
        this.railLabel.textContent = `${this.lensActive ? 'Match' : 'Message'} ${p + 1} of ${len}`;
        if (p === d.pos) return;
        d.pos = p;
        clearTimeout(d.timer);
        d.timer = setTimeout(() => {
            if (this.railDrag !== d) return;
            d.jumped = p;
            this.jumpToPosition(p);
        }, 150);
    }

    placeThumb(f) {
        const range = Math.max(0, this.railEl.clientHeight - this.railThumb.offsetHeight);
        const y = Math.round(f * range) + 'px';
        this.railThumb.style.transform = `translateY(${y})`;
        this.railLabel.style.transform = `translateY(${y})`;
    }

    updateRail() {
        const rail = this.railEl;
        if (!rail || this.railDrag) return;
        const c = this.container;
        const len = this.seqLength();
        const fits = len === 0 ||
            (this.plo <= 0 && this.atTail() && c.scrollHeight <= c.clientHeight + 1);
        rail.classList.toggle('bt-rail-hidden', fits);
        if (fits) return;
        let f;
        if (this.atTail() && this.atBottom()) {
            f = 1;
        } else if (this.plo <= 0 && c.scrollTop <= 1) {
            f = 0;
        } else {
            const [first] = this.visibleSpan();
            if (first < 0) return;
            const idx = this.order[first];
            const node = this.cache.get(idx);
            const into = node.offsetHeight > 0
                ? Math.min(1, Math.max(0, (c.scrollTop - node.offsetTop) / node.offsetHeight)) : 0;
            f = Math.min(1, (this.seqPos(idx) + into) / Math.max(1, len - 1));
        }
        this.placeThumb(f);
    }

    // Is this node the one currently held fullscreen (or does it contain it)?
    //
    // Two mechanisms, because iOS is the platform this matters on and iOS is the
    // one that does not implement the first: Safari plays `<video>` fullscreen
    // through its own presentation mode WITHOUT ever setting
    // `document.fullscreenElement`, so a check on that alone reads "not
    // fullscreen" on exactly the device where the bug shows up.
    holdsFullscreen(node) {
        if (!node) return false;
        const fs = document.fullscreenElement || document.webkitFullscreenElement;
        if (fs && (node === fs || node.contains(fs))) return true;
        for (const v of node.querySelectorAll('video')) {
            if (v.webkitDisplayingFullscreen ||
                v.webkitPresentationMode === 'fullscreen') return true;
        }
        return false;
    }

    // Anything fullscreen anywhere in this pane. Used to tell a viewport change
    // caused BY fullscreen apart from the soft keyboard, which is the only thing
    // the viewport handler is actually there for.
    fullscreenActive() {
        return this.holdsFullscreen(this.container) ||
               !!(document.fullscreenElement || document.webkitFullscreenElement);
    }

    // Mark a live app as most-recently-relevant in the keep-alive LRU (it
    // entered or left the viewport).
    touchApp(idx) {
        const node = this.cache.get(idx);
        if (!node || node.dataset.btSpilled) return;
        const i = this.appLru.indexOf(idx);
        if (i !== -1) this.appLru.splice(i, 1);
        this.appLru.push(idx);
    }

    // Keep at most APP_KEEPALIVE live apps outside the viewport, spilling the
    // least-recently-visible ones beyond that. Visible apps are never
    // spilled. A spilled app shows its last frame as a static <img> + Reload
    // button and has given back its WebGL context; the browser hard-caps live
    // contexts (~16) and destroys the oldest beyond that, so this keeps us
    // deterministically below the ceiling: our snapshot fires first, instead
    // of the browser blanking a canvas out from under us.
    enforceAppLru() {
        const offscreen = this.appLru.filter(idx => !this.visibleApps.has(idx));
        let extra = offscreen.length - this.APP_KEEPALIVE;
        for (const idx of offscreen) {          // least recent first
            if (extra <= 0) break;
            const node = this.cache.get(idx);
            if (!node || this.holdsFullscreen(node)) continue;
            this.spillApp(idx, node);
            extra--;
        }
    }

    // Freeze an app to a snapshot + Reload button and tear down its live
    // embed. The row stays in place; Reload re-mounts a fresh sub-session
    // via the standard tool.render path.
    spillApp(idx, node) {
        const slot = node.querySelector('.bt-slot') || node.querySelector('.bt-tool-body');
        const li0 = this.appLru.indexOf(idx);
        // Nothing mounted (a collapsed app, a body not rendered yet) holds no
        // live app to freeze: it only leaves the keep-alive list. Freezing it
        // put a snapshot box into the empty body and grew the row.
        if (!slot || slot.childElementCount === 0) {
            if (li0 !== -1) this.appLru.splice(li0, 1);
            return;
        }
        const canvas = node.querySelector('canvas');
        let dataUrl = null;
        // preserveDrawingBuffer is on, so toDataURL returns the last rendered
        // frame even when the app is off-screen.
        if (canvas) {
            // A canvas that drew a cross-origin picture is tainted and can't be
            // read: the app is then frozen without a snapshot.
            try { dataUrl = canvas.toDataURL('image/png'); }
            catch (error) {
                if (error.name !== 'SecurityError') throw error;
                console.warn('app snapshot refused:', error.message);
            }
        }
        if (slot) {
            // The snapshot takes the app's place at the app's size: the row
            // keeps its height, so nothing around it moves when an app out of
            // view is frozen. Measured before emptying: the canvas at its size
            // on screen (its pixels are devicePixelRatio times more, which as an
            // <img> came out twice the size on a HiDPI screen).
            // (A floor for an app whose body never rendered: the Reload button
            // has to fit.)
            const h = Math.max(40, slot.offsetHeight);
            const cssW = canvas ? canvas.clientWidth : 0, cssH = canvas ? canvas.clientHeight : 0;
            // Emptying the slot removes the sub-session root → Bonito closes the
            // sub-session and WGLMakie disposes the WebGL context.
            slot.innerHTML = '';
            const wrap = document.createElement('div');
            wrap.className = 'bt-app-snapshot';
            wrap.style.cssText = `position:relative;max-width:100%;height:${h}px;overflow:hidden`;
            if (dataUrl) {
                const img = document.createElement('img');
                img.src = dataUrl;
                img.alt = 'app snapshot';
                img.style.cssText = `width:${cssW}px;height:${cssH}px;max-width:100%;object-fit:contain;display:block;` +
                    'border-radius:6px;filter:saturate(.85) brightness(.97)';
                wrap.appendChild(img);
            }
            const btn = document.createElement('button');
            btn.className = 'bt-app-reload';
            btn.type = 'button';
            btn.textContent = dataUrl ? '⟳ Reload live app' : '⟳ Load live app';
            btn.style.cssText = 'position:absolute;top:8px;right:8px;padding:4px 10px;' +
                'border-radius:6px;border:1px solid #cbd5e1;background:rgba(255,255,255,.9);' +
                'cursor:pointer;font:500 12px/1 ui-sans-serif,system-ui';
            btn.addEventListener('click', (e) => { e.stopPropagation(); this.reloadApp(node); });
            wrap.appendChild(btn);
            slot.appendChild(wrap);
        }
        node.dataset.btSpilled = '1';
        const li = this.appLru.indexOf(idx);
        if (li !== -1) this.appLru.splice(li, 1);
    }

    // Re-mount a spilled app: drop the snapshot, re-render the BonitoAppMsg body
    // (fresh worker sub-session) through the existing tool.render path.
    reloadApp(node) {
        delete node.dataset.btSpilled;
        this.touchApp(node.__btIdx);
        const id = node.dataset.msgId;
        const body = node.querySelector('.bt-tool-body');
        if (body) {
            // At the snapshot's height until the app is back, like any body
            // waiting for its render (`showPlaceholder`).
            showLoading(body, {height: body.offsetHeight + 'px'});
        }
        if (id) this.comm.notify({ type: 'tool.render', id });
    }

    // An editor in this row's body died with its session: the row left the
    // document, or the body was mounted while it was out. Render the body again
    // now if on the page, else on return (mountDeferred). A replaced or
    // collapsed body leaves the row first. A spilled eval card keeps its code
    // editor outside the emptied slot, and its Reload: no live remount.
    bodyDied(row) {
        if (this.destroyed || row.dataset.btSpilled || row.dataset.btFreed) return;
        row.dataset.btRemount = '1';
        // Several editors in one body die at once: one render, since
        // mountDeferred clears the flag.
        if (row.isConnected) queueMicrotask(() => this.mountDeferred(row));
    }

    // Fetch a tool row's body once the row is near the view (`mountObserver`).
    // Expanding, and the placeholder that holds the body's height, happen at
    // once; only the request waits. Observing again makes the observer report
    // where the row is now, after whatever placed it.
    requestBody(node) {
        node.dataset.btWantsBody = '1';
        this.mountObserver.unobserve(node);
        this.mountObserver.observe(node);
    }

    // Bodies that wait for their node to be in the document, so the
    // tool.render reply has a live slot to mount into. One-shot flags,
    // cleared before acting.
    mountDeferred(node) {
        // Auto-expand (bt_show / native images, a completed eval).
        if (node.dataset.btAutoExpand) {
            delete node.dataset.btAutoExpand;
            const c = node.collapsable;
            c?.setExpanded(true);
            // Already expanded, with no body yet (`setExpanded` only fetches
            // on the way in): fetch it.
            if (c && c.lazy && !c.loaded) {
                c.loaded = true;
                c.showPlaceholder();
                this.requestBody(node);
            }
        }
        // Eager mount for edit tools (Monaco body without flipping the
        // Collapsable to expanded).
        if (node.dataset.btAutoMount) {
            delete node.dataset.btAutoMount;
            if (node.collapsable && !node.collapsable.loaded) {
                node.collapsable.loaded = true;
                const body = node.collapsable.body;
                if (body.childElementCount === 0 && this.bodyReserve(node))
                    node.collapsable.showPlaceholder();
                this.requestBody(node);
            }
        }
        // Its body's editors died (bodyDied): render it again. The reply
        // replaces the old body in place.
        if (node.dataset.btRemount) {
            delete node.dataset.btRemount;
            this.requestBody(node);
        }
    }

    // ── New messages + streaming ──────────────────────────────────────────

    appendNewMessage(msg) {
        // `n` already pushed totalCount above; the new message lives at idx n-1.
        const idx = this.totalCount - 1;
        if (!this.cache.has(idx)) {
            // A lens's matches are a STATIC set computed when its query ran:
            // a new message can't be in it. It shows anyway (re-running the
            // query re-evaluates it), so it joins the sequence at the end.
            if (this.seq) this.seq.push(idx);
            // Into the page only when the block reaches the end; otherwise it
            // loads with the rest when the reader gets there.
            if (this.seqPos(idx) === this.phi + 1) {
                const nodes = this.insertRows([[idx, msg]], this.rowsEnd);
                this.order.push(idx);
                this.phi += 1;
                this.adoptRows(nodes);
            }
        }
        // Strict no-yank semantics: any new message (including the
        // user's own) auto-scrolls ONLY while followMode is on.
        // When the user is reading scrollback we just register unread
        // and surface the pill — sending their own message doesn't
        // re-engage follow either; they have to click the pill or
        // scroll to the bottom to come back. This matches the spec
        // "always stay at the position the user scrolls to".
        if (this.followMode) {
            // Scroll synchronously. We deliberately do NOT route through
            // `queueScrollToBottom` here: rAF is paused in backgrounded
            // tabs/windows, so the bubble would only show once the user
            // re-focuses the tab. Synchronous scrollTop writes work
            // regardless of tab visibility. rAF batching is still used for
            // `appendChunk` (50 chunks/s, batching is a real perf win; the
            // streaming bubble itself is already in the DOM, only the
            // scroll lags).
            this.scrollToBottom();
        } else {
            this.registerUnread();
            this.updateRail();
        }
    }

    appendChunk(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        // A finalized node has already been painted with the authoritative html
        // by `onAgentFinal` (which cleared the pending stream). Message ids are
        // unique per message, so a finalized id never legitimately gets more
        // chunks: a LATE or duplicate `chunk` for it would repaint the older,
        // shorter cumulative html; drop it. A NEW message uses a fresh node
        // (fresh id), so this per-node flag never blocks live streaming. (A
        // row dropped from the block has no node: its chunks are ignored, and
        // it comes back from the server with its final text.)
        if (node.__btFinal) return;
        // Server ships the FULL rendered html of the message-so-far each
        // chunk (CommonMark-rendered, so intraword `_`s don't italicize and
        // newlines/lists/headings format correctly while streaming). Each
        // payload is self-contained, so intermediate frames are droppable —
        // apply through the throttle below instead of re-parsing and
        // re-laying-out the whole (growing) bubble at chunk rate.
        if (msg.html !== undefined) {
            this.applyStreamHtml(node, msg.html);
        } else if (msg.text !== undefined) {
            // Legacy text-delta path (kept for the streaming-stress mocks
            // that still feed plain text). Append to the streaming span.
            const t = node.querySelector('.bt-stream-text');
            if (t) t.textContent += msg.text;
        }
        // queueScrollToBottom rAF-batches multiple chunks per frame so
        // we only scroll AFTER the layout pass that includes the new
        // text (avoids the stale-scrollHeight race).
        if (this.followMode) {
            this.queueScrollToBottom();
        } else {
            // Streaming bubble is being extended while user is reading
            // scrollback. registerUnread is idempotent for repeated
            // chunks of the same bubble — the pill stays visible once
            // shown.
            this.registerUnread();
        }
    }

    appendUserChunk(text) {
        // Streaming user message: append to the most recent user bubble.
        const idx = this.totalCount - 1;
        const node = this.cache.get(idx);
        if (node && node.classList.contains('bt-user-msg')) {
            node.textContent += text;
            if (this.followMode) {
                this.queueScrollToBottom();
            } else {
                this.registerUnread();
            }
        }
    }

    // Leading+trailing throttle for streaming innerHTML. The first chunk
    // paints immediately; chunks inside the STREAM_APPLY_MS window are
    // coalesced (last one wins — payloads are cumulative) and flushed by the
    // trailing timer, so the final chunk always lands even if the stream
    // stops mid-window. Per-chunk replacement re-parsed + re-laid-out the
    // entire message at chunk rate — a real stutter source on long replies.
    applyStreamHtml(node, html) {
        node.__btStreamHtml = html;
        if (node.__btStreamTimer != null) return;   // window open: coalesce
        const flush = () => {
            node.__btStreamTimer = null;
            // A final may have landed while this timer was pending; never let a
            // trailing flush repaint an already-finalized bubble.
            if (this.destroyed || node.__btFinal || node.__btStreamHtml == null) return;
            node.innerHTML = node.__btStreamHtml;
            node.__btStreamHtml = null;
            node.__btStreamTimer = setTimeout(flush, this.STREAM_APPLY_MS);
        };
        flush();
    }

    // Final html supersedes any throttled stream payload still pending — a
    // trailing flush after this would resurrect the older streaming state.
    clearPendingStream(node) {
        node.__btStreamHtml = null;
        if (node.__btStreamTimer != null) {
            clearTimeout(node.__btStreamTimer);
            node.__btStreamTimer = null;
        }
    }

    onAgentFinal(msg) {
        const node = this.nodeById.get(msg.id);
        if (node) {
            // ALWAYS clear the pending stream, even for an empty final: a
            // throttled trailing flush queued by `applyStreamHtml` would
            // otherwise fire AFTER this and resurrect stale streamed text into
            // an already-final bubble. For an empty final we also blank the
            // node so the bubble reflects the authoritative (empty) message.
            this.clearPendingStream(node);
            node.innerHTML = msg.html || '';
            linkifyPaths(node);
            decorateCodeBlocks(node);
            // Mark the node final so a LATE/duplicate `chunk` for this id can't
            // repaint the older, shorter cumulative html (see `appendChunk`).
            node.__btFinal = true;
            return;
        }
        // Id mismatch: mirror `onSummaryFinal`'s DOM fallback so the
        // authoritative final isn't silently dropped. Prefer a precise by-id
        // lookup (agent nodes carry `data-msg-id`); fall back to the last
        // agent bubble in the DOM, but only when the block ends at the newest
        // message. Otherwise the last bubble in the page is an OLD message,
        // and the final belongs to a row the block doesn't hold: it arrives
        // with its final text when the reader gets there.
        let tgt = msg.id
            ? this.container.querySelector(
                `.bt-agent-msg[data-msg-id="${CSS.escape(msg.id)}"]`)
            : null;
        if (!tgt && this.atTail()) {
            const nodes = this.container.querySelectorAll('.bt-agent-msg');
            tgt = nodes[nodes.length - 1];
        }
        if (tgt) {
            this.clearPendingStream(tgt);
            tgt.innerHTML = msg.html || '';
            linkifyPaths(tgt);
            decorateCodeBlocks(tgt);
            tgt.__btFinal = true;
        }
    }

    // A committed thought ships its html on close — pre-fill so the body is
    // there (and marked loaded) before the user even expands.
    onThoughtFinal(msg) {
        const node = this.nodeById.get(msg.id);
        node && node.collapsable && node.collapsable.fill(msg.html || '');
    }

    // Reply to a `thought.render` request (reloaded thought, lazy body).
    onThoughtBody(msg) {
        const node = this.nodeById.get(msg.id);
        node && node.collapsable && node.collapsable.fill(msg.html);
    }

    // Transient "reasoning…" indicator toggled by Julia for the lifetime of an
    // agent thought (redacted thoughts have no body, so this is the only trace).
    onThinking(msg) {
        const active = msg.active;
        if (this.thinkingEl) this.thinkingEl.classList.toggle('bt-thinking-active', !!active);
        // The busy dots and the reasoning line are redundant while a thought
        // streams — suppress the dots so exactly ONE liveness indicator shows.
        if (this.busyEl) this.busyEl.classList.toggle('bt-busy-suppressed', !!active);
        // Show the running chunk count while active; clear it on teardown so the
        // next think starts fresh. count 0 (initial activation) shows no number.
        // Spell the unit out — a bare number next to "reasoning…" read as noise.
        if (this.thinkingCountEl)
            this.thinkingCountEl.textContent =
                (active && msg.count) ? `${msg.count} token chunks` : '';
        if (active && this.followMode) this.queueScrollToBottom();
    }

    // Claude Code's estimate of the tokens thought so far, while the model
    // thinks without streaming its thoughts (the usage updates that carry
    // `_claude/thinkingTokens`, about one a second). The reasoning line shows
    // it in place of the busy dots, so a long think reads as progress and
    // not as a stalled agent. The model's next output ends it (`dispatch`).
    onThinkingTokens(n) {
        if (!this.thinkingEl || !Number.isFinite(n)) return;
        this.thinkingEstimate = true;
        this.thinkingEl.classList.add('bt-thinking-active');
        this.busyEl?.classList.add('bt-busy-suppressed');
        if (this.thinkingCountEl) this.thinkingCountEl.textContent = `${formatTokens(n)} tokens`;
        if (this.followMode) this.queueScrollToBottom();
    }

    endThinkingEstimate() {
        this.thinkingEstimate = false;
        this.thinkingEl?.classList.remove('bt-thinking-active');
        this.busyEl?.classList.remove('bt-busy-suppressed');
        if (this.thinkingCountEl) this.thinkingCountEl.textContent = '';
    }

    // ── Permission / question cards ──────────────────────────────────────
    // A `session/request_permission` (AskUserQuestion, plan approval, …)
    // renders as an interactive card with one button per option. The card is
    // PLAIN scroll content (like the busy/thinking indicators, inserted
    // after the rows, never one of them): it lives exactly under the last message for the lifetime
    // of the request and is dropped via `permission_done` once the answer
    // (from ANY tab, or the server-side timeout) resolves the RPC.
    onPermission(msg) {
        if (!msg.key || !Array.isArray(msg.options)) return;
        // Re-emit / remount safety: one card per key.
        if (this.container.querySelector(
                `.bt-permission-card[data-perm-key="${CSS.escape(msg.key)}"]`)) return;
        const card = document.createElement('div');
        card.className = 'bt-permission-card';
        card.dataset.permKey = msg.key;
        const q = document.createElement('div');
        q.className = 'bt-permission-question';
        q.textContent = msg.question || 'The agent is asking for permission';
        const row = document.createElement('div');
        row.className = 'bt-permission-options';
        for (const opt of msg.options) {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'bt-permission-btn' +
                (String(opt.kind || '').startsWith('allow') ? ' bt-perm-allow' :
                 String(opt.kind || '').startsWith('reject') ? ' bt-perm-reject' : '');
            btn.textContent = opt.name || opt.optionId;
            btn.addEventListener('click', () => {
                if (card.classList.contains('bt-perm-answered')) return;
                card.classList.add('bt-perm-answered');
                btn.classList.add('bt-perm-chosen');
                row.querySelectorAll('button').forEach(b => b.disabled = true);
                this.comm.notify({ type: 'permission_answer',
                                   key: msg.key, optionId: opt.optionId });
            });
            row.appendChild(btn);
        }
        card.append(q, row);
        // Under the last message: before the busy indicator (which follows
        // the rows).
        this.container.insertBefore(card, this.busyEl || null);
        if (this.followMode) this.queueScrollToBottom();
    }

    onPermissionDone(msg) {
        const card = this.container.querySelector(
            `.bt-permission-card[data-perm-key="${CSS.escape(msg.key || '')}"]`);
        if (!card) return;
        if (card.classList.contains('bt-perm-answered')) {
            // Leave the chosen state visible for a beat, then clear.
            setTimeout(() => card.remove(), 1500);
        } else {
            card.remove();   // answered elsewhere (other tab / timeout)
        }
    }

    // ── Question forms (AskUserQuestion via ACP form elicitation) ────────
    // `fields` is the flattened requestedSchema: select / multiselect
    // fields carry option lists; text fields render as a free-text input
    // (the "Other" box). The common case — ONE single-select question —
    // submits on option click; everything else collects picks and submits
    // through the Answer button. Skip = decline ("the user skipped", the
    // agent continues on its own).
    onQuestion(msg) {
        if (!msg.key || !Array.isArray(msg.fields)) return;
        if (this.container.querySelector(
                `.bt-permission-card[data-perm-key="${CSS.escape(msg.key)}"]`)) return;
        const card = document.createElement('div');
        // Keep `bt-permission-card` for the dedup selector + shared chrome; add
        // `bt-question-card` so a question reads distinctly from a permission ask.
        card.className = 'bt-permission-card bt-question-card';
        card.dataset.permKey = msg.key;
        const q = document.createElement('div');
        q.className = 'bt-permission-question bt-question-prompt';
        // A small "?" badge gives the card a clear "the agent is asking you"
        // identity instead of looking like a generic panel.
        const icon = document.createElement('span');
        icon.className = 'bt-question-icon';
        icon.textContent = '?';
        icon.setAttribute('aria-hidden', 'true');
        const qtext = document.createElement('span');
        qtext.textContent = msg.message || 'The agent has a question';
        q.appendChild(icon);
        q.appendChild(qtext);
        card.appendChild(q);

        const selects = msg.fields.filter(f => f.kind === 'select' || f.kind === 'multiselect');
        const texts   = msg.fields.filter(f => f.kind === 'text');
        const instant = selects.length === 1 && selects[0].kind === 'select';
        const chosen  = {};   // field key → value (string) or Set (multiselect)

        const submit = () => {
            if (card.classList.contains('bt-perm-answered')) return;
            card.classList.add('bt-perm-answered');
            const content = {};
            for (const [k, v] of Object.entries(chosen)) {
                content[k] = v instanceof Set ? [...v] : v;
            }
            for (const inp of card.querySelectorAll('input.bt-question-text')) {
                if (inp.value.trim() !== '') content[inp.dataset.fieldKey] = inp.value;
            }
            card.querySelectorAll('button, input').forEach(el => el.disabled = true);
            this.comm.notify({ type: 'question_answer', key: msg.key, content });
        };
        const skip = () => {
            if (card.classList.contains('bt-perm-answered')) return;
            card.classList.add('bt-perm-answered');
            card.querySelectorAll('button, input').forEach(el => el.disabled = true);
            this.comm.notify({ type: 'question_skip', key: msg.key });
        };

        for (const f of selects) {
            if ((f.title || f.description) && !instant) {
                const lbl = document.createElement('div');
                lbl.className = 'bt-question-field-label';
                lbl.textContent = f.title ? `${f.title}${f.description ? ' — ' + f.description : ''}`
                                          : f.description;
                card.appendChild(lbl);
            }
            const row = document.createElement('div');
            row.className = 'bt-permission-options';
            for (const opt of (f.options || [])) {
                const btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'bt-permission-btn';
                btn.textContent = opt.label || opt.value;
                btn.addEventListener('click', () => {
                    if (card.classList.contains('bt-perm-answered')) return;
                    if (f.kind === 'multiselect') {
                        if (!(chosen[f.key] instanceof Set)) chosen[f.key] = new Set();
                        if (chosen[f.key].has(opt.value)) {
                            chosen[f.key].delete(opt.value);
                            btn.classList.remove('bt-perm-chosen');
                        } else {
                            chosen[f.key].add(opt.value);
                            btn.classList.add('bt-perm-chosen');
                        }
                    } else {
                        chosen[f.key] = opt.value;
                        row.querySelectorAll('button').forEach(b =>
                            b.classList.remove('bt-perm-chosen'));
                        btn.classList.add('bt-perm-chosen');
                        if (instant) submit();
                    }
                });
                row.appendChild(btn);
            }
            card.appendChild(row);
        }
        for (const f of texts) {
            const inp = document.createElement('input');
            inp.type = 'text';
            inp.className = 'bt-question-text';
            inp.dataset.fieldKey = f.key;
            inp.placeholder = f.title || 'Other…';
            if (f.description) inp.title = f.description;
            inp.addEventListener('keydown', (e) => {
                if (e.key === 'Enter') submit();
            });
            card.appendChild(inp);
        }
        const actions = document.createElement('div');
        actions.className = 'bt-permission-actions';
        if (!instant || texts.length > 0) {
            const answer = document.createElement('button');
            answer.type = 'button';
            answer.className = 'bt-permission-btn bt-perm-allow';
            answer.textContent = 'Answer';
            answer.addEventListener('click', submit);
            actions.appendChild(answer);
        }
        const skipBtn = document.createElement('button');
        skipBtn.type = 'button';
        skipBtn.className = 'bt-permission-btn bt-question-skip';
        skipBtn.textContent = 'Skip';
        skipBtn.title = 'Skip — let the agent decide on its own';
        skipBtn.addEventListener('click', skip);
        actions.appendChild(skipBtn);
        card.appendChild(actions);

        this.container.insertBefore(card, this.busyEl || null);
        if (this.followMode) this.queueScrollToBottom();
    }

    // Julia called `restart_chat_session!` — the ACP subprocess was killed
    // and a fresh one is coming up. Any UI state attached to the now-dead
    // session must be cleared here, BEFORE the fresh session starts
    // emitting chunks (Julia emits this event before spawning the new
    // client and before re-broadcasting `msgs.count`).
    //
    // Concretely:
    //   • `bt-thinking-active` may be stuck on (process!(::Thought) emit
    //     races against teardown). Drop it.
    //   • `bt-busy-active` is bound to a Julia Observable but its update
    //     may not have shipped yet. Drop it defensively.
    //   • Pending chase rAFs queued from the last stream's `appendChunk`
    //     would otherwise fire AFTER the reset and snap to bottom — yank.
    //   • Any DOM bubble still carrying `bt-stream-active` (the streaming-
    //     class some renderers use) loses it; Julia's orphan sweep
    //     finalised the message itself with the proper `agent_final` /
    //     `thought_final` so the bubble's innerHTML is already updated.
    //   • We deliberately KEEP `nodeById` so a finalising `agent_final`
    //     event Julia emits during sweep (concurrent with this reset)
    //     still finds its node. The next `msgs.count` from Julia re-
    //     bootstraps the virtual scroll; any final-form HTML changes will
    //     land via the resulting range-refetch path.
    onSessionReset() {
        this.thinkingEl?.classList.remove('bt-thinking-active');
        this.busyEl?.classList.remove('bt-busy-active');
        this.busyEl?.classList.remove('bt-busy-suppressed');
        this.cancelPendingScroll();
        for (const node of this.nodeById.values()) {
            node.classList?.remove('bt-stream-active');
        }
    }

    onToolUpdate(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        if (msg.status) {
            const s = node.querySelector('.bt-tool-status');
            if (s) { s.textContent = msg.status; s.className = `bt-tool-status bt-status-${msg.status}`; }
            // Pulsing glow + taskbar slot are gated on the `bt-tool-live`
            // class. Terminal status sheds it; mid-flight gets it (and the
            // shared elapsed ticker with it).
            const live = !(msg.status === 'completed' || msg.status === 'failed');
            node.classList.toggle('bt-tool-live', live);
            if (live) this.ensureElapsedTicker();
            // NOTE: no re-render at terminal status. An eval body is mounted
            // ONCE and its Output text + result embed are Observables the
            // server fills on completion (`eval_result!`). Re-rendering here
            // used to detach the Code section's Monaco container while its
            // async `create` was still resolving — an unhandled "Cannot read
            // properties of null (reading 'parentNode')".
        }
        // A body expanded before the tool had any content holds the server's
        // "(loading…)" placeholder (`render_tool_body`), and nothing replaces it
        // by itself: a long call — bt_julia_wait, bt_wait — expanded while it
        // ran stayed "(loading…)" after it finished. Ask again on each update
        // until the real body is in.
        if (node.collapsable?.expanded && node.querySelector('.bt-tool-body .bt-tool-loading'))
            this.requestBody(node);
        // A Julia run outlived the call that ended this card: it is live again,
        // and its elapsed clock runs on from the start instead of the call's end.
        if (msg.reopen) {
            delete node.dataset.toolFinished;
            node.classList.add('bt-tool-live');
            this.ensureElapsedTicker();
        }
        if (msg.finished_at != null) {
            node.dataset.toolFinished = String(msg.finished_at);
            node.classList.remove('bt-tool-live');
            // Final duration, written once on completion (no timer).
            _writeToolElapsed(node);
        }
        if (msg.title) {
            const t = node.querySelector('.bt-tool-title');
            if (t) t.textContent = msg.title;
        }
        // Bash: the command that ran must be VISIBLE (the visible title is
        // claude's human-readable description; the raw command used to hide in a
        // header tooltip). Render a persistent preview block under the header —
        // the command streams in on a later update for real agents, so create it
        // on demand if createNode didn't have it yet. Keep the tooltip too.
        if (msg.command) {
            const h = node.querySelector('.bt-tool-header');
            if (h) h.title = msg.command;
            let cp = node.querySelector('.bt-cmd-preview');
            if (cp) {
                cp.querySelector('pre').textContent = msg.command;
            } else if (h) {
                cp = document.createElement('div');
                cp.className = 'bt-cmd-preview';
                const pre = document.createElement('pre');
                pre.textContent = msg.command;
                cp.appendChild(pre);
                h.insertAdjacentElement('afterend', cp);
            }
        }
        if (msg.summary != null) {
            const s = node.querySelector('.bt-tool-summary');
            if (s) s.textContent = msg.summary;
        }
        // Eval compact-body mode can arrive LATE (claude streams tool input;
        // the typed extras ride a later update). Flip the Collapsable into
        // editMode BEFORE the expand handling below so the eager-mount takes
        // the compact path.
        if (msg.compact_body === true && node.collapsable && !node.collapsable.editMode) {
            const c = node.collapsable;
            c.editMode = true;
            c.hideBodyOnCollapse = true;
            c.fetchEachExpand = false;
            c.discardOnCollapse = false;
            node.dataset.compactBody = '1';
        }
        // bt_show: the completion update is when we learn it's a "show me
        // this" tool (and its mime). Native-media mode takes precedence:
        // chrome off + body mounted; otherwise auto-expand the pill
        // (idempotent; user can still collapse). A row not in the document
        // yet defers the expand to insertion (see mountDeferred).
        if (msg.show_mime) node.dataset.showMime = msg.show_mime;
        if (this.wantsNative(node)) {
            this.applyNative(node);
        } else if (msg.expand && node.collapsable) {
            if (node.collapsable.editMode) {
                // Edit tools: msg.expand from the server means "the first
                // DiffContent landed — eager-mount the compact Monaco
                // preview, but DON'T flip Collapsable.expanded (we stay in
                // compact size). A click on the header is what expands
                // Monaco; this auto-mount just makes the diff visible
                // without requiring a click.
                // Eval compact bodies (hideBodyOnCollapse) DO flip expanded:
                // their visible-body state IS the expanded state (sections
                // self-clamp), so the arrow must read ▼ while the body shows.
                // The body is fetched once the row is near the view
                // (`requestBody`): a burst of edits streams faster than the
                // reader scrolls, and each diff built far away was only freed
                // again.
                if (node.isConnected) {
                    if (!node.collapsable.loaded) {
                        node.collapsable.loaded = true;
                        this.requestBody(node);
                    }
                    if (node.collapsable.hideBodyOnCollapse)
                        node.collapsable.setExpanded(true);
                } else {
                    node.dataset.btAutoMount = '1';
                    if (node.collapsable.hideBodyOnCollapse)
                        node.dataset.btAutoExpand = '1';
                }
            } else if (node.isConnected) {
                node.collapsable.setExpanded(true);
            } else {
                node.dataset.btAutoExpand = '1';
            }
        }
        // FULL uncollapse (server-typed, e.g. a completed eval whose result is
        // non-empty): mount if needed, then actually flip expanded — unlike
        // `expand`, which in compact-body mode only eager-mounts at compact
        // height.
        if (msg.expand_full && node.collapsable) {
            if (node.isConnected) {
                if (!node.collapsable.loaded) {
                    node.collapsable.loaded = true;
                    this.requestBody(node);
                }
                node.collapsable.setExpanded(true);
            } else {
                node.dataset.btAutoExpand = '1';
            }
        }
        // Eval extras arrive LATE for real agents: claude-agent-acp streams
        // tool input, so the initial tool_call has an empty rawInput and the
        // code/timeout/stoppable fields only ride a later update. Insert the
        // missing affordances on demand (mirrors createNode's wiring).
        const headerEl = node.querySelector('.bt-tool-header');
        const stillLive = !node.dataset.toolFinished &&
            !['completed', 'failed'].includes(
                node.querySelector('.bt-tool-status')?.textContent || '');
        if (msg.timeout_s && headerEl && !headerEl.querySelector('.bt-tool-timeout')) {
            const badge = document.createElement('span');
            badge.className = 'bt-tool-timeout';
            badge.title = 'Soft eval timeout — the call checkpoints with partial output at this cadence';
            badge.textContent = `⏱ ${String(msg.timeout_s)}`;
            const timer = headerEl.querySelector('.bt-tool-timer');
            headerEl.insertBefore(badge, timer || null);
        }
        // Running on ANOTHER worker: the badge sits right after the tool name.
        if (msg.worker && headerEl && !headerEl.querySelector('.bt-tool-worker')) {
            const wb = document.createElement('span');
            wb.className = 'bt-tool-worker';
            wb.title = 'This runs on another worker';
            wb.textContent = `⇢ ${String(msg.worker)}`;
            const title = headerEl.querySelector('.bt-tool-title');
            headerEl.insertBefore(wb, title ? title.nextSibling : null);
        }
        // What a continue / wait waits on can resolve after the card opened
        // (its arguments stream in, its run is announced later): replace the
        // chips whenever an update carries them.
        if (Array.isArray(msg.jumps) && headerEl) {
            headerEl.querySelectorAll('.bt-tool-jump').forEach(b => b.remove());
            const anchor = headerEl.querySelector('.bt-tool-summary');
            anchor?.insertAdjacentHTML('beforebegin', jumpChipsHTML(msg.jumps));
        }
        if (msg.stoppable && headerEl && !headerEl.querySelector('.bt-tool-stop')) {
            const sb = document.createElement('button');
            sb.type = 'button';
            sb.className = 'bt-tool-stop bt-stop-mini' + (msg.dismiss_only ? ' bt-task-dismiss' : '');
            sb.title = msg.dismiss_only ? 'Dismiss task entry (does not stop the agent)' : 'Stop';
            sb.setAttribute('aria-label', msg.dismiss_only ? 'Dismiss task entry' : 'Stop');
            if (msg.dismiss_only) sb.textContent = '×';
            sb.addEventListener('click', (e) => {
                e.stopPropagation();
                this.comm.notify({ type: 'stop_tool', id: msg.id });
            });
            headerEl.insertBefore(sb,
                headerEl.querySelector('.bt-tool-fullwidth') || null);
        }
        // The completed update announced a LIVE result embed (worker-parked
        // value mounted via RemoteRef): give the card bt_show_app's output
        // handling — keep-alive parking on scroll-off (btApp LRU; plain
        // virtualization would close the sub-session and kill e.g. a
        // WGLMakie canvas) and the ⤢ detach button (embed adopted into its
        // own workspace panel; same wiring as createNode's).
        if (msg.live_embed) {
            const became = !node.dataset.btApp;
            node.dataset.btApp = '1';
            // A card already in the page becomes an app here (an eval's result
            // arrives after its card): watched for the keep-alive limit from now
            // on, as `adoptRows` watches a row that came in as one. Before, the
            // apps made in a session were never counted, so the limit that keeps
            // WebGL contexts below the browser's cap held only after a reload.
            if (became && node.__btIdx !== undefined && this.cache.get(node.__btIdx) === node) {
                this.appObserver.observe(node);
                this.touchApp(node.__btIdx);
            }
            if (headerEl && !headerEl.querySelector('.bt-tool-detach')) {
                const db = document.createElement('button');
                db.type = 'button';
                db.className = 'bt-tool-detach';
                db.title = 'Detach to floating window';
                db.textContent = '⤢';
                db.addEventListener('click', (e) => {
                    e.stopPropagation();
                    this.comm.notify({ type: 'detach_app', id: msg.id });
                });
                headerEl.insertBefore(db,
                    headerEl.querySelector('.bt-tool-fullwidth') || null);
            }
        }
        // NOTE: live stdout is NOT pushed from here any more. The Output
        // section binds to the card's `stream_text` Observable, so the server
        // writing it updates the console in place — no wire message, no DOM
        // poke, and the same widget streaming and done.
        // The file path usually arrives with a later update (the initial
        // header has no arguments/content yet) — turn the title into a
        // path link on demand.
        if (msg.editable && msg.edit_path && headerEl) {
            const t = headerEl.querySelector('.bt-tool-title');
            if (t) {
                t.classList.add('bt-path-link');
                t.dataset.path = msg.edit_path;
            }
        }
    }

    // ── Subagent activity feed (Task tool bubbles) ───────────────────────
    // Every parentToolUseId-tagged update is addressed to the subagent that
    // owns it; the server keeps that subagent's WHOLE history and mirrors each
    // step here as a `task_activity` event. The bubble renders them
    // most-recent-last, auto-scrolled, in its own collapsible section between
    // the header and the lazy body (same Collapsable behaviour the tool body /
    // thought sections use). Remounts rebuild from the header's `task_feed`
    // snapshot (createNode), which carries the tail plus the true total.
    //
    // TASK_FEED_ROWS bounds the DOM, not the data: the count shown is the
    // subagent's real step count, which is what the user is asking when they
    // look at a long run.

    onTaskActivity(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node || !msg.entry) return;
        this.upsertTaskFeedEntry(this.ensureTaskFeed(node), msg.entry, msg.total);
    }

    ensureTaskFeed(node) {
        let feed = node.querySelector('.bt-task-feed');
        if (feed) return feed;
        feed = document.createElement('div');
        feed.className = 'bt-task-feed';
        feed.innerHTML = `
            <div class="bt-task-feed-head" data-expanded="false">
                <span class="bt-tool-toggle">▶</span>
                <span class="bt-task-feed-title">subagent activity</span>
                <span class="bt-task-feed-count"></span>
            </div>
            <div class="bt-task-feed-list"></div>`;
        node.querySelector('.bt-tool-header')?.insertAdjacentElement('afterend', feed) ||
            node.appendChild(feed);
        const list = feed.querySelector('.bt-task-feed-list');
        feed._collapsable = new Collapsable(
            feed.querySelector('.bt-task-feed-head'), list,
            { toggleEl: feed.querySelector('.bt-task-feed-head .bt-tool-toggle') });
        // Live task: open by default so the activity is visible as it
        // streams; finished/replayed bubbles start collapsed (a click on
        // the section head re-opens — the list is filled either way).
        if (node.classList.contains('bt-tool-live')) {
            feed._collapsable.setExpanded(true);
        } else {
            list.style.display = 'none';
        }
        return feed;
    }

    upsertTaskFeedEntry(feed, e, total) {
        const list = feed.querySelector('.bt-task-feed-list');
        let row = e.eid != null ?
            list.querySelector(`[data-eid="${CSS.escape(String(e.eid))}"]`) : null;
        if (!row) {
            row = document.createElement('div');
            row.dataset.eid = String(e.eid ?? '');
            list.appendChild(row);
            // Bounded DOM. Matches the server's wire window so a remount and a
            // live run converge on the same rows.
            while (list.children.length > TASK_FEED_ROWS) list.removeChild(list.firstChild);
        }
        row.className = `bt-task-feed-entry bt-task-feed-${e.kind || 'text'}` +
            (e.status ? ` bt-feed-${e.status}` : '');
        row.textContent = e.kind === 'tool' ? `⚙ ${e.label || ''}` : (e.label || '');
        if (e.kind === 'tool' && e.status) row.title = e.status;
        const count = feed.querySelector('.bt-task-feed-count');
        // The subagent's real step count when the server sent one; the rows we
        // are holding otherwise.
        if (count) {
            const n = Number.isFinite(total) ? total : list.children.length;
            feed.dataset.total = String(Math.max(n, Number(feed.dataset.total || 0)));
            count.textContent = feed.dataset.total;
        }
        // Most-recent-last + auto-scroll while the section is open.
        if (feed._collapsable?.expanded) list.scrollTop = list.scrollHeight;
    }

    // ── Message filter (toolbar below the composer) ──────────────────────

    // First occurrence of a filter key → add its show/hide checkbox to the
    // toolbar, checked. Base types sit first in TYPE_ORDER; tool keys go in
    // a trailing "Tools:" group, alphabetical — stable positions either way,
    // independent of arrival order. No-op when the toolbar isn't mounted.
    // Track which filter keys have appeared. The per-tool filter checkboxes
    // are gone (the lens replaces them); we keep this only for the side
    // effect that the FIRST agent reply lets the idle "waiting" line show.
    noteKey(msg) {
        const key = filterKey(msg);
        if (!key || this.seenTypes.has(key)) return;
        this.seenTypes.add(key);
        if (key === 'agent') this.updateWaiting();
    }

    // ── Native media display (bt_show results) ───────────────────────────
    // When "Native Images" / "Native Videos" is on, a bt_show whose mime is
    // image/* / video/* renders bare in the chat flow: the pill's chrome is
    // hidden via the bt-tool-native class and the body is auto-expanded
    // through the normal Collapsable → tool.render path (the server fills
    // the slot with the <img>/<video>). Display-only, per-tab — like the
    // filters.

    // Does the current display-option state want this node native? Keys on
    // the wire show_mime; mimes outside image/video are never native.
    wantsNative(node) {
        const mime = node.dataset.showMime || '';
        if (mime.startsWith('image/')) return this.nativeImages;
        if (mime.startsWith('video/')) return this.nativeVideos;
        return false;
    }

    applyNative(node) {
        node.classList.add('bt-tool-native');
        if (node.isConnected) {
            node.collapsable?.setExpanded(true);
        } else {
            // Not in the document yet (a row being built): defer the expand
            // to insertion so the tool.render reply has a slot to mount into.
            node.dataset.btAutoExpand = '1';
        }
    }

    removeNative(node) {
        node.classList.remove('bt-tool-native');
        delete node.dataset.btAutoExpand;
        node.collapsable?.setExpanded(false);   // discardOnCollapse frees the body
    }

    // Flip one media class ('image/' or 'video/') and re-depict every cached
    // node of that class; the other class is untouched.
    setNativeMedia(prefix, on) {
        if (prefix === 'image/') this.nativeImages = on;
        else                     this.nativeVideos = on;
        for (const node of this.cache.values()) {
            if (!(node.dataset.showMime || '').startsWith(prefix)) continue;
            on ? this.applyNative(node) : this.removeNative(node);
        }
        this.ensureWindow();
    }

    // Toggle a key's visibility: inline display on every matching row (an
    // open key-set, per-tool keys, rules out static CSS classes). Rows
    // created later pick up the current state in `makeRow`.
    setKeyHidden(key, hidden) {
        // Hold the read position across the toggle: matching rows collapse to
        // or expand from 0px, which would move what the reader sees. The
        // anchor is the top-visible row that SURVIVES the toggle.
        const anchor = this.followMode ? null : this.captureAnchor(key);
        this.hiddenTypes[hidden ? 'add' : 'delete'](key);
        for (const [idx, node] of this.cache) {
            if (node.dataset.filterKey === key) this.applyVisibility(idx, node);
        }
        // Hiding the agent stream also hides the idle "waiting" line that
        // would otherwise dangle under messages that aren't there.
        if (key === 'agent') this.updateWaiting();
        if (this.followMode) this.queueScrollToBottom();
        else this.restoreAnchor(anchor);
        // Already anchored: the row observer must not correct for it again.
        this.syncRowHeights();
        this.ensureWindow();
    }

    // The idle "waiting for your next instruction" line only makes sense
    // under an agent reply: keep it off for empty chats (nothing was asked
    // yet) and while the Agent filter hides the messages it would sit
    // under. The CSS show-rule requires `bt-waiting-on` on top of the
    // not-busy sibling condition, so busy/idle switching stays pure CSS.
    updateWaiting() {
        if (!this.waitingEl) return;
        const on = this.seenTypes.has('agent') && !this.hiddenTypes.has('agent');
        this.waitingEl.classList.toggle('bt-waiting-on', on);
    }

    // ── DOM node creation ────────────────────────────────────────────────

    createNode(msg) {
        const div = document.createElement('div');
        const fkey = filterKey(msg);
        div.dataset.filterKey = fkey;       // filter identity: type, or tool:<name>
        this.noteKey(msg);                  // first occurrence → toolbar checkbox
        switch (msg.type) {
            case 'user':
                div.className = 'bt-user-msg';
                if (msg.queued) {
                    div.classList.add('bt-queued');
                    // The badge text lives in an attribute so the position can
                    // be re-numbered in place as the queue drains.
                    div.dataset.queueLabel = queueLabel(msg.queue_pos);
                }
                // Yolo auto-continue nudge: dim/system-styled, not a real submit.
                if (msg.auto) div.classList.add('bt-user-msg-auto');
                div.textContent = msg.text;
                // Attached images render inline (the server split the raw
                // "[attached files …]" suffix into this list — see
                // msg_to_dict(::UserMsg)). Click → the shared lightbox. A file
                // the route can no longer serve (project moved, cleanup) falls
                // back to its name instead of a broken-image icon.
                if (Array.isArray(msg.attachments) && msg.attachments.length) {
                    const gallery = document.createElement('div');
                    gallery.className = 'bt-user-attachments';
                    for (const a of msg.attachments) {
                        if (a.kind === 'file') {
                            // Not an image: its name, opening the file (a PDF
                            // in the browser, anything else as a download).
                            const link = document.createElement('a');
                            link.className = 'bt-user-att-file';
                            link.href = a.url;
                            link.target = '_blank';
                            link.rel = 'noopener';
                            link.textContent = a.name.replace(/^\d{4}-\d{2}-\d{2}_\d{6}_[0-9a-f]{8}_/, '');
                            link.title = a.name;
                            link.addEventListener('click', e => e.stopPropagation());
                            gallery.appendChild(link);
                            continue;
                        }
                        const img = document.createElement('img');
                        img.className = 'bt-user-att-img';
                        img.src = a.url;
                        img.alt = a.name || 'attachment';
                        img.dataset.attachmentName = a.name;
                        img.loading = 'lazy';
                        img.addEventListener('click', e => { e.stopPropagation(); openLightbox(img); });
                        img.addEventListener('error', () => {
                            // In the thumbnail's box (same height, see the CSS),
                            // so a picture that is gone does not resize the row.
                            const miss = document.createElement('span');
                            miss.className = 'bt-user-att-missing';
                            miss.textContent = a.name || 'attachment';
                            img.replaceWith(miss);
                        }, { once: true });
                        const wrap = document.createElement('div');
                        wrap.className = 'bt-media-wrap';
                        wrap.appendChild(img);
                        const actions = document.createElement('div');
                        actions.className = 'bt-media-actions';
                        const enlarge = document.createElement('button');
                        enlarge.type = 'button';
                        enlarge.className = 'bt-media-action bt-media-enlarge';
                        enlarge.title = 'Enlarge'; enlarge.textContent = '⤢';
                        enlarge.addEventListener('click', e => { e.stopPropagation(); openLightbox(img); });
                        const choose = document.createElement('button');
                        choose.type = 'button';
                        choose.className = 'bt-media-action bt-media-chat-icon';
                        choose.title = 'Set as chat icon'; choose.textContent = '▣';
                        choose.setAttribute('aria-label', choose.title);
                        actions.append(enlarge, choose);
                        wrap.appendChild(actions);
                        gallery.appendChild(wrap);
                    }
                    div.appendChild(gallery);
                }
                break;
            case 'agent':
                div.className = 'bt-agent-msg';
                // Carry the id so `onAgentFinal`'s DOM fallback can find this
                // bubble by id when the node is missing from `nodeById`.
                if (msg.id) div.dataset.msgId = msg.id;
                if (msg.streaming) {
                    const span = document.createElement('span');
                    span.className = 'bt-stream-text';
                    // Seed with whatever the first chunk sent (may be ""):
                    // a viewer that joined mid-stream needs to see this
                    // initial text immediately, not wait for the next chunk.
                    if (msg.text) span.textContent = msg.text;
                    div.appendChild(span);
                } else {
                    div.innerHTML = msg.html || '';
                    linkifyPaths(div);
                    decorateCodeBlocks(div);
                }
                break;
            case 'thought': {
                div.className = 'bt-thought-msg';
                div.innerHTML = this.thoughtHTML(msg);
                const id = msg.id;
                // Native <details> host, lazy body loaded once via thought.render.
                div.collapsable = new Collapsable(
                    div.querySelector('.bt-thought-summary'),
                    div.querySelector('.bt-thought-body'),
                    { native: true,
                      onExpand: () => this.comm.notify({type: 'thought.render', id}) });
                if (msg.html) div.collapsable.fill(msg.html);
                break;
            }
            case 'tool': {
                div.className = 'bt-tool-msg';
                div.innerHTML = this.toolHTML(msg);
                // Live Bonito/WGLMakie embeds get kept alive (display:none) on
                // scroll-off instead of removed — see the keep-alive LRU.
                if (msg.kind === 'bonito_app' || msg.live_embed) div.dataset.btApp = '1';
                // Live state + start/finish time live on the message node.
                // Status `pending` / `in_progress` count as live until a
                // terminal update flips the class via `onToolUpdate`; the
                // final duration is written from these attrs on completion.
                if (msg.id) div.dataset.msgId = msg.id;
                if (msg.started_at != null)
                    div.dataset.toolStarted = String(msg.started_at);
                if (msg.finished_at != null)
                    div.dataset.toolFinished = String(msg.finished_at);
                // History replay / late mount of an already-finished pill:
                // write its final duration now (event-driven, no timer).
                _writeToolElapsed(div);
                // Server-decided opt-in for the taskbar slot. Background bash
                // / Task land here; regular tools don't.
                const liveTool = !(msg.status === 'completed' || msg.status === 'failed') &&
                                  msg.finished_at == null;
                if (liveTool) {
                    div.classList.add('bt-tool-live');
                    this.ensureElapsedTicker();
                }
                const id = msg.id;
                // Click-header host; the body is re-rendered (Monaco etc.) on
                // every expand via tool.render → dom_in_js, and discarded on
                // collapse so the editors are freed.
                // Edit tools render their compact Monaco diff under the
                // header eagerly (no click required). The Collapsable's
                // editMode keeps the body mounted across collapse — toggle
                // just calls Monaco.setMaxHeight to swap compact↔full.
                // Eval tools reuse editMode's KEEP-MOUNTED semantics via
                // `compact_body` (server-typed) but not its height games:
                // their body shows all sections (Code / Output each clamped
                // to ~4 lines SECTION-side, result embed unclamped) and the
                // header toggle plainly hides/shows the mounted body.
                const compactBody = msg.kind === 'edit' || msg.compact_body === true;
                if (msg.compact_body === true) div.dataset.compactBody = '1';
                // An editor in the body died with its Bonito session while
                // still in this row: render the body again (bodyDied).
                div.addEventListener('monaco-editor-disposed', () => this.bodyDied(div));
                // The heights its body rendered at, by width (`body_h`,
                // measured_sizes.jl), updated as it reports new ones.
                div.__btBodyH = msg.body_h || null;
                // A body that is one picture of known size (`media`, [w, h]):
                // what its placeholder reserves until a height is measured.
                div.__btMedia = msg.media || null;
                div.__btMediaExtra = msg.media_extra || 0;
                div.collapsable = new Collapsable(
                    div.querySelector('.bt-tool-header'),
                    div.querySelector('.bt-tool-body'),
                    { toggleEl: div.querySelector('.bt-tool-toggle'),
                      editMode: compactBody,
                      hideBodyOnCollapse: msg.compact_body === true,
                      fetchEachExpand: !compactBody, discardOnCollapse: !compactBody,
                      reserve: () => this.bodyReserve(div),
                      onToggle: (expanded) => this.expandState.set(id, expanded),
                      onExpand: () => this.requestBody(div) });
                // Subagent Task: rebuild the live activity feed from the
                // header's snapshot (live growth rides task_activity events).
                if (Array.isArray(msg.task_feed) && msg.task_feed.length) {
                    const feed = this.ensureTaskFeed(div);
                    for (const e of msg.task_feed)
                        this.upsertTaskFeedEntry(feed, e, msg.task_feed_total);
                }
                // Detach (bonito_app only): pop the embed into the floating
                // window. Lives on the ⤢ header button — the conventional "open
                // in a window" glyph, and where users expect detach. Routed
                // through the comm (→ DetachAppCommand → pane.detach_app →
                // PopupController); no window-global controller.
                const detachBtn = div.querySelector('.bt-tool-detach');
                if (detachBtn) detachBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    this.comm.notify({ type: 'detach_app', id });
                });
                // Full-chat-width toggle: extends the pill to span the whole
                // message column so wide content (the result embed, a plot, a
                // table, a long diff) gets the room it needs. Must NOT toggle
                // expand/collapse, so stopPropagation.
                const wideBtn = div.querySelector('.bt-tool-fullwidth');
                if (wideBtn) wideBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    const active = div.classList.toggle('bt-tool-wide-active');
                    wideBtn.textContent = active ? '«' : '»';
                    wideBtn.title = active ?
                        'Collapse to default width' : 'Expand to full chat width';
                });
                // Per-pill interrupt (eval family). Routes through the same
                // stop_tool command the taskbar uses; the server dispatches
                // per tool kind (eval → SIGINT the worker's eval process).
                const stopBtn2 = div.querySelector('.bt-tool-stop');
                if (stopBtn2) stopBtn2.addEventListener('click', (e) => {
                    e.stopPropagation();
                    this.comm.notify({ type: 'stop_tool', id });
                });
                // The show's mime (bt_show results) — the native-media
                // toggles key on it.
                if (msg.show_mime) div.dataset.showMime = msg.show_mime;
                if (this.wantsNative(div)) {
                    // Native display: chrome off + body auto-mounted on
                    // first insertion.
                    div.classList.add('bt-tool-native');
                    div.dataset.btAutoExpand = '1';
                } else if (msg.expand || msg.expand_full) {
                    // Auto-expand (bt_show refs, eval eager-mount /
                    // expand_full) — DEFERRED until the node first enters the
                    // document (mountDeferred). Rows are built before they
                    // are inserted; expanding then fired tool.render whose
                    // dom_in_js reply found no slot in the document — the
                    // body stayed on "loading…" forever. Same split as onToolUpdate's
                    // detached fallback: editMode bodies need the explicit
                    // MOUNT flag (their applyExpanded never lazy-fetches),
                    // plus the expanded flip for expand_full / evals whose
                    // visible-body state IS the expanded state.
                    if (div.collapsable.editMode) {
                        div.dataset.btAutoMount = '1';
                        if (msg.expand_full || div.collapsable.hideBodyOnCollapse)
                            div.dataset.btAutoExpand = '1';
                    } else {
                        div.dataset.btAutoExpand = '1';
                    }
                }
                // What the reader did to it last wins over the default.
                const mine = this.expandState.get(id);
                if (mine === true) {
                    if (div.collapsable.editMode) div.dataset.btAutoMount = '1';
                    div.dataset.btAutoExpand = '1';
                } else if (mine === false) {
                    delete div.dataset.btAutoExpand;
                }
                break;
            }
            case 'plan': {
                div.className = 'bt-plan-msg';
                div.innerHTML = msg.html || '';
                // TodoListMsg absorbs subsequent updates by id — every later
                // emit overwrites the same node's html. The live flag (and
                // started_at) drive the pulse + taskbar slot.
                if (msg.id) div.dataset.msgId = msg.id;
                if (msg.started_at != null)
                    div.dataset.planStarted = String(msg.started_at);
                if (msg.finished_at != null)
                    div.dataset.planFinished = String(msg.finished_at);
                if (msg.summary)
                    div.dataset.planSummary = msg.summary;
                if (msg.live) div.classList.add('bt-plan-live');
                break;
            }
            case 'summary': {
                // Centered separator block for a `/compact` summary — NOT a
                // user/agent bubble. Streaming case shows a tiny placeholder
                // until `summary_final` lands; the persisted-replay case ships
                // the html directly in `msg.html`.
                div.className = 'bt-summary-msg';
                const inner = document.createElement('div');
                inner.className = 'bt-summary-body';
                if (msg.streaming && !msg.html) {
                    inner.textContent = 'Session continued — summary loading…';
                } else {
                    inner.innerHTML = msg.html || '';
                }
                div.appendChild(inner);
                break;
            }
        }
        // A node created while its filter key is unchecked starts hidden —
        // scrollback fetches and live appends respect the active filter.
        if (this.hiddenTypes.has(fkey)) div.style.display = 'none';
        return div;
    }

    // Clear the "queued" badge from the promoted user bubble. Targeted by
    // STORE INDEX into the node cache — the bubble may be virtually
    // scrolled out of the DOM, and a DOM-only lookup would leave its cached
    // node wearing a stale QUEUED badge forever (the "chat looks wedged"
    // bug). Falls back to oldest-in-DOM for events without an index.
    unqueueUser(msg) {
        if (Number.isInteger(msg.idx)) {
            const node = this.cache.get(msg.idx);
            if (node) { node.classList.remove('bt-queued'); return; }
            // No cached node yet: nothing stale to clear — a later render
            // builds it from the (already-promoted) store dict.
            return;
        }
        const q = this.container.querySelector('.bt-user-msg.bt-queued');
        if (q) q.classList.remove('bt-queued');
    }

    // Re-number the bubbles still waiting after one was promoted, so "3rd in
    // queue" counts down instead of going stale. Same store-index targeting as
    // unqueueUser — a virtually-scrolled-out bubble must not keep a wrong
    // position in its cached node.
    requeueUser(msg) {
        for (const it of (msg.items || [])) {
            const node = this.cache.get(it.idx);
            // An explicit `label` overrides the position wording — stop uses it
            // to mark a dropped bubble "not sent" while keeping it dimmed, so
            // the text is still there to copy but clearly never went out.
            if (node) node.dataset.queueLabel = it.label || queueLabel(it.pos);
        }
    }

    onSummaryFinal(msg) {
        // By id through the node cache — a DOM-only lookup missed summaries
        // the virtual scroll currently holds detached, leaving the cached
        // node on "summary loading…" forever.
        const node = msg.id ? this.nodeById.get(msg.id) : null;
        if (node) {
            const body = node.querySelector('.bt-summary-body');
            if (body) { body.innerHTML = msg.html || ''; return; }
        }
        // Fallback (id-less event from an older server): last summary node
        // in the DOM, when the block ends at the newest message (else the
        // last one in the page is an old one).
        if (!this.atTail()) return;
        const nodes = this.container.querySelectorAll('.bt-summary-msg .bt-summary-body');
        const tgt = nodes[nodes.length - 1];
        if (tgt) tgt.innerHTML = msg.html || '';
    }

    thoughtHTML(msg) {
        const summary = msg.summary || 'Show thinking';
        return `<details class="bt-thought-details" data-thought-id="${escapeAttr(msg.id || '')}">
            <summary class="bt-thought-summary">💭 ${escapeHTML(summary)}</summary>
            <div class="bt-thought-body">${msg.html || ''}</div>
        </details>`;
    }

    toolHTML(msg) {
        const statusCls = `bt-tool-status bt-status-${msg.status || 'pending'}`;
        // MCP tools carry a `server` (e.g. "bonitoagents"); show it as a dim
        // badge before the (already prefix-stripped) tool name.
        const server = msg.server ?
            `<span class="bt-tool-server">${escapeHTML(msg.server)}</span>` : '';
        // Eval-family extras (bt_julia_eval & friends):
        //   • `timeout_s` — the soft-checkpoint cadence, always visible so
        //     "why did this come back after 30s" answers itself.
        //   • `code` — the source being executed; painted as a compact live
        //     preview under the header WHILE the eval runs (the completed
        //     body's Monaco "Code" section replaces it — see onToolUpdate).
        //   • `stoppable` — the ⊗ interrupt button (CSS shows it only while
        //     the pill is live).
        const timeoutBadge = msg.timeout_s ?
            `<span class="bt-tool-timeout" title="Soft eval timeout — the call checkpoints with partial output at this cadence">⏱ ${escapeHTML(String(msg.timeout_s))}</span>` : '';
        //   • `worker` — the OTHER worker the eval runs on (bt_julia_eval
        //     worker=…): a filled badge right after the tool name, so code
        //     running on a different machine is visible without reading the card.
        const workerBadge = msg.worker ?
            `<span class="bt-tool-worker" title="This runs on another worker">⇢ ${escapeHTML(String(msg.worker))}</span>` : '';
        //   • `jumps` — the evals a continue / wait waits on, as ↑ chips that
        //     bring each one's card into view (see jumpToMessage).
        const jumpChips = jumpChipsHTML(msg.jumps);
        const stopBtn = msg.stoppable ?
            `<button class="bt-tool-stop bt-stop-mini${msg.dismiss_only ? ' bt-task-dismiss' : ''}" type="button"
                     title="${msg.dismiss_only ? 'Dismiss task entry (does not stop the agent)' : 'Stop'}"
                     aria-label="${msg.dismiss_only ? 'Dismiss task entry' : 'Stop'}">${msg.dismiss_only ? '×' : ''}</button>` : '';
        // File-path link: when the tool identifies a file (the server ships
        // `edit_path`), its TITLE becomes a clickable link that opens the
        // file in the plotpane editor — same affordance as every other path
        // link in the chat (diff headers, search hits, paths in messages).
        // One delegated container listener handles all of them.
        const titleLink = msg.edit_path
            ? ` bt-path-link" data-path="${escapeAttr(msg.edit_path)}` : '';
        const live = !(msg.status === 'completed' || msg.status === 'failed') &&
                     msg.finished_at == null;
        // (The old <pre> eval code preview is gone: eval cards mount their
        // BODY compactly instead — the real Monaco Code editor capped at ~4
        // lines via Collapsable compact-body mode, see `msg.compact_body`.)
        // "What ran", ALWAYS visible (persists past completion — there's no Monaco
        // "Code" section afterwards) and never hidden in a tooltip: the bash command,
        // OR a control MCP tool's action (interrupt/restart/list its target session).
        // A tool ships either `code` (eval preview above) or `command` (this).
        const cmdPreview = msg.command ? `
            <div class="bt-cmd-preview"><pre>${escapeHTML(msg.command)}</pre></div>` : '';
        // Elapsed timer — ticks at 1Hz while the pill is LIVE (see
        // ensureElapsedTicker; running evals sit at "pending" for the whole
        // MCP call, so this is how a user tells a hang from slow work) and
        // freezes at the final duration on the terminal update
        // (`_writeToolElapsed`).
        // The full-width toggle lives IN the header (right edge, after the
        // status pill) — an overlay button floating over the body covered
        // the actual app/diff content. CSS reveals it only while the body
        // is expanded (nothing to widen on a collapsed header).
        return `
            <div class="bt-tool-header" data-expanded="false"${
                msg.command ? ` title="${escapeAttr(msg.command)}"` : ''}>
                <span class="bt-tool-toggle">▶</span>
                <span class="bt-tool-kind">${msg.icon || '⚙'}</span>
                ${server}
                <span class="bt-tool-title${titleLink}">${escapeHTML(msg.title || '')}</span>
                ${workerBadge}
                ${jumpChips}
                <span class="bt-tool-summary">${escapeHTML(msg.summary || '')}</span>
                ${timeoutBadge}
                <span class="bt-tool-timer"></span>
                <span class="${statusCls}">${escapeHTML(msg.status || '')}</span>
                ${stopBtn}
                ${(msg.kind === 'bonito_app' || msg.live_embed)
                    ? `<button class="bt-tool-detach" type="button"
                              title="Detach to floating window">⤢</button>`
                    : ''}
                <button class="bt-tool-fullwidth" type="button"
                        title="Expand to full chat width">»</button>
            </div>
            ${cmdPreview}
            <div class="bt-tool-body" data-tool-id="${escapeAttr(msg.id || '')}"></div>`;
    }

    // ── Live tools / todos: pulse + timer + taskbar ──────────────────────
    // Live-pill UX: the shared 1Hz `ensureElapsedTicker` writes each live
    // pill's `.bt-tool-timer` (> 1s only); the taskbar is a Julia-rendered
    // component wired in `setupLiveTicker` (click-to-scroll only here).
    // No per-pill timers — DOM is the source of truth, scanned once a second
    // while anything is live.
    onPlanUpdate(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        if (msg.html != null) node.innerHTML = msg.html;
        if (msg.started_at != null)
            node.dataset.planStarted = String(msg.started_at);
        if (msg.finished_at != null) {
            node.dataset.planFinished = String(msg.finished_at);
            node.classList.remove('bt-plan-live');
        } else if (msg.live === false) {
            node.classList.remove('bt-plan-live');
        } else if (msg.live === true) {
            node.classList.add('bt-plan-live');
        }
        if (msg.summary) node.dataset.planSummary = msg.summary;
    }

    setupLiveTicker() {
        // The taskbar itself is a Julia-rendered Bonito component (see
        // taskbar.jl) — state-first, untouched by virtual scrolling. The
        // chat module only contributes click-to-scroll: a slot click jumps
        // back to the source pill IF it's currently rendered. (The ⊗ stop
        // is the component's own observable.)
        this.taskbarEl = (this.app || this.container.closest('.bt-app') ||
                          this.container.parentElement).querySelector('.bt-taskbar');
        if (this.taskbarEl) {
            // Live-todo collapse state lives HERE, on the persistent
            // .bt-taskbar element: the slots inside are 1 Hz KeyedList
            // re-renders (static snapshots), so state on them would be wiped
            // every tick. Default: collapsed on narrow panes (a long plan
            // card buried the whole chat on phones), expanded elsewhere; the
            // ▾ toggle persists the user's choice browser-wide.
            const storedTodo = storage.get('bt-todo-collapsed');
            const paneW = this.container.closest('.bt-chatpane')?.clientWidth
                       ?? window.innerWidth;
            this.taskbarEl.classList.toggle('bt-todo-collapsed',
                storedTodo != null ? storedTodo === '1' : paneW < 660);
            this.onTaskbarClick = (ev) => {
                if (ev.target.closest('.bt-taskbar-todo-toggle')) {
                    const c = this.taskbarEl.classList.toggle('bt-todo-collapsed');
                    storage.set('bt-todo-collapsed', c ? '1' : '0');
                    return;
                }
                if (ev.target.closest('.bt-taskbar-slot-stop')) return;
                const slot = ev.target.closest('.bt-taskbar-slot');
                if (!slot) return;
                this.jumpToMessage(parseInt(slot.dataset.msgIndex ?? '-1', 10),
                                   slot.dataset.taskId);
            };
            this.taskbarEl.addEventListener('click', this.onTaskbarClick);
        }
        // The in-chat elapsed ticker lives in `ensureElapsedTicker` below —
        // started on demand when a live pill appears, self-stopping when the
        // last one finishes. (The taskbar keeps its own Julia clock.)
    }

    // Bring message `idx` (its 0-based store index) into view and light up its
    // node (`id`), so the eye lands on it: from the block when it holds the
    // row, else with a new block around it. Used by the task bar's rows and
    // by the ↑ chips of cards that wait on an eval. A message a lens filters
    // out is not in the sequence, so the lens goes first.
    jumpToMessage(idx, id) {
        if (!Number.isInteger(idx) || idx < 0 || idx >= this.totalCount) return;
        if (this.seqPos(idx) < 0) {
            this.lensClearAll();
            this.pendingJump = { idx, id };     // applied once the lens result lands
            return;
        }
        this.jumpToPosition(this.seqPos(idx), { flashId: id || null, offset: 60 });
    }

    // One shared 1Hz interval ticks the inline `.bt-tool-timer` of every
    // LIVE pill. Self-managing: call whenever a pill becomes live; the
    // interval clears itself once no live pill exists anywhere (checked
    // against `nodeById`, not the container — a live pill the virtual
    // scroll has DETACHED must keep the ticker alive so it shows the right
    // time the moment it scrolls back in). Ticks only write a span's
    // textContent (no height change → no scroll perturbation), and the
    // value is recomputed from `toolStarted` each tick, so the 1s cadence
    // is purely cosmetic (background throttling clamps intervals to 1Hz —
    // exactly this rate).
    ensureElapsedTicker() {
        if (this.elapsedTimer) return;
        this.elapsedTimer = setInterval(() => {
            let any = false;
            for (const node of this.nodeById.values()) {
                if (!node.classList || !node.classList.contains('bt-tool-live')) continue;
                any = true;
                if (node.isConnected) _writeToolElapsed(node);
            }
            if (!any) {
                clearInterval(this.elapsedTimer);
                this.elapsedTimer = null;
            }
        }, 1000);
    }

    // ── Lens search bar (header) ─────────────────────────────────────────
    // Builds: [ input (with autocomplete) | save ] [ search ]  + saved chips.
    // The query is parsed + run SERVER-SIDE (lens.query → lens.result with the
    // visible index set + actions); this side just renders the bar, drives
    // autocomplete from the chat vocabulary, and applies the result.
    // The lens bar is PILL-based: each committed clause renders as a pill, an
    // inline input composes the next clause. After a `/key` is picked the
    // autocomplete switches from KEYS to ACTIONS (expand/collapse) + OPERATORS
    // (＋ include / − exclude), each starting the next clause. The serialized
    // query (pills + the in-progress tail) is what runs server-side.
    setupLens() {
        const host = (this.app || this.container.closest('.bt-app') ||
                      this.container.parentElement).querySelector('.bt-lens-bar');
        if (!host) return;
        this.lensBarEl = host;
        this.lensClauses = [];          // committed: [{sign:'+'|'-', text}]
        this.lensPendingSign = '+';     // sign for the clause being composed
        host.innerHTML = `
            <div class="bt-lens-row">
                <div class="bt-lens-field">
                    <span class="bt-lens-pills"></span>
                    <input class="bt-lens-input" type="text" spellcheck="false"
                           placeholder="/ to pick a type, or type to search everything" />
                    <button class="bt-lens-save" type="button" title="Save lens">★</button>
                    <div class="bt-lens-autocomplete" hidden></div>
                </div>
                <button class="bt-lens-go" type="button" title="Apply lens">Search</button>
                <button class="bt-lens-clear" type="button" title="Clear lens" hidden>✕</button>
            </div>
            <div class="bt-lens-chips"></div>`;
        this.lensInput = host.querySelector('.bt-lens-input');
        this.lensAC    = host.querySelector('.bt-lens-autocomplete');
        this.lensPills = host.querySelector('.bt-lens-pills');
        this.lensChips = host.querySelector('.bt-lens-chips');
        const go    = host.querySelector('.bt-lens-go');
        const save  = host.querySelector('.bt-lens-save');
        const clear = host.querySelector('.bt-lens-clear');
        this.lensClearBtn = clear;

        const apply = () => { this.lensCommitTail(); this.hideLensAutocomplete();
                              this.runLens(this.lensSerialize()); };
        go.addEventListener('click', apply);
        save.addEventListener('click', () => {
            this.lensCommitTail();
            const q = this.lensSerialize();
            if (q) this.comm.notify({ type: 'lens.save', q });
        });
        clear.addEventListener('click', () => this.lensClearAll());
        this.lensInput.addEventListener('input', () => {
            this.lensAutoCommitOnOperator();
            this.updateLensAutocomplete();
        });
        this.lensInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault();
                if (!this.acceptLensAutocomplete()) apply(); }
            else if (e.key === 'Escape') this.hideLensAutocomplete();
            else if (e.key === 'ArrowDown' || e.key === 'ArrowUp')
                this.moveLensAutocomplete(e.key === 'ArrowDown' ? 1 : -1, e);
            else if (e.key === 'Backspace' && this.lensInput.value === '' &&
                     this.lensClauses.length) { e.preventDefault(); this.lensPopPill(); }
        });
        // Click-away closes the autocomplete. (Document-level: lazy
        // self-destroy backstop, same as the ESC handler.)
        this.onLensDocClick = (e) => {
            if (!this.container.isConnected) { this.lazyDestroy(); return; }
            if (!host.contains(e.target)) this.hideLensAutocomplete();
        };
        document.addEventListener('click', this.onLensDocClick);
        this.renderLensPills();
        this.renderSavedLenses();
    }

    // ── Clause model: parse / serialize / split ───────────────────────────
    // Light client-side parse of one clause's text, for the pill label + to
    // know whether a structured key is present (mirrors lens.jl parse_clause).
    lensClauseParts(text) {
        text = (text || '').trim();
        let sign = '+';
        if (text.startsWith('!') || text.startsWith('-')) { sign = '-'; text = text.slice(1).trim(); }
        let key = '', rest = text;
        if (text.startsWith('/')) {
            const m = text.slice(1).match(/^([\w.@*-]+)\s*:?\s*(.*)$/);
            if (m) { key = m[1]; rest = m[2]; } else { rest = text.slice(1); }
        }
        let action = null; const qparts = [];
        const re = /"([^"]*)"|(\S+)/g; let mm;
        while ((mm = re.exec(rest))) {
            if (mm[1] !== undefined) qparts.push(mm[1]);
            else if (mm[2] === 'expand' || mm[2] === 'collapse') action = mm[2];
            else qparts.push(mm[2]);
        }
        return { sign, key, action, query: qparts.join(' ') };
    }

    // Serialize committed clauses to a query string (sign carried by the join
    // operator; first exclude clause keeps a leading `!`). Parsed back verbatim
    // by lens.jl split_lens_clauses.
    lensSerialize() {
        return this.lensClauses.map((c, i) => i === 0
            ? (c.sign === '-' ? '!' + c.text.replace(/^[!-]\s*/, '') : c.text)
            : (c.sign === '-' ? '- ' + c.text.replace(/^[!-]\s*/, '') : '+ ' + c.text)
        ).join(' ').trim();
    }

    // Split a saved query back into clauses (mirrors lens.jl split_lens_clauses).
    lensSplit(str) {
        const segs = []; let buf = '', inq = false, sign = '+';
        for (let i = 0; i < str.length; i++) {
            const c = str[i];
            if (c === '"') { inq = !inq; buf += c; }
            else if (!inq && (c === '+' || c === '-') &&
                     i > 0 && /\s/.test(str[i - 1]) &&
                     i < str.length - 1 && /\s/.test(str[i + 1])) {
                segs.push({ sign, text: buf.trim() });
                sign = c === '-' ? '-' : '+'; buf = '';
            } else buf += c;
        }
        segs.push({ sign, text: buf.trim() });
        return segs.filter(s => s.text !== '');
    }

    // ── Pill commit / edit / remove ───────────────────────────────────────
    lensCommitTail() {
        const t = this.lensInput.value.trim();
        if (t) this.lensClauses.push({ sign: this.lensPendingSign, text: t });
        this.lensInput.value = '';
        this.lensPendingSign = '+';
        this.renderLensPills();
    }

    // Auto-commit when the user types a top-level ` + ` / ` - ` (quote-balanced):
    // the operator finalizes the current clause and opens the next.
    lensAutoCommitOnOperator() {
        const v = this.lensInput.value;
        const m = v.match(/^(.*\S)\s+([+-])\s$/);
        if (!m) return;
        if (((v.match(/"/g) || []).length) % 2 !== 0) return;   // inside a quote
        this.lensClauses.push({ sign: this.lensPendingSign, text: m[1].trim() });
        this.lensPendingSign = m[2] === '-' ? '-' : '+';
        this.lensInput.value = '';
        this.renderLensPills();
    }

    lensClearAll() {
        this.lensClauses = []; this.lensPendingSign = '+';
        this.lensInput.value = '';
        this.renderLensPills();
        this.hideLensAutocomplete();
        this.runLens('');
    }

    lensRemovePill(i) {
        this.lensClauses.splice(i, 1);
        this.renderLensPills();
        this.runLens(this.lensSerialize());
    }

    lensEditPill(i) {
        this.lensCommitTail();                 // don't lose the in-progress tail
        const c = this.lensClauses.splice(i, 1)[0];
        this.lensInput.value = c.text;
        this.lensPendingSign = c.sign;
        this.renderLensPills();
        this.lensInput.focus();
        const n = this.lensInput.value.length; this.lensInput.setSelectionRange(n, n);
        this.updateLensAutocomplete();
    }

    lensPopPill() {
        const c = this.lensClauses.pop();
        if (!c) return;
        this.lensInput.value = c.text;
        this.lensPendingSign = c.sign;
        this.renderLensPills();
        const n = this.lensInput.value.length; this.lensInput.setSelectionRange(n, n);
        this.updateLensAutocomplete();
    }

    lensLoadQuery(q) {
        this.lensClauses = this.lensSplit(q);
        this.lensPendingSign = '+';
        this.lensInput.value = '';
        this.renderLensPills();
        this.runLens(q);
    }

    renderLensPills() {
        if (!this.lensPills) return;
        this.lensPills.innerHTML = '';
        this.lensClauses.forEach((c, i) => {
            const p = this.lensClauseParts(c.text);
            const sign = (c.sign === '-' || p.sign === '-') ? '-' : '+';
            const pill = document.createElement('span');
            pill.className = 'bt-lens-pill' + (sign === '-' ? ' bt-lens-pill-ex' : '');
            let html = sign === '-' ? `<span class="bt-lens-pill-sign">−</span>` : '';
            html += `<span class="bt-lens-pill-key">${escapeHTML(p.key || 'text')}</span>`;
            if (p.query)  html += `<span class="bt-lens-pill-q">“${escapeHTML(p.query)}”</span>`;
            if (p.action) html += `<span class="bt-lens-pill-act">${escapeHTML(p.action)}</span>`;
            html += `<span class="bt-lens-pill-x" title="Remove">✕</span>`;
            pill.innerHTML = html;
            pill.querySelector('.bt-lens-pill-x').addEventListener('mousedown', (e) => {
                e.preventDefault(); e.stopPropagation(); this.lensRemovePill(i); });
            pill.addEventListener('mousedown', (e) => {
                if (e.target.classList.contains('bt-lens-pill-x')) return;
                e.preventDefault(); this.lensEditPill(i); });
            this.lensPills.appendChild(pill);
        });
        this.lensBarEl?.classList.toggle('bt-lens-pending-ex', this.lensPendingSign === '-');
    }

    // ── Autocomplete (contextual: keys, then actions + operators) ─────────
    // Suggest keys for the token currently being typed after the last `/`.
    currentLensToken() {
        const v = this.lensInput.value;
        const caret = this.lensInput.selectionStart ?? v.length;
        const head = v.slice(0, caret);
        const slash = head.lastIndexOf('/');
        if (slash < 0) return null;
        const frag = head.slice(slash + 1);
        if (/[\s:"]/.test(frag)) return null;       // KEY only (stop at space/colon/quote)
        return { start: slash + 1, end: caret, frag };
    }

    updateLensAutocomplete() {
        const tok = this.currentLensToken();
        if (tok) {                                   // KEY suggestions
            const f = tok.frag.toLowerCase();
            const matches = this.lensVocab.filter(k => _subseqMatch(f, k)).slice(0, 8);
            if (!matches.length) return this.hideLensAutocomplete();
            this.renderLensAC(matches.map(k => ({ kind: 'key', val: k, label: '/' + k })), true);
            return;
        }
        // Past the key (or composing free text) → ACTIONS + OPERATORS.
        if (this.lensInput.value.trim() !== '') {
            const p = this.lensClauseParts(this.lensInput.value);
            const items = [];
            if (p.key) for (const a of ['expand', 'collapse'])
                if (p.action !== a) items.push({ kind: 'action', val: a, label: a, hint: `${a} matches` });
            items.push({ kind: 'op', val: '+', label: '＋ add',     hint: 'include another clause' });
            items.push({ kind: 'op', val: '-', label: '− exclude',  hint: 'hide the next clause' });
            this.renderLensAC(items, false);        // no pre-select → Enter applies the lens
            return;
        }
        this.hideLensAutocomplete();
    }

    renderLensAC(items, selectFirst) {
        if (!items.length) return this.hideLensAutocomplete();
        this.lensAC.innerHTML = items.map((it, i) =>
            `<div class="bt-lens-ac-item${selectFirst && i === 0 ? ' bt-ac-sel' : ''}" ` +
            `data-kind="${it.kind}" data-val="${escapeAttr(it.val)}">` +
            `<span class="bt-lens-ac-label">${escapeHTML(it.label)}</span>` +
            (it.hint ? `<span class="bt-lens-ac-hint">${escapeHTML(it.hint)}</span>` : '') +
            `</div>`).join('');
        this.lensAC.hidden = false;
        for (const el of this.lensAC.querySelectorAll('.bt-lens-ac-item')) {
            el.addEventListener('mousedown', (e) => { e.preventDefault();
                this.applyLensAC(el.dataset.kind, el.dataset.val); });
        }
    }
    hideLensAutocomplete() { if (this.lensAC) { this.lensAC.hidden = true; this.lensAC.innerHTML = ''; } }
    moveLensAutocomplete(dir, e) {
        if (this.lensAC.hidden) return;
        e.preventDefault();
        const items = [...this.lensAC.querySelectorAll('.bt-lens-ac-item')];
        if (!items.length) return;
        let i = items.findIndex(el => el.classList.contains('bt-ac-sel'));
        if (i >= 0) items[i].classList.remove('bt-ac-sel');
        i = (i + dir + items.length) % items.length;
        items[i].classList.add('bt-ac-sel');
    }
    acceptLensAutocomplete() {
        if (this.lensAC.hidden) return false;
        const sel = this.lensAC.querySelector('.bt-ac-sel');
        if (!sel) return false;
        this.applyLensAC(sel.dataset.kind, sel.dataset.val);
        return true;
    }
    applyLensAC(kind, val) {
        if (kind === 'key') return this.fillLensKey(val);
        if (kind === 'action') return this.lensAppendToken(val);
        if (kind === 'op') {                          // commit clause, open the next
            this.lensCommitTail();
            this.lensPendingSign = val === '-' ? '-' : '+';
            this.renderLensPills();
            this.hideLensAutocomplete();
            this.lensInput.focus();
        }
    }
    lensAppendToken(tok) {
        let v = this.lensInput.value;
        if (v && !v.endsWith(' ')) v += ' ';
        this.lensInput.value = v + tok + ' ';
        this.hideLensAutocomplete();
        this.lensInput.focus();
        this.updateLensAutocomplete();
    }
    fillLensKey(key) {
        const tok = this.currentLensToken();
        const v = this.lensInput.value;
        if (!tok) return;
        const before = v.slice(0, tok.start), after = v.slice(tok.end);
        this.lensInput.value = before + key + (after.startsWith(' ') ? '' : ' ') + after;
        const caret = (before + key + ' ').length;
        this.lensInput.setSelectionRange(caret, caret);
        this.hideLensAutocomplete();
        this.lensInput.focus();
        this.updateLensAutocomplete();
    }

    // ── Run / receive / apply ─────────────────────────────────────────────
    runLens(query) {
        this.lensQuery = query;
        this.comm.notify({ type: 'lens.query', q: query });
    }

    onLensResult(msg) {
        // Only the result for the query THIS tab currently has pending.
        if (msg.q !== this.lensQuery) return;
        // The message being read, to come back to when a lens is cleared.
        const anchor = (this.lensActive && !msg.active && !this.followMode)
            ? this.captureAnchor() : null;
        if (!msg.active) {
            this.lensActive = false; this.seq = null; this.lensActions = null;
        } else {
            this.lensActive  = true;
            this.seq = (msg.visible || []).slice().sort((a, b) => a - b);
            this.lensActions = new Map(Object.entries(msg.actions || {}).map(([k, v]) => [+k, v]));
        }
        if (this.lensClearBtn) this.lensClearBtn.hidden = !this.lensActive;
        this.lensBarEl?.classList.toggle('bt-lens-on', this.lensActive);
        // The block holds sequence positions, and the sequence just changed:
        // a new block. A lens opens on its first match; clearing one goes back
        // to the message that was being read (or the bottom when following).
        const len = this.seqLength();
        const jump = this.pendingJump;
        this.pendingJump = null;
        if (jump && this.seqPos(jump.idx) >= 0) {
            this.clearBlock();
            this.jumpToPosition(this.seqPos(jump.idx), { flashId: jump.id || null, offset: 60 });
        } else if (this.lensActive) {
            this.clearBlock();
            if (len === 0) { this.updateRail(); return; }
            this.requestBlock(0, Math.min(len - 1, this.CHUNK - 1), { kind: 'lens' });
        } else if (anchor && this.seqPos(anchor.idx) >= 0) {
            const p = anchor.idx;
            this.clearBlock();
            this.requestBlock(Math.max(0, p - this.CHUNK), Math.min(len - 1, p + this.CHUNK),
                              { kind: 'restore', idx: anchor.idx, off: anchor.off });
        } else {
            this.clearBlock();
            this.loadTail();
        }
    }

    onLensSaved(msg) {
        this.savedLenses = msg.lenses || [];
        this.renderSavedLenses();
    }

    renderSavedLenses() {
        if (!this.lensChips) return;
        this.lensChips.innerHTML = '';
        for (const l of this.savedLenses) {
            const chip = document.createElement('span');
            chip.className = 'bt-lens-chip';
            chip.style.setProperty('--chip', l.color);
            chip.title = l.query;
            chip.innerHTML = `<span class="bt-lens-chip-label"></span><span class="bt-lens-chip-x" title="Remove">✕</span>`;
            chip.querySelector('.bt-lens-chip-label').textContent = l.title;
            chip.querySelector('.bt-lens-chip-label').addEventListener('click', () => {
                this.lensLoadQuery(l.query);    // populate pills + apply
            });
            chip.querySelector('.bt-lens-chip-x').addEventListener('click', (e) => {
                e.stopPropagation(); this.comm.notify({ type: 'lens.delete', q: l.query });
            });
            this.lensChips.appendChild(chip);
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    // The overscroll tail (empty space below the last message) is PLAIN
    // CONTENT: "bottom" everywhere is the real scroll bottom, tail fully
    // visible. No bottom-math special-cases — an earlier content-bottom-
    // excluding-tail model needed tail-awareness in four places and the
    // missed interactions made the scrollbar fight the user.
    //
    // Fixed-height (was ~30% of clientHeight): a tall pane wasted hundreds
    // of pixels between the last message and the composer that the user
    // had to scroll past. 50 px is enough for breathing room + the busy /
    // waiting / thinking row to clear the bottom edge without dwarfing
    // short replies in a tall window. (Pull-up past the bottom rubberbands
    // via the pan handler — see the panning block in the constructor —
    // so the tail no longer carries the "give me room to overscroll"
    // job.)
    sizeTail() {
        if (!this.tailEl) return;
        this.tailEl.style.height = '50px';
    }

    atBottom() {
        const { scrollTop, scrollHeight, clientHeight } = this.container;
        // Tight (AT_BOTTOM_PX = 20) so "user manually scrolled to the
        // very bottom" re-engages follow mode while merely-near doesn't.
        // The chase always scrolls to scrollHeight so streaming content
        // doesn't bounce in and out of this threshold — the worry the
        // old generous 200px window was guarding against.
        return scrollHeight - scrollTop - clientHeight < this.AT_BOTTOM_PX;
    }

    // The jump pill's visibility criterion: TRUE only when the LAST message
    // is COMPLETELY out of the container's visible box (its top edge at or
    // below the visible bottom — not a single pixel showing). Deliberately
    // NOT the razor-thin atBottom() boundary: composer autosize shifts the
    // container by ~a keystroke's worth of pixels, and a pill keyed on
    // "off the bottom" flickered on/off while typing. A whole message
    // height of hysteresis makes layout jitter invisible to the pill,
    // while followMode / unread-clearing keep using atBottom().
    lastMessageFullyOutOfView() {
        if (this.totalCount === 0) return false;
        const node = this.cache.get(this.totalCount - 1);
        // Virtual scroll detaches nodes far outside the viewport (cache
        // keeps them), and deep in scrollback the last message may not be
        // fetched at all — a missing/detached/display:none node has no
        // visible pixel by definition.
        if (!node || !node.isConnected || node.offsetParent === null) return true;
        return node.getBoundingClientRect().top >=
            this.container.getBoundingClientRect().bottom;
    }

    // rAF-batched scroll: multiple stream chunks arriving in the same
    // frame (or a chunk + a ResizeObserver callback) coalesce into ONE
    // scroll, run AFTER the browser has laid out the new content.
    // Reading scrollHeight synchronously after a textContent write
    // returns a stale value mid-layout; deferring to rAF guarantees
    // we measure post-layout.
    queueScrollToBottom() {
        // A held scrollbar is ABSOLUTE authority over scrollTop: no chase,
        // no re-anchor, no reveal-scroll may fire mid-drag (container
        // resizes from toolbar growth, streaming chunks, and range
        // arrivals all funnel through here — any of them would snap the
        // thumb out of the user's hand).
        if (this.scrollbarDrag) return;
        if (this.scrollQueued || this.destroyed) return;
        this.scrollQueued = true;
        this.scrollRafId = requestAnimationFrame(() => {
            this.scrollQueued = false;
            this.scrollRafId = null;
            if (this.destroyed) return;
            // A chunk that lands AFTER `markUserInput` cancelled the
            // previous rAF, but BEFORE the user's scroll event flips
            // followMode, will queue a fresh chase here. Defensive
            // re-check: if the user gestured within the last 100 ms,
            // assume their scroll-down/up intent is still in flight and
            // don't yank mid-gesture. 100 ms covers the wheel→scroll-event
            // delay (typically one task ≪ 50 ms, generous for slow
            // devices) without locking out chase for the steady-state
            // stream-while-at-bottom case. But follow mode SURVIVING to
            // this point means nothing disengaged or cancelled us (every
            // disengage goes through setFollowMode(false), which cancels
            // the pending chase) — the chase must still
            // land, e.g. after a downward re-engage mid-gesture. Re-arm
            // until the input window lapses instead of dropping.
            if ((performance.now() - this.lastUserInputT) < 100) {
                if (this.followMode) this.queueScrollToBottom();
                return;
            }
            this.scrollToBottom();
        });
    }

    // Survive the container being MOVED in the DOM.
    //
    // The workspace (BonitoWidgets) rebuilds its panel tree on every render: it
    // parks each `.bw-ws-panel` into `.bw-ws-parking`, then re-places it into
    // its group — TWICE per chat switch, in the ~10ms after `onShown` has
    // already restored the scroll correctly. Detaching an element resets its
    // scrollTop to 0 in the BROWSER, and that is invisible to everything here:
    //
    //   • no JS writes scrollTop, so trapping the property catches nothing;
    //   • park and re-place happen in ONE synchronous task, so the container's
    //     end-of-frame size never changes and `viewportObserver` never fires;
    //   • BonitoWidgets' own snapshotScroll skips elements reading
    //     `scrollTop === 0` — i.e. exactly the pane that was hidden when its
    //     snapshot was taken, so it is never restored either.
    //
    // Reported as a blank chat after switching: scrollTop 0 against a
    // scrollHeight of 107629, with a 58574px top spacer above the render
    // window. A live trace confirmed the geometry never moved (estimate,
    // spacers, scrollHeight, rendered range all constant) — only the position
    // was destroyed, and only by the re-insert.
    //
    // Guarded in `panel_move_scroll_test.jl`, which performs the same
    // park/re-place directly rather than relying on chat length or timing.
    setupMoveObserver() {
        const root = this.container.closest('.bw-ws') || document.body;
        this.moveObserver = new MutationObserver((records) => {
            if (this.destroyed || !this.container.isConnected) return;
            for (const r of records) {
                // Everything that happens INSIDE the container — every message
                // append, every virtual-scroll re-window — is not a move of us
                // and is discarded here, before any other work. Only structural
                // changes at or above our own level can relocate us.
                if (this.container.contains(r.target)) continue;
                for (const n of r.addedNodes) {
                    if (n !== this.container &&
                        !(n.nodeType === 1 && n.contains(this.container))) continue;
                    this.restoreAfterMove();
                    return;
                }
            }
        });
        this.moveObserver.observe(root, { childList: true, subtree: true });
    }

    // Undo a re-insert that zeroed us. ONLY that: a node can be moved WITHOUT
    // losing its scroll (an ordinary re-render of a wrapper), and re-pinning on
    // those fights every legitimate position holder — the lens/filter anchor
    // holds and the jitter guards all regress. A genuine reset is ours to undo;
    // nothing else is.
    restoreAfterMove() {
        if (this.container.clientHeight === 0) return;   // no box yet; onShown owns it
        if (this.container.scrollTop > 1) return;        // scroll survived the move
        if (this.followMode) {
            if (!this.atBottom()) this.scrollToBottom();
            return;
        }
        const want = this.lastGoodTop;
        if (want != null && want > 1) {
            this.container.scrollTop = want;
            this.prevScrollTop = this.container.scrollTop;
        }
    }

    scrollToBottom() {
        if (this.scrollbarDrag) return;   // the rail drag owns the position
        // The bottom of the conversation, not just of the block: a block that
        // stops short of the end is replaced by the tail, which lands pinned.
        if (this.blockEmpty() || !this.atTail()) {
            if (this.pending.block?.kind !== 'tail') this.loadTail();
            return;
        }
        // Use the scroll container's layout coordinates only. scrollIntoView
        // uses the tail's transformed box during rubberbanding and moves us
        // back UP immediately after this write (also dropping bottom padding).
        // One owner prevents opposing corrections on each viewport/stream tick.
        this.container.scrollTop = this.container.scrollHeight;
        // Keep the direction baseline honest where no scroll event may fire
        // (offscreen renderers fire none for programmatic writes): a chase
        // leaving a stale, SMALLER prevScrollTop would make the next upward
        // peek read as "moving down" and wrongly re-engage.
        this.prevScrollTop = this.container.scrollTop;
        // For the same reason, keep the block in shape here rather than wait
        // for a scroll event that may not come.
        this.ensureWindow();
    }

    // Save the user-visible scroll state at the instant the pane is
    // about to be hidden. The browser's own `scrollTop` preservation
    // across `display:none → display:flex` is unreliable on Chromium
    // for our flex + virtual-scroll geometry: when the container has no
    // layout box, a `scrollTop = X` write that happens during the
    // un-hide frame gets silently clamped (typically to 0), so the user
    // pops back to the top. By caching here and restoring through the
    // multi-attempt cascade in `onShown` we treat the browser as opaque
    // and just brute-force the right answer.
    onHidden() {
        // Freeze all in-flight scroll animation BEFORE snapshotting the position.
        // A pan fling leaves momentum/spring rAFs (and an append chase rAF) that
        // write `scrollTop` every frame; if the pane is hidden mid-fling they keep
        // mutating the now-zero-height container and then fight `onShown`'s restore
        // on return, so the user's read position is lost — it snaps to the top
        // (upward fling decays toward scrollTop 0) or the bottom. Cancelling here
        // makes the saved scrollTop authoritative across the hide/show.
        if (this.cancelMomentum) this.cancelMomentum();
        this.cancelPendingScroll();
        if (this.setOverscroll) this.setOverscroll(0);
        this.savedScrollTop  = this.container.scrollTop;
        this.savedFollowMode = this.followMode;
        // CONTENT anchor besides the pixel position: rows that change height
        // while hidden (images, editors) change what a raw scrollTop points
        // at; restoring to the anchored MESSAGE is what "keep my read
        // position" actually means.
        this.savedAnchor = this.captureAnchor();
    }

    // Called by the chat-pane visibility toggle whenever this pane goes
    // display:flex (initial open, kept-alive re-open, dashboard ↔ chat).
    // Two branches:
    //
    //   • Was at the bottom (followMode true now, OR it was true when we
    //     hid the pane): re-anchor to the bottom on every retry so any
    //     bubbles that streamed in while we were hidden land in view.
    //   • Was scrolled up to read history (followMode false on both
    //     sides): restore the anchored message on every retry so a
    //     mid-layout clamp can be undone on the next frame.
    //
    // The 0 / rAF / 50 ms / 200 ms cascade: a single-frame write loses to a
    // still-in-progress flex relayout (clicking the chat TWICE used to land
    // right). The cascade replicates "click again later", just automatically.
    onShown() {
        const followNow  = !!this.followMode;
        const followThen = !!this.savedFollowMode;
        const wantBottom = followNow || followThen;
        const savedTop   = this.savedScrollTop;
        const anchor     = this.savedAnchor;

        const apply = () => {
            if (this.destroyed) return;
            if (wantBottom) {
                if (this.followMode) this.scrollToBottom();
                return;
            }
            const n = anchor ? this.cache.get(anchor.idx) : null;
            if (n && n.isConnected && n.offsetParent !== null) {
                this.container.scrollTop = n.offsetTop - anchor.off;
            } else if (savedTop != null) {
                this.container.scrollTop = savedTop;
            }
            // Programmatic, possibly event-less write: sync the direction
            // baseline (see prevScrollTop).
            this.prevScrollTop = this.container.scrollTop;
            this.ensureWindow();
        };
        apply();
        requestAnimationFrame(apply);
        setTimeout(apply,  50);
        setTimeout(apply, 200);
    }

    // ── Image attachments ────────────────────────────────────────────────
    // Wire up the input widgets (textarea + send/stop buttons + attachments).
    // Single send path: ALL user submissions ship `{type: 'send', text,
    // attachments}` through `comm`. The send-button click + textarea Enter
    // are JS-owned in capture phase; the local textarea + attachment strip
    // are cleared right after `comm.notify` — no Julia round-trip for the
    // UI reset. Stop button posts `{type: 'cancel'}`. Paste / drag-drop
    // populates `this.attachments` (Map<id, {blob, mime, filename, dataUrl}>)
    // with thumbnails shown above the input row; on submit Julia stores
    // the bytes under `<cwd>/.bt-attachments/<ts>.<ext>`, pushes to the
    // worker mirror (via `send_file_to_worker!`), and forwards them to
    // claude as multimodal content blocks.
    setupInputs() {
        if (this.destroyed) return;
        // The chat shell root. `closest` — the messages container sits
        // inside a positioning wrapper (.bt-messages-wrap), so a bare
        // parentElement is NOT the app. Fallback for bare test mounts.
        const app = this.container?.closest('.bt-app') ||
                    this.container?.parentElement;
        if (!app) return;
        this.app       = app;
        this.inputArea = app.querySelector('.bt-input-area');
        this.textInput = app.querySelector('.bt-text-input');
        // NOTE: we deliberately do NOT cache `.bt-send-btn` / `.bt-stop-btn`
        // references at setup time. Bonito renders the chat's children
        // non-atomically — the send button can land in the DOM a frame
        // before the stop button, so a `querySelector('.bt-stop-btn')`
        // here can return `null` even though the button shows up moments
        // later. A null-ref + late button = silently dead click handler
        // (esp. the stop button, which is the user's only interrupt
        // affordance). Event delegation on the chat root (`.bt-app`)
        // sidesteps the race entirely: the listener is alive before
        // either button exists, and dispatches by `e.target.closest`
        // at click time.
        if (!this.inputArea || !this.textInput) return;

        // Native sizing avoids synchronous textarea collapse/reflow during
        // Android IME edits and preserves selection/scroll within long drafts.
        // Older engines measure an unfocused, isolated copy once per frame.
        if (!CSS.supports('field-sizing', 'content')) {
            this.textInput.dataset.btSizingFallback = '';
            const mirror = document.createElement('textarea');
            mirror.className = 'bt-input-measure';
            mirror.tabIndex = -1;
            mirror.setAttribute('aria-hidden', 'true');
            this.inputArea.appendChild(mirror);
            this.inputMeasure = mirror;
            this.onInputResize = () => {
                if (this.inputResizeFrame) return;
                this.inputResizeFrame = requestAnimationFrame(() => {
                    this.inputResizeFrame = null;
                    if (this.destroyed || !this.textInput.clientWidth) return;
                    mirror.style.width = this.textInput.clientWidth + 'px';
                    mirror.value = this.textInput.value;
                    const height = (mirror.scrollHeight + 2) + 'px';
                    if (this.textInput.style.height !== height) this.textInput.style.height = height;
                });
            };
            this.textInput.addEventListener('input', this.onInputResize);
            this.textInput.addEventListener('bt-composer-resize', this.onInputResize);
            let width = 0;
            this.inputWidthObserver = new ResizeObserver(entries => {
                const next = entries[0].contentRect.width;
                if (width === next) return;
                width = next;
                this.onInputResize();
            });
            this.inputWidthObserver.observe(this.textInput);
            this.onInputResize();
        }

        // Thumbnail strip lives ABOVE the input row inside .bt-input-area.
        this.attachBar = document.createElement('div');
        this.attachBar.className = 'bt-attachments';
        this.inputArea.insertBefore(this.attachBar, this.inputArea.firstChild);

        this.attachments = new Map();
        this.attachIdCounter = 0;
        // An image up to this size goes inline, for the agent to see; anything
        // bigger, and any other file, is uploaded for the agent to open.
        this.ATTACH_MAX_BYTES = 5 * 1024 * 1024;
        // The image types the server stores inline (ATTACHMENT_EXTENSIONS).
        // Any other image (HEIC off a phone) travels as a file.
        this.INLINE_IMAGE_TYPES = new Set(['image/png', 'image/jpeg', 'image/jpg',
            'image/gif', 'image/webp', 'image/svg+xml']);
        this.FILE_MAX_BYTES = 2 * 1024 * 1024 * 1024;
        // One upload request: well under any proxy's default body limit (1 MB).
        this.UPLOAD_CHUNK_BYTES = 512 * 1024;
        // Queue length cap. The file picker makes "select all" in a phone
        // gallery a single tap, so an unbounded queue is one gesture away from
        // dozens of multi-MB data URLs in memory and one enormous message.
        this.ATTACH_MAX_COUNT = 10;
        // Counts blobs whose FileReader is still running. `attachments` only
        // grows in the async onload, so a synchronous loop over 40 picked files
        // would see size 0 forty times and let every one of them through.
        this.attachPending = 0;

        // Paste — clipboardData.items carries File entries for images.
        this.onPaste = (e) => {
            const items = e.clipboardData?.items;
            if (!items) return;
            for (const it of items) {
                if (it.kind !== 'file') continue;
                const blob = it.getAsFile();
                if (blob) this.attachAdd(blob, `pasted-${Date.now()}`);
            }
        };
        this.textInput.addEventListener('paste', this.onPaste);

        // Drag-drop — listen on the whole .bt-app so a drop anywhere in
        // the chat counts. dragover MUST preventDefault to enable drop.
        this.onDragOver = (e) => {
            if (!this.dragHasFiles(e)) return;
            e.preventDefault();
            this.app.classList.add('bt-drag-over');
        };
        this.onDragLeave = (e) => {
            // Only clear when leaving the .bt-app envelope itself, not
            // when crossing between nested children (relatedTarget inside app).
            if (e.relatedTarget && this.app.contains(e.relatedTarget)) return;
            this.app.classList.remove('bt-drag-over');
        };
        this.onDrop = (e) => {
            e.preventDefault();
            this.app.classList.remove('bt-drag-over');
            const files = e.dataTransfer?.files;
            if (!files) return;
            for (const f of files) this.attachAdd(f, `dropped-${Date.now()}`);
        };
        this.app.addEventListener('dragover',  this.onDragOver);
        this.app.addEventListener('dragleave', this.onDragLeave);
        this.app.addEventListener('drop',      this.onDrop);

        // Single delegated click handler on the chat root. Capture phase
        // so we run before any inner element that might (in the future)
        // also wire a click handler. `target.closest` survives DOM swaps
        // and works regardless of when the buttons are added.
        this.onAppClickCapture = (e) => {
            if (this.destroyed) return;
            const modeOption = e.target.closest('.bt-send-mode-option');
            const queueAction = e.target.closest('[data-queue-action]');
            const modeMenu = this.app.querySelector('.bt-send-mode-menu');
            if (modeMenu && !e.target.closest('.bt-send-mode')) {
                modeMenu.hidden = true;
                this.app.querySelector('.bt-send-mode-trigger')?.setAttribute('aria-expanded', 'false');
            }
            if (modeOption) {
                e.preventDefault(); e.stopImmediatePropagation();
                this.sendMode = modeOption.dataset.sendMode;
                const trigger = this.app.querySelector('.bt-send-mode-trigger');
                trigger.querySelector('.bt-send-mode-label').textContent =
                    {done: 'Queue when done', next: 'Queue after message', interrupt: 'Interrupt + send'}[this.sendMode];
                trigger.title = modeOption.textContent;
                trigger.setAttribute('aria-label', trigger.title);
                trigger.setAttribute('aria-expanded', 'false');
                modeMenu.hidden = true;
                for (const option of modeMenu.children)
                    option.setAttribute('aria-checked', String(option === modeOption));
            } else if (e.target.closest('.bt-send-mode-trigger')) {
                e.preventDefault(); e.stopImmediatePropagation();
                modeMenu.hidden = !modeMenu.hidden;
                e.target.closest('button').setAttribute('aria-expanded', String(!modeMenu.hidden));
            } else if (queueAction) {
                e.preventDefault(); e.stopImmediatePropagation();
                this.comm.notify({type: 'queue.action', id: queueAction.dataset.queueId,
                    action: queueAction.dataset.queueAction});

            } else if (e.target.closest('.bt-send-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this.submit();
            } else if (e.target.closest('.bt-stop-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this.cancel();
            } else if (e.target.closest('.bt-attach-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                // Resolved at click time, not cached — same reason as the
                // send/stop buttons above.
                this.app.querySelector('.bt-attach-input')?.click();
            }
        };
        this.app.addEventListener('click', this.onAppClickCapture, true);

        // File picker — the third way to attach an image, and the only one a
        // phone has. Paste needs a clipboard holding a file, drag-drop needs a
        // pointer; neither exists on touch, so attaching was desktop-only by
        // accident. A plain <input type=file> is what a mobile browser turns
        // into the camera/gallery sheet. `change` bubbles, so this delegates
        // off the chat root like the clicks do.
        this.onAppChange = (e) => {
            if (this.destroyed) return;
            const input = e.target.closest('.bt-attach-input');
            if (!input || !input.files) return;
            for (const f of input.files) this.attachAdd(f, `picked-${Date.now()}`);
            // Clear, or picking the SAME file twice fires no `change` at all
            // and the second attempt looks broken.
            input.value = '';
            // Land back in the composer: after the picker closes focus is on
            // nothing, so the next keystroke would go nowhere and on a phone
            // you'd have to tap the field before typing a caption.
            this.textInput?.focus();
        };
        this.app.addEventListener('change', this.onAppChange);

        // Unsent text outlives the page. A reload (a login that ended, a server
        // restart) used to take a half-written message with it; now it is kept
        // per chat in localStorage and put back here. `submit` clears the field
        // with an `input` event, which drops the saved copy. Yolo reminders are
        // not a draft: the server keeps those.
        const pid = app.closest('.bt-chatpane')?.dataset.panePid;
        if (pid) {
            const key = 'bt-draft:' + pid;
            const yolo = () => this.textInput.classList.contains('bt-text-input-yolo');
            const saved = storage.get(key);
            if (saved && !this.textInput.value && !yolo()) {
                this.textInput.value = saved;
                this.textInput.dispatchEvent(new Event('input', {bubbles: true}));
            }
            // Storage is synchronous. Coalesce typing bursts; flush on
            // background/blur/pagehide so navigating away still keeps the draft.
            this.flushDraft = () => {
                clearTimeout(this.draftTimer);
                if (this.pendingDraft === undefined) return;
                const text = this.pendingDraft;
                this.pendingDraft = undefined;
                text.trim() ? storage.set(key, text) : storage.remove(key);
            };
            this.onDraftInput = () => {
                if (yolo()) return;
                this.pendingDraft = this.textInput.value;
                clearTimeout(this.draftTimer);
                if (!this.pendingDraft.trim()) this.flushDraft();
                else this.draftTimer = setTimeout(this.flushDraft, 250);
            };
            this.onDraftVisibility = () => {
                if (document.visibilityState === 'hidden') this.flushDraft();
            };
            this.textInput.addEventListener('input', this.onDraftInput);
            this.textInput.addEventListener('blur', this.flushDraft);
            window.addEventListener('pagehide', this.flushDraft);
            document.addEventListener('visibilitychange', this.onDraftVisibility);
        }

        // Mobile Enter belongs to the editor, including autocomplete. IME
        // confirmation is never Send, even on a desktop keyboard.
        this.onCompositionStart = () => { this.inputComposing = true; };
        this.onCompositionEnd = () => { this.inputComposing = false; };
        this.textInput.addEventListener('compositionstart', this.onCompositionStart);
        this.textInput.addEventListener('compositionend', this.onCompositionEnd);
        this.onTextInputKeyCapture = (e) => {
            if (e.isComposing || this.inputComposing || e.keyCode === 229) return;
            const mobile = matchMedia('(pointer: coarse)').matches ||
                navigator.userAgentData?.mobile || /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
            if (e.key === 'Enter' && (mobile || e.shiftKey)) return;
            if (this.cmdAcHandleKey(e)) return;
            if (e.key !== 'Enter') return;
            e.preventDefault();
            e.stopImmediatePropagation();
            this.submit();
        };
        this.textInput.addEventListener('keydown', this.onTextInputKeyCapture, true);

        // ── Slash-command autocomplete ────────────────────────────────────
        // `this.slashCommands` ({name, description, hint}) = the agent's
        // command set — seeded via connect(init) for late-mounted tabs,
        // refreshed by the 'commands' comm event (available_commands_update
        // re-pushes the complete set whenever it changes). The popup opens
        // while the composer holds ONLY a "/partial" first token; ↑/↓ move,
        // Enter/Tab accept, Escape closes (swallowed before the global
        // ESC-cancels-turn handler — see onEscapeKey).
        this.cmdAc = document.createElement('div');
        this.cmdAc.className = 'bt-cmd-ac';
        this.inputArea.appendChild(this.cmdAc);
        this.cmdAcItems = [];
        this.cmdAcSel = 0;
        const acClose = () => {
            this.cmdAcItems = [];
            this.cmdAc.classList.remove('bt-cmd-ac-open');
        };
        this.cmdAcClose = acClose;
        const acAccept = (cmd) => {
            this.textInput.value = '/' + cmd.name + ' ';
            this.textInput.focus();
            this.textInput.dispatchEvent(new Event('input', {bubbles: true}));
            acClose();
        };
        const acRender = () => {
            this.cmdAc.innerHTML = '';
            this.cmdAcItems.forEach((cmd, i) => {
                const row = document.createElement('div');
                row.className = 'bt-cmd-ac-item' +
                    (i === this.cmdAcSel ? ' bt-cmd-ac-sel' : '');
                const name = document.createElement('span');
                name.className = 'bt-cmd-ac-name';
                name.textContent = '/' + cmd.name;
                row.appendChild(name);
                if (cmd.hint) {
                    const hint = document.createElement('span');
                    hint.className = 'bt-cmd-ac-hint';
                    hint.textContent = cmd.hint;
                    row.appendChild(hint);
                }
                if (cmd.description) {
                    const desc = document.createElement('span');
                    desc.className = 'bt-cmd-ac-desc';
                    desc.textContent = cmd.description;
                    row.appendChild(desc);
                }
                // mousedown, not click: fires before the textarea blurs, so
                // the blur-close below can't beat the accept.
                row.addEventListener('mousedown', (e) => {
                    e.preventDefault();
                    acAccept(cmd);
                });
                this.cmdAc.appendChild(row);
            });
            this.cmdAc.classList.toggle('bt-cmd-ac-open', this.cmdAcItems.length > 0);
        };
        this.cmdAcHandleKey = (e) => {
            if (!this.cmdAcItems.length) return false;
            if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
                const d = e.key === 'ArrowDown' ? 1 : -1;
                this.cmdAcSel = (this.cmdAcSel + d + this.cmdAcItems.length)
                               % this.cmdAcItems.length;
                acRender();
            } else if (e.key === 'Enter' || e.key === 'Tab') {
                acAccept(this.cmdAcItems[this.cmdAcSel]);
            } else if (e.key === 'Escape') {
                acClose();
            } else {
                return false;
            }
            e.preventDefault();
            e.stopImmediatePropagation();
            return true;
        };
        this.onCmdInput = () => {
            const m = (this.textInput.value || '').match(/^\/([\w:-]*)$/);
            const cmds = this.slashCommands || [];
            if (!m || !cmds.length) { acClose(); return; }
            const q = m[1].toLowerCase();
            const starts = cmds.filter(c => c.name.toLowerCase().startsWith(q));
            const incl   = cmds.filter(c => !c.name.toLowerCase().startsWith(q) &&
                                            c.name.toLowerCase().includes(q));
            this.cmdAcItems = starts.concat(incl).slice(0, 8);
            this.cmdAcSel = 0;
            acRender();
        };
        this.onCmdBlur = () => acClose();
        this.textInput.addEventListener('input', this.onCmdInput);
        this.textInput.addEventListener('blur', this.onCmdBlur);

        // ESC anywhere → cancel. Listener on `document` so the user's
        // current focus (textarea, scroll position, anywhere) can't
        // suppress it. The Monaco tool-body editor owns ESC for its own
        // semantics — skip when the user is editing inside one.
        this.onEscapeKey = (e) => {
            if (e.key !== 'Escape' || e.repeat || e.isComposing || this.inputComposing || e.keyCode === 229) return;
            // Document-level listener + kept-alive panes (display:none but
            // connected) = EVERY chat instance hears this. Only the VISIBLE
            // pane may cancel — one ESC used to cancel the running turn of
            // every open chat. offsetParent is null while the pane (or any
            // ancestor) is display:none. A container that left the document
            // entirely means the `connect` MutationObserver missed an
            // ancestor-level unmount: self-destroy.
            if (!this.container.isConnected) { this.lazyDestroy(); return; }
            if (this.container.offsetParent === null) return;
            if (document.querySelector('.bt-lightbox-overlay')) return;
            const modeMenu = this.app.querySelector('.bt-send-mode-menu');
            if (modeMenu && !modeMenu.hidden) {
                e.preventDefault();
                modeMenu.hidden = true;
                const trigger = this.app.querySelector('.bt-send-mode-trigger');
                trigger.setAttribute('aria-expanded', 'false');
                trigger.focus();
                return;
            }
            // The slash-command popup owns ESC while open (this document-level
            // capture fires BEFORE the textarea's own capture handler, so the
            // popup must be dismissed here or ESC would cancel the turn).
            if (this.cmdAcItems && this.cmdAcItems.length) {
                e.preventDefault();
                this.cmdAcClose();
                return;
            }
            const t = e.target;
            if (t && t.closest && t.closest('.monaco-editor')) return;
            e.preventDefault();
            this.cancel();
        };
        document.addEventListener('keydown', this.onEscapeKey, true);
    }

    // Fire a cancel notification. Used by both the stop button click
    // and the ESC keystroke. Stays a one-line helper so the two
    // entry points can't drift in what they send.
    // Carries the sequence number of the turn the user is LOOKING AT
    // (`turn_begin`), so a stale click can never cancel a later turn.
    cancel() {
        this.comm.notify({type: 'cancel', seq: this.turnSeq ?? -1});
    }

    dragHasFiles(e) {
        const dt = e.dataTransfer;
        if (!dt) return false;
        if (dt.types) {
            // 'Files' is the type when the user drags from the OS file picker.
            for (const t of dt.types) if (t === 'Files') return true;
        }
        return false;
    }

    // Any file the user attaches. An image the server stores inline, small
    // enough, goes into the message for the agent to see; everything else is
    // uploaded and copied to the worker, and the message names its path.
    attachAdd(file, fallbackName) {
        const mime = file.type || '';
        if (this.INLINE_IMAGE_TYPES.has(mime) && file.size <= this.ATTACH_MAX_BYTES) {
            this.attachAddBlob(file, mime, file.name || `${fallbackName}.png`);
        } else {
            this.attachAddFile(file, file.name || fallbackName);
        }
    }

    attachAddFile(file, filename) {
        if (this.attachments.size + this.attachPending >= this.ATTACH_MAX_COUNT) {
            this.showAttachError(`At most ${this.ATTACH_MAX_COUNT} attachments per message`);
            return;
        }
        if (file.size > this.FILE_MAX_BYTES) {
            this.showAttachError(`${filename} is too large (${formatBytes(file.size)}, ` +
                `at most ${formatBytes(this.FILE_MAX_BYTES)})`);
            return;
        }
        const pid = this.app.closest('.bt-chatpane')?.dataset.panePid;
        if (!pid) { this.showAttachError('Files can only be attached in a chat'); return; }
        const id = `att-${++this.attachIdCounter}`;
        const bytes = crypto.getRandomValues(new Uint8Array(12));
        const item = {
            kind: 'file', file, filename, mime: file.type || '', size: file.size,
            pid, uploadId: Array.from(bytes, b => b.toString(16).padStart(2, '0')).join(''),
            sent: 0, path: null, onWorker: false, error: null, removed: false,
        };
        item.done = this.uploadFile(item);
        this.attachments.set(id, item);
        this.renderAttachments();
    }

    // Chunk after chunk, each one request; the last one's answer says where
    // the file landed. Resolves either way: `item.error` says what went wrong.
    async uploadFile(item) {
        const url = (offset) => `/attachment-upload/${encodeURIComponent(item.pid)}` +
            `?upload=${item.uploadId}&offset=${offset}&total=${item.size}` +
            `&name=${encodeURIComponent(item.filename)}`;
        try {
            let offset = 0;
            do {
                if (item.removed) return;
                const chunk = item.file.slice(offset, offset + this.UPLOAD_CHUNK_BYTES);
                const resp = await fetch(url(offset), {
                    method: 'POST', body: chunk, headers: {'X-BT-Upload': '1'}});
                if (!resp.ok) throw new Error((await resp.text()).trim() || `HTTP ${resp.status}`);
                const answer = await resp.json();
                offset = answer.received;
                item.sent = offset;
                if (answer.path) { item.path = answer.path; item.onWorker = answer.on_worker; }
                if (!this.destroyed) this.renderAttachments();
            } while (offset < item.size);
        } catch (error) {
            item.error = `Upload failed: ${error.message}`;
            if (!this.destroyed) this.renderAttachments();
        }
    }

    attachAddBlob(blob, mime, filename) {
        if (this.attachments.size + this.attachPending >= this.ATTACH_MAX_COUNT) {
            this.showAttachError(
                `At most ${this.ATTACH_MAX_COUNT} images per message`);
            return;
        }
        if (blob.size > this.ATTACH_MAX_BYTES) {
            this.showAttachError(
                `Image too large (${(blob.size / 1024 / 1024).toFixed(1)} MB, ` +
                `max ${this.ATTACH_MAX_BYTES / 1024 / 1024} MB)`);
            return;
        }
        const id = `att-${++this.attachIdCounter}`;
        const reader = new FileReader();
        this.attachPending++;
        reader.onload = () => {
            this.attachPending--;
            if (this.destroyed) return;
            this.attachments.set(id, {
                blob, mime, filename,
                dataUrl: reader.result,
            });
            this.renderAttachments();
        };
        reader.onerror = () => {
            this.attachPending--;
            this.showAttachError('Failed to read image');
        };
        reader.readAsDataURL(blob);
    }

    attachRemove(id) {
        const item = this.attachments.get(id);
        this.attachments.delete(id);
        // An upload still running stops, and what arrived of it goes.
        if (item?.kind === 'file' && !item.path) {
            item.removed = true;
            fetch(`/attachment-upload/${encodeURIComponent(item.pid)}?upload=${item.uploadId}`,
                {method: 'DELETE', headers: {'X-BT-Upload': '1'}})
                .catch(e => console.warn('could not drop the partial upload', e));
        }
        this.renderAttachments();
    }

    attachClear() {
        this.attachments.clear();
        this.renderAttachments();
    }

    renderAttachments() {
        if (!this.attachBar) return;
        // Preserve any transient error chip across re-renders.
        const err = this.attachBar.querySelector('.bt-attach-error');
        this.attachBar.innerHTML = '';
        if (this.attachments.size === 0) {
            this.attachBar.classList.remove('bt-attachments-active');
        } else {
            this.attachBar.classList.add('bt-attachments-active');
            for (const [id, item] of this.attachments) {
                const wrap = document.createElement('div');
                wrap.dataset.attachId = id;
                if (item.kind === 'file') {
                    // Name, size, and how far the upload got.
                    wrap.className = 'bt-attachment-file';
                    wrap.dataset.state = item.error ? 'error' : item.path ? 'done' : 'uploading';
                    const name = document.createElement('div');
                    name.className = 'bt-attachment-file-name';
                    name.textContent = item.filename;
                    name.title = item.filename;
                    const status = document.createElement('div');
                    status.className = 'bt-attachment-file-status';
                    status.textContent = item.error ? item.error :
                        item.path ? formatBytes(item.size) :
                        `Uploading ${Math.floor(100 * item.sent / Math.max(1, item.size))}% of ${formatBytes(item.size)}`;
                    const bar = document.createElement('div');
                    bar.className = 'bt-attachment-file-bar';
                    bar.style.width = `${item.path ? 100 : Math.floor(100 * item.sent / Math.max(1, item.size))}%`;
                    wrap.append(name, status, bar);
                } else {
                    wrap.className = 'bt-attachment-thumb';
                    const img = document.createElement('img');
                    img.src   = item.dataUrl;
                    img.alt   = item.filename || 'image';
                    img.title = item.filename || 'image';
                    wrap.appendChild(img);
                }
                const rm = document.createElement('button');
                rm.type = 'button';
                rm.className = 'bt-attachment-remove';
                rm.title = 'Remove';
                rm.textContent = '×';
                rm.addEventListener('click', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    this.attachRemove(id);
                });
                wrap.appendChild(rm);
                this.attachBar.appendChild(wrap);
            }
        }
        if (err) this.attachBar.appendChild(err);
    }

    showAttachError(message) {
        if (!this.attachBar) return;
        let chip = this.attachBar.querySelector('.bt-attach-error');
        if (!chip) {
            chip = document.createElement('div');
            chip.className = 'bt-attach-error';
            this.attachBar.appendChild(chip);
            this.attachBar.classList.add('bt-attachments-active');
        }
        chip.textContent = message;
        clearTimeout(this.attachErrorTimer);
        this.attachErrorTimer = setTimeout(() => {
            chip.remove();
            if (this.attachments.size === 0) {
                this.attachBar.classList.remove('bt-attachments-active');
            }
        }, 4500);
    }

    renderQueue(msg) {
        const box = this.app.querySelector('.bt-message-queue');
        if (!box) return;
        const expanded = new Set([...box.querySelectorAll('details[open]')].map(e => e.dataset.queueId));
        box.replaceChildren();
        const items = msg.items || [];
        box.hidden = items.length === 0;
        if (!items.length) return;
        box.setAttribute('aria-label', `Pending messages (${items.length})`);
        for (const item of items) {
            const row = document.createElement('details');
            row.className = 'bt-queue-item';
            row.open = expanded.has(item.id);
            row.dataset.queueId = item.id;
            row.dataset.status = item.status;
            row.dataset.mode = item.mode;
            const text = document.createElement('div');
            text.className = 'bt-queue-text';
            text.textContent = item.text;
            const status = document.createElement('div');
            status.className = 'bt-queue-status';
            status.textContent = item.detail || (item.status === 'paused' ? 'Paused · not sent' :
                item.status === 'offline' ? 'Agent not reachable · sends once it is back' :
                item.status === 'sending' ? 'Connecting · not sent yet' :
                item.mode === 'interrupt' ? 'Waiting for interruption to finish' :
                item.mode === 'next' ? 'Waiting for the next message boundary' :
                'Waiting until the agent finishes');
            const summary = document.createElement('summary');
            summary.className = 'bt-queue-summary';
            const preview = document.createElement('span');
            preview.className = 'bt-queue-preview';
            preview.textContent = item.text;
            const badge = document.createElement('span');
            badge.className = 'bt-queue-badge';
            badge.textContent = item.status === 'paused' ? 'Paused · not sent' :
                item.status === 'offline' ? 'Agent offline · queued' :
                item.status === 'sending' ? 'Sending…' : item.mode === 'interrupt' ? 'Interrupting…' :
                item.mode === 'next' ? 'Queued · next message' : 'Queued · when done';
            summary.title = status.textContent;
            summary.append(preview, badge);
            const detail = document.createElement('div');
            detail.className = 'bt-queue-detail';
            detail.append(text, status);
            row.append(summary, detail);
            const actions = document.createElement('div');
            actions.className = 'bt-queue-actions';
            for (const [action, label] of item.status === 'paused' ?
                    [['send', 'Queue again'], ['remove', 'Remove']] :
                    item.status === 'waiting' || item.status === 'offline' ? [['remove', 'Remove']] : []) {
                const button = document.createElement('button');
                button.type = 'button';
                button.className = 'bt-btn bt-btn-ghost bt-btn-sm';
                button.dataset.queueAction = action;
                button.dataset.queueId = item.id;
                button.textContent = label;
                actions.append(button);
            }
            detail.append(actions);
            box.append(row);
        }
    }

    queueDelivered(msg) {
        const box = this.app.querySelector('.bt-queue-delivery');
        if (!box) return;
        box.textContent = 'Sent to agent: ' + msg.text.replace(/\s+/g, ' ').slice(0, 100);
        box.hidden = false;
    }

    async submit() {
        const text = this.textInput.value;
        // Nothing to send → noop. (Pressing Enter on an empty textarea
        // shouldn't fire a request, and the user can have queued some
        // attachments without any text — the latter case still sends.)
        // EXCEPT in Yolo mode: the composer is the reminders editor and this
        // same send path LOCKS IN the text server-side (SendCommand becomes a
        // reminders write, never a send — see handle_command!). An empty
        // lock-in is meaningful there: it clears the reminders.
        const yoloMode = this.textInput.classList.contains('bt-text-input-yolo');
        if (!yoloMode && text.trim() === '' && this.attachments.size === 0) return;
        // Files still uploading: the message waits for them (the chips show how
        // far they are). A second click meanwhile does nothing.
        if (this.submitting) return;
        const files = [...this.attachments.values()].filter(item => item.kind === 'file');
        if (files.some(item => !item.path && !item.error)) {
            this.submitting = true;
            try { await Promise.all(files.map(item => item.done)); }
            finally { this.submitting = false; }
        }
        const failed = files.find(item => item.error);
        if (failed) {
            this.showAttachError(`${failed.filename}: ${failed.error}. Remove it to send.`);
            return;
        }
        const payload = [];
        for (const item of this.attachments.values()) {
            if (item.kind === 'file') {
                payload.push({kind: 'file', path: item.path, filename: item.filename,
                              on_worker: item.onWorker});
                continue;
            }
            const buf = await item.blob.arrayBuffer();
            payload.push({
                mime:     item.mime,
                filename: item.filename || '',
                data:     arrayBufferToBase64(buf),
            });
        }
        // What is in the composer now: typing went on while files uploaded.
        this.comm.notify({type: 'send', text: this.textInput.value, attachments: payload,
                          mode: this.sendMode || 'done'});
        // Clear the local input immediately. We don't wait for any
        // server ack — the textarea content is already encoded on the
        // wire, Julia will surface errors (e.g. attachment rejection)
        // via a separate event, and locking the user out of typing
        // their next message while bytes are in flight would be hostile.
        this.textInput.value = '';
        this.textInput.dispatchEvent(new Event('input', {bubbles: true}));
        this.attachClear();
    }

    onViewportResize() {
        // Mobile keyboard or browser address bar changed the visual
        // viewport. Resize bt-app so flex math has the right available
        // height, then chase the tail across the keyboard's slide-in
        // animation (~250ms on iOS; the container's ResizeObserver
        // picks up each frame of it once .bt-app's height has changed).
        // OUR pane, not document.querySelector('.bt-app') — that grabbed the
        // FIRST pane in the document, so every kept-alive instance resized
        // the same (wrong) one.
        //
        // NOT while something is fullscreen. Entering a video's fullscreen
        // resizes the visual viewport too, and chasing the tail then scrolls the
        // chat away from the very video being watched — which used to end the
        // fullscreen outright (the node left the render window and was detached).
        // `trimBlock` refuses to drop it, but the scroll is still wrong: the
        // user asked for fullscreen, not for the conversation to move.
        if (this.fullscreenActive()) return;
        const vv = window.visualViewport;
        // IME notifications can repeat without a viewport change. Do not
        // re-pin the transcript for every key/selection event. Actual content
        // and composer resizes are already handled by the ResizeObservers.
        if (this.destroyed || !this.container.offsetParent) return;
        const h = Math.round(vv.height);
        if (this.lastViewportHeight === h) return;
        this.lastViewportHeight = h;
        const app = this.app || this.container.closest('.bt-app');
        if (app) app.style.height = h + 'px';
        if (this.followMode) this.queueScrollToBottom();
    }

    // ── Follow mode + unread pill ────────────────────────────────────────
    // Classify ONE user-driven scroll movement (prevTop → current scrollTop)
    // into the follow-mode transition. Called from the scroll handler AND
    // directly at the pan/momentum scrollTop writes — offscreen renderers
    // don't fire scroll events for programmatic writes (see scrollToBottom),
    // and when the event DOES fire it sees a zero delta and skips, so the
    // movement is never classified twice.
    //
    // DISENGAGE is razor-thin, direction-blind: any user scroll landing off
    // the bottom (beyond AT_BOTTOM_PX) while following — even a small upward
    // peek — turns follow off. RE-ENGAGE is generous but DOWNWARD-ONLY, and
    // shares the jump-pill's boundary (pill visible ⟺ out of follow range):
    // a downward scroll re-engages the moment any pixel of the last message
    // is visible, capped at one viewport of remaining gap so a multi-screen-
    // tall last message can't snap-skip content the user is still reading.
    // Disengage runs first, so a continuous downward scroll THROUGH the zone
    // doesn't flip-flop with event parity: every in-zone downward event
    // lands on "following".
    applyUserScroll(prevTop) {
        const { scrollTop, scrollHeight, clientHeight } = this.container;
        const atBot = this.atBottom();
        if (this.followMode && !atBot) this.setFollowMode(false);
        if (this.followMode) return;
        if (atBot || (scrollTop > prevTop &&
                      scrollHeight - scrollTop - clientHeight < clientHeight &&
                      !this.lastMessageFullyOutOfView())) {
            this.setFollowMode(true);
            // Pin the viewport. The chase rAF defers while the gesture is
            // still in flight and re-arms itself (see queueScrollToBottom),
            // so it lands right after the input window lapses — and a
            // disengage meanwhile cancels it as always.
            this.queueScrollToBottom();
        } else {
            // Off-bottom AND outside the re-engage zone (the last message is
            // fully hidden, or more than a viewport of gap remains): any
            // pending chase yields to the user's position. The zone check
            // above is what keeps this from being the only way back — see the
            // asymmetry note in this function's header.
            this.cancelPendingScroll();
        }
    }

    // followMode is the one-bit "should new content auto-scroll" state.
    // It's set true when the user is at the bottom (within AT_BOTTOM_PX)
    // and the chat starts in this mode. Scrolling away → false. Sending
    // a message, clicking the pill, or scrolling DOWN into the last-message
    // zone (any pixel visible, less than a viewport to go) → true. Layout
    // shifts never toggle it.
    setFollowMode(on) {
        if (this.followMode === on) return;
        this.followMode = on;
        if (on) {
            this.unreadCount = 0;
            this.hideNewMessagePill();
        } else {
            // A chase queued while following has nothing left to follow: a
            // jump, a lens or a restore that ends following must not be
            // pulled back to the bottom on the next frame.
            this.cancelPendingScroll();
        }
    }

    cancelPendingScroll() {
        if (this.scrollRafId !== null && this.scrollRafId !== undefined) {
            cancelAnimationFrame(this.scrollRafId);
            this.scrollRafId = null;
            this.scrollQueued = false;
        }
    }

    // Bump unread + surface the pill. Called from appendNewMessage and
    // appendChunk when followMode is off. Appending only ever pushes the
    // last message FURTHER down, so re-checking the criterion here can
    // flip the pill ON (never off); while the freshly appended message is
    // still partially visible there's no pill — just keep the glow/label
    // fresh in case it's already showing.
    registerUnread() {
        this.unreadCount++;
        if (this.lastMessageFullyOutOfView()) {
            this.showNewMessagePill();
        } else {
            this.refreshPillContent();
        }
    }

    // The scroll-to-bottom affordance is visible ONLY when the last message is
    // completely out of view — while any pixel of it still shows there is
    // nothing hidden to jump to (see lastMessageFullyOutOfView). It GLOWS and
    // reads "New messages" when there's unread content (a real nudge);
    // otherwise it's the same pill without the glow, a plain "Move to bottom"
    // jump button. `atBot` (the tight AT_BOTTOM_PX check) keeps its OLD job
    // here: clearing unread. In the in-between state — last message partially
    // visible but not at the bottom — the pill hides, but unread is NOT
    // cleared: the user hasn't actually reached the bottom.
    updateScrollAffordance(atBot) {
        if (atBot) {
            this.unreadCount = 0;
            this.hideNewMessagePill();
        } else if (this.lastMessageFullyOutOfView()) {
            this.showNewMessagePill();
        } else {
            this.hideNewMessagePill();
        }
    }

    showNewMessagePill() {
        if (!this.pillEl) this.createNewMessagePill();
        if (!this.pillEl) return;
        // Touch classList only on an actual hidden→shown flip (the scroll
        // handler re-derives visibility on every event) — but ALWAYS refresh
        // the glow/label: unread can arrive while the pill is already up.
        if (!this.pillShown) {
            this.pillShown = true;
            this.pillEl.classList.add('bt-new-msg-pill-visible');
        }
        this.refreshPillContent();
    }

    hideNewMessagePill() {
        if (!this.pillShown) return;
        this.pillShown = false;
        if (this.pillEl) this.pillEl.classList.remove('bt-new-msg-pill-visible');
    }

    // Glow + "New messages" only while there's unread content; otherwise the
    // plain "Move to bottom" form (same popup, no glow).
    refreshPillContent() {
        if (!this.pillEl) return;
        const hasUnread = this.unreadCount > 0;
        this.pillEl.classList.toggle('bt-new-msg-pill-glow', hasUnread);
        if (this.pillLabelEl) {
            this.pillLabelEl.textContent = hasUnread ? 'New messages' : 'Move to bottom';
        }
    }

    // Anchor above the composer so queues, attachments and growing drafts
    // cannot overlap it. Append once and toggle visibility. Click →
    // re-engage follow mode and scroll to the bottom.
    createNewMessagePill() {
        const app = this.container?.closest('.bt-app') ||
                    this.container?.parentElement;
        if (!app) return;
        const pill = document.createElement('button');
        pill.type = 'button';
        pill.className = 'bt-new-msg-pill';
        const arrow = document.createElement('span');
        arrow.className = 'bt-new-msg-pill-arrow';
        arrow.textContent = '↓';
        const label = document.createElement('span');
        label.className = 'bt-new-msg-pill-label';
        label.textContent = 'Move to bottom';
        pill.appendChild(arrow);
        pill.appendChild(label);
        pill.addEventListener('click', (e) => {
            e.preventDefault();
            this.setFollowMode(true);
            this.scrollToBottom();
        });
        const inputArea = app.querySelector('.bt-input-area');
        if (!inputArea) return;
        inputArea.appendChild(pill);
        this.pillEl = pill;
        this.pillLabelEl = label;
    }
}

// Conservative "this inline code span IS a file path" test: at least one
// directory separator, path-ish characters only, optional trailing :line —
// and not a URL. Bare names like `foo.jl` stay unlinked on purpose (too many
// false positives: package names, "Project.toml" as a concept, …).
const PATH_RE = /^(~|\.{1,2})?\/?[\w.@+-]+(\/[\w.@+-]+)+(:\d+)?$/;

// `text` onto the clipboard; rejects when it did not get there. The same as
// COPY_TEXT_JS (styles.jl), which the Julia-rendered Copy buttons use.
function copyText(text) {
    const legacy = () => {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.setAttribute('readonly', '');
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        ta.setSelectionRange(0, text.length);
        const ok = document.execCommand('copy');
        ta.remove();
        return ok ? Promise.resolve() : Promise.reject(new Error('copy refused'));
    };
    return navigator.clipboard && window.isSecureContext ?
        navigator.clipboard.writeText(text).catch(legacy) : legacy();
}

// Give every fenced code block (<pre>) in a rendered message a hover action row
// (copy · download), Signal-style. The <pre> is wrapped in a positioned
// `.bt-code-wrap` so the buttons can float top-right without disturbing layout.
// Idempotent: re-running on a re-rendered message (streaming) won't double-wrap.
function decorateCodeBlocks(rootEl) {
    rootEl.querySelectorAll('pre').forEach((pre) => {
        if (pre.dataset.btDecorated || pre.closest('.bt-code-wrap')) return;
        pre.dataset.btDecorated = '1';
        const wrap = document.createElement('div');
        wrap.className = 'bt-code-wrap';
        pre.parentNode.insertBefore(wrap, pre);
        wrap.appendChild(pre);
        const codeText = () => (pre.innerText || '');
        const mk = (cls, glyph, title, onClick) => {
            const b = document.createElement('button');
            b.type = 'button';
            b.className = 'bt-code-action ' + cls;
            b.title = title;
            b.textContent = glyph;
            b.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); onClick(b); });
            return b;
        };
        const copyBtn = mk('bt-code-copy', '⧉', 'Copy code', (b) => {
            const say = t => { b.textContent = t; setTimeout(() => { b.textContent = '⧉'; }, 1200); };
            copyText(codeText()).then(() => say('✓'), () => say('✕'));
        });
        const dlBtn = mk('bt-code-download', '⤓', 'Download', () => {
            const blob = new Blob([codeText()], { type: 'text/plain' });
            const a = document.createElement('a');
            a.href = URL.createObjectURL(blob);
            a.download = 'snippet.txt';
            document.body.appendChild(a); a.click(); a.remove();
            setTimeout(() => URL.revokeObjectURL(a.href), 1000);
        });
        const actions = document.createElement('div');
        actions.className = 'bt-code-actions';
        actions.appendChild(copyBtn);
        actions.appendChild(dlBtn);
        wrap.appendChild(actions);
    });
}

// Turn paths inside an agent message into clickable workspace links. This
// covers both actual Markdown anchors and inline `code`; fenced code blocks
// are skipped because linkifying inside code listings is noise.
// Recover the WORKER path from a Markdown anchor. CommonMark emits a link to
// /work/media/clip.mp4 as an anchor with that href; left alone, the browser
// turns it into http://dashboard/work/... and navigates to a route the server
// cannot serve. Same-origin absolute URLs are the same failure after the
// browser has resolved the href, so accept those too. Real web links remain
// ordinary anchors.
// A malformed percent escape is still a valid Unix filename: keep it as written.
function decodePath(text) {
    try { return decodeURIComponent(text); }
    catch (error) { if (!(error instanceof URIError)) throw error; return text; }
}

function markdownWorkerPath(anchor) {
    const raw = (anchor.getAttribute('href') || '').trim();
    if (!raw || raw.startsWith('#') || raw.startsWith('?')) return null;
    if (/^(mailto|tel|data|blob|javascript):/i.test(raw)) return null;

    let path = raw;
    let url = null;
    try { url = new URL(raw, window.location.href); }
    catch (error) { if (!(error instanceof TypeError)) throw error; }
    if (url === null) {
        // Not a URL: keep the raw relative path; the server resolves it
        // against the project's worker cwd.
        path = decodePath(raw);
    } else if (url.protocol === 'file:') {
        path = decodePath(url.pathname);
    } else if (url.protocol === 'http:' || url.protocol === 'https:') {
        // An explicitly external URL is a web link. A same-dashboard URL
        // is what a leading worker path becomes in the browser.
        if (url.origin !== window.location.origin) return null;
        path = decodePath(url.pathname);
    } else {
        return null;
    }

    // For relative hrefs URL() above resolves against the dashboard origin;
    // preserve the relative spelling so media/clip.mp4 resolves against the
    // PROJECT rather than becoming /media/clip.mp4 on the worker.
    if (!/^(?:[a-z][a-z0-9+.-]*:|\/)/i.test(raw)) {
        path = decodePath(raw.split(/[?#]/, 1)[0]);
    }
    return path || null;
}

function linkifyPaths(rootEl) {
    rootEl.querySelectorAll('a[href]').forEach((el) => {
        if (el.classList.contains('bt-path-link')) return;
        const path = markdownWorkerPath(el);
        if (!path) return;
        el.classList.add('bt-path-link');
        el.dataset.path = path;
    });
    rootEl.querySelectorAll('code').forEach((el) => {
        if (el.closest('pre') || el.closest('a')) return;
        const text = (el.textContent || '').trim();
        if (!PATH_RE.test(text) || text.includes('://')) return;
        el.classList.add('bt-path-link');
        el.dataset.path = text;
    });
}

// Shared image viewer: only the source is reused, never thumbnail classes,
// inline sizing, lazy-loading or tool-body ids/handlers.
export function openLightbox(media) {
    document.querySelector('.bt-lightbox-overlay')?.closeLightbox();
    const overlay = document.createElement('div');
    overlay.className = 'bt-lightbox-overlay';
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');
    overlay.setAttribute('aria-label', 'Enlarged image');
    const big = document.createElement('img');
    big.src = media.currentSrc || media.src;
    big.alt = media.alt || '';
    big.className = 'bt-lightbox-media';
    overlay.appendChild(big);
    const close = () => { overlay.remove(); document.removeEventListener('keydown', onkey, true); };
    overlay.closeLightbox = close;
    const onkey = e => {
        if (e.key !== 'Escape') return;
        e.preventDefault(); e.stopImmediatePropagation(); close();
    };
    overlay.addEventListener('click', close);
    document.addEventListener('keydown', onkey, true);
    document.body.appendChild(overlay);
}

// ↑ chips for the evals a card waits on (`msg.jumps`: label, store index, id,
// title). A click brings that card into view (delegated, see jumpToMessage).
function jumpChipsHTML(jumps) {
    if (!Array.isArray(jumps)) return '';
    return jumps.map(j =>
        `<button type="button" class="bt-tool-jump" data-jump-index="${Number(j.index)}"` +
        ` data-jump-id="${escapeAttr(String(j.id))}" title="${escapeAttr(String(j.title || ''))}">` +
        `↑ ${escapeHTML(String(j.label))}</button>`).join('');
}

function escapeHTML(str) {
    return String(str).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function escapeAttr(str) {
    return escapeHTML(str).replace(/"/g, '&quot;');
}

// Case-insensitive subsequence test ("bt_eval" ⊆ "bt_julia_eval") — the
// lens autocomplete matcher; mirrors `subseq_match` in lens.jl.
function _subseqMatch(needle, haystack) {
    if (!needle) return true;
    const n = needle.toLowerCase(), h = haystack.toLowerCase();
    let j = 0;
    for (let i = 0; i < h.length && j < n.length; i++) if (h[i] === n[j]) j++;
    return j === n.length;
}

// Compact elapsed-time formatting for the inline tool timer + taskbar slot.
// `< 60s` shows seconds; minutes-and-up shows `<m>m<s>s`. Only callers that
// have already crossed the 1s threshold reach here, so we never render "0s".
function _formatElapsed(sec) {
    if (sec < 60) return `${Math.round(sec)}s`;
    const m = Math.floor(sec / 60);
    const s = Math.round(sec - m * 60);
    return s === 0 ? `${m}m` : `${m}m${s}s`;
}

// Write a tool pill's duration into its `.bt-tool-timer` from its data
// attrs. A finished pill freezes at finished−started (event-driven writes on
// creation of an already-finished pill and on the terminal update); a LIVE
// pill (no finished attr) shows elapsed against the browser clock, driven by
// the shared 1Hz ticker (`ensureElapsedTicker`) — a running eval sits at
// "pending" for its whole MCP call on the real wire, and without a clock
// there's no telling a hang from slow work. The value is always RECOMPUTED
// from the server's `started_at` timestamp (never accumulated tick counts),
// so background-throttled or missed ticks and machine sleep can't drift it,
// and a page reloaded mid-run still shows the true elapsed. Clamped ≥ 0
// against minor server/browser clock skew.
function _writeToolElapsed(node) {
    if (!node) return;
    const timer = node.querySelector('.bt-tool-timer');
    if (!timer) return;
    const started  = parseFloat(node.dataset.toolStarted  ?? '0');
    const finished = parseFloat(node.dataset.toolFinished ?? '0');
    if (!started) return;
    const dt = Math.max(0, (finished || Date.now() / 1000) - started);
    timer.textContent = dt > 1 ? _formatElapsed(dt) : '';
}

// Chunked base64 encoder. `btoa(String.fromCharCode(...new Uint8Array(buf)))`
// breaks on large buffers (browser arg-count limit, ~64k); we chunk through
// 32k bytes at a time.
function arrayBufferToBase64(buf) {
    const bytes = new Uint8Array(buf);
    let binary = '';
    const CHUNK = 0x8000;
    for (let i = 0; i < bytes.length; i += CHUNK) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
    }
    return btoa(binary);
}

// ── Searchable config select (model search) ────────────────────────────────
// Replaces the native <select> when there are many choices (e.g. OpenCode's
// ~100 models). All filtering is pure DOM — no Julia round-trips per keystroke.

// Module exports, not `window`. The inline `onclick=` handlers Julia writes are
// outside module scope, which is what the globals were for — but they can reach
// in the same way everything else here does, through
// `$(ChatLib).then(lib => lib.msearch…)`. Same pattern as `toolSlot`, and the
// same reason: a global is a name every other script on the page can see and
// nothing declares a dependency on.
//
// The call sites resolve `event.currentTarget` BEFORE awaiting the module —
// `currentTarget` is null once dispatch finishes, so reading it inside the
// `.then()` would hand these functions nothing.
export function msearchFilter(inputEl) {
    const q = inputEl.value.toLowerCase();
    const wrap = inputEl.closest('.bt-msearch');
    wrap.querySelectorAll('.bt-msearch-item').forEach(item => {
        item.hidden = q.length > 0 && !item.dataset.label.includes(q);
    });
}

export function msearchOpen(triggerEl) {
    // Close any other open dropdown first.
    document.querySelectorAll('.bt-msearch-open').forEach(el =>
        el.classList.remove('bt-msearch-open'));
    const wrap = triggerEl.closest('.bt-msearch');
    wrap.classList.add('bt-msearch-open');
    // The list is `position: fixed` (the header's session group clips, so an
    // absolute one would be cut off at its edge) — so place it under the
    // trigger here, flipping above / nudging left when the viewport runs out.
    const list = wrap.querySelector('.bt-msearch-list');
    if (list) {
        const t = triggerEl.getBoundingClientRect();
        list.style.top = '0px';
        list.style.left = '0px';
        const l = list.getBoundingClientRect();
        const below = t.bottom + 4;
        const top = (below + l.height > window.innerHeight - 8 && t.top - 4 - l.height > 8)
            ? t.top - 4 - l.height : below;
        list.style.top = `${Math.max(8, top)}px`;
        list.style.left = `${Math.max(8, Math.min(t.left, window.innerWidth - l.width - 8))}px`;
    }
    const input = wrap.querySelector('.bt-msearch-input');
    if (input) { input.value = ''; msearchFilter(input); }
    // Register close-on-outside-click after one frame so the triggering click
    // doesn't immediately close the dropdown we just opened.
    requestAnimationFrame(() => {
        function onOutside(e) {
            if (!e.target.closest('.bt-msearch-open')) {
                document.querySelectorAll('.bt-msearch-open').forEach(el =>
                    el.classList.remove('bt-msearch-open'));
                document.removeEventListener('click', onOutside, true);
            }
        }
        document.addEventListener('click', onOutside, true);
        if (input) input.focus();
    });
}

export function msearchSelect(itemEl, pickObs, cfgId, value) {
    pickObs.notify([cfgId, value]);
    const wrap = itemEl.closest('.bt-msearch');
    if (wrap) wrap.classList.remove('bt-msearch-open');
}

// ── ES6 module exports ─────────────────────────────────────────────────────
// `connect(node, comm)` is the public entry point — Julia calls it inline
// via `js"$(ChatLib).then(lib => lib.connect($(node), $(comm)))"`. The
// MutationObserver auto-cleans the BonitoChat instance when its container
// leaves the document, so no Julia-side lifecycle plumbing is needed.
// Live chat instances, so `toolSlot` can find tool-body slots on nodes the
// virtual scroll currently holds DETACHED (cached but not in the document).
// The server's tool.render reply mounts via this helper — filling a detached
// node is fine, the content shows when the node is re-inserted. Without it,
// a reply racing an eviction was silently dropped and the body stayed on
// "loading…".
// Module scope, not `window`. This module is instantiated once per page, so
// module scope already IS the singleton a global was standing in for. It used
// to be mirrored to `window.__btChats` for debugging, but nothing read it:
// every test and console probe reaches a chat the honest way, through the DOM
// node that owns it (`document.querySelector('.bt-messages').__bt_chat`).
const CHAT_INSTANCES = new Set();

// Find the tool-body slot for `id` — in the live DOM, or on a cached node a
// virtual-scroll window currently holds detached. A module export (Julia's
// dom_in_js callbacks resolve it via `$(ChatLib).then(lib => lib.toolSlot(...))`)
// instead of the former `window._btToolSlot` global.
// The tool.render reply put a body into `slot`: tell the chat that owns it.
export function bodyMounted(slot) {
    const row = slot.closest('.bt-tool-msg');
    if (!row) return;
    for (const chat of CHAT_INSTANCES) {
        if (chat.container.contains(row)) { chat.onBodyMounted(row); return; }
    }
}

export function toolSlot(id) {
    const direct = document.querySelector(
        `.bt-tool-body[data-tool-id="${CSS.escape(id)}"]`);
    if (direct) return direct;
    for (const chat of CHAT_INSTANCES) {
        const node = chat.nodeById.get(id);
        const slot = node && node.querySelector('.bt-tool-body');
        if (slot) return slot;
    }
    return null;
}

// Write every chat's pending draft to storage now. A draft is written 250ms
// after the last keystroke; the connection guard reloads a page only when no
// typed text would be lost, and text from the last 250ms was not saved yet.
export function flushDrafts() {
    for (const chat of CHAT_INSTANCES) chat.flushDraft?.();
}

export function connect(node, comm, init = {}) {
    const chat = new BonitoChat(node, comm, init);
    // Late-mount snapshot: comm events fired before this tab connected are
    // gone, so the server bakes the current slash-command set into the init
    // call; live changes keep flowing via the 'commands' comm event.
    if (Array.isArray(init.commands)) chat.slashCommands = init.commands;
    node.__bt_chat = chat;     // devtools/test inspection hook
    CHAT_INSTANCES.add(chat);

    const parent = node.parentNode;
    if (parent) {
        const mo = new MutationObserver(() => {
            if (!node.isConnected) {
                mo.disconnect();
                CHAT_INSTANCES.delete(chat);
                if (!chat.destroyed) chat.destroy();
            }
        });
        mo.observe(parent, { childList: true });
    }
    return chat;
}

export { BonitoChat };

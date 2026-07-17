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
export class Collapsable {
    constructor(headerEl, bodyEl, opts = {}) {
        this.header  = headerEl;
        this.body    = bodyEl;
        this.toggle  = opts.toggleEl || null;
        this.native  = opts.native || false;          // hosted in <details>/<summary>
        this.editMode = opts.editMode || false;
        this.compactHeight  = opts.compactHeight  || 240;
        this.expandedHeight = opts.expandedHeight || 2000;
        this.fetchEachExpand   = this.editMode ? false : (opts.fetchEachExpand || false);
        this.discardOnCollapse = this.editMode ? false : (opts.discardOnCollapse || false);
        this.onExpand = opts.onExpand || null;
        this.lazy     = !!this.onExpand;
        this.loaded   = !this.lazy;                    // eager bodies start loaded

        // Everything (edit tools included) starts collapsed. Edit tools are
        // in COMPACT visual state (Monaco capped to 240px) but their body
        // element is rendered/visible from the start; the initial
        // `setMaxHeight` lookup is deferred to the first toggle (Monaco may
        // not have finished its async init when createNode runs).
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
            if (this.editMode) {
                // Body stays visible; size via Monaco's own API so the
                // resize is animated by Monaco itself instead of CSS clip.
                this.body.style.display = '';
                this._applyEditHeight(expanded ? this.expandedHeight : this.compactHeight);
            } else {
                this.body.style.display = expanded ? '' : 'none';
            }
        }
        // Lazy body fetch. editMode pills normally keep their streamed-in
        // body across toggles and only resize Monaco — but a HISTORY-REPLAYED
        // edit pill starts with an EMPTY body (its diff lives server-side
        // until a tool.render round trip), so gating the fetch on
        // `!editMode` alone made replayed Edit pills permanently
        // unexpandable: the arrow flipped, `_applyEditHeight` sized zero
        // Monaco divs, and nothing ever appeared. Fetch whenever the body
        // has nothing to show.
        const editBodyEmpty = this.editMode && this.body.childElementCount === 0;
        if (expanded && (!this.editMode || editBodyEmpty)) {
            if (this.lazy && (!this.loaded || this.fetchEachExpand)) {
                this.body.innerHTML = '<div class="bt-collapsable-loading">loading…</div>';
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
    // editor finished tearing down or never mounted.
    _applyEditHeight(h) {
        const divs = this.body.querySelectorAll('.monaco-diff-editor-div');
        divs.forEach(div => {
            const monaco = div.__btMonacoDiff;
            if (monaco && typeof monaco.setMaxHeight === 'function') monaco.setMaxHeight(h);
        });
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

class BonitoChat {
    constructor(container, comm) {
        this.container = container;
        this.comm      = comm;
        this.destroyed = false;

        this.cache    = new Map();  // idx (0-based) → DOMNode
        this.heights  = new Map();
        this.rendered = new Set();
        this.nodeById = new Map();  // msg_id → DOMNode  (for streaming updates)
        this.observed = new Set();  // idx currently watched by the shared RO

        this.totalCount    = 0;
        this.EST_HEIGHT    = 80;    // adapted to the measured average, see _measureNodes
        this.OVERSCAN      = 8;
        this.initialLoad   = false;
        this._bootstrapped = false; // first msgs.count seen (guards initialLoad re-arm)
        this._measSum      = 0;     // running mean of measured heights → EST_HEIGHT
        this._measCount    = 0;
        this._spacerTopH   = -1;    // last written spacer px (skip no-op style writes)
        this._spacerBotH   = -1;
        this._requestedAt  = new Map(); // idx → time of in-flight msgs.request
        // Bumped on msgs.reload (the server SPLICED history — all indices
        // shifted). Every msgs.request carries it and the server echoes it
        // back on msgs.range; a reply from before the reload is dropped in
        // onRange instead of caching old-world nodes at new-world indices.
        this._epoch        = 0;
        this.STREAM_APPLY_MS = 100; // min interval between streaming innerHTML applies

        // ONE shared ResizeObserver for every node in the render window.
        // (A fresh observer per node made every window enter/exit allocate +
        // tear down an observer — churn on each scroll tick.)
        //
        // Heights are recorded as the BORDER BOX so they agree with the
        // offsetHeight that `_measureNodes` records: `contentRect` is the
        // CONTENT box and undercounts every bubble by its padding + border
        // (~22px for a text bubble). That undercount accumulated across the
        // render window to MORE than the overscan, so the computed window
        // start landed inside the viewport — visible bubbles were evicted
        // ("bubbles hide before they leave the screen") and every eviction
        // shrank scrollHeight mid-scroll (stutter).
        this._ro = new ResizeObserver((entries) => {
            if (this.destroyed) return;
            let changed = false;
            for (const e of entries) {
                const idx = e.target.__btIdx;
                if (idx === undefined) continue;
                const h = (e.borderBoxSize && e.borderBoxSize.length)
                    ? e.borderBoxSize[0].blockSize
                    : e.target.offsetHeight;
                // h>0 guard keeps the last measured height through a
                // hide/show cycle, so re-showing restores exact sizes.
                if (h > 0 && this.heights.get(idx) !== h) {
                    this.heights.set(idx, h);
                    changed = true;
                }
            }
            // Apply corrections NOW (rAF-batched) instead of letting them
            // ambush the next scroll tick. EXCEPT mid-scrollbar-drag:
            // corrections then wait for release — re-spacing under a held
            // thumb is exactly the flicker.
            if (changed && !this._scrollbarDrag) this._queueRefresh();
        });

        // ── Live-app keep-alive LRU ──────────────────────────────────────
        // App embeds (msg.kind === 'bonito_app', marked data-bt-app) host a
        // live Bonito sub-session + WGLMakie WebGL context. Plain removal on
        // scroll-off closes the sub-session and disposes the context, so the
        // app comes back dead. Instead we PARK such nodes in place via
        // `display:none`: the node never leaves its parent, so Bonito's
        // delete-observer never fires (session stays open) and the canvas
        // stays under document.body (WGLMakie keeps the context); on-demand
        // rendering means a hidden app costs ~0. `parked` holds the idxs that
        // are display:none-parked (still in `rendered` so insertSorted/spacer
        // math is unchanged). The browser hard-caps live WebGL contexts (~16,
        // varies) and DESTROYS the oldest beyond that, so we keep at most
        // APP_KEEPALIVE parked alive and clamp it well under that ceiling;
        // the LRU-oldest beyond it spills to a snapshot+reload (Stage 2).
        // Clamp hard: the browser destroys the oldest WebGL context past its
        // ceiling (~16, varies), so keep this well under it. An optional
        // window.BT_APP_KEEPALIVE override (set before connect) is clamped too —
        // asking for 100 silently gives 10, never the danger zone.
        const wantKeepalive = (typeof window !== 'undefined' && Number.isFinite(window.BT_APP_KEEPALIVE))
            ? window.BT_APP_KEEPALIVE : 6;
        this.APP_KEEPALIVE = Math.min(10, Math.max(0, wantKeepalive));
        this.parked = new Set();   // idx → parked (display:none, alive, off-screen)
        this.appLru = [];          // app idxs, least-recently-visible first
        // The .bt-messages flex column separates children with a row gap.
        // The virtual height math must count it per item or the virtual
        // geometry drifts ~gap px per message from the real scrollHeight —
        // in long chats that drift exceeds the overscan and the bottom
        // "bounces" away while scrolling down. Read it from the computed
        // style so a CSS change can't silently re-introduce the drift.
        this.ITEM_GAP = parseFloat(getComputedStyle(container).rowGap) || 0;
        // A rendered node's real offsetTop = cumHeight(0, idx) + PAD_TOP + one
        // ITEM_GAP: the container's top padding, plus the flex row-gap between the
        // (always-present) top spacer and the first node — every OTHER gap is
        // already folded into effHeight, and they telescope so this constant is
        // window-position-independent. `_restoreAnchor`'s virtual fallback needs
        // it to convert a cumHeight() position into a real scrollTop.
        this.PAD_TOP = parseFloat(getComputedStyle(container).paddingTop) || 0;

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
        // actual flip — see _showNewMessagePill/_hideNewMessagePill.
        this._pillShown = false;
        // "At bottom" is intentionally tight here (20px) — the loose
        // 200px threshold the old code used was a workaround for
        // chunked-text-during-burst race conditions. With explicit
        // followMode there's no race: chase scrolls to scrollHeight
        // unconditionally, so being "at the bottom" means actually
        // there, not "near enough".
        this.AT_BOTTOM_PX = 20;
        // Last processed scroll position — the delta against it gives a user
        // scroll its DIRECTION (re-engage is downward-only, see
        // _applyUserScroll). Kept fresh by the scroll handler and by every
        // programmatic scrollTop write that may not fire a scroll event
        // (offscreen renderers): scrollToBottom, the re-pin in updateVisible,
        // onShown's restore, the lens reset, and the pan/momentum writes.
        this._prevScrollTop = container.scrollTop;

        this.spacerTop    = container.querySelector('.bt-spacer-top');
        this.spacerBottom = container.querySelector('.bt-spacer-bottom');
        // ── Filter / lens state ────────────────────────────────────────
        // The per-tool filter toolbar is GONE — the header lens bar
        // (`_setupLens`) replaces it. `keyByIdx` still drives effHeight, and
        // the lens hides messages by a server-computed visible-index set
        // (`lensVisible`). Native-media toggles live in the lens bar now.
        this.toolbarEl   = (container.closest('.bt-app') || container.parentElement)
            .querySelector('.bt-chat-toolbar');
        if (this.toolbarEl) this.toolbarEl.style.display = 'none';
        this.hiddenTypes = new Set(DEFAULT_HIDDEN);   // kept for DEFAULT_HIDDEN
        this.seenTypes   = new Set();   // keys seen (drives the waiting line)
        this.keyByIdx    = new Map();   // idx → filter key (drives effHeight)
        this.filterRow   = null;        // no per-tool checkboxes anymore
        this.nativeImages = true;       // bt_show image results: bare by default
        this.nativeVideos = true;       // bt_show video results: ditto
        // Lens: server returns the set of VISIBLE 0-based indices for the
        // current query (+ per-index actions). `lensActive=false` shows all.
        this.lensActive  = false;
        this.lensVisible = null;        // Set<idx> when active
        this.lensActions = null;        // Map<idx, action>
        this.lensQuery   = '';          // the query this tab currently applies
        this.lensVocab   = [];          // autocomplete keys (from the server)
        this.savedLenses = [];          // global favorites (from the server)
        this.lensClauses = [];          // committed pills: [{sign:'+'|'-', text}]
        this.lensPendingSign = '+';     // sign for the clause being composed
        // Busy dots + thinking indicator are scroll CONTENT — they sit
        // between the bottom spacer and the overscroll tail so they appear
        // directly under the last message (not below the tail, down by the
        // composer). Plain content like the tail: the virtual-scroll
        // geometry never tracks them.
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
        // Overscroll tail: empty space below the last message the user can
        // scroll into (~30% of the pane; sized in the container RO).
        this.tailEl       = container.querySelector('.bt-messages-tail');
        this._sizeTail();
        // Off-screen measuring host: prefetched nodes get REAL heights here
        // before they're ever rendered, so the virtual geometry is exact
        // everywhere and scrollbar drags see a stable scrollHeight (see
        // `_measureNodes`). Width is synced to the messages content box so
        // text wrapping (and thus heights) match the live layout.
        this.measureEl = document.createElement('div');
        this.measureEl.className = 'bt-measure';
        container.parentElement.appendChild(this.measureEl);
        // Start the settle watch immediately: its hard cap must dismiss the
        // load overlay (sidebar.jl chat_waiting_view) even if the comm
        // bootstrap stalls.
        this._startSettle();

        // Single subscription. `comm` is a Bonito Observable bridged via
        // WS; every message Julia sets via `model.comm[] = {...}` arrives here.
        comm.on((msg) => {
            // Returning `false` deregisters the callback (Observable.notify
            // contract) — a destroyed instance must not stay subscribed.
            if (this.destroyed) return false;
            if (msg && typeof msg === 'object') this.dispatch(msg);
        });

        // Ask Julia for the current message count. The reply arrives as
        // `{type: "msgs.count", n}` and triggers the initial range fetch.
        // If Julia already pushed a count (e.g., on a re-mount the
        // observable still holds the latest dict), bootstrap from that
        // immediately so we don't double-render.
        const cur = comm.value;
        if (cur && cur.type === 'msgs.count' && cur.n > 0) {
            this.applyCount(cur.n);
        } else if (cur && cur.type === 'msgs.range') {
            // Re-mount of a chat that already has messages cached.
            this._startSettle();
            this.onRange(cur);
            this._startPrefetch();
        }
        comm.notify({type: 'init'});

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
        // nothing"). `_pendingUserScroll` closes it: the FIRST scroll
        // event after a gesture is user-driven no matter how long the
        // intervening frame took. Consumed on use; wall-clock can't
        // expire it because a blocked main thread can't deliver an
        // unrelated scroll event in between anyway.
        this._lastUserInputT = 0;
        this._pendingUserScroll = false;
        const markUserInput = () => {
            this._lastUserInputT = performance.now();
            this._pendingUserScroll = true;
            this._cancelPendingScroll();
        };
        container.addEventListener('wheel',      markUserInput, { passive: true });
        container.addEventListener('touchstart', markUserInput, { passive: true });
        container.addEventListener('touchmove',  markUserInput, { passive: true });
        container.addEventListener('keydown',    markUserInput, { passive: true });
        this._markUserInput = markUserInput;

        // File-path links: ONE delegated listener for every `.bt-path-link`
        // in the chat (tool titles, diff headers, search hits, linkified
        // paths in agent messages) → open the file in the plotpane editor.
        // Capture phase, so a click on a linked TOOL TITLE opens the editor
        // instead of toggling the pill's expand state (the Collapsable
        // listener sits on the header, below us on the capture path).
        container.addEventListener('click', (e) => {
            const link = e.target.closest('.bt-path-link');
            if (!link || !container.contains(link)) return;
            const path = link.dataset.path || link.textContent.trim();
            if (!path) return;
            e.preventDefault();
            e.stopPropagation();
            this.comm.notify({ type: 'edit_file', path });
        }, { capture: true });

        // Scrollbar drags emit NO wheel/touch/key events — only mousedown on
        // the container (the scrollbar is part of its hit area) and then
        // scroll events while the button is held, possibly for much longer
        // than the 400ms recency window. Track the held state explicitly so
        // a drag is always classified as user-driven; otherwise the chase
        // treats it as a layout shift and yanks the thumb back to the
        // bottom ("scrollbar feels stuck"). mouseup lands on window — the
        // pointer often leaves the container before release.
        this._scrollbarDrag = false;
        this._onContainerMouseDown = () => {
            this._scrollbarDrag = true;
            markUserInput();
        };
        this._onWindowMouseUp      = () => {
            // Window-level listener: a pane whose subtree was unmounted above
            // the direct parent (MutationObserver in `connect` can't see
            // that) self-destroys lazily here.
            if (!this.container.isConnected) { this._lazyDestroy(); return; }
            if (!this._scrollbarDrag) return;
            this._scrollbarDrag = false;
            markUserInput();   // the release tick still counts as user input
            // Auto-expands deferred during the drag (image bodies inflate
            // scrollHeight — poison for a held thumb): mount them now. Only
            // rendered nodes can carry a deferred flag from a mid-drag
            // insert; detached flagged nodes expand on their insertSorted.
            for (const idx of this.rendered) {
                const node = this.cache.get(idx);
                if (node && node.isConnected && node.dataset.btAutoExpand) {
                    delete node.dataset.btAutoExpand;
                    node.collapsable?.setExpanded(true);
                }
            }
            this._queueRefresh();   // re-true spacers to the corrected heights
        };
        container.addEventListener('mousedown', this._onContainerMouseDown, { passive: true });
        window.addEventListener('mouseup', this._onWindowMouseUp, { passive: true });

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

        this._overscroll  = 0;
        this._panState    = null;
        this._momentumRaf = null;
        this._springRaf   = null;

        const setOverscroll = (v) => {
            this._overscroll = v;
            this.container.style.setProperty('--bt-overscroll', v + 'px');
            // The rubberband translateY is applied to EVERY rendered child;
            // a non-`none` transform on each child turns one composited scroll
            // layer into N stacking contexts, hurting steady-state scroll
            // smoothness. Gate it behind a class so the transform exists ONLY
            // during an active overscroll gesture (the only time it's needed),
            // and normal scrolling composites natively.
            this.container.classList.toggle('bt-overscrolling', v !== 0);
        };
        this._setOverscroll = setOverscroll;   // so onHidden can clear it

        this._cancelMomentum = () => {
            if (this._momentumRaf !== null) {
                cancelAnimationFrame(this._momentumRaf);
                this._momentumRaf = null;
            }
            if (this._springRaf !== null) {
                cancelAnimationFrame(this._springRaf);
                this._springRaf = null;
            }
        };

        const springStep = () => {
            this._springRaf = null;
            if (this.destroyed) return;
            if (Math.abs(this._overscroll) < 0.5) { setOverscroll(0); return; }
            setOverscroll(this._overscroll * PAN_SPRING_DAMPING);
            this._springRaf = requestAnimationFrame(springStep);
        };

        const startSpring = () => {
            if (this._springRaf !== null || this._overscroll === 0) return;
            this._springRaf = requestAnimationFrame(springStep);
        };

        const momentumStep = (vel) => {
            this._momentumRaf = null;
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
                setOverscroll(this._overscroll + (-newTop) * PAN_BOUNCE_RESIST);
                this.container.scrollTop = 0;
                hitEdge = true;
            } else if (newTop > maxScroll) {
                setOverscroll(this._overscroll - (newTop - maxScroll) * PAN_BOUNCE_RESIST);
                this.container.scrollTop = maxScroll;
                hitEdge = true;
            } else {
                this.container.scrollTop = newTop;
            }
            // The fling is the user's own gesture: classify the follow-mode
            // transition at the write — offscreen renderers fire no scroll
            // event for programmatic scrollTop writes, and when the event
            // DOES fire it sees a zero delta against the synced
            // _prevScrollTop and skips (never classified twice).
            if (this.container.scrollTop !== prevTop) this._applyUserScroll(prevTop);
            this._prevScrollTop = this.container.scrollTop;
            // Keep the user-input timestamp fresh so the scroll handler
            // continues classifying these programmatic scrollTop writes
            // as user-driven (= the fling the user threw). Without this
            // the 400 ms recency window lapses mid-fling and a stray
            // layout shift re-engages chase, snapping to bottom in the
            // middle of the user's read.
            this._lastUserInputT = performance.now();
            // Edge-hit: absorb the remaining velocity into the bounce
            // and let the spring carry the rest. Otherwise decay.
            vel = hitEdge ? 0 : vel * PAN_FRICTION;
            if (Math.abs(vel) < PAN_MIN_VELOCITY) { startSpring(); return; }
            this._momentumRaf = requestAnimationFrame(() => momentumStep(vel));
        };

        const onPanDown = (e) => {
            if (e.pointerType === 'touch') return;
            if (e.button !== 0) return;
            if (this._scrollbarDrag) return;
            // Don't engage on form controls / buttons / links — let their
            // native semantics own the gesture. Closest is cheap.
            if (e.target.closest('input, textarea, button, a, select, [contenteditable]')) return;
            this._cancelMomentum();
            this._panState = {
                pointerId: e.pointerId,
                startY:    e.clientY,
                lastY:     e.clientY,
                lastT:     performance.now(),
                velocity:  0,
                engaged:   false,
            };
        };

        const onPanMove = (e) => {
            const p = this._panState;
            if (!p || e.pointerId !== p.pointerId) return;
            if (!p.engaged) {
                if (Math.abs(e.clientY - p.startY) < PAN_THRESHOLD) return;
                // The user started a text selection during the threshold
                // window: yield. Pan only fires when the gesture was
                // intended as a pan.
                const sel = window.getSelection();
                if (sel && sel.toString().length > 0) { this._panState = null; return; }
                p.engaged = true;
                p.lastY = e.clientY;
                p.lastT = performance.now();
                try { this.container.setPointerCapture(e.pointerId); } catch (_) {}
                this.container.classList.add('bt-messages-grabbing');
                // Pan acts like a wheel: cancels pending chase + marks
                // user input so the scroll handler treats subsequent
                // scrollTop writes as user-driven.
                this._lastUserInputT = performance.now();
                this._cancelPendingScroll();
            }
            e.preventDefault();
            const now = performance.now();
            const stepDy = e.clientY - p.lastY;
            const stepDt = now - p.lastT;
            const maxScroll = this.container.scrollHeight - this.container.clientHeight;
            const prevTop = this.container.scrollTop;
            const newTop = prevTop - stepDy;
            if (newTop < 0) {
                setOverscroll(this._overscroll + (-newTop) * PAN_RESIST);
                this.container.scrollTop = 0;
            } else if (newTop > maxScroll) {
                setOverscroll(this._overscroll - (newTop - maxScroll) * PAN_RESIST);
                this.container.scrollTop = maxScroll;
            } else {
                if (this._overscroll !== 0) setOverscroll(0);
                this.container.scrollTop = newTop;
            }
            // A drag step is the user's own gesture — classify it at the
            // write, exactly like the momentum step above (offscreen: no
            // scroll event; onscreen: the trailing event is a zero-delta
            // no-op). A downward re-engage never yanks mid-drag: the chase
            // rAF re-arms while the input timestamp stays fresh.
            if (this.container.scrollTop !== prevTop) this._applyUserScroll(prevTop);
            this._prevScrollTop = this.container.scrollTop;
            if (stepDt > 0) {
                // Exponentially-smoothed velocity (px/ms): noise-resistant
                // and recency-biased so the release-instant velocity
                // approximates the last ~30 ms of motion.
                const instant = stepDy / stepDt;
                p.velocity = 0.65 * instant + 0.35 * p.velocity;
            }
            p.lastY = e.clientY;
            p.lastT = now;
            this._lastUserInputT = now;
        };

        const onPanUp = (e) => {
            const p = this._panState;
            if (!p || e.pointerId !== p.pointerId) return;
            const engaged = p.engaged;
            const vel     = p.velocity;
            this._panState = null;
            if (!engaged) return;
            try { this.container.releasePointerCapture(e.pointerId); } catch (_) {}
            this.container.classList.remove('bt-messages-grabbing');
            if (Math.abs(vel) > PAN_FLING_THRESHOLD) {
                this._momentumRaf = requestAnimationFrame(() => momentumStep(vel));
            } else if (this._overscroll !== 0) {
                startSpring();
            }
        };

        container.addEventListener('pointerdown',   onPanDown);
        container.addEventListener('pointermove',   onPanMove);
        container.addEventListener('pointerup',     onPanUp);
        container.addEventListener('pointercancel', onPanUp);
        this._onPanDown = onPanDown;
        this._onPanMove = onPanMove;
        this._onPanUp   = onPanUp;

        this._onScroll = () => {
            // A scroll event on a zero-height container carries no user intent:
            // hiding the pane (display:none on a chat switch) collapses
            // scrollTop to 0 and fires this handler. `atBottom()` is then
            // trivially true (0 - 0 - 0 < AT_BOTTOM_PX), so a switch made
            // within 400ms of a real scroll (still "userDriven") would flip
            // followMode back to true and chase the pane to the bottom on the
            // next onShown — the user's read position lost. Ignore it: the pane
            // has no viewport, so there is nothing to classify.
            if (this.container.clientHeight === 0) return;
            const userDriven = this._scrollbarDrag ||
                this._pendingUserScroll ||
                (performance.now() - this._lastUserInputT) < 400;
            this._pendingUserScroll = false;
            const atBot      = this.atBottom();
            // Direction comes from the delta since the last processed
            // position. A zero-delta event carries no movement — nothing to
            // classify. That also makes the async scroll event trailing a
            // pan/momentum scrollTop write (already classified at the write,
            // which synced _prevScrollTop) a no-op instead of a double count.
            const prevTop = this._prevScrollTop;
            this._prevScrollTop = this.container.scrollTop;
            if (userDriven) {
                // User-driven movement → the follow-mode transition lives in
                // _applyUserScroll (razor-thin disengage; generous,
                // downward-only re-engage at the pill's boundary).
                if (this.container.scrollTop !== prevTop) {
                    this._applyUserScroll(prevTop);
                }
            } else if (this.followMode && !atBot) {
                // Layout shift moved us off the bottom while in
                // follow mode (viewport resize / attachment-bar
                // pop-in). Re-anchor.
                this._queueScrollToBottom();
            }
            // The jump-to-bottom pill tracks the read position directly: shown
            // once the last message is completely out of view (plain), glowing
            // only when unread. atBot still owns the unread-clear.
            this._updateScrollAffordance(atBot);
            this.refresh();
        };
        container.addEventListener('scroll', this._onScroll, { passive: true });

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
        this._containerRO = new ResizeObserver(() => {
            if (this.destroyed) return;
            // A zero-height (hidden) container has nothing to chase — and the
            // re-show / restore is owned by onShown(), so don't fight it here.
            if (this.container.clientHeight === 0) return;
            this._sizeTail();
            if (this.followMode) this._queueScrollToBottom();
        });
        this._containerRO.observe(this.container);
        if (this.busyEl)     this._containerRO.observe(this.busyEl);
        if (this.waitingEl)  this._containerRO.observe(this.waitingEl);
        if (this.thinkingEl) this._containerRO.observe(this.thinkingEl);

        if (window.visualViewport) {
            this._onVPResize = () => this.onViewportResize();
            window.visualViewport.addEventListener('resize', this._onVPResize);
        }

        // Image attachments (paste / drag-drop). Wired AFTER the input area
        // is in the DOM, on a microtask so .bt-app's children are queryable.
        Promise.resolve().then(() => {
            this._setupInputs();
            this._setupLiveTicker();
            this._setupLens();
        });
    }

    destroy() {
        this.destroyed = true;
        if (this._onScroll) {
            this.container.removeEventListener('scroll', this._onScroll);
        }
        if (this._markUserInput) {
            this.container.removeEventListener('wheel',    this._markUserInput);
            this.container.removeEventListener('touchstart', this._markUserInput);
            this.container.removeEventListener('touchmove',  this._markUserInput);
            this.container.removeEventListener('keydown',  this._markUserInput);
        }
        if (this._onContainerMouseDown) {
            this.container.removeEventListener('mousedown', this._onContainerMouseDown);
        }
        if (this._onWindowMouseUp) {
            window.removeEventListener('mouseup', this._onWindowMouseUp);
        }
        if (this._onPanDown) {
            this.container.removeEventListener('pointerdown',   this._onPanDown);
            this.container.removeEventListener('pointermove',   this._onPanMove);
            this.container.removeEventListener('pointerup',     this._onPanUp);
            this.container.removeEventListener('pointercancel', this._onPanUp);
        }
        if (this._cancelMomentum) this._cancelMomentum();
        if (this._scrollRafId !== null && this._scrollRafId !== undefined) {
            cancelAnimationFrame(this._scrollRafId);
        }
        if (this._onVPResize && window.visualViewport) {
            window.visualViewport.removeEventListener('resize', this._onVPResize);
        }
        if (this._containerRO) {
            this._containerRO.disconnect();
        }
        if (this._ro) this._ro.disconnect();
        this.observed.clear();
        if (this._onPaste && this.textInput) {
            this.textInput.removeEventListener('paste', this._onPaste);
        }
        if (this._onTextInputKeyCapture && this.textInput) {
            this.textInput.removeEventListener('keydown', this._onTextInputKeyCapture, true);
        }
        if (this._onAppClickCapture && this.app) {
            this.app.removeEventListener('click', this._onAppClickCapture, true);
        }
        if (this._onEscapeKey) {
            document.removeEventListener('keydown', this._onEscapeKey, true);
        }
        if (this.app) {
            this._onDragOver  && this.app.removeEventListener('dragover',  this._onDragOver);
            this._onDragLeave && this.app.removeEventListener('dragleave', this._onDragLeave);
            this._onDrop      && this.app.removeEventListener('drop',      this._onDrop);
        }
        clearTimeout(this._attachErrorTimer);
        clearTimeout(this._prefetchTimer);
        // Torn down mid-settle: clear the in-progress flag so a successor
        // overlay doesn't read a stale "settling" state off the pane (the
        // overlay's own timeout failsafe covers the never-settled case).
        if (!this._settleDone && this._paneEl) delete this._paneEl.dataset.btSettling;
        if (this.measureEl) { this.measureEl.remove(); this.measureEl = null; }
        if (this._tickerId) {
            clearInterval(this._tickerId);
            this._tickerId = null;
        }
        if (this.taskbarEl && this._onTaskbarClick) {
            this.taskbarEl.removeEventListener('click', this._onTaskbarClick);
        }
        if (this._onLensDocClick) {
            document.removeEventListener('click', this._onLensDocClick);
        }
    }

    // Backstop teardown for an instance whose container left the document
    // without the `connect` MutationObserver seeing it (that observer only
    // watches the DIRECT parent's childList; an ancestor-level unmount slips
    // past). Document/window-level handlers call this when they notice
    // `container.isConnected === false`, so leaked instances clean up on the
    // next global event instead of reacting forever.
    _lazyDestroy() {
        if (this.destroyed) return;
        try { this.destroy(); } catch (_) { /* already half-gone */ }
        CHAT_INSTANCES.delete(this);
    }

    // Single dispatch table. Julia sends `{type, ...}`; we route here.
    dispatch(msg) {
        // Track incrementally-arriving counts: every message-creation event
        // includes `n`, the new total. We avoid a separate `msgs.count`
        // broadcast for the steady-state stream.
        if (typeof msg.n === 'number' && msg.n > this.totalCount) {
            this.totalCount = msg.n;
        }

        switch (msg.type) {
            case 'msgs.count':   return this.applyCount(msg.n);
            case 'msgs.reload':  return this.onMsgsReload(msg.n);
            case 'turn_begin':   this.turnSeq = msg.seq; return;
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
                if (this.followMode) this._queueScrollToBottom();
                return;
            case 'busy_end':
                this.busyEl?.classList.remove('bt-busy-active');
                if (this.followMode) this._queueScrollToBottom();
                return;
            case 'agent_final':  return this.onAgentFinal(msg);
            case 'thinking':     return this.onThinking(msg);
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
            case 'summary_final':return this.onSummaryFinal(msg);
            case 'attach_error':
                return this._showAttachError(msg.error || 'Attachment failed');
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

    // ── Range / virtual scroll ────────────────────────────────────────────

    // Full re-sync: the server SPLICED or rebuilt the history (a resumed
    // session's reconcile inserted messages mid-store), so every cached
    // index → node mapping is invalid. Tear the rendered window down and
    // re-run the initial mount cascade against the new total, pinned to the
    // bottom — the newest messages are what a sync is for.
    onMsgsReload(n) {
        for (const node of this.cache.values()) node.remove();
        this.cache.clear();
        this.heights.clear();
        this.rendered.clear();
        this.nodeById.clear();
        this.observed.clear();
        this._requestedAt.clear();
        this._cancelPendingScroll();
        // Indices shifted: invalidate every in-flight range reply (onRange
        // drops mismatching epochs) and restart the history backfill against
        // the new indices.
        this._epoch++;
        this._prefetchStarted = false;
        this._prefetchCursor  = null;
        this._prefetchPending = null;
        clearTimeout(this._prefetchTimer);
        this.totalCount    = 0;      // applyCount below re-sets it
        this._bootstrapped = false;  // re-arm the initial bottom-pin cascade
        this.followMode    = true;
        this.unreadCount   = 0;
        this.applyCount(n);
    }

    applyCount(n) {
        if (n <= 0) {
            // Empty chat: nothing to settle — dismiss the load overlay
            // right away.
            this._startSettle();
            this._settle();
            return;
        }
        this.totalCount  = n;
        // Only the FIRST count arms initial-mount behavior. `msgs.count` is
        // re-broadcast on a shared channel (another tab's init handshake, a
        // session restart), and re-arming `initialLoad` here made the NEXT
        // msgs.range — including ranges OTHER tabs requested — run the
        // initial scroll cascade: follow mode force-enabled and the pane
        // yanked to the bottom while the user was reading scrollback.
        if (!this._bootstrapped) {
            this._bootstrapped = true;
            this.initialLoad = true;
        }
        this._startSettle();
        this.refresh();
        this._startPrefetch();
    }

    // ── Settle watch (drives the load overlay) ────────────────────────────
    // The first second after mount is geometry soup: the visible window
    // renders, estimate heights correct to measurements, bt_show images
    // mount and resize their nodes — the scrollbar visibly pumps. The
    // dashboard's load overlay (sidebar.jl chat_waiting_view) covers the
    // pane through all of it; this module owns settle DETECTION and tells
    // the overlay when to move on:
    //   bt-chat-settling  (watch started — overlay flips to "Rendering
    //                      messages…")
    //   bt-chat-settled   (geometry quiet — overlay fades out)
    // Both are window events carrying the pane pid, mirrored as
    // data-bt-settling / data-bt-settled flags on the .bt-chatpane so an
    // overlay that mounts AFTER an event fired (kept-alive revisit) reads
    // the state synchronously. Settle = scrollHeight unchanged for ~10
    // frames once the initial scroll passes are done; image loads reset
    // the quiet counter via their height changes, so image-heavy chats
    // simply hold the overlay a little longer. Hard cap so a broken image
    // can never strand it.
    _startSettle() {
        if (this._settleWatch || this._settleDone) return;
        this._settleWatch  = true;
        this._settleT0     = performance.now();
        this._settleLastH  = -1;
        this._settleStable = 0;
        this._paneEl = this.container.closest('.bt-chatpane');
        if (this._paneEl) {
            delete this._paneEl.dataset.btSettled;
            this._paneEl.dataset.btSettling = '1';
        }
        this._announceSettle('bt-chat-settling');
        const watch = () => {
            if (this.destroyed || this._settleDone) return;
            const h = this.container.scrollHeight;
            if (h === this._settleLastH) this._settleStable++;
            else { this._settleStable = 0; this._settleLastH = h; }
            const elapsed = performance.now() - this._settleT0;
            // Quiet geometry alone isn't enough: a tool body still being
            // fetched (native bt_show images come from the worker) shows a
            // "loading…" placeholder with STABLE height, and a mounted
            // <img> may not have decoded yet — both would pop in right
            // after an early reveal ("saw the box flash"). Hold for them
            // too; the hard cap still guarantees the overlay lifts.
            // EXCEPT video bodies: a multi-GB bt_show fetch takes minutes,
            // not frames — the overlay must not ride out its hard cap on
            // every reload. Videos pop in when ready; the follow chase
            // absorbs the height jump.
            const pendingBody = [...this.container.querySelectorAll('.bt-collapsable-loading')]
                .some(el => !(el.closest('.bt-tool-msg')?.dataset.showMime || '')
                    .startsWith('video/'));
            const pendingImg  = [...this.container.querySelectorAll('img')]
                .some(img => !img.complete);
            const settled = this._settleStable >= 10 &&
                            elapsed > 400 && !this.initialLoad &&
                            !pendingBody && !pendingImg;
            if (settled || elapsed > 5000) this._settle();
            else requestAnimationFrame(watch);
        };
        requestAnimationFrame(watch);
    }

    _settle() {
        if (this._settleDone) return;
        this._settleDone  = true;
        this._settleWatch = false;
        // Land exactly at the bottom of the SETTLED layout before the
        // overlay reveals it — but ONLY if follow mode is still on.
        // followMode starts true on construction, so it's false here only
        // because the user actively scrolled away while the watch was
        // running (slow image chats can ride out the 5s hard cap with the
        // pane fully interactive). Forcing it back on would yank them to
        // the bottom mid-read.
        if (this.followMode) this.scrollToBottom();
        if (this._paneEl) {
            delete this._paneEl.dataset.btSettling;
            this._paneEl.dataset.btSettled = '1';
        }
        this._announceSettle('bt-chat-settled');
    }

    _announceSettle(name) {
        const pid = this._paneEl?.dataset.panePid || '';
        window.dispatchEvent(new CustomEvent(name, { detail: pid }));
    }

    // ── Background history prefetch ──────────────────────────────────────
    // Trickle-load the ENTIRE history into the node cache after mount, so
    // scrolling/seeking never lands on blank spacer. Bottom-up (the
    // direction users scroll into), 64 messages per request, each chunk
    // paced on the previous response — user-driven fetches and streaming
    // always win the wire. Cached-only during scrollbar drags by design
    // (onRange skips DOM work mid-drag), so blanks fill in on release.
    _startPrefetch() {
        if (this._prefetchStarted) return;
        this._prefetchStarted = true;
        this._prefetchTimer = setTimeout(() => this._prefetchTick(), 600);
    }

    _prefetchTick() {
        if (this.destroyed) return;
        if (this._prefetchPaused) return;   // hidden pane — onShown resumes
        // Highest missing index at or below the cursor.
        let e = -1;
        for (let i = Math.min(this._prefetchCursor ?? Infinity, this.totalCount - 1); i >= 0; i--) {
            if (!this.cache.has(i)) { e = i; break; }
        }
        if (e < 0) return;                       // fully cached — done
        let s = e;
        while (s > 0 && !this.cache.has(s - 1) && (e - s) < 63) s--;
        this._prefetchCursor = s - 1;
        // Marks the in-flight chunk so onRange can treat its arrival as
        // SILENT (cache-only): prefetch must not re-window/scroll per chunk
        // — that's a visible flicker storm right after mount.
        this._prefetchPending = [s, e];
        this.comm.notify({type: 'msgs.request', range: [s, e], epoch: this._epoch});
        // onRange reschedules the next tick when the response lands; this
        // timer is only the safety net for a lost/empty response.
        clearTimeout(this._prefetchTimer);
        this._prefetchTimer = setTimeout(() => this._prefetchTick(), 2000);
    }

    visibleRange() {
        if (this.totalCount === 0) return [0, -1];
        const { scrollTop, clientHeight } = this.container;
        const over = this.OVERSCAN * this.EST_HEIGHT;
        const s = this.indexAt(Math.max(0, scrollTop - over));
        const e = this.indexAt(scrollTop + clientHeight + over);
        return [s, Math.min(this.totalCount - 1, e)];
    }

    // Effective height: 0 for filtered-out keys (display:none flex items
    // produce no gap either), else the measured height (or the estimate)
    // PLUS the flex row gap that follows each rendered item. The ONLY way
    // spacer/offset math may read heights — keeping it gap-aware makes a
    // measured node's virtual contribution match its real pixels exactly.
    // `observe`'s h>0 guard keeps the last measured height through a
    // hide/show cycle, so re-showing restores exact sizes.
    effHeight(i) {
        // Lens-hidden indices contribute 0 height (their nodes are
        // display:none), so the spacer/scroll geometry matches the visible
        // subset exactly.
        if (this.lensActive && !this.lensVisible.has(i)) return 0;
        if (this.hiddenTypes.has(this.keyByIdx.get(i))) return 0;
        return (this.heights.get(i) ?? this.EST_HEIGHT) + this.ITEM_GAP;
    }

    // Is index `i` hidden by the active lens?
    lensHides(i) { return this.lensActive && !this.lensVisible.has(i); }

    // THE one owner of a cached node's `display`. Three mechanisms hide
    // nodes — parking (live-app keep-alive), the type filter (hiddenTypes)
    // and the lens — and they used to write style.display independently:
    // clearing a lens could un-hide a PARKED live app far outside the
    // viewport (updateDOM never re-hides an already-parked idx), and could
    // reveal filter-hidden nodes whose effHeight stays 0, desyncing the
    // virtual geometry from the real pixels. Every writer routes here so
    // the decision is always the conjunction of all three.
    applyVisibility(idx, node = this.cache.get(idx)) {
        if (!node) return;
        const hidden = this.parked.has(idx) ||
            this.lensHides(idx) ||
            this.hiddenTypes.has(this.keyByIdx.get(idx));
        node.style.display = hidden ? 'none' : '';
    }

    // Linear scan — profiled at 0.23ms for N=6000, far under a frame, so the
    // O(N) here is not a scroll-smoothness factor (an O(log n) prefix sum was
    // tried and dropped: it optimized something already imperceptible).
    indexAt(offset) {
        let h = 0;
        for (let i = 0; i < this.totalCount; i++) {
            h += this.effHeight(i);
            if (h > offset) return i;
        }
        return Math.max(0, this.totalCount - 1);
    }

    cumHeight(from, to) {
        let h = 0;
        for (let i = from; i < to; i++) h += this.effHeight(i);
        return h;
    }

    refresh() {
        if (this.totalCount === 0) return;
        // Bottom anchoring: updateDOM resizes the spacers, which moves
        // scrollHeight under a scrollTop pinned at the bottom — without
        // compensation the bottom edge "bounces" away from the user
        // (scrollHeight changes fire no scroll event, and overflow-anchor
        // is off on the spacers). If we were at the bottom before the
        // re-window and the geometry shifted, re-pin. Within-AT_BOTTOM_PX
        // already means "at the bottom" everywhere else (followMode), so
        // pinning here matches the existing semantics.
        const wasAtBottom = this.atBottom();
        const preHeight   = this.container.scrollHeight;
        const [s, e] = this.visibleRange();

        // While the scrollbar is held, do NOT fetch: every arriving range
        // inserts + measures new nodes mid-drag and the resulting geometry
        // churn makes the thumb flicker. A drag navigates CACHED content
        // only (uncached regions show as spacer); the release handler's
        // refresh fetches whatever the thumb landed on.
        if (!this._scrollbarDrag) {
            // Dedup in-flight requests: refresh() runs on EVERY scroll event,
            // so without this each tick re-sent the same range until the
            // response landed — dozens of identical server renders (each
            // broadcast to every tab) while scrolling through an uncached
            // region. The 2s expiry is the lost-response retry.
            const now = performance.now();
            const missing = [];
            for (let i = s; i <= e; i++) {
                if (this.cache.has(i)) continue;
                const t = this._requestedAt.get(i);
                if (t !== undefined && (now - t) < 2000) continue;
                missing.push(i);
            }
            if (missing.length > 0) {
                for (const i of missing) this._requestedAt.set(i, now);
                this.comm.notify({type: 'msgs.request',
                                  range: [missing[0], missing[missing.length - 1]],
                                  epoch: this._epoch});
            }
        }
        this.updateDOM(s, e);
        // Re-pin the bottom only for CONTENT-driven geometry changes (height
        // corrections, streaming growth). Never while the user is driving
        // scrollTop: a held scrollbar owns the position outright, and a slow
        // upward wheel/trackpad gesture starting inside AT_BOTTOM_PX used to
        // coincide with a respacing here and get yanked straight back down
        // ("wheel did nothing" at the bottom edge).
        const userDriving = this._scrollbarDrag || this._pendingUserScroll ||
            (performance.now() - this._lastUserInputT) < 400;
        if (wasAtBottom && !userDriving &&
            this.container.scrollHeight !== preHeight) {
            this.container.scrollTop = this.container.scrollHeight;
            // Programmatic write, possibly event-less (offscreen): keep the
            // direction baseline fresh so the next user scroll classifies
            // against the real position (see _prevScrollTop).
            this._prevScrollTop = this.container.scrollTop;
        }
    }

    onRange({ start, msgs, epoch }) {
        // A reply computed BEFORE a msgs.reload carries the old epoch — its
        // indices belong to the pre-splice world; caching them would put the
        // wrong messages at the wrong positions. Drop it (the dedup expiry
        // re-requests anything still missing). Servers that don't echo the
        // epoch (older builds) send undefined → accepted, old behavior.
        if (epoch !== undefined && epoch !== null && epoch !== this._epoch) return;
        const messages = msgs ?? [];          // tolerate the legacy `messages` field
        const fresh = [];
        messages.forEach((data, i) => {
            const idx = start + i;
            this._requestedAt.delete(idx);   // no longer in flight
            if (this.cache.has(idx)) return;
            const node = this.createNode(data);
            this.cache.set(idx, node);
            this.keyByIdx.set(idx, filterKey(data));
            if (data.id) this.nodeById.set(data.id, node);
            // Do NOT observe at creation — a node is observed only while it's
            // in the render window (updateDOM), so the live ResizeObserver set
            // stays bounded to ~the viewport instead of accumulating one per
            // message for the whole session (which grows per-layout cost
            // without bound). Off-screen heights come from `_measureNodes`.
            fresh.push([idx, node]);
        });
        this._measureNodes(fresh);
        // Any arriving range advances the background prefetch (pacing: one
        // chunk in flight at a time, ~30ms apart). Runs through drags too —
        // caching is the drag-safe part.
        if (this._prefetchStarted && !this._prefetchPaused) {
            clearTimeout(this._prefetchTimer);
            this._prefetchTimer = setTimeout(() => this._prefetchTick(), 30);
        }
        // Prefetch chunks are SILENT: cache-only, no scroll, and a DOM
        // re-window only when the chunk actually overlaps the visible
        // window. Per-chunk updateDOM + scroll-to-bottom was a visible
        // flicker storm (scrollbar resizing, content shifting) right after
        // mount while ~15 chunks streamed in.
        const pf = this._prefetchPending;
        if (pf && start === pf[0]) {
            this._prefetchPending = null;
            const [vs, ve] = this.visibleRange();
            const end = start + messages.length - 1;
            if (end >= vs && start <= ve && !this._scrollbarDrag) {
                this.updateDOM(vs, ve);
            }
            return;
        }
        // Ranges still in flight when a scrollbar drag started: cache the
        // nodes (above) but don't touch the DOM/geometry until release —
        // mid-drag insertion is the thumb flicker.
        if (this._scrollbarDrag) return;
        this.updateDOM(...this.visibleRange());
        if (this.initialLoad) {
            // Initial mount: scroll to bottom and lock follow mode on.
            // Multiple scroll attempts cover the period during which
            // child Monaco editors / images are still laying out and
            // pushing scrollHeight around.
            this.initialLoad = true; // cleared below after the last scroll
            this.setFollowMode(true);
            this.scrollToBottom();
            requestAnimationFrame(() => {
                if (!this.destroyed && this.followMode) this.scrollToBottom();
            });
            setTimeout(() => {
                if (!this.destroyed && this.followMode) this.scrollToBottom();
            }, 100);
            setTimeout(() => {
                if (!this.destroyed && this.followMode) this.scrollToBottom();
                this.initialLoad = false;
            }, 300);
        } else if (this.followMode) {
            this._queueScrollToBottom();
        }
    }

    // Measure freshly-created (detached) nodes in the hidden off-screen
    // host: one batch insert, one layout pass, real heights for everything
    // the prefetcher caches. Estimates then only ever exist for the few
    // frames before a chunk arrives — scrollbar geometry stays truthful,
    // which is what keeps direct thumb drags smooth (no drift to correct,
    // no freeze needed). Nodes already in the live DOM are skipped.
    _measureNodes(pairs) {
        if (!this.measureEl || pairs.length === 0) return;
        const cs = getComputedStyle(this.container);
        const w = this.container.clientWidth -
            (parseFloat(cs.paddingLeft) || 0) - (parseFloat(cs.paddingRight) || 0);
        if (w <= 0) return;   // hidden pane — measuring would record garbage
        this.measureEl.style.width = w + 'px';
        const toMeasure = pairs.filter(([idx, node]) =>
            !node.isConnected && !this.heights.has(idx));
        for (const [, node] of toMeasure) this.measureEl.appendChild(node);
        for (const [idx, node] of toMeasure) {
            const h = node.offsetHeight;
            if (h > 0) {
                this.heights.set(idx, h);
                this._measSum += h;
                this._measCount++;
            }
        }
        for (const [, node] of toMeasure) {
            if (node.parentNode === this.measureEl) this.measureEl.removeChild(node);
        }
        // Adapt the estimate to this chat's real average so the pre-measure
        // spacer geometry (and the pixel overscan derived from EST_HEIGHT)
        // tracks tall-message chats instead of the fixed 80px guess.
        if (this._measCount >= 20) {
            this.EST_HEIGHT = Math.min(400, Math.max(24,
                this._measSum / this._measCount));
        }
    }

    // Register `node` (at store index `idx`) with the shared ResizeObserver
    // (constructed once in the constructor — see there for the border-box
    // rationale). The reverse mapping rides on the node itself.
    observe(idx, node) {
        node.__btIdx = idx;
        this.observed.add(idx);
        this._ro.observe(node);
    }

    // rAF-batched refresh: many ResizeObserver measurements land in the
    // same frame (initial range render, streaming reflows) — coalesce them
    // into one re-window + respace.
    _queueRefresh() {
        if (this._refreshQueued || this.destroyed) return;
        this._refreshQueued = true;
        requestAnimationFrame(() => {
            this._refreshQueued = false;
            if (!this.destroyed) this.refresh();
        });
    }

    // The topmost rendered, visible node at/under the current scrollTop and
    // its offset from the viewport top. This is THE scroll anchor: geometry
    // changes ABOVE the viewport (height corrections, prefetch measurements,
    // EST_HEIGHT adaptation re-spacing the top spacer) must not move what the
    // user is looking at — without it, every prefetch/retry tick snapped the
    // view back while scrolling through unmeasured history ("scrolling is
    // stuck: it resets to an earlier position every second").
    // The top-visible rendered node + its offset from scrollTop. `excludeKey`
    // skips rows of a filter type that's about to be hidden — they won't survive
    // the toggle, so anchoring on one would lose the read position (setKeyHidden).
    _captureAnchor(excludeKey = null) {
        const st = this.container.scrollTop;
        for (const i of [...this.rendered].sort((a, b) => a - b)) {
            const n = this.cache.get(i);
            if (!n || !n.isConnected || n.style.display === 'none') continue;
            if (excludeKey && n.dataset.filterKey === excludeKey) continue;
            if (n.offsetTop + n.offsetHeight > st) {
                return { idx: i, off: n.offsetTop - st };
            }
        }
        return null;
    }

    // Re-pin the anchor after DOM/spacer mutations. No-op when nothing above
    // the viewport changed (|delta| ≤ 1px), so plain scroll ticks never write.
    _restoreAnchor(a) {
        if (!a) return;
        const n = this.rendered.has(a.idx) ? this.cache.get(a.idx) : null;
        let want;
        if (n && n.isConnected) {
            want = n.offsetTop - a.off;
        } else {
            // The re-window EVICTED the anchor: a large estimate shift (e.g. a
            // background prefetch re-measuring unrendered rows ABOVE the viewport
            // taller) remaps scrollTop to different indices and the anchor falls
            // outside the newly computed range. Restore to its VIRTUAL position
            // and queue a refresh so the window re-materialises around it.
            //
            // cumHeight() lives in a padding-less coordinate; a rendered node's
            // real offsetTop is cumHeight(0, idx) + PAD_TOP + one ITEM_GAP (see
            // the constructor). Omitting that constant left `want` ~a row short,
            // so the queued refresh's _captureAnchor picked the NEIGHBOURING row
            // and the view jumped ~1 row — a stuck drift on above-viewport churn.
            want = this.cumHeight(0, a.idx) + this.PAD_TOP + this.ITEM_GAP - a.off;
            this._queueRefresh();
        }
        if (Math.abs(this.container.scrollTop - want) > 1) {
            this.container.scrollTop = want;
            // Programmatic, possibly event-less write: keep the direction
            // baseline fresh (see _prevScrollTop).
            this._prevScrollTop = this.container.scrollTop;
        }
    }

    updateDOM(s, e) {
        if (s > e) return;
        // Anchor BEFORE any mutation; restored after the spacer writes below.
        // Skipped during the initial mount cascade (scrollToBottom owns it).
        const anchor = this.initialLoad ? null : this._captureAnchor();
        for (const idx of [...this.rendered]) {
            if (idx < s || idx > e) {
                const node = this.cache.get(idx);
                // Live app embeds: PARK in place (display:none) to keep the
                // sub-session + WebGL context alive, rather than removing
                // (which closes the session and disposes the canvas → it comes
                // back dead). The node stays in `rendered`, so insertSorted's
                // ordering and the spacer math are unchanged (a display:none
                // node is 0px). Spilled nodes (Stage 2) are plain again.
                if (node && node.dataset && node.dataset.btApp && !node.dataset.btSpilled) {
                    if (!this.parked.has(idx)) {
                        this.parked.add(idx);
                        this.applyVisibility(idx, node);
                        this.touchApp(idx);   // just left the viewport
                    }
                } else {
                    // Leaving the window: unobserve so the live observer set
                    // stays bounded to the rendered window. A detached node
                    // doesn't resize anyway; on re-entry the insert branch
                    // re-observes it.
                    if (this.observed.delete(idx) && node) this._ro.unobserve(node);
                    node?.remove();
                    this.rendered.delete(idx);
                    this.parked.delete(idx);
                }
            }
        }
        for (let i = s; i <= e; i++) {
            if (this.parked.has(i)) {
                // Re-entering the viewport: un-park the kept-alive app
                // (visibility still honors lens/filter state).
                const node = this.cache.get(i);
                this.parked.delete(i);
                this.applyVisibility(i, node);
                this.touchApp(i);
            } else if (this.cache.has(i) && !this.rendered.has(i)) {
                const node = this.cache.get(i);
                this.insertSorted(i, node);
                this.rendered.add(i);
                // Entering the window: (re-)observe for live height
                // corrections. Bounded to the window (see the remove branch).
                if (!this.observed.has(i)) this.observe(i, node);
                // A lens-/filter-hidden index scrolled into the window stays
                // hidden (one display owner — see applyVisibility).
                this.applyVisibility(i, node);
                if (node?.dataset?.btApp) this.touchApp(i);
            }
        }
        this.enforceAppLru();
        // Skip no-op spacer writes: this runs on every scroll event, and an
        // unconditional style write per tick invalidates style/layout even
        // when the window didn't move.
        const topH = this.cumHeight(0, s);
        const botH = this.cumHeight(e + 1, this.totalCount);
        if (topH !== this._spacerTopH) {
            this.spacerTop.style.height = topH + 'px';
            this._spacerTopH = topH;
        }
        if (botH !== this._spacerBotH) {
            this.spacerBottom.style.height = botH + 'px';
            this._spacerBotH = botH;
        }
        this._restoreAnchor(anchor);
        // NOTE: no drag-time scrollHeight freeze here. An earlier freeze
        // (pin total at drag-start, absorb deltas in the spacers) turned
        // estimate-vs-real drift into PHANTOM BLANK at the end of the
        // scroll range — "the view hits bottom while the bar still has
        // track left". The real fix is upstream: prefetched nodes are
        // measured off-screen (`_measureNodes`), so heights are real
        // everywhere and drags see a stable scrollHeight to begin with.
    }

    // Mark an app idx as most-recently-relevant in the keep-alive LRU
    // (called when it enters the viewport or just left it).
    touchApp(idx) {
        const i = this.appLru.indexOf(idx);
        if (i !== -1) this.appLru.splice(i, 1);
        this.appLru.push(idx);
    }

    // Keep at most APP_KEEPALIVE parked (off-screen, alive) app sub-sessions,
    // evicting the least-recently-visible parked ones. Visible apps are never
    // evicted. The evicted node is SPILLED: its last frame is snapshotted to a
    // static <img> + Reload button (which tears down the live sub-session and
    // frees the WebGL context). The browser hard-caps live contexts (~16) and
    // destroys the oldest beyond that, so this keeps us deterministically below
    // the ceiling — our snapshot fires first, instead of the browser blanking a
    // canvas out from under us.
    enforceAppLru() {
        if (this.parked.size <= this.APP_KEEPALIVE) return;
        for (const idx of [...this.appLru]) {
            if (this.parked.size <= this.APP_KEEPALIVE) break;
            if (!this.parked.has(idx)) continue;   // only parked nodes are evictable
            this.spillApp(idx, this.cache.get(idx));
        }
    }

    // Freeze a parked app to a snapshot + Reload button and tear down its live
    // embed. The node stays in `cache` showing the snapshot; on scroll-back it
    // behaves like any normal node (no WebGL context), and Reload re-mounts a
    // fresh sub-session via the standard tool.render path.
    spillApp(idx, node) {
        if (!node) { this.parked.delete(idx); return; }
        const slot = node.querySelector('.bt-slot') || node.querySelector('.bt-tool-body');
        const canvas = node.querySelector('canvas');
        let dataUrl = null;
        // preserveDrawingBuffer is on, so toDataURL returns the last rendered
        // frame even though the node is parked (display:none).
        if (canvas) { try { dataUrl = canvas.toDataURL('image/png'); } catch (_) {} }
        if (slot) {
            // Emptying the slot removes the sub-session root → Bonito closes the
            // sub-session and WGLMakie disposes the WebGL context.
            slot.innerHTML = '';
            const wrap = document.createElement('div');
            wrap.className = 'bt-app-snapshot';
            wrap.style.cssText = 'position:relative;display:inline-block;max-width:100%';
            if (dataUrl) {
                const img = document.createElement('img');
                img.src = dataUrl;
                img.alt = 'app snapshot';
                img.style.cssText = 'max-width:100%;display:block;border-radius:6px;filter:saturate(.85) brightness(.97)';
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
        node.remove();             // off-screen → leaves the DOM like any normal node
        this.rendered.delete(idx);
        this.parked.delete(idx);
        // A spilled node is a plain <img> — visible again unless the lens /
        // filter hides it (applyVisibility owns the decision).
        this.applyVisibility(idx, node);
        const li = this.appLru.indexOf(idx);
        if (li !== -1) this.appLru.splice(li, 1);
    }

    // Re-mount a spilled app: drop the snapshot, re-render the BonitoAppMsg body
    // (fresh worker sub-session) through the existing tool.render path.
    reloadApp(node) {
        delete node.dataset.btSpilled;
        const id = node.dataset.msgId;
        const body = node.querySelector('.bt-tool-body');
        if (body) body.innerHTML = '<div class="bt-collapsable-loading">loading…</div>';
        if (id) this.comm.notify({ type: 'tool.render', id });
    }

    insertSorted(idx, node) {
        const sorted = [...this.rendered].filter(i => i > idx).sort((a,b) => a-b);
        const before = sorted.length ? this.cache.get(sorted[0]) : this.spacerBottom;
        this.container.insertBefore(node, before);
        // Deferred auto-expand (bt_show / native images): the node is now in
        // the document, so the tool.render reply has a live slot to mount
        // into. One-shot — clear the flag before expanding. NOT during a
        // scrollbar drag: bodies mounting mid-drag inflate scrollHeight and
        // the thumb's mapping stretches out from under the pointer ("bar
        // gets stuck before the bottom") — the release sweep handles them.
        if (node.dataset && node.dataset.btAutoExpand && !this._scrollbarDrag) {
            delete node.dataset.btAutoExpand;
            node.collapsable?.setExpanded(true);
        }
        // Deferred eager-mount for edit tools (Monaco body without flipping
        // the Collapsable to expanded). Same scrollbar-drag guard as above.
        if (node.dataset && node.dataset.btAutoMount && !this._scrollbarDrag) {
            delete node.dataset.btAutoMount;
            if (node.collapsable && !node.collapsable.loaded) {
                node.collapsable.loaded = true;
                this.comm.notify({type: 'tool.render', id: node.dataset.msgId});
            }
        }
    }

    // ── New messages + streaming ──────────────────────────────────────────

    appendNewMessage(msg) {
        // `n` already pushed totalCount above; the new message lives at idx n-1.
        const idx = this.totalCount - 1;
        if (!this.cache.has(idx)) {
            const node = this.createNode(msg);
            this.cache.set(idx, node);
            this.keyByIdx.set(idx, filterKey(msg));
            if (msg.id) this.nodeById.set(msg.id, node);
            this.observe(idx, node);
            // A lens result is a STATIC index set computed when the query
            // ran — new indices can't be in it, which used to hide every
            // message arriving while a lens was active (matches included).
            // Default new messages to visible; re-running the query
            // re-evaluates them properly.
            if (this.lensActive) this.lensVisible.add(idx);
        }
        // Strict no-yank semantics: any new message (including the
        // user's own) auto-scrolls ONLY while followMode is on.
        // When the user is reading scrollback we just register unread
        // and surface the pill — sending their own message doesn't
        // re-engage follow either; they have to click the pill or
        // scroll to the bottom to come back. This matches the spec
        // "always stay at the position the user scrolls to".
        if (this.followMode) {
            // Scroll synchronously — `scrollToBottom` does the scroll +
            // calls `refresh()` (which re-computes `visibleRange()` from
            // the new scrollTop and calls `updateDOM`), so the new bubble
            // lands in the DOM in one synchronous call. We deliberately
            // do NOT route through `_queueScrollToBottom` here: rAF is
            // paused in backgrounded tabs/windows, which means new
            // messages would land in `cache` but never make it into the
            // DOM until the user re-focuses the tab. That manifests as
            // "I sent a message and 5 old messages appeared instantly" —
            // they were already cached, the auto-scroll just couldn't
            // fire while the tab was in the background. Synchronous
            // scrollTop writes and DOM updates work regardless of tab
            // visibility, so we land the bubble immediately. rAF batching
            // is still used for `appendChunk` (50 chunks/s, batching is
            // a real perf win; the streaming bubble itself is already in
            // the DOM, only the scroll lags).
            this.scrollToBottom();
        } else {
            this._registerUnread();
        }
    }

    appendChunk(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        // A finalized node has already been painted with the authoritative html
        // by `onAgentFinal` (which cleared the pending stream). Nodes are never
        // removed from `nodeById`/`cache` (virtual scroll only detaches them
        // from the DOM), so a finalized node lives forever — and message ids
        // are unique per message, so a finalized id never legitimately gets
        // more chunks. A LATE or duplicate `chunk` for it would repaint the
        // older, shorter cumulative html; drop it. A NEW message uses a fresh
        // node (fresh id), so this per-node flag never blocks live streaming.
        if (node.__btFinal) return;
        // Server ships the FULL rendered html of the message-so-far each
        // chunk (CommonMark-rendered, so intraword `_`s don't italicize and
        // newlines/lists/headings format correctly while streaming). Each
        // payload is self-contained, so intermediate frames are droppable —
        // apply through the throttle below instead of re-parsing and
        // re-laying-out the whole (growing) bubble at chunk rate.
        if (msg.html !== undefined) {
            this._applyStreamHtml(node, msg.html);
        } else if (msg.text !== undefined) {
            // Legacy text-delta path (kept for the streaming-stress mocks
            // that still feed plain text). Append to the streaming span.
            const t = node.querySelector('.bt-stream-text');
            if (t) t.textContent += msg.text;
        }
        // _queueScrollToBottom rAF-batches multiple chunks per frame so
        // we only scroll AFTER the layout pass that includes the new
        // text (avoids the stale-scrollHeight race).
        if (this.followMode) {
            this._queueScrollToBottom();
        } else {
            // Streaming bubble is being extended while user is reading
            // scrollback. _registerUnread is idempotent for repeated
            // chunks of the same bubble — the pill stays visible once
            // shown.
            this._registerUnread();
        }
    }

    appendUserChunk(text) {
        // Streaming user message: append to the most recent user bubble.
        const idx = this.totalCount - 1;
        const node = this.cache.get(idx);
        if (node && node.classList.contains('bt-user-msg')) {
            node.textContent += text;
            if (this.followMode) {
                this._queueScrollToBottom();
            } else {
                this._registerUnread();
            }
        }
    }

    // Leading+trailing throttle for streaming innerHTML. The first chunk
    // paints immediately; chunks inside the STREAM_APPLY_MS window are
    // coalesced (last one wins — payloads are cumulative) and flushed by the
    // trailing timer, so the final chunk always lands even if the stream
    // stops mid-window. Per-chunk replacement re-parsed + re-laid-out the
    // entire message at chunk rate — a real stutter source on long replies.
    _applyStreamHtml(node, html) {
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
    _clearPendingStream(node) {
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
            // throttled trailing flush queued by `_applyStreamHtml` would
            // otherwise fire AFTER this and resurrect stale streamed text into
            // an already-final bubble. For an empty final we also blank the
            // node so the bubble reflects the authoritative (empty) message.
            this._clearPendingStream(node);
            node.innerHTML = msg.html || '';
            linkifyPaths(node);
            decorateCodeBlocks(node);
            // Mark the node final so a LATE/duplicate `chunk` for this id can't
            // repaint the older, shorter cumulative html (see `appendChunk`).
            node.__btFinal = true;
            return;
        }
        // Node evicted / id mismatch: mirror `onSummaryFinal`'s DOM fallback so
        // the authoritative final isn't silently dropped. Prefer a precise
        // by-id lookup (agent nodes carry `data-msg-id`); fall back to the last
        // agent bubble in the DOM.
        let tgt = msg.id
            ? this.container.querySelector(
                `.bt-agent-msg[data-msg-id="${CSS.escape(msg.id)}"]`)
            : null;
        if (!tgt) {
            const nodes = this.container.querySelectorAll('.bt-agent-msg');
            tgt = nodes[nodes.length - 1];
        }
        if (tgt) {
            this._clearPendingStream(tgt);
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
        if (active && this.followMode) this._queueScrollToBottom();
    }

    // ── Permission / question cards ──────────────────────────────────────
    // A `session/request_permission` (AskUserQuestion, plan approval, …)
    // renders as an interactive card with one button per option. The card is
    // PLAIN scroll content (like the busy/thinking indicators — inserted
    // after the bottom spacer, never tracked by the virtual-scroll
    // geometry): it lives exactly under the last message for the lifetime
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
        // the bottom spacer).
        this.container.insertBefore(card, this.busyEl || null);
        if (this.followMode) this._queueScrollToBottom();
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
        if (this.followMode) this._queueScrollToBottom();
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
        this._cancelPendingScroll();
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
            // class. Terminal status sheds it; mid-flight gets it.
            const live = !(msg.status === 'completed' || msg.status === 'failed');
            node.classList.toggle('bt-tool-live', live);
            // The live code preview's job ends with the eval — the completed
            // body renders the same code as its Monaco "Code" section.
            if (!live) node.querySelector('.bt-eval-preview')?.remove();
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
        // bt_show: the completion update is when we learn it's a "show me
        // this" tool (and its mime). Native-media mode takes precedence:
        // chrome off + body mounted; otherwise auto-expand the pill
        // (idempotent; user can still collapse). Detached nodes defer the
        // expand to insertion (see insertSorted).
        if (msg.show_mime) node.dataset.showMime = msg.show_mime;
        if (this._wantsNative(node)) {
            this._applyNative(node);
        } else if (msg.expand && node.collapsable) {
            if (node.collapsable.editMode) {
                // Edit tools: msg.expand from the server means "the first
                // DiffContent landed — eager-mount the compact Monaco
                // preview, but DON'T flip Collapsable.expanded (we stay in
                // compact size). A click on the header is what expands
                // Monaco; this auto-mount just makes the diff visible
                // without requiring a click.
                if (node.isConnected) {
                    if (!node.collapsable.loaded) {
                        node.collapsable.loaded = true;
                        this.comm.notify({type: 'tool.render', id: msg.id});
                    }
                } else {
                    node.dataset.btAutoMount = '1';
                }
            } else if (node.isConnected) {
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
        if (msg.stoppable && headerEl && !headerEl.querySelector('.bt-tool-stop')) {
            const sb = document.createElement('button');
            sb.type = 'button';
            sb.className = 'bt-tool-stop bt-stop-mini';
            sb.title = 'Stop';
            sb.addEventListener('click', (e) => {
                e.stopPropagation();
                this.comm.notify({ type: 'stop_tool', id: msg.id });
            });
            headerEl.insertBefore(sb,
                headerEl.querySelector('.bt-tool-fullwidth') || null);
        }
        if (msg.code && stillLive && headerEl && !node.querySelector('.bt-eval-preview')) {
            const pv = document.createElement('div');
            pv.className = 'bt-eval-preview';
            const pre = document.createElement('pre');
            pre.textContent = msg.code;
            const tg = document.createElement('button');
            tg.type = 'button';
            tg.className = 'bt-eval-preview-toggle';
            tg.title = 'Enlarge';
            tg.textContent = '⌄';
            tg.addEventListener('click', (e) => {
                e.stopPropagation();
                const full = pv.classList.toggle('bt-eval-preview-full');
                tg.textContent = full ? '⌃' : '⌄';
                tg.title = full ? 'Collapse' : 'Enlarge';
            });
            pv.append(pre, tg);
            headerEl.insertAdjacentElement('afterend', pv);
        }
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
    // The server routes every parentToolUseId-tagged subagent update to its
    // parent TaskToolMsg and mirrors it here as `task_activity` events; the
    // bubble renders them as a bounded, most-recent-last, auto-scrolled feed
    // in its own collapsible section between the header and the lazy body
    // (same Collapsable behaviour the tool body / thought sections use).
    // Remounts rebuild from the header's `task_feed` snapshot (createNode).

    onTaskActivity(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node || !msg.entry) return;
        this._upsertTaskFeedEntry(this._ensureTaskFeed(node), msg.entry);
    }

    _ensureTaskFeed(node) {
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

    _upsertTaskFeedEntry(feed, e) {
        const list = feed.querySelector('.bt-task-feed-list');
        let row = e.eid != null ?
            list.querySelector(`[data-eid="${CSS.escape(String(e.eid))}"]`) : null;
        if (!row) {
            row = document.createElement('div');
            row.dataset.eid = String(e.eid ?? '');
            list.appendChild(row);
            // Bounded mirror of the server's feed window.
            while (list.children.length > 50) list.removeChild(list.firstChild);
        }
        row.className = `bt-task-feed-entry bt-task-feed-${e.kind || 'text'}` +
            (e.status ? ` bt-feed-${e.status}` : '');
        row.textContent = e.kind === 'tool' ? `⚙ ${e.label || ''}` : (e.label || '');
        if (e.kind === 'tool' && e.status) row.title = e.status;
        const count = feed.querySelector('.bt-task-feed-count');
        if (count) count.textContent = String(list.children.length);
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
        if (key === 'agent') this._updateWaiting();
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
    _wantsNative(node) {
        const mime = node.dataset.showMime || '';
        if (mime.startsWith('image/')) return this.nativeImages;
        if (mime.startsWith('video/')) return this.nativeVideos;
        return false;
    }

    _applyNative(node) {
        node.classList.add('bt-tool-native');
        if (node.isConnected) {
            node.collapsable?.setExpanded(true);
        } else {
            // Cached but not in the document (virtual-scroll window /
            // prefetch): defer the expand to insertion so the tool.render
            // reply has a slot to mount into.
            node.dataset.btAutoExpand = '1';
        }
    }

    _removeNative(node) {
        node.classList.remove('bt-tool-native');
        delete node.dataset.btAutoExpand;
        node.collapsable?.setExpanded(false);   // discardOnCollapse frees the body
    }

    // Flip one media class ('image/' or 'video/') and re-depict every cached
    // node of that class; the other class is untouched.
    _setNativeMedia(prefix, on) {
        if (prefix === 'image/') this.nativeImages = on;
        else                     this.nativeVideos = on;
        for (const node of this.cache.values()) {
            if (!(node.dataset.showMime || '').startsWith(prefix)) continue;
            on ? this._applyNative(node) : this._removeNative(node);
        }
        this.refresh();
    }

    // Toggle a key's visibility: inline display on every matching node (an
    // open key-set — per-tool keys — rules out static CSS classes), while
    // effHeight zeroes the hidden indices so the spacer/scroll math matches
    // the real (collapsed) layout exactly. Nodes created later pick up the
    // current state in createNode.
    setKeyHidden(key, hidden) {
        // Hold the read position across the toggle. Applying visibility reflows
        // the transcript (matching rows collapse to / expand from 0px), which
        // moves the viewport BEFORE refresh's own anchor runs — refresh then
        // faithfully preserves the ALREADY-jumped spot, throwing the reader to a
        // different message. So capture the top-visible SURVIVING row now (before
        // the reflow, excluding the type being toggled) and re-pin it after
        // refresh has trued up the spacers/window.
        const anchor = this.followMode ? null : this._captureAnchor(key);
        this.hiddenTypes[hidden ? 'add' : 'delete'](key);
        for (const [idx, node] of this.cache) {
            // applyVisibility, not a raw display write: un-hiding a key must
            // not reveal nodes the lens hides or un-park live apps.
            if (node.dataset.filterKey === key) this.applyVisibility(idx, node);
        }
        // Hiding the agent stream also hides the idle "waiting" line that
        // would otherwise dangle under messages that aren't there.
        if (key === 'agent') this._updateWaiting();
        this.refresh();
        if (this.followMode) this._queueScrollToBottom();
        else if (anchor) this._restoreAnchor(anchor);
    }

    // The idle "waiting for your next instruction" line only makes sense
    // under an agent reply: keep it off for empty chats (nothing was asked
    // yet) and while the Agent filter hides the messages it would sit
    // under. The CSS show-rule requires `bt-waiting-on` on top of the
    // not-busy sibling condition, so busy/idle switching stays pure CSS.
    _updateWaiting() {
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
                if (msg.queued) div.classList.add('bt-queued');
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
                        const img = document.createElement('img');
                        img.className = 'bt-user-att-img';
                        img.src = a.url;
                        img.alt = a.name || 'attachment';
                        img.loading = 'lazy';
                        img.addEventListener('click', () => openLightbox(img));
                        img.addEventListener('error', () => {
                            const miss = document.createElement('span');
                            miss.className = 'bt-user-att-missing';
                            miss.textContent = a.name || 'attachment';
                            img.replaceWith(miss);
                        }, { once: true });
                        gallery.appendChild(img);
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
                if (msg.kind === 'bonito_app') div.dataset.btApp = '1';
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
                if (liveTool) div.classList.add('bt-tool-live');
                const id = msg.id;
                // Click-header host; the body is re-rendered (Monaco etc.) on
                // every expand via tool.render → dom_in_js, and discarded on
                // collapse so the editors are freed.
                // Edit tools render their compact Monaco diff under the
                // header eagerly (no click required). The Collapsable's
                // editMode keeps the body mounted across collapse — toggle
                // just calls Monaco.setMaxHeight to swap compact↔full.
                const isEdit = msg.kind === 'edit';
                div.collapsable = new Collapsable(
                    div.querySelector('.bt-tool-header'),
                    div.querySelector('.bt-tool-body'),
                    { toggleEl: div.querySelector('.bt-tool-toggle'),
                      editMode: isEdit,
                      fetchEachExpand: !isEdit, discardOnCollapse: !isEdit,
                      onExpand: () => this.comm.notify({type: 'tool.render', id}) });
                // Subagent Task: rebuild the live activity feed from the
                // header's snapshot (live growth rides task_activity events).
                if (Array.isArray(msg.task_feed) && msg.task_feed.length) {
                    const feed = this._ensureTaskFeed(div);
                    for (const e of msg.task_feed) this._upsertTaskFeedEntry(feed, e);
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
                // Full-chat-width toggle, vertically centered on the bubble's
                // right edge (CSS reveals it only while the body is expanded —
                // there's no point widening an empty header). Extends the pill to
                // span the whole message column so wide content (diffs / tables /
                // remote-app embeds) gets room. Must NOT toggle expand/collapse,
                // so stopPropagation.
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
                // Live code preview enlarge/collapse — same small-preview →
                // grow interaction as the diff view, no re-fetch.
                const pvToggle = div.querySelector('.bt-eval-preview-toggle');
                if (pvToggle) pvToggle.addEventListener('click', (e) => {
                    e.stopPropagation();
                    const pv = div.querySelector('.bt-eval-preview');
                    if (!pv) return;
                    const full = pv.classList.toggle('bt-eval-preview-full');
                    pvToggle.textContent = full ? '⌃' : '⌄';
                    pvToggle.title = full ? 'Collapse' : 'Enlarge';
                });
                // The show's mime (bt_show results) — the native-media
                // toggles key on it.
                if (msg.show_mime) div.dataset.showMime = msg.show_mime;
                if (this._wantsNative(div)) {
                    // Native display: chrome off + body auto-mounted on
                    // first insertion.
                    div.classList.add('bt-tool-native');
                    div.dataset.btAutoExpand = '1';
                } else if (msg.expand) {
                    // Auto-expand (e.g. bt_show) — DEFERRED until the node
                    // first enters the document (insertSorted). The history
                    // prefetcher creates nodes detached; expanding those
                    // immediately fired tool.render whose dom_in_js reply
                    // found no slot in the document — the body stayed on
                    // "loading…" forever (and every off-screen bt_show in
                    // history cost a render round-trip up front).
                    div.dataset.btAutoExpand = '1';
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
        // in the DOM.
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
        const stopBtn = msg.stoppable ?
            `<button class="bt-tool-stop bt-stop-mini" type="button"
                     title="Stop"></button>` : '';
        // File-path link: when the tool identifies a file (the server ships
        // `edit_path`), its TITLE becomes a clickable link that opens the
        // file in the plotpane editor — same affordance as every other path
        // link in the chat (diff headers, search hits, paths in messages).
        // One delegated container listener handles all of them.
        const titleLink = msg.edit_path
            ? ` bt-path-link" data-path="${escapeAttr(msg.edit_path)}` : '';
        const live = !(msg.status === 'completed' || msg.status === 'failed') &&
                     msg.finished_at == null;
        const evalPreview = (msg.code && live) ? `
            <div class="bt-eval-preview">
                <pre>${escapeHTML(msg.code)}</pre>
                <button class="bt-eval-preview-toggle" type="button"
                        title="Enlarge">⌄</button>
            </div>` : '';
        // "What ran", ALWAYS visible (persists past completion — there's no Monaco
        // "Code" section afterwards) and never hidden in a tooltip: the bash command,
        // OR a control MCP tool's action (interrupt/restart/list its target session).
        // A tool ships either `code` (eval preview above) or `command` (this).
        const cmdPreview = msg.command ? `
            <div class="bt-cmd-preview"><pre>${escapeHTML(msg.command)}</pre></div>` : '';
        // Elapsed timer — empty until the pill finishes, then filled ONCE
        // with the final duration by `_writeToolElapsed` (on creation of an
        // already-finished pill, and on the completion update). Live elapsed
        // time is the taskbar's job (Julia clock); no JS timer touches this.
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
                <span class="bt-tool-summary">${escapeHTML(msg.summary || '')}</span>
                ${timeoutBadge}
                <span class="bt-tool-timer"></span>
                <span class="${statusCls}">${escapeHTML(msg.status || '')}</span>
                ${stopBtn}
                ${msg.kind === 'bonito_app'
                    ? `<button class="bt-tool-detach" type="button"
                              title="Detach to floating window">⤢</button>`
                    : ''}
                <button class="bt-tool-fullwidth" type="button"
                        title="Expand to full chat width">»</button>
            </div>
            ${evalPreview}${cmdPreview}
            <div class="bt-tool-body" data-tool-id="${escapeAttr(msg.id || '')}"></div>`;
    }

    // ── Live tools / todos: pulse + timer + taskbar ──────────────────────
    // A single 1s interval drives all live-state UX:
    //   1) Update the inline `.bt-tool-timer` on each live pill (> 1s only).
    //   2) Rebuild the floating taskbar from current live DOM (one slot per
    //      live pill; click → scrollIntoView on the source).
    // No per-pill timers, no server-pushed taskbar state — DOM is the source
    // of truth. Cheap: scans at most a few dozen nodes once a second.
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

    _setupLiveTicker() {
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
            const storedTodo = localStorage.getItem('bt-todo-collapsed');
            const paneW = this.container.closest('.bt-chatpane')?.clientWidth
                       ?? window.innerWidth;
            this.taskbarEl.classList.toggle('bt-todo-collapsed',
                storedTodo != null ? storedTodo === '1' : paneW < 660);
            this._onTaskbarClick = (ev) => {
                if (ev.target.closest('.bt-taskbar-todo-toggle')) {
                    const c = this.taskbarEl.classList.toggle('bt-todo-collapsed');
                    localStorage.setItem('bt-todo-collapsed', c ? '1' : '0');
                    return;
                }
                if (ev.target.closest('.bt-taskbar-slot-stop')) return;
                const slot = ev.target.closest('.bt-taskbar-slot');
                if (!slot) return;
                const idx = parseInt(slot.dataset.msgIndex ?? '-1', 10);
                if (!Number.isInteger(idx) || idx < 0 || idx >= this.totalCount) return;
                // Jump via the scroller's own geometry — works whether or
                // not the pill is currently rendered (scrollIntoView on a
                // recycled node silently does nothing). Two passes: the
                // first render swaps estimated heights for real ones, the
                // second corrects the target with the settled geometry.
                const jump = () => {
                    this.container.scrollTop =
                        Math.max(0, this.cumHeight(0, idx) - 60);
                };
                this.followMode = false;
                jump();
                requestAnimationFrame(() => requestAnimationFrame(jump));
            };
            this.taskbarEl.addEventListener('click', this._onTaskbarClick);
        }
        // NO ticker here. Live elapsed time is shown in the TASKBAR, driven
        // by a Julia clock (taskbar.jl / ensure_taskbar_clock!). In-chat tool
        // pills show their FINAL duration, written ONCE on completion
        // (`_writeToolElapsed`) — event-driven, never polled, so the scroll
        // container is never queried on a timer.
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
    _setupLens() {
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

        const apply = () => { this._lensCommitTail(); this._hideLensAutocomplete();
                              this.runLens(this._lensSerialize()); };
        go.addEventListener('click', apply);
        save.addEventListener('click', () => {
            this._lensCommitTail();
            const q = this._lensSerialize();
            if (q) this.comm.notify({ type: 'lens.save', q });
        });
        clear.addEventListener('click', () => this._lensClearAll());
        this.lensInput.addEventListener('input', () => {
            this._lensAutoCommitOnOperator();
            this._updateLensAutocomplete();
        });
        this.lensInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') { e.preventDefault();
                if (!this._acceptLensAutocomplete()) apply(); }
            else if (e.key === 'Escape') this._hideLensAutocomplete();
            else if (e.key === 'ArrowDown' || e.key === 'ArrowUp')
                this._moveLensAutocomplete(e.key === 'ArrowDown' ? 1 : -1, e);
            else if (e.key === 'Backspace' && this.lensInput.value === '' &&
                     this.lensClauses.length) { e.preventDefault(); this._lensPopPill(); }
        });
        // Click-away closes the autocomplete. (Document-level: lazy
        // self-destroy backstop, same as the ESC handler.)
        this._onLensDocClick = (e) => {
            if (!this.container.isConnected) { this._lazyDestroy(); return; }
            if (!host.contains(e.target)) this._hideLensAutocomplete();
        };
        document.addEventListener('click', this._onLensDocClick);
        this._renderLensPills();
        this._renderSavedLenses();
    }

    // ── Clause model: parse / serialize / split ───────────────────────────
    // Light client-side parse of one clause's text, for the pill label + to
    // know whether a structured key is present (mirrors lens.jl parse_clause).
    _lensClauseParts(text) {
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
    _lensSerialize() {
        return this.lensClauses.map((c, i) => i === 0
            ? (c.sign === '-' ? '!' + c.text.replace(/^[!-]\s*/, '') : c.text)
            : (c.sign === '-' ? '- ' + c.text.replace(/^[!-]\s*/, '') : '+ ' + c.text)
        ).join(' ').trim();
    }

    // Split a saved query back into clauses (mirrors lens.jl split_lens_clauses).
    _lensSplit(str) {
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
    _lensCommitTail() {
        const t = this.lensInput.value.trim();
        if (t) this.lensClauses.push({ sign: this.lensPendingSign, text: t });
        this.lensInput.value = '';
        this.lensPendingSign = '+';
        this._renderLensPills();
    }

    // Auto-commit when the user types a top-level ` + ` / ` - ` (quote-balanced):
    // the operator finalizes the current clause and opens the next.
    _lensAutoCommitOnOperator() {
        const v = this.lensInput.value;
        const m = v.match(/^(.*\S)\s+([+-])\s$/);
        if (!m) return;
        if (((v.match(/"/g) || []).length) % 2 !== 0) return;   // inside a quote
        this.lensClauses.push({ sign: this.lensPendingSign, text: m[1].trim() });
        this.lensPendingSign = m[2] === '-' ? '-' : '+';
        this.lensInput.value = '';
        this._renderLensPills();
    }

    _lensClearAll() {
        this.lensClauses = []; this.lensPendingSign = '+';
        this.lensInput.value = '';
        this._renderLensPills();
        this._hideLensAutocomplete();
        this.runLens('');
    }

    _lensRemovePill(i) {
        this.lensClauses.splice(i, 1);
        this._renderLensPills();
        this.runLens(this._lensSerialize());
    }

    _lensEditPill(i) {
        this._lensCommitTail();                 // don't lose the in-progress tail
        const c = this.lensClauses.splice(i, 1)[0];
        this.lensInput.value = c.text;
        this.lensPendingSign = c.sign;
        this._renderLensPills();
        this.lensInput.focus();
        const n = this.lensInput.value.length; this.lensInput.setSelectionRange(n, n);
        this._updateLensAutocomplete();
    }

    _lensPopPill() {
        const c = this.lensClauses.pop();
        if (!c) return;
        this.lensInput.value = c.text;
        this.lensPendingSign = c.sign;
        this._renderLensPills();
        const n = this.lensInput.value.length; this.lensInput.setSelectionRange(n, n);
        this._updateLensAutocomplete();
    }

    _lensLoadQuery(q) {
        this.lensClauses = this._lensSplit(q);
        this.lensPendingSign = '+';
        this.lensInput.value = '';
        this._renderLensPills();
        this.runLens(q);
    }

    _renderLensPills() {
        if (!this.lensPills) return;
        this.lensPills.innerHTML = '';
        this.lensClauses.forEach((c, i) => {
            const p = this._lensClauseParts(c.text);
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
                e.preventDefault(); e.stopPropagation(); this._lensRemovePill(i); });
            pill.addEventListener('mousedown', (e) => {
                if (e.target.classList.contains('bt-lens-pill-x')) return;
                e.preventDefault(); this._lensEditPill(i); });
            this.lensPills.appendChild(pill);
        });
        this.lensBarEl?.classList.toggle('bt-lens-pending-ex', this.lensPendingSign === '-');
    }

    // ── Autocomplete (contextual: keys, then actions + operators) ─────────
    // Suggest keys for the token currently being typed after the last `/`.
    _currentLensToken() {
        const v = this.lensInput.value;
        const caret = this.lensInput.selectionStart ?? v.length;
        const head = v.slice(0, caret);
        const slash = head.lastIndexOf('/');
        if (slash < 0) return null;
        const frag = head.slice(slash + 1);
        if (/[\s:"]/.test(frag)) return null;       // KEY only (stop at space/colon/quote)
        return { start: slash + 1, end: caret, frag };
    }

    _updateLensAutocomplete() {
        const tok = this._currentLensToken();
        if (tok) {                                   // KEY suggestions
            const f = tok.frag.toLowerCase();
            const matches = this.lensVocab.filter(k => _subseqMatch(f, k)).slice(0, 8);
            if (!matches.length) return this._hideLensAutocomplete();
            this._renderLensAC(matches.map(k => ({ kind: 'key', val: k, label: '/' + k })), true);
            return;
        }
        // Past the key (or composing free text) → ACTIONS + OPERATORS.
        if (this.lensInput.value.trim() !== '') {
            const p = this._lensClauseParts(this.lensInput.value);
            const items = [];
            if (p.key) for (const a of ['expand', 'collapse'])
                if (p.action !== a) items.push({ kind: 'action', val: a, label: a, hint: `${a} matches` });
            items.push({ kind: 'op', val: '+', label: '＋ add',     hint: 'include another clause' });
            items.push({ kind: 'op', val: '-', label: '− exclude',  hint: 'hide the next clause' });
            this._renderLensAC(items, false);        // no pre-select → Enter applies the lens
            return;
        }
        this._hideLensAutocomplete();
    }

    _renderLensAC(items, selectFirst) {
        if (!items.length) return this._hideLensAutocomplete();
        this.lensAC.innerHTML = items.map((it, i) =>
            `<div class="bt-lens-ac-item${selectFirst && i === 0 ? ' bt-ac-sel' : ''}" ` +
            `data-kind="${it.kind}" data-val="${escapeAttr(it.val)}">` +
            `<span class="bt-lens-ac-label">${escapeHTML(it.label)}</span>` +
            (it.hint ? `<span class="bt-lens-ac-hint">${escapeHTML(it.hint)}</span>` : '') +
            `</div>`).join('');
        this.lensAC.hidden = false;
        for (const el of this.lensAC.querySelectorAll('.bt-lens-ac-item')) {
            el.addEventListener('mousedown', (e) => { e.preventDefault();
                this._applyLensAC(el.dataset.kind, el.dataset.val); });
        }
    }
    _hideLensAutocomplete() { if (this.lensAC) { this.lensAC.hidden = true; this.lensAC.innerHTML = ''; } }
    _moveLensAutocomplete(dir, e) {
        if (this.lensAC.hidden) return;
        e.preventDefault();
        const items = [...this.lensAC.querySelectorAll('.bt-lens-ac-item')];
        if (!items.length) return;
        let i = items.findIndex(el => el.classList.contains('bt-ac-sel'));
        if (i >= 0) items[i].classList.remove('bt-ac-sel');
        i = (i + dir + items.length) % items.length;
        items[i].classList.add('bt-ac-sel');
    }
    _acceptLensAutocomplete() {
        if (this.lensAC.hidden) return false;
        const sel = this.lensAC.querySelector('.bt-ac-sel');
        if (!sel) return false;
        this._applyLensAC(sel.dataset.kind, sel.dataset.val);
        return true;
    }
    _applyLensAC(kind, val) {
        if (kind === 'key') return this._fillLensKey(val);
        if (kind === 'action') return this._lensAppendToken(val);
        if (kind === 'op') {                          // commit clause, open the next
            this._lensCommitTail();
            this.lensPendingSign = val === '-' ? '-' : '+';
            this._renderLensPills();
            this._hideLensAutocomplete();
            this.lensInput.focus();
        }
    }
    _lensAppendToken(tok) {
        let v = this.lensInput.value;
        if (v && !v.endsWith(' ')) v += ' ';
        this.lensInput.value = v + tok + ' ';
        this._hideLensAutocomplete();
        this.lensInput.focus();
        this._updateLensAutocomplete();
    }
    _fillLensKey(key) {
        const tok = this._currentLensToken();
        const v = this.lensInput.value;
        if (!tok) return;
        const before = v.slice(0, tok.start), after = v.slice(tok.end);
        this.lensInput.value = before + key + (after.startsWith(' ') ? '' : ' ') + after;
        const caret = (before + key + ' ').length;
        this.lensInput.setSelectionRange(caret, caret);
        this._hideLensAutocomplete();
        this.lensInput.focus();
        this._updateLensAutocomplete();
    }

    // ── Run / receive / apply ─────────────────────────────────────────────
    runLens(query) {
        this.lensQuery = query;
        this.comm.notify({ type: 'lens.query', q: query });
    }

    onLensResult(msg) {
        // Only apply results for the query THIS tab currently has pending
        // (the channel is shared across tabs — see the server handler).
        if (msg.q !== this.lensQuery) return;
        // Clearing an active lens un-hides rows (a reflow that would jump the
        // view before refresh's anchor runs) — hold the read position like
        // setKeyHidden. Activating scrolls to the first match below, so no anchor.
        const holdAnchor = (this.lensActive && !msg.active && !this.followMode)
            ? this._captureAnchor() : null;
        if (!msg.active) {
            this.lensActive = false; this.lensVisible = null; this.lensActions = null;
        } else {
            this.lensActive  = true;
            this.lensVisible = new Set(msg.visible || []);
            this.lensActions = new Map(Object.entries(msg.actions || {}).map(([k, v]) => [+k, v]));
        }
        if (this.lensClearBtn) this.lensClearBtn.hidden = !this.lensActive;
        this.lensBarEl?.classList.toggle('bt-lens-on', this.lensActive);
        // Re-apply visibility to every rendered node, then re-window (heights
        // of hidden indices are now 0) and run any actions (expand).
        // applyVisibility (not a raw display write) keeps parked live apps
        // parked and filter-hidden nodes hidden when a lens is cleared.
        for (const [idx, node] of this.cache) {
            if (this.rendered.has(idx)) this.applyVisibility(idx, node);
        }
        this.refresh();
        if (this.lensActions) {
            for (const [idx, action] of this.lensActions) {
                const node = this.cache.get(idx);
                if (!node) continue;
                if (action === 'expand')        node.collapsable?.setExpanded(true);
                else if (action === 'collapse') node.collapsable?.setExpanded(false);
            }
        }
        // Jump to the top of the filtered view so the first match is visible.
        // (scrollTop write syncs _prevScrollTop: programmatic, possibly event-less.)
        if (this.lensActive) { this.followMode = false; this.container.scrollTop = 0; this._prevScrollTop = 0; this.refresh(); }
        else if (holdAnchor) this._restoreAnchor(holdAnchor);   // clearing: hold the read position
    }

    onLensSaved(msg) {
        this.savedLenses = msg.lenses || [];
        this._renderSavedLenses();
    }

    _renderSavedLenses() {
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
                this._lensLoadQuery(l.query);    // populate pills + apply
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
    _sizeTail() {
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
    _queueScrollToBottom() {
        // A held scrollbar is ABSOLUTE authority over scrollTop: no chase,
        // no re-anchor, no reveal-scroll may fire mid-drag (container
        // resizes from toolbar growth, streaming chunks, and range
        // arrivals all funnel through here — any of them would snap the
        // thumb out of the user's hand).
        if (this._scrollbarDrag) return;
        if (this._scrollQueued || this.destroyed) return;
        this._scrollQueued = true;
        this._scrollRafId = requestAnimationFrame(() => {
            this._scrollQueued = false;
            this._scrollRafId = null;
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
            // this point means nothing disengaged or cancelled us (a
            // scroll-away lands in _applyUserScroll's disengage, which
            // cancels through _cancelPendingScroll) — the chase must still
            // land, e.g. after a downward re-engage mid-gesture. Re-arm
            // until the input window lapses instead of dropping.
            if ((performance.now() - this._lastUserInputT) < 100) {
                if (this.followMode) this._queueScrollToBottom();
                return;
            }
            this.scrollToBottom();
        });
    }

    scrollToBottom() {
        if (this._scrollbarDrag) return;   // the drag owns scrollTop
        // Belt + suspenders: set scrollTop AND scrollIntoView on the LAST
        // child (the overscroll tail — plain content, see _sizeTail).
        // scrollTop alone uses the container's reported scrollHeight which
        // can be stale during streaming; scrollIntoView tells the browser
        // "make this element's bottom edge visible" and lets it compute
        // the right position from current layout.
        this.container.scrollTop = this.container.scrollHeight;
        const anchor = this.tailEl || this.spacerBottom;
        if (anchor) {
            anchor.scrollIntoView({ block: 'end', behavior: 'auto' });
        }
        // Keep the direction baseline honest where no scroll event may fire
        // (see the offscreen note below): a chase leaving a stale, SMALLER
        // _prevScrollTop would make the next upward peek read as "moving
        // down" and wrongly re-engage.
        this._prevScrollTop = this.container.scrollTop;
        // Don't rely on the `scroll` event to drive the post-scroll range
        // fetch — Electron's offscreen renderer (and a few other headless
        // browser configs) doesn't fire scroll events for programmatic
        // scrollTop changes, which leaves the chasing-bottom loop fetching
        // nothing past the initial range. `refresh()` is idempotent and
        // cheap, so call it explicitly.
        this.refresh();
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
        if (this._cancelMomentum) this._cancelMomentum();
        this._cancelPendingScroll();
        if (this._setOverscroll) this._setOverscroll(0);
        this._savedScrollTop  = this.container.scrollTop;
        this._savedFollowMode = this.followMode;
        // CONTENT anchor besides the pixel position: heights re-measured
        // while hidden (or the backfill running meanwhile) change what a raw
        // scrollTop points at — restoring to the anchored MESSAGE is what
        // "keep my read position" actually means.
        this._savedAnchor = this._captureAnchor();
        // Hidden panes stop backfilling: every prefetch chunk is a server-side
        // render broadcast to every tab — deferred until the user returns.
        this._prefetchPaused = true;
        clearTimeout(this._prefetchTimer);
    }

    // Called by the chat-pane visibility toggle whenever this pane goes
    // display:flex (initial open, kept-alive re-open, dashboard ↔ chat).
    // Two branches:
    //
    //   • Was at the bottom (followMode true now, OR it was true when we
    //     hid the pane): re-anchor to the bottom on every retry so any
    //     bubbles that streamed in while we were hidden land in view.
    //   • Was scrolled up to read history (followMode false on both
    //     sides): restore the SAVED scrollTop on every retry so a
    //     mid-layout clamp can be undone on the next frame.
    //
    // Both branches use the same 0 / rAF / 50 ms / 200 ms cascade as the
    // initial-mount path. The user observed that clicking the chat
    // button TWICE landed on the right position — that's the symptom of
    // a single-frame write losing to a still-in-progress flex relayout.
    // The cascade replicates "click again later", just automatically.
    onShown() {
        const followNow  = !!this.followMode;
        const followThen = !!this._savedFollowMode;
        const wantBottom = followNow || followThen;
        const savedTop   = this._savedScrollTop;
        const anchor     = this._savedAnchor;

        // Resume the paused history backfill (see onHidden).
        this._prefetchPaused = false;
        if (this._prefetchStarted) {
            clearTimeout(this._prefetchTimer);
            this._prefetchTimer = setTimeout(() => this._prefetchTick(), 600);
        }

        const apply = () => {
            if (this.destroyed) return;
            if (wantBottom) {
                if (this.followMode) this.scrollToBottom();
                return;
            }
            // Prefer the CONTENT anchor: land on the message the user was
            // reading, not on whatever pixel offset the re-measured heights
            // now map to. Falls back to the raw scrollTop while the anchor
            // node isn't rendered yet (a later cascade retry snaps it true).
            const n = anchor && this.rendered.has(anchor.idx) ? this.cache.get(anchor.idx) : null;
            if (n && n.isConnected) {
                this.container.scrollTop = n.offsetTop - anchor.off;
            } else if (savedTop != null) {
                this.container.scrollTop = savedTop;
            }
            // Programmatic, possibly event-less write: sync the direction
            // baseline (see _prevScrollTop).
            this._prevScrollTop = this.container.scrollTop;
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
    _setupInputs() {
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

        // Thumbnail strip lives ABOVE the input row inside .bt-input-area.
        this.attachBar = document.createElement('div');
        this.attachBar.className = 'bt-attachments';
        this.inputArea.insertBefore(this.attachBar, this.inputArea.firstChild);

        this.attachments = new Map();
        this._attachIdCounter = 0;
        this.ATTACH_MAX_BYTES = 5 * 1024 * 1024;

        // Paste — clipboardData.items carries File entries for images.
        this._onPaste = (e) => {
            const items = e.clipboardData?.items;
            if (!items) return;
            for (const it of items) {
                if (it.kind === 'file' && it.type && it.type.startsWith('image/')) {
                    const blob = it.getAsFile();
                    if (blob) this._attachAddBlob(blob, blob.type || it.type,
                                                  blob.name || `pasted-${Date.now()}.png`);
                }
            }
        };
        this.textInput.addEventListener('paste', this._onPaste);

        // Drag-drop — listen on the whole .bt-app so a drop anywhere in
        // the chat counts. dragover MUST preventDefault to enable drop.
        this._onDragOver = (e) => {
            if (!this._dragHasImage(e)) return;
            e.preventDefault();
            this.app.classList.add('bt-drag-over');
        };
        this._onDragLeave = (e) => {
            // Only clear when leaving the .bt-app envelope itself, not
            // when crossing between nested children (relatedTarget inside app).
            if (e.relatedTarget && this.app.contains(e.relatedTarget)) return;
            this.app.classList.remove('bt-drag-over');
        };
        this._onDrop = (e) => {
            e.preventDefault();
            this.app.classList.remove('bt-drag-over');
            const files = e.dataTransfer?.files;
            if (!files) return;
            for (const f of files) {
                if (f.type && f.type.startsWith('image/')) {
                    this._attachAddBlob(f, f.type, f.name || `dropped-${Date.now()}.png`);
                }
            }
        };
        this.app.addEventListener('dragover',  this._onDragOver);
        this.app.addEventListener('dragleave', this._onDragLeave);
        this.app.addEventListener('drop',      this._onDrop);

        // Single delegated click handler on the chat root. Capture phase
        // so we run before any inner element that might (in the future)
        // also wire a click handler. `target.closest` survives DOM swaps
        // and works regardless of when the buttons are added.
        this._onAppClickCapture = (e) => {
            if (this.destroyed) return;
            if (e.target.closest('.bt-send-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this._submit();
            } else if (e.target.closest('.bt-stop-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this._cancel();
            }
        };
        this.app.addEventListener('click', this._onAppClickCapture, true);

        // Enter-to-send on the textarea (Shift+Enter newline as usual).
        this._onTextInputKeyCapture = (e) => {
            if (e.key !== 'Enter' || e.shiftKey) return;
            e.preventDefault();
            e.stopImmediatePropagation();
            this._submit();
        };
        this.textInput.addEventListener('keydown', this._onTextInputKeyCapture, true);

        // ESC anywhere → cancel. Listener on `document` so the user's
        // current focus (textarea, scroll position, anywhere) can't
        // suppress it. The Monaco tool-body editor owns ESC for its own
        // semantics — skip when the user is editing inside one.
        this._onEscapeKey = (e) => {
            if (e.key !== 'Escape' || e.repeat) return;
            // Document-level listener + kept-alive panes (display:none but
            // connected) = EVERY chat instance hears this. Only the VISIBLE
            // pane may cancel — one ESC used to cancel the running turn of
            // every open chat. offsetParent is null while the pane (or any
            // ancestor) is display:none. A container that left the document
            // entirely means the `connect` MutationObserver missed an
            // ancestor-level unmount: self-destroy.
            if (!this.container.isConnected) { this._lazyDestroy(); return; }
            if (this.container.offsetParent === null) return;
            const t = e.target;
            if (t && t.closest && t.closest('.monaco-editor')) return;
            e.preventDefault();
            this._cancel();
        };
        document.addEventListener('keydown', this._onEscapeKey, true);
    }

    // Fire a cancel notification. Used by both the stop button click
    // and the ESC keystroke. Stays a one-line helper so the two
    // entry points can't drift in what they send.
    // Carries the sequence number of the turn the user is LOOKING AT
    // (`turn_begin`), so a stale click can never cancel a later turn.
    _cancel() {
        this.comm.notify({type: 'cancel', seq: this.turnSeq ?? -1});
    }

    _dragHasImage(e) {
        const dt = e.dataTransfer;
        if (!dt) return false;
        if (dt.types) {
            // 'Files' is the type when the user drags from the OS file picker.
            // Browsers don't expose individual MIME types during dragover, so
            // we accept any Files drag here and filter image/* on drop.
            for (const t of dt.types) if (t === 'Files') return true;
        }
        return false;
    }

    _attachAddBlob(blob, mime, filename) {
        if (blob.size > this.ATTACH_MAX_BYTES) {
            this._showAttachError(
                `Image too large (${(blob.size / 1024 / 1024).toFixed(1)} MB, ` +
                `max ${this.ATTACH_MAX_BYTES / 1024 / 1024} MB)`);
            return;
        }
        const id = `att-${++this._attachIdCounter}`;
        const reader = new FileReader();
        reader.onload = () => {
            if (this.destroyed) return;
            this.attachments.set(id, {
                blob, mime, filename,
                dataUrl: reader.result,
            });
            this._renderAttachments();
        };
        reader.onerror = () => this._showAttachError('Failed to read image');
        reader.readAsDataURL(blob);
    }

    _attachRemove(id) {
        this.attachments.delete(id);
        this._renderAttachments();
    }

    _attachClear() {
        this.attachments.clear();
        this._renderAttachments();
    }

    _renderAttachments() {
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
                wrap.className = 'bt-attachment-thumb';
                wrap.dataset.attachId = id;
                const img = document.createElement('img');
                img.src   = item.dataUrl;
                img.alt   = item.filename || 'image';
                img.title = item.filename || 'image';
                wrap.appendChild(img);
                const rm = document.createElement('button');
                rm.type = 'button';
                rm.className = 'bt-attachment-remove';
                rm.title = 'Remove';
                rm.textContent = '×';
                rm.addEventListener('click', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    this._attachRemove(id);
                });
                wrap.appendChild(rm);
                this.attachBar.appendChild(wrap);
            }
        }
        if (err) this.attachBar.appendChild(err);
    }

    _showAttachError(message) {
        if (!this.attachBar) return;
        let chip = this.attachBar.querySelector('.bt-attach-error');
        if (!chip) {
            chip = document.createElement('div');
            chip.className = 'bt-attach-error';
            this.attachBar.appendChild(chip);
            this.attachBar.classList.add('bt-attachments-active');
        }
        chip.textContent = message;
        clearTimeout(this._attachErrorTimer);
        this._attachErrorTimer = setTimeout(() => {
            chip.remove();
            if (this.attachments.size === 0) {
                this.attachBar.classList.remove('bt-attachments-active');
            }
        }, 4500);
    }

    async _submit() {
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
        const payload = [];
        for (const item of this.attachments.values()) {
            const buf = await item.blob.arrayBuffer();
            payload.push({
                mime:     item.mime,
                filename: item.filename || '',
                data:     arrayBufferToBase64(buf),
            });
        }
        this.comm.notify({type: 'send', text, attachments: payload});
        // Clear the local input immediately. We don't wait for any
        // server ack — the textarea content is already encoded on the
        // wire, Julia will surface errors (e.g. attachment rejection)
        // via a separate event, and locking the user out of typing
        // their next message while bytes are in flight would be hostile.
        this.textInput.value = '';
        this.textInput.dispatchEvent(new Event('input', {bubbles: true}));
        this._attachClear();
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
        const vv  = window.visualViewport;
        const app = this.app || this.container.closest('.bt-app');
        if (app) app.style.height = vv.height + 'px';
        if (this.followMode) this._queueScrollToBottom();
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
    _applyUserScroll(prevTop) {
        const { scrollTop, scrollHeight, clientHeight } = this.container;
        const atBot = this.atBottom();
        if (this.followMode && !atBot) {
            this.setFollowMode(false);
            this._cancelPendingScroll();
        }
        if (this.followMode) return;
        if (atBot || (scrollTop > prevTop &&
                      scrollHeight - scrollTop - clientHeight < clientHeight &&
                      !this.lastMessageFullyOutOfView())) {
            this.setFollowMode(true);
            // Pin the viewport. The chase rAF defers while the gesture is
            // still in flight and re-arms itself (see _queueScrollToBottom),
            // so it lands right after the input window lapses — and a
            // disengage meanwhile cancels it as always.
            this._queueScrollToBottom();
        } else {
            // Off-bottom without re-engaging: any pending chase yields to
            // the user's position (same cancel the old handler did).
            this._cancelPendingScroll();
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
            this._hideNewMessagePill();
        }
    }

    _cancelPendingScroll() {
        if (this._scrollRafId !== null && this._scrollRafId !== undefined) {
            cancelAnimationFrame(this._scrollRafId);
            this._scrollRafId = null;
            this._scrollQueued = false;
        }
    }

    // Bump unread + surface the pill. Called from appendNewMessage and
    // appendChunk when followMode is off. Appending only ever pushes the
    // last message FURTHER down, so re-checking the criterion here can
    // flip the pill ON (never off); while the freshly appended message is
    // still partially visible there's no pill — just keep the glow/label
    // fresh in case it's already showing.
    _registerUnread() {
        this.unreadCount++;
        if (this.lastMessageFullyOutOfView()) {
            this._showNewMessagePill();
        } else {
            this._refreshPillContent();
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
    _updateScrollAffordance(atBot) {
        if (atBot) {
            this.unreadCount = 0;
            this._hideNewMessagePill();
        } else if (this.lastMessageFullyOutOfView()) {
            this._showNewMessagePill();
        } else {
            this._hideNewMessagePill();
        }
    }

    _showNewMessagePill() {
        if (!this._pillEl) this._createNewMessagePill();
        if (!this._pillEl) return;
        // Touch classList only on an actual hidden→shown flip (the scroll
        // handler re-derives visibility on every event) — but ALWAYS refresh
        // the glow/label: unread can arrive while the pill is already up.
        if (!this._pillShown) {
            this._pillShown = true;
            this._pillEl.classList.add('bt-new-msg-pill-visible');
        }
        this._refreshPillContent();
    }

    _hideNewMessagePill() {
        if (!this._pillShown) return;
        this._pillShown = false;
        if (this._pillEl) this._pillEl.classList.remove('bt-new-msg-pill-visible');
    }

    // Glow + "New messages" only while there's unread content; otherwise the
    // plain "Move to bottom" form (same popup, no glow).
    _refreshPillContent() {
        if (!this._pillEl) return;
        const hasUnread = this.unreadCount > 0;
        this._pillEl.classList.toggle('bt-new-msg-pill-glow', hasUnread);
        if (this._pillLabelEl) {
            this._pillLabelEl.textContent = hasUnread ? 'New messages' : 'Move to bottom';
        }
    }

    // Pill lives inside .bt-app, absolutely positioned above the input
    // area. We append it once and toggle its visibility class. Click →
    // re-engage follow mode and scroll to the bottom.
    _createNewMessagePill() {
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
        app.appendChild(pill);
        this._pillEl = pill;
        this._pillLabelEl = label;
    }
}

// Conservative "this inline code span IS a file path" test: at least one
// directory separator, path-ish characters only, optional trailing :line —
// and not a URL. Bare names like `foo.jl` stay unlinked on purpose (too many
// false positives: package names, "Project.toml" as a concept, …).
const PATH_RE = /^(~|\.{1,2})?\/?[\w.@+-]+(\/[\w.@+-]+)+(:\d+)?$/;

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
            if (!navigator.clipboard) return;
            navigator.clipboard.writeText(codeText()).then(() => {
                b.textContent = '✓';
                setTimeout(() => { b.textContent = '⧉'; }, 1200);
            }).catch(() => {});
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

// Turn path-looking inline `code` spans inside an agent message into
// clickable path links (the delegated container listener opens them in the
// plotpane editor). Fenced blocks (<pre><code>) are skipped — linkifying
// inside code listings is noise.
function linkifyPaths(rootEl) {
    rootEl.querySelectorAll('code').forEach((el) => {
        if (el.closest('pre') || el.closest('a')) return;
        const text = (el.textContent || '').trim();
        if (!PATH_RE.test(text) || text.includes('://')) return;
        el.classList.add('bt-path-link');
        el.dataset.path = text;
    });
}

// Click-to-enlarge for JS-created media (user-bubble attachment images).
// Mirrors the Julia-side LIGHTBOX_OPEN_JS (chat.jl) used by bt_show / Read
// previews: clone into a fullscreen overlay, Esc or backdrop click closes.
function openLightbox(media) {
    const overlay = document.createElement('div');
    overlay.className = 'bt-lightbox-overlay';
    const big = media.cloneNode(true);
    big.classList.add('bt-lightbox-media');
    overlay.appendChild(big);
    const close = () => { overlay.remove(); document.removeEventListener('keydown', onkey); };
    const onkey = e => { if (e.key === 'Escape') close(); };
    overlay.addEventListener('click', e => { if (e.target === overlay) close(); });
    document.addEventListener('keydown', onkey);
    document.body.appendChild(overlay);
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

// Write a tool pill's FINAL duration into its `.bt-tool-timer`, once, from
// its started/finished data attrs. Event-driven (called on creation of an
// already-finished pill and on the completion update) — there is no timer.
// A still-running pill (no finished attr) shows nothing; its live elapsed
// is the taskbar's job (Julia clock).
function _writeToolElapsed(node) {
    if (!node) return;
    const timer = node.querySelector('.bt-tool-timer');
    if (!timer) return;
    const started  = parseFloat(node.dataset.toolStarted  ?? '0');
    const finished = parseFloat(node.dataset.toolFinished ?? '0');
    if (!started || !finished) return;
    const dt = finished - started;
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
const CHAT_INSTANCES = new Set();
// Debug/test introspection: e.g. `[...window.__btChats][0].APP_KEEPALIVE` /
// `.parked.size`. Read-only convenience; not used by product code.
if (typeof window !== 'undefined') window.__btChats = CHAT_INSTANCES;

// Find the tool-body slot for `id` — in the live DOM, or on a cached node a
// virtual-scroll window currently holds detached. A module export (Julia's
// dom_in_js callbacks resolve it via `$(ChatLib).then(lib => lib.toolSlot(...))`)
// instead of the former `window._btToolSlot` global.
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

export function connect(node, comm) {
    const chat = new BonitoChat(node, comm);
    node.__bt_chat = chat;     // devtools/test inspection hook
    CHAT_INSTANCES.add(chat);

    const parent = node.parentNode;
    if (parent) {
        const mo = new MutationObserver(() => {
            if (!node.isConnected) {
                try { chat.destroy(); } catch (_) {}
                CHAT_INSTANCES.delete(chat);
                mo.disconnect();
            }
        });
        mo.observe(parent, { childList: true });
    }
    return chat;
}

export { BonitoChat };

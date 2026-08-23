// deno-fmt-ignore-file
// deno-lint-ignore-file
// This code was bundled using `deno bundle` and it's not recommended to edit it manually

if (typeof document !== 'undefined') {
    const vp = document.querySelector('meta[name="viewport"]');
    if (vp && !vp.content.includes('interactive-widget')) vp.content += ', interactive-widget=resizes-content';
}
function queueLabel(pos) {
    if (!Number.isInteger(pos) || pos < 1) return 'queued';
    if (pos === 1) return 'next up';
    return `queued \u00b7 #${pos}`;
}
class Collapsable {
    constructor(headerEl, bodyEl, opts = {}){
        this.header = headerEl;
        this.body = bodyEl;
        this.toggle = opts.toggleEl || null;
        this.native = opts.native || false;
        this.editMode = opts.editMode || false;
        this.hideBodyOnCollapse = opts.hideBodyOnCollapse || false;
        this.compactHeight = opts.compactHeight || 240;
        this.expandedHeight = opts.expandedHeight || 2000;
        this.fetchEachExpand = this.editMode ? false : opts.fetchEachExpand || false;
        this.discardOnCollapse = this.editMode ? false : opts.discardOnCollapse || false;
        this.onExpand = opts.onExpand || null;
        this.lazy = !!this.onExpand;
        this.loaded = !this.lazy;
        this.expanded = false;
        if (this.native) {
            this.details = headerEl.closest('details') || bodyEl.closest('details');
            this.details && this.details.addEventListener('toggle', ()=>this.applyExpanded(this.details.open));
        } else {
            headerEl.style.cursor = 'pointer';
            headerEl.addEventListener('click', (e)=>{
                if (this.expanded && this.toggle && e.target !== this.toggle && !this.toggle.contains(e.target)) return;
                this.applyExpanded(!this.expanded);
            });
        }
    }
    setExpanded(expanded) {
        if (this.native) {
            if (this.details) this.details.open = expanded;
            return;
        }
        this.applyExpanded(expanded);
    }
    applyExpanded(expanded) {
        if (expanded === this.expanded) return;
        this.expanded = expanded;
        if (!this.native) {
            this.header.dataset.expanded = expanded ? 'true' : 'false';
            if (this.toggle) this.toggle.textContent = expanded ? '▼' : '▶';
            if (this.editMode && !this.hideBodyOnCollapse) {
                this.body.style.display = '';
                this.applyEditHeight(expanded ? this.expandedHeight : this.compactHeight);
            } else {
                this.body.style.display = expanded ? '' : 'none';
            }
        }
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
    applyEditHeight(h) {
        const divs = this.body.querySelectorAll('.monaco-diff-editor-div');
        divs.forEach((div)=>{
            const monaco = div.__btMonacoDiff;
            if (monaco && typeof monaco.setMaxHeight === 'function') monaco.setMaxHeight(h);
        });
    }
    fill(html) {
        if (html != null) this.body.innerHTML = html;
        this.loaded = true;
    }
}
const filterKey = (msg)=>msg.type === 'tool' ? 'tool:' + (msg.tool || 'other') : msg.type;
const DEFAULT_HIDDEN = [
    'tool:ToolSearch'
];
class BonitoChat {
    constructor(container, comm){
        this.container = container;
        this.comm = comm;
        this.destroyed = false;
        this.cache = new Map();
        this.heights = new Map();
        this.rendered = new Set();
        this.nodeById = new Map();
        this.observed = new Set();
        this.totalCount = 0;
        this.EST_HEIGHT = 80;
        this.OVERSCAN = 8;
        this.initialLoad = false;
        this.bootstrapped = false;
        this.measuredHeightSum = 0;
        this.measuredHeightCount = 0;
        this.spacerTopHeight = -1;
        this.spacerBottomHeight = -1;
        this.requestedAt = new Map();
        this.epoch = 0;
        this.STREAM_APPLY_MS = 100;
        this.messageHeightObserver = new ResizeObserver((entries)=>{
            if (this.destroyed) return;
            let changed = false;
            for (const e of entries){
                const idx = e.target.__btIdx;
                if (idx === undefined) continue;
                const h = e.borderBoxSize && e.borderBoxSize.length ? e.borderBoxSize[0].blockSize : e.target.offsetHeight;
                if (h > 0 && this.heights.get(idx) !== h) {
                    this.heights.set(idx, h);
                    changed = true;
                }
            }
            if (changed && !this.scrollbarDrag) this.queueRefresh();
        });
        const wantKeepalive = typeof window !== 'undefined' && Number.isFinite(window.BT_APP_KEEPALIVE) ? window.BT_APP_KEEPALIVE : 6;
        this.APP_KEEPALIVE = Math.min(10, Math.max(0, wantKeepalive));
        this.parked = new Set();
        this.appLru = [];
        this.ITEM_GAP = parseFloat(getComputedStyle(container).rowGap) || 0;
        this.PAD_TOP = parseFloat(getComputedStyle(container).paddingTop) || 0;
        this.followMode = true;
        this.unreadCount = 0;
        this.pillShown = false;
        this.AT_BOTTOM_PX = 20;
        this.prevScrollTop = container.scrollTop;
        this.spacerTop = container.querySelector('.bt-spacer-top');
        this.spacerBottom = container.querySelector('.bt-spacer-bottom');
        this.toolbarEl = (container.closest('.bt-app') || container.parentElement).querySelector('.bt-chat-toolbar');
        if (this.toolbarEl) this.toolbarEl.style.display = 'none';
        this.hiddenTypes = new Set(DEFAULT_HIDDEN);
        this.seenTypes = new Set();
        this.keyByIdx = new Map();
        this.filterRow = null;
        this.nativeImages = true;
        this.nativeVideos = true;
        this.lensActive = false;
        this.lensVisible = null;
        this.lensActions = null;
        this.lensQuery = '';
        this.lensVocab = [];
        this.savedLenses = [];
        this.lensClauses = [];
        this.lensPendingSign = '+';
        this.busyEl = container.querySelector('.bt-busy');
        this.waitingEl = container.querySelector('.bt-waiting');
        this.thinkingEl = container.querySelector('.bt-thinking');
        this.thinkingCountEl = container.querySelector('.bt-thinking-count');
        this.tailEl = container.querySelector('.bt-messages-tail');
        this.sizeTail();
        this.measureEl = document.createElement('div');
        this.measureEl.className = 'bt-measure';
        container.parentElement.appendChild(this.measureEl);
        this.startSettle();
        comm.on((msg)=>{
            if (this.destroyed) return false;
            if (msg && typeof msg === 'object') this.dispatch(msg);
        });
        const cur = comm.value;
        if (cur && cur.type === 'msgs.count' && cur.n > 0) {
            this.applyCount(cur.n);
        } else if (cur && cur.type === 'msgs.range') {
            this.startSettle();
            this.onRange(cur);
            this.startPrefetch();
        }
        comm.notify({
            type: 'init'
        });
        this.lastUserInputT = 0;
        this.pendingUserScroll = false;
        const markUserInput = ()=>{
            this.lastUserInputT = performance.now();
            this.pendingUserScroll = true;
            this.cancelPendingScroll();
        };
        container.addEventListener('wheel', markUserInput, {
            passive: true
        });
        container.addEventListener('touchstart', markUserInput, {
            passive: true
        });
        container.addEventListener('touchmove', markUserInput, {
            passive: true
        });
        container.addEventListener('keydown', markUserInput, {
            passive: true
        });
        this.markUserInput = markUserInput;
        container.addEventListener('click', (e)=>{
            const link = e.target.closest('.bt-path-link');
            if (!link || !container.contains(link)) return;
            const path = link.dataset.path || link.textContent.trim();
            if (!path) return;
            e.preventDefault();
            e.stopPropagation();
            this.comm.notify({
                type: 'edit_file',
                path
            });
        }, {
            capture: true
        });
        this.scrollbarDrag = false;
        this.onContainerMouseDown = ()=>{
            this.scrollbarDrag = true;
            markUserInput();
        };
        this.onWindowMouseUp = ()=>{
            if (!this.container.isConnected) {
                this.lazyDestroy();
                return;
            }
            if (!this.scrollbarDrag) return;
            this.scrollbarDrag = false;
            markUserInput();
            for (const idx of this.rendered){
                const node = this.cache.get(idx);
                if (node && node.isConnected && node.dataset.btAutoExpand) {
                    delete node.dataset.btAutoExpand;
                    node.collapsable?.setExpanded(true);
                }
            }
            this.queueRefresh();
        };
        container.addEventListener('mousedown', this.onContainerMouseDown, {
            passive: true
        });
        window.addEventListener('mouseup', this.onWindowMouseUp, {
            passive: true
        });
        const PAN_FRICTION = 0.94;
        this.overscroll = 0;
        this.panState = null;
        this.momentumRaf = null;
        this.springRaf = null;
        const setOverscroll = (v)=>{
            this.overscroll = v;
            this.container.style.setProperty('--bt-overscroll', v + 'px');
            this.container.classList.toggle('bt-overscrolling', v !== 0);
        };
        this.setOverscroll = setOverscroll;
        this.cancelMomentum = ()=>{
            if (this.momentumRaf !== null) {
                cancelAnimationFrame(this.momentumRaf);
                this.momentumRaf = null;
            }
            if (this.springRaf !== null) {
                cancelAnimationFrame(this.springRaf);
                this.springRaf = null;
            }
        };
        const springStep = ()=>{
            this.springRaf = null;
            if (this.destroyed) return;
            if (Math.abs(this.overscroll) < 0.5) {
                setOverscroll(0);
                return;
            }
            setOverscroll(this.overscroll * 0.72);
            this.springRaf = requestAnimationFrame(springStep);
        };
        const startSpring = ()=>{
            if (this.springRaf !== null || this.overscroll === 0) return;
            this.springRaf = requestAnimationFrame(springStep);
        };
        const momentumStep = (vel)=>{
            this.momentumRaf = null;
            if (this.destroyed) return;
            const delta = vel * 16;
            const maxScroll = this.container.scrollHeight - this.container.clientHeight;
            const prevTop = this.container.scrollTop;
            let newTop = prevTop - delta;
            let hitEdge = false;
            if (newTop < 0) {
                setOverscroll(this.overscroll + -newTop * 0.40);
                this.container.scrollTop = 0;
                hitEdge = true;
            } else if (newTop > maxScroll) {
                setOverscroll(this.overscroll - (newTop - maxScroll) * 0.40);
                this.container.scrollTop = maxScroll;
                hitEdge = true;
            } else {
                this.container.scrollTop = newTop;
            }
            if (this.container.scrollTop !== prevTop) this.applyUserScroll(prevTop);
            this.prevScrollTop = this.container.scrollTop;
            this.lastUserInputT = performance.now();
            vel = hitEdge ? 0 : vel * PAN_FRICTION;
            if (Math.abs(vel) < 0.03) {
                startSpring();
                return;
            }
            this.momentumRaf = requestAnimationFrame(()=>momentumStep(vel));
        };
        const onPanDown = (e)=>{
            if (e.pointerType === 'touch') return;
            if (e.button !== 0) return;
            if (this.scrollbarDrag) return;
            if (e.target.closest('input, textarea, button, a, select, [contenteditable]')) return;
            this.cancelMomentum();
            this.panState = {
                pointerId: e.pointerId,
                startY: e.clientY,
                lastY: e.clientY,
                lastT: performance.now(),
                velocity: 0,
                engaged: false
            };
        };
        const onPanMove = (e)=>{
            const p = this.panState;
            if (!p || e.pointerId !== p.pointerId) return;
            if (!p.engaged) {
                if (Math.abs(e.clientY - p.startY) < 6) return;
                const sel = window.getSelection();
                if (sel && sel.toString().length > 0) {
                    this.panState = null;
                    return;
                }
                p.engaged = true;
                p.lastY = e.clientY;
                p.lastT = performance.now();
                try {
                    this.container.setPointerCapture(e.pointerId);
                } catch (_) {}
                this.container.classList.add('bt-messages-grabbing');
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
                setOverscroll(this.overscroll + -newTop * 0.55);
                this.container.scrollTop = 0;
            } else if (newTop > maxScroll) {
                setOverscroll(this.overscroll - (newTop - maxScroll) * 0.55);
                this.container.scrollTop = maxScroll;
            } else {
                if (this.overscroll !== 0) setOverscroll(0);
                this.container.scrollTop = newTop;
            }
            if (this.container.scrollTop !== prevTop) this.applyUserScroll(prevTop);
            this.prevScrollTop = this.container.scrollTop;
            if (stepDt > 0) {
                const instant = stepDy / stepDt;
                p.velocity = 0.65 * instant + 0.35 * p.velocity;
            }
            p.lastY = e.clientY;
            p.lastT = now;
            this.lastUserInputT = now;
        };
        const onPanUp = (e)=>{
            const p = this.panState;
            if (!p || e.pointerId !== p.pointerId) return;
            const engaged = p.engaged;
            const vel = p.velocity;
            this.panState = null;
            if (!engaged) return;
            try {
                this.container.releasePointerCapture(e.pointerId);
            } catch (_) {}
            this.container.classList.remove('bt-messages-grabbing');
            if (Math.abs(vel) > 0.10) {
                this.momentumRaf = requestAnimationFrame(()=>momentumStep(vel));
            } else if (this.overscroll !== 0) {
                startSpring();
            }
        };
        container.addEventListener('pointerdown', onPanDown);
        container.addEventListener('pointermove', onPanMove);
        container.addEventListener('pointerup', onPanUp);
        container.addEventListener('pointercancel', onPanUp);
        this.onPanDown = onPanDown;
        this.onPanMove = onPanMove;
        this.onPanUp = onPanUp;
        this.onScroll = ()=>{
            if (this.container.clientHeight === 0) return;
            this.lastGoodTop = this.container.scrollTop;
            const userDriven = this.scrollbarDrag || this.pendingUserScroll || performance.now() - this.lastUserInputT < 400;
            this.pendingUserScroll = false;
            const atBot = this.atBottom();
            const prevTop = this.prevScrollTop;
            this.prevScrollTop = this.container.scrollTop;
            if (userDriven) {
                if (this.container.scrollTop !== prevTop) {
                    this.applyUserScroll(prevTop);
                }
            } else if (this.followMode && !atBot) {
                this.queueScrollToBottom();
            }
            this.updateScrollAffordance(atBot);
            this.refresh();
        };
        container.addEventListener('scroll', this.onScroll, {
            passive: true
        });
        this.viewportObserver = new ResizeObserver(()=>{
            if (this.destroyed) return;
            if (this.container.clientHeight === 0) return;
            this.sizeTail();
            if (this.followMode) this.queueScrollToBottom();
        });
        this.viewportObserver.observe(this.container);
        this.setupMoveObserver();
        if (this.busyEl) this.viewportObserver.observe(this.busyEl);
        if (this.waitingEl) this.viewportObserver.observe(this.waitingEl);
        if (this.thinkingEl) this.viewportObserver.observe(this.thinkingEl);
        if (window.visualViewport) {
            this.onVisualViewportResize = ()=>this.onViewportResize();
            window.visualViewport.addEventListener('resize', this.onVisualViewportResize);
        }
        Promise.resolve().then(()=>{
            this.setupInputs();
            this.setupLiveTicker();
            this.setupLens();
        });
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
            this.container.removeEventListener('wheel', this.markUserInput);
            this.container.removeEventListener('touchstart', this.markUserInput);
            this.container.removeEventListener('touchmove', this.markUserInput);
            this.container.removeEventListener('keydown', this.markUserInput);
        }
        if (this.onContainerMouseDown) {
            this.container.removeEventListener('mousedown', this.onContainerMouseDown);
        }
        if (this.onWindowMouseUp) {
            window.removeEventListener('mouseup', this.onWindowMouseUp);
        }
        if (this.onPanDown) {
            this.container.removeEventListener('pointerdown', this.onPanDown);
            this.container.removeEventListener('pointermove', this.onPanMove);
            this.container.removeEventListener('pointerup', this.onPanUp);
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
        if (this.messageHeightObserver) this.messageHeightObserver.disconnect();
        if (this.moveObserver) this.moveObserver.disconnect();
        this.observed.clear();
        if (this.onPaste && this.textInput) {
            this.textInput.removeEventListener('paste', this.onPaste);
        }
        if (this.onTextInputKeyCapture && this.textInput) {
            this.textInput.removeEventListener('keydown', this.onTextInputKeyCapture, true);
        }
        if (this.textInput) {
            this.onCmdInput && this.textInput.removeEventListener('input', this.onCmdInput);
            this.onCmdBlur && this.textInput.removeEventListener('blur', this.onCmdBlur);
        }
        if (this.cmdAc) {
            this.cmdAc.remove();
            this.cmdAc = null;
        }
        if (this.onAppClickCapture && this.app) {
            this.app.removeEventListener('click', this.onAppClickCapture, true);
        }
        if (this.onEscapeKey) {
            document.removeEventListener('keydown', this.onEscapeKey, true);
        }
        if (this.app) {
            this.onDragOver && this.app.removeEventListener('dragover', this.onDragOver);
            this.onDragLeave && this.app.removeEventListener('dragleave', this.onDragLeave);
            this.onDrop && this.app.removeEventListener('drop', this.onDrop);
        }
        clearTimeout(this.attachErrorTimer);
        clearTimeout(this.prefetchTimer);
        if (!this.settleDone && this.paneEl) delete this.paneEl.dataset.btSettling;
        if (this.measureEl) {
            this.measureEl.remove();
            this.measureEl = null;
        }
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
    lazyDestroy() {
        if (this.destroyed) return;
        try {
            this.destroy();
        } catch (_) {}
        CHAT_INSTANCES.delete(this);
    }
    dispatch(msg) {
        if (typeof msg.n === 'number' && msg.n > this.totalCount) {
            this.totalCount = msg.n;
        }
        switch(msg.type){
            case 'msgs.count':
                return this.applyCount(msg.n);
            case 'msgs.reload':
                return this.onMsgsReload(msg.n);
            case 'turn_begin':
                this.turnSeq = msg.seq;
                return;
            case 'commands':
                this.slashCommands = msg.items || [];
                return;
            case 'lens.vocab':
                this.lensVocab = msg.keys || [];
                return;
            case 'lens.saved':
                return this.onLensSaved(msg);
            case 'lens.result':
                return this.onLensResult(msg);
            case 'msgs.range':
                return this.onRange(msg);
            case 'session_reset':
                return this.onSessionReset();
            case 'busy_start':
                this.busyEl?.classList.add('bt-busy-active');
                if (this.followMode) this.queueScrollToBottom();
                return;
            case 'busy_end':
                this.busyEl?.classList.remove('bt-busy-active');
                if (this.followMode) this.queueScrollToBottom();
                return;
            case 'agent_final':
                return this.onAgentFinal(msg);
            case 'thinking':
                return this.onThinking(msg);
            case 'permission':
                return this.onPermission(msg);
            case 'permission_done':
                return this.onPermissionDone(msg);
            case 'question':
                return this.onQuestion(msg);
            case 'question_done':
                return this.onPermissionDone(msg);
            case 'thought_final':
                return this.onThoughtFinal(msg);
            case 'thought.body':
                return this.onThoughtBody(msg);
            case 'tool_update':
                return this.onToolUpdate(msg);
            case 'task_activity':
                return this.onTaskActivity(msg);
            case 'plan_update':
                return this.onPlanUpdate(msg);
            case 'chunk':
                return this.appendChunk(msg);
            case 'user_chunk':
                return this.appendUserChunk(msg.text);
            case 'user_unqueue':
                return this.unqueueUser(msg);
            case 'user_requeue':
                return this.requeueUser(msg);
            case 'summary_final':
                return this.onSummaryFinal(msg);
            case 'attach_error':
                return this.showAttachError(msg.error || 'Attachment failed');
            case 'user':
            case 'agent':
            case 'thought':
            case 'tool':
            case 'plan':
            case 'summary':
                return this.appendNewMessage(msg);
        }
    }
    onMsgsReload(n) {
        for (const node of this.cache.values())node.remove();
        this.cache.clear();
        this.heights.clear();
        this.rendered.clear();
        this.nodeById.clear();
        this.observed.clear();
        this.requestedAt.clear();
        this.cancelPendingScroll();
        this.epoch++;
        this.prefetchStarted = false;
        this.prefetchCursor = null;
        this.prefetchPending = null;
        clearTimeout(this.prefetchTimer);
        this.totalCount = 0;
        this.bootstrapped = false;
        this.followMode = true;
        this.unreadCount = 0;
        this.applyCount(n);
    }
    applyCount(n) {
        if (n <= 0) {
            this.startSettle();
            this.settle();
            return;
        }
        this.totalCount = n;
        if (!this.bootstrapped) {
            this.bootstrapped = true;
            this.initialLoad = true;
        }
        this.startSettle();
        this.refresh();
        this.startPrefetch();
    }
    startSettle() {
        if (this.settleWatch || this.settleDone) return;
        this.settleWatch = true;
        this.settleStartedAt = performance.now();
        this.settleLastHeight = -1;
        this.settleStable = 0;
        this.paneEl = this.container.closest('.bt-chatpane');
        if (this.paneEl) {
            delete this.paneEl.dataset.btSettled;
            this.paneEl.dataset.btSettling = '1';
        }
        this.announceSettle('bt-chat-settling');
        const watch = ()=>{
            if (this.destroyed || this.settleDone) return;
            const h = this.container.scrollHeight;
            if (h === this.settleLastHeight) this.settleStable++;
            else {
                this.settleStable = 0;
                this.settleLastHeight = h;
            }
            const elapsed = performance.now() - this.settleStartedAt;
            const pendingBody = [
                ...this.container.querySelectorAll('.bt-collapsable-loading')
            ].some((el)=>!(el.closest('.bt-tool-msg')?.dataset.showMime || '').startsWith('video/'));
            const pendingImg = [
                ...this.container.querySelectorAll('img')
            ].some((img)=>!img.complete);
            const settled = this.settleStable >= 10 && elapsed > 400 && !this.initialLoad && !pendingBody && !pendingImg;
            if (settled || elapsed > 5000) this.settle();
            else requestAnimationFrame(watch);
        };
        requestAnimationFrame(watch);
    }
    settle() {
        if (this.settleDone) return;
        this.settleDone = true;
        this.settleWatch = false;
        if (this.followMode) this.scrollToBottom();
        if (this.paneEl) {
            delete this.paneEl.dataset.btSettling;
            this.paneEl.dataset.btSettled = '1';
        }
        this.announceSettle('bt-chat-settled');
    }
    announceSettle(name) {
        const pid = this.paneEl?.dataset.panePid || '';
        window.dispatchEvent(new CustomEvent(name, {
            detail: pid
        }));
    }
    startPrefetch() {
        if (this.prefetchStarted) return;
        this.prefetchStarted = true;
        this.prefetchTimer = setTimeout(()=>this.prefetchTick(), 600);
    }
    prefetchTick() {
        if (this.destroyed) return;
        if (this.prefetchPaused) return;
        let e = -1;
        for(let i = Math.min(this.prefetchCursor ?? Infinity, this.totalCount - 1); i >= 0; i--){
            if (!this.cache.has(i)) {
                e = i;
                break;
            }
        }
        if (e < 0) return;
        let s = e;
        while(s > 0 && !this.cache.has(s - 1) && e - s < 63)s--;
        this.prefetchCursor = s - 1;
        this.prefetchPending = [
            s,
            e
        ];
        this.comm.notify({
            type: 'msgs.request',
            range: [
                s,
                e
            ],
            epoch: this.epoch
        });
        clearTimeout(this.prefetchTimer);
        this.prefetchTimer = setTimeout(()=>this.prefetchTick(), 2000);
    }
    visibleRange() {
        if (this.totalCount === 0) return [
            0,
            -1
        ];
        const { scrollTop , clientHeight  } = this.container;
        const over = this.OVERSCAN * this.EST_HEIGHT;
        const s = this.indexAt(Math.max(0, scrollTop - over));
        const e = this.indexAt(scrollTop + clientHeight + over);
        return [
            s,
            Math.min(this.totalCount - 1, e)
        ];
    }
    effHeight(i) {
        if (this.lensActive && !this.lensVisible.has(i)) return 0;
        if (this.hiddenTypes.has(this.keyByIdx.get(i))) return 0;
        return (this.heights.get(i) ?? this.EST_HEIGHT) + this.ITEM_GAP;
    }
    lensHides(i) {
        return this.lensActive && !this.lensVisible.has(i);
    }
    applyVisibility(idx, node = this.cache.get(idx)) {
        if (!node) return;
        const hidden = this.parked.has(idx) || this.lensHides(idx) || this.hiddenTypes.has(this.keyByIdx.get(idx));
        node.style.display = hidden ? 'none' : '';
    }
    indexAt(offset) {
        let h = 0;
        for(let i = 0; i < this.totalCount; i++){
            h += this.effHeight(i);
            if (h > offset) return i;
        }
        return Math.max(0, this.totalCount - 1);
    }
    cumHeight(from, to) {
        let h = 0;
        for(let i = from; i < to; i++)h += this.effHeight(i);
        return h;
    }
    refresh() {
        if (this.totalCount === 0) return;
        const wasAtBottom = this.atBottom();
        const preHeight = this.container.scrollHeight;
        const [s, e] = this.visibleRange();
        if (!this.scrollbarDrag) {
            const now = performance.now();
            const missing = [];
            for(let i = s; i <= e; i++){
                if (this.cache.has(i)) continue;
                const t = this.requestedAt.get(i);
                if (t !== undefined && now - t < 2000) continue;
                missing.push(i);
            }
            if (missing.length > 0) {
                for (const i of missing)this.requestedAt.set(i, now);
                this.comm.notify({
                    type: 'msgs.request',
                    range: [
                        missing[0],
                        missing[missing.length - 1]
                    ],
                    epoch: this.epoch
                });
            }
        }
        this.updateDOM(s, e);
        const userDriving = this.scrollbarDrag || this.pendingUserScroll || performance.now() - this.lastUserInputT < 400;
        if (wasAtBottom && !userDriving && this.container.scrollHeight !== preHeight) {
            this.container.scrollTop = this.container.scrollHeight;
            this.prevScrollTop = this.container.scrollTop;
        }
    }
    onRange({ start , msgs , epoch  }) {
        if (epoch !== undefined && epoch !== null && epoch !== this.epoch) return;
        const messages = msgs ?? [];
        const fresh = [];
        messages.forEach((data, i)=>{
            const idx = start + i;
            this.requestedAt.delete(idx);
            if (this.cache.has(idx)) return;
            const node = this.createNode(data);
            this.cache.set(idx, node);
            this.keyByIdx.set(idx, filterKey(data));
            if (data.id) this.nodeById.set(data.id, node);
            fresh.push([
                idx,
                node
            ]);
        });
        this.measureNodes(fresh);
        if (this.prefetchStarted && !this.prefetchPaused) {
            clearTimeout(this.prefetchTimer);
            this.prefetchTimer = setTimeout(()=>this.prefetchTick(), 30);
        }
        const pf = this.prefetchPending;
        if (pf && start === pf[0]) {
            this.prefetchPending = null;
            const [vs, ve] = this.visibleRange();
            const end = start + messages.length - 1;
            if (end >= vs && start <= ve && !this.scrollbarDrag) {
                this.updateDOM(vs, ve);
            }
            return;
        }
        if (this.scrollbarDrag) return;
        this.updateDOM(...this.visibleRange());
        if (this.initialLoad) {
            this.initialLoad = true;
            this.setFollowMode(true);
            this.scrollToBottom();
            requestAnimationFrame(()=>{
                if (!this.destroyed && this.followMode) this.scrollToBottom();
            });
            setTimeout(()=>{
                if (!this.destroyed && this.followMode) this.scrollToBottom();
            }, 100);
            setTimeout(()=>{
                if (!this.destroyed && this.followMode) this.scrollToBottom();
                this.initialLoad = false;
            }, 300);
        } else if (this.followMode) {
            this.queueScrollToBottom();
        }
    }
    measureNodes(pairs) {
        if (!this.measureEl || pairs.length === 0) return;
        const cs = getComputedStyle(this.container);
        const w = this.container.clientWidth - (parseFloat(cs.paddingLeft) || 0) - (parseFloat(cs.paddingRight) || 0);
        if (w <= 0) return;
        this.measureEl.style.width = w + 'px';
        const toMeasure = pairs.filter(([idx, node])=>!node.isConnected && !this.heights.has(idx));
        for (const [, node] of toMeasure)this.measureEl.appendChild(node);
        for (const [idx, node] of toMeasure){
            const h = node.offsetHeight;
            if (h > 0) {
                this.heights.set(idx, h);
                this.measuredHeightSum += h;
                this.measuredHeightCount++;
            }
        }
        for (const [, node] of toMeasure){
            if (node.parentNode === this.measureEl) this.measureEl.removeChild(node);
        }
        if (this.measuredHeightCount >= 20) {
            this.EST_HEIGHT = Math.min(400, Math.max(24, this.measuredHeightSum / this.measuredHeightCount));
        }
    }
    observe(idx, node) {
        node.__btIdx = idx;
        this.observed.add(idx);
        this.messageHeightObserver.observe(node);
    }
    queueRefresh() {
        if (this.refreshQueued || this.destroyed) return;
        this.refreshQueued = true;
        requestAnimationFrame(()=>{
            this.refreshQueued = false;
            if (!this.destroyed) this.refresh();
        });
    }
    captureAnchor(excludeKey = null) {
        const st = this.container.scrollTop;
        for (const i of [
            ...this.rendered
        ].sort((a, b)=>a - b)){
            const n = this.cache.get(i);
            if (!n || !n.isConnected || n.style.display === 'none') continue;
            if (excludeKey && n.dataset.filterKey === excludeKey) continue;
            if (n.offsetTop + n.offsetHeight > st + 4) {
                this.anchorDebugGeneric = {
                    st,
                    idx: i,
                    off: n.offsetTop - st
                };
                return {
                    idx: i,
                    off: n.offsetTop - st
                };
            }
        }
        this.anchorDebugGeneric = {
            st,
            idx: -1,
            off: 0
        };
        return null;
    }
    restoreAnchor(a) {
        if (!a) return;
        const n = this.rendered.has(a.idx) ? this.cache.get(a.idx) : null;
        let want;
        if (n && n.isConnected) {
            want = n.offsetTop - a.off;
        } else {
            want = this.cumHeight(0, a.idx) + this.PAD_TOP + this.ITEM_GAP - a.off;
            this.queueRefresh();
        }
        if (Math.abs(this.container.scrollTop - want) > 1) {
            this.container.scrollTop = want;
            this.prevScrollTop = this.container.scrollTop;
        }
    }
    captureKeyAnchor(excludeKey) {
        const st = this.container.scrollTop;
        let vi = this.indexAt(st);
        while(vi < this.totalCount && (this.keyByIdx.get(vi) === excludeKey || this.effHeight(vi) === 0))vi++;
        if (vi >= this.totalCount) return null;
        let di = -1, doff = 0;
        for (const i of [
            ...this.rendered
        ].sort((a, b)=>a - b)){
            const n = this.cache.get(i);
            if (!n || !n.isConnected || n.style.display === 'none') continue;
            if (this.keyByIdx.get(i) === excludeKey) continue;
            if (n.offsetTop + n.offsetHeight > st + 4) {
                di = i;
                doff = n.offsetTop - st;
                break;
            }
        }
        this.anchorDebug = {
            st,
            vi,
            di,
            doff,
            pickedDom: di >= 0 && di <= vi
        };
        if (di >= 0 && di <= vi) {
            return {
                idx: di,
                off: doff,
                dom: true
            };
        }
        return {
            idx: vi,
            dom: false,
            off: this.PAD_TOP + this.ITEM_GAP + this.cumHeight(0, vi) - st
        };
    }
    restoreKeyAnchor(a) {
        if (!a) return;
        let want;
        const n = this.rendered.has(a.idx) ? this.cache.get(a.idx) : null;
        if (a.dom && n && n.isConnected && n.style.display !== 'none') {
            want = n.offsetTop - a.off;
        } else if (a.dom) {
            want = this.PAD_TOP + this.ITEM_GAP + this.cumHeight(0, a.idx) - a.off;
        } else {
            want = this.PAD_TOP + this.ITEM_GAP + this.cumHeight(0, a.idx) - a.off;
        }
        want = Math.max(0, want);
        if (Math.abs(this.container.scrollTop - want) > 1) {
            this.container.scrollTop = want;
            this.prevScrollTop = this.container.scrollTop;
        }
    }
    activeKeyAnchor() {
        const a = this.keyAnchor;
        if (!a) return null;
        if (performance.now() > a.until || this.lastUserInputT > a.setAt) {
            this.keyAnchor = null;
            return null;
        }
        return a;
    }
    updateDOM(s, e) {
        if (s > e) return;
        const sticky = this.activeKeyAnchor();
        const anchor = this.initialLoad || sticky ? null : this.captureAnchor();
        for (const idx of [
            ...this.rendered
        ]){
            if (idx < s || idx > e) {
                const node = this.cache.get(idx);
                if (node && node.dataset && node.dataset.btApp && !node.dataset.btSpilled) {
                    if (!this.parked.has(idx)) {
                        this.parked.add(idx);
                        this.applyVisibility(idx, node);
                        this.touchApp(idx);
                    }
                } else {
                    if (this.observed.delete(idx) && node) this.messageHeightObserver.unobserve(node);
                    node?.remove();
                    this.rendered.delete(idx);
                    this.parked.delete(idx);
                }
            }
        }
        for(let i = s; i <= e; i++){
            if (this.parked.has(i)) {
                const node = this.cache.get(i);
                this.parked.delete(i);
                this.applyVisibility(i, node);
                this.touchApp(i);
            } else if (this.cache.has(i) && !this.rendered.has(i)) {
                const node = this.cache.get(i);
                this.insertSorted(i, node);
                this.rendered.add(i);
                if (!this.observed.has(i)) this.observe(i, node);
                this.applyVisibility(i, node);
                if (node?.dataset?.btApp) this.touchApp(i);
            }
        }
        this.enforceAppLru();
        const topH = this.cumHeight(0, s);
        const botH = this.cumHeight(e + 1, this.totalCount);
        if (topH !== this.spacerTopHeight) {
            this.spacerTop.style.height = topH + 'px';
            this.spacerTopHeight = topH;
        }
        if (botH !== this.spacerBottomHeight) {
            this.spacerBottom.style.height = botH + 'px';
            this.spacerBottomHeight = botH;
        }
        if (sticky) this.restoreKeyAnchor(sticky);
        else this.restoreAnchor(anchor);
    }
    touchApp(idx) {
        const i = this.appLru.indexOf(idx);
        if (i !== -1) this.appLru.splice(i, 1);
        this.appLru.push(idx);
    }
    enforceAppLru() {
        if (this.parked.size <= this.APP_KEEPALIVE) return;
        for (const idx of [
            ...this.appLru
        ]){
            if (this.parked.size <= this.APP_KEEPALIVE) break;
            if (!this.parked.has(idx)) continue;
            this.spillApp(idx, this.cache.get(idx));
        }
    }
    spillApp(idx, node) {
        if (!node) {
            this.parked.delete(idx);
            return;
        }
        const slot = node.querySelector('.bt-slot') || node.querySelector('.bt-tool-body');
        const canvas = node.querySelector('canvas');
        let dataUrl = null;
        if (canvas) {
            try {
                dataUrl = canvas.toDataURL('image/png');
            } catch (_) {}
        }
        if (slot) {
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
            btn.style.cssText = 'position:absolute;top:8px;right:8px;padding:4px 10px;' + 'border-radius:6px;border:1px solid #cbd5e1;background:rgba(255,255,255,.9);' + 'cursor:pointer;font:500 12px/1 ui-sans-serif,system-ui';
            btn.addEventListener('click', (e)=>{
                e.stopPropagation();
                this.reloadApp(node);
            });
            wrap.appendChild(btn);
            slot.appendChild(wrap);
        }
        node.dataset.btSpilled = '1';
        node.remove();
        this.rendered.delete(idx);
        this.parked.delete(idx);
        this.applyVisibility(idx, node);
        const li = this.appLru.indexOf(idx);
        if (li !== -1) this.appLru.splice(li, 1);
    }
    reloadApp(node) {
        delete node.dataset.btSpilled;
        const id = node.dataset.msgId;
        const body = node.querySelector('.bt-tool-body');
        if (body) body.innerHTML = '<div class="bt-collapsable-loading">loading…</div>';
        if (id) this.comm.notify({
            type: 'tool.render',
            id
        });
    }
    insertSorted(idx, node) {
        const sorted = [
            ...this.rendered
        ].filter((i)=>i > idx).sort((a, b)=>a - b);
        const before = sorted.length ? this.cache.get(sorted[0]) : this.spacerBottom;
        this.container.insertBefore(node, before);
        if (node.dataset && node.dataset.btAutoExpand && !this.scrollbarDrag) {
            delete node.dataset.btAutoExpand;
            node.collapsable?.setExpanded(true);
        }
        if (node.dataset && node.dataset.btAutoMount && !this.scrollbarDrag) {
            delete node.dataset.btAutoMount;
            if (node.collapsable && !node.collapsable.loaded) {
                node.collapsable.loaded = true;
                this.comm.notify({
                    type: 'tool.render',
                    id: node.dataset.msgId
                });
            }
        }
    }
    appendNewMessage(msg) {
        const idx = this.totalCount - 1;
        if (!this.cache.has(idx)) {
            const node = this.createNode(msg);
            this.cache.set(idx, node);
            this.keyByIdx.set(idx, filterKey(msg));
            if (msg.id) this.nodeById.set(msg.id, node);
            this.observe(idx, node);
            if (this.lensActive) this.lensVisible.add(idx);
        }
        if (this.followMode) {
            this.scrollToBottom();
        } else {
            this.registerUnread();
        }
    }
    appendChunk(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        if (node.__btFinal) return;
        if (msg.html !== undefined) {
            this.applyStreamHtml(node, msg.html);
        } else if (msg.text !== undefined) {
            const t = node.querySelector('.bt-stream-text');
            if (t) t.textContent += msg.text;
        }
        if (this.followMode) {
            this.queueScrollToBottom();
        } else {
            this.registerUnread();
        }
    }
    appendUserChunk(text) {
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
    applyStreamHtml(node, html) {
        node.__btStreamHtml = html;
        if (node.__btStreamTimer != null) return;
        const flush = ()=>{
            node.__btStreamTimer = null;
            if (this.destroyed || node.__btFinal || node.__btStreamHtml == null) return;
            node.innerHTML = node.__btStreamHtml;
            node.__btStreamHtml = null;
            node.__btStreamTimer = setTimeout(flush, this.STREAM_APPLY_MS);
        };
        flush();
    }
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
            this.clearPendingStream(node);
            node.innerHTML = msg.html || '';
            linkifyPaths(node);
            decorateCodeBlocks(node);
            node.__btFinal = true;
            return;
        }
        let tgt = msg.id ? this.container.querySelector(`.bt-agent-msg[data-msg-id="${CSS.escape(msg.id)}"]`) : null;
        if (!tgt) {
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
    onThoughtFinal(msg) {
        const node = this.nodeById.get(msg.id);
        node && node.collapsable && node.collapsable.fill(msg.html || '');
    }
    onThoughtBody(msg) {
        const node = this.nodeById.get(msg.id);
        node && node.collapsable && node.collapsable.fill(msg.html);
    }
    onThinking(msg) {
        const active = msg.active;
        if (this.thinkingEl) this.thinkingEl.classList.toggle('bt-thinking-active', !!active);
        if (this.busyEl) this.busyEl.classList.toggle('bt-busy-suppressed', !!active);
        if (this.thinkingCountEl) this.thinkingCountEl.textContent = active && msg.count ? `${msg.count} token chunks` : '';
        if (active && this.followMode) this.queueScrollToBottom();
    }
    onPermission(msg) {
        if (!msg.key || !Array.isArray(msg.options)) return;
        if (this.container.querySelector(`.bt-permission-card[data-perm-key="${CSS.escape(msg.key)}"]`)) return;
        const card = document.createElement('div');
        card.className = 'bt-permission-card';
        card.dataset.permKey = msg.key;
        const q = document.createElement('div');
        q.className = 'bt-permission-question';
        q.textContent = msg.question || 'The agent is asking for permission';
        const row = document.createElement('div');
        row.className = 'bt-permission-options';
        for (const opt of msg.options){
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'bt-permission-btn' + (String(opt.kind || '').startsWith('allow') ? ' bt-perm-allow' : String(opt.kind || '').startsWith('reject') ? ' bt-perm-reject' : '');
            btn.textContent = opt.name || opt.optionId;
            btn.addEventListener('click', ()=>{
                if (card.classList.contains('bt-perm-answered')) return;
                card.classList.add('bt-perm-answered');
                btn.classList.add('bt-perm-chosen');
                row.querySelectorAll('button').forEach((b)=>b.disabled = true);
                this.comm.notify({
                    type: 'permission_answer',
                    key: msg.key,
                    optionId: opt.optionId
                });
            });
            row.appendChild(btn);
        }
        card.append(q, row);
        this.container.insertBefore(card, this.busyEl || null);
        if (this.followMode) this.queueScrollToBottom();
    }
    onPermissionDone(msg) {
        const card = this.container.querySelector(`.bt-permission-card[data-perm-key="${CSS.escape(msg.key || '')}"]`);
        if (!card) return;
        if (card.classList.contains('bt-perm-answered')) {
            setTimeout(()=>card.remove(), 1500);
        } else {
            card.remove();
        }
    }
    onQuestion(msg) {
        if (!msg.key || !Array.isArray(msg.fields)) return;
        if (this.container.querySelector(`.bt-permission-card[data-perm-key="${CSS.escape(msg.key)}"]`)) return;
        const card = document.createElement('div');
        card.className = 'bt-permission-card bt-question-card';
        card.dataset.permKey = msg.key;
        const q = document.createElement('div');
        q.className = 'bt-permission-question bt-question-prompt';
        const icon = document.createElement('span');
        icon.className = 'bt-question-icon';
        icon.textContent = '?';
        icon.setAttribute('aria-hidden', 'true');
        const qtext = document.createElement('span');
        qtext.textContent = msg.message || 'The agent has a question';
        q.appendChild(icon);
        q.appendChild(qtext);
        card.appendChild(q);
        const selects = msg.fields.filter((f)=>f.kind === 'select' || f.kind === 'multiselect');
        const texts = msg.fields.filter((f)=>f.kind === 'text');
        const instant = selects.length === 1 && selects[0].kind === 'select';
        const chosen = {};
        const submit = ()=>{
            if (card.classList.contains('bt-perm-answered')) return;
            card.classList.add('bt-perm-answered');
            const content = {};
            for (const [k, v] of Object.entries(chosen)){
                content[k] = v instanceof Set ? [
                    ...v
                ] : v;
            }
            for (const inp of card.querySelectorAll('input.bt-question-text')){
                if (inp.value.trim() !== '') content[inp.dataset.fieldKey] = inp.value;
            }
            card.querySelectorAll('button, input').forEach((el)=>el.disabled = true);
            this.comm.notify({
                type: 'question_answer',
                key: msg.key,
                content
            });
        };
        const skip = ()=>{
            if (card.classList.contains('bt-perm-answered')) return;
            card.classList.add('bt-perm-answered');
            card.querySelectorAll('button, input').forEach((el)=>el.disabled = true);
            this.comm.notify({
                type: 'question_skip',
                key: msg.key
            });
        };
        for (const f of selects){
            if ((f.title || f.description) && !instant) {
                const lbl = document.createElement('div');
                lbl.className = 'bt-question-field-label';
                lbl.textContent = f.title ? `${f.title}${f.description ? ' — ' + f.description : ''}` : f.description;
                card.appendChild(lbl);
            }
            const row = document.createElement('div');
            row.className = 'bt-permission-options';
            for (const opt of f.options || []){
                const btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'bt-permission-btn';
                btn.textContent = opt.label || opt.value;
                btn.addEventListener('click', ()=>{
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
                        row.querySelectorAll('button').forEach((b)=>b.classList.remove('bt-perm-chosen'));
                        btn.classList.add('bt-perm-chosen');
                        if (instant) submit();
                    }
                });
                row.appendChild(btn);
            }
            card.appendChild(row);
        }
        for (const f of texts){
            const inp = document.createElement('input');
            inp.type = 'text';
            inp.className = 'bt-question-text';
            inp.dataset.fieldKey = f.key;
            inp.placeholder = f.title || 'Other…';
            if (f.description) inp.title = f.description;
            inp.addEventListener('keydown', (e)=>{
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
    onSessionReset() {
        this.thinkingEl?.classList.remove('bt-thinking-active');
        this.busyEl?.classList.remove('bt-busy-active');
        this.busyEl?.classList.remove('bt-busy-suppressed');
        this.cancelPendingScroll();
        for (const node of this.nodeById.values()){
            node.classList?.remove('bt-stream-active');
        }
    }
    evalOutputConsole(node) {
        const secs = node.querySelectorAll('.bt-tool-body .bt-subsection');
        for (const d of secs){
            const label = d.querySelector('.bt-subsection-label');
            if (label && (label.textContent || '').trim() === 'Output') return d.querySelector('.bt-console');
        }
        return null;
    }
    onToolUpdate(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        if (msg.status) {
            const s = node.querySelector('.bt-tool-status');
            if (s) {
                s.textContent = msg.status;
                s.className = `bt-tool-status bt-status-${msg.status}`;
            }
            const live = !(msg.status === 'completed' || msg.status === 'failed');
            node.classList.toggle('bt-tool-live', live);
            if (live) this.ensureElapsedTicker();
            if (!live) {
                if (node.dataset.compactBody === '1' && node.collapsable && node.collapsable.loaded && node.isConnected) {
                    this.comm.notify({
                        type: 'tool.render',
                        id: msg.id
                    });
                }
            }
        }
        if (msg.finished_at != null) {
            node.dataset.toolFinished = String(msg.finished_at);
            node.classList.remove('bt-tool-live');
            _writeToolElapsed(node);
        }
        if (msg.title) {
            const t = node.querySelector('.bt-tool-title');
            if (t) t.textContent = msg.title;
        }
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
        if (msg.compact_body === true && node.collapsable && !node.collapsable.editMode) {
            const c = node.collapsable;
            c.editMode = true;
            c.hideBodyOnCollapse = true;
            c.fetchEachExpand = false;
            c.discardOnCollapse = false;
            node.dataset.compactBody = '1';
        }
        if (msg.show_mime) node.dataset.showMime = msg.show_mime;
        if (this.wantsNative(node)) {
            this.applyNative(node);
        } else if (msg.expand && node.collapsable) {
            if (node.collapsable.editMode) {
                if (node.isConnected) {
                    if (!node.collapsable.loaded) {
                        node.collapsable.loaded = true;
                        this.comm.notify({
                            type: 'tool.render',
                            id: msg.id
                        });
                    }
                    if (node.collapsable.hideBodyOnCollapse) node.collapsable.setExpanded(true);
                } else {
                    node.dataset.btAutoMount = '1';
                    if (node.collapsable.hideBodyOnCollapse) node.dataset.btAutoExpand = '1';
                }
            } else if (node.isConnected) {
                node.collapsable.setExpanded(true);
            } else {
                node.dataset.btAutoExpand = '1';
            }
        }
        if (msg.expand_full && node.collapsable) {
            if (node.isConnected) {
                if (!node.collapsable.loaded) {
                    node.collapsable.loaded = true;
                    this.comm.notify({
                        type: 'tool.render',
                        id: msg.id
                    });
                }
                node.collapsable.setExpanded(true);
            } else {
                node.dataset.btAutoExpand = '1';
            }
        }
        const headerEl = node.querySelector('.bt-tool-header');
        const stillLive = !node.dataset.toolFinished && ![
            'completed',
            'failed'
        ].includes(node.querySelector('.bt-tool-status')?.textContent || '');
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
            sb.addEventListener('click', (e)=>{
                e.stopPropagation();
                this.comm.notify({
                    type: 'stop_tool',
                    id: msg.id
                });
            });
            headerEl.insertBefore(sb, headerEl.querySelector('.bt-tool-fullwidth') || null);
        }
        if (msg.live_embed) {
            node.dataset.btApp = '1';
            if (headerEl && !headerEl.querySelector('.bt-tool-detach')) {
                const db = document.createElement('button');
                db.type = 'button';
                db.className = 'bt-tool-detach';
                db.title = 'Detach to floating window';
                db.textContent = '⤢';
                db.addEventListener('click', (e)=>{
                    e.stopPropagation();
                    this.comm.notify({
                        type: 'detach_app',
                        id: msg.id
                    });
                });
                headerEl.insertBefore(db, headerEl.querySelector('.bt-tool-fullwidth') || null);
            }
        }
        if (msg.stream_tail != null && stillLive && headerEl) {
            const con = this.evalOutputConsole(node);
            if (con) {
                for (const stray of node.querySelectorAll('.bt-eval-stream'))stray.remove();
                con.textContent = msg.stream_tail;
                const scroller = con.closest('.bt-subsection-body');
                if (scroller) scroller.scrollTop = scroller.scrollHeight;
            } else {
                let sp = node.querySelector('.bt-eval-stream');
                if (!sp) {
                    sp = document.createElement('pre');
                    sp.className = 'bt-eval-stream';
                    headerEl.insertAdjacentElement('afterend', sp);
                }
                sp.textContent = msg.stream_tail;
                sp.scrollTop = sp.scrollHeight;
            }
        }
        if (msg.editable && msg.edit_path && headerEl) {
            const t = headerEl.querySelector('.bt-tool-title');
            if (t) {
                t.classList.add('bt-path-link');
                t.dataset.path = msg.edit_path;
            }
        }
    }
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
        node.querySelector('.bt-tool-header')?.insertAdjacentElement('afterend', feed) || node.appendChild(feed);
        const list = feed.querySelector('.bt-task-feed-list');
        feed._collapsable = new Collapsable(feed.querySelector('.bt-task-feed-head'), list, {
            toggleEl: feed.querySelector('.bt-task-feed-head .bt-tool-toggle')
        });
        if (node.classList.contains('bt-tool-live')) {
            feed._collapsable.setExpanded(true);
        } else {
            list.style.display = 'none';
        }
        return feed;
    }
    upsertTaskFeedEntry(feed, e, total) {
        const list = feed.querySelector('.bt-task-feed-list');
        let row = e.eid != null ? list.querySelector(`[data-eid="${CSS.escape(String(e.eid))}"]`) : null;
        if (!row) {
            row = document.createElement('div');
            row.dataset.eid = String(e.eid ?? '');
            list.appendChild(row);
            while(list.children.length > 300)list.removeChild(list.firstChild);
        }
        row.className = `bt-task-feed-entry bt-task-feed-${e.kind || 'text'}` + (e.status ? ` bt-feed-${e.status}` : '');
        row.textContent = e.kind === 'tool' ? `⚙ ${e.label || ''}` : e.label || '';
        if (e.kind === 'tool' && e.status) row.title = e.status;
        const count = feed.querySelector('.bt-task-feed-count');
        if (count) {
            const n = Number.isFinite(total) ? total : list.children.length;
            feed.dataset.total = String(Math.max(n, Number(feed.dataset.total || 0)));
            count.textContent = feed.dataset.total;
        }
        if (feed._collapsable?.expanded) list.scrollTop = list.scrollHeight;
    }
    noteKey(msg) {
        const key = filterKey(msg);
        if (!key || this.seenTypes.has(key)) return;
        this.seenTypes.add(key);
        if (key === 'agent') this.updateWaiting();
    }
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
            node.dataset.btAutoExpand = '1';
        }
    }
    removeNative(node) {
        node.classList.remove('bt-tool-native');
        delete node.dataset.btAutoExpand;
        node.collapsable?.setExpanded(false);
    }
    setNativeMedia(prefix, on) {
        if (prefix === 'image/') this.nativeImages = on;
        else this.nativeVideos = on;
        for (const node of this.cache.values()){
            if (!(node.dataset.showMime || '').startsWith(prefix)) continue;
            on ? this.applyNative(node) : this.removeNative(node);
        }
        this.refresh();
    }
    setKeyHidden(key, hidden) {
        const anchor = this.followMode ? null : this.captureKeyAnchor(key);
        this.hiddenTypes[hidden ? 'add' : 'delete'](key);
        for (const [idx, node] of this.cache){
            if (node.dataset.filterKey === key) this.applyVisibility(idx, node);
        }
        if (key === 'agent') this.updateWaiting();
        if (anchor) {
            this.keyAnchor = {
                ...anchor,
                setAt: performance.now(),
                until: performance.now() + 1500
            };
        }
        this.refresh();
        if (this.followMode) this.queueScrollToBottom();
        else if (anchor) this.restoreKeyAnchor(anchor);
    }
    updateWaiting() {
        if (!this.waitingEl) return;
        const on = this.seenTypes.has('agent') && !this.hiddenTypes.has('agent');
        this.waitingEl.classList.toggle('bt-waiting-on', on);
    }
    createNode(msg) {
        const div = document.createElement('div');
        const fkey = filterKey(msg);
        div.dataset.filterKey = fkey;
        this.noteKey(msg);
        switch(msg.type){
            case 'user':
                div.className = 'bt-user-msg';
                if (msg.queued) {
                    div.classList.add('bt-queued');
                    div.dataset.queueLabel = queueLabel(msg.queue_pos);
                }
                if (msg.auto) div.classList.add('bt-user-msg-auto');
                div.textContent = msg.text;
                if (Array.isArray(msg.attachments) && msg.attachments.length) {
                    const gallery = document.createElement('div');
                    gallery.className = 'bt-user-attachments';
                    for (const a of msg.attachments){
                        const img = document.createElement('img');
                        img.className = 'bt-user-att-img';
                        img.src = a.url;
                        img.alt = a.name || 'attachment';
                        img.loading = 'lazy';
                        img.addEventListener('click', ()=>openLightbox(img));
                        img.addEventListener('error', ()=>{
                            const miss = document.createElement('span');
                            miss.className = 'bt-user-att-missing';
                            miss.textContent = a.name || 'attachment';
                            img.replaceWith(miss);
                        }, {
                            once: true
                        });
                        gallery.appendChild(img);
                    }
                    div.appendChild(gallery);
                }
                break;
            case 'agent':
                div.className = 'bt-agent-msg';
                if (msg.id) div.dataset.msgId = msg.id;
                if (msg.streaming) {
                    const span = document.createElement('span');
                    span.className = 'bt-stream-text';
                    if (msg.text) span.textContent = msg.text;
                    div.appendChild(span);
                } else {
                    div.innerHTML = msg.html || '';
                    linkifyPaths(div);
                    decorateCodeBlocks(div);
                }
                break;
            case 'thought':
                {
                    div.className = 'bt-thought-msg';
                    div.innerHTML = this.thoughtHTML(msg);
                    const id = msg.id;
                    div.collapsable = new Collapsable(div.querySelector('.bt-thought-summary'), div.querySelector('.bt-thought-body'), {
                        native: true,
                        onExpand: ()=>this.comm.notify({
                                type: 'thought.render',
                                id
                            })
                    });
                    if (msg.html) div.collapsable.fill(msg.html);
                    break;
                }
            case 'tool':
                {
                    div.className = 'bt-tool-msg';
                    div.innerHTML = this.toolHTML(msg);
                    if (msg.kind === 'bonito_app' || msg.live_embed) div.dataset.btApp = '1';
                    if (msg.id) div.dataset.msgId = msg.id;
                    if (msg.started_at != null) div.dataset.toolStarted = String(msg.started_at);
                    if (msg.finished_at != null) div.dataset.toolFinished = String(msg.finished_at);
                    _writeToolElapsed(div);
                    const liveTool = !(msg.status === 'completed' || msg.status === 'failed') && msg.finished_at == null;
                    if (liveTool) {
                        div.classList.add('bt-tool-live');
                        this.ensureElapsedTicker();
                    }
                    const id = msg.id;
                    const compactBody = msg.kind === 'edit' || msg.compact_body === true;
                    if (msg.compact_body === true) div.dataset.compactBody = '1';
                    div.collapsable = new Collapsable(div.querySelector('.bt-tool-header'), div.querySelector('.bt-tool-body'), {
                        toggleEl: div.querySelector('.bt-tool-toggle'),
                        editMode: compactBody,
                        hideBodyOnCollapse: msg.compact_body === true,
                        fetchEachExpand: !compactBody,
                        discardOnCollapse: !compactBody,
                        onExpand: ()=>this.comm.notify({
                                type: 'tool.render',
                                id
                            })
                    });
                    if (Array.isArray(msg.task_feed) && msg.task_feed.length) {
                        const feed = this.ensureTaskFeed(div);
                        for (const e of msg.task_feed)this.upsertTaskFeedEntry(feed, e, msg.task_feed_total);
                    }
                    const detachBtn = div.querySelector('.bt-tool-detach');
                    if (detachBtn) detachBtn.addEventListener('click', (e)=>{
                        e.stopPropagation();
                        this.comm.notify({
                            type: 'detach_app',
                            id
                        });
                    });
                    const wideBtn = div.querySelector('.bt-tool-fullwidth');
                    if (wideBtn) wideBtn.addEventListener('click', (e)=>{
                        e.stopPropagation();
                        const active = div.classList.toggle('bt-tool-wide-active');
                        wideBtn.textContent = active ? '«' : '»';
                        wideBtn.title = active ? 'Collapse to default width' : 'Expand to full chat width';
                    });
                    const stopBtn2 = div.querySelector('.bt-tool-stop');
                    if (stopBtn2) stopBtn2.addEventListener('click', (e)=>{
                        e.stopPropagation();
                        this.comm.notify({
                            type: 'stop_tool',
                            id
                        });
                    });
                    if (msg.show_mime) div.dataset.showMime = msg.show_mime;
                    if (this.wantsNative(div)) {
                        div.classList.add('bt-tool-native');
                        div.dataset.btAutoExpand = '1';
                    } else if (msg.expand || msg.expand_full) {
                        if (div.collapsable.editMode) {
                            div.dataset.btAutoMount = '1';
                            if (msg.expand_full || div.collapsable.hideBodyOnCollapse) div.dataset.btAutoExpand = '1';
                        } else {
                            div.dataset.btAutoExpand = '1';
                        }
                    }
                    break;
                }
            case 'plan':
                {
                    div.className = 'bt-plan-msg';
                    div.innerHTML = msg.html || '';
                    if (msg.id) div.dataset.msgId = msg.id;
                    if (msg.started_at != null) div.dataset.planStarted = String(msg.started_at);
                    if (msg.finished_at != null) div.dataset.planFinished = String(msg.finished_at);
                    if (msg.summary) div.dataset.planSummary = msg.summary;
                    if (msg.live) div.classList.add('bt-plan-live');
                    break;
                }
            case 'summary':
                {
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
        if (this.hiddenTypes.has(fkey)) div.style.display = 'none';
        return div;
    }
    unqueueUser(msg) {
        if (Number.isInteger(msg.idx)) {
            const node = this.cache.get(msg.idx);
            if (node) {
                node.classList.remove('bt-queued');
                return;
            }
            return;
        }
        const q = this.container.querySelector('.bt-user-msg.bt-queued');
        if (q) q.classList.remove('bt-queued');
    }
    requeueUser(msg) {
        for (const it of msg.items || []){
            const node = this.cache.get(it.idx);
            if (node) node.dataset.queueLabel = it.label || queueLabel(it.pos);
        }
    }
    onSummaryFinal(msg) {
        const node = msg.id ? this.nodeById.get(msg.id) : null;
        if (node) {
            const body = node.querySelector('.bt-summary-body');
            if (body) {
                body.innerHTML = msg.html || '';
                return;
            }
        }
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
        const server = msg.server ? `<span class="bt-tool-server">${escapeHTML(msg.server)}</span>` : '';
        const timeoutBadge = msg.timeout_s ? `<span class="bt-tool-timeout" title="Soft eval timeout — the call checkpoints with partial output at this cadence">⏱ ${escapeHTML(String(msg.timeout_s))}</span>` : '';
        const stopBtn = msg.stoppable ? `<button class="bt-tool-stop bt-stop-mini" type="button"
                     title="Stop"></button>` : '';
        const titleLink = msg.edit_path ? ` bt-path-link" data-path="${escapeAttr(msg.edit_path)}` : '';
        !(msg.status === 'completed' || msg.status === 'failed') && msg.finished_at == null;
        const cmdPreview = msg.command ? `
            <div class="bt-cmd-preview"><pre>${escapeHTML(msg.command)}</pre></div>` : '';
        return `
            <div class="bt-tool-header" data-expanded="false"${msg.command ? ` title="${escapeAttr(msg.command)}"` : ''}>
                <span class="bt-tool-toggle">▶</span>
                <span class="bt-tool-kind">${msg.icon || '⚙'}</span>
                ${server}
                <span class="bt-tool-title${titleLink}">${escapeHTML(msg.title || '')}</span>
                <span class="bt-tool-summary">${escapeHTML(msg.summary || '')}</span>
                ${timeoutBadge}
                <span class="bt-tool-timer"></span>
                <span class="${statusCls}">${escapeHTML(msg.status || '')}</span>
                ${stopBtn}
                ${msg.kind === 'bonito_app' || msg.live_embed ? `<button class="bt-tool-detach" type="button"
                              title="Detach to floating window">⤢</button>` : ''}
                <button class="bt-tool-fullwidth" type="button"
                        title="Expand to full chat width">»</button>
            </div>
            ${cmdPreview}
            <div class="bt-tool-body" data-tool-id="${escapeAttr(msg.id || '')}"></div>`;
    }
    onPlanUpdate(msg) {
        const node = this.nodeById.get(msg.id);
        if (!node) return;
        if (msg.html != null) node.innerHTML = msg.html;
        if (msg.started_at != null) node.dataset.planStarted = String(msg.started_at);
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
        this.taskbarEl = (this.app || this.container.closest('.bt-app') || this.container.parentElement).querySelector('.bt-taskbar');
        if (this.taskbarEl) {
            const storedTodo = localStorage.getItem('bt-todo-collapsed');
            const paneW = this.container.closest('.bt-chatpane')?.clientWidth ?? window.innerWidth;
            this.taskbarEl.classList.toggle('bt-todo-collapsed', storedTodo != null ? storedTodo === '1' : paneW < 660);
            this.onTaskbarClick = (ev)=>{
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
                const jump = ()=>{
                    this.container.scrollTop = Math.max(0, this.cumHeight(0, idx) - 60);
                };
                this.followMode = false;
                jump();
                requestAnimationFrame(()=>requestAnimationFrame(jump));
            };
            this.taskbarEl.addEventListener('click', this.onTaskbarClick);
        }
    }
    ensureElapsedTicker() {
        if (this.elapsedTimer) return;
        this.elapsedTimer = setInterval(()=>{
            let any = false;
            for (const node of this.nodeById.values()){
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
    setupLens() {
        const host = (this.app || this.container.closest('.bt-app') || this.container.parentElement).querySelector('.bt-lens-bar');
        if (!host) return;
        this.lensBarEl = host;
        this.lensClauses = [];
        this.lensPendingSign = '+';
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
        this.lensAC = host.querySelector('.bt-lens-autocomplete');
        this.lensPills = host.querySelector('.bt-lens-pills');
        this.lensChips = host.querySelector('.bt-lens-chips');
        const go = host.querySelector('.bt-lens-go');
        const save = host.querySelector('.bt-lens-save');
        const clear = host.querySelector('.bt-lens-clear');
        this.lensClearBtn = clear;
        const apply = ()=>{
            this.lensCommitTail();
            this.hideLensAutocomplete();
            this.runLens(this.lensSerialize());
        };
        go.addEventListener('click', apply);
        save.addEventListener('click', ()=>{
            this.lensCommitTail();
            const q = this.lensSerialize();
            if (q) this.comm.notify({
                type: 'lens.save',
                q
            });
        });
        clear.addEventListener('click', ()=>this.lensClearAll());
        this.lensInput.addEventListener('input', ()=>{
            this.lensAutoCommitOnOperator();
            this.updateLensAutocomplete();
        });
        this.lensInput.addEventListener('keydown', (e)=>{
            if (e.key === 'Enter') {
                e.preventDefault();
                if (!this.acceptLensAutocomplete()) apply();
            } else if (e.key === 'Escape') this.hideLensAutocomplete();
            else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') this.moveLensAutocomplete(e.key === 'ArrowDown' ? 1 : -1, e);
            else if (e.key === 'Backspace' && this.lensInput.value === '' && this.lensClauses.length) {
                e.preventDefault();
                this.lensPopPill();
            }
        });
        this.onLensDocClick = (e)=>{
            if (!this.container.isConnected) {
                this.lazyDestroy();
                return;
            }
            if (!host.contains(e.target)) this.hideLensAutocomplete();
        };
        document.addEventListener('click', this.onLensDocClick);
        this.renderLensPills();
        this.renderSavedLenses();
    }
    lensClauseParts(text) {
        text = (text || '').trim();
        let sign = '+';
        if (text.startsWith('!') || text.startsWith('-')) {
            sign = '-';
            text = text.slice(1).trim();
        }
        let key = '', rest = text;
        if (text.startsWith('/')) {
            const m = text.slice(1).match(/^([\w.@*-]+)\s*:?\s*(.*)$/);
            if (m) {
                key = m[1];
                rest = m[2];
            } else {
                rest = text.slice(1);
            }
        }
        let action = null;
        const qparts = [];
        const re = /"([^"]*)"|(\S+)/g;
        let mm;
        while(mm = re.exec(rest)){
            if (mm[1] !== undefined) qparts.push(mm[1]);
            else if (mm[2] === 'expand' || mm[2] === 'collapse') action = mm[2];
            else qparts.push(mm[2]);
        }
        return {
            sign,
            key,
            action,
            query: qparts.join(' ')
        };
    }
    lensSerialize() {
        return this.lensClauses.map((c, i)=>i === 0 ? c.sign === '-' ? '!' + c.text.replace(/^[!-]\s*/, '') : c.text : c.sign === '-' ? '- ' + c.text.replace(/^[!-]\s*/, '') : '+ ' + c.text).join(' ').trim();
    }
    lensSplit(str) {
        const segs = [];
        let buf = '', inq = false, sign = '+';
        for(let i = 0; i < str.length; i++){
            const c = str[i];
            if (c === '"') {
                inq = !inq;
                buf += c;
            } else if (!inq && (c === '+' || c === '-') && i > 0 && /\s/.test(str[i - 1]) && i < str.length - 1 && /\s/.test(str[i + 1])) {
                segs.push({
                    sign,
                    text: buf.trim()
                });
                sign = c === '-' ? '-' : '+';
                buf = '';
            } else buf += c;
        }
        segs.push({
            sign,
            text: buf.trim()
        });
        return segs.filter((s)=>s.text !== '');
    }
    lensCommitTail() {
        const t = this.lensInput.value.trim();
        if (t) this.lensClauses.push({
            sign: this.lensPendingSign,
            text: t
        });
        this.lensInput.value = '';
        this.lensPendingSign = '+';
        this.renderLensPills();
    }
    lensAutoCommitOnOperator() {
        const v = this.lensInput.value;
        const m = v.match(/^(.*\S)\s+([+-])\s$/);
        if (!m) return;
        if ((v.match(/"/g) || []).length % 2 !== 0) return;
        this.lensClauses.push({
            sign: this.lensPendingSign,
            text: m[1].trim()
        });
        this.lensPendingSign = m[2] === '-' ? '-' : '+';
        this.lensInput.value = '';
        this.renderLensPills();
    }
    lensClearAll() {
        this.lensClauses = [];
        this.lensPendingSign = '+';
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
        this.lensCommitTail();
        const c = this.lensClauses.splice(i, 1)[0];
        this.lensInput.value = c.text;
        this.lensPendingSign = c.sign;
        this.renderLensPills();
        this.lensInput.focus();
        const n = this.lensInput.value.length;
        this.lensInput.setSelectionRange(n, n);
        this.updateLensAutocomplete();
    }
    lensPopPill() {
        const c = this.lensClauses.pop();
        if (!c) return;
        this.lensInput.value = c.text;
        this.lensPendingSign = c.sign;
        this.renderLensPills();
        const n = this.lensInput.value.length;
        this.lensInput.setSelectionRange(n, n);
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
        this.lensClauses.forEach((c, i)=>{
            const p = this.lensClauseParts(c.text);
            const sign = c.sign === '-' || p.sign === '-' ? '-' : '+';
            const pill = document.createElement('span');
            pill.className = 'bt-lens-pill' + (sign === '-' ? ' bt-lens-pill-ex' : '');
            let html = sign === '-' ? `<span class="bt-lens-pill-sign">−</span>` : '';
            html += `<span class="bt-lens-pill-key">${escapeHTML(p.key || 'text')}</span>`;
            if (p.query) html += `<span class="bt-lens-pill-q">“${escapeHTML(p.query)}”</span>`;
            if (p.action) html += `<span class="bt-lens-pill-act">${escapeHTML(p.action)}</span>`;
            html += `<span class="bt-lens-pill-x" title="Remove">✕</span>`;
            pill.innerHTML = html;
            pill.querySelector('.bt-lens-pill-x').addEventListener('mousedown', (e)=>{
                e.preventDefault();
                e.stopPropagation();
                this.lensRemovePill(i);
            });
            pill.addEventListener('mousedown', (e)=>{
                if (e.target.classList.contains('bt-lens-pill-x')) return;
                e.preventDefault();
                this.lensEditPill(i);
            });
            this.lensPills.appendChild(pill);
        });
        this.lensBarEl?.classList.toggle('bt-lens-pending-ex', this.lensPendingSign === '-');
    }
    currentLensToken() {
        const v = this.lensInput.value;
        const caret = this.lensInput.selectionStart ?? v.length;
        const head = v.slice(0, caret);
        const slash = head.lastIndexOf('/');
        if (slash < 0) return null;
        const frag = head.slice(slash + 1);
        if (/[\s:"]/.test(frag)) return null;
        return {
            start: slash + 1,
            end: caret,
            frag
        };
    }
    updateLensAutocomplete() {
        const tok = this.currentLensToken();
        if (tok) {
            const f = tok.frag.toLowerCase();
            const matches = this.lensVocab.filter((k)=>_subseqMatch(f, k)).slice(0, 8);
            if (!matches.length) return this.hideLensAutocomplete();
            this.renderLensAC(matches.map((k)=>({
                    kind: 'key',
                    val: k,
                    label: '/' + k
                })), true);
            return;
        }
        if (this.lensInput.value.trim() !== '') {
            const p = this.lensClauseParts(this.lensInput.value);
            const items = [];
            if (p.key) {
                for (const a of [
                    'expand',
                    'collapse'
                ])if (p.action !== a) items.push({
                    kind: 'action',
                    val: a,
                    label: a,
                    hint: `${a} matches`
                });
            }
            items.push({
                kind: 'op',
                val: '+',
                label: '＋ add',
                hint: 'include another clause'
            });
            items.push({
                kind: 'op',
                val: '-',
                label: '− exclude',
                hint: 'hide the next clause'
            });
            this.renderLensAC(items, false);
            return;
        }
        this.hideLensAutocomplete();
    }
    renderLensAC(items, selectFirst) {
        if (!items.length) return this.hideLensAutocomplete();
        this.lensAC.innerHTML = items.map((it, i)=>`<div class="bt-lens-ac-item${selectFirst && i === 0 ? ' bt-ac-sel' : ''}" ` + `data-kind="${it.kind}" data-val="${escapeAttr(it.val)}">` + `<span class="bt-lens-ac-label">${escapeHTML(it.label)}</span>` + (it.hint ? `<span class="bt-lens-ac-hint">${escapeHTML(it.hint)}</span>` : '') + `</div>`).join('');
        this.lensAC.hidden = false;
        for (const el of this.lensAC.querySelectorAll('.bt-lens-ac-item')){
            el.addEventListener('mousedown', (e)=>{
                e.preventDefault();
                this.applyLensAC(el.dataset.kind, el.dataset.val);
            });
        }
    }
    hideLensAutocomplete() {
        if (this.lensAC) {
            this.lensAC.hidden = true;
            this.lensAC.innerHTML = '';
        }
    }
    moveLensAutocomplete(dir, e) {
        if (this.lensAC.hidden) return;
        e.preventDefault();
        const items = [
            ...this.lensAC.querySelectorAll('.bt-lens-ac-item')
        ];
        if (!items.length) return;
        let i = items.findIndex((el)=>el.classList.contains('bt-ac-sel'));
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
        if (kind === 'op') {
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
    runLens(query) {
        this.lensQuery = query;
        this.comm.notify({
            type: 'lens.query',
            q: query
        });
    }
    onLensResult(msg) {
        if (msg.q !== this.lensQuery) return;
        const holdAnchor = this.lensActive && !msg.active && !this.followMode ? this.captureAnchor() : null;
        if (!msg.active) {
            this.lensActive = false;
            this.lensVisible = null;
            this.lensActions = null;
        } else {
            this.lensActive = true;
            this.lensVisible = new Set(msg.visible || []);
            this.lensActions = new Map(Object.entries(msg.actions || {}).map(([k, v])=>[
                    +k,
                    v
                ]));
        }
        if (this.lensClearBtn) this.lensClearBtn.hidden = !this.lensActive;
        this.lensBarEl?.classList.toggle('bt-lens-on', this.lensActive);
        for (const [idx, node] of this.cache){
            if (this.rendered.has(idx)) this.applyVisibility(idx, node);
        }
        this.refresh();
        if (this.lensActions) {
            for (const [idx, action] of this.lensActions){
                const node = this.cache.get(idx);
                if (!node) continue;
                if (action === 'expand') node.collapsable?.setExpanded(true);
                else if (action === 'collapse') node.collapsable?.setExpanded(false);
            }
        }
        if (this.lensActive) {
            this.followMode = false;
            this.container.scrollTop = 0;
            this.prevScrollTop = 0;
            this.refresh();
        } else if (holdAnchor) this.restoreAnchor(holdAnchor);
    }
    onLensSaved(msg) {
        this.savedLenses = msg.lenses || [];
        this.renderSavedLenses();
    }
    renderSavedLenses() {
        if (!this.lensChips) return;
        this.lensChips.innerHTML = '';
        for (const l of this.savedLenses){
            const chip = document.createElement('span');
            chip.className = 'bt-lens-chip';
            chip.style.setProperty('--chip', l.color);
            chip.title = l.query;
            chip.innerHTML = `<span class="bt-lens-chip-label"></span><span class="bt-lens-chip-x" title="Remove">✕</span>`;
            chip.querySelector('.bt-lens-chip-label').textContent = l.title;
            chip.querySelector('.bt-lens-chip-label').addEventListener('click', ()=>{
                this.lensLoadQuery(l.query);
            });
            chip.querySelector('.bt-lens-chip-x').addEventListener('click', (e)=>{
                e.stopPropagation();
                this.comm.notify({
                    type: 'lens.delete',
                    q: l.query
                });
            });
            this.lensChips.appendChild(chip);
        }
    }
    sizeTail() {
        if (!this.tailEl) return;
        this.tailEl.style.height = '50px';
    }
    atBottom() {
        const { scrollTop , scrollHeight , clientHeight  } = this.container;
        return scrollHeight - scrollTop - clientHeight < this.AT_BOTTOM_PX;
    }
    lastMessageFullyOutOfView() {
        if (this.totalCount === 0) return false;
        const node = this.cache.get(this.totalCount - 1);
        if (!node || !node.isConnected || node.offsetParent === null) return true;
        return node.getBoundingClientRect().top >= this.container.getBoundingClientRect().bottom;
    }
    queueScrollToBottom() {
        if (this.scrollbarDrag) return;
        if (this.scrollQueued || this.destroyed) return;
        this.scrollQueued = true;
        this.scrollRafId = requestAnimationFrame(()=>{
            this.scrollQueued = false;
            this.scrollRafId = null;
            if (this.destroyed) return;
            if (performance.now() - this.lastUserInputT < 100) {
                if (this.followMode) this.queueScrollToBottom();
                return;
            }
            this.scrollToBottom();
        });
    }
    setupMoveObserver() {
        const root = this.container.closest('.bw-ws') || document.body;
        this.moveObserver = new MutationObserver((records)=>{
            if (this.destroyed || !this.container.isConnected) return;
            for (const r of records){
                if (this.container.contains(r.target)) continue;
                for (const n of r.addedNodes){
                    if (n !== this.container && !(n.nodeType === 1 && n.contains(this.container))) continue;
                    this.restoreAfterMove();
                    return;
                }
            }
        });
        this.moveObserver.observe(root, {
            childList: true,
            subtree: true
        });
    }
    restoreAfterMove() {
        if (this.container.clientHeight === 0) return;
        if (this.container.scrollTop > 1) return;
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
        if (this.scrollbarDrag) return;
        this.container.scrollTop = this.container.scrollHeight;
        const anchor = this.tailEl || this.spacerBottom;
        if (anchor) {
            anchor.scrollIntoView({
                block: 'end',
                behavior: 'auto'
            });
        }
        this.prevScrollTop = this.container.scrollTop;
        this.refresh();
    }
    onHidden() {
        if (this.cancelMomentum) this.cancelMomentum();
        this.cancelPendingScroll();
        if (this.setOverscroll) this.setOverscroll(0);
        this.savedScrollTop = this.container.scrollTop;
        this.savedFollowMode = this.followMode;
        this.savedAnchor = this.captureAnchor();
        this.prefetchPaused = true;
        clearTimeout(this.prefetchTimer);
    }
    onShown() {
        const followNow = !!this.followMode;
        const followThen = !!this.savedFollowMode;
        const wantBottom = followNow || followThen;
        const savedTop = this.savedScrollTop;
        const anchor = this.savedAnchor;
        this.prefetchPaused = false;
        if (this.prefetchStarted) {
            clearTimeout(this.prefetchTimer);
            this.prefetchTimer = setTimeout(()=>this.prefetchTick(), 600);
        }
        const apply = ()=>{
            if (this.destroyed) return;
            if (wantBottom) {
                if (this.followMode) this.scrollToBottom();
                return;
            }
            const n = anchor && this.rendered.has(anchor.idx) ? this.cache.get(anchor.idx) : null;
            if (n && n.isConnected) {
                this.container.scrollTop = n.offsetTop - anchor.off;
            } else if (savedTop != null) {
                this.container.scrollTop = savedTop;
            }
            this.prevScrollTop = this.container.scrollTop;
        };
        apply();
        requestAnimationFrame(apply);
        setTimeout(apply, 50);
        setTimeout(apply, 200);
    }
    setupInputs() {
        if (this.destroyed) return;
        const app = this.container?.closest('.bt-app') || this.container?.parentElement;
        if (!app) return;
        this.app = app;
        this.inputArea = app.querySelector('.bt-input-area');
        this.textInput = app.querySelector('.bt-text-input');
        if (!this.inputArea || !this.textInput) return;
        this.attachBar = document.createElement('div');
        this.attachBar.className = 'bt-attachments';
        this.inputArea.insertBefore(this.attachBar, this.inputArea.firstChild);
        this.attachments = new Map();
        this.attachIdCounter = 0;
        this.ATTACH_MAX_BYTES = 5 * 1024 * 1024;
        this.onPaste = (e)=>{
            const items = e.clipboardData?.items;
            if (!items) return;
            for (const it of items){
                if (it.kind === 'file' && it.type && it.type.startsWith('image/')) {
                    const blob = it.getAsFile();
                    if (blob) this.attachAddBlob(blob, blob.type || it.type, blob.name || `pasted-${Date.now()}.png`);
                }
            }
        };
        this.textInput.addEventListener('paste', this.onPaste);
        this.onDragOver = (e)=>{
            if (!this.dragHasImage(e)) return;
            e.preventDefault();
            this.app.classList.add('bt-drag-over');
        };
        this.onDragLeave = (e)=>{
            if (e.relatedTarget && this.app.contains(e.relatedTarget)) return;
            this.app.classList.remove('bt-drag-over');
        };
        this.onDrop = (e)=>{
            e.preventDefault();
            this.app.classList.remove('bt-drag-over');
            const files = e.dataTransfer?.files;
            if (!files) return;
            for (const f of files){
                if (f.type && f.type.startsWith('image/')) {
                    this.attachAddBlob(f, f.type, f.name || `dropped-${Date.now()}.png`);
                }
            }
        };
        this.app.addEventListener('dragover', this.onDragOver);
        this.app.addEventListener('dragleave', this.onDragLeave);
        this.app.addEventListener('drop', this.onDrop);
        this.onAppClickCapture = (e)=>{
            if (this.destroyed) return;
            if (e.target.closest('.bt-send-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this.submit();
            } else if (e.target.closest('.bt-stop-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this.cancel();
            }
        };
        this.app.addEventListener('click', this.onAppClickCapture, true);
        this.onTextInputKeyCapture = (e)=>{
            if (this.cmdAcHandleKey(e)) return;
            if (e.key !== 'Enter' || e.shiftKey) return;
            e.preventDefault();
            e.stopImmediatePropagation();
            this.submit();
        };
        this.textInput.addEventListener('keydown', this.onTextInputKeyCapture, true);
        this.cmdAc = document.createElement('div');
        this.cmdAc.className = 'bt-cmd-ac';
        this.inputArea.appendChild(this.cmdAc);
        this.cmdAcItems = [];
        this.cmdAcSel = 0;
        const acClose = ()=>{
            this.cmdAcItems = [];
            this.cmdAc.classList.remove('bt-cmd-ac-open');
        };
        this.cmdAcClose = acClose;
        const acAccept = (cmd)=>{
            this.textInput.value = '/' + cmd.name + ' ';
            this.textInput.focus();
            acClose();
        };
        const acRender = ()=>{
            this.cmdAc.innerHTML = '';
            this.cmdAcItems.forEach((cmd, i)=>{
                const row = document.createElement('div');
                row.className = 'bt-cmd-ac-item' + (i === this.cmdAcSel ? ' bt-cmd-ac-sel' : '');
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
                row.addEventListener('mousedown', (e)=>{
                    e.preventDefault();
                    acAccept(cmd);
                });
                this.cmdAc.appendChild(row);
            });
            this.cmdAc.classList.toggle('bt-cmd-ac-open', this.cmdAcItems.length > 0);
        };
        this.cmdAcHandleKey = (e)=>{
            if (!this.cmdAcItems.length) return false;
            if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
                const d = e.key === 'ArrowDown' ? 1 : -1;
                this.cmdAcSel = (this.cmdAcSel + d + this.cmdAcItems.length) % this.cmdAcItems.length;
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
        this.onCmdInput = ()=>{
            const m = (this.textInput.value || '').match(/^\/([\w:-]*)$/);
            const cmds = this.slashCommands || [];
            if (!m || !cmds.length) {
                acClose();
                return;
            }
            const q = m[1].toLowerCase();
            const starts = cmds.filter((c)=>c.name.toLowerCase().startsWith(q));
            const incl = cmds.filter((c)=>!c.name.toLowerCase().startsWith(q) && c.name.toLowerCase().includes(q));
            this.cmdAcItems = starts.concat(incl).slice(0, 8);
            this.cmdAcSel = 0;
            acRender();
        };
        this.onCmdBlur = ()=>acClose();
        this.textInput.addEventListener('input', this.onCmdInput);
        this.textInput.addEventListener('blur', this.onCmdBlur);
        this.onEscapeKey = (e)=>{
            if (e.key !== 'Escape' || e.repeat) return;
            if (!this.container.isConnected) {
                this.lazyDestroy();
                return;
            }
            if (this.container.offsetParent === null) return;
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
    cancel() {
        this.comm.notify({
            type: 'cancel',
            seq: this.turnSeq ?? -1
        });
    }
    dragHasImage(e) {
        const dt = e.dataTransfer;
        if (!dt) return false;
        if (dt.types) {
            for (const t of dt.types)if (t === 'Files') return true;
        }
        return false;
    }
    attachAddBlob(blob, mime, filename) {
        if (blob.size > this.ATTACH_MAX_BYTES) {
            this.showAttachError(`Image too large (${(blob.size / 1024 / 1024).toFixed(1)} MB, ` + `max ${this.ATTACH_MAX_BYTES / 1024 / 1024} MB)`);
            return;
        }
        const id = `att-${++this.attachIdCounter}`;
        const reader = new FileReader();
        reader.onload = ()=>{
            if (this.destroyed) return;
            this.attachments.set(id, {
                blob,
                mime,
                filename,
                dataUrl: reader.result
            });
            this.renderAttachments();
        };
        reader.onerror = ()=>this.showAttachError('Failed to read image');
        reader.readAsDataURL(blob);
    }
    attachRemove(id) {
        this.attachments.delete(id);
        this.renderAttachments();
    }
    attachClear() {
        this.attachments.clear();
        this.renderAttachments();
    }
    renderAttachments() {
        if (!this.attachBar) return;
        const err = this.attachBar.querySelector('.bt-attach-error');
        this.attachBar.innerHTML = '';
        if (this.attachments.size === 0) {
            this.attachBar.classList.remove('bt-attachments-active');
        } else {
            this.attachBar.classList.add('bt-attachments-active');
            for (const [id, item] of this.attachments){
                const wrap = document.createElement('div');
                wrap.className = 'bt-attachment-thumb';
                wrap.dataset.attachId = id;
                const img = document.createElement('img');
                img.src = item.dataUrl;
                img.alt = item.filename || 'image';
                img.title = item.filename || 'image';
                wrap.appendChild(img);
                const rm = document.createElement('button');
                rm.type = 'button';
                rm.className = 'bt-attachment-remove';
                rm.title = 'Remove';
                rm.textContent = '×';
                rm.addEventListener('click', (e)=>{
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
        this.attachErrorTimer = setTimeout(()=>{
            chip.remove();
            if (this.attachments.size === 0) {
                this.attachBar.classList.remove('bt-attachments-active');
            }
        }, 4500);
    }
    async _submit() {
        const text = this.textInput.value;
        const yoloMode = this.textInput.classList.contains('bt-text-input-yolo');
        if (!yoloMode && text.trim() === '' && this.attachments.size === 0) return;
        const payload = [];
        for (const item of this.attachments.values()){
            const buf = await item.blob.arrayBuffer();
            payload.push({
                mime: item.mime,
                filename: item.filename || '',
                data: arrayBufferToBase64(buf)
            });
        }
        this.comm.notify({
            type: 'send',
            text,
            attachments: payload
        });
        this.textInput.value = '';
        this.textInput.dispatchEvent(new Event('input', {
            bubbles: true
        }));
        this.attachClear();
    }
    onViewportResize() {
        const vv = window.visualViewport;
        const app = this.app || this.container.closest('.bt-app');
        if (app) app.style.height = vv.height + 'px';
        if (this.followMode) this.queueScrollToBottom();
    }
    applyUserScroll(prevTop) {
        const { scrollTop , scrollHeight , clientHeight  } = this.container;
        const atBot = this.atBottom();
        if (this.followMode && !atBot) {
            this.setFollowMode(false);
            this.cancelPendingScroll();
        }
        if (this.followMode) return;
        if (atBot) {
            this.setFollowMode(true);
            this.queueScrollToBottom();
        } else {
            this.cancelPendingScroll();
        }
    }
    setFollowMode(on) {
        if (this.followMode === on) return;
        this.followMode = on;
        if (on) {
            this.unreadCount = 0;
            this.hideNewMessagePill();
        }
    }
    cancelPendingScroll() {
        if (this.scrollRafId !== null && this.scrollRafId !== undefined) {
            cancelAnimationFrame(this.scrollRafId);
            this.scrollRafId = null;
            this.scrollQueued = false;
        }
    }
    registerUnread() {
        this.unreadCount++;
        if (this.lastMessageFullyOutOfView()) {
            this.showNewMessagePill();
        } else {
            this.refreshPillContent();
        }
    }
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
    refreshPillContent() {
        if (!this.pillEl) return;
        const hasUnread = this.unreadCount > 0;
        this.pillEl.classList.toggle('bt-new-msg-pill-glow', hasUnread);
        if (this.pillLabelEl) {
            this.pillLabelEl.textContent = hasUnread ? 'New messages' : 'Move to bottom';
        }
    }
    createNewMessagePill() {
        const app = this.container?.closest('.bt-app') || this.container?.parentElement;
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
        pill.addEventListener('click', (e)=>{
            e.preventDefault();
            this.setFollowMode(true);
            this.scrollToBottom();
        });
        app.appendChild(pill);
        this.pillEl = pill;
        this.pillLabelEl = label;
    }
}
const PATH_RE = /^(~|\.{1,2})?\/?[\w.@+-]+(\/[\w.@+-]+)+(:\d+)?$/;
function decorateCodeBlocks(rootEl) {
    rootEl.querySelectorAll('pre').forEach((pre)=>{
        if (pre.dataset.btDecorated || pre.closest('.bt-code-wrap')) return;
        pre.dataset.btDecorated = '1';
        const wrap = document.createElement('div');
        wrap.className = 'bt-code-wrap';
        pre.parentNode.insertBefore(wrap, pre);
        wrap.appendChild(pre);
        const codeText = ()=>pre.innerText || '';
        const mk = (cls, glyph, title, onClick)=>{
            const b = document.createElement('button');
            b.type = 'button';
            b.className = 'bt-code-action ' + cls;
            b.title = title;
            b.textContent = glyph;
            b.addEventListener('click', (e)=>{
                e.preventDefault();
                e.stopPropagation();
                onClick(b);
            });
            return b;
        };
        const copyBtn = mk('bt-code-copy', '⧉', 'Copy code', (b)=>{
            if (!navigator.clipboard) return;
            navigator.clipboard.writeText(codeText()).then(()=>{
                b.textContent = '✓';
                setTimeout(()=>{
                    b.textContent = '⧉';
                }, 1200);
            }).catch(()=>{});
        });
        const dlBtn = mk('bt-code-download', '⤓', 'Download', ()=>{
            const blob = new Blob([
                codeText()
            ], {
                type: 'text/plain'
            });
            const a = document.createElement('a');
            a.href = URL.createObjectURL(blob);
            a.download = 'snippet.txt';
            document.body.appendChild(a);
            a.click();
            a.remove();
            setTimeout(()=>URL.revokeObjectURL(a.href), 1000);
        });
        const actions = document.createElement('div');
        actions.className = 'bt-code-actions';
        actions.appendChild(copyBtn);
        actions.appendChild(dlBtn);
        wrap.appendChild(actions);
    });
}
function linkifyPaths(rootEl) {
    rootEl.querySelectorAll('code').forEach((el)=>{
        if (el.closest('pre') || el.closest('a')) return;
        const text = (el.textContent || '').trim();
        if (!PATH_RE.test(text) || text.includes('://')) return;
        el.classList.add('bt-path-link');
        el.dataset.path = text;
    });
}
function openLightbox(media) {
    const overlay = document.createElement('div');
    overlay.className = 'bt-lightbox-overlay';
    const big = media.cloneNode(true);
    big.classList.add('bt-lightbox-media');
    overlay.appendChild(big);
    const close = ()=>{
        overlay.remove();
        document.removeEventListener('keydown', onkey);
    };
    const onkey = (e)=>{
        if (e.key === 'Escape') close();
    };
    overlay.addEventListener('click', (e)=>{
        if (e.target === overlay) close();
    });
    document.addEventListener('keydown', onkey);
    document.body.appendChild(overlay);
}
function escapeHTML(str) {
    return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function escapeAttr(str) {
    return escapeHTML(str).replace(/"/g, '&quot;');
}
function _subseqMatch(needle, haystack) {
    if (!needle) return true;
    const n = needle.toLowerCase(), h = haystack.toLowerCase();
    let j = 0;
    for(let i = 0; i < h.length && j < n.length; i++)if (h[i] === n[j]) j++;
    return j === n.length;
}
function _formatElapsed(sec) {
    if (sec < 60) return `${Math.round(sec)}s`;
    const m = Math.floor(sec / 60);
    const s = Math.round(sec - m * 60);
    return s === 0 ? `${m}m` : `${m}m${s}s`;
}
function _writeToolElapsed(node) {
    if (!node) return;
    const timer = node.querySelector('.bt-tool-timer');
    if (!timer) return;
    const started = parseFloat(node.dataset.toolStarted ?? '0');
    const finished = parseFloat(node.dataset.toolFinished ?? '0');
    if (!started) return;
    const dt = Math.max(0, (finished || Date.now() / 1000) - started);
    timer.textContent = dt > 1 ? _formatElapsed(dt) : '';
}
function arrayBufferToBase64(buf) {
    const bytes = new Uint8Array(buf);
    let binary = '';
    const CHUNK = 0x8000;
    for(let i = 0; i < bytes.length; i += CHUNK){
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
    }
    return btoa(binary);
}
window.btMSearchFilter = function btMSearchFilter(inputEl) {
    const q = inputEl.value.toLowerCase();
    const wrap = inputEl.closest('.bt-msearch');
    wrap.querySelectorAll('.bt-msearch-item').forEach((item)=>{
        item.hidden = q.length > 0 && !item.dataset.label.includes(q);
    });
};
window.btMSearchOpen = function btMSearchOpen(triggerEl) {
    document.querySelectorAll('.bt-msearch-open').forEach((el)=>el.classList.remove('bt-msearch-open'));
    const wrap = triggerEl.closest('.bt-msearch');
    wrap.classList.add('bt-msearch-open');
    const input = wrap.querySelector('.bt-msearch-input');
    if (input) {
        input.value = '';
        window.btMSearchFilter(input);
    }
    requestAnimationFrame(()=>{
        function onOutside(e) {
            if (!e.target.closest('.bt-msearch-open')) {
                document.querySelectorAll('.bt-msearch-open').forEach((el)=>el.classList.remove('bt-msearch-open'));
                document.removeEventListener('click', onOutside, true);
            }
        }
        document.addEventListener('click', onOutside, true);
        if (input) input.focus();
    });
};
window.btMSearchSelect = function btMSearchSelect(itemEl, pickObs, cfgId, value) {
    pickObs.notify([
        cfgId,
        value
    ]);
    const wrap = itemEl.closest('.bt-msearch');
    if (wrap) wrap.classList.remove('bt-msearch-open');
};
const CHAT_INSTANCES = new Set();
function toolSlot(id) {
    const direct = document.querySelector(`.bt-tool-body[data-tool-id="${CSS.escape(id)}"]`);
    if (direct) return direct;
    for (const chat of CHAT_INSTANCES){
        const node = chat.nodeById.get(id);
        const slot = node && node.querySelector('.bt-tool-body');
        if (slot) return slot;
    }
    return null;
}
function connect(node, comm, init = {}) {
    const chat = new BonitoChat(node, comm);
    if (Array.isArray(init.commands)) chat.slashCommands = init.commands;
    node.__bt_chat = chat;
    CHAT_INSTANCES.add(chat);
    const parent = node.parentNode;
    if (parent) {
        const mo = new MutationObserver(()=>{
            if (!node.isConnected) {
                try {
                    chat.destroy();
                } catch (_) {}
                CHAT_INSTANCES.delete(chat);
                mo.disconnect();
            }
        });
        mo.observe(parent, {
            childList: true
        });
    }
    return chat;
}
export { BonitoChat as BonitoChat };
export { Collapsable as Collapsable };
export { toolSlot as toolSlot };
export { connect as connect };


// deno-fmt-ignore-file
// deno-lint-ignore-file
// This code was bundled using `deno bundle` and it's not recommended to edit it manually

function editSteps(a, b, maxD) {
    const n = a.length, m = b.length, limit = Math.min(n + m, maxD), off = limit + 1;
    const v = new Int32Array(2 * limit + 3);
    const trace = [];
    for(let d = 0; d <= limit; d++){
        trace.push(v.slice(off - d - 1, off + d + 2));
        for(let k = -d; k <= d; k += 2){
            let x = k === -d || k !== d && v[k - 1 + off] < v[k + 1 + off] ? v[k + 1 + off] : v[k - 1 + off] + 1;
            let y = x - k;
            while(x < n && y < m && a[x] === b[y]){
                x++;
                y++;
            }
            v[k + off] = x;
            if (x >= n && y >= m) {
                const steps = [];
                for(let dd = d; dd > 0; dd--){
                    const w = trace[dd], kk = x - y;
                    const down = kk === -dd || kk !== dd && w[kk + dd] < w[kk + dd + 2];
                    const pk = down ? kk + 1 : kk - 1, px = w[pk + dd + 1], py = px - pk;
                    while(x > (down ? px : px + 1) && y > (down ? py + 1 : py)){
                        steps.push('=');
                        x--;
                        y--;
                    }
                    steps.push(down ? '+' : '-');
                    x = px;
                    y = py;
                }
                while(x > 0 && y > 0){
                    steps.push('=');
                    x--;
                    y--;
                }
                return steps.reverse();
            }
        }
    }
    return null;
}
function changedRanges(a, b) {
    const ta = a.match(/\w+|\s+|[^\w\s]/g) || [], tb = b.match(/\w+|\s+|[^\w\s]/g) || [];
    const steps = editSteps(ta, tb, 200);
    if (!steps) return null;
    const ra = [], rb = [];
    let i = 0, j = 0, pa = 0, pb = 0, kept = 0;
    const add = (ranges, from, to)=>{
        const last = ranges[ranges.length - 1];
        if (last && last[1] === from) last[1] = to;
        else ranges.push([
            from,
            to
        ]);
    };
    for (const st of steps){
        if (st === '=') {
            pa += ta[i].length;
            pb += tb[j].length;
            kept += ta[i].length;
            i++;
            j++;
        } else if (st === '-') {
            add(ra, pa, pa + ta[i].length);
            pa += ta[i++].length;
        } else {
            add(rb, pb, pb + tb[j].length);
            pb += tb[j++].length;
        }
    }
    if (kept * 3 < Math.max(a.length, b.length)) return null;
    return [
        ra,
        rb
    ];
}
if (typeof document !== 'undefined') {
    const vp = document.querySelector('meta[name="viewport"]');
    if (vp && !vp.content.includes('interactive-widget')) vp.content += ', interactive-widget=resizes-content';
}
const storage = (()=>{
    const refused = (error, key)=>{
        if (!(error instanceof DOMException) || ![
            'SecurityError',
            'QuotaExceededError'
        ].includes(error.name)) throw error;
        console.warn(`browser storage refused (${key}):`, error.message);
    };
    return {
        get (key) {
            try {
                return localStorage.getItem(key);
            } catch (e) {
                refused(e, key);
                return null;
            }
        },
        set (key, value) {
            try {
                localStorage.setItem(key, value);
            } catch (e) {
                refused(e, key);
            }
        },
        remove (key) {
            try {
                localStorage.removeItem(key);
            } catch (e) {
                refused(e, key);
            }
        }
    };
})();
function formatTokens(n) {
    if (n < 1000) return String(Math.round(n));
    if (n < 10000) return (n / 1000).toFixed(1) + 'k';
    if (n < 1000000) return Math.round(n / 1000) + 'k';
    return (n / 1000000).toFixed(1) + 'M';
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
        this.fetchEachExpand = this.editMode ? false : opts.fetchEachExpand || false;
        this.discardOnCollapse = this.editMode ? false : opts.discardOnCollapse || false;
        this.onExpand = opts.onExpand || null;
        this.reserve = opts.reserve || null;
        this.onToggle = opts.onToggle || null;
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
                this.onToggle && this.onToggle(this.expanded);
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
            } else {
                this.body.style.display = expanded ? '' : 'none';
            }
        }
        const editBodyEmpty = this.editMode && this.body.childElementCount === 0;
        if (expanded && (!this.editMode || editBodyEmpty)) {
            if (this.lazy && (!this.loaded || this.fetchEachExpand)) {
                this.loaded = true;
                this.showPlaceholder();
                this.onExpand && this.onExpand();
            }
        } else if (!expanded && this.discardOnCollapse) {
            this.body.innerHTML = '';
            this.loaded = false;
        }
    }
    showPlaceholder() {
        showLoading(this.body, this.reserve ? this.reserve() : null);
    }
    fill(html) {
        if (html != null) this.body.innerHTML = html;
        this.loaded = true;
    }
}
const CODE_STATE = new WeakMap();
const CODE_OBSERVERS = new WeakMap();
const CODE_CHUNKS = new WeakMap();
function codeLines(text) {
    return text === '' ? [] : text.split('\n');
}
function codeRow(kind, text, side, index, gutter) {
    const shown = text.endsWith('\r') ? text.slice(0, -1) : text;
    return {
        el: null,
        kind,
        gutter,
        text: shown,
        side,
        index,
        marks: null
    };
}
function* codeRows(sources, ops) {
    if (ops === undefined) {
        const lines = codeLines(sources[0]);
        if (lines.length > 1 && lines[lines.length - 1] === '') lines.pop();
        for(let i = 0; i < lines.length; i++)yield codeRow('', lines[i], 0, i, null);
        return;
    }
    const a = codeLines(sources[0]), b = codeLines(sources[1]);
    const w = String(Math.max(a.length, b.length, 1)).length;
    const pad = (x)=>(x === null ? '' : String(x)).padStart(w);
    const gutter = (i, j, sign)=>`${pad(i === null ? null : i + 1)} ${pad(j === null ? null : j + 1)} ${sign}`;
    let i = 0, j = 0;
    const runs = ops.split(' ').filter(Boolean).map((op)=>[
            op[0],
            parseInt(op.slice(1), 10)
        ]);
    for(let r = 0; r < runs.length; r++){
        const [k, n] = runs[r];
        if (k === '=') {
            for(let t = 0; t < n; t++, i++, j++)yield codeRow('', b[j], 1, j, gutter(i, j, ' '));
        } else if (k === '-') {
            const removed = [];
            for(let t = 0; t < n; t++, i++){
                const row = codeRow('del', a[i], 0, i, gutter(i, null, '-'));
                removed.push(row);
                yield row;
            }
            if (r + 1 < runs.length && runs[r + 1][0] === '+') {
                const [, m] = runs[++r];
                for(let t = 0; t < m; t++, j++){
                    const row = codeRow('add', b[j], 1, j, gutter(null, j, '+'));
                    const old = removed[t];
                    if (old) {
                        const ranges = changedRanges(old.text, row.text);
                        if (ranges) {
                            old.marks = ranges[0];
                            row.marks = ranges[1];
                        }
                    }
                    yield row;
                }
            }
        } else {
            for(let t = 0; t < n; t++, j++)yield codeRow('add', b[j], 1, j, gutter(null, j, '+'));
        }
    }
}
function markRange(row, from, to) {
    if (from >= to) return;
    const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
    const nodes = [];
    for(let n = walker.nextNode(); n; n = walker.nextNode())nodes.push(n);
    let pos = 0;
    for (const node of nodes){
        const start = pos, end = pos + node.data.length;
        pos = end;
        const a = Math.max(from, start), b = Math.min(to, end);
        if (a >= b) continue;
        let mid = node;
        if (a > start) mid = mid.splitText(a - start);
        if (b < end) mid.splitText(b - a);
        const span = document.createElement('span');
        span.className = 'bt-ch';
        mid.replaceWith(span);
        span.appendChild(mid);
    }
}
function markRanges(row) {
    if (row.marks) for (const [from, to] of row.marks)markRange(row.el, from, to);
}
function resource(line, text) {
    const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
    let i = 0, col = 0, carry = 0;
    const out = [];
    for(let node = walker.nextNode(); node; node = walker.nextNode()){
        let need = node.data.length, s = '';
        while(need > 0){
            if (carry > 0) {
                const k = Math.min(carry, need);
                carry -= k;
                need -= k;
                continue;
            }
            if (i >= text.length) return false;
            const c = text[i++];
            if (c === '\t') {
                const w = 4 - col % 4;
                s += c;
                col += w;
                const k = Math.min(w, need);
                need -= k;
                carry = w - k;
            } else {
                s += c;
                col += 1;
                need -= 1;
            }
        }
        out.push([
            node,
            s
        ]);
    }
    if (i !== text.length || carry !== 0) return false;
    for (const [node, s] of out)node.data = s;
    return true;
}
async function highlightCode(el) {
    const st = CODE_STATE.get(el);
    CODE_STATE.set(el, null);
    if (!st.lib) {
        el.dataset.btHighlighted = 'true';
        return;
    }
    const lib = await st.lib;
    const lang = st.lang || (st.path ? await lib.language_for_path(st.path) : 'plaintext');
    if (lang === 'plaintext') {
        st.highlighter.forget(el);
        el.dataset.btHighlighted = 'true';
        return;
    }
    const tpl = document.createElement('template');
    for(let side = 0; side < st.sources.length; side++){
        if (!el.isConnected || st.highlighter.closed) return;
        const rows = new Map(st.rows.filter((r)=>r.side === side).map((r)=>[
                r.index,
                r
            ]));
        if (!rows.size) continue;
        await lib.colorize_lines(st.sources[side], lang, (index, html)=>{
            if (!el.isConnected || st.highlighter.closed) return false;
            const row = rows.get(index);
            if (!row) return;
            row.html = html;
            if (row.chunk.wanted) paintCodeRow(row, tpl);
        });
    }
    if (el.isConnected && !st.highlighter.closed) el.dataset.btHighlighted = 'true';
}
function paintCodeRow(row, tpl) {
    if (row.html == null) return;
    tpl.innerHTML = row.html;
    row.html = null;
    if (!resource(tpl.content, row.text)) return;
    const selection = window.getSelection();
    const point = (node, offset)=>{
        if (!node || !row.el.contains(node)) return {
            node,
            offset
        };
        const range = document.createRange();
        range.selectNodeContents(row.el);
        range.setEnd(node, offset);
        return {
            index: range.toString().length
        };
    };
    const anchor = point(selection.anchorNode, selection.anchorOffset);
    const focus = point(selection.focusNode, selection.focusOffset);
    row.el.replaceChildren(tpl.content);
    markRanges(row);
    if (anchor.index === undefined && focus.index === undefined) return;
    const restore = (p)=>{
        if (p.index === undefined) return p;
        const walker = document.createTreeWalker(row.el, NodeFilter.SHOW_TEXT);
        let left = p.index;
        for(let n = walker.nextNode(); n; n = walker.nextNode()){
            if (left <= n.length) return {
                node: n,
                offset: left
            };
            left -= n.length;
        }
        return {
            node: row.el,
            offset: row.el.childNodes.length
        };
    };
    const a = restore(anchor), f = restore(focus);
    selection.setBaseAndExtent(a.node, a.offset, f.node, f.offset);
}
class CodeHighlighter {
    constructor(root){
        this.pending = [];
        this.running = false;
        this.closed = false;
        this.paintPending = [];
        this.painting = false;
        this.observer = new IntersectionObserver((entries)=>{
            for (const e of entries){
                if (!e.isIntersecting) continue;
                this.observer.unobserve(e.target);
                this.pending.push(e.target);
            }
            this.drain();
        }, {
            root,
            rootMargin: '100% 0px'
        });
        this.chunks = new IntersectionObserver((entries)=>{
            for (const e of entries){
                if (!e.isIntersecting) continue;
                this.chunks.unobserve(e.target);
                const chunk = CODE_CHUNKS.get(e.target);
                chunk.wanted = true;
                this.paintPending.push(chunk.rows);
            }
            this.paint();
        }, {
            root,
            rootMargin: '100% 0px'
        });
    }
    observe(el) {
        const st = CODE_STATE.get(el);
        st.highlighter = this;
        for (const chunk of st.chunks)this.chunks.observe(chunk);
        this.observer.observe(el);
    }
    forget(body) {
        for (const el of body.querySelectorAll('.bt-code'))this.observer.unobserve(el);
        for (const el of body.querySelectorAll('.bt-code-chunk'))this.chunks.unobserve(el);
    }
    disconnect() {
        this.closed = true;
        this.observer.disconnect();
        this.chunks.disconnect();
        this.pending.length = 0;
        this.paintPending.length = 0;
    }
    async paint() {
        if (this.painting) return;
        this.painting = true;
        const tpl = document.createElement('template');
        let until = performance.now() + 3;
        try {
            while(!this.closed && this.paintPending.length){
                for (const row of this.paintPending.shift()){
                    if (!row.el.isConnected) continue;
                    paintCodeRow(row, tpl);
                    if (performance.now() >= until) {
                        await new Promise((resolve)=>setTimeout(resolve, 0));
                        until = performance.now() + 3;
                    }
                }
            }
        } finally{
            this.painting = false;
        }
    }
    async drain() {
        if (this.running) return;
        this.running = true;
        let until = performance.now() + 3;
        try {
            while(!this.closed && this.pending.length){
                const el = this.pending.shift();
                if (el.isConnected) await highlightCode(el);
                if (performance.now() >= until) {
                    await new Promise((resolve)=>setTimeout(resolve, 0));
                    until = performance.now() + 3;
                }
            }
        } finally{
            this.running = false;
        }
    }
}
function observeCode(el) {
    const root = el.closest('.bt-messages');
    const key = root || document;
    let highlighter = CODE_OBSERVERS.get(key);
    if (!highlighter) {
        highlighter = new CodeHighlighter(root);
        CODE_OBSERVERS.set(key, highlighter);
    }
    highlighter.observe(el);
}
async function mountCode(el, lib) {
    if (CODE_STATE.has(el)) return;
    CODE_STATE.set(el, null);
    el.dataset.btHighlighted = 'false';
    const sources = [
        ...el.querySelectorAll(':scope > pre.bt-code-src')
    ].map((p)=>p.textContent);
    const rows = [];
    let until = performance.now() + 3;
    for (const row of codeRows(sources, el.dataset.ops)){
        rows.push(row);
        if (performance.now() >= until) {
            await new Promise((resolve)=>setTimeout(resolve, 0));
            if (!el.isConnected) return;
            until = performance.now() + 3;
        }
    }
    const last = rows[rows.length - 1];
    if (el.dataset.ops !== undefined && last?.kind === '' && last.text === '') rows.pop();
    const lines = document.createElement('div');
    const chunks = [];
    lines.className = 'bt-code-lines';
    lines.style.setProperty('--bt-code-height', rows.length * 18 + 'px');
    for(let i = 0; i < rows.length; i += 32){
        const chunk = document.createElement('div');
        chunk.className = 'bt-code-chunk';
        chunk.style.setProperty('--bt-code-height', Math.min(32, rows.length - i) * 18 + 'px');
        const state = {
            rows: rows.slice(i, i + 32),
            wanted: false
        };
        if (lib) CODE_CHUNKS.set(chunk, state);
        for (const row of state.rows){
            row.el = document.createElement('div');
            row.el.className = row.kind ? `bt-l bt-l-${row.kind}` : 'bt-l';
            if (row.gutter !== null) row.el.dataset.g = row.gutter;
            row.el.textContent = row.text;
            if (lib) row.chunk = state;
            chunk.appendChild(row.el);
            markRanges(row);
        }
        lines.appendChild(chunk);
        chunks.push(chunk);
        if (performance.now() >= until) {
            await new Promise((resolve)=>setTimeout(resolve, 0));
            if (!el.isConnected) return;
            until = performance.now() + 3;
        }
    }
    el.replaceChildren(lines);
    if (lib) {
        CODE_STATE.set(el, {
            lib,
            lang: el.dataset.lang || '',
            path: el.dataset.path || '',
            sources,
            rows,
            chunks
        });
        observeCode(el);
    } else {
        CODE_STATE.set(el, null);
        el.dataset.btHighlighted = 'true';
    }
    bodyMounted(el);
}
const filterKey = (msg)=>msg.type === 'tool' ? 'tool:' + (msg.tool || 'other') : msg.type;
const DEFAULT_HIDDEN = [
    'tool:ToolSearch'
];
function formatBytes(n) {
    if (n < 1024 * 1024) return `${Math.max(1, Math.round(n / 1024))} KB`;
    if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
    return `${(n / 1024 / 1024 / 1024).toFixed(1)} GB`;
}
function showLoading(body, shape) {
    body.innerHTML = '<div class="bt-collapsable-loading">loading…</div>';
    if (shape) Object.assign(body.firstElementChild.style, {
        boxSizing: 'border-box'
    }, shape);
}
class BonitoChat {
    constructor(container, comm, init = {}){
        this.container = container;
        this.projectVisible = container.closest('.bt-chatpane')?.getAttribute('aria-hidden') !== 'true';
        this.workspacePanel = container.closest('.bw-ws-panel');
        this.workspaceVisible = this.workspacePanel?.dataset.bwVisible !== 'false';
        this.paneVisible = this.projectVisible && this.workspaceVisible;
        this.onWorkspaceVisibility = (e)=>{
            this.workspaceVisible = e.detail;
            this.updateVisibility();
        };
        this.workspacePanel?.addEventListener('bw-panel-visibility', this.onWorkspaceVisibility);
        this.showRestoreRaf = 0;
        this.showRestoreTimers = [];
        this.comm = comm;
        this.destroyed = false;
        this.cache = new Map();
        this.expandState = new Map();
        this.order = [];
        this.nodeById = new Map();
        this.totalCount = 0;
        this.seq = null;
        this.plo = 0;
        this.phi = -1;
        this.CHUNK = 40;
        this.MAX_WINDOW = 160;
        this.reqSeq = 0;
        this.pending = {};
        this.epoch = 0;
        this.STREAM_APPLY_MS = 100;
        this.rowObserver = new ResizeObserver((entries)=>{
            if (this.destroyed) return;
            const c = this.container;
            if (!this.paneVisible || c.clientHeight === 0) return;
            const st = c.scrollTop;
            const sb = st + c.clientHeight;
            const last = this.cache.get(this.order[this.order.length - 1]);
            const rows = entries.map((e)=>[
                    e.target,
                    e.borderBoxSize && e.borderBoxSize.length ? e.borderBoxSize[0].blockSize : e.target.offsetHeight
                ]).sort(([a], [b])=>a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1);
            let above = 0;
            let shift = 0;
            let grew = false;
            for (const [node, h] of rows){
                const prev = node.__btH;
                node.__btH = h;
                if (prev === undefined || prev === h) continue;
                grew = true;
                if (node.collapsable && node.classList.contains('bt-tool-msg')) {
                    this.scheduleBodyReport(node);
                    this.onBodyMounted(node);
                }
                const top = node.offsetTop - shift;
                shift += h - prev;
                if (node.offsetParent === null) continue;
                if (top < st - 1 && (top + prev <= st + 1 || top + prev < sb && node !== last)) {
                    above += h - prev;
                }
            }
            if (above !== 0 && !this.followMode && !this.railDrag) {
                c.scrollTop = st + above;
                this.prevScrollTop = c.scrollTop;
            }
            if (grew && this.followMode) this.queueScrollToBottom();
            if (grew) this.updateRail();
        });
        const wantKeepalive = typeof window !== 'undefined' && Number.isFinite(window.BT_APP_KEEPALIVE) ? window.BT_APP_KEEPALIVE : 6;
        this.APP_KEEPALIVE = Math.min(10, Math.max(0, wantKeepalive));
        this.appLru = [];
        this.visibleApps = new Set();
        this.appObserver = new IntersectionObserver((entries)=>{
            if (this.destroyed) return;
            for (const e of entries){
                const idx = e.target.__btIdx;
                if (idx === undefined) continue;
                if (e.isIntersecting) this.visibleApps.add(idx);
                else this.visibleApps.delete(idx);
                this.touchApp(idx);
            }
            this.enforceAppLru();
        }, {
            root: container
        });
        this.freeObserver = new IntersectionObserver((entries)=>{
            if (this.destroyed || !this.paneVisible || this.container.clientHeight === 0) return;
            for (const e of entries)if (!e.isIntersecting) this.freeBody(e.target);
        }, {
            root: container,
            rootMargin: '300% 0px'
        });
        this.mountObserver = new IntersectionObserver((entries)=>{
            if (this.destroyed || !this.paneVisible || this.container.clientHeight === 0) return;
            for (const e of entries){
                if (!e.isIntersecting) continue;
                const n = e.target;
                if (n.dataset.btFreed) {
                    this.unfreeBody(n);
                } else if (n.dataset.btWantsBody) {
                    delete n.dataset.btWantsBody;
                    this.comm.notify({
                        type: 'tool.render',
                        id: n.dataset.msgId
                    });
                }
            }
        }, {
            root: container,
            rootMargin: '150% 0px'
        });
        this.followMode = true;
        this.unreadCount = 0;
        this.pillShown = false;
        this.AT_BOTTOM_PX = 20;
        this.prevScrollTop = container.scrollTop;
        this.rowsEnd = container.querySelector('.bt-rows-end');
        this.toolbarEl = (container.closest('.bt-app') || container.parentElement).querySelector('.bt-chat-toolbar');
        if (this.toolbarEl) this.toolbarEl.style.display = 'none';
        this.hiddenTypes = new Set(DEFAULT_HIDDEN);
        this.seenTypes = new Set();
        this.keyByIdx = new Map();
        this.filterRow = null;
        this.nativeImages = true;
        this.nativeVideos = true;
        this.lensActive = false;
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
        this.thinkingEstimate = false;
        this.tailEl = container.querySelector('.bt-messages-tail');
        this.sizeTail();
        comm.on((msg)=>{
            if (this.destroyed) return false;
            if (msg && typeof msg === 'object') this.dispatch(msg);
        });
        this.lastUserInputT = -Infinity;
        this.pendingUserScroll = false;
        const markUserInput = ()=>{
            this.lastUserInputT = performance.now();
            this.pendingUserScroll = true;
            this.cancelPendingScroll();
            this.cancelShowRestore();
        };
        container.addEventListener('wheel', markUserInput, {
            passive: true,
            capture: true
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
        this.onMediaSized = (e)=>{
            const el = e.target;
            if (!(el instanceof HTMLElement) || !el.classList.contains('bt-media')) return;
            const path = el.closest('.bt-media-wrap')?.dataset.workerPath;
            const video = el.tagName === 'VIDEO';
            const w = video ? el.videoWidth : el.naturalWidth;
            const h = video ? el.videoHeight : el.naturalHeight;
            if (!path || !w || !h) return;
            if (+el.getAttribute('width') === w && +el.getAttribute('height') === h) return;
            el.setAttribute('width', w);
            el.setAttribute('height', h);
            this.comm.notify({
                type: 'media.size',
                path,
                w,
                h
            });
        };
        container.addEventListener('load', this.onMediaSized, true);
        container.addEventListener('loadedmetadata', this.onMediaSized, true);
        container.addEventListener('click', (e)=>{
            const chip = e.target.closest('.bt-tool-jump');
            if (!chip || !container.contains(chip)) return;
            e.preventDefault();
            e.stopPropagation();
            this.jumpToMessage(parseInt(chip.dataset.jumpIndex ?? '-1', 10), chip.dataset.jumpId);
        }, {
            capture: true
        });
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
        container.addEventListener('click', (e)=>{
            const img = e.target.closest('.bt-agent-msg img, .bt-tool-md img');
            if (!img || img.closest('a, .bt-media-wrap')) return;
            e.stopPropagation();
            openLightbox(img);
        });
        this.scrollbarDrag = false;
        this.railDrag = null;
        this.onWindowMouseUp = ()=>{
            if (!this.container.isConnected) this.lazyDestroy();
        };
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
                } catch (error) {
                    if (error.name !== 'NotFoundError') throw error;
                }
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
            if (this.container.hasPointerCapture(e.pointerId)) this.container.releasePointerCapture(e.pointerId);
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
            if (!this.paneVisible || this.container.clientHeight === 0) return;
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
            this.ensureWindow();
        };
        container.addEventListener('scroll', this.onScroll, {
            passive: true
        });
        this.viewportObserver = new ResizeObserver(()=>{
            if (this.destroyed) return;
            if (!this.paneVisible || this.container.clientHeight === 0) return;
            this.sizeTail();
            if (this.followMode) this.queueScrollToBottom();
        });
        this.viewportObserver.observe(this.container);
        this.setupMoveObserver();
        if (this.busyEl) this.viewportObserver.observe(this.busyEl);
        if (this.waitingEl) this.viewportObserver.observe(this.waitingEl);
        if (this.thinkingEl) this.viewportObserver.observe(this.thinkingEl);
        if (window.visualViewport) {
            this.lastViewportHeight = null;
            this.onVisualViewportResize = ()=>this.onViewportResize();
            window.visualViewport.addEventListener('resize', this.onVisualViewportResize);
        }
        Promise.resolve().then(()=>{
            this.setupInputs();
            this.setCancelling(this.cancelling ?? false);
            this.setupLiveTicker();
            this.setupLens();
        });
        this.setupRail();
        const tail = init.tail;
        if (tail && Number.isInteger(tail.n)) this.applyTail(tail);
        comm.notify({
            type: 'init'
        });
    }
    destroy() {
        this.destroyed = true;
        this.workspacePanel?.removeEventListener('bw-panel-visibility', this.onWorkspaceVisibility);
        this.cancelShowRestore();
        CODE_OBSERVERS.get(this.container)?.disconnect();
        CODE_OBSERVERS.delete(this.container);
        if (this.elapsedTimer) {
            clearInterval(this.elapsedTimer);
            this.elapsedTimer = null;
        }
        if (this.onScroll) {
            this.container.removeEventListener('scroll', this.onScroll);
        }
        if (this.markUserInput) {
            this.container.removeEventListener('wheel', this.markUserInput, {
                capture: true
            });
            this.container.removeEventListener('touchstart', this.markUserInput);
            this.container.removeEventListener('touchmove', this.markUserInput);
            this.container.removeEventListener('keydown', this.markUserInput);
        }
        if (this.onMediaSized) {
            this.container.removeEventListener('load', this.onMediaSized, true);
            this.container.removeEventListener('loadedmetadata', this.onMediaSized, true);
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
            this.onCmdBlur && this.textInput.removeEventListener('blur', this.onCmdBlur);
        }
        if (this.cmdAc) {
            this.cmdAc.remove();
            this.cmdAc = null;
        }
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
            this.onDragOver && this.app.removeEventListener('dragover', this.onDragOver);
            this.onDragLeave && this.app.removeEventListener('dragleave', this.onDragLeave);
            this.onDrop && this.app.removeEventListener('drop', this.onDrop);
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
    lazyDestroy() {
        if (this.destroyed) return;
        try {
            this.destroy();
        } finally{
            CHAT_INSTANCES.delete(this);
        }
    }
    dispatch(msg) {
        if (typeof msg.n === 'number' && msg.n > this.totalCount) {
            this.totalCount = msg.n;
        }
        if (this.thinkingEstimate && [
            'chunk',
            'agent',
            'thought',
            'tool',
            'tool_update',
            'plan',
            'summary',
            'agent_final',
            'thinking',
            'busy_end',
            'session_reset'
        ].includes(msg.type)) this.endThinkingEstimate();
        switch(msg.type){
            case 'queue.state':
                return this.renderQueue(msg);
            case 'queue.delivered':
                return this.queueDelivered(msg);
            case 'cancel.state':
                this.turnSeq = msg.seq;
                this.setCancelling(msg.stopping);
                return;
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
                this.setCancelling(false);
                this.busyEl?.classList.remove('bt-busy-active');
                if (this.followMode) this.queueScrollToBottom();
                return;
            case 'agent_final':
                return this.onAgentFinal(msg);
            case 'thinking':
                return this.onThinking(msg);
            case 'thinking_tokens':
                return this.onThinkingTokens(msg.tokens);
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
    seqLength() {
        return this.seq ? this.seq.length : this.totalCount;
    }
    seqIndex(p) {
        return this.seq ? this.seq[p] : p;
    }
    seqPos(idx) {
        if (!this.seq) return idx >= 0 && idx < this.totalCount ? idx : -1;
        let lo = 0, hi = this.seq.length - 1;
        while(lo <= hi){
            const mid = lo + hi >> 1;
            const v = this.seq[mid];
            if (v === idx) return mid;
            if (v < idx) lo = mid + 1;
            else hi = mid - 1;
        }
        return -1;
    }
    blockEmpty() {
        return this.phi < this.plo;
    }
    atTail() {
        return this.phi === this.seqLength() - 1;
    }
    applyTail(tail) {
        this.totalCount = Math.max(this.totalCount, tail.n);
        if (tail.n === 0) {
            this.markReady();
            this.updateRail();
            return;
        }
        const items = (tail.msgs || []).map((m, i)=>[
                tail.start + i,
                m
            ]);
        this.replaceBlock(items, {
            kind: 'tail'
        });
    }
    applyCount(n) {
        if (n < this.totalCount) {
            this.onMsgsReload(n);
            return;
        }
        this.totalCount = n;
        if (n === 0) {
            this.markReady();
            this.updateRail();
            return;
        }
        if (this.blockEmpty()) {
            if (!this.pending.block) this.loadTail();
            return;
        }
        this.ensureWindow();
    }
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
        this.requestBlock(Math.max(0, len - this.CHUNK), len - 1, {
            kind: 'tail'
        });
    }
    requestBlock(pa, pb, opts) {
        this.epoch++;
        this.pending = {};
        this.request('block', pa, pb, opts);
    }
    request(slot, pa, pb, opts = {}) {
        if (pa > pb) return;
        const id = ++this.reqSeq;
        this.pending[slot] = {
            ...opts,
            id,
            slot,
            pa,
            pb
        };
        const msg = {
            type: 'msgs.request',
            epoch: this.epoch,
            req: id
        };
        if (this.seq) msg.indices = this.seq.slice(pa, pb + 1);
        else msg.range = [
            pa,
            pb
        ];
        this.comm.notify(msg);
    }
    onRange(msg) {
        if (msg.epoch !== undefined && msg.epoch !== null && msg.epoch !== this.epoch) return;
        const req = Object.values(this.pending).find((r)=>r.id === msg.req);
        if (!req) return;
        delete this.pending[req.slot];
        const msgs = msg.msgs ?? [];
        const items = Array.isArray(msg.indices) ? msg.indices.map((idx, i)=>[
                idx,
                msgs[i]
            ]) : msgs.map((m, i)=>[
                msg.start + i,
                m
            ]);
        if (req.slot === 'older') this.prependItems(items);
        else if (req.slot === 'newer') this.appendItems(items);
        else this.replaceBlock(items, req);
        this.ensureWindow();
    }
    makeRow(idx, data) {
        const node = this.createNode(data);
        node.__btIdx = idx;
        node.__btId = data.id;
        this.cache.set(idx, node);
        this.keyByIdx.set(idx, filterKey(data));
        if (data.id) this.nodeById.set(data.id, node);
        this.applyVisibility(idx, node);
        if (this.lensActions?.get(idx) === 'expand') node.dataset.btAutoExpand = '1';
        return node;
    }
    adoptRows(nodes) {
        for (const node of nodes){
            this.mountDeferred(node);
            if (this.lensActions?.get(node.__btIdx) === 'collapse') {
                node.collapsable?.setExpanded(false);
            }
        }
        for (const node of nodes){
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
        for (const idx of this.order)this.removeRow(idx);
        this.order = [];
        this.plo = 0;
        this.phi = -1;
    }
    insertRows(items, before) {
        const frag = document.createDocumentFragment();
        const nodes = [];
        for (const [idx, data] of items){
            const node = this.makeRow(idx, data);
            frag.appendChild(node);
            nodes.push(node);
        }
        this.container.insertBefore(frag, before);
        return nodes;
    }
    replaceBlock(items, req) {
        this.clearBlock();
        const rows = items.filter(([, d])=>d != null);
        const nodes = this.insertRows(rows, this.rowsEnd);
        this.order = rows.map(([idx])=>idx);
        if (this.order.length) {
            this.plo = this.seqPos(this.order[0]);
            this.phi = this.seqPos(this.order[this.order.length - 1]);
        }
        this.adoptRows(nodes);
        this.placeView(req);
        this.markReady();
    }
    prependItems(items) {
        const rows = items.filter(([idx, d])=>d != null && !this.cache.has(idx));
        if (rows.length === 0) return;
        if (this.seqPos(rows[rows.length - 1][0]) !== this.plo - 1) return;
        const c = this.container;
        const before = c.scrollHeight;
        const top = c.scrollTop;
        const first = this.cache.get(this.order[0]) || this.rowsEnd;
        const nodes = this.insertRows(rows, first);
        this.order = rows.map(([idx])=>idx).concat(this.order);
        this.plo = this.seqPos(rows[0][0]);
        this.adoptRows(nodes);
        const grown = c.scrollHeight - before;
        if (grown !== 0 && !this.railDrag) {
            c.scrollTop = top + grown;
            this.prevScrollTop = c.scrollTop;
        }
    }
    appendItems(items) {
        const rows = items.filter(([idx, d])=>d != null && !this.cache.has(idx));
        if (rows.length === 0) return;
        if (this.seqPos(rows[0][0]) !== this.phi + 1) return;
        const nodes = this.insertRows(rows, this.rowsEnd);
        this.order = this.order.concat(rows.map(([idx])=>idx));
        this.phi = this.seqPos(rows[rows.length - 1][0]);
        this.adoptRows(nodes);
        if (this.followMode) this.queueScrollToBottom();
    }
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
            this.restoreAnchor({
                idx: req.idx,
                off: req.off
            });
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
    ensureWindow() {
        if (this.destroyed) return;
        const c = this.container;
        if (!this.paneVisible || this.railDrag || c.clientHeight === 0) {
            this.updateRail();
            return;
        }
        const len = this.seqLength();
        if (this.pending.block || len === 0) {
            this.updateRail();
            return;
        }
        if (this.blockEmpty()) {
            this.loadTail();
            return;
        }
        const margin = Math.max(800, 2 * c.clientHeight);
        if (this.plo > 0 && !this.pending.older && c.scrollTop < margin) {
            this.request('older', Math.max(0, this.plo - this.CHUNK), this.plo - 1);
        }
        if (this.phi < len - 1 && !this.pending.newer && c.scrollHeight - c.scrollTop - c.clientHeight < margin) {
            this.request('newer', this.phi + 1, Math.min(len - 1, this.phi + this.CHUNK));
        }
        this.trimBlock();
        this.updateRail();
    }
    visibleSpan() {
        const st = this.container.scrollTop;
        const sb = st + this.container.clientHeight;
        let first = -1, last = -1;
        for(let i = 0; i < this.order.length; i++){
            const node = this.cache.get(this.order[i]);
            if (!node || node.offsetParent === null) continue;
            const top = node.offsetTop;
            if (top + node.offsetHeight <= st + 1) continue;
            if (top >= sb) break;
            if (first < 0) first = i;
            last = i;
        }
        return [
            first,
            last
        ];
    }
    trimBlock() {
        const n = this.order.length;
        if (n <= this.MAX_WINDOW) return;
        const [first, last] = this.visibleSpan();
        if (first < 0) return;
        const c = this.container;
        const excess = n - (this.MAX_WINDOW - this.CHUNK);
        const keepBeyond = Math.floor(this.CHUNK / 2);
        const above = first, below = n - 1 - last;
        const holds = (ids)=>ids.some((idx)=>this.holdsFullscreen(this.cache.get(idx)));
        if (above >= below) {
            const d = Math.min(excess, above - keepBeyond);
            if (d <= 0 || holds(this.order.slice(0, d))) return;
            const before = c.scrollHeight;
            const top = c.scrollTop;
            for (const idx of this.order.splice(0, d))this.removeRow(idx);
            this.plo = this.seqPos(this.order[0]);
            const shrunk = before - c.scrollHeight;
            if (shrunk !== 0) {
                c.scrollTop = top - shrunk;
                this.prevScrollTop = c.scrollTop;
            }
        } else {
            const d = Math.min(excess, below - keepBeyond);
            if (d <= 0 || holds(this.order.slice(n - d))) return;
            for (const idx of this.order.splice(n - d))this.removeRow(idx);
            this.phi = this.seqPos(this.order[this.order.length - 1]);
        }
    }
    jumpToPosition(p, { flashId =null , offset =8  } = {}) {
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
        this.requestBlock(Math.max(0, p - back), Math.min(len - 1, p + this.CHUNK), {
            kind: 'jump',
            target: p,
            offset,
            flashId
        });
    }
    flash(id) {
        const node = this.nodeById.get(id);
        if (!node) return;
        node.classList.remove('bt-jump-flash');
        void node.offsetWidth;
        node.classList.add('bt-jump-flash');
        setTimeout(()=>node.classList.remove('bt-jump-flash'), 1800);
    }
    markReady() {
        if (this.ready) return;
        this.ready = true;
        this.paneEl = this.container.closest('.bt-chatpane');
        if (this.paneEl) this.paneEl.dataset.btSettled = '1';
        this.announceSettle('bt-chat-settled');
    }
    announceSettle(name) {
        const pid = this.paneEl?.dataset.panePid || '';
        window.dispatchEvent(new CustomEvent(name, {
            detail: pid
        }));
    }
    applyVisibility(idx, node = this.cache.get(idx)) {
        if (!node) return;
        node.style.display = this.hiddenTypes.has(this.keyByIdx.get(idx)) ? 'none' : '';
    }
    captureAnchor(excludeKey = null) {
        const st = this.container.scrollTop;
        for (const idx of this.order){
            const n = this.cache.get(idx);
            if (!n || n.offsetParent === null) continue;
            if (excludeKey && n.dataset.filterKey === excludeKey) continue;
            if (n.offsetTop + n.offsetHeight > st + 4) return {
                idx,
                off: n.offsetTop - st
            };
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
    syncRowHeights() {
        for (const idx of this.order){
            const node = this.cache.get(idx);
            if (node) node.__btH = node.getBoundingClientRect().height;
        }
    }
    bodyReserve(node) {
        if (!node.collapsable) return null;
        const map = node.__btBodyH;
        const sizes = map ? Object.entries(map) : [];
        if (sizes.length) {
            const w = this.bodyWidth();
            for (const [k, h] of sizes)if (Math.abs(+k - w) <= 2) return {
                height: h + 'px'
            };
        }
        const m = node.__btMedia;
        if (m && m[0] > 0 && m[1] > 0) return {
            boxSizing: 'content-box',
            padding: (node.__btMediaExtra || 0) + 'px 0 0',
            width: m[0] + 'px',
            maxWidth: '100%',
            aspectRatio: m[0] + ' / ' + m[1],
            overflow: 'hidden'
        };
        return null;
    }
    bodyWidth() {
        return Math.round(this.container.clientWidth);
    }
    scheduleBodyReport(node) {
        clearTimeout(node.__btBodyTimer);
        node.__btBodyTimer = setTimeout(()=>this.reportBody(node), 800);
    }
    reportBody(node) {
        node.__btBodyTimer = null;
        if (this.destroyed || !this.paneVisible || !node.isConnected || this.container.clientHeight === 0) return;
        const body = node.collapsable?.body;
        const id = node.dataset.msgId;
        if (!id || !body || body.offsetParent === null || body.childElementCount === 0) return;
        if (body.querySelector(':scope > .bt-collapsable-loading')) return;
        const content = this.bodyContentHeight(body);
        const h = Math.round(content);
        const w = this.bodyWidth();
        if (w < 1 || h < 1) return;
        const map = node.__btBodyH || {};
        for (const k of Object.keys(map)){
            if (Math.abs(+k - w) > 2) continue;
            if (Math.abs(map[k] - h) <= 1) return;
            delete map[k];
        }
        map[w] = h;
        node.__btBodyH = map;
        const pics = body.querySelectorAll('.bt-media-wrap');
        const extra = pics.length === 1 ? Math.min(h, Math.max(0, Math.round(content - pics[0].getBoundingClientRect().height))) : 0;
        node.__btMediaExtra = extra;
        this.comm.notify({
            type: 'tool.size',
            id,
            w,
            h,
            extra
        });
    }
    bodyContentHeight(body) {
        const cs = getComputedStyle(body);
        return body.getBoundingClientRect().height - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom) - parseFloat(cs.borderTopWidth) - parseFloat(cs.borderBottomWidth);
    }
    freeBody(node) {
        if (!this.paneVisible) return;
        if (!node.isConnected || node.dataset.btFreed || node.dataset.btApp) return;
        if (node.classList.contains('bt-tool-live') || this.holdsFullscreen(node)) return;
        const c = node.collapsable;
        const body = c?.body;
        if (!body || !c.loaded || body.offsetParent === null || body.childElementCount === 0) return;
        if (body.querySelector(':scope > .bt-collapsable-loading')) return;
        if (body.querySelector('img, video, audio')) return;
        const weight = body.getElementsByTagName('*').length - body.querySelectorAll('.bt-l span').length;
        if (!body.querySelector('.monaco-editor') && weight < 300) return;
        const h = this.bodyContentHeight(body);
        node.dataset.btFreed = '1';
        CODE_OBSERVERS.get(this.container)?.forget(body);
        body.innerHTML = '<div class="bt-collapsable-loading bt-body-freed">loading…</div>';
        const ph = body.firstElementChild;
        ph.style.boxSizing = 'border-box';
        ph.style.height = h + 'px';
    }
    unfreeBody(node) {
        delete node.dataset.btFreed;
        this.comm.notify({
            type: 'tool.render',
            id: node.dataset.msgId
        });
    }
    onBodyMounted(node) {
        this.freeObserver.unobserve(node);
        this.freeObserver.observe(node);
    }
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
        this.thumbMoves = null;
        this.thumbRange = -1;
        this.railLabel = label;
        const fracAt = (clientY)=>{
            const r = rail.getBoundingClientRect();
            const th = thumb.offsetHeight;
            return Math.min(1, Math.max(0, (clientY - r.top - th / 2) / Math.max(1, r.height - th)));
        };
        this.onRailDown = (e)=>{
            if (e.button !== 0) return;
            e.preventDefault();
            e.stopPropagation();
            rail.setPointerCapture(e.pointerId);
            this.markUserInput();
            this.cancelMomentum();
            const tr = thumb.getBoundingClientRect();
            const grab = e.target === thumb ? e.clientY - (tr.top + tr.height / 2) : 0;
            this.railDrag = {
                pointerId: e.pointerId,
                grab,
                pos: null,
                timer: null
            };
            this.scrollbarDrag = true;
            rail.classList.add('bt-rail-active');
            this.railMove(fracAt(e.clientY - grab));
        };
        this.onRailMove = (e)=>{
            const d = this.railDrag;
            if (!d || e.pointerId !== d.pointerId) return;
            e.preventDefault();
            this.railMove(fracAt(e.clientY - d.grab));
        };
        this.onRailUp = (e)=>{
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
        this.onRailWheel = (e)=>{
            e.preventDefault();
            this.markUserInput();
            const line = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? this.container.clientHeight : 1;
            this.container.scrollTop += e.deltaY * line;
        };
        rail.addEventListener('pointerdown', this.onRailDown);
        rail.addEventListener('pointermove', this.onRailMove);
        rail.addEventListener('pointerup', this.onRailUp);
        rail.addEventListener('pointercancel', this.onRailUp);
        rail.addEventListener('wheel', this.onRailWheel, {
            passive: false
        });
        this.keyScope = false;
        this.onScopePointer = (e)=>{
            this.keyScope = wrap.contains(e.target);
        };
        this.onEndsKey = (e)=>{
            const findKey = e.key === 'F3' || (e.ctrlKey || e.metaKey) && (e.key.toLowerCase() === 'f' || e.key.toLowerCase() === 'g');
            if (!findKey && e.key !== 'Home' && e.key !== 'End') return;
            if (this.destroyed || !this.paneVisible || this.container.clientHeight === 0) return;
            if (findKey && !e.defaultPrevented && !e.target.closest?.('.monaco-editor')) {
                this.markUserInput();
                this.setFollowMode(false);
                return;
            }
            if (e.key !== 'Home' && e.key !== 'End') return;
            if (e.altKey || e.metaKey || e.shiftKey || e.defaultPrevented) return;
            const t = e.target;
            const page = t === document.body || t === document.documentElement;
            if (!(wrap.contains(t) || page && this.keyScope)) return;
            if (t.isContentEditable || t.closest && t.closest('input, textarea, select, .monaco-editor')) return;
            const len = this.seqLength();
            if (len === 0) return;
            e.preventDefault();
            this.markUserInput();
            if (e.key === 'Home') this.jumpToPosition(0, {
                offset: Infinity
            });
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
        this.thumbMoves = null;
        this.thumbRange = -1;
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
        d.timer = setTimeout(()=>{
            if (this.railDrag !== d) return;
            d.jumped = p;
            this.jumpToPosition(p);
        }, 150);
    }
    placeThumb(f) {
        const range = Math.max(0, this.railEl.clientHeight - this.railThumb.offsetHeight);
        if (this.thumbRange !== range) {
            this.thumbRange = range;
            for (const a of this.thumbMoves ?? [])a.cancel();
            this.thumbMoves = [
                this.railThumb,
                this.railLabel
            ].map((el)=>{
                const a = el.animate([
                    {
                        transform: 'translateY(0px)'
                    },
                    {
                        transform: `translateY(${range}px)`
                    }
                ], {
                    duration: 1000,
                    fill: 'both',
                    easing: 'linear'
                });
                a.pause();
                return a;
            });
        }
        const t = range > 0 ? Math.round(f * range) / range * 1000 : 0;
        for (const a of this.thumbMoves)a.currentTime = t;
    }
    updateRail() {
        if (!this.paneVisible) return;
        const rail = this.railEl;
        if (!rail || this.railDrag) return;
        const c = this.container;
        const len = this.seqLength();
        const fits = len === 0 || this.plo <= 0 && this.atTail() && c.scrollHeight <= c.clientHeight + 1;
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
            const into = node.offsetHeight > 0 ? Math.min(1, Math.max(0, (c.scrollTop - node.offsetTop) / node.offsetHeight)) : 0;
            f = Math.min(1, (this.seqPos(idx) + into) / Math.max(1, len - 1));
        }
        this.placeThumb(f);
    }
    holdsFullscreen(node) {
        if (!node) return false;
        const fs = document.fullscreenElement || document.webkitFullscreenElement;
        if (fs && (node === fs || node.contains(fs))) return true;
        for (const v of node.querySelectorAll('video')){
            if (v.webkitDisplayingFullscreen || v.webkitPresentationMode === 'fullscreen') return true;
        }
        return false;
    }
    fullscreenActive() {
        return this.holdsFullscreen(this.container) || !!(document.fullscreenElement || document.webkitFullscreenElement);
    }
    touchApp(idx) {
        const node = this.cache.get(idx);
        if (!node || node.dataset.btSpilled) return;
        const i = this.appLru.indexOf(idx);
        if (i !== -1) this.appLru.splice(i, 1);
        this.appLru.push(idx);
    }
    enforceAppLru() {
        const offscreen = this.appLru.filter((idx)=>!this.visibleApps.has(idx));
        let extra = offscreen.length - this.APP_KEEPALIVE;
        for (const idx of offscreen){
            if (extra <= 0) break;
            const node = this.cache.get(idx);
            if (!node || this.holdsFullscreen(node)) continue;
            this.spillApp(idx, node);
            extra--;
        }
    }
    spillApp(idx, node) {
        const slot = node.querySelector('.bt-slot') || node.querySelector('.bt-tool-body');
        const li0 = this.appLru.indexOf(idx);
        if (!slot || slot.childElementCount === 0) {
            if (li0 !== -1) this.appLru.splice(li0, 1);
            return;
        }
        const canvas = node.querySelector('canvas');
        let dataUrl = null;
        if (canvas) {
            try {
                dataUrl = canvas.toDataURL('image/png');
            } catch (error) {
                if (error.name !== 'SecurityError') throw error;
                console.warn('app snapshot refused:', error.message);
            }
        }
        if (slot) {
            const h = Math.max(40, slot.offsetHeight);
            const cssW = canvas ? canvas.clientWidth : 0, cssH = canvas ? canvas.clientHeight : 0;
            slot.innerHTML = '';
            const wrap = document.createElement('div');
            wrap.className = 'bt-app-snapshot';
            wrap.style.cssText = `position:relative;max-width:100%;height:${h}px;overflow:hidden`;
            if (dataUrl) {
                const img = document.createElement('img');
                img.src = dataUrl;
                img.alt = 'app snapshot';
                img.style.cssText = `width:${cssW}px;height:${cssH}px;max-width:100%;object-fit:contain;display:block;` + 'border-radius:6px;filter:saturate(.85) brightness(.97)';
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
        const li = this.appLru.indexOf(idx);
        if (li !== -1) this.appLru.splice(li, 1);
    }
    reloadApp(node) {
        delete node.dataset.btSpilled;
        this.touchApp(node.__btIdx);
        const id = node.dataset.msgId;
        const body = node.querySelector('.bt-tool-body');
        if (body) {
            showLoading(body, {
                height: body.offsetHeight + 'px'
            });
        }
        if (id) this.comm.notify({
            type: 'tool.render',
            id
        });
    }
    bodyDied(row) {
        if (this.destroyed || row.dataset.btSpilled || row.dataset.btFreed) return;
        row.dataset.btRemount = '1';
        if (row.isConnected) queueMicrotask(()=>this.mountDeferred(row));
    }
    requestBody(node) {
        node.dataset.btWantsBody = '1';
        this.mountObserver.unobserve(node);
        this.mountObserver.observe(node);
    }
    mountDeferred(node) {
        if (node.dataset.btAutoExpand) {
            delete node.dataset.btAutoExpand;
            const c = node.collapsable;
            c?.setExpanded(true);
            if (c && c.lazy && !c.loaded) {
                c.loaded = true;
                c.showPlaceholder();
                this.requestBody(node);
            }
        }
        if (node.dataset.btAutoMount) {
            delete node.dataset.btAutoMount;
            if (node.collapsable && !node.collapsable.loaded) {
                node.collapsable.loaded = true;
                const body = node.collapsable.body;
                if (body.childElementCount === 0 && this.bodyReserve(node)) node.collapsable.showPlaceholder();
                this.requestBody(node);
            }
        }
        if (node.dataset.btRemount) {
            delete node.dataset.btRemount;
            this.requestBody(node);
        }
    }
    appendNewMessage(msg) {
        const idx = this.totalCount - 1;
        if (!this.cache.has(idx)) {
            if (this.seq) this.seq.push(idx);
            if (this.seqPos(idx) === this.phi + 1) {
                const nodes = this.insertRows([
                    [
                        idx,
                        msg
                    ]
                ], this.rowsEnd);
                this.order.push(idx);
                this.phi += 1;
                this.adoptRows(nodes);
            }
        }
        if (this.followMode) {
            this.scrollToBottom();
        } else {
            this.registerUnread();
            this.updateRail();
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
        this.setCancelling(false);
        this.thinkingEl?.classList.remove('bt-thinking-active');
        this.busyEl?.classList.remove('bt-busy-active');
        this.busyEl?.classList.remove('bt-busy-suppressed');
        this.cancelPendingScroll();
        for (const node of this.nodeById.values()){
            node.classList?.remove('bt-stream-active');
        }
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
        }
        if (node.collapsable?.expanded && node.querySelector('.bt-tool-body .bt-tool-loading')) this.requestBody(node);
        if (msg.reopen) {
            delete node.dataset.toolFinished;
            node.classList.add('bt-tool-live');
            this.ensureElapsedTicker();
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
                        this.requestBody(node);
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
                    this.requestBody(node);
                }
                node.collapsable.setExpanded(true);
            } else {
                node.dataset.btAutoExpand = '1';
            }
        }
        const headerEl = node.querySelector('.bt-tool-header');
        !node.dataset.toolFinished && ![
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
        if (msg.worker && headerEl && !headerEl.querySelector('.bt-tool-worker')) {
            const wb = document.createElement('span');
            wb.className = 'bt-tool-worker';
            wb.title = 'This runs on another worker';
            wb.textContent = `⇢ ${String(msg.worker)}`;
            const title = headerEl.querySelector('.bt-tool-title');
            headerEl.insertBefore(wb, title ? title.nextSibling : null);
        }
        if (Array.isArray(msg.jumps) && headerEl) {
            headerEl.querySelectorAll('.bt-tool-jump').forEach((b)=>b.remove());
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
            const became = !node.dataset.btApp;
            node.dataset.btApp = '1';
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
        if (msg.editable && msg.edit_path && headerEl) {
            const t = headerEl.querySelector('.bt-tool-title');
            if (t) {
                t.classList.add('bt-path-link');
                t.dataset.path = msg.edit_path;
                t.title = msg.edit_path;
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
        this.ensureWindow();
    }
    setKeyHidden(key, hidden) {
        const anchor = this.followMode ? null : this.captureAnchor(key);
        this.hiddenTypes[hidden ? 'add' : 'delete'](key);
        for (const [idx, node] of this.cache){
            if (node.dataset.filterKey === key) this.applyVisibility(idx, node);
        }
        if (key === 'agent') this.updateWaiting();
        if (this.followMode) this.queueScrollToBottom();
        else this.restoreAnchor(anchor);
        this.syncRowHeights();
        this.ensureWindow();
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
                        if (a.kind === 'file') {
                            const link = document.createElement('a');
                            link.className = 'bt-user-att-file';
                            link.href = a.url;
                            link.target = '_blank';
                            link.rel = 'noopener';
                            link.textContent = a.name.replace(/^\d{4}-\d{2}-\d{2}_\d{6}_[0-9a-f]{8}_/, '');
                            link.title = a.name;
                            link.addEventListener('click', (e)=>e.stopPropagation());
                            gallery.appendChild(link);
                            continue;
                        }
                        const img = document.createElement('img');
                        img.className = 'bt-user-att-img';
                        img.src = a.url;
                        img.alt = a.name || 'attachment';
                        img.dataset.attachmentName = a.name;
                        img.loading = 'lazy';
                        img.addEventListener('click', (e)=>{
                            e.stopPropagation();
                            openLightbox(img);
                        });
                        img.addEventListener('error', ()=>{
                            const miss = document.createElement('span');
                            miss.className = 'bt-user-att-missing';
                            miss.textContent = a.name || 'attachment';
                            img.replaceWith(miss);
                        }, {
                            once: true
                        });
                        const wrap = document.createElement('div');
                        wrap.className = 'bt-media-wrap';
                        wrap.appendChild(img);
                        const actions = document.createElement('div');
                        actions.className = 'bt-media-actions';
                        const enlarge = document.createElement('button');
                        enlarge.type = 'button';
                        enlarge.className = 'bt-media-action bt-media-enlarge';
                        enlarge.title = 'Enlarge';
                        enlarge.textContent = '⤢';
                        enlarge.addEventListener('click', (e)=>{
                            e.stopPropagation();
                            openLightbox(img);
                        });
                        const choose = document.createElement('button');
                        choose.type = 'button';
                        choose.className = 'bt-media-action bt-media-chat-icon';
                        choose.title = 'Set as chat icon';
                        choose.textContent = '▣';
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
                    div.addEventListener('monaco-editor-disposed', ()=>this.bodyDied(div));
                    div.__btBodyH = msg.body_h || null;
                    div.__btMedia = msg.media || null;
                    div.__btMediaExtra = msg.media_extra || 0;
                    div.collapsable = new Collapsable(div.querySelector('.bt-tool-header'), div.querySelector('.bt-tool-body'), {
                        toggleEl: div.querySelector('.bt-tool-toggle'),
                        editMode: compactBody,
                        hideBodyOnCollapse: msg.compact_body === true,
                        fetchEachExpand: !compactBody,
                        discardOnCollapse: !compactBody,
                        reserve: ()=>this.bodyReserve(div),
                        onToggle: (expanded)=>this.expandState.set(id, expanded),
                        onExpand: ()=>this.requestBody(div)
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
                    const mine = this.expandState.get(id);
                    if (mine === true) {
                        if (div.collapsable.editMode) div.dataset.btAutoMount = '1';
                        div.dataset.btAutoExpand = '1';
                    } else if (mine === false) {
                        delete div.dataset.btAutoExpand;
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
        const server = msg.server ? `<span class="bt-tool-server">${escapeHTML(msg.server)}</span>` : '';
        const timeoutBadge = msg.timeout_s ? `<span class="bt-tool-timeout" title="Soft eval timeout — the call checkpoints with partial output at this cadence">⏱ ${escapeHTML(String(msg.timeout_s))}</span>` : '';
        const workerBadge = msg.worker ? `<span class="bt-tool-worker" title="This runs on another worker">⇢ ${escapeHTML(String(msg.worker))}</span>` : '';
        const jumpChips = jumpChipsHTML(msg.jumps);
        const stopBtn = msg.stoppable ? `<button class="bt-tool-stop bt-stop-mini${msg.dismiss_only ? ' bt-task-dismiss' : ''}" type="button"
                     title="${msg.dismiss_only ? 'Dismiss task entry (does not stop the agent)' : 'Stop'}"
                     aria-label="${msg.dismiss_only ? 'Dismiss task entry' : 'Stop'}">${msg.dismiss_only ? '×' : ''}</button>` : '';
        const titleLink = msg.edit_path ? ` bt-path-link" data-path="${escapeAttr(msg.edit_path)}" title="${escapeAttr(msg.edit_path)}` : '';
        !(msg.status === 'completed' || msg.status === 'failed') && msg.finished_at == null;
        const cmdPreview = msg.command ? `
            <div class="bt-cmd-preview"><pre>${escapeHTML(msg.command)}</pre></div>` : '';
        return `
            <div class="bt-tool-header" data-expanded="false"${msg.command ? ` title="${escapeAttr(msg.command)}"` : ''}>
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
            const storedTodo = storage.get('bt-todo-collapsed');
            const paneW = this.container.closest('.bt-chatpane')?.clientWidth ?? window.innerWidth;
            this.taskbarEl.classList.toggle('bt-todo-collapsed', storedTodo != null ? storedTodo === '1' : paneW < 660);
            this.onTaskbarClick = (ev)=>{
                if (ev.target.closest('.bt-taskbar-todo-toggle')) {
                    const c = this.taskbarEl.classList.toggle('bt-todo-collapsed');
                    storage.set('bt-todo-collapsed', c ? '1' : '0');
                    return;
                }
                if (ev.target.closest('.bt-taskbar-slot-stop')) return;
                const slot = ev.target.closest('.bt-taskbar-slot');
                if (!slot) return;
                this.jumpToMessage(parseInt(slot.dataset.msgIndex ?? '-1', 10), slot.dataset.taskId);
            };
            this.taskbarEl.addEventListener('click', this.onTaskbarClick);
        }
    }
    jumpToMessage(idx, id) {
        if (!Number.isInteger(idx) || idx < 0 || idx >= this.totalCount) return;
        if (this.seqPos(idx) < 0) {
            this.lensClearAll();
            this.pendingJump = {
                idx,
                id
            };
            return;
        }
        this.jumpToPosition(this.seqPos(idx), {
            flashId: id || null,
            offset: 60
        });
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
        const anchor = this.lensActive && !msg.active && !this.followMode ? this.captureAnchor() : null;
        if (!msg.active) {
            this.lensActive = false;
            this.seq = null;
            this.lensActions = null;
        } else {
            this.lensActive = true;
            this.seq = (msg.visible || []).slice().sort((a, b)=>a - b);
            this.lensActions = new Map(Object.entries(msg.actions || {}).map(([k, v])=>[
                    +k,
                    v
                ]));
        }
        if (this.lensClearBtn) this.lensClearBtn.hidden = !this.lensActive;
        this.lensBarEl?.classList.toggle('bt-lens-on', this.lensActive);
        const len = this.seqLength();
        const jump = this.pendingJump;
        this.pendingJump = null;
        if (jump && this.seqPos(jump.idx) >= 0) {
            this.clearBlock();
            this.jumpToPosition(this.seqPos(jump.idx), {
                flashId: jump.id || null,
                offset: 60
            });
        } else if (this.lensActive) {
            this.clearBlock();
            if (len === 0) {
                this.updateRail();
                return;
            }
            this.requestBlock(0, Math.min(len - 1, this.CHUNK - 1), {
                kind: 'lens'
            });
        } else if (anchor && this.seqPos(anchor.idx) >= 0) {
            const p = anchor.idx;
            this.clearBlock();
            this.requestBlock(Math.max(0, p - this.CHUNK), Math.min(len - 1, p + this.CHUNK), {
                kind: 'restore',
                idx: anchor.idx,
                off: anchor.off
            });
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
        if (!this.paneVisible) return false;
        const { scrollTop , scrollHeight , clientHeight  } = this.container;
        return scrollHeight - scrollTop - clientHeight < this.AT_BOTTOM_PX;
    }
    lastMessageFullyOutOfView() {
        if (!this.paneVisible) return true;
        if (this.totalCount === 0) return false;
        const node = this.cache.get(this.totalCount - 1);
        if (!node || !node.isConnected || node.offsetParent === null) return true;
        return node.getBoundingClientRect().top >= this.container.getBoundingClientRect().bottom;
    }
    queueScrollToBottom() {
        if (this.scrollbarDrag) return;
        if (this.scrollQueued || this.destroyed || !this.paneVisible) return;
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
        if (!this.paneVisible || this.container.clientHeight === 0) return;
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
        if (this.destroyed || !this.paneVisible || this.scrollbarDrag) return;
        if (this.blockEmpty() || !this.atTail()) {
            if (this.pending.block?.kind !== 'tail') this.loadTail();
            return;
        }
        this.container.scrollTop = this.container.scrollHeight;
        this.prevScrollTop = this.container.scrollTop;
        this.ensureWindow();
    }
    onHidden() {
        this.projectVisible = false;
        this.updateVisibility();
    }
    onShown() {
        this.projectVisible = true;
        this.updateVisibility(true);
    }
    updateVisibility(restore = false) {
        const visible = this.projectVisible && this.workspaceVisible;
        if (visible && (restore || !this.paneVisible)) this.showPane();
        else if (!visible && this.paneVisible) this.hidePane();
    }
    hidePane() {
        if (!this.paneVisible) return;
        this.cancelShowRestore();
        if (this.cancelMomentum) this.cancelMomentum();
        this.cancelPendingScroll();
        if (this.setOverscroll) this.setOverscroll(0);
        this.savedScrollTop = this.container.scrollTop;
        this.savedFollowMode = this.followMode;
        this.savedAnchor = this.captureAnchor();
        this.paneVisible = false;
    }
    cancelShowRestore() {
        cancelAnimationFrame(this.showRestoreRaf);
        this.showRestoreRaf = 0;
        for (const timer of this.showRestoreTimers)clearTimeout(timer);
        this.showRestoreTimers = [];
    }
    showPane() {
        this.cancelShowRestore();
        this.paneVisible = true;
        const followNow = !!this.followMode;
        const followThen = !!this.savedFollowMode;
        const wantBottom = followNow || followThen;
        const savedTop = this.savedScrollTop;
        const anchor = this.savedAnchor;
        const apply = ()=>{
            if (this.destroyed || !this.paneVisible) return;
            if (wantBottom) {
                if (this.followMode) this.scrollToBottom();
                this.updateScrollAffordance(this.atBottom());
                return;
            }
            const n = anchor ? this.cache.get(anchor.idx) : null;
            if (n && n.isConnected && n.offsetParent !== null) {
                this.container.scrollTop = n.offsetTop - anchor.off;
            } else if (savedTop != null) {
                this.container.scrollTop = savedTop;
            }
            this.prevScrollTop = this.container.scrollTop;
            this.ensureWindow();
            this.updateScrollAffordance(this.atBottom());
        };
        apply();
        this.showRestoreRaf = requestAnimationFrame(apply);
        this.showRestoreTimers = [
            setTimeout(apply, 50),
            setTimeout(apply, 200)
        ];
    }
    setupInputs() {
        if (this.destroyed) return;
        const app = this.container?.closest('.bt-app') || this.container?.parentElement;
        if (!app) return;
        this.app = app;
        this.inputArea = app.querySelector('.bt-input-area');
        this.textInput = app.querySelector('.bt-text-input');
        if (!this.inputArea || !this.textInput) return;
        if (!CSS.supports('field-sizing', 'content')) {
            this.textInput.dataset.btSizingFallback = '';
            const mirror = document.createElement('textarea');
            mirror.className = 'bt-input-measure';
            mirror.tabIndex = -1;
            mirror.setAttribute('aria-hidden', 'true');
            this.inputArea.appendChild(mirror);
            this.inputMeasure = mirror;
            this.onInputResize = ()=>{
                if (this.inputResizeFrame) return;
                this.inputResizeFrame = requestAnimationFrame(()=>{
                    this.inputResizeFrame = null;
                    if (this.destroyed || !this.textInput.clientWidth) return;
                    mirror.style.width = this.textInput.clientWidth + 'px';
                    mirror.value = this.textInput.value;
                    const height = mirror.scrollHeight + 2 + 'px';
                    if (this.textInput.style.height !== height) this.textInput.style.height = height;
                });
            };
            this.textInput.addEventListener('input', this.onInputResize);
            this.textInput.addEventListener('bt-composer-resize', this.onInputResize);
            let width = 0;
            this.inputWidthObserver = new ResizeObserver((entries)=>{
                const next = entries[0].contentRect.width;
                if (width === next) return;
                width = next;
                this.onInputResize();
            });
            this.inputWidthObserver.observe(this.textInput);
            this.onInputResize();
        }
        this.attachBar = document.createElement('div');
        this.attachBar.className = 'bt-attachments';
        this.inputArea.insertBefore(this.attachBar, this.inputArea.firstChild);
        this.attachments = new Map();
        this.attachIdCounter = 0;
        this.ATTACH_MAX_BYTES = 5 * 1024 * 1024;
        this.INLINE_IMAGE_TYPES = new Set([
            'image/png',
            'image/jpeg',
            'image/jpg',
            'image/gif',
            'image/webp',
            'image/svg+xml'
        ]);
        this.FILE_MAX_BYTES = 2 * 1024 * 1024 * 1024;
        this.UPLOAD_CHUNK_BYTES = 512 * 1024;
        this.ATTACH_MAX_COUNT = 10;
        this.attachPending = 0;
        this.onPaste = (e)=>{
            const items = e.clipboardData?.items;
            if (!items) return;
            for (const it of items){
                if (it.kind !== 'file') continue;
                const blob = it.getAsFile();
                if (blob) this.attachAdd(blob, `pasted-${Date.now()}`);
            }
        };
        this.textInput.addEventListener('paste', this.onPaste);
        this.onDragOver = (e)=>{
            if (!this.dragHasFiles(e)) return;
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
            for (const f of files)this.attachAdd(f, `dropped-${Date.now()}`);
        };
        this.app.addEventListener('dragover', this.onDragOver);
        this.app.addEventListener('dragleave', this.onDragLeave);
        this.app.addEventListener('drop', this.onDrop);
        this.onAppClickCapture = (e)=>{
            if (this.destroyed) return;
            const modeOption = e.target.closest('.bt-send-mode-option');
            const queueAction = e.target.closest('[data-queue-action]');
            const modeMenu = this.app.querySelector('.bt-send-mode-menu');
            if (modeMenu && !e.target.closest('.bt-send-mode')) {
                modeMenu.hidden = true;
                this.app.querySelector('.bt-send-mode-trigger')?.setAttribute('aria-expanded', 'false');
            }
            if (modeOption) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this.sendMode = modeOption.dataset.sendMode;
                const trigger = this.app.querySelector('.bt-send-mode-trigger');
                trigger.querySelector('.bt-send-mode-label').textContent = ({
                    done: 'Queue when done',
                    next: 'Queue after message',
                    interrupt: 'Interrupt + send'
                })[this.sendMode];
                trigger.title = modeOption.textContent;
                trigger.setAttribute('aria-label', trigger.title);
                trigger.setAttribute('aria-expanded', 'false');
                modeMenu.hidden = true;
                for (const option of modeMenu.children)option.setAttribute('aria-checked', String(option === modeOption));
            } else if (e.target.closest('.bt-send-mode-trigger')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                modeMenu.hidden = !modeMenu.hidden;
                e.target.closest('button').setAttribute('aria-expanded', String(!modeMenu.hidden));
            } else if (queueAction) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this.comm.notify({
                    type: 'queue.action',
                    id: queueAction.dataset.queueId,
                    action: queueAction.dataset.queueAction
                });
            } else if (e.target.closest('.bt-send-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this.submit();
            } else if (e.target.closest('.bt-stop-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this.cancel();
            } else if (e.target.closest('.bt-force-stop-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this.cancel(true);
            } else if (e.target.closest('.bt-attach-btn')) {
                e.preventDefault();
                e.stopImmediatePropagation();
                this.app.querySelector('.bt-attach-input')?.click();
            }
        };
        this.app.addEventListener('click', this.onAppClickCapture, true);
        this.onAppChange = (e)=>{
            if (this.destroyed) return;
            const input = e.target.closest('.bt-attach-input');
            if (!input || !input.files) return;
            for (const f of input.files)this.attachAdd(f, `picked-${Date.now()}`);
            input.value = '';
            this.textInput?.focus();
        };
        this.app.addEventListener('change', this.onAppChange);
        const pid = app.closest('.bt-chatpane')?.dataset.panePid;
        if (pid) {
            const key = 'bt-draft:' + pid;
            const yolo = ()=>this.textInput.classList.contains('bt-text-input-yolo');
            const saved = storage.get(key);
            if (saved && !this.textInput.value && !yolo()) {
                this.textInput.value = saved;
                this.textInput.dispatchEvent(new Event('input', {
                    bubbles: true
                }));
            }
            this.flushDraft = ()=>{
                clearTimeout(this.draftTimer);
                if (this.pendingDraft === undefined) return;
                const text = this.pendingDraft;
                this.pendingDraft = undefined;
                text.trim() ? storage.set(key, text) : storage.remove(key);
            };
            this.onDraftInput = ()=>{
                if (yolo()) return;
                this.pendingDraft = this.textInput.value;
                clearTimeout(this.draftTimer);
                if (!this.pendingDraft.trim()) this.flushDraft();
                else this.draftTimer = setTimeout(this.flushDraft, 250);
            };
            this.onDraftVisibility = ()=>{
                if (document.visibilityState === 'hidden') this.flushDraft();
            };
            this.textInput.addEventListener('input', this.onDraftInput);
            this.textInput.addEventListener('blur', this.flushDraft);
            window.addEventListener('pagehide', this.flushDraft);
            document.addEventListener('visibilitychange', this.onDraftVisibility);
        }
        this.onCompositionStart = ()=>{
            this.inputComposing = true;
        };
        this.onCompositionEnd = ()=>{
            this.inputComposing = false;
        };
        this.textInput.addEventListener('compositionstart', this.onCompositionStart);
        this.textInput.addEventListener('compositionend', this.onCompositionEnd);
        this.onTextInputKeyCapture = (e)=>{
            if (e.isComposing || this.inputComposing || e.keyCode === 229) return;
            const mobile = matchMedia('(pointer: coarse)').matches || navigator.userAgentData?.mobile || /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
            if (e.key === 'Enter' && (mobile || e.shiftKey)) return;
            if (this.cmdAcHandleKey(e)) return;
            if (e.key !== 'Enter') return;
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
            this.textInput.dispatchEvent(new Event('input', {
                bubbles: true
            }));
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
            if (e.key !== 'Escape' || e.repeat || e.isComposing || this.inputComposing || e.keyCode === 229) return;
            if (!this.container.isConnected) {
                this.lazyDestroy();
                return;
            }
            if (!this.paneVisible || this.container.offsetParent === null) return;
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
    cancel(force = false) {
        this.comm.notify({
            type: 'cancel',
            seq: this.turnSeq ?? -1,
            force
        });
    }
    setCancelling(stopping) {
        this.cancelling = stopping;
        const status = this.app.querySelector('.bt-cancel-status');
        if (status) status.hidden = !stopping;
        const stop = this.app.querySelector('.bt-stop-btn');
        if (stop) stop.title = stopping ? 'Stopping the agent. Use Force stop if it does not respond.' : 'Stop generation and pause queued messages';
    }
    dragHasFiles(e) {
        const dt = e.dataTransfer;
        if (!dt) return false;
        if (dt.types) {
            for (const t of dt.types)if (t === 'Files') return true;
        }
        return false;
    }
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
            this.showAttachError(`${filename} is too large (${formatBytes(file.size)}, ` + `at most ${formatBytes(this.FILE_MAX_BYTES)})`);
            return;
        }
        const pid = this.app.closest('.bt-chatpane')?.dataset.panePid;
        if (!pid) {
            this.showAttachError('Files can only be attached in a chat');
            return;
        }
        const id = `att-${++this.attachIdCounter}`;
        const bytes = crypto.getRandomValues(new Uint8Array(12));
        const item = {
            kind: 'file',
            file,
            filename,
            mime: file.type || '',
            size: file.size,
            pid,
            uploadId: Array.from(bytes, (b)=>b.toString(16).padStart(2, '0')).join(''),
            sent: 0,
            path: null,
            onWorker: false,
            error: null,
            removed: false
        };
        item.done = this.uploadFile(item);
        this.attachments.set(id, item);
        this.renderAttachments();
    }
    async uploadFile(item) {
        const url = (offset)=>`/attachment-upload/${encodeURIComponent(item.pid)}` + `?upload=${item.uploadId}&offset=${offset}&total=${item.size}` + `&name=${encodeURIComponent(item.filename)}`;
        try {
            let offset = 0;
            do {
                if (item.removed) return;
                const chunk = item.file.slice(offset, offset + this.UPLOAD_CHUNK_BYTES);
                const resp = await fetch(url(offset), {
                    method: 'POST',
                    body: chunk,
                    headers: {
                        'X-BT-Upload': '1'
                    }
                });
                if (!resp.ok) throw new Error((await resp.text()).trim() || `HTTP ${resp.status}`);
                const answer = await resp.json();
                offset = answer.received;
                item.sent = offset;
                if (answer.path) {
                    item.path = answer.path;
                    item.onWorker = answer.on_worker;
                }
                if (!this.destroyed) this.renderAttachments();
            }while (offset < item.size)
        } catch (error) {
            item.error = `Upload failed: ${error.message}`;
            if (!this.destroyed) this.renderAttachments();
        }
    }
    attachAddBlob(blob, mime, filename) {
        if (this.attachments.size + this.attachPending >= this.ATTACH_MAX_COUNT) {
            this.showAttachError(`At most ${this.ATTACH_MAX_COUNT} images per message`);
            return;
        }
        if (blob.size > this.ATTACH_MAX_BYTES) {
            this.showAttachError(`Image too large (${(blob.size / 1024 / 1024).toFixed(1)} MB, ` + `max ${this.ATTACH_MAX_BYTES / 1024 / 1024} MB)`);
            return;
        }
        const id = `att-${++this.attachIdCounter}`;
        const reader = new FileReader();
        this.attachPending++;
        reader.onload = ()=>{
            this.attachPending--;
            if (this.destroyed) return;
            this.attachments.set(id, {
                blob,
                mime,
                filename,
                dataUrl: reader.result
            });
            this.renderAttachments();
        };
        reader.onerror = ()=>{
            this.attachPending--;
            this.showAttachError('Failed to read image');
        };
        reader.readAsDataURL(blob);
    }
    attachRemove(id) {
        const item = this.attachments.get(id);
        this.attachments.delete(id);
        if (item?.kind === 'file' && !item.path) {
            item.removed = true;
            fetch(`/attachment-upload/${encodeURIComponent(item.pid)}?upload=${item.uploadId}`, {
                method: 'DELETE',
                headers: {
                    'X-BT-Upload': '1'
                }
            }).catch((e)=>console.warn('could not drop the partial upload', e));
        }
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
                wrap.dataset.attachId = id;
                if (item.kind === 'file') {
                    wrap.className = 'bt-attachment-file';
                    wrap.dataset.state = item.error ? 'error' : item.path ? 'done' : 'uploading';
                    const name = document.createElement('div');
                    name.className = 'bt-attachment-file-name';
                    name.textContent = item.filename;
                    name.title = item.filename;
                    const status = document.createElement('div');
                    status.className = 'bt-attachment-file-status';
                    status.textContent = item.error ? item.error : item.path ? formatBytes(item.size) : `Uploading ${Math.floor(100 * item.sent / Math.max(1, item.size))}% of ${formatBytes(item.size)}`;
                    const bar = document.createElement('div');
                    bar.className = 'bt-attachment-file-bar';
                    bar.style.width = `${item.path ? 100 : Math.floor(100 * item.sent / Math.max(1, item.size))}%`;
                    wrap.append(name, status, bar);
                } else {
                    wrap.className = 'bt-attachment-thumb';
                    const img = document.createElement('img');
                    img.src = item.dataUrl;
                    img.alt = item.filename || 'image';
                    img.title = item.filename || 'image';
                    wrap.appendChild(img);
                }
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
    renderQueue(msg) {
        const box = this.app.querySelector('.bt-message-queue');
        if (!box) return;
        const expanded = new Set([
            ...box.querySelectorAll('details[open]')
        ].map((e)=>e.dataset.queueId));
        box.replaceChildren();
        const items = msg.items || [];
        box.hidden = items.length === 0;
        if (!items.length) return;
        box.setAttribute('aria-label', `Pending messages (${items.length})`);
        for (const item of items){
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
            status.textContent = item.detail || (item.status === 'paused' ? 'Paused · not sent' : item.status === 'held' ? 'Goes out with your next message' : item.status === 'offline' ? 'Agent not reachable · sends once it is back' : item.status === 'sending' ? 'Connecting · not sent yet' : item.mode === 'interrupt' ? 'Waiting for interruption to finish' : item.mode === 'next' ? 'Waiting for the next message boundary' : 'Waiting until the agent finishes');
            const summary = document.createElement('summary');
            summary.className = 'bt-queue-summary';
            const preview = document.createElement('span');
            preview.className = 'bt-queue-preview';
            preview.textContent = item.text;
            const badge = document.createElement('span');
            badge.className = 'bt-queue-badge';
            badge.textContent = item.status === 'paused' ? 'Paused · not sent' : item.status === 'held' ? 'With your next message' : item.status === 'offline' ? 'Agent offline · queued' : item.status === 'sending' ? 'Sending…' : item.mode === 'interrupt' ? 'Interrupting…' : item.mode === 'next' ? 'Queued · next message' : 'Queued · when done';
            summary.title = status.textContent;
            summary.append(preview, badge);
            const detail = document.createElement('div');
            detail.className = 'bt-queue-detail';
            detail.append(text, status);
            row.append(summary, detail);
            const actions = document.createElement('div');
            actions.className = 'bt-queue-actions';
            for (const [action, label] of item.status === 'paused' ? [
                [
                    'send',
                    'Queue again'
                ],
                [
                    'remove',
                    'Remove'
                ]
            ] : item.status === 'held' ? [
                [
                    'send',
                    'Send now'
                ],
                [
                    'remove',
                    'Remove'
                ]
            ] : item.status === 'waiting' || item.status === 'offline' ? [
                [
                    'remove',
                    'Remove'
                ]
            ] : []){
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
        const yoloMode = this.textInput.classList.contains('bt-text-input-yolo');
        if (!yoloMode && text.trim() === '' && this.attachments.size === 0) return;
        if (this.submitting) return;
        const files = [
            ...this.attachments.values()
        ].filter((item)=>item.kind === 'file');
        if (files.some((item)=>!item.path && !item.error)) {
            this.submitting = true;
            try {
                await Promise.all(files.map((item)=>item.done));
            } finally{
                this.submitting = false;
            }
        }
        const failed = files.find((item)=>item.error);
        if (failed) {
            this.showAttachError(`${failed.filename}: ${failed.error}. Remove it to send.`);
            return;
        }
        const payload = [];
        for (const item of this.attachments.values()){
            if (item.kind === 'file') {
                payload.push({
                    kind: 'file',
                    path: item.path,
                    filename: item.filename,
                    on_worker: item.onWorker
                });
                continue;
            }
            const buf = await item.blob.arrayBuffer();
            payload.push({
                mime: item.mime,
                filename: item.filename || '',
                data: arrayBufferToBase64(buf)
            });
        }
        this.comm.notify({
            type: 'send',
            text: this.textInput.value,
            attachments: payload,
            mode: this.sendMode || 'done'
        });
        this.textInput.value = '';
        this.textInput.dispatchEvent(new Event('input', {
            bubbles: true
        }));
        this.attachClear();
    }
    onViewportResize() {
        if (this.fullscreenActive()) return;
        const vv = window.visualViewport;
        if (this.destroyed || !this.paneVisible || !this.container.offsetParent) return;
        const h = Math.round(vv.height);
        if (this.lastViewportHeight === h) return;
        this.lastViewportHeight = h;
        const app = this.app || this.container.closest('.bt-app');
        if (app) app.style.height = h + 'px';
        if (this.followMode) this.queueScrollToBottom();
    }
    applyUserScroll(prevTop) {
        const { scrollTop , scrollHeight , clientHeight  } = this.container;
        const atBot = this.atBottom();
        if (this.followMode && !atBot) this.setFollowMode(false);
        if (this.followMode) return;
        if (atBot || scrollTop > prevTop && scrollHeight - scrollTop - clientHeight < clientHeight && !this.lastMessageFullyOutOfView()) {
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
        } else {
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
    registerUnread() {
        this.unreadCount++;
        if (this.lastMessageFullyOutOfView()) {
            this.showNewMessagePill();
        } else {
            this.refreshPillContent();
        }
    }
    updateScrollAffordance(atBot) {
        if (!this.paneVisible) return;
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
        if (this.pillEl.classList.contains('bt-new-msg-pill-glow') !== hasUnread) this.pillEl.classList.toggle('bt-new-msg-pill-glow', hasUnread);
        const label = hasUnread ? 'New messages' : 'Move to bottom';
        if (this.pillLabelEl && this.pillLabelEl.textContent !== label) this.pillLabelEl.textContent = label;
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
        const inputArea = app.querySelector('.bt-input-area');
        if (!inputArea) return;
        inputArea.appendChild(pill);
        this.pillEl = pill;
        this.pillLabelEl = label;
    }
}
const PATH_RE = /^(~|\.{1,2})?\/?[\w.@+-]+(\/[\w.@+-]+)+(:\d+)?$/;
function copyText(text) {
    const legacy = ()=>{
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
    return navigator.clipboard && window.isSecureContext ? navigator.clipboard.writeText(text).catch(legacy) : legacy();
}
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
            const say = (t)=>{
                b.textContent = t;
                setTimeout(()=>{
                    b.textContent = '⧉';
                }, 1200);
            };
            copyText(codeText()).then(()=>say('✓'), ()=>say('✕'));
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
function decodePath(text) {
    try {
        return decodeURIComponent(text);
    } catch (error) {
        if (!(error instanceof URIError)) throw error;
        return text;
    }
}
function markdownWorkerPath(anchor) {
    const raw = (anchor.getAttribute('href') || '').trim();
    if (!raw || raw.startsWith('#') || raw.startsWith('?')) return null;
    if (/^(mailto|tel|data|blob|javascript):/i.test(raw)) return null;
    let path = raw;
    let url = null;
    try {
        url = new URL(raw, window.location.href);
    } catch (error) {
        if (!(error instanceof TypeError)) throw error;
    }
    if (url === null) {
        path = decodePath(raw);
    } else if (url.protocol === 'file:') {
        path = decodePath(url.pathname);
    } else if (url.protocol === 'http:' || url.protocol === 'https:') {
        if (url.origin !== window.location.origin) return null;
        path = decodePath(url.pathname);
    } else {
        return null;
    }
    if (!/^(?:[a-z][a-z0-9+.-]*:|\/)/i.test(raw)) {
        path = decodePath(raw.split(/[?#]/, 1)[0]);
    }
    return path || null;
}
function linkifyPaths(rootEl) {
    rootEl.querySelectorAll('a[href]').forEach((el)=>{
        if (el.classList.contains('bt-path-link')) return;
        const path = markdownWorkerPath(el);
        if (!path) return;
        el.classList.add('bt-path-link');
        el.dataset.path = path;
    });
    rootEl.querySelectorAll('code').forEach((el)=>{
        if (el.closest('pre') || el.closest('a')) return;
        const text = (el.textContent || '').trim();
        if (!PATH_RE.test(text) || text.includes('://')) return;
        el.classList.add('bt-path-link');
        el.dataset.path = text;
    });
}
function openLightbox(media) {
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
    const close = ()=>{
        overlay.remove();
        document.removeEventListener('keydown', onkey, true);
    };
    overlay.closeLightbox = close;
    const onkey = (e)=>{
        if (e.key !== 'Escape') return;
        e.preventDefault();
        e.stopImmediatePropagation();
        close();
    };
    overlay.addEventListener('click', close);
    document.addEventListener('keydown', onkey, true);
    document.body.appendChild(overlay);
}
function jumpChipsHTML(jumps) {
    if (!Array.isArray(jumps)) return '';
    return jumps.map((j)=>`<button type="button" class="bt-tool-jump" data-jump-index="${Number(j.index)}"` + ` data-jump-id="${escapeAttr(String(j.id))}" title="${escapeAttr(String(j.title || ''))}">` + `↑ ${escapeHTML(String(j.label))}</button>`).join('');
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
function msearchFilter(inputEl) {
    const q = inputEl.value.toLowerCase();
    const wrap = inputEl.closest('.bt-msearch');
    wrap.querySelectorAll('.bt-msearch-item').forEach((item)=>{
        item.hidden = q.length > 0 && !item.dataset.label.includes(q);
    });
}
function msearchOpen(triggerEl) {
    document.querySelectorAll('.bt-msearch-open').forEach((el)=>el.classList.remove('bt-msearch-open'));
    const wrap = triggerEl.closest('.bt-msearch');
    wrap.classList.add('bt-msearch-open');
    const list = wrap.querySelector('.bt-msearch-list');
    if (list) {
        const t = triggerEl.getBoundingClientRect();
        list.style.top = '0px';
        list.style.left = '0px';
        const l = list.getBoundingClientRect();
        const below = t.bottom + 4;
        const top = below + l.height > window.innerHeight - 8 && t.top - 4 - l.height > 8 ? t.top - 4 - l.height : below;
        list.style.top = `${Math.max(8, top)}px`;
        list.style.left = `${Math.max(8, Math.min(t.left, window.innerWidth - l.width - 8))}px`;
    }
    const input = wrap.querySelector('.bt-msearch-input');
    if (input) {
        input.value = '';
        msearchFilter(input);
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
}
function msearchSelect(itemEl, pickObs, cfgId, value) {
    pickObs.notify([
        cfgId,
        value
    ]);
    const wrap = itemEl.closest('.bt-msearch');
    if (wrap) wrap.classList.remove('bt-msearch-open');
}
const CHAT_INSTANCES = new Set();
function bodyMounted(slot) {
    const row = slot.closest('.bt-tool-msg');
    if (!row) return;
    for (const chat of CHAT_INSTANCES){
        if (chat.container.contains(row)) {
            chat.onBodyMounted(row);
            return;
        }
    }
}
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
function flushDrafts() {
    for (const chat of CHAT_INSTANCES)chat.flushDraft?.();
}
function connect(node, comm, init = {}) {
    const chat = new BonitoChat(node, comm, init);
    if (Array.isArray(init.commands)) chat.slashCommands = init.commands;
    node.__bt_chat = chat;
    CHAT_INSTANCES.add(chat);
    const parent = node.parentNode;
    if (parent) {
        const mo = new MutationObserver(()=>{
            if (!node.isConnected) {
                mo.disconnect();
                CHAT_INSTANCES.delete(chat);
                if (!chat.destroyed) chat.destroy();
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
export { mountCode as mountCode };
export { openLightbox as openLightbox };
export { msearchFilter as msearchFilter };
export { msearchOpen as msearchOpen };
export { msearchSelect as msearchSelect };
export { bodyMounted as bodyMounted };
export { toolSlot as toolSlot };
export { flushDrafts as flushDrafts };
export { connect as connect };


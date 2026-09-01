// Behaviour for file-viewer bodies, wired by OBSERVATION rather than by
// per-node callbacks.
//
// Why: `Bonito.onload(session, node, js)` pushes onto the session's
// `on_document_load` list, which is flushed when that session's document is
// shown. A file body is built OFF the session task (a worker round-trip for a
// media url, a mesh parse, a table read) and delivered later as an Observable
// update — so whether its `onload` is still in time for the flush is a race
// against how long the fetch took. A small CSV won it; an image and a mesh lost
// it, silently, leaving dead nodes with no behaviour and no error.
//
// So the JS is installed ONCE per window and adopts whatever appears:
//
//   .bt-fv-image-stage           → report the decoded pixel size into the header
//   .bt-fv-table-wrap            → click-to-sort + filter
//   .bt-fv-frame[data-frame-src] → point the pdf/html frame at its file
//   .bt-mesh-view[data-mesh-url] → mount the WebGL geometry viewer
//
// Each node is marked once (`data-fv-ready`), so re-scans are idempotent and a
// node that gets MOVED (the workspace relocates panel content by identity) keeps
// its behaviour instead of being re-initialised.

const READY = "fvReady";        // dataset key ⇒ data-fv-ready

// ── image: report intrinsic size into the panel header ──────────────────────
function initImage(stage) {
    const img = stage.querySelector("img");
    if (!img) return;
    // Both the decode and the attachment can still be pending; neither has a
    // single event that covers the other, so one bounded frame loop does both.
    let tries = 240;
    const show = () => {
        // Stop the moment the panel goes away: a hidden window throttles rAF to
        // ~1Hz, so without this an image that never decodes (dead src, closed
        // tab) would keep a callback — and through it a detached subtree — alive
        // for minutes, which is exactly what the soak's leak audit looks for.
        if (!stage.isConnected) return;
        const meta = stage.closest(".bt-file-view")?.querySelector(".bt-fv-dims");
        if (meta && img.naturalWidth) {
            meta.textContent = img.naturalWidth + " × " + img.naturalHeight + " px";
            return;
        }
        if (tries-- > 0) requestAnimationFrame(show);
    };
    show();
}

// ── table: sort + filter, entirely client-side ──────────────────────────────
// No round-trip, so a 5000-row table stays instant and keeps working if the
// worker goes away.
function initTable(root) {
    const tbody = root.querySelector("tbody");
    if (!tbody) return;
    const original = [...tbody.rows];
    let sortCol = null, dir = 1;
    const key = (row, c) => row.cells[c].textContent;

    root.querySelectorAll("th.bt-fv-sortable").forEach(th => {
        th.addEventListener("click", () => {
            // 1-based data column; cell 0 is the row number.
            const c = parseInt(th.dataset.col, 10);
            if (sortCol === c) { dir = -dir; } else { sortCol = c; dir = 1; }
            root.querySelectorAll("th .bt-fv-sort-arrow").forEach(a => a.textContent = "⇅");
            th.querySelector(".bt-fv-sort-arrow").textContent = dir > 0 ? "↑" : "↓";
            const num = th.classList.contains("bt-fv-num");
            const rows = [...tbody.rows].sort((a, b) => {
                const x = key(a, c), y = key(b, c);
                if (num) {
                    const fx = parseFloat(x), fy = parseFloat(y);
                    const nx = isNaN(fx), ny = isNaN(fy);
                    if (nx && ny) return 0;
                    if (nx) return 1;          // blanks / NaN always sort last
                    if (ny) return -1;
                    return (fx - fy) * dir;
                }
                return x.localeCompare(y) * dir;
            });
            rows.forEach(r => tbody.appendChild(r));
        });
    });

    const input = root.querySelector(".bt-fv-table-filter");
    if (input) input.addEventListener("input", () => {
        const q = input.value.toLowerCase();
        original.forEach(r => {
            r.style.display = (!q || r.textContent.toLowerCase().includes(q)) ? "" : "none";
        });
    });
}

// ── pdf / html: give the frame its src only once it is IN the document ──────
// A `<iframe src=…>` that arrives already-sourced through Bonito's node
// insertion never gets a live view for Chromium's PDF plugin: the frame
// navigates, the viewer's `<embed>` is created with `src="about:blank"`, and the
// panel shows nothing but the viewer's dark backdrop — forever. Re-assigning the
// SAME url once the node is connected renders it immediately, which is the whole
// fix. An ordinary HTML document reloads through the same insertion without
// complaint, which is what made this look like a PDF-only mystery.
function initFrame(el) {
    const src = el.dataset.frameSrc;
    if (src) el.src = src;
}

/**
 * Install the file-viewer driver for this window. Idempotent: the first caller
 * wins and later ones are no-ops, so the shell and an individually-rendered
 * panel can both ask for it.
 *
 * `meshLib` is `assets/meshview.js`, passed in rather than imported so the two
 * modules stay independently bundleable.
 */
export function install(meshLib) {
    if (window.__btFileViewDriver) return window.__btFileViewDriver;

    const initOne = (el) => {
        if (el.dataset[READY] === "1") return;
        el.dataset[READY] = "1";
        try {
            if (el.classList.contains("bt-fv-image-stage")) initImage(el);
            else if (el.classList.contains("bt-fv-table-wrap")) initTable(el);
            else if (el.classList.contains("bt-fv-frame")) initFrame(el);
            else if (el.classList.contains("bt-mesh-view")) {
                meshLib.mount(el, el.dataset.meshUrl);
            }
        } catch (err) {
            // A failure here is a dead viewer; make it say so rather than
            // sitting there empty (the exact failure this file exists to fix).
            console.error("bt-fileview: init failed", el, err);
            const status = el.querySelector(".bt-mesh-status");
            if (status) status.textContent = "viewer failed: " + (err && err.message || err);
        }
    };

    const SEL = ".bt-fv-image-stage, .bt-fv-table-wrap, .bt-fv-frame[data-frame-src], " +
                ".bt-mesh-view[data-mesh-url]";
    const scan = (root) => {
        if (!root || root.nodeType !== 1) return;
        if (root.matches && root.matches(SEL)) initOne(root);
        root.querySelectorAll && root.querySelectorAll(SEL).forEach(initOne);
    };

    scan(document.body);

    // The observer callback must stay O(1): it runs in the microtask checkpoint
    // right after a DOM mutation, and Bonito's own move machinery (`move_dom_node`
    // in Sessions.js) runs its bookkeeping in that same checkpoint and is timing
    // sensitive by design — a live embed being relocated between a chat bubble, a
    // float and a tab depends on it. So this only QUEUES the added roots and does
    // the actual walking on the next frame, outside the checkpoint entirely.
    //
    // It also keeps a streaming chat cheap: a burst of message mutations costs
    // one queued entry each and one coalesced scan pass, not a `querySelectorAll`
    // per mutation record.
    let pending = [];
    let scheduled = false;
    const drain = () => {
        scheduled = false;
        const roots = pending;
        pending = [];
        for (const node of roots) scan(node);
    };
    const observer = new MutationObserver(records => {
        for (const rec of records) {
            for (const node of rec.addedNodes) {
                if (node.nodeType === 1) pending.push(node);
            }
        }
        if (pending.length && !scheduled) {
            scheduled = true;
            // A timer, NOT requestAnimationFrame: a hidden window throttles rAF
            // to ~1Hz (and OSR/background tabs vary), which would stall a file
            // body's behaviour behind the compositor. All this needs is to be
            // OUT of the mutation checkpoint, which any macrotask achieves.
            setTimeout(drain, 0);
        }
    });
    observer.observe(document.body, { childList: true, subtree: true });

    window.__btFileViewDriver = { observer, scan, drain };
    return window.__btFileViewDriver;
}

// deno-fmt-ignore-file
// deno-lint-ignore-file
// This code was bundled using `deno bundle` and it's not recommended to edit it manually

const READY = "fvReady";
function initImage(stage) {
    const img = stage.querySelector("img");
    if (!img) return;
    let tries = 240;
    const show = ()=>{
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
function initTable(root) {
    const tbody = root.querySelector("tbody");
    if (!tbody) return;
    const original = [
        ...tbody.rows
    ];
    let sortCol = null, dir = 1;
    const key = (row, c)=>row.cells[c].textContent;
    root.querySelectorAll("th.bt-fv-sortable").forEach((th)=>{
        th.addEventListener("click", ()=>{
            const c = parseInt(th.dataset.col, 10);
            if (sortCol === c) {
                dir = -dir;
            } else {
                sortCol = c;
                dir = 1;
            }
            root.querySelectorAll("th .bt-fv-sort-arrow").forEach((a)=>a.textContent = "⇅");
            th.querySelector(".bt-fv-sort-arrow").textContent = dir > 0 ? "↑" : "↓";
            const num = th.classList.contains("bt-fv-num");
            const rows = [
                ...tbody.rows
            ].sort((a, b)=>{
                const x = key(a, c), y = key(b, c);
                if (num) {
                    const fx = parseFloat(x), fy = parseFloat(y);
                    const nx = isNaN(fx), ny = isNaN(fy);
                    if (nx && ny) return 0;
                    if (nx) return 1;
                    if (ny) return -1;
                    return (fx - fy) * dir;
                }
                return x.localeCompare(y) * dir;
            });
            rows.forEach((r)=>tbody.appendChild(r));
        });
    });
    const input = root.querySelector(".bt-fv-table-filter");
    if (input) input.addEventListener("input", ()=>{
        const q = input.value.toLowerCase();
        original.forEach((r)=>{
            r.style.display = !q || r.textContent.toLowerCase().includes(q) ? "" : "none";
        });
    });
}
function initFrame(el) {
    const src = el.dataset.frameSrc;
    if (src) el.src = src;
}
function install(meshLib) {
    if (window.__btFileViewDriver) return window.__btFileViewDriver;
    const initOne = (el)=>{
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
            console.error("bt-fileview: init failed", el, err);
            const status = el.querySelector(".bt-mesh-status");
            if (status) status.textContent = "viewer failed: " + (err && err.message || err);
        }
    };
    const SEL = ".bt-fv-image-stage, .bt-fv-table-wrap, .bt-fv-frame[data-frame-src], " + ".bt-mesh-view[data-mesh-url]";
    const scan = (root)=>{
        if (!root || root.nodeType !== 1) return;
        if (root.matches && root.matches(SEL)) initOne(root);
        root.querySelectorAll && root.querySelectorAll(SEL).forEach(initOne);
    };
    scan(document.body);
    let pending = [];
    let scheduled = false;
    const drain = ()=>{
        scheduled = false;
        const roots = pending;
        pending = [];
        for (const node of roots)scan(node);
    };
    const observer = new MutationObserver((records)=>{
        for (const rec of records){
            for (const node of rec.addedNodes){
                if (node.nodeType === 1) pending.push(node);
            }
        }
        if (pending.length && !scheduled) {
            scheduled = true;
            setTimeout(drain, 0);
        }
    });
    observer.observe(document.body, {
        childList: true,
        subtree: true
    });
    window.__btFileViewDriver = {
        observer,
        scan,
        drain
    };
    return window.__btFileViewDriver;
}
export { install as install };


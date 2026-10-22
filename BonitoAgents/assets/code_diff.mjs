// The shortest edit script between two arrays (Myers 1986), one step per
// element: '=' keeps one, '-' drops one of `a`, '+' takes one of `b`. Null past
// `maxD` differences.
export function editSteps(a, b, maxD) {
    const n = a.length, m = b.length, limit = Math.min(n + m, maxD), off = limit + 1;
    const v = new Int32Array(2 * limit + 3);
    const trace = [];
    for (let d = 0; d <= limit; d++) {
        // Backtracking only reads diagonals within this round, not the whole input.
        trace.push(v.slice(off - d - 1, off + d + 2));
        for (let k = -d; k <= d; k += 2) {
            let x = (k === -d || (k !== d && v[k - 1 + off] < v[k + 1 + off])) ? v[k + 1 + off] : v[k - 1 + off] + 1;
            let y = x - k;
            while (x < n && y < m && a[x] === b[y]) { x++; y++; }
            v[k + off] = x;
            if (x >= n && y >= m) {
                const steps = [];
                for (let dd = d; dd > 0; dd--) {
                    const w = trace[dd], kk = x - y;
                    const down = kk === -dd || (kk !== dd && w[kk + dd] < w[kk + dd + 2]);
                    const pk = down ? kk + 1 : kk - 1, px = w[pk + dd + 1], py = px - pk;
                    while (x > (down ? px : px + 1) && y > (down ? py + 1 : py)) { steps.push('='); x--; y--; }
                    steps.push(down ? '+' : '-');
                    x = px; y = py;
                }
                while (x > 0 && y > 0) { steps.push('='); x--; y--; }
                return steps.reverse();
            }
        }
    }
    return null;
}

// What a removed line and the added line it became differ in, word by word
// (runs of word characters, of spaces, single other characters): the
// character ranges of each side that the other lacks. Nothing when the lines
// share too little for marks to say more than the line's own colour does.
export function changedRanges(a, b) {
    const ta = a.match(/\w+|\s+|[^\w\s]/g) || [], tb = b.match(/\w+|\s+|[^\w\s]/g) || [];
    const steps = editSteps(ta, tb, 200);
    if (!steps) return null;
    const ra = [], rb = [];
    let i = 0, j = 0, pa = 0, pb = 0, kept = 0;
    const add = (ranges, from, to) => {
        const last = ranges[ranges.length - 1];
        if (last && last[1] === from) last[1] = to; else ranges.push([from, to]);
    };
    for (const st of steps) {
        if (st === '=') { pa += ta[i].length; pb += tb[j].length; kept += ta[i].length; i++; j++; }
        else if (st === '-') { add(ra, pa, pa + ta[i].length); pa += ta[i++].length; }
        else { add(rb, pb, pb + tb[j].length); pb += tb[j++].length; }
    }
    if (kept * 3 < Math.max(a.length, b.length)) return null;
    return [ra, rb];
}


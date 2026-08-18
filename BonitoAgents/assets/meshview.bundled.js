// deno-fmt-ignore-file
// deno-lint-ignore-file
// This code was bundled using `deno bundle` and it's not recommended to edit it manually

const VERT_SRC = `
attribute vec3 aPos;
attribute vec3 aNormal;
uniform mat4 uMVP;
uniform mat4 uModelView;
uniform mat3 uNormalMat;
varying vec3 vNormal;
varying vec3 vViewPos;
void main() {
    vNormal  = normalize(uNormalMat * aNormal);
    vec4 mv  = uModelView * vec4(aPos, 1.0);
    vViewPos = mv.xyz;
    gl_Position = uMVP * vec4(aPos, 1.0);
}`;
const fragSource = (hasDerivatives)=>`
${hasDerivatives ? "#extension GL_OES_standard_derivatives : enable" : ""}
precision mediump float;
varying vec3 vNormal;
varying vec3 vViewPos;
uniform vec3 uColor;
uniform float uFlat;
void main() {
    vec3 n = normalize(vNormal);
    ${hasDerivatives ? "if (uFlat > 0.5) { n = normalize(cross(dFdx(vViewPos), dFdy(vViewPos))); }" : ""}
    vec3 v = normalize(-vViewPos);
    if (dot(n, v) < 0.0) n = -n;            // two-sided: unify winding
    float key  = max(dot(n, normalize(vec3(0.35, 0.5, 1.0))), 0.0);
    float fill = max(dot(n, normalize(vec3(-0.4, -0.6, 0.3))), 0.0) * 0.25;
    float rim  = pow(1.0 - max(dot(n, v), 0.0), 2.5) * 0.35;
    vec3 c = uColor * (0.22 + 0.78 * key + fill) + vec3(rim);
    gl_FragColor = vec4(c, 1.0);
}`.trimStart();
const WIRE_FRAG_SRC = `
precision mediump float;
varying vec3 vNormal;
varying vec3 vViewPos;
void main() { gl_FragColor = vec4(0.09, 0.13, 0.21, 1.0); }`;
function compile(gl, type, src) {
    const sh = gl.createShader(type);
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
        const log = gl.getShaderInfoLog(sh);
        gl.deleteShader(sh);
        throw new Error("shader compile failed: " + log);
    }
    return sh;
}
function program(gl, fragSrc) {
    const p = gl.createProgram();
    gl.attachShader(p, compile(gl, gl.VERTEX_SHADER, VERT_SRC));
    gl.attachShader(p, compile(gl, gl.FRAGMENT_SHADER, fragSrc));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
        throw new Error("program link failed: " + gl.getProgramInfoLog(p));
    }
    return p;
}
const mat4 = {
    identity: ()=>new Float32Array([
            1,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            1
        ]),
    perspective (fovy, aspect, near, far) {
        const f = 1 / Math.tan(fovy / 2), nf = 1 / (near - far);
        return new Float32Array([
            f / aspect,
            0,
            0,
            0,
            0,
            f,
            0,
            0,
            0,
            0,
            (far + near) * nf,
            -1,
            0,
            0,
            2 * far * near * nf,
            0
        ]);
    },
    lookAt (eye, center, up) {
        const z = norm3(sub3(eye, center));
        const x = norm3(cross3(up, z));
        const y = cross3(z, x);
        return new Float32Array([
            x[0],
            y[0],
            z[0],
            0,
            x[1],
            y[1],
            z[1],
            0,
            x[2],
            y[2],
            z[2],
            0,
            -dot3(x, eye),
            -dot3(y, eye),
            -dot3(z, eye),
            1
        ]);
    },
    mul (a, b) {
        const o = new Float32Array(16);
        for(let c = 0; c < 4; c++){
            for(let r = 0; r < 4; r++){
                let s = 0;
                for(let k = 0; k < 4; k++)s += a[k * 4 + r] * b[c * 4 + k];
                o[c * 4 + r] = s;
            }
        }
        return o;
    },
    normalMat (m) {
        return new Float32Array([
            m[0],
            m[1],
            m[2],
            m[4],
            m[5],
            m[6],
            m[8],
            m[9],
            m[10]
        ]);
    }
};
const sub3 = (a, b)=>[
        a[0] - b[0],
        a[1] - b[1],
        a[2] - b[2]
    ];
const add3 = (a, b)=>[
        a[0] + b[0],
        a[1] + b[1],
        a[2] + b[2]
    ];
const dot3 = (a, b)=>a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross3 = (a, b)=>[
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0]
    ];
const scale3 = (a, s)=>[
        a[0] * s,
        a[1] * s,
        a[2] * s
    ];
function norm3(a) {
    const l = Math.hypot(a[0], a[1], a[2]) || 1;
    return [
        a[0] / l,
        a[1] / l,
        a[2] / l
    ];
}
const count = (n, one, many)=>`${n.toLocaleString()} ${n === 1 ? one : many}`;
const MAGIC = "BTMESH1\0";
function parseBlob(buffer) {
    const bytes = new Uint8Array(buffer);
    let magic = "";
    for(let i = 0; i < 8; i++)magic += String.fromCharCode(bytes[i]);
    if (magic !== MAGIC) throw new Error("not a BTMESH1 blob");
    const head = new Uint32Array(buffer, 8, 2);
    const nverts = head[0], ntris = head[1];
    let off = 16;
    const positions = new Float32Array(buffer, off, 3 * nverts);
    off += 12 * nverts;
    const normals = new Float32Array(buffer, off, 3 * nverts);
    off += 12 * nverts;
    const indices = new Uint32Array(buffer, off, 3 * ntris);
    return {
        nverts,
        ntris,
        positions,
        normals,
        indices
    };
}
function wireIndices(indices) {
    const seen = new Set();
    const out = [];
    for(let i = 0; i < indices.length; i += 3){
        const t = [
            indices[i],
            indices[i + 1],
            indices[i + 2]
        ];
        for(let e = 0; e < 3; e++){
            const a = t[e], b = t[(e + 1) % 3];
            const key = a < b ? a * 4294967296 + b : b * 4294967296 + a;
            if (seen.has(key)) continue;
            seen.add(key);
            out.push(a, b);
        }
    }
    return new Uint32Array(out);
}
function boundingSphere(positions) {
    let minx = Infinity, miny = Infinity, minz = Infinity;
    let maxx = -Infinity, maxy = -Infinity, maxz = -Infinity;
    for(let i = 0; i < positions.length; i += 3){
        const x = positions[i], y = positions[i + 1], z = positions[i + 2];
        if (x < minx) minx = x;
        if (x > maxx) maxx = x;
        if (y < miny) miny = y;
        if (y > maxy) maxy = y;
        if (z < minz) minz = z;
        if (z > maxz) maxz = z;
    }
    if (!isFinite(minx)) return {
        center: [
            0,
            0,
            0
        ],
        radius: 1
    };
    const center = [
        (minx + maxx) / 2,
        (miny + maxy) / 2,
        (minz + maxz) / 2
    ];
    const radius = Math.max(1e-6, Math.hypot(maxx - minx, maxy - miny, maxz - minz) / 2);
    return {
        center,
        radius
    };
}
async function mount(root, url) {
    const status = root.querySelector(".bt-mesh-status");
    try {
        return await mountViewer(root, url, status);
    } catch (err) {
        if (status) status.textContent = "3D viewer failed: " + (err && err.message || err);
        console.error("bt-mesh: mount failed", err);
        return ()=>{};
    }
}
async function mountViewer(root, url, status) {
    const canvas = root.querySelector("canvas.bt-mesh-canvas");
    if (!canvas) return ()=>{};
    const gl = canvas.getContext("webgl", {
        antialias: true,
        alpha: false
    }) || canvas.getContext("experimental-webgl");
    if (!gl) {
        if (status) status.textContent = "WebGL is not available in this window";
        return ()=>{};
    }
    const hasDerivatives = !!gl.getExtension("OES_standard_derivatives");
    const uintExt = gl.getExtension("OES_element_index_uint");
    let mesh;
    try {
        const resp = await fetch(url);
        if (!resp.ok) throw new Error("HTTP " + resp.status);
        mesh = parseBlob(await resp.arrayBuffer());
    } catch (err) {
        if (status) status.textContent = "could not load geometry: " + err.message;
        return ()=>{};
    }
    if (!uintExt && mesh.nverts > 65535) {
        if (status) status.textContent = `mesh too large for this GPU context (${count(mesh.nverts, "vertex", "vertices")}, ` + `no 32-bit index support)`;
        return ()=>{};
    }
    const solidProg = program(gl, fragSource(hasDerivatives));
    const wireProg = program(gl, WIRE_FRAG_SRC);
    const posBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, posBuf);
    gl.bufferData(gl.ARRAY_BUFFER, mesh.positions, gl.STATIC_DRAW);
    const nrmBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, nrmBuf);
    gl.bufferData(gl.ARRAY_BUFFER, mesh.normals, gl.STATIC_DRAW);
    const idxBuf = gl.createBuffer();
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, idxBuf);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, mesh.indices, gl.STATIC_DRAW);
    let wireBuf = null, wireCount = 0;
    const bs = boundingSphere(mesh.positions);
    const view = {
        yaw: 0.6,
        pitch: 0.45,
        dist: bs.radius * 3.0,
        target: bs.center.slice()
    };
    const home = JSON.parse(JSON.stringify(view));
    let wireframe = false, flat = false;
    const setStatus = ()=>{
        if (!status) return;
        status.textContent = `${count(mesh.ntris, "triangle", "triangles")} · ${count(mesh.nverts, "vertex", "vertices")}`;
    };
    setStatus();
    function resize() {
        const dpr = Math.min(window.devicePixelRatio || 1, 2);
        const w = Math.max(1, Math.round(canvas.clientWidth * dpr));
        const h = Math.max(1, Math.round(canvas.clientHeight * dpr));
        if (canvas.width !== w || canvas.height !== h) {
            canvas.width = w;
            canvas.height = h;
        }
    }
    function draw() {
        resize();
        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.clearColor(0.97, 0.98, 0.99, 1);
        gl.enable(gl.DEPTH_TEST);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        const cp = Math.cos(view.pitch), sp = Math.sin(view.pitch);
        const eye = add3(view.target, scale3([
            cp * Math.sin(view.yaw),
            sp,
            cp * Math.cos(view.yaw)
        ], view.dist));
        const near = Math.max(view.dist * 0.001, bs.radius * 1e-4);
        const far = view.dist + bs.radius * 8 + 1;
        const proj = mat4.perspective(Math.PI / 4, Math.max(canvas.width / Math.max(canvas.height, 1), 1e-3), near, far);
        const mv = mat4.lookAt(eye, view.target, [
            0,
            1,
            0
        ]);
        const mvp = mat4.mul(proj, mv);
        const bind = (prog)=>{
            gl.useProgram(prog);
            gl.uniformMatrix4fv(gl.getUniformLocation(prog, "uMVP"), false, mvp);
            gl.uniformMatrix4fv(gl.getUniformLocation(prog, "uModelView"), false, mv);
            gl.uniformMatrix3fv(gl.getUniformLocation(prog, "uNormalMat"), false, mat4.normalMat(mv));
            const ap = gl.getAttribLocation(prog, "aPos");
            gl.bindBuffer(gl.ARRAY_BUFFER, posBuf);
            gl.enableVertexAttribArray(ap);
            gl.vertexAttribPointer(ap, 3, gl.FLOAT, false, 0, 0);
            const an = gl.getAttribLocation(prog, "aNormal");
            if (an >= 0) {
                gl.bindBuffer(gl.ARRAY_BUFFER, nrmBuf);
                gl.enableVertexAttribArray(an);
                gl.vertexAttribPointer(an, 3, gl.FLOAT, false, 0, 0);
            }
        };
        bind(solidProg);
        gl.uniform3f(gl.getUniformLocation(solidProg, "uColor"), 0.62, 0.70, 0.82);
        gl.uniform1f(gl.getUniformLocation(solidProg, "uFlat"), flat && hasDerivatives ? 1.0 : 0.0);
        gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, idxBuf);
        if (wireframe) {
            gl.enable(gl.POLYGON_OFFSET_FILL);
            gl.polygonOffset(1.0, 1.0);
        }
        gl.drawElements(gl.TRIANGLES, mesh.indices.length, gl.UNSIGNED_INT, 0);
        gl.disable(gl.POLYGON_OFFSET_FILL);
        if (wireframe) {
            if (!wireBuf) {
                const wi = wireIndices(mesh.indices);
                wireCount = wi.length;
                wireBuf = gl.createBuffer();
                gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, wireBuf);
                gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, wi, gl.STATIC_DRAW);
            }
            bind(wireProg);
            gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, wireBuf);
            gl.drawElements(gl.LINES, wireCount, gl.UNSIGNED_INT, 0);
        }
    }
    let frame = 0, alive = true;
    const invalidate = ()=>{
        if (!alive || frame) return;
        frame = requestAnimationFrame(()=>{
            frame = 0;
            if (alive) draw();
        });
    };
    let drag = null;
    canvas.addEventListener("pointerdown", (e)=>{
        canvas.setPointerCapture(e.pointerId);
        drag = {
            x: e.clientX,
            y: e.clientY,
            pan: e.button === 2 || e.shiftKey
        };
        e.preventDefault();
    });
    canvas.addEventListener("pointermove", (e)=>{
        if (!drag) return;
        const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
        drag.x = e.clientX;
        drag.y = e.clientY;
        if (drag.pan) {
            const cp = Math.cos(view.pitch), sp = Math.sin(view.pitch);
            const fwd = [
                cp * Math.sin(view.yaw),
                sp,
                cp * Math.cos(view.yaw)
            ];
            const right = norm3(cross3([
                0,
                1,
                0
            ], fwd));
            const up = cross3(fwd, right);
            const k = view.dist * 0.002;
            view.target = add3(view.target, add3(scale3(right, -dx * k), scale3(up, dy * k)));
        } else {
            view.yaw -= dx * 0.01;
            view.pitch = Math.max(-1.5, Math.min(1.5, view.pitch + dy * 0.01));
        }
        invalidate();
    });
    const endDrag = ()=>{
        drag = null;
    };
    canvas.addEventListener("pointerup", endDrag);
    canvas.addEventListener("pointercancel", endDrag);
    canvas.addEventListener("contextmenu", (e)=>e.preventDefault());
    canvas.addEventListener("wheel", (e)=>{
        e.preventDefault();
        view.dist = Math.max(bs.radius * 0.02, Math.min(bs.radius * 200, view.dist * Math.exp(e.deltaY * 0.001)));
        invalidate();
    }, {
        passive: false
    });
    const onClick = (e)=>{
        const btn = e.target.closest("[data-mesh-action]");
        if (!btn) return;
        const action = btn.dataset.meshAction;
        if (action === "reset") {
            Object.assign(view, JSON.parse(JSON.stringify(home)));
        } else if (action === "wire") {
            wireframe = !wireframe;
            btn.dataset.on = wireframe ? "1" : "0";
        } else if (action === "flat") {
            if (!hasDerivatives) return;
            flat = !flat;
            btn.dataset.on = flat ? "1" : "0";
        }
        invalidate();
    };
    root.addEventListener("click", onClick);
    const flatBtn = root.querySelector('[data-mesh-action="flat"]');
    if (flatBtn && !hasDerivatives) {
        flatBtn.disabled = true;
        flatBtn.title = "not supported here";
    }
    const ro = new ResizeObserver(invalidate);
    ro.observe(canvas);
    const dispose = ()=>{
        if (!alive) return;
        alive = false;
        ro.disconnect();
        root.removeEventListener("click", onClick);
        [
            posBuf,
            nrmBuf,
            idxBuf,
            wireBuf
        ].forEach((b)=>b && gl.deleteBuffer(b));
        gl.deleteProgram(solidProg);
        gl.deleteProgram(wireProg);
        const lose = gl.getExtension("WEBGL_lose_context");
        if (lose) lose.loseContext();
    };
    const mo = new MutationObserver(()=>{
        if (canvas.isConnected) return;
        setTimeout(()=>{
            if (!canvas.isConnected) {
                mo.disconnect();
                dispose();
            }
        }, 250);
    });
    if (canvas.parentElement) mo.observe(canvas.parentElement, {
        childList: true
    });
    invalidate();
    return dispose;
}
export { parseBlob as parseBlob };
export { mount as mount };


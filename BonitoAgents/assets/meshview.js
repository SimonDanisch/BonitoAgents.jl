// The file viewer's 3D view, one for every format it shows (.obj/.stl/.ply/.off/
// .glb/.gltf). The browser reads the original file with three.js's loader for
// it: a glTF with its textures, PBR materials, vertex colours and animations, an
// OBJ with its .mtl materials. The URL is a signed one for the file's folder
// (server.jl :: worker_folder_url), so whatever a file names next to it (a
// .gltf's .bin and textures, an OBJ's .mtl) resolves and is fetched from the
// worker when the loader asks for it.
//
// Loaded on first use (fileview.js), since three.js is most of a megabyte.
//
// Camera: orbit (drag) · dolly (wheel) · pan (right-drag or shift-drag). Framed
// on the scene's bounding box, so a 1 cm part and a 1 km terrain both open
// filling the view.

// One esm.sh build target for every import. Without it Deno gets "denonext"
// builds, but several loaders hard-code the es2022 one: the bundle carried two
// copies of three.js, and the page warned "Multiple instances of Three.js".
import * as THREE from "https://esm.sh/three@0.173.0?target=es2022";
import { GLTFLoader } from "https://esm.sh/three@0.173.0/examples/jsm/loaders/GLTFLoader.js?target=es2022";
import { OBJLoader } from "https://esm.sh/three@0.173.0/examples/jsm/loaders/OBJLoader.js?target=es2022";
import { MTLLoader } from "https://esm.sh/three@0.173.0/examples/jsm/loaders/MTLLoader.js?target=es2022";
import { STLLoader } from "https://esm.sh/three@0.173.0/examples/jsm/loaders/STLLoader.js?target=es2022";
import { PLYLoader } from "https://esm.sh/three@0.173.0/examples/jsm/loaders/PLYLoader.js?target=es2022";
import { mergeVertices } from "https://esm.sh/three@0.173.0/examples/jsm/utils/BufferGeometryUtils.js?target=es2022";
import { OrbitControls } from "https://esm.sh/three@0.173.0/examples/jsm/controls/OrbitControls.js?target=es2022";
import { RoomEnvironment } from "https://esm.sh/three@0.173.0/examples/jsm/environments/RoomEnvironment.js?target=es2022";

// Thousands-separated and correctly pluralised: a one-triangle file reading
// "1 triangles" is the sort of thing you notice every single time.
const count = (n, one, many) => `${n.toLocaleString()} ${n === 1 ? one : many}`;

// A loader's error in words. GLTFLoader names a JS class for what a glTF needs
// that this preview does not bring, which tells nobody what to do, and a failed
// fetch quotes the whole signed URL.
function explain(err) {
    const m = (err && err.message) || String(err);
    if (/DRACOLoader/.test(m)) return "it is Draco-compressed, which the preview does not decode";
    if (/MeshoptDecoder/.test(m)) return "it is meshopt-compressed, which the preview does not decode";
    if (/KTX2Loader/.test(m)) return "its textures are KTX2, which the preview does not decode";
    const http = m.match(/fetch for "([^"]+)" responded with (\d+)/);
    if (http) return `${decodeURIComponent(http[1].split("/").pop())} could not be fetched (HTTP ${http[2]})`;
    return m;
}

// Geometry that comes without a material of its own (STL, PLY, OFF, an OBJ
// without .mtl): a light slate blue, matte, since shape reads best without
// highlights, and double-sided, since their winding is anyone's guess. Vertex
// colours win when the file has them.
function plainMaterial(geometry) {
    const colored = !!geometry.getAttribute("color");
    return new THREE.MeshStandardMaterial({
        color: colored ? 0xffffff : 0x9eb3d1, vertexColors: colored,
        metalness: 0, roughness: 0.6, side: THREE.DoubleSide });
}

function meshOf(geometry) {
    if (!geometry.getAttribute("normal")) geometry.computeVertexNormals();
    return new THREE.Mesh(geometry, plainMaterial(geometry));
}

// A PLY without faces is a point cloud (a scan, most of the time).
function cloudOf(geometry) {
    const colored = !!geometry.getAttribute("color");
    return new THREE.Points(geometry, new THREE.PointsMaterial({
        color: colored ? 0xffffff : 0x3b5b8c, vertexColors: colored, size: 2, sizeAttenuation: false }));
}

// OFF has no three.js loader, and is small enough to read here: "OFF", the
// vertex and face counts, the vertices, then each face as `n i1 … in`, fanned
// into triangles like every quick viewer does.
function parseOFF(text) {
    const w = text.replace(/#[^\n]*/g, " ").trim().split(/\s+/);
    if ((w[0] || "").toUpperCase() !== "OFF") throw new Error("not an OFF file (it does not start with OFF)");
    const nv = parseInt(w[1], 10), nf = parseInt(w[2], 10);
    if (!(nv >= 0 && nf >= 0)) throw new Error("OFF: no vertex and face counts after the header");
    let i = 4;
    const positions = new Float32Array(3 * nv);
    for (let k = 0; k < 3 * nv; k++) positions[k] = parseFloat(w[i++]);
    const index = [];
    for (let f = 0; f < nf; f++) {
        const n = parseInt(w[i++], 10), corners = w.slice(i, i + n).map(x => parseInt(x, 10));
        i += n;
        if (!(n >= 0) || corners.length < n) throw new Error(`OFF: the file ends inside face ${f + 1}`);
        if (corners.some(c => !(c >= 0 && c < nv)))
            throw new Error(`OFF: face ${f + 1} names a vertex that is not among the ${nv}`);
        for (let k = 1; k + 1 < n; k++) index.push(corners[0], corners[k], corners[k + 1]);
    }
    if (positions.some(Number.isNaN)) throw new Error("OFF: the file ends inside the vertex list");
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute("position", new THREE.BufferAttribute(positions, 3));
    geometry.setIndex(index);
    return geometry;
}

async function loadGLTF(url) {
    const gltf = await new GLTFLoader().loadAsync(url);
    const model = gltf.scene || gltf.scenes[0];
    if (!model) throw new Error("this file has no scene to show");
    return { model, animations: gltf.animations, notes: [] };
}

// An OBJ names its materials in an .mtl next to it (`mtllib`). Without one, or
// when it can't be fetched, its meshes get the plain material; lines and points
// keep theirs.
async function loadOBJ(url) {
    const text = await new THREE.FileLoader().loadAsync(url);
    const bare = new OBJLoader().parse(text);
    const lib = bare.materialLibraries[0];
    let model = bare;
    const notes = [];
    if (lib !== undefined) {
        let materials;
        try {
            materials = await new MTLLoader().loadAsync(new URL(lib, new URL(url, location.href)).href);
        } catch (err) {
            console.warn("bt-mesh: the OBJ's material library did not load", lib, err);
            notes.push(`${lib}: ${explain(err)}`);
        }
        if (materials) {
            // The .mtl's textures load in the background, and a view that draws
            // on demand would show them black until something moved. Wait for
            // them like GLTFLoader does; a failed one ends its wait too.
            const textures = new THREE.LoadingManager();
            let pending = false;
            textures.onStart = () => { pending = true; };
            textures.onError = (u) => notes.push(`${decodeURIComponent(u.split("/").pop())} could not be fetched`);
            const loaded = new Promise(resolve => { textures.onLoad = resolve; });
            materials.setManager(textures);
            materials.preload();
            model = new OBJLoader().setMaterials(materials).parse(text);
            if (pending) await loaded;
        }
    }
    if (model === bare) bare.traverse(o => { if (o.isMesh) o.material = plainMaterial(o.geometry); });
    // OBJLoader gives every face vertices of its own and, when the file has no
    // normals (`vn`), a normal of its own: faceted, whatever the shading toggle
    // says, and a square counted as 6 vertices. Without authored normals, join
    // the shared corners again and smooth them.
    if (!/^\s*vn\s/m.test(text)) model.traverse(o => {
        if (!o.isMesh) return;
        const faceted = o.geometry;
        faceted.deleteAttribute("normal");
        o.geometry = mergeVertices(faceted);
        o.geometry.computeVertexNormals();
        faceted.dispose();
    });
    return { model, animations: [], notes };
}

const LOADERS = {
    glb: loadGLTF,
    gltf: loadGLTF,
    obj: loadOBJ,
    stl: async (url) => ({ model: meshOf(await new STLLoader().loadAsync(url)), animations: [], notes: [] }),
    ply: async (url) => {
        const geometry = await new PLYLoader().loadAsync(url);
        return { model: geometry.index ? meshOf(geometry) : cloudOf(geometry), animations: [], notes: [] };
    },
    off: async (url) => ({ model: meshOf(parseOFF(await new THREE.FileLoader().loadAsync(url))),
                           animations: [], notes: [] }),
};

// Image-based light from a neutral studio: PBR materials look as meant without
// guessing at a light rig per file, and an untextured mesh keeps its shape
// readable. Rendered into a texture, so it dies with the GL context.
function studio(renderer) {
    const pmrem = new THREE.PMREMGenerator(renderer);
    const room = new RoomEnvironment();
    const env = pmrem.fromScene(room, 0.04).texture;
    room.dispose();
    pmrem.dispose();
    return env;
}

/**
 * Mount the viewer for the `format` file (its extension) at `url` into `root`.
 *
 * `root` is the `.bt-mesh-view` element the Julia side rendered: it already
 * carries the canvas, the toolbar buttons and the status line, so this only
 * wires behaviour. Called by the file-view driver (assets/fileview.js) when such
 * a node appears. Returns a `dispose()`; the viewer also disposes itself when
 * its canvas leaves the document.
 */
export async function mount(root, url, format) {
    const status = root.querySelector(".bt-mesh-status");
    const canvas = root.querySelector("canvas.bt-mesh-canvas");
    if (!canvas) return () => {};
    try {
        return await mountViewer(root, url, format, status, canvas);
    } catch (err) {
        // A rejected async mount is otherwise silent: the viewer just sits
        // there empty. Put the reason where the user is looking.
        if (status) status.textContent = "3D viewer failed: " + explain(err);
        console.error("bt-mesh: mount failed", err);
        return () => {};
    }
}

async function mountViewer(root, url, format, status, canvas) {
    const say = (text) => { if (status) status.textContent = text; };
    say("loading…");
    // preserveDrawingBuffer keeps the last frame readable (a screenshot, a pixel
    // check) at no cost that matters for a preview.
    const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: true });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.NeutralToneMapping;

    // The drawing buffer at the canvas' size; true when that changed. three.js
    // floors the size, so comparing against a rounded one would resize (and so
    // clear) on every frame at a fractional pixel ratio.
    const fit = () => {
        const w = Math.max(1, canvas.clientWidth), h = Math.max(1, canvas.clientHeight);
        const px = renderer.getPixelRatio();
        if (canvas.width === Math.floor(w * px) && canvas.height === Math.floor(h * px)) return false;
        renderer.setSize(w, h, false);
        return true;
    };

    const scene = new THREE.Scene();
    const background = new THREE.Color(0.97, 0.98, 0.99);
    scene.background = background;
    scene.environment = studio(renderer);
    // Show the empty stage while the model loads (seconds, for a big one): a
    // buffer nobody has drawn to shows as a black panel.
    fit();
    renderer.setClearColor(background);
    renderer.clear();

    const load = LOADERS[format];
    let loaded;
    try {
        if (!load) throw new Error(`no 3D reader for .${format} files`);
        loaded = await load(url);
    } catch (err) {
        scene.environment.dispose();
        renderer.dispose();
        say("could not load this model: " + explain(err));
        return () => {};
    }
    const { model, animations, notes } = loaded;
    scene.add(model);

    // What is in it, for the status line.
    let tris = 0, verts = 0, points = 0;
    const textures = new Set(), materials = new Set();
    model.traverse((o) => {
        if (!o.isMesh && !o.isPoints) return;
        const g = o.geometry;
        if (o.isPoints) {
            points += g.attributes.position.count;
        } else {
            verts += g.attributes.position.count;
            tris += (g.index ? g.index.count : g.attributes.position.count) / 3;
        }
        (Array.isArray(o.material) ? o.material : [o.material]).forEach((m) => {
            materials.add(m);
            for (const k of Object.keys(m)) if (m[k] && m[k].isTexture) textures.add(m[k]);
        });
    });
    const parts = [];
    if (verts || !points) parts.push(count(Math.round(tris), "triangle", "triangles"), count(verts, "vertex", "vertices"));
    if (points) parts.push(count(points, "point", "points"));
    if (textures.size) parts.push(count(textures.size, "texture", "textures"));
    if (animations.length) parts.push(count(animations.length, "animation", "animations"));
    const summary = [...parts, ...notes].join(" · ");
    say(summary);

    // Frame the bounding box.
    const box = new THREE.Box3().setFromObject(model);
    const center = box.isEmpty() ? new THREE.Vector3() : box.getCenter(new THREE.Vector3());
    const radius = box.isEmpty() ? 1 : Math.max(box.getSize(new THREE.Vector3()).length() / 2, 1e-6);
    const camera = new THREE.PerspectiveCamera(45, 1, radius * 1e-3, radius * 100);
    const home = center.clone().add(new THREE.Vector3(0.6, 0.45, 1).normalize().multiplyScalar(radius * 2.6));
    camera.position.copy(home);
    // Classic (non-PBR) materials, an OBJ's .mtl ones, ignore the studio light:
    // they get a headlight riding on the camera and a sky/ground fill.
    if ([...materials].some(m => m.isMeshPhongMaterial || m.isMeshLambertMaterial)) {
        scene.add(new THREE.HemisphereLight(0xffffff, 0x8d8d8d, 1.5));
        // A directional light aims at its target, which stays at the world
        // origin unless it rides along too.
        const head = new THREE.DirectionalLight(0xffffff, 1.5);
        head.target.position.set(0, 0, -1);
        camera.add(head, head.target);
        scene.add(camera);
    }
    const controls = new OrbitControls(camera, canvas);
    controls.target.copy(center);
    controls.minDistance = radius * 0.02;
    controls.maxDistance = radius * 50;
    controls.update();

    const mixer = animations.length ? new THREE.AnimationMixer(model) : null;
    if (mixer) animations.forEach(clip => mixer.clipAction(clip).play());
    const clock = new THREE.Clock();


    // The wireframe is an OVERLAY: a second pass drawing every triangle's edges
    // over the shaded surface, which is pushed back a little (polygon offset) so
    // the lines don't z-fight into dashes. The background has to go for that
    // pass: a colour background clears the frame even with autoClear off.
    const wireMat = new THREE.MeshBasicMaterial({ color: 0x172136, wireframe: true });
    let wireframe = false, flat = false;
    function render() {
        renderer.render(scene, camera);
        if (!wireframe) return;
        scene.overrideMaterial = wireMat;
        scene.background = null;
        renderer.autoClear = false;
        renderer.render(scene, camera);
        renderer.autoClear = true;
        scene.background = background;
        scene.overrideMaterial = null;
    }

    // Draw when something changed; an animated scene draws every frame.
    let frame = 0, alive = true;
    const draw = () => {
        frame = 0;
        if (!alive) return;
        if (fit() || camera.aspect !== canvas.width / canvas.height) {
            camera.aspect = canvas.width / canvas.height;
            camera.updateProjectionMatrix();
        }
        if (mixer) mixer.update(clock.getDelta());
        render();
        if (mixer) invalidate();
    };
    const invalidate = () => { if (alive && !frame) frame = requestAnimationFrame(draw); };
    controls.addEventListener("change", invalidate);

    const onClick = (e) => {
        const btn = e.target.closest("[data-mesh-action]");
        if (!btn) return;
        const action = btn.dataset.meshAction;
        if (action === "reset") {
            camera.position.copy(home);
            controls.target.copy(center);
            controls.update();
        } else if (action === "wire") {
            wireframe = !wireframe;
            btn.dataset.on = wireframe ? "1" : "0";
            materials.forEach(m => {
                m.polygonOffset = wireframe;
                m.polygonOffsetFactor = 1;
                m.polygonOffsetUnits = 1;
            });
        } else if (action === "flat") {
            // Unlit materials have no shading to flatten.
            flat = !flat;
            btn.dataset.on = flat ? "1" : "0";
            materials.forEach(m => {
                if (!("flatShading" in m)) return;
                m.flatShading = flat;
                m.needsUpdate = true;
            });
        }
        invalidate();
    };
    root.addEventListener("click", onClick);
    const ro = new ResizeObserver(invalidate);
    ro.observe(canvas);

    // Chromium's GPU process can exit under load ("GPU process exited
    // unexpectedly: exit_code=512") and take every live context with it. The
    // renderer handles the protocol itself (it preventDefault()s the loss, which
    // is what lets the browser restore, and rebuilds its GL state on restore);
    // what it cannot rebuild is the studio light, rendered into a texture that
    // died with the context. Its listeners were added first, so ours run after.
    const onLost = () => say("3D viewer: graphics context lost, waiting for it to come back…");
    const onRestored = () => {
        scene.environment.dispose();
        scene.environment = studio(renderer);
        say(summary);
        invalidate();
    };
    canvas.addEventListener("webglcontextlost", onLost);
    canvas.addEventListener("webglcontextrestored", onRestored);

    // Closed, or moved away for good: release the GPU side (browsers cap live
    // WebGL contexts at ~16). A workspace move detaches and re-attaches within a
    // frame, so only a canvas still gone a moment later counts.
    const dispose = () => {
        if (!alive) return;
        alive = false;
        ro.disconnect();
        root.removeEventListener("click", onClick);
        canvas.removeEventListener("webglcontextlost", onLost);
        canvas.removeEventListener("webglcontextrestored", onRestored);
        controls.dispose();
        model.traverse((o) => { if (o.isMesh) o.geometry.dispose(); });
        materials.forEach(m => m.dispose());
        textures.forEach(t => t.dispose());
        wireMat.dispose();
        scene.environment.dispose();
        renderer.dispose();
        renderer.forceContextLoss();
    };
    const mo = new MutationObserver(() => {
        if (canvas.isConnected) return;
        setTimeout(() => { if (!canvas.isConnected) { mo.disconnect(); dispose(); } }, 250);
    });
    if (canvas.parentElement) mo.observe(canvas.parentElement, { childList: true });

    invalidate();
    return dispose;
}

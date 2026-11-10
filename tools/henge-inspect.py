#!/usr/bin/env python3
"""Henge GPU inspector: lists the meshes the Mac draws, hides or solos them live, and shows one in 3D the way the
GPU places it, with the vertices whose part or bone data is out of range in red.

    Phone: HV_INSPECT=1 in Documents/henge-env.txt, then start the Mac (devices/pvg_metal.m, insp_serve).
    iproxy 15902:5902 &
    python3 tools/henge-inspect.py          # then open http://127.0.0.1:8765

The page talks to this script, which passes each request on to Henge as one JSON line and its reply back.
"""
import http.server, json, socket, sys, threading, webbrowser

PHONE = ("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 15902)
PORT = 8765
lock = threading.Lock()
conn = rfile = None


def ask(body):
    """One request to Henge, one reply; reconnects once if the phone side went away."""
    global conn, rfile
    with lock:
        for attempt in (0, 1):
            try:
                if conn is None:
                    conn = socket.create_connection(PHONE, timeout=60)
                    rfile = conn.makefile("rb")
                conn.sendall(body.strip() + b"\n")
                line = rfile.readline()
                if not line:
                    raise OSError("connection closed")
                return line
            except OSError as e:
                conn = None
                if attempt:
                    return json.dumps({"error": f"can't reach Henge's inspector at {PHONE[0]}:{PHONE[1]}: {e}. "
                                       "Is HV_INSPECT=1 set and iproxy 15902:5902 running?"}).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.reply(200, "text/html; charset=utf-8", PAGE.encode())

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.reply(200, "application/json", ask(body))

    def reply(self, code, kind, data):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Henge Inspector</title>
<style>
:root { --bg:#14161a; --panel:#1c1f25; --line:#2c3038; --text:#e4e6ea; --dim:#9097a3; --accent:#5aa9ff; --bad:#ff4d4d; --ok:#4cc38a; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:13px/1.4 system-ui, sans-serif; height:100vh; display:grid; grid-template-columns:minmax(360px, 34%) 1fr; }
#side { border-right:1px solid var(--line); display:flex; flex-direction:column; min-height:0; }
#bar { padding:10px; display:flex; flex-wrap:wrap; gap:6px; border-bottom:1px solid var(--line); background:var(--panel); }
button, select, input[type=text] { background:#262a32; color:var(--text); border:1px solid var(--line); border-radius:6px; padding:5px 9px; font:inherit; }
button:hover { border-color:var(--accent); cursor:pointer; }
button.on { background:var(--accent); color:#000; border-color:var(--accent); }
#status { padding:6px 10px; color:var(--dim); border-bottom:1px solid var(--line); min-height:28px; }
#list { overflow:auto; flex:1; }
table { width:100%; border-collapse:collapse; }
th { position:sticky; top:0; background:var(--panel); text-align:left; font-weight:600; color:var(--dim); padding:5px 6px; border-bottom:1px solid var(--line); cursor:pointer; }
td { padding:4px 6px; border-bottom:1px solid #22252c; white-space:nowrap; }
tr.sel td { background:#24324a; }
tr:hover td { background:#20242c; }
tr.hidden td { opacity:.45; }
.kind { font-size:11px; padding:1px 6px; border-radius:9px; background:#2a2f39; color:var(--dim); }
.kind.rigid { color:#ffb454; } .kind.skinned { color:#7fd6ff; } .kind.depth { color:#a5a5a5; }
.badge { font-weight:700; } .badge.bad { color:var(--bad); } .badge.ok { color:var(--ok); }
#main { display:grid; grid-template-rows:auto 1fr minmax(120px, 34%); min-width:0; min-height:0; }
#viewbar { padding:8px 10px; display:flex; gap:6px; align-items:center; flex-wrap:wrap; border-bottom:1px solid var(--line); background:var(--panel); }
#view { position:relative; min-height:0; }
#view canvas { display:block; width:100%; height:100%; }
#legend { position:absolute; left:10px; bottom:10px; color:var(--dim); font-size:12px; background:#0009; padding:6px 8px; border-radius:6px; }
#info { overflow:auto; border-top:1px solid var(--line); padding:8px 10px; font:12px/1.45 ui-monospace, monospace; }
#info .bad { color:var(--bad); }
.small { color:var(--dim); font-size:12px; }
</style>
<script type="importmap">{ "imports": { "three": "https://unpkg.com/three@0.160.0/build/three.module.js",
  "three/addons/": "https://unpkg.com/three@0.160.0/examples/jsm/" } }</script>
</head><body>
<div id="side">
  <div id="bar">
    <button id="capture" title="Record the meshes drawn over the next quarter second">Capture</button>
    <button id="scan" title="Fetch every rigid and skinned mesh and count its bad vertices">Scan all</button>
    <select id="filter"><option value="">All meshes</option><option value="rigid">Rigid (body, accessories)</option>
      <option value="skinned">Skinned (layered clothing)</option><option value="bad">With bad vertices</option><option value="hidden">Hidden</option></select>
    <button id="showall" title="Draw everything again">Show all</button>
  </div>
  <div id="status">Press Capture while the Mac shows the scene.</div>
  <div id="list"><table><thead><tr><th></th><th data-k="kind">Kind</th><th data-k="count">Indices</th><th data-k="verts">Verts</th>
    <th data-k="draws">Draws</th><th data-k="pipe">Pipe</th><th data-k="bad">Bad</th><th></th></tr></thead><tbody id="rows"></tbody></table></div>
</div>
<div id="main">
  <div id="viewbar">
    <span id="title" class="small">No mesh selected</span>
    <span style="flex:1"></span>
    <button id="world" class="on" title="Where the GPU puts it, through its bones">World</button>
    <button id="raw" title="The mesh as stored, before bones">Raw</button>
    <button id="wire" title="Wireframe">Wire</button>
    <button id="badonly" title="Only the triangles touching bad vertices">Bad only</button>
    <button id="fit">Fit</button>
  </div>
  <div id="view"><div id="legend">Colour: part/bone · <span style="color:var(--bad)">red: bone out of range (GPU reads garbage)</span> · <span style="color:#ff9a1a">orange: bone not a whole number</span> · drag to orbit, scroll to zoom</div></div>
  <div id="info" class="small">Mesh details appear here.</div>
</div>
<script type="module">
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const $ = id => document.getElementById(id);
const api = req => fetch('/api', { method: 'POST', body: JSON.stringify(req) }).then(r => r.json());
let meshes = [], hidden = new Set(), hiddenPipes = new Set(), solo = null, selected = null, sortKey = 'count', sortDir = -1;
let world = true, wire = false, badOnly = false, current = null;

const kindOf = m => m.name.includes('vl17:16') ? 'rigid' : m.name.includes('vl17:24') ? 'skinned'
  : / fmt 0 /.test(m.name) ? 'depth' : 'other';
const passOf = m => / fmt 0 /.test(m.name) ? 'depth' : 'color';

// three.js view
const view = $('view'), renderer = new THREE.WebGLRenderer({ antialias: true });
view.prepend(renderer.domElement);
const scene = new THREE.Scene(); scene.background = new THREE.Color(0x101216);
const camera = new THREE.PerspectiveCamera(50, 1, 0.001, 1e6);
const controls = new OrbitControls(camera, renderer.domElement);
let group = new THREE.Group(); scene.add(group);
function resize() { const r = view.getBoundingClientRect(); renderer.setSize(r.width, r.height, false); camera.aspect = r.width / Math.max(1, r.height); camera.updateProjectionMatrix(); }
new ResizeObserver(resize).observe(view); resize();
(function loop() { requestAnimationFrame(loop); controls.update(); renderer.render(scene, camera); })();

function dv(b64) { const s = atob(b64 || ''), u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i); return new DataView(u.buffer); }

// Rebuild a mesh as the GPU does: rigid parts take a bone from the part table (CB11[part].second.w), skinned
// vertices blend up to four bones; bone matrices are 3 rows of float4 in CB1.
function decode(m) {
  const kind = kindOf(m), size = m.index_type === 1 ? 4 : 2, idx = dv(m.indices), n = m.count;
  const nv = (m.max - m.min) + 1, s16 = m.streams?.['16'], s17 = m.streams?.['17'];
  const pos = s16 ? dv(s16.data) : null, att = s17 ? dv(s17.data) : null;
  const cb1 = m.consts?.['1'] ? dv(m.consts['1']) : null, cb11 = m.consts?.['11'] ? dv(m.consts['11']) : null;
  // bad 1: out of range, the GPU reads some other memory for it (red); bad 2: a bone index that isn't a whole number,
  // which the GPU truncates and uses (orange): real indices are whole numbers, so the part entry is not one.
  const raw = new Float32Array(nv * 3), out = new Float32Array(nv * 3), part = new Int32Array(nv).fill(-1), bad = new Uint8Array(nv);
  const tableUse = new Map(), reasons = [];
  const f = (d, o) => d.getFloat32(o, true);
  const bone = (b, p) => { const o = b * 48; if (!cb1 || o + 48 > cb1.byteLength) return null;
    return [0, 1, 2].map(k => f(cb1, o + k*16) * p[0] + f(cb1, o + k*16 + 4) * p[1] + f(cb1, o + k*16 + 8) * p[2] + f(cb1, o + k*16 + 12)); };
  for (let v = 0; v < nv; v++) {
    const p = pos && (v * s16.stride + 12 <= pos.byteLength) ? [f(pos, v*s16.stride), f(pos, v*s16.stride + 4), f(pos, v*s16.stride + 8)] : [0, 0, 0];
    raw.set(p, v * 3);
    let w = p;
    if (kind === 'rigid' && att && cb11 && v * s17.stride + 5 <= att.byteLength) {
      const c = att.getUint8(v * s17.stride + 4); part[v] = c;
      const e = c * 32, b = e + 32 <= cb11.byteLength ? f(cb11, e + 28) : NaN;
      if (!tableUse.has(c)) tableUse.set(c, { verts: 0, bone: b, entry: e + 32 <= cb11.byteLength ? [...Array(8)].map((_, i) => f(cb11, e + i*4)) : null });
      tableUse.get(c).verts++;
      const t = Math.trunc(b), inRange = Number.isFinite(b) && t >= 0 && t < 72;
      const q = inRange ? bone(t, p) : null;
      if (q && q.every(Number.isFinite)) { w = q; if (Math.abs(b - t) > 1e-3) bad[v] = 2; } else bad[v] = 1;
    } else if (kind === 'skinned' && att && v * s17.stride + 24 <= att.byteLength) {
      const acc = [0, 0, 0]; let sum = 0;
      for (let k = 0; k < 4; k++) {
        const b = att.getUint8(v * s17.stride + 16 + k), wt = att.getUint8(v * s17.stride + 20 + k) / 255;
        if (!wt) continue; sum += wt;
        if (k === 0) part[v] = b;
        const q = b < 72 ? bone(b, p) : null;
        if (!q || !q.every(Number.isFinite)) { bad[v] = 1; continue; }
        for (let i = 0; i < 3; i++) acc[i] += wt * q[i];
      }
      if (Math.abs(sum - 1) > 0.02) bad[v] = 1;
      if (!bad[v]) w = acc;
    }
    out.set(w, v * 3);
  }
  const tris = [];
  for (let i = 0; i + 2 < n; i += 3) for (let k = 0; k < 3; k++) tris.push((size === 4 ? idx.getUint32((i + k) * 4, true) : idx.getUint16((i + k) * 2, true)) - m.min);
  let badCount = 0, oddCount = 0;
  for (const x of bad) { if (x === 1) badCount++; else if (x === 2) oddCount++; }
  return { kind, raw, out, part, bad, tris, nv, tableUse, badCount, oddCount };
}

function show(m, d) {
  scene.remove(group); group = new THREE.Group(); scene.add(group);
  const P = world ? d.out : d.raw, colors = new Float32Array(d.nv * 3), col = new THREE.Color();
  const good = [];
  for (let v = 0; v < d.nv; v++) {
    if (d.bad[v] === 1) col.setRGB(1, 0.2, 0.2); else if (d.bad[v] === 2) col.setRGB(1, 0.6, 0.1); else col.setHSL(((d.part[v] < 0 ? 0 : d.part[v]) * 0.137) % 1, 0.55, 0.6);
    colors.set([col.r, col.g, col.b], v * 3);
    if (d.bad[v] !== 1 && Number.isFinite(P[v*3]) && Number.isFinite(P[v*3+1]) && Number.isFinite(P[v*3+2])) good.push(v);
  }
  const safe = P.map(x => Number.isFinite(x) ? Math.max(-1e5, Math.min(1e5, x)) : 0);
  const tris = badOnly ? d.tris.filter((_, i, a) => { const t = i - i % 3; return d.bad[a[t]] || d.bad[a[t+1]] || d.bad[a[t+2]]; }) : d.tris;
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(safe, 3));
  g.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  g.setIndex(tris);
  group.add(wire ? new THREE.LineSegments(new THREE.WireframeGeometry(g), new THREE.LineBasicMaterial({ vertexColors: true }))
                 : new THREE.Mesh(g, new THREE.MeshBasicMaterial({ vertexColors: true, side: THREE.DoubleSide })));
  const badIdx = []; for (let v = 0; v < d.nv; v++) if (d.bad[v] === 1) badIdx.push(v);
  if (badIdx.length) {
    const bg = new THREE.BufferGeometry(); bg.setAttribute('position', new THREE.BufferAttribute(safe, 3)); bg.setIndex(badIdx);
    group.add(new THREE.Points(bg, new THREE.PointsMaterial({ color: 0xff3030, size: 5, sizeAttenuation: false })));
  }
  fit(safe, good.length ? good : [...Array(d.nv).keys()]);
}

function fit(P, which) {
  const box = new THREE.Box3(), v = new THREE.Vector3();
  for (const i of which) box.expandByPoint(v.set(P[i*3], P[i*3+1], P[i*3+2]));
  const c = box.getCenter(new THREE.Vector3()), r = Math.max(box.getSize(new THREE.Vector3()).length() / 2, 1e-3);
  controls.target.copy(c); camera.position.copy(c).add(new THREE.Vector3(0, r * 0.3, r * 2.4)); camera.near = r / 1000; camera.far = r * 1e4; camera.updateProjectionMatrix();
}

function details(m, d) {
  const lines = [];
  lines.push(`<b>${d.kind}</b> · ${m.count} indices · ${d.nv} vertices · drawn ${m.draws}x in the capture · pipe ${m.pipe} (${passOf(m)} pass) · <span class="${d.badCount ? 'bad' : ''}">${d.badCount} bad vertices</span> · <span style="color:#ff9a1a">${d.oddCount} suspicious</span>`);
  lines.push(`<span class="small">${m.name}</span>`);
  if (d.kind === 'rigid') {
    lines.push('<br>part → table entry (CB11[part]: first float4 | second float4; second.w is the bone)');
    for (const [c, u] of [...d.tableUse].sort((a, b) => a[0] - b[0])) {
      const t = Math.trunc(u.bone), inRange = Number.isFinite(u.bone) && t >= 0 && t < 72, whole = Math.abs(u.bone - t) < 1e-3;
      const e = u.entry ? u.entry.map(x => x.toPrecision(4)).join(' ') : '(past the captured table)';
      const what = !inRange ? `BAD ${u.bone}` : whole ? `${t}` : `${t} (from ${u.bone.toPrecision(5)}: not a whole number)`;
      lines.push(`<span class="${!inRange ? 'bad' : ''}" style="${inRange && !whole ? 'color:#ff9a1a' : ''}">part ${String(c).padStart(3)}: ${String(u.verts).padStart(5)} verts · bone ${what} · ${e}</span>`);
    }
  }
  $('info').innerHTML = lines.join('<br>');
  $('title').textContent = `${d.kind} mesh · ${m.count} indices · pipe ${m.pipe}`;
}

async function select(m) {
  selected = m.key; renderList();
  $('status').textContent = 'Fetching mesh…';
  const full = await api({ op: 'mesh', key: m.key });
  if (full.error) { $('status').textContent = full.error; return; }
  const d = decode(full); m.bad = d.badCount; m.verts = d.nv; current = { m: full, d };
  show(full, d); details(full, d); renderList();
  m.odd = d.oddCount;
  $('status').textContent = `${d.badCount} bad, ${d.oddCount} suspicious vertices in this mesh.`;
}

function sendHide() { return api({ op: 'hide', keys: [...hidden], pipes: [...hiddenPipes], solo }); }

function renderList() {
  const f = $('filter').value;
  const rows = meshes.filter(m => !f || (f === 'bad' ? (m.bad > 0 || m.odd > 0) : f === 'hidden' ? hidden.has(m.key) || hiddenPipes.has(m.pipe) : kindOf(m) === f));
  rows.sort((a, b) => { const k = sortKey; const x = k === 'kind' ? kindOf(a) : a[k] ?? -1, y = k === 'kind' ? kindOf(b) : b[k] ?? -1; return (x > y ? 1 : x < y ? -1 : 0) * sortDir; });
  $('rows').innerHTML = rows.map(m => {
    const k = kindOf(m), hid = hidden.has(m.key) || hiddenPipes.has(m.pipe);
    const badge = m.bad === undefined ? '' : (m.bad || m.odd) ? `<span class="badge bad">${m.bad}</span>${m.odd ? ` <span class="badge" style="color:#ff9a1a">${m.odd}</span>` : ''}` : '<span class="badge ok">✓</span>';
    return `<tr data-key="${m.key}" class="${m.key === selected ? 'sel' : ''} ${hid ? 'hidden' : ''}">
      <td><input type="checkbox" ${hid ? '' : 'checked'} title="Drawn"></td><td><span class="kind ${k}">${k}</span> <span class="small">${passOf(m)}</span></td>
      <td>${m.count}</td><td>${m.verts ?? (m.max - m.min + 1)}</td><td>${m.draws}</td><td>${m.pipe}</td><td>${badge}</td>
      <td><button class="solo ${solo === m.key ? 'on' : ''}" title="Draw only this">Solo</button></td></tr>`; }).join('');
  $('status').textContent = $('status').textContent || '';
}

$('rows').addEventListener('click', async ev => {
  const tr = ev.target.closest('tr'); if (!tr) return;
  const m = meshes.find(x => x.key === tr.dataset.key);
  if (ev.target.type === 'checkbox') { ev.target.checked ? hidden.delete(m.key) : hidden.add(m.key); await sendHide(); renderList(); return; }
  if (ev.target.classList.contains('solo')) { solo = solo === m.key ? null : m.key; await sendHide(); renderList(); return; }
  select(m);
});
document.querySelectorAll('th[data-k]').forEach(th => th.onclick = () => { sortDir = sortKey === th.dataset.k ? -sortDir : -1; sortKey = th.dataset.k; renderList(); });
$('filter').onchange = renderList;
$('capture').onclick = async () => {
  $('status').textContent = 'Capturing…';
  const r = await api({ op: 'capture', seconds: 0.25 });
  if (r.error) { $('status').textContent = r.error; return; }
  const old = new Map(meshes.map(m => [m.key, m])); meshes = r.meshes.filter(m => m.indices !== undefined || m.count);
  for (const m of meshes) { const o = old.get(m.key); if (o) { m.bad = o.bad; m.verts = o.verts; } }
  $('status').textContent = `${meshes.length} meshes captured. Click one to inspect it, or Scan all.`; renderList();
};
$('scan').onclick = async () => {
  const todo = meshes.filter(m => ['rigid', 'skinned'].includes(kindOf(m)));
  let i = 0, badMeshes = 0;
  for (const m of todo) {
    $('status').textContent = `Scanning ${++i}/${todo.length}…`;
    const full = await api({ op: 'mesh', key: m.key }); if (full.error) continue;
    const d = decode(full); m.bad = d.badCount; m.odd = d.oddCount; m.verts = d.nv; if (d.badCount || d.oddCount) badMeshes++;
    if (i % 5 === 0) renderList();
  }
  $('status').textContent = `${badMeshes} of ${todo.length} meshes have bad or suspicious vertices. Filter "With bad vertices" to list them.`; renderList();
};
$('showall').onclick = async () => { hidden.clear(); hiddenPipes.clear(); solo = null; await sendHide(); renderList(); };
const toggle = (id, set) => $(id).onclick = () => { set(); if (current) { show(current.m, current.d); } };
toggle('world', () => { world = true; $('world').classList.add('on'); $('raw').classList.remove('on'); });
toggle('raw', () => { world = false; $('raw').classList.add('on'); $('world').classList.remove('on'); });
toggle('wire', () => { wire = !wire; $('wire').classList.toggle('on', wire); });
toggle('badonly', () => { badOnly = !badOnly; $('badonly').classList.toggle('on', badOnly); });
$('fit').onclick = () => current && show(current.m, current.d);
</script></body></html>
"""

if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    url = f"http://127.0.0.1:{PORT}"
    print(f"Henge inspector at {url} (Henge at {PHONE[0]}:{PHONE[1]})", flush=True)
    threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    server.serve_forever()

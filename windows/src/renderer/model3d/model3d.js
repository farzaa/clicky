import * as THREE from '../../../node_modules/three/build/three.module.js';

/* Interactive 3D model viewer: parts come from the model as simple primitives. */
const api = window.clicky;
const cv = document.getElementById('cv');
const loading = document.getElementById('loading');
const loadtxt = document.getElementById('loadtxt');
const titleEl = document.getElementById('title');
const infoEl = document.getElementById('info');
const labelEl = document.getElementById('label');

const renderer = new THREE.WebGLRenderer({ canvas: cv, antialias: true, alpha: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
renderer.setClearColor(0x000000, 0);
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 100);
const pivot = new THREE.Group();
scene.add(pivot);
scene.add(new THREE.HemisphereLight(0xdbe8ff, 0x1a1f2b, 1.1));
const key = new THREE.DirectionalLight(0xffffff, 2.2);
key.position.set(4, 6, 5);
scene.add(key);
const rim = new THREE.DirectionalLight(0x3380ff, 1.4);
rim.position.set(-5, 2, -4);
scene.add(rim);

const view = { yaw: 0.6, pitch: 0.28, dist: 8.5, auto: true, vyaw: 0 };
const DEFAULT_VIEW = { yaw: 0.6, pitch: 0.28, dist: 8.5 };
let meshes = [];
let selected = null;
let currentModel = null;

function resize() {
  const r = cv.getBoundingClientRect();
  const w = Math.max(10, Math.floor(r.width));
  const h = Math.max(10, Math.floor(r.height));
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
}
new ResizeObserver(resize).observe(cv);

function num(v, d) {
  const n = Number(v);
  return Number.isFinite(n) ? n : d;
}
function vec3(a, d) {
  const arr = Array.isArray(a) ? a : [];
  return [num(arr[0], d[0]), num(arr[1], d[1]), num(arr[2], d[2])];
}

function geometryFor(shape, size) {
  const [a, b, c] = size.map((v) => Math.max(0.02, Math.abs(v)));
  switch (shape) {
    case 'sphere': return new THREE.SphereGeometry(a, 40, 28);
    case 'cylinder': return new THREE.CylinderGeometry(a, a, b, 40);
    case 'cone': return new THREE.ConeGeometry(a, b, 40);
    case 'torus': return new THREE.TorusGeometry(a, Math.min(b, a * 0.9), 20, 56);
    case 'capsule': return new THREE.CapsuleGeometry(a, Math.max(0.02, b), 10, 24);
    default: return new THREE.BoxGeometry(a, b, c);
  }
}

function clearModel() {
  for (const m of meshes) {
    m.geometry.dispose();
    m.material.dispose();
    pivot.remove(m);
  }
  meshes = [];
  selected = null;
}

function buildModel(model) {
  clearModel();
  currentModel = model;
  const parts = (model.parts || []).slice(0, 60);
  parts.forEach((p, i) => {
    const mat = new THREE.MeshStandardMaterial({ color: new THREE.Color(/^#[0-9a-f]{6}$/i.test(p.color || '') ? p.color : '#6aa6ff'), roughness: 0.42, metalness: 0.15, emissive: 0x000000 });
    const mesh = new THREE.Mesh(geometryFor(p.shape, vec3(p.size, [1, 1, 1])), mat);
    const pos = vec3(p.position, [0, 0, 0]);
    mesh.position.set(pos[0], pos[1], pos[2]);
    const rot = vec3(p.rotation, [0, 0, 0]);
    mesh.rotation.set(THREE.MathUtils.degToRad(rot[0]), THREE.MathUtils.degToRad(rot[1]), THREE.MathUtils.degToRad(rot[2]));
    mesh.userData = { name: String(p.name || 'Part ' + (i + 1)), info: String(p.info || ''), base: mat.color.clone() };
    mesh.userData.delay = 0.04 * i;
    pivot.add(mesh);
    meshes.push(mesh);
  });
  // parts that enclose other parts (cell wall, shell, body) become glass so the inside stays visible
  meshes.forEach((m) => {
    m.updateMatrixWorld(true);
    const b = new THREE.Box3().setFromObject(m);
    const inside = meshes.filter((o) => o !== m && b.containsPoint(o.position)).length;
    if (inside >= 2) {
      m.material.transparent = true;
      m.material.opacity = 0.26;
      m.material.depthWrite = false;
      m.renderOrder = -1;
      m.userData.glass = true;
    }
  });
  // centre + fit
  pivot.updateMatrixWorld(true);
  const box = new THREE.Box3().setFromObject(pivot);
  const centre = box.getCenter(new THREE.Vector3());
  const size = box.getSize(new THREE.Vector3());
  meshes.forEach((m) => {
    m.position.sub(centre);
    m.scale.setScalar(0.001); // pop-in starts after bounds are measured at full size
  });
  const radius = Math.max(size.length() * 0.5, 0.5);
  const fov = THREE.MathUtils.degToRad(camera.fov) * 0.5;
  const fit = radius / Math.sin(Math.min(fov, Math.atan(Math.tan(fov) * camera.aspect)));
  view.dist = DEFAULT_VIEW.dist = Math.max(3.5, fit * 1.12);
  titleEl.textContent = model.title || 'Model';
  setInfo(null);
  loading.classList.add('hide');
}

function setInfo(mesh) {
  selected = mesh;
  meshes.forEach((m) => {
    m.material.emissive.setHex(m === mesh ? 0x2255aa : 0x000000);
  });
  if (!mesh) {
    infoEl.innerHTML = '<span class="muted">Drag to rotate, scroll to zoom, click a part to learn about it.</span>';
    return;
  }
  const d = mesh.userData;
  infoEl.innerHTML = `<div><b></b><span class="secondary"></span></div><button class="btn btn-secondary ask">Ask Clicky</button>`;
  infoEl.querySelector('b').textContent = d.name;
  infoEl.querySelector('span').textContent = d.info;
  infoEl.querySelector('.ask').addEventListener('click', () => {
    api.invoke('model3d:ask', { title: titleEl.textContent, part: d.name, info: d.info });
  });
}

// ---------------------------------------------------------------- interaction
const ray = new THREE.Raycaster();
const ndc = new THREE.Vector2();
let drag = null;

function pick(clientX, clientY) {
  const r = cv.getBoundingClientRect();
  ndc.set(((clientX - r.left) / r.width) * 2 - 1, -((clientY - r.top) / r.height) * 2 + 1);
  ray.setFromCamera(ndc, camera);
  const hit = ray.intersectObjects(meshes, false)[0];
  return hit ? hit.object : null;
}

cv.addEventListener('pointerdown', (e) => {
  cv.setPointerCapture(e.pointerId);
  drag = { x: e.clientX, y: e.clientY, moved: 0 };
  view.auto = false;
});
cv.addEventListener('pointermove', (e) => {
  if (drag) {
    const dx = e.clientX - drag.x;
    const dy = e.clientY - drag.y;
    drag.x = e.clientX;
    drag.y = e.clientY;
    drag.moved += Math.abs(dx) + Math.abs(dy);
    view.yaw -= dx * 0.008;
    view.pitch = Math.max(-1.35, Math.min(1.35, view.pitch + dy * 0.008));
  } else {
    const m = pick(e.clientX, e.clientY);
    cv.style.cursor = m ? 'pointer' : 'grab';
    if (m) {
      labelEl.textContent = m.userData.name;
      const r = cv.getBoundingClientRect();
      labelEl.style.left = e.clientX - r.left + 'px';
      labelEl.style.top = e.clientY - r.top + 'px';
      labelEl.classList.add('show');
    } else labelEl.classList.remove('show');
  }
});
cv.addEventListener('pointerup', (e) => {
  if (drag && drag.moved < 5) setInfo(pick(e.clientX, e.clientY));
  drag = null;
});
cv.addEventListener('pointerleave', () => labelEl.classList.remove('show'));
cv.addEventListener('wheel', (e) => {
  e.preventDefault();
  view.dist = Math.max(2.5, Math.min(30, view.dist * (1 + Math.sign(e.deltaY) * 0.08)));
}, { passive: false });
document.getElementById('reset').addEventListener('click', () => {
  Object.assign(view, DEFAULT_VIEW, { auto: true });
});
document.getElementById('close').addEventListener('click', () => api.invoke('window:control', { action: 'close' }));

// ---------------------------------------------------------------- loop
let last = performance.now();
function frame(now) {
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;
  if (view.auto) view.yaw += dt * 0.35;
  camera.position.set(
    Math.sin(view.yaw) * Math.cos(view.pitch) * view.dist,
    Math.sin(view.pitch) * view.dist,
    Math.cos(view.yaw) * Math.cos(view.pitch) * view.dist
  );
  camera.lookAt(0, 0, 0);
  for (const m of meshes) {
    if (m.userData.delay > 0) m.userData.delay -= dt;
    else if (m.scale.x < 1) m.scale.setScalar(Math.min(1, m.scale.x + dt * 3.2 + (1 - m.scale.x) * dt * 6));
  }
  renderer.render(scene, camera);
  requestAnimationFrame(frame);
}
resize();
requestAnimationFrame(frame);

api.on('model3d:show', (payload) => {
  if (!payload) return;
  if (payload.state === 'loading') {
    clearModel();
    titleEl.textContent = payload.topic || '3D model';
    loadtxt.textContent = 'Building ' + (payload.topic || 'model') + '...';
    loading.classList.remove('hide');
  } else if (payload.state === 'error') {
    loadtxt.textContent = payload.message || 'Could not build that model.';
    loading.classList.remove('hide');
    loading.querySelector('.spin').style.display = 'none';
  } else if (payload.model) {
    loading.querySelector('.spin').style.display = '';
    buildModel(payload.model);
  }
});
api.invoke('model3d:ready');

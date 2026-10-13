// The four things on stage — the AI (a glass block with its transcript
// sealed inside), Ask Key (a frosted vault in the shape of the app icon, with
// the vermilion keys inside), the program ./deploy.sh (a graphite box with a
// keyhole) and the website it publishes — plus the paper slips and the
// threads that connect them, on an oiled walnut desk in morning light.
// Vermilion is reserved for the secret.
import * as THREE from "three";
import { RoundedBoxGeometry } from "three/examples/jsm/geometries/RoundedBoxGeometry.js";
import { mergeGeometries } from "three/examples/jsm/utils/BufferGeometryUtils.js";
import { canvasTexture, drawCard, drawChip, drawSite, drawProgramFace, shadowTexture, dotTexture, glowTexture, blurredShapesTexture } from "./textures.js";
import { glassMaterial, decalMaterial, deskMaterial, dissolveMaterial } from "./materials.js";
import { createTranscript } from "./transcript.js";
import { layoutScene } from "./layout.js";
import { daylightEnvironment } from "./room.js";

export const ZHU = new THREE.Color("#b8281e");
export const BG = "#ffffff";
const V3 = (x, y, z) => new THREE.Vector3(x, y, z);
const V2 = (x, y) => new THREE.Vector2(x, y);

function roundedPolygon(points, r) {
  const s = new THREE.Shape();
  const n = points.length;
  for (let i = 0; i < n; i++) {
    const p = points[i], a = points[(i - 1 + n) % n], b = points[(i + 1) % n];
    const da = a.clone().sub(p).normalize().multiplyScalar(r);
    const db = b.clone().sub(p).normalize().multiplyScalar(r);
    const p1 = p.clone().add(da), p2 = p.clone().add(db);
    if (i === 0) s.moveTo(p1.x, p1.y); else s.lineTo(p1.x, p1.y);
    s.quadraticCurveTo(p.x, p.y, p2.x, p2.y);
  }
  s.closePath();
  return s;
}

function capsulePath(cx, cy, w, h) {
  const p = new THREE.Path();
  const r = h / 2;
  p.moveTo(cx - w / 2 + r, cy - r);
  p.lineTo(cx + w / 2 - r, cy - r);
  p.absarc(cx + w / 2 - r, cy, r, -Math.PI / 2, Math.PI / 2, false);
  p.lineTo(cx - w / 2 + r, cy + r);
  p.absarc(cx - w / 2 + r, cy, r, Math.PI / 2, Math.PI * 1.5, false);
  return p;
}

// Key along +x: tip at the origin, bow at x = -0.5 (like the app icon's key).
function keyShapes() {
  const s = 0.13;
  const bow = roundedPolygon([V2(-0.5 - s, 0), V2(-0.5, -s), V2(-0.5 + s, 0), V2(-0.5, s)], 0.05);
  const hole = new THREE.Path();
  hole.absarc(-0.5, 0, 0.043, 0, Math.PI * 2, true);
  bow.holes.push(hole);
  const shaft = roundedPolygon([V2(-0.42, -0.034), V2(0, -0.034), V2(0, 0.034), V2(-0.42, 0.034)], 0.02);
  const t1 = roundedPolygon([V2(-0.11, -0.13), V2(-0.055, -0.13), V2(-0.055, -0.02), V2(-0.11, -0.02)], 0.018);
  const t2 = roundedPolygon([V2(-0.035, -0.105), V2(0, -0.105), V2(0, -0.02), V2(-0.035, -0.02)], 0.014);
  return [bow, shaft, t1, t2];
}

export function keyGeometry() {
  const ex = { depth: 0.05, bevelEnabled: true, bevelThickness: 0.014, bevelSize: 0.012, bevelSegments: 3, curveSegments: 20 };
  const g = mergeGeometries(keyShapes().map((sh) => new THREE.ExtrudeGeometry(sh, ex)));
  g.translate(0, 0, -0.025);
  g.computeVertexNormals();
  return g;
}

export function buildScene(renderer, I, paper, assets = {}) {
  const scene = new THREE.Scene();
  scene.environment = daylightEnvironment(renderer);
  scene.environmentIntensity = 1.0;

  // Morning: cool daylight from a window to the back left, a white room
  // bouncing light back. No shadow maps; contact shadows are decals.
  const sky = new THREE.HemisphereLight(0xf3f7ff, 0xe6dccf, 0.9);
  const sun = new THREE.DirectionalLight(0xf2f6ff, 2.2);
  sun.position.set(-5, 7, -4);
  scene.add(sky, sun);

  // Images arrive after the programs are compiled. Each material starts
  // with a 1×1 stand-in so its program already expects a texture, and the
  // real one is swapped in without a recompile mid-film.
  const standIn = () => {
    const t = new THREE.DataTexture(new Uint8Array([255, 255, 255, 0]), 1, 1);
    t.colorSpace = THREE.SRGBColorSpace;
    t.needsUpdate = true;
    return t;
  };
  const floorMat = deskMaterial();
  const uFloor = floorMat.userData.u;
  floorMat.map = standIn();
  floorMat.map.repeat.set(7, 7);
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(60, 60), floorMat);
  floor.rotation.x = -Math.PI / 2;
  scene.add(floor);
  if (assets.wood) new THREE.TextureLoader().load(assets.wood, (tex) => {
    tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
    // a tile is two planks, 5.5 wide by 4.25 deep: planks about 2 units
    tex.repeat.set(60 / 5.5, 60 / 4.25);
    tex.colorSpace = THREE.SRGBColorSpace;
    tex.anisotropy = 8;
    renderer.initTexture(tex);
    floorMat.map = tex;
    uFloor.uHasMap.value = 1;
    if (assets.onTexture) assets.onTexture();
  });

  const glowTex = glowTexture();
  const glow = (color, size, opacity = 1) => {
    const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: glowTex, color, transparent: true, opacity, depthWrite: false, toneMapped: false }));
    sp.scale.setScalar(size);
    return sp;
  };

  // Soft contact shadows, cast away from the window and a little blue.
  const shadowTex = shadowTexture();
  const shadow = (sx, sz, op = 1, color = 0x5b6475) => {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), decalMaterial({ map: shadowTex, color, opacity: op }));
    m.rotation.x = -Math.PI / 2;
    m.scale.set(sx, sz, 1);
    m.renderOrder = 1;
    return m;
  };

  // --- The AI: clear glass, transcript sealed inside -------------------------
  const agent = new THREE.Group();
  // Back faces and front faces as two meshes (back first, by creation
  // order): a double-sided transparent material would make three.js switch
  // its side and look its program up twice every frame.
  const clearGlass = { edgeColor: 0x3a525a, edgeMix: 1.0, specEdge: 0.7, base: 0.025, edge: 0.9, power: 2.2, roughness: 0.02, envMapIntensity: 1.2, key: "clear" };
  const slab = new RoundedBoxGeometry(2.6, 1.72, 0.3, 8, 0.12);
  const glassBack = new THREE.Mesh(slab, glassMaterial({ ...clearGlass, side: THREE.BackSide, key: "clear-back" }));
  agent.add(glassBack);
  const glass = new THREE.Mesh(slab, glassMaterial({ ...clearGlass, side: THREE.FrontSide }));
  agent.add(glass);
  const term = createTranscript(I, paper);
  // the sheet floats inside with a clear margin, so the glass reads as glass
  term.group.scale.setScalar(0.9);
  agent.add(term.group);
  const agentShadow = shadow(3.2, 0.95, 0.62);
  const agentLight = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), decalMaterial({ map: glowTex, color: 0xffffff, opacity: 0.55 }));
  agentLight.rotation.x = -Math.PI / 2;
  agentLight.renderOrder = 1;

  // --- Ask Key: a frosted vault shaped like the app icon -------------------
  const vault = new THREE.Group();
  const W = 1.5, H = 1.86, c = 0.36;
  const tag = roundedPolygon([V2(-W / 2, -H / 2), V2(W / 2, -H / 2), V2(W / 2, H / 2 - c), V2(W / 2 - c, H / 2), V2(-W / 2 + c, H / 2), V2(-W / 2, H / 2 - c)], 0.16);
  tag.holes.push(capsulePath(0, H / 2 - 0.25, 0.44, 0.1));
  const vg = new THREE.ExtrudeGeometry(tag, { depth: 0.52, bevelEnabled: true, bevelThickness: 0.07, bevelSize: 0.06, bevelSegments: 6, curveSegments: 24 });
  vg.center();
  const vaultMat = glassMaterial({ color: 0xc7ced5, edgeColor: 0xf1f4f7, edgeMix: 0.3, base: 0.1, edge: 0.6, power: 1.6, roughness: 0.6, envMapIntensity: 0.8, clearcoat: 1, clearcoatRoughness: 0.05, side: THREE.FrontSide, key: "frost" });
  const vaultBody = new THREE.Mesh(vg, vaultMat);
  vault.add(vaultBody);
  // the frost scatters light inside: a soft milky core behind the keys hides
  // the desk the way ground glass would, without blurring anything per frame
  const coreTex = blurredShapesTexture([tag], { minX: -1.05, maxX: 1.05, minY: -1.2, maxY: 1.2, ppu: 128, blur: 40, color: "#eef1f4" });
  const core = new THREE.Mesh(new THREE.PlaneGeometry(2.1, 2.4), decalMaterial({ map: coreTex, opacity: 0.82 }));
  core.position.z = -0.16;
  core.scale.setScalar(0.9);
  core.renderOrder = 1;
  vault.add(core);
  const kg = keyGeometry();
  const lacquer = new THREE.MeshPhysicalMaterial({ color: ZHU, roughness: 0.32, clearcoat: 1, clearcoatRoughness: 0.06, emissive: ZHU, emissiveIntensity: 0, envMapIntensity: 1.1 });
  // Inside the frosted glass the keys are seen softened but still readable
  // as keys, drawn once into a lightly blurred texture. The sharp key exists only
  // as the copy that is delivered.
  const blurKey = blurredShapesTexture(keyShapes(), { minX: -0.78, maxX: 0.15, minY: -0.3, maxY: 0.3, ppu: 256, blur: 7, color: "#c22d1f", passes: 2 });
  const keyPlaneGeo = new THREE.PlaneGeometry(0.93, 0.6).translate(-0.315, 0, 0);
  // Drawn just after the frosted shell (they sit a little in front of its
  // centre, so depth sorting puts them there): a white veil over vermilion
  // would turn it pink, and the blur already says "behind frosted glass".
  const keyBlurMat = new THREE.MeshBasicMaterial({ map: blurKey, transparent: true, depthWrite: false, toneMapped: false, opacity: 0.92 });
  const vaultKeys = [];
  [0.42, 0.0, -0.42].forEach((y, i) => {
    const k = new THREE.Mesh(keyPlaneGeo, keyBlurMat);
    k.rotation.z = -0.32 + i * 0.05;
    // centre the key (its centre sits ~0.3 behind the tip)
    k.position.set(0.3 * Math.cos(k.rotation.z), y + 0.3 * Math.sin(k.rotation.z) - 0.08, 0.05);
    vault.add(k);
    vaultKeys.push(k);
  });
  const vaultShadow = shadow(2.0, 1.0, 0.55);
  const vaultGlow = glow(0xd2402a, 3.0, 0.0);
  vaultGlow.position.z = -0.4;
  vault.add(vaultGlow);
  // light through the red keys tints the desk under the vault
  const vaultTint = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), decalMaterial({ map: glowTex, color: 0xd8442c, opacity: 0 }));
  vaultTint.rotation.x = -Math.PI / 2;
  vaultTint.renderOrder = 1;

  // --- The program: a graphite box with a keyhole --------------------------
  const prog = new THREE.Group();
  const graphite = new THREE.MeshPhysicalMaterial({ color: 0x2b2c30, metalness: 0.5, roughness: 0.36, clearcoat: 0.6, clearcoatRoughness: 0.22, envMapIntensity: 0.75 });
  const box = new THREE.Mesh(new RoundedBoxGeometry(1.5, 0.92, 1.0, 6, 0.09), graphite);
  prog.add(box);
  const faceT = canvasTexture(1024, 614);
  drawProgramFace(faceT, I);
  const face = new THREE.Mesh(new THREE.PlaneGeometry(1.4, 0.84), new THREE.MeshBasicMaterial({ map: faceT.tex, transparent: true, toneMapped: false }));
  face.position.z = 0.501;
  prog.add(face);
  const keyhole = V3(-0.44, 0.03, 0.5);
  const ring = new THREE.Mesh(new THREE.RingGeometry(0.1, 0.118, 64), new THREE.MeshBasicMaterial({ color: 0xff4a32, transparent: true, opacity: 0, toneMapped: false }));
  ring.position.copy(keyhole).add(V3(0, 0, 0.003));
  prog.add(ring);
  const ringGlow = glow(0xff3b22, 0.9, 0);
  ringGlow.position.copy(keyhole).add(V3(0, 0, 0.05));
  prog.add(ringGlow);
  const leds = [];
  const ledOff = new THREE.MeshBasicMaterial({ color: 0x47474b, toneMapped: false });
  const ledOn = new THREE.MeshBasicMaterial({ color: 0x5fe07f, toneMapped: false });
  const ledGeo = new THREE.CircleGeometry(0.016, 20);
  for (let i = 0; i < 6; i++) {
    const led = new THREE.Mesh(ledGeo, ledOff);
    led.position.set(-0.17 + i * 0.058, -0.3, 0.503);
    const lg = glow(0x34c759, 0.14, 0);
    lg.position.copy(led.position).add(V3(0, 0, 0.01));
    prog.add(led, lg);
    led.userData.glow = lg;
    leds.push(led);
  }
  const progShadow = shadow(2.2, 1.6, 0.78);

  // --- The website it publishes -------------------------------------------
  const site = new THREE.Group();
  const frame = new THREE.Mesh(new RoundedBoxGeometry(1.74, 1.11, 0.03, 4, 0.014), new THREE.MeshStandardMaterial({ color: 0xdfe1e4, roughness: 0.42, metalness: 0.3 }));
  site.add(frame);
  const siteIdle = canvasTexture(1024, 650), siteLive = canvasTexture(1024, 650);
  drawSite(siteIdle, I, false);
  drawSite(siteLive, I, true);
  const sIdle = new THREE.Mesh(new THREE.PlaneGeometry(1.7, 1.08), new THREE.MeshBasicMaterial({ map: siteIdle.tex, transparent: true, toneMapped: false }));
  const sLive = new THREE.Mesh(new THREE.PlaneGeometry(1.7, 1.08), new THREE.MeshBasicMaterial({ map: siteLive.tex, transparent: true, opacity: 0, toneMapped: false }));
  sIdle.position.z = 0.017;
  sLive.position.z = 0.018;
  site.add(sIdle, sLive);
  const siteShadow = shadow(1.9, 0.5, 0.18);

  // --- Paper slips --------------------------------------------------------
  const cardMesh = (tex, w, h) => {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ map: tex, transparent: true, toneMapped: false, side: THREE.DoubleSide, forceSinglePass: true, depthWrite: false }));
    m.visible = false;
    return m;
  };
  const c1 = canvasTexture(640, 390), c2 = canvasTexture(640, 390), sl = canvasTexture(640, 390), ch = canvasTexture(560, 150);
  const redrawCards = () => {
    drawCard(c1, [[I.card.name, "name"], [I.card.note, "note"], [I.card.env, "mono"], [I.card.value, "empty"]], paper);
    drawCard(c2, [[I.card.name2, "name"], [I.card.note2, "note"], [I.card.env2, "mono"], [I.card.value, "empty"]], paper);
    drawCard(sl, [[I.slip.line1, "name"], [I.slip.line2, "mono"]], paper, { head: I.slip.head });
    drawChip(ch, I.chip);
    term.redrawBase();
  };
  redrawCards();
  const card1 = cardMesh(c1.tex, 0.82, 0.5), card2 = cardMesh(c2.tex, 0.82, 0.5), slip = cardMesh(sl.tex, 0.82, 0.5), chip = cardMesh(ch.tex, 0.8, 0.214);
  const seal = new THREE.Mesh(new THREE.PlaneGeometry(0.3, 0.3), new THREE.MeshBasicMaterial({ map: standIn(), transparent: true, opacity: 0, depthWrite: false, toneMapped: false, side: THREE.DoubleSide, forceSinglePass: true }));
  seal.position.set(0.22, -0.03, 0.002);
  seal.rotation.z = 0.06;
  slip.add(seal);
  if (assets.seal) new THREE.TextureLoader().load(assets.seal, (t) => {
    t.colorSpace = THREE.SRGBColorSpace;
    renderer.initTexture(t);
    seal.material.map = t;
    if (assets.onTexture) assets.onTexture();
  });
  const slipShadow = shadow(0.9, 0.55, 0);

  // --- The delivered copy of the key, and its dust -------------------------
  const { mat: copyMat, uDis } = dissolveMaterial(lacquer);
  copyMat.emissiveIntensity = 0.1;
  const copy = new THREE.Mesh(kg, copyMat);
  copy.visible = false;
  const copyGlow = glow(0xe0452c, 1.1, 0);
  scene.add(copyGlow);
  const DUST = 240;
  const dustGeo = new THREE.BufferGeometry();
  dustGeo.setAttribute("position", new THREE.BufferAttribute(new Float32Array(DUST * 3), 3));
  const dust = new THREE.Points(dustGeo, new THREE.PointsMaterial({ color: 0xd2381f, size: 0.03, map: dotTexture(), transparent: true, depthWrite: false, opacity: 0, toneMapped: false }));
  dust.visible = false;
  dust.frustumCulled = false;
  const seeds = Array.from({ length: DUST }, (_, i) => {
    const r = (n) => { const x = Math.sin(i * 127.1 + n * 311.7) * 43758.5453; return x - Math.floor(x); };
    return { a: r(1) * Math.PI * 2, b: r(2) * 2 - 1, s: 0.25 + r(3) * 0.75, along: r(4), lift: 0.3 + r(5) * 0.8 };
  });

  // --- Threads ------------------------------------------------------------
  const thread = (color, opacity, radius) => {
    const m = new THREE.Mesh(new THREE.BufferGeometry(), new THREE.MeshBasicMaterial({ color, transparent: true, opacity, depthWrite: false, toneMapped: false }));
    m.userData = { radius, segs: 260, radial: 8, base: opacity };
    m.frustumCulled = false;
    return m;
  };
  const reqThread = thread(0x3a3d44, 0.5, 0.0065);
  const keyThread = thread(0xc42d1d, 1.0, 0.009);
  const outThread = thread(0x3a3d44, 0.5, 0.0065);

  scene.add(agent, agentShadow, agentLight, vault, vaultShadow, vaultTint, prog, progShadow, site, siteShadow, card1, card2, slip, slipShadow, chip, copy, dust, reqThread, keyThread, outThread);

  const W_ = {
    scene, floor, uFloor, agent, agentShadow, agentLight, vaultGlow, vaultTint, ringGlow, copyGlow, seal, glass, term, vault, vaultBody, vaultKeys, keyBlurMat, lacquer,
    prog, progShadow, ring, leds, ledOn, ledOff, site, siteShadow, sLive, sIdle, card1, card2, slip, slipShadow, chip, copy, uDis, dust, seeds, reqThread, keyThread, outThread,
    vaultShadow, keyhole, redrawCards, L: {},
  };
  W_.setLayout = (kind) => layoutScene(W_, kind);
  W_.reveal = (m, p) => {
    const per = m.userData.radial * 6;
    m.geometry.setDrawRange(0, Math.floor(THREE.MathUtils.clamp(p, 0, 1) * m.userData.segs) * per);
    m.visible = p > 0.001;
  };
  return W_;
}

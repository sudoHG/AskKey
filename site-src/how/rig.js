// The camera: one unbroken move. A key frame names what to look at, from
// which direction, and how big a sphere around it must fit in the frame.
// Distance follows from the viewport, so the same move recomposes itself
// for a phone held upright.
import * as THREE from "three";
import { PRE, POST, clamp, smooth } from "./timing.js";

const kf = (t, target, dir, r) => ({ t, target, dir: new THREE.Vector3(...dir).normalize(), r });
const lerpV = (a, b, t) => a.clone().lerp(b, t);

export function buildRails(L) {
  const { A, V, P, W: Wp, C, R, sA, sV, sP } = L;
  const v = (x, y, z) => new THREE.Vector3(x, y, z);
  const at = (p, s, x, y, z) => p.clone().add(v(x, y, z).multiplyScalar(s));
  const tall = L.kind === "tall";
  const k = tall ? 1.15 : 1;
  const gate = kf(PRE, v(V.x, V.y * 0.55, V.z + 0.55 * sV), [0, 0.3, 1], 1.5 * sV * k);
  const pre = [
    kf(0, C.clone().add(v(0, 0.15, 0)), [0.02, tall ? 1.0 : 0.55, 1], R * (tall ? 0.92 : 1.04)),
    kf(1.4, C.clone().add(v(-0.2, 0.1, 0)), [0.08, 0.48, 1], R * 0.92),
    kf(3.0, at(A, sA, 0.05, 0.08, 0), [0.16, 0.1, 1], 1.18 * sA * k),
    kf(4.2, at(A, sA, 0.12, 0.02, 0), [0.24, 0.13, 1], 1.3 * sA * k),
    kf(6.0, lerpV(A, V, 0.48).add(v(0, 0.15, 0.2)), [0.22, 0.42, 1], tall ? R * 0.78 : 2.95),
    kf(8.0, lerpV(A, V, 0.4).add(v(0, 0.05, 0.3)), [0.05, 0.36, 1], tall ? R * 0.74 : 2.75),
    kf(9.8, at(A, sA, 0.55, 0.15, 0), [0.42, 0.22, 1], 1.75 * sA * k),
    kf(12.0, lerpV(A, V, 0.7).add(v(0, 0.45 * sV, 0)), [-0.2, 0.22, 1], tall ? R * 0.62 : 1.95),
    kf(13.3, v(V.x, V.y * 0.62, V.z + 0.45 * sV), [-0.06, 0.26, 1], 1.55 * sV * k),
    gate,
  ];
  const allow = [
    { ...gate, t: 0 },
    kf(0.9, v(V.x, V.y * 0.5, V.z + 0.7 * sV), [0.04, 0.42, 1], 1.25 * sV * k),
    kf(2.2, at(V, sV, 0.25, 0.1, 0.6), [0.4, 0.14, 1], 1.15 * sV * k),
    kf(3.6, lerpV(V, P, 0.55).add(v(0.2, 0.75 * sV, 0.6)), [0.12, 0.38, 1], tall ? R * 0.7 : 2.35),
    kf(4.9, at(L.keyholeW, 1, 0.1 * sP, 0.02, 0.3 * sP), [-0.5, 0.16, 1], 0.92 * sP * k),
    kf(6.2, at(L.keyholeW, 1, 0.35 * sP, 0.05, 0.15 * sP), [-0.36, 0.12, 1], 1.0 * sP * k),
    kf(7.5, lerpV(P, Wp, 0.62), [-0.3, 0.18, 1], 1.55 * sP * k),
    kf(9.0, lerpV(P, A, 0.5).add(v(0, 0.35, 0.6)), [0, 0.32, 1], tall ? R * 0.85 : 3.6),
    kf(10.4, at(A, sA, 0.15, 0.02, 0), [0.2, 0.12, 1], 1.32 * sA * k),
    kf(11.6, at(A, sA, 0.2, 0.05, 0), [0.28, 0.18, 1], 1.45 * sA * k),
    kf(14.4, C.clone().add(v(0, 0.12, 0)), [0.0, tall ? 1.15 : 0.6, 1], R * (tall ? 0.94 : 1.0)),
    kf(POST.allow, C.clone().add(v(0, 0.12, 0)), [0.03, tall ? 1.12 : 0.58, 1], R * (tall ? 0.95 : 1.01)),
  ];
  const deny = [
    { ...gate, t: 0 },
    kf(1.3, at(V, sV, 0, 0.05, 0), [0.12, 0.16, 1], 1.4 * sV * k),
    kf(3.0, at(A, sA, 0.15, 0.02, 0), [0.22, 0.13, 1], 1.32 * sA * k),
    kf(4.4, at(A, sA, 0.2, 0.05, 0), [0.28, 0.18, 1], 1.45 * sA * k),
    kf(7.0, C.clone().add(v(0, 0.12, 0)), [0.0, tall ? 1.15 : 0.6, 1], R * (tall ? 0.94 : 1.0)),
    kf(POST.deny, C.clone().add(v(0, 0.12, 0)), [0.03, tall ? 1.12 : 0.58, 1], R * (tall ? 0.95 : 1.01)),
  ];
  return { pre: rail(pre), allow: rail(allow), deny: rail(deny) };
}

// Catmull-Rom through the key frames, with a monotone time warp so the
// camera never stops between frames: one continuous move. `at` writes into
// a shot object it owns, so a frame allocates nothing.
function rail(keys) {
  const n = keys.length;
  const tgt = new THREE.CatmullRomCurve3(keys.map((k) => k.target), false, "centripetal");
  const dir = new THREE.CatmullRomCurve3(keys.map((k) => k.dir.clone()), false, "catmullrom", 0.5);
  const ts = keys.map((k) => k.t), rs = keys.map((k) => Math.log(k.r));
  // Fritsch–Carlson slopes for index(t)
  const d = [];
  for (let i = 0; i < n - 1; i++) d.push(1 / (ts[i + 1] - ts[i]));
  const m = [d[0]];
  for (let i = 1; i < n - 1; i++) m.push(d[i - 1] * d[i] <= 0 ? 0 : (2 * d[i - 1] * d[i]) / (d[i - 1] + d[i]));
  m.push(d[n - 2]);
  m[0] *= 0.15; // ease in from rest
  const idx = (t) => {
    if (t <= ts[0]) return 0;
    if (t >= ts[n - 1]) return n - 1;
    let i = 0;
    while (t > ts[i + 1]) i++;
    const h = ts[i + 1] - ts[i], s = (t - ts[i]) / h;
    const h00 = 2 * s ** 3 - 3 * s ** 2 + 1, h10 = s ** 3 - 2 * s ** 2 + s, h01 = -2 * s ** 3 + 3 * s ** 2, h11 = s ** 3 - s ** 2;
    return h00 * i + h10 * h * m[i] + h01 * (i + 1) + h11 * h * m[i + 1];
  };
  const rAt = (x) => {
    const i = Math.min(n - 2, Math.floor(x)), f = x - i;
    return Math.exp(rs[i] + (rs[i + 1] - rs[i]) * smooth(f));
  };
  const shot = { target: new THREE.Vector3(), dir: new THREE.Vector3(), r: 1 };
  return {
    end: ts[n - 1],
    at(t) {
      const x = clamp(idx(t), 0, n - 1);
      const u = x / (n - 1);
      tgt.getPoint(u, shot.target);
      dir.getPoint(u, shot.dir).normalize();
      shot.r = rAt(x);
      return shot;
    },
  };
}

const _d = new THREE.Vector3();
export function placeCamera(camera, shot, clock, pointer, drift) {
  const fovV = THREE.MathUtils.degToRad(camera.fov);
  // An upright stage wider than a phone's (a tablet held upright) is framed
  // as if it were phone-shaped, so the cast keeps clear of every edge.
  const aspect = camera.aspect < 1.02 ? Math.min(camera.aspect, 0.75) : camera.aspect;
  const fovH = 2 * Math.atan(Math.tan(fovV / 2) * aspect);
  const lim = Math.min(fovV, fovH);
  const dist = shot.r / Math.sin(lim / 2);
  const d = _d.copy(shot.dir);
  d.x += drift * (0.025 * Math.sin(clock * 0.23) + pointer.sx * 0.07);
  d.y += drift * (0.018 * Math.sin(clock * 0.17 + 1.3) - pointer.sy * 0.045);
  d.normalize();
  camera.position.copy(shot.target).addScaledVector(d, dist);
  camera.lookAt(shot.target);
}

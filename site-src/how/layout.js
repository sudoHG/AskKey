// Where everything stands, for a wide screen or a phone held upright, and
// the paths the cards, the request, the key and the result travel along.
import * as THREE from "three";

const V3 = (x, y, z) => new THREE.Vector3(x, y, z);
// contact shadows fall away from the window (back left)
const CAST = V3(0.16, 0, 0.12);

export function layoutScene(W, kind) {
  const L = W.L;
  const wide = kind === "wide";
  const A = wide ? V3(-3.05, 1.32, 0.9) : V3(-0.92, 1.0, 1.9);
  const V = wide ? V3(0, 1.26, -2.3) : V3(0.02, 1.58, -2.5);
  const P = wide ? V3(3.05, 0.62, 0.9) : V3(1.0, 0.48, 2.3);
  const sA = wide ? 1 : 0.66, sV = wide ? 1 : 0.8, sP = wide ? 1 : 0.68;
  const Wp = P.clone().add((wide ? V3(0, 1.62, -0.32) : V3(0.2, 1.4, -1.5)).multiplyScalar(sP));
  Object.assign(L, { kind, A, V, P, W: Wp, sA, sV, sP });

  const onDesk = (m, p, s, sx, sz, lift = 0) => {
    m.position.set(p.x + CAST.x * p.y, 0.003 + lift, p.z + CAST.z * p.y);
    m.scale.set(sx * s, sz * s, 1);
  };
  W.agent.position.copy(A); W.agent.scale.setScalar(sA);
  onDesk(W.agentShadow, A, sA, 3.2, 0.95);
  onDesk(W.agentLight, A, sA, 2.6, 0.7, 0.001);
  W.agentLight.position.x += 0.2 * sA;
  W.agentLight.position.z += 0.35 * sA;
  W.vault.position.copy(V); W.vault.scale.setScalar(sV);
  onDesk(W.vaultShadow, V, sV, 2.0, 1.0);
  onDesk(W.vaultTint, V, sV, 1.9, 1.1, 0.001);
  W.vaultTint.position.z += 0.3 * sV;
  W.prog.position.copy(P); W.prog.scale.setScalar(sP);
  onDesk(W.progShadow, P, sP, 2.2, 1.6);
  W.site.position.copy(Wp); W.site.scale.setScalar(sP);
  onDesk(W.siteShadow, Wp, sP, 1.9, 0.5);
  [W.card1, W.card2, W.slip].forEach((m) => m.scale.setScalar(wide ? 1 : 0.72));
  L.cardScale = wide ? 1.45 : 0.9;
  W.chip.scale.setScalar(wide ? 1 : 0.7);
  W.copy.scale.setScalar(wide ? 1.15 : 0.8);
  W.dust.material.size = wide ? 0.03 : 0.022;

  const mid = (a, b, t = 0.5) => a.clone().lerp(b, t);
  const off = (p, s, x, y, z) => p.clone().add(V3(x, y, z).multiplyScalar(s));
  const kh = W.keyhole;
  L.keyholeW = off(P, sP, kh.x, kh.y, kh.z);
  L.catPath = new THREE.CatmullRomCurve3([off(V, sV, -0.55, 0.35, 0.45), mid(A, V).add(V3(-0.1, 0.7 * sV, wide ? 1.5 : 0.9)), off(A, sA, 0.55, 0.25, 0.4)], false, "centripetal");
  L.reqPath = new THREE.CatmullRomCurve3([off(A, sA, 1.05, 0.5, 0.05), mid(A, V).add(V3(0.35, 1.2 * sV, 0.2)), off(V, sV, -0.6, 0.62, 0.4)], false, "centripetal");
  L.keyPath = new THREE.CatmullRomCurve3(
    [
      off(V, sV, 0.08, 0.0, 1.0),
      off(V, sV, 0.75, 0.35, 1.45),
      mid(V, P).add(V3(0.1, 0.55 * sV, wide ? 1.55 : 1.2)),
      L.keyholeW.clone().add(V3(-0.55, 0.32, 0.7).multiplyScalar(sP)),
      L.keyholeW.clone().add(V3(0, 0.05, 0.26).multiplyScalar(sP)),
      L.keyholeW.clone().add(V3(0, 0, 0.015).multiplyScalar(sP)),
    ],
    false,
    "centripetal"
  );
  L.outPath = new THREE.CatmullRomCurve3([off(P, sP, -0.8, 0.12, 0.45), mid(P, A).add(V3(0, 0.3, wide ? 1.7 : 1.0)), off(A, sA, 1.1, -0.25, 0.3)], false, "centripetal");
  for (const [m, path] of [[W.reqThread, L.reqPath], [W.keyThread, L.keyPath], [W.outThread, L.outPath]]) {
    m.geometry.dispose();
    m.geometry = new THREE.TubeGeometry(path, m.userData.segs, m.userData.radius * (wide ? 1 : 0.8), m.userData.radial, false);
    m.geometry.setDrawRange(0, 0);
  }

  W.copyGlow.scale.setScalar(wide ? 1.1 : 0.75);
  L.slipRest = V3(V.x - 0.05 * sV, 0.012, V.z + 1.25 * sV);
  L.slipRestQ = new THREE.Quaternion().setFromEuler(new THREE.Euler(-Math.PI / 2, 0, 0.12));
  W.slipShadow.position.set(L.slipRest.x + 0.02, 0.004, L.slipRest.z + 0.03);
  W.slipShadow.rotation.z = -0.12;
  W.slipShadow.scale.set(0.95 * (wide ? 1 : 0.72) * 1.2, 0.58 * (wide ? 1 : 0.72) * 1.2, 1);

  // framing sphere for the whole cast
  const parts = [[A, 1.55 * sA], [V, 1.15 * sV], [P, 0.95 * sP], [Wp, 0.95 * sP]];
  const box3 = new THREE.Box3();
  parts.forEach(([p, r]) => box3.expandByPoint(p.clone().addScalar(r)).expandByPoint(p.clone().subScalar(r)));
  L.C = box3.getCenter(new THREE.Vector3());
  L.R = Math.max(...parts.map(([p, r]) => p.distanceTo(L.C) + r)) * (wide ? 0.74 : 0.86);
  W.uFloor.uCenter.value.copy(L.C);
  W.uFloor.uRad.value.set(wide ? 6.4 : 3.8, wide ? 14 : 9);
  // the window patch falls across the AI's side of the desk, from the back left
  W.uFloor.uWinO.value.set(wide ? A.x + 1.5 : A.x + 0.5, wide ? A.z - 1.3 : A.z - 1.4);
  W.uFloor.uWinS.value.set(wide ? 1.9 : 1.15, wide ? 1.35 : 0.95);
}

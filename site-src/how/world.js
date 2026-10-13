// Every visual is a pure function of the film's time and the reader's
// decision, which makes chapter seeking, replays and the alternate endings
// exact. Nothing here allocates per frame.
import * as THREE from "three";
import { PRE, POST, WHITE_OUT, clamp, seg, ease, easeOut, smooth, fade, kindOf } from "./timing.js";

export function createWorld(W, I, camera) {
  // ---------------------------------------------------------- transcript
  const out = [];
  const lines = Array.from({ length: 12 }, () => ({}));
  let nLines = 0;
  const push = (kind, text, alpha, extra) => {
    const L = lines[nLines++];
    L.kind = kind; L.text = text; L.alpha = alpha; L.chars = undefined; L.caret = false; L.row = undefined;
    if (extra) Object.assign(L, extra);
    return L;
  };
  const askChars = [...I.term.ask].length;
  function transcriptLines(s) {
    nLines = 0;
    const T = s.phase === "pre" ? s.T : PRE + 1;
    const post = s.phase === "post" || s.phase === "end";
    const u = post ? s.u : -1;
    const k = kindOf(s.decision);
    const a = (at) => clamp((T - at) / 0.35);
    const au = (at) => clamp((u - at) / 0.35);
    const me = push("me", I.term.ask, 1);
    me.chars = Math.floor(seg(T, 0.7, 2.7) * askChars);
    me.caret = T < 3.0 && (T < 2.7 || Math.floor(T * 2.2) % 2 === 0);
    if (T >= 3.4) push("ai", I.term.check, a(3.4));
    if (T >= 6.7) push("cat", "", a(6.7), { row: I.term.cat[0] });
    if (T >= 7.0) push("cat", "", a(7.0), { row: I.term.cat[1] });
    if (T >= 7.3) push("note", I.term.noValue, a(7.3));
    if (T >= 8.6) push("ai", I.term.cant, a(8.6));
    if (T >= 8.9) push("indent", I.term.req, a(8.9));
    if (T >= 12.6) {
      if (!post || u < 0.5) push("wait", I.term.wait, a(12.6));
      else if (k === "allow") push("ok", s.decision === "timed" ? I.term.okTimed : I.term.ok, au(0.5));
      else push("no", s.decision === "expire" ? I.term.expired : I.term.denied, au(0.5));
    }
    if (post && k === "allow") {
      if (u >= 10.0) push("ai", I.term.out, au(10.0));
      if (u >= 10.5) push("ok", I.term.live, au(10.5));
    }
    if (post && k === "deny" && u >= 1.7) push("ai", s.decision === "expire" ? I.term.expiredNext : I.term.deniedNext, au(1.7));
    out.length = nLines;
    for (let i = 0; i < nLines; i++) out[i] = lines[i];
    return out;
  }
  function updateTranscript(s, clock) {
    const ls = transcriptLines(s);
    const waiting = ls.some((l) => l.kind === "wait");
    W.term.update(ls, waiting ? Math.floor(clock * 9) / 8 : 0);
  }

  // ------------------------------------------------------------ the world
  const q = new THREE.Quaternion(), q2 = new THREE.Quaternion(), X = new THREE.Vector3(1, 0, 0), NZ = new THREE.Vector3(0, 0, -1);
  const tmp = new THREE.Vector3(), tmp2 = new THREE.Vector3(), sp = new THREE.Vector3(), ss = new THREE.Vector3();
  const sq = new THREE.Quaternion();
  function along(m, path, p, wobble = 0) {
    path.getPoint(p, tmp);
    m.position.copy(tmp);
    m.quaternion.copy(camera.quaternion);
    m.rotateZ(wobble);
  }

  function update(s, clock) {
    const T = s.phase === "pre" ? s.T : PRE + 1;
    const post = s.phase === "post" || s.phase === "end";
    const u = post ? s.u : 0;
    const k = post ? kindOf(s.decision) : null;
    const L = W.L;

    // catalog cards: vault → AI
    for (let i = 0; i < 2; i++) {
      const m = i ? W.card2 : W.card1, t0 = i ? 4.75 : 4.3;
      const p = seg(T, t0, t0 + 2.2);
      m.visible = p > 0 && p < 1;
      if (!m.visible) continue;
      const e = ease(p);
      along(m, L.catPath, e, Math.sin(clock * 2 + i) * 0.04 + (1 - e) * 0.2);
      if (i) m.position.y += 0.12 * L.sA;
      const sc = L.cardScale * (0.35 + 0.65 * smooth(seg(p, 0, 0.2))) * (1 - 0.5 * smooth(seg(p, 0.82, 1)));
      m.scale.setScalar(sc);
      m.material.opacity = Math.min(seg(p, 0, 0.12), 1 - seg(p, 0.86, 1));
    }

    // request slip: AI → vault, then it lands on the desk in front of you
    {
      const p = seg(T, 9.6, 12.2), l = seg(T, 12.2, 13.3);
      const base = L.kind === "wide" ? 1 : 0.72;
      W.slip.visible = p > 0;
      if (p > 0 && l <= 0) {
        along(W.slip, L.reqPath, ease(p), Math.sin(clock * 2.4) * 0.05);
        W.slip.material.opacity = seg(p, 0, 0.1);
        W.slip.scale.setScalar(base * (1 - 0.2 * smooth(seg(p, 0.8, 1))));
      } else if (l > 0) {
        L.reqPath.getPoint(1, tmp);
        const e = ease(l);
        W.slip.position.lerpVectors(tmp, L.slipRest, e);
        W.slip.position.y += Math.sin(e * Math.PI) * 0.25 * L.sV;
        W.slip.quaternion.slerpQuaternions(camera.quaternion, L.slipRestQ, smooth(l));
        W.slip.scale.setScalar(base * (0.8 + 0.4 * e));
        W.slip.material.opacity = 1;
      }
      W.slipShadow.material.opacity = 0.5 * smooth(seg(l, 0.55, 1)) * (post && k === "deny" ? 1 - 0.55 * seg(u, 0.5, 1.6) : 1);
      const stamp = k === "allow" ? seg(u, 0.12, 0.5) : 0;
      W.seal.material.opacity = Math.min(1, stamp * 3) * 0.92;
      W.seal.scale.setScalar(1 + 0.6 * (1 - easeOut(stamp)));
      if (post && k === "deny") W.slip.material.opacity = 1 - 0.55 * seg(u, 0.5, 1.6);
      W.reveal(W.reqThread, ease(seg(T, 9.6, 12.2)));
    }

    // the vault answers: keys warm up while it asks you
    const ask = seg(T, 12.3, 13.2) * (post ? 1 - seg(u, 0.2, 1.2) : 1);
    const pulse = s.phase === "gate" && !s.later ? 0.5 + 0.5 * Math.sin(clock * 3) : 0;
    const warm = ask * (0.5 + pulse * 0.5) + (k === "allow" ? 0.7 * fade(u, 0.4, 2.6, 0.4, 0.8) : 0);
    W.lacquer.emissiveIntensity = 0.5 * warm;
    // the blurred keys brighten toward a lit vermilion
    W.keyBlurMat.color.setScalar(1 + 0.45 * warm);
    W.vault.scale.setScalar(L.sV * (1 + 0.025 * ask * smooth(fade(T, 12.3, 13.4, 0.4, 0.6))));
    const lantern = 0.1 + ask * (0.2 + pulse * 0.18) + (k === "allow" ? 0.32 * fade(u, 0.3, 2.8, 0.4, 0.9) : 0);
    W.vaultGlow.material.opacity = lantern * 0.85;
    W.vaultTint.material.opacity = 0.08 + lantern * 0.42;

    // allow: a copy of the key leaves the vault, goes to the program, is used and destroyed
    const allow = k === "allow";
    const copy = W.copy;
    copy.visible = allow && u > 0.5 && u < 10.4;
    W.dust.visible = false;
    if (copy.visible) {
      const src = W.vaultKeys[1];
      src.updateWorldMatrix(true, false);
      src.matrixWorld.decompose(sp, sq, ss);
      const base = L.kind === "wide" ? 1.15 : 0.8;
      const e = smooth(seg(u, 0.5, 2.0));
      const f = ease(seg(u, 2.0, 5.2));
      const turn = ease(seg(u, 5.3, 5.85));
      if (u < 2.0) {
        L.keyPath.getPoint(0, tmp);
        L.keyPath.getTangent(0.001, tmp2);
        q.setFromUnitVectors(X, tmp2);
        copy.position.lerpVectors(sp, tmp, e);
        copy.quaternion.slerpQuaternions(sq, q, e);
        copy.scale.setScalar(ss.x + (base - ss.x) * e);
      } else {
        L.keyPath.getPoint(f, tmp);
        L.keyPath.getTangent(Math.min(0.999, Math.max(0.001, f)), tmp2);
        tmp2.lerp(NZ, smooth(seg(f, 0.8, 1))).normalize();
        copy.position.copy(tmp);
        q.setFromUnitVectors(X, tmp2);
        q2.setFromAxisAngle(X, Math.sin(f * Math.PI) * Math.PI - (turn * Math.PI) / 2);
        copy.quaternion.copy(q).multiply(q2);
        copy.scale.setScalar(base);
      }
      const dis = seg(u, 8.4, 10.2);
      W.uDis.value = dis;
      if (dis > 0) {
        W.dust.visible = true;
        const arr = W.dust.geometry.attributes.position.array;
        const tip = copy.position;
        const len = 0.62 * base;
        const seeds = W.seeds;
        for (let i = 0; i < seeds.length; i++) {
          const sd = seeds[i];
          const t = clamp((dis - sd.along * 0.6) / 0.6);
          const r = easeOut(t) * 0.35 * sd.s * L.sP * 1.6;
          arr[i * 3] = tip.x + Math.cos(sd.a) * r * 0.8;
          arr[i * 3 + 1] = tip.y + sd.b * 0.06 + t * sd.lift * 0.5 * L.sP + Math.sin(sd.a) * r * 0.25;
          arr[i * 3 + 2] = tip.z + len * (1 - sd.along) * (t > 0 ? 1 : 0) + Math.abs(Math.sin(sd.a)) * r * 0.4;
        }
        W.dust.geometry.attributes.position.needsUpdate = true;
        W.dust.material.opacity = 0.95 * (1 - seg(dis, 0.55, 1));
      }
    } else {
      W.uDis.value = 0;
    }
    W.copyGlow.visible = copy.visible && W.uDis.value < 0.95;
    if (W.copyGlow.visible) {
      W.copyGlow.position.copy(copy.position);
      W.copyGlow.material.opacity = 0.32 * seg(u, 0.6, 1.6) * (1 - W.uDis.value);
    }
    W.reveal(W.keyThread, allow ? ease(seg(u, 2.0, 5.2)) : 0);

    // the program runs
    W.ring.material.opacity = allow ? seg(u, 4.2, 4.8) * (1 - 0.6 * seg(u, 9.4, 10.4)) : 0;
    W.ringGlow.material.opacity = W.ring.material.opacity * (0.4 + 0.2 * fade(u, 5.3, 6.4, 0.2, 0.6));
    for (let i = 0; i < W.leds.length; i++) {
      const led = W.leds[i];
      const on = allow && u > 5.95 + i * 0.16;
      led.material = on ? W.ledOn : W.ledOff;
      led.userData.glow.material.opacity = on ? 0.7 : 0;
    }
    const live = allow ? smooth(seg(u, 6.9, 7.5)) : 0;
    W.sLive.material.opacity = live;
    W.sIdle.material.opacity = 1 - live;
    W.site.position.y = L.W.y + Math.sin(clock * 0.9) * 0.015 * L.sP + live * 0.04 * (1 - seg(u, 7.5, 8.5)) * L.sP;

    // the result comes back: program → AI
    {
      const p = allow ? seg(u, 7.7, 9.9) : 0;
      W.chip.visible = p > 0 && p < 1;
      if (W.chip.visible) {
        along(W.chip, L.outPath, ease(p), Math.sin(clock * 2) * 0.03);
        W.chip.material.opacity = Math.min(seg(p, 0, 0.1), 1 - seg(p, 0.86, 1));
      }
      W.reveal(W.outThread, allow ? ease(seg(u, 7.7, 9.9)) : 0);
    }

    // threads settle into a faint diagram for the final frame
    const settle = post ? seg(u, k === "allow" ? 11 : 3, k === "allow" ? 13 : 5) : 0;
    W.reqThread.material.opacity = k === "deny" ? 0.5 - 0.24 * settle : 0.5;

    // the room gives way to the page as each ending closes
    W.uFloor.uWhite.value = post ? smooth(seg(u, POST[k] - WHITE_OUT, POST[k])) : 0;

    // idle life
    W.agent.position.y = L.A.y + Math.sin(clock * 0.7) * 0.02 * L.sA;
  }

  return { update, updateTranscript };
}

// The DOM around the scene: labels pinned to objects, the caption, the
// chapter rail, Ask Key's approval prompt with its live countdown, and the
// two endings.
import * as THREE from "three";
import { PRE, POST, STEP_AT, seg, clamp, kindOf, outcomeOf } from "./timing.js";

export function createUI({ root, I, S, W, camera, reduced, wake, renderNow }) {
  const $ = (s) => root.querySelector(s);
  const $$ = (s) => [...root.querySelectorAll(s)];
  const stage = $(".akhw-stage"), say = $(".akhw-say"), tagLayer = $(".akhw-tags");
  const alert = $(".akhw-alert"), hint = $(".akhw-hint"), pending = $(".akhw-pending"), endBar = $(".akhw-end"), playBtn = $(".akhw-play");
  const count = $(".akhw-count"), details = $(".akhw-alert-details"), rows = $(".akhw-alert-rows");
  const steps = $$(".akhw-steps li");

  // ------------------------------------------------------------ tags
  const tags = [];
  const v3 = new THREE.Vector3(), o3 = new THREE.Vector3();
  const tag = (cls, html, anchor, show, dy = 0) => {
    if (!html || html.includes("undefined")) return; // copy missing for this language
    const el = document.createElement("div");
    el.className = `akhw-tag ${cls}`;
    el.innerHTML = html;
    tagLayer.appendChild(el);
    tags.push({ el, anchor, show, dy, on: false, w: 0, x: NaN, y: NaN });
  };
  const T_ = I.tags;
  {
    const L = W.L;
    const add = (p, x, y, z) => v3.copy(p).add(o3.set(x, y, z));
    const below = (key, s, y) => () => add(L[key], 0, -y * L[s], L.kind === "wide" ? 0 : 0.75 * L[s]);
    const finalAllow = (s) => s.phase !== "pre" && s.phase !== "gate" && kindOf(s.decision) === "allow" && s.u > 12.6;
    const finalDeny = (s) => s.phase !== "pre" && s.phase !== "gate" && kindOf(s.decision) === "deny" && s.u > 5.6;
    const finalAny = (s) => finalAllow(s) || finalDeny(s);
    const opening = (s) => s.phase === "pre" && s.T < 1.9;
    const catalog = (s) => s.phase === "pre" && s.T > 4.9 && s.T < 8.5;
    // Names show while the desk around them is wood: light text cannot sit
    // on the white the closing shot fades into, so the end uses pills only.
    tag("is-id", `<b>${T_.agent[0]}</b><small>${T_.agent[1]}</small>`, below("A", "sA", 1.08), (s) => opening(s) || catalog(s));
    tag("is-id", `<b>${T_.vault[0]}</b><small>${T_.vault[1]}</small>`, () => below("V", "sV", L.kind === "wide" ? 1.5 : 1.32)(), (s) => opening(s) || catalog(s));
    tag("is-id", `<b>${T_.prog[0]}</b><small>${T_.prog[1]}</small>`, () => add(L.P, 0, -0.62 * L.sP, (L.kind === "wide" ? 0.5 : 1.05) * L.sP), (s) => s.phase === "post" && kindOf(s.decision) === "allow" && s.u > 3.2 && s.u < 4.6);
    tag("is-pill", T_.noValue, () => add(L.A, 0.2 * L.sA, 0.98 * L.sA, 0), (s) => s.phase === "pre" && s.T > 7.2 && s.T < 8.6);
    tag("is-pill is-key", T_.flying, () => add(W.copy.position, 0, 0.3 * L.sP, 0), (s) => s.phase !== "pre" && s.phase !== "gate" && kindOf(s.decision) === "allow" && s.u > 2.2 && s.u < 4.6);
    tag("is-pill is-zero", T_.agentEnd.replace(/(\d+)/, "<em>$1</em>"), () => add(L.A, 0, 1.02 * L.sA, 0), (s) => finalAny(s) || (s.phase === "post" && s.u > (kindOf(s.decision) === "allow" ? 10.8 : 3.4)));
    tag("is-pill", T_.vaultEnd, () => add(L.V, 0, 1.2 * L.sV, 0), (s) => finalAllow(s) && s.decision === "once");
    tag("is-pill", T_.vaultTimed, () => add(L.V, 0, 1.2 * L.sV, 0), (s) => finalAllow(s) && s.decision === "timed");
    tag("is-pill", T_.vaultDeny, () => add(L.V, 0, 1.2 * L.sV, 0), (s) => finalDeny(s));
    tag("is-pill is-key", T_.progEnd, () => add(L.W, 0, 0.74 * L.sP, 0), (s) => finalAllow(s));
    tag("is-pill", T_.progDeny, () => add(L.W, 0, 0.74 * L.sP, 0), (s) => finalDeny(s));
  }

  // Positions are written in one pass after every width is known, so the
  // browser never lays out mid-frame. A label is measured once, when it
  // first shows.
  let stageW = stage.clientWidth, stageH = stage.clientHeight;
  function measure() {
    stageW = stage.clientWidth;
    stageH = stage.clientHeight;
    tags.forEach((t) => (t.w = 0));
  }
  function updateTags(s) {
    const w = stageW, h = stageH, now = performance.now();
    for (const t of tags) {
      const on = s.phase !== "idle" && t.show(s);
      if (on !== t.on) {
        t.el.classList.toggle("on", on);
        t.on = on;
        if (!on) t.offAt = now;
      }
      if (on && !t.w) t.w = t.el.offsetWidth;
    }
    for (const t of tags) {
      // keep following the object while the label fades out
      if (!t.on && !(now - (t.offAt || 0) < 600)) continue;
      const p = t.anchor().project(camera);
      if (p.z > 1) { if (t.on) { t.el.classList.remove("on"); t.on = false; t.offAt = 0; } continue; }
      const half = t.w / 2 + 10;
      const x = clamp((p.x * 0.5 + 0.5) * w, half, Math.max(half, w - half)), y = (-p.y * 0.5 + 0.5) * h + t.dy;
      if (Math.abs(x - t.x) < 0.05 && Math.abs(y - t.y) < 0.05) continue;
      t.x = x; t.y = y;
      t.el.style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px) translate(-50%, -50%)`;
    }
  }

  // ------------------------------------------------------------- captions
  const sayPs = steps.map(() => {
    const p = document.createElement("p");
    say.appendChild(p);
    return p;
  });
  function stepOf(s) {
    if (s.phase === "pre" || s.phase === "idle") return s.T < STEP_AT.pre[1] ? 0 : s.T < STEP_AT.pre[2] ? 1 : 2;
    if (s.phase === "gate") return 3;
    const k = kindOf(s.decision);
    return s.u < STEP_AT[k][1] ? 4 : 5;
  }
  let lastStep = -1, lastOutcome = "";
  const lastFill = steps.map(() => -1);
  function updateCaptions(s) {
    const st = stepOf(s);
    const oc = outcomeOf(s.decision);
    if (oc !== lastOutcome) {
      root.dataset.outcome = oc;
      lastOutcome = oc;
      lastStep = -1;
    }
    if (st !== lastStep) {
      const li = steps[st];
      const src = [...li.querySelectorAll("p")].find((p) => getComputedStyle(p).display !== "none");
      sayPs.forEach((p, i) => {
        if (i === st && src) p.innerHTML = src.innerHTML;
        p.classList.toggle("on", i === st);
      });
      steps.forEach((li, i) => li.classList.toggle("on", i === st));
      lastStep = st;
    }
    const k = kindOf(s.decision);
    for (let i = 0; i < steps.length; i++) {
      let f;
      if (i < st) f = 1;
      else if (i > st) f = 0;
      else if (st <= 2) f = seg(s.T, STEP_AT.pre[st], st < 2 ? STEP_AT.pre[st + 1] : PRE);
      else if (st === 3) f = 1;
      else f = seg(s.u, STEP_AT[k][st - 4], st === 4 ? STEP_AT[k][1] : POST[k]);
      f = Math.round(f * 400) / 400;
      if (f !== lastFill[i]) {
        steps[i].style.setProperty("--fill", f.toFixed(3));
        lastFill[i] = f;
      }
    }
  }

  // ------------------------------------------------------------- the gate
  let hintTimer = 0;
  function showAlert() {
    alert.hidden = false;
    alert.classList.remove("leave");
    alert.classList.add("enter");
    pending.hidden = true;
    root.classList.remove("is-later");
    clearTimeout(hintTimer);
    hintTimer = setTimeout(() => {
      if (S.phase === "gate" && !S.later) {
        hint.hidden = false;
        root.classList.add("is-hinting");
      }
    }, 6500);
  }
  function hideAlert(instant) {
    clearTimeout(hintTimer);
    hint.hidden = true;
    root.classList.remove("is-hinting");
    if (instant || reduced) {
      alert.hidden = true;
      return;
    }
    alert.classList.remove("enter");
    alert.classList.add("leave");
    setTimeout(() => {
      if (alert.classList.contains("leave")) {
        alert.hidden = true;
        alert.classList.remove("leave");
      }
    }, 280);
  }
  function enterGate() {
    S.phase = "gate";
    S.T = PRE;
    S.gateAt = performance.now();
    S.later = false;
    root.classList.add("is-gate");
    count.textContent = count.dataset.format.replace("{t}", "4:57");
    showAlert();
  }
  function decide(d) {
    if (S.phase !== "gate") return;
    S.decision = d;
    S.phase = "post";
    S.u = 0;
    S.ended = false;
    S.later = false;
    root.classList.remove("is-gate", "is-later");
    pending.hidden = true;
    hideAlert();
    if (reduced) {
      S.u = POST[kindOf(d)];
      S.phase = "end";
      showEnd();
      renderNow();
    } else wake();
  }
  function tickCountdown(now) {
    if (S.phase !== "gate") return;
    const left = Math.max(0, 297 - Math.floor((now - S.gateAt) / 1000));
    const txt = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}`;
    const full = count.dataset.format.replace("{t}", txt);
    if (count.textContent !== full) count.textContent = full;
    if (S.later) {
      const pt = pending.dataset.base.replace("{t}", txt);
      if (pending.textContent !== pt) pending.textContent = pt;
    }
    if (left === 0) {
      S.later = false;
      decide("expire");
    }
  }
  pending.dataset.base = pending.textContent.includes("·") ? pending.textContent.split("·")[0].trim() + " · {t}" : pending.textContent;
  function later() {
    if (S.phase !== "gate" || S.later) return;
    S.later = true;
    root.classList.add("is-later");
    hideAlert();
    pending.hidden = false;
    wake();
  }
  alert.addEventListener("click", (e) => {
    const b = e.target.closest("[data-decide]");
    if (b && !root.classList.contains("is-still")) decide(b.dataset.decide);
  });
  details.addEventListener("click", () => {
    const open = details.getAttribute("aria-expanded") !== "true";
    details.setAttribute("aria-expanded", String(open));
    rows.hidden = !open;
  });
  $(".akhw-later").addEventListener("click", later);
  pending.addEventListener("click", () => {
    S.later = false;
    showAlert();
    alert.querySelector(".is-primary").focus({ preventScroll: true });
    wake();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && S.phase === "gate" && !S.later && S.visible) later();
  });

  // ------------------------------------------------------------- endings
  const again = $(".akhw-again"), other = $(".akhw-other");
  function showEnd() {
    S.ended = true;
    endBar.hidden = false;
    other.textContent = kindOf(S.decision) === "allow" ? other.dataset.deny : other.dataset.allow;
  }
  function hideEnd() {
    S.ended = false;
    endBar.hidden = true;
  }
  function seek(i) {
    hideEnd();
    playBtn.hidden = true;
    S.started = true;
    if (i <= 2) {
      if (S.phase === "gate") hideAlert(true);
      root.classList.remove("is-gate", "is-later");
      pending.hidden = true;
      S.phase = "pre";
      S.T = STEP_AT.pre[i] + (i === 0 ? 0 : 0.01);
      S.decision = null;
    } else if (i === 3) {
      S.decision = null;
      if (S.phase !== "gate") enterGate();
      else if (S.later) { S.later = false; showAlert(); }
    } else {
      if (S.phase === "gate") {
        hideAlert(true);
        root.classList.remove("is-gate", "is-later");
        pending.hidden = true;
      }
      if (!S.decision) S.decision = "once";
      S.phase = "post";
      S.u = STEP_AT[kindOf(S.decision)][i - 4] + 0.01;
    }
    wake();
  }
  again.addEventListener("click", () => seek(0));
  other.addEventListener("click", () => seek(3));
  steps.forEach((li, i) => li.querySelector("button").addEventListener("click", () => seek(i)));
  playBtn.addEventListener("click", () => seek(0));

  return { updateTags, updateCaptions, tickCountdown, enterGate, decide, showEnd, hideEnd, hideAlert, measure, alert, hint, stage };
}

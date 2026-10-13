// Ask Key — "How it works", told as one unbroken camera move across a desk
// in morning light that stops and waits for the reader to approve (or deny)
// the request.
//
// Rendering budget: one pass, no transmission or shadow maps, pixel ratio
// capped and set from a benchmark, and frames are drawn only when something
// moves: while the film plays, at a reduced rate behind the approval prompt,
// and on demand (pointer, resize) before and after.
import * as THREE from "three";
import { buildScene, BG } from "./scene.js";
import { buildRails, placeCamera } from "./rig.js";
import { createWorld } from "./world.js";
import { createUI } from "./ui.js";
import { probeGPU, createQuality } from "./quality.js";
import { PRE, POST, kindOf, outcomeOf } from "./timing.js";

const root = document.querySelector(".akhw");
if (root) init(root);

function init(root) {
  const I = JSON.parse(root.querySelector(".akhw-i18n").textContent);
  const $ = (s) => root.querySelector(s);
  const stage = $(".akhw-stage"), canvas = $(".akhw-canvas");
  const params = new URLSearchParams(location.search);
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches || params.has("still");
  const S = { phase: "idle", T: 0, u: 0, decision: null, started: false, visible: false, later: false, gateAt: 0, ended: false };

  // ------------------------------------------------------------ renderer
  const gpu = probeGPU();
  let renderer = null;
  if (gpu) try {
    renderer = new THREE.WebGLRenderer({ canvas, antialias: !gpu.software, alpha: false, powerPreference: "high-performance" });
  } catch (e) {
    renderer = null;
  }
  if (!renderer || !renderer.capabilities.isWebGL2) {
    root.classList.add("no-gl", "is-still");
    stillTelling(null);
    return;
  }
  renderer.setClearColor(BG, 1);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.NeutralToneMapping;
  renderer.toneMappingExposure = 1.0;
  const gl = renderer.getContext();
  const Q = createQuality(gpu, params);

  const asset = (p) => new URL(p, import.meta.url).href;
  const paper = new Image();
  paper.src = asset("img/paper.jpg");
  const W = buildScene(renderer, I, paper, { wood: asset("img/walnut.webp"), seal: asset("img/seal-zhun.webp"), onTexture: () => wake(true) });
  const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 100);
  let rails = null;
  const world = createWorld(W, I, camera);
  const ui = createUI({ root, I, S, W, camera, reduced, wake: () => wake(true), renderNow: () => frame(performance.now()) });

  // ------------------------------------------------------------ one frame
  const pointer = { x: 0, y: 0, sx: 0, sy: 0 };
  let clock = 0; // drives the slow drift and idle life; runs only while the film does
  const px = new Uint8Array(4);
  function frame(now) {
    let shot;
    if (S.phase === "pre" || S.phase === "idle") shot = rails.pre.at(S.T);
    else if (S.phase === "gate") shot = rails.pre.at(PRE);
    else shot = rails[kindOf(S.decision)].at(S.u);
    placeCamera(camera, shot, clock, pointer, reduced ? 0 : 1);
    camera.updateMatrixWorld();
    world.update(S, clock);
    world.updateTranscript(S, clock);
    const t0 = performance.now();
    renderer.render(W.scene, camera);
    if (!Q.benchmarked && !reduced) {
      gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
      Q.sample(performance.now() - t0);
      if (Q.changed) { Q.changed = false; resize(); }
    }
    ui.updateTags(S);
    ui.updateCaptions(S);
    // the room fades up out of the page's white the first time it is seen
    if (S.visible && !root.classList.contains("is-ready")) requestAnimationFrame(() => root.classList.add("is-ready"));
  }

  // --------------------------------------------------------------- loop
  let raf = 0, last = 0, lastDraw = 0, dirty = true, frozen = false;
  function wake(markDirty) {
    if (markDirty) dirty = true;
    if (reduced) { if (rails) frame(performance.now()); return; }
    if (!raf && rails && S.visible && !document.hidden) {
      last = 0;
      raf = requestAnimationFrame(tick);
    }
  }
  function tick(now) {
    raf = 0;
    const dt = last ? Math.min(0.05, (now - last) / 1000) : 0;
    last = now;
    const playing = S.started && !frozen && (S.phase === "pre" || S.phase === "post");
    if (playing) {
      clock += dt;
      if (S.phase === "pre") {
        S.T += dt;
        if (S.T >= PRE) ui.enterGate();
      } else {
        S.u += dt;
        const k = kindOf(S.decision);
        if (S.u >= POST[k]) {
          S.u = POST[k];
          S.phase = "end";
          ui.showEnd();
        }
      }
    } else if (S.phase === "gate" && !frozen) clock += dt;
    ui.tickCountdown(now);
    pointer.sx += (pointer.x - pointer.sx) * 0.06;
    pointer.sy += (pointer.y - pointer.sy) * 0.06;
    const easing = Math.abs(pointer.x - pointer.sx) + Math.abs(pointer.y - pointer.sy) > 0.002;
    // Behind the prompt the scene is blurred and barely moves: 20 fps is
    // plenty, 30 when the prompt is set aside.
    const gateDue = S.phase === "gate" && now - lastDraw >= (S.later ? 30 : 46);
    if (playing || dirty || easing || gateDue || !Q.benchmarked) {
      dirty = false;
      lastDraw = now;
      frame(now);
      if (playing && Q.frame(dt)) resize();
    }
    if ((playing || S.phase === "gate" || easing || dirty || !Q.benchmarked) && S.visible && !document.hidden) raf = requestAnimationFrame(tick);
  }
  function sleep() {
    cancelAnimationFrame(raf);
    raf = 0;
  }

  stage.addEventListener("pointermove", (e) => {
    if (e.pointerType !== "mouse" || reduced) return;
    const r = stage.getBoundingClientRect();
    pointer.x = ((e.clientX - r.left) / r.width) * 2 - 1;
    pointer.y = ((e.clientY - r.top) / r.height) * 2 - 1;
    wake();
  });
  stage.addEventListener("pointerleave", () => { pointer.x = 0; pointer.y = 0; wake(); });

  // ------------------------------------------------------------- sizing
  function resize() {
    const w = stage.clientWidth, h = stage.clientHeight;
    if (!w || !h) return;
    renderer.setPixelRatio(Q.dpr);
    renderer.setSize(w, h, false);
    W.uFloor.uView.value.set(w * Q.dpr, h * Q.dpr);
    camera.aspect = w / h;
    const kind = w / h >= 1.02 ? "wide" : "tall";
    camera.fov = kind === "wide" ? 32 : 46;
    if (kind !== W.L.kind) {
      W.setLayout(kind);
      rails = buildRails(W.L);
    }
    // keep the cast clear of the caption in the top-left on wide screens
    if (kind === "wide") camera.setViewOffset(w, h, 0, -h * 0.045, w, h);
    else camera.clearViewOffset();
    camera.updateProjectionMatrix();
    ui.measure();
    // a resized canvas is blank until drawn again
    if (rails && S.phase !== "idle") frame(performance.now());
  }

  // ------------------------------------------------------------- start
  W.setLayout(stage.clientWidth / Math.max(1, stage.clientHeight) >= 1.02 ? "wide" : "tall");
  rails = buildRails(W.L);

  const fontsReady = Promise.all([
    document.fonts.load('400 40px "IBM Plex Mono"'),
    document.fonts.load('500 40px "Hanken Grotesk"'),
    document.fonts.load('600 40px "Hanken Grotesk"'),
    new Promise((r) => (paper.complete ? r() : (paper.onload = paper.onerror = r))),
  ]).catch(() => {});

  fontsReady.then(async () => {
    W.redrawCards();
    // every program the film will need is compiled before it starts, so no
    // object appearing mid-film can stall a frame
    resize();
    world.update(S, 0);
    try {
      await (renderer.compileAsync ? renderer.compileAsync(W.scene, camera) : renderer.compile(W.scene, camera));
    } catch (e) { /* compiled lazily instead */ }
    // and every texture is on the GPU before it is first seen
    W.scene.traverse((o) => o.material && o.material.map && renderer.initTexture(o.material.map));
    S.phase = "pre";
    S.T = 0;
    new ResizeObserver(() => resize()).observe(stage);
    if (reduced) {
      root.classList.add("is-still");
      S.started = true;
      S.decision = "once";
      S.phase = "end";
      S.u = POST.allow;
      stillTelling(() => frame(performance.now()));
      frame(performance.now());
      return;
    }
    frame(performance.now());
    const io = new IntersectionObserver(
      (entries) => {
        const e = entries[0];
        S.visible = e.isIntersecting;
        if (e.intersectionRatio >= 0.55 && !S.started) S.started = true;
        if (S.visible) wake(true); else sleep();
        // A scroll that lands while the observer is being set up can leave it
        // reporting a stale ratio with no later crossing: confirm by hand.
        if (S.visible && !S.started) setTimeout(confirmStart, 250);
      },
      { threshold: [0, 0.55] }
    );
    function confirmStart() {
      if (S.started || !S.visible) return;
      const r = stage.getBoundingClientRect();
      const seen = Math.min(r.bottom, innerHeight) - Math.max(r.top, 0);
      if (seen >= 0.55 * r.height) { S.started = true; wake(true); } else setTimeout(confirmStart, 250);
    }
    io.observe(stage);
    document.addEventListener("visibilitychange", () => (document.hidden ? sleep() : wake(true)));
  });

  // Debug hook for headless verification only: ?debug exposes a seek.
  if (params.has("debug")) {
    window.__akhw = {
      S,
      Q,
      gpu,
      W,
      renderer,
      camera,
      go(phase, t, decision) {
        ui.hideEnd();
        S.started = true;
        if (phase === "gate") { S.phase = "pre"; S.T = PRE - 0.01; S.decision = null; wake(true); return; }
        if (phase !== "pre" && S.phase === "gate") { ui.hideAlert(true); root.classList.remove("is-gate", "is-later"); }
        S.phase = phase;
        if (phase === "pre") S.T = t; else S.u = t;
        S.decision = decision ?? S.decision;
        if (phase === "post" && t >= POST[kindOf(S.decision)]) { S.phase = "end"; S.u = POST[kindOf(S.decision)]; ui.showEnd(); }
        wake(true);
      },
      gate() { ui.enterGate(); wake(true); },
      freeze(v) { frozen = !!v; if (!v) wake(true); },
      render() { frame(performance.now()); },
      decide: ui.decide,
    };
  }

  // Still telling: the prompt sits under the scene; choosing re-renders the
  // last frame for that outcome.
  function stillTelling(render) {
    root.dataset.outcome = "allow";
    const lede = $(".akhw-lede");
    if (lede && lede.dataset.still) lede.textContent = lede.dataset.still;
    const alert = $(".akhw-alert");
    const holder = document.createElement("div");
    holder.className = "akhw-still-alert";
    stage.after(holder);
    holder.appendChild(alert);
    alert.hidden = false;
    $(".akhw-hint").hidden = true;
    alert.querySelector(".akhw-alert-foot").hidden = true;
    alert.addEventListener("click", (e) => {
      const b = e.target.closest("[data-decide]");
      if (!b) return;
      S.decision = b.dataset.decide;
      S.u = POST[kindOf(S.decision)];
      S.phase = "end";
      root.dataset.outcome = outcomeOf(S.decision);
      if (render) render();
    });
    if (!render) {
      const img = $(".akhw-poster img");
      if (img) img.loading = "eager";
    }
  }
}

// The agent's transcript, a dark terminal window suspended inside the glass.
// The window (background and title bar) is drawn once. Each line of the
// transcript is its own thin strip with its own small texture, so typing a
// character or turning the spinner re-uploads one strip instead of the
// whole page, and fading a line in is a change of opacity, not a redraw.
import * as THREE from "three";
import { canvasTexture, roundRect, MONO, SANS } from "./textures.js";

// Terminal colours, light on dark.
const INK = "#e9e7e3", GRAY = "#9b9ba1", GREEN = "#5fd38a", DIM = "rgba(255,255,255,0.24)";
const BG = "#1c1d20", BAR = "#2b2c30";
import { decalMaterial } from "./materials.js";

const TW = 2048, TH = 1296; // the page, in canvas pixels
const PW = 2.34, PH = 1.48; // the page, in scene units
const K = 1.28; // drawing scale: layout below is in units of 1/K pixels
const X0 = 92, LH = 66, Y0 = 178;
const BAND_TOP = 58, BAND_H = 104; // a strip, in canvas pixels, around a baseline

export function createTranscript(I, paper) {
  const group = new THREE.Group();
  const base = canvasTexture(TW, TH);
  const sheet = new THREE.Mesh(new THREE.PlaneGeometry(PW, PH), new THREE.MeshBasicMaterial({ map: base.tex, color: 0xffffff, toneMapped: false }));
  sheet.position.z = -0.01;
  const back = new THREE.Mesh(new THREE.PlaneGeometry(PW, PH), new THREE.MeshBasicMaterial({ color: 0x2b2c30, toneMapped: false }));
  back.rotation.y = Math.PI;
  back.position.z = -0.012;
  group.add(sheet, back);

  const stripGeo = new THREE.PlaneGeometry(PW, (BAND_H / TH) * PH);
  const rows = [];
  function row(i) {
    if (rows[i]) return rows[i];
    const t = canvasTexture(TW, BAND_H);
    const mesh = new THREE.Mesh(stripGeo, decalMaterial({ map: t.tex, opacity: 1 }));
    mesh.position.z = -0.008;
    mesh.renderOrder = 1;
    mesh.visible = false;
    group.add(mesh);
    return (rows[i] = { t, mesh, sig: "", y: -1 });
  }
  // Pre-create enough strips for the longest telling so no texture or
  // program is created mid-film.
  for (let i = 0; i < 11; i++) row(i);

  function redrawBase() {
    const { ctx } = base;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    const g = ctx.createLinearGradient(0, 0, 0, TH);
    g.addColorStop(0, BG);
    g.addColorStop(1, "#18191b");
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, TW, TH);
    ctx.setTransform(K, 0, 0, K, 0, 0);
    const w = TW / K;
    ctx.fillStyle = BAR;
    ctx.fillRect(0, 0, w, 96);
    ctx.fillStyle = "rgba(0,0,0,0.5)";
    ctx.fillRect(0, 96, w, 2);
    ["#ff5f57", "#febc2e", "#28c840"].forEach((c, i) => {
      ctx.beginPath();
      ctx.arc(56 + i * 40, 48, 12, 0, Math.PI * 2);
      ctx.fillStyle = c;
      ctx.fill();
    });
    ctx.font = `400 30px ${SANS}`;
    ctx.fillStyle = GRAY;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(I.term.title, w / 2, 50);
    ctx.textAlign = "left";
    ctx.textBaseline = "alphabetic";
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    base.tex.needsUpdate = true;
    rows.forEach((r) => (r.sig = ""));
  }

  // `lines` is a list of { kind, text, chars, caret, alpha, row } computed by
  // the timeline; `spin` is the spinner's phase.
  function update(lines, spin) {
    let y = Y0;
    let n = 0;
    for (const L of lines) {
      if (L.kind === "gap") { y += L.size ?? 20; continue; }
      const r = row(n++);
      const sig = `${L.kind}|${L.text ?? ""}|${L.row ?? ""}|${L.chars ?? ""}|${L.caret ? 1 : 0}|${L.kind === "wait" ? spin : ""}`;
      if (sig !== r.sig) {
        drawLine(r.t, L, y, spin);
        r.sig = sig;
      }
      if (r.y !== y) {
        r.y = y;
        const cy = y * K - BAND_TOP + BAND_H / 2;
        r.mesh.position.y = (0.5 - cy / TH) * PH;
      }
      r.mesh.visible = true;
      r.mesh.material.opacity = L.alpha ?? 1;
      y += L.kind === "me" ? LH + 10 : LH;
    }
    for (let i = n; i < rows.length; i++) rows[i].mesh.visible = false;
  }

  return { group, sheet, update, redrawBase };
}

function drawLine(t, L, y, spin) {
  const { ctx } = t;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, t.w, t.h);
  ctx.setTransform(K, 0, 0, K, 0, BAND_TOP - y * K);
  const x0 = X0;
  if (L.kind === "me") {
    ctx.font = `500 44px ${MONO}`;
    ctx.fillStyle = GRAY;
    ctx.fillText("›", x0 - 46, y);
    ctx.fillStyle = INK;
    const s = [...L.text].slice(0, L.chars ?? Infinity).join("");
    ctx.fillText(s, x0, y);
    if (L.caret) {
      const m = ctx.measureText(s).width;
      ctx.fillRect(x0 + m + 6, y - 36, 20, 44);
    }
  } else if (L.kind === "ai" || L.kind === "ok" || L.kind === "no" || L.kind === "wait") {
    ctx.font = `400 38px ${MONO}`;
    ctx.lineCap = "round";
    if (L.kind === "ai") {
      ctx.beginPath();
      ctx.arc(x0 - 30, y - 13, 9, 0, Math.PI * 2);
      ctx.fillStyle = INK;
      ctx.fill();
    } else if (L.kind === "ok") {
      ctx.strokeStyle = GREEN;
      ctx.lineWidth = 6;
      ctx.beginPath();
      ctx.moveTo(x0 - 42, y - 14);
      ctx.lineTo(x0 - 32, y - 4);
      ctx.lineTo(x0 - 14, y - 28);
      ctx.stroke();
    } else if (L.kind === "no") {
      ctx.strokeStyle = INK;
      ctx.lineWidth = 5;
      ctx.beginPath();
      ctx.moveTo(x0 - 40, y - 28); ctx.lineTo(x0 - 18, y - 6);
      ctx.moveTo(x0 - 18, y - 28); ctx.lineTo(x0 - 40, y - 6);
      ctx.stroke();
    } else {
      // spinner: eight ticks, one bright
      for (let i = 0; i < 8; i++) {
        const ang = (i / 8) * Math.PI * 2;
        ctx.strokeStyle = Math.floor(spin * 8) % 8 === i ? INK : DIM;
        ctx.lineWidth = 5;
        ctx.beginPath();
        ctx.moveTo(x0 - 29 + Math.cos(ang) * 6, y - 16 + Math.sin(ang) * 6);
        ctx.lineTo(x0 - 29 + Math.cos(ang) * 15, y - 16 + Math.sin(ang) * 15);
        ctx.stroke();
      }
    }
    ctx.fillStyle = L.kind === "ok" ? GREEN : L.kind === "wait" ? GRAY : INK;
    ctx.fillText(L.text, x0, y);
  } else if (L.kind === "indent") {
    ctx.font = `400 38px ${MONO}`;
    ctx.fillStyle = INK;
    ctx.fillText(L.text, x0, y);
  } else if (L.kind === "cat") {
    // name · note · ENV  [value: —]
    const [name, note, env] = L.row;
    ctx.font = `600 36px ${SANS}`;
    ctx.fillStyle = INK;
    ctx.fillText(name, x0 + 28, y);
    ctx.font = `400 32px ${SANS}`;
    ctx.fillStyle = GRAY;
    ctx.fillText(note, x0 + 400, y);
    ctx.font = `400 30px ${MONO}`;
    const ew = ctx.measureText(env).width;
    roundRect(ctx, x0 + 760, y - 38, ew + 36, 52, 10);
    ctx.fillStyle = "rgba(255,255,255,0.08)";
    ctx.fill();
    ctx.fillStyle = INK;
    ctx.fillText(env, x0 + 778, y - 2);
    // the empty value slot
    const vx = x0 + 760 + ew + 64;
    ctx.setLineDash([10, 9]);
    ctx.strokeStyle = "rgba(255,255,255,0.3)";
    ctx.lineWidth = 3;
    roundRect(ctx, vx, y - 38, 250, 52, 10);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = DIM;
    ctx.fillText("— — —", vx + 44, y - 2);
  } else if (L.kind === "note") {
    ctx.font = `400 30px ${SANS}`;
    ctx.fillStyle = GRAY;
    ctx.fillText(L.text, x0 + 28, y - 4);
  }
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  t.tex.needsUpdate = true;
}

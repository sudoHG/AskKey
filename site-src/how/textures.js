// Canvas-drawn textures: every word inside the 3D scene is drawn here (or
// in transcript.js), from the page's own i18n block, so the scene speaks
// the page's language. All of it is drawn once, at load or when fonts arrive.
import * as THREE from "three";

export const MONO = '"IBM Plex Mono", "SF Mono", Menlo, "PingFang SC", "Hiragino Sans GB", monospace';
export const SANS = '"Hanken Grotesk", "PingFang SC", "Hiragino Sans GB", "Noto Sans CJK SC", system-ui, sans-serif';
export const INK = "#1d1d1f";
export const GRAY = "#8a8a8e";
export const GREEN = "#2a9d4b";

export function canvasTexture(w, h, { transparent = false } = {}) {
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext("2d");
  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 8;
  tex.generateMipmaps = true;
  tex.minFilter = THREE.LinearMipmapLinearFilter;
  return { canvas, ctx, tex, w, h, transparent };
}

export function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

export function paperFill(ctx, w, h, paper, alpha = 0.22) {
  ctx.fillStyle = "#fbfaf7";
  ctx.fillRect(0, 0, w, h);
  if (paper && paper.complete && paper.naturalWidth) {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.globalCompositeOperation = "multiply";
    const pat = ctx.createPattern(paper, "repeat");
    ctx.fillStyle = pat;
    ctx.fillRect(0, 0, w, h);
    ctx.restore();
  }
}

export function drawCard(t, lines, paper, { head } = {}) {
  const { ctx, w, h } = t;
  const m = 14;
  ctx.clearRect(0, 0, w, h);
  // a soft shadow under the slip, so paper reads against a white room
  ctx.save();
  ctx.shadowColor = "rgba(40, 50, 70, 0.22)";
  ctx.shadowBlur = 12;
  ctx.shadowOffsetY = 4;
  roundRect(ctx, m, m, w - 2 * m, h - 2 * m, 24);
  ctx.fillStyle = "#fbfaf7";
  ctx.fill();
  ctx.restore();
  ctx.save();
  roundRect(ctx, m, m, w - 2 * m, h - 2 * m, 24);
  ctx.clip();
  paperFill(ctx, w, h, paper, 0.25);
  ctx.restore();
  roundRect(ctx, m, m, w - 2 * m, h - 2 * m, 24);
  ctx.strokeStyle = "rgba(0,0,0,0.1)";
  ctx.lineWidth = 2;
  ctx.stroke();
  let y = 80;
  if (head) {
    ctx.font = `500 30px ${SANS}`;
    ctx.fillStyle = GRAY;
    ctx.fillText(head, 46, y);
    y += 70;
  }
  for (const [text, style] of lines) {
    if (style === "name") { ctx.font = `600 54px ${SANS}`; ctx.fillStyle = INK; }
    else if (style === "note") { ctx.font = `400 36px ${SANS}`; ctx.fillStyle = GRAY; }
    else if (style === "mono") { ctx.font = `400 38px ${MONO}`; ctx.fillStyle = INK; }
    else if (style === "empty") {
      ctx.font = `400 32px ${MONO}`;
      ctx.fillStyle = "rgba(0,0,0,0.34)";
      ctx.setLineDash([10, 9]);
      ctx.strokeStyle = "rgba(0,0,0,0.25)";
      ctx.lineWidth = 3;
      const tw = ctx.measureText(text).width;
      roundRect(ctx, 42, y - 42, tw + 40, 58, 10);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillText(text, 62, y - 2);
      y += 70;
      continue;
    }
    ctx.fillText(text, 46, y);
    y += style === "name" ? 66 : 56;
  }
  t.tex.needsUpdate = true;
}

export function drawChip(t, text) {
  const { ctx, w, h } = t;
  ctx.clearRect(0, 0, w, h);
  ctx.save();
  ctx.shadowColor = "rgba(40, 50, 70, 0.2)";
  ctx.shadowBlur = 10;
  ctx.shadowOffsetY = 3;
  roundRect(ctx, 14, 14, w - 28, h - 28, (h - 28) / 2);
  ctx.fillStyle = "#ffffff";
  ctx.fill();
  ctx.restore();
  ctx.strokeStyle = "rgba(0,0,0,0.1)";
  ctx.lineWidth = 3;
  ctx.stroke();
  ctx.strokeStyle = GREEN;
  ctx.lineWidth = 9;
  ctx.lineCap = "round";
  ctx.beginPath();
  ctx.moveTo(62, h / 2);
  ctx.lineTo(80, h / 2 + 18);
  ctx.lineTo(112, h / 2 - 22);
  ctx.stroke();
  ctx.font = `500 58px ${MONO}`;
  ctx.fillStyle = INK;
  ctx.textBaseline = "middle";
  ctx.fillText(text, 140, h / 2 + 3);
  ctx.textBaseline = "alphabetic";
  t.tex.needsUpdate = true;
}

export function drawSite(t, I, live) {
  const { ctx, w, h } = t;
  ctx.clearRect(0, 0, w, h);
  ctx.save();
  roundRect(ctx, 0, 0, w, h, 34);
  ctx.clip();
  ctx.fillStyle = "#ffffff";
  ctx.fillRect(0, 0, w, h);
  // chrome
  ctx.fillStyle = "#f1f1f2";
  ctx.fillRect(0, 0, w, 92);
  ctx.fillStyle = "rgba(0,0,0,0.08)";
  ctx.fillRect(0, 92, w, 2);
  [0, 1, 2].forEach((i) => {
    ctx.beginPath();
    ctx.arc(52 + i * 36, 46, 11, 0, Math.PI * 2);
    ctx.fillStyle = "#d4d4d8";
    ctx.fill();
  });
  roundRect(ctx, w / 2 - 220, 22, 440, 48, 24);
  ctx.fillStyle = "#ffffff";
  ctx.fill();
  ctx.font = `400 28px ${SANS}`;
  ctx.fillStyle = "#5a5a5e";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(I.site.url, w / 2, 47);
  ctx.textAlign = "left";
  if (live) {
    const g = ctx.createLinearGradient(0, 94, w, h);
    g.addColorStop(0, "#f6efe6");
    g.addColorStop(1, "#e9eef4");
    ctx.fillStyle = g;
    ctx.fillRect(0, 94, w, 300);
    ctx.font = `600 66px ${SANS}`;
    ctx.fillStyle = INK;
    ctx.textBaseline = "alphabetic";
    ctx.fillText(I.site.title, 64, 250);
    ctx.fillStyle = "rgba(0,0,0,0.12)";
    roundRect(ctx, 64, 290, 420, 20, 10); ctx.fill();
    roundRect(ctx, 64, 326, 300, 20, 10); ctx.fill();
    [0, 1, 2].forEach((i) => {
      roundRect(ctx, 64 + i * 296, 430, 270, 190, 18);
      ctx.fillStyle = ["#eef1f4", "#f3eee8", "#eef3ee"][i];
      ctx.fill();
    });
    // status
    ctx.font = `500 28px ${SANS}`;
    const s = I.site.live;
    const sw = ctx.measureText(s).width;
    roundRect(ctx, w - sw - 112, 24, sw + 74, 44, 22);
    ctx.fillStyle = "rgba(42,157,75,0.12)";
    ctx.fill();
    ctx.beginPath();
    ctx.arc(w - sw - 84, 46, 9, 0, Math.PI * 2);
    ctx.fillStyle = GREEN;
    ctx.fill();
    ctx.fillStyle = "#1f7a3a";
    ctx.textBaseline = "middle";
    ctx.fillText(s, w - sw - 64, 47);
  } else {
    ctx.fillStyle = "#f6f6f7";
    ctx.fillRect(0, 94, w, h - 94);
    ctx.fillStyle = "rgba(0,0,0,0.06)";
    roundRect(ctx, 64, 170, 380, 44, 12); ctx.fill();
    roundRect(ctx, 64, 240, 520, 20, 10); ctx.fill();
    roundRect(ctx, 64, 276, 360, 20, 10); ctx.fill();
    ctx.font = `400 34px ${SANS}`;
    ctx.fillStyle = "#9a9a9e";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(I.site.idle, w / 2, h - 120);
    ctx.textAlign = "left";
  }
  ctx.restore();
  ctx.textBaseline = "alphabetic";
  t.tex.needsUpdate = true;
}

export function drawProgramFace(t, I) {
  const { ctx, w, h } = t;
  ctx.clearRect(0, 0, w, h);
  // keyhole well on the left, where the key arrives
  const cx = 190, cy = h / 2 - 20;
  const g = ctx.createRadialGradient(cx, cy, 10, cx, cy, 130);
  g.addColorStop(0, "rgba(0,0,0,0.6)");
  g.addColorStop(1, "rgba(0,0,0,0)");
  ctx.fillStyle = g;
  ctx.fillRect(cx - 140, cy - 140, 280, 280);
  ctx.beginPath();
  ctx.arc(cx, cy - 16, 26, 0, Math.PI * 2);
  ctx.moveTo(cx - 14, cy);
  ctx.lineTo(cx + 14, cy);
  ctx.lineTo(cx + 22, cy + 52);
  ctx.lineTo(cx - 22, cy + 52);
  ctx.closePath();
  ctx.fillStyle = "#050505";
  ctx.fill();
  const x = 372;
  ctx.font = `500 64px ${MONO}`;
  ctx.fillStyle = "#f4f4f5";
  ctx.fillText(I.prog, x, 150);
  ctx.font = `400 30px ${MONO}`;
  ctx.fillStyle = "rgba(255,255,255,0.42)";
  ctx.fillText("#!/bin/sh", x + 2, 226);
  ctx.fillText("rsync ./site server:", x + 2, 272);
  ctx.fillText("  uses $DEPLOY_TOKEN", x + 2, 318);
  t.tex.needsUpdate = true;
}

// A soft contact shadow: dense near the centre, long soft falloff. Drawn in
// white; the decal's colour tints it.
export function shadowTexture() {
  const c = document.createElement("canvas");
  c.width = c.height = 256;
  const ctx = c.getContext("2d");
  const g = ctx.createRadialGradient(128, 128, 0, 128, 128, 128);
  g.addColorStop(0, "rgba(255,255,255,0.62)");
  g.addColorStop(0.3, "rgba(255,255,255,0.36)");
  g.addColorStop(0.62, "rgba(255,255,255,0.1)");
  g.addColorStop(1, "rgba(255,255,255,0)");
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, 256, 256);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

// Shapes seen through frosted glass: filled once and blurred with a canvas
// shadow (which every browser blurs, unlike ctx.filter).
export function blurredShapesTexture(shapes, { minX, maxX, minY, maxY, ppu, blur, color, passes = 1 }) {
  const c = document.createElement("canvas");
  c.width = Math.round((maxX - minX) * ppu);
  c.height = Math.round((maxY - minY) * ppu);
  const ctx = c.getContext("2d");
  const off = c.width + 200;
  ctx.shadowColor = color;
  ctx.shadowBlur = blur;
  ctx.shadowOffsetX = off;
  ctx.fillStyle = "#000";
  const px = (x) => (x - minX) * ppu - off, py = (y) => (maxY - y) * ppu;
  ctx.beginPath();
  for (const sh of shapes) {
    const { shape, holes } = sh.extractPoints(24);
    [shape, ...holes].forEach((pts) => {
      pts.forEach((p, i) => (i ? ctx.lineTo(px(p.x), py(p.y)) : ctx.moveTo(px(p.x), py(p.y))));
      ctx.closePath();
    });
  }
  // repeated passes build up density in thin parts (a key's shaft) that a
  // single blur would leave faint
  for (let i = 0; i < passes; i++) ctx.fill("evenodd");
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

export function glowTexture() {
  const c = document.createElement("canvas");
  c.width = c.height = 128;
  const ctx = c.getContext("2d");
  const g = ctx.createRadialGradient(64, 64, 0, 64, 64, 64);
  g.addColorStop(0, "rgba(255,255,255,1)");
  g.addColorStop(0.18, "rgba(255,255,255,0.55)");
  g.addColorStop(0.45, "rgba(255,255,255,0.16)");
  g.addColorStop(1, "rgba(255,255,255,0)");
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, 128, 128);
  return new THREE.CanvasTexture(c);
}

export function dotTexture() {
  const c = document.createElement("canvas");
  c.width = c.height = 64;
  const ctx = c.getContext("2d");
  const g = ctx.createRadialGradient(32, 32, 0, 32, 32, 32);
  g.addColorStop(0, "rgba(255,255,255,1)");
  g.addColorStop(0.5, "rgba(255,255,255,0.8)");
  g.addColorStop(1, "rgba(255,255,255,0)");
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, 64, 64);
  const tex = new THREE.CanvasTexture(c);
  return tex;
}

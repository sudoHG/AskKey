// Resolution is the one knob that matters: every material here is cheap
// per pixel, so frame cost scales with the drawing buffer. The pixel ratio
// starts capped (1.5, or 1 on a software renderer), is set from a short
// timed benchmark of the first real frames, and steps down if the film
// starts dropping frames. It never steps back up above what the benchmark
// allowed, so it cannot oscillate.
export function probeGPU() {
  let gl = null;
  try {
    gl = document.createElement("canvas").getContext("webgl2");
  } catch (e) {
    gl = null;
  }
  if (!gl) return null;
  const dbg = gl.getExtension("WEBGL_debug_renderer_info");
  const name = String(dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER));
  gl.getExtension("WEBGL_lose_context")?.loseContext();
  return { name, software: /swiftshader|llvmpipe|softpipe|software|basic render/i.test(name) };
}

const FLOOR = 0.5; // never render below half the CSS resolution
const BUDGET = 7.5; // ms of synchronous render cost we accept per frame

export function createQuality(gpu, params) {
  const device = Math.max(1, window.devicePixelRatio || 1);
  const forced = params.has("dpr") ? Number(params.get("dpr")) : 0;
  const cap = forced || Math.min(device, gpu.software ? 1 : 1.5);
  const q = { dpr: cap, max: cap, benchmarked: !!forced || params.has("nobench"), changed: false };
  let win = [], hold = 0, smooth = 0;

  // `sample(ms)` is called with the synchronous cost of each of the first
  // frames rendered with a forced GPU sync; three samples decide.
  const bench = [];
  q.sample = (ms) => {
    if (q.benchmarked) return false;
    bench.push(ms);
    // the first frame carries one-off uploads, so the next two decide; a
    // hopeless frame on a slow machine is enough on its own
    if (bench.length < 3 && ms < 250) return true;
    const cost = bench.length >= 3 ? Math.min(bench[1], bench[2]) : ms;
    q.benchmarked = true;
    if (cost > BUDGET) {
      const next = Math.max(FLOOR, Math.round(q.dpr * Math.sqrt(BUDGET / cost) * 20) / 20);
      if (next < q.dpr - 0.01) {
        q.dpr = q.max = next;
        q.changed = true;
      }
    }
    return false;
  };

  // `frame(dt)` is called every played frame with the interval since the
  // last one, in seconds. Returns true when the resolution changed.
  q.frame = (dt) => {
    if (forced || dt <= 0 || dt > 0.25) return false;
    smooth = smooth ? smooth * 0.9 + dt * 0.1 : dt;
    if (hold > 0) { hold--; return false; }
    win.push(dt);
    if (win.length < 40) return false;
    const sorted = win.slice().sort((a, b) => a - b);
    win = [];
    const p75 = sorted[Math.floor(sorted.length * 0.75)];
    if (p75 > 0.0205 && q.dpr > FLOOR) {
      // a quarter fewer pixels each step
      q.dpr = q.max = Math.max(FLOOR, Math.round(q.dpr * 0.87 * 20) / 20);
      hold = 30; // let the new size settle before judging again
      return true;
    }
    return false;
  };
  q.fps = () => (smooth ? 1 / smooth : 0);
  return q;
}

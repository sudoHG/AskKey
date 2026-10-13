// The film's clock: when things happen, and the easing they happen with.
export const PRE = 14.4; // the request reaches you
export const POST = { allow: 16.5, deny: 8.5 };
export const STEP_AT = { pre: [0, 3.4, 8.6], allow: [0, 9.2], deny: [0, 2.6] };
// the last seconds of each ending, when the room gives way to the page
export const WHITE_OUT = 2.6;

export const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
export const seg = (t, a, b) => clamp((t - a) / (b - a));
export const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
export const easeOut = (t) => 1 - Math.pow(1 - t, 3);
export const smooth = (t) => t * t * (3 - 2 * t);
export const fade = (t, a, b, inn = 0.35, out = 0.35) => Math.min(seg(t, a, a + inn), 1 - seg(t, b - out, b));

export const kindOf = (d) => (d === "once" || d === "timed" ? "allow" : d ? "deny" : null);
export const outcomeOf = (d) => (d === "once" ? "allow" : d || "allow");

// Materials for the morning desk. None of them needs a second render of
// the scene: the glass is a premultiplied layer (a Fresnel-weighted body
// plus the environment's reflections), the desk is lit by a procedural
// window, and the delivered key dissolves in its own shader.
import * as THREE from "three";

// Glass without a transmission pass. Light reflected off the surface is
// added on top of whatever is behind it; the body itself is a thin tint
// that thickens toward grazing angles, the way the edges of a real slab of
// glass go dark and green. `edgeColor` pulls that body toward a fixed
// colour so the rim reads on a white page even where the light is flat.
export function glassMaterial({
  color = 0xffffff,
  edgeColor = 0x6f8a86,
  edgeMix = 0.6,
  specEdge = 0,
  base = 0.04,
  edge = 0.6,
  power = 2.4,
  roughness = 0.04,
  envMapIntensity = 1.4,
  clearcoat = 0,
  clearcoatRoughness = 0.06,
  side = THREE.FrontSide,
  key = "glass",
} = {}) {
  const Physical = clearcoat > 0 ? THREE.MeshPhysicalMaterial : THREE.MeshStandardMaterial;
  const m = new Physical({ color, roughness, metalness: 0, envMapIntensity, transparent: true, premultipliedAlpha: true, depthWrite: false, side });
  if (clearcoat > 0) Object.assign(m, { clearcoat, clearcoatRoughness });
  const u = {
    uBase: { value: base },
    uEdge: { value: edge },
    uPow: { value: power },
    uEdgeColor: { value: new THREE.Color(edgeColor) },
    uEdgeMix: { value: edgeMix },
    uSpecEdge: { value: specEdge },
  };
  m.userData.u = u;
  m.onBeforeCompile = (sh) => {
    Object.assign(sh.uniforms, u);
    sh.fragmentShader = sh.fragmentShader
      .replace("#include <common>", "#include <common>\nuniform float uBase, uEdge, uPow, uEdgeMix, uSpecEdge;\nuniform vec3 uEdgeColor;")
      .replace(
        "#include <opaque_fragment>",
        `float gNV = clamp(abs(dot(normal, normalize(vViewPosition))), 0.0, 1.0);
float gF = pow(1.0 - gNV, uPow);
// what the surface reflects is light the background no longer sends through
float gR = 0.04 + 0.96 * pow(1.0 - gNV, 5.0);
float gA = clamp(uBase + uEdge * gF, 0.0, 1.0);
vec3 gBody = mix(totalDiffuse, uEdgeColor, uEdgeMix);
// thick glass seen edge-on shows its own dark body more than the room
vec3 gSpec = max(outgoingLight - totalDiffuse, vec3(0.0)) * (1.0 - uSpecEdge * gF);
gl_FragColor = vec4(gBody * gA + gSpec, clamp(gA + gR * (1.0 - gA) * (1.0 - uSpecEdge * gF), 0.0, 1.0));`
      )
      .replace("#include <premultiplied_alpha_fragment>", "");
  };
  m.customProgramCacheKey = () => `akhw-${key}`;
  return m;
}

// A decal drawn in the opaque pass with alpha blending: it lands after the
// desk and before every transparent object, so it never needs sorting.
export function decalMaterial(params) {
  return new THREE.MeshBasicMaterial({
    transparent: false,
    blending: THREE.CustomBlending,
    blendSrc: THREE.SrcAlphaFactor,
    blendDst: THREE.OneMinusSrcAlphaFactor,
    blendSrcAlpha: THREE.OneFactor,
    blendDstAlpha: THREE.OneMinusSrcAlphaFactor,
    depthWrite: false,
    toneMapped: false,
    ...params,
  });
}

// The desk: oiled black walnut in early light. The scan is used in its own
// colour; a soft window falls across it with a satin sheen; and it fades
// into the page's white beyond the cast (all in one cheap unlit shader).
export function deskMaterial() {
  const m = new THREE.MeshBasicMaterial({ color: 0xffffff, toneMapped: false });
  const u = {
    uCenter: { value: new THREE.Vector3() },
    uRad: { value: new THREE.Vector2(5, 11) },
    uWhite: { value: 0 },
    uAsh: { value: new THREE.Color("#7a5643") },
    uGrain: { value: new THREE.Color("#4a3124") },
    uGain: { value: 1.12 },
    uSheen: { value: 0.07 },
    uShade: { value: 0.86 },
    uSun: { value: 0.5 },
    uWinO: { value: new THREE.Vector2(-1.2, -1.0) },
    uWinS: { value: new THREE.Vector2(3.6, 2.6) },
    uWinA: { value: 0.62 },
    uHasMap: { value: 0 },
    uView: { value: new THREE.Vector2(1, 1) },
  };
  m.userData.u = u;
  m.onBeforeCompile = (sh) => {
    Object.assign(sh.uniforms, u);
    sh.vertexShader = sh.vertexShader
      .replace("#include <common>", "#include <common>\nvarying vec3 vWp;")
      .replace("#include <worldpos_vertex>", "#include <worldpos_vertex>\nvWp = (modelMatrix * vec4(transformed, 1.0)).xyz;");
    sh.fragmentShader = sh.fragmentShader
      .replace(
        "#include <common>",
        `#include <common>
varying vec3 vWp;
uniform vec3 uCenter, uAsh, uGrain;
uniform vec2 uRad, uWinO, uWinS, uView;
uniform float uWhite, uShade, uSun, uWinA, uHasMap, uGain, uSheen;
float akBand(float x, float h, float s) { return smoothstep(-h - s, -h + s, x) * (1.0 - smoothstep(h - s, h + s, x)); }
float akBars(float x, float pitch, float bar, float s) { float d = abs(fract(x / pitch + 0.5) - 0.5) * pitch; return smoothstep(bar - s, bar + s, d); }`
      )
      .replace(
        "#include <map_fragment>",
        `#ifdef USE_MAP
  vec4 akT = texture2D(map, vMapUv);
  diffuseColor.rgb = mix(mix(uGrain, uAsh, 0.5), akT.rgb * uGain, uHasMap);
#else
  diffuseColor.rgb = mix(uGrain, uAsh, 0.82);
#endif
  // a tall window to the back left: four soft panes, then a broad falloff
  float akC = cos(uWinA), akS = sin(uWinA);
  vec2 akQ = mat2(akC, -akS, akS, akC) * (vWp.xz - uWinO);
  akQ.x += akQ.y * 0.32;
  float akWin = akBand(akQ.x, uWinS.x, 0.45) * akBand(akQ.y, uWinS.y, 0.55);
  akWin *= akBars(akQ.x, uWinS.x, 0.1, 0.16) * akBars(akQ.y + uWinS.y, uWinS.y, 0.08, 0.16);
  float akFall = 1.0 - smoothstep(-6.0, 9.0, dot(vWp.xz - uWinO, vec2(0.55, 0.83)));
  // as an ending closes the window light thins out with the room
  diffuseColor.rgb *= uShade + (uSun * akWin + 0.06 * akFall) * (1.0 - uWhite);
  // hand-rubbed oil: the window reads as a soft satin sheen on the wood
  diffuseColor.rgb += vec3(1.0, 0.96, 0.9) * uSheen * akWin * (1.0 - uWhite);`
      )
      .replace(
        "#include <dithering_fragment>",
        `#include <dithering_fragment>
float akD = length((vWp.xz - uCenter.xz) * vec2(0.8, 1.15));
float akR0 = mix(uRad.x, uRad.x * 0.2, uWhite), akR1 = mix(uRad.y, uRad.x * 0.85, uWhite);
float akFar = smoothstep(akR0, akR1, akD);
// the desk runs off both sides of the window; only the top and bottom of
// the frame soften into the page
float akY = gl_FragCoord.y / uView.y;
float akEdge = 1.0 - smoothstep(0.0, 0.12, akY) * (1.0 - smoothstep(0.86, 1.0, akY));
float akW = max(akFar, akEdge);
// a whisper of noise keeps the long fade free of bands
akW = clamp(akW + (fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453) - 0.5) / 255.0, 0.0, 1.0);
gl_FragColor.rgb = mix(gl_FragColor.rgb, vec3(1.0), akW);`
      );
  };
  m.customProgramCacheKey = () => "akhw-desk";
  return m;
}

// The delivered copy of the key burns away from its tip: noise discard plus
// a hot edge.
export function dissolveMaterial(base) {
  const uDis = { value: 0 };
  const m = base.clone();
  m.onBeforeCompile = (sh) => {
    sh.uniforms.uDis = uDis;
    sh.vertexShader = sh.vertexShader
      .replace("#include <common>", "#include <common>\nvarying vec3 vKeyPos;")
      .replace("#include <begin_vertex>", "#include <begin_vertex>\nvKeyPos = position;");
    sh.fragmentShader = sh.fragmentShader
      .replace(
        "#include <common>",
        `#include <common>
varying vec3 vKeyPos;
uniform float uDis;
float kh(vec3 p){ p = fract(p*0.3183099+.1); p*=17.0; return fract(p.x*p.y*p.z*(p.x+p.y+p.z)); }
float kn(vec3 x){ vec3 i=floor(x); vec3 f=fract(x); f=f*f*(3.0-2.0*f);
  return mix(mix(mix(kh(i+vec3(0,0,0)),kh(i+vec3(1,0,0)),f.x),mix(kh(i+vec3(0,1,0)),kh(i+vec3(1,1,0)),f.x),f.y),
             mix(mix(kh(i+vec3(0,0,1)),kh(i+vec3(1,0,1)),f.x),mix(kh(i+vec3(0,1,1)),kh(i+vec3(1,1,1)),f.x),f.y),f.z); }`
      )
      .replace(
        "#include <clipping_planes_fragment>",
        `#include <clipping_planes_fragment>
float kN = kn(vKeyPos*26.0)*0.65 + kn(vKeyPos*61.0)*0.35;
float kD = uDis*1.15 - 0.08 + (vKeyPos.x+0.5)*0.25;
if (kN < kD) discard;
float kEdge = 1.0 - smoothstep(kD, kD+0.07, kN);`
      )
      .replace(
        "#include <emissivemap_fragment>",
        `#include <emissivemap_fragment>
totalEmissiveRadiance += vec3(1.0, 0.42, 0.2) * kEdge * step(0.001, uDis) * 2.2;`
      );
  };
  m.customProgramCacheKey = () => "akhw-dissolve";
  return { mat: m, uDis };
}

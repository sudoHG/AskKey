# Ask Key — "How it works" (morning desk, one unbroken shot)

## Concept

A single continuous camera move across an oiled black walnut desk by a window in early morning, where three real-time 3D objects act out the mechanism: the AI is a clear glass block with its live transcript sealed inside (so you can see everything it holds), Ask Key is a frosted vault in the shape of the app icon with vermilion keys inside it, and `./deploy.sh` is a graphite box with a keyhole. The film stops when the request reaches you and shows Ask Key's real approval prompt with a live 5-minute countdown. Whatever you click actually decides the ending: Allow sends a copy of the key out of the frosted glass, around the AI and into the program, which runs, publishes the site and dissolves the key; Deny (or letting it expire) leaves the key untouched and the program never runs. Either way the AI gets back one line and ends holding zero keys. Vermilion is reserved for the secret, so you can watch where it goes and see it never enters the glass.

The room belongs to the page around it. The stage is the page's own white: the desk fades into white beyond the cast (the white wall of a bright room), the top and bottom of the stage dissolve into the page, the canvas fades up out of white the first time it is seen, and as each ending closes the desk recedes until the cast stands on white paper with its labels, like the slips with seals further down the site. Light is cool morning daylight from a window to the back left: a soft window falls across the desk, the glass and lacquer reflect that window, contact shadows fall away from it, and light through the red keys tints the desk under the vault. Type, ink, vermilion and paper slips are the site's own (#fff, #1a1a1a, #b8281e, Hanken Grotesk, Songti, the site's paper texture and its vermilion "approved" seal).

## Techniques

- three.js r186 bundled and minified with esbuild into one ES module (`site/how/how.js`, about 640 KB, about 170 KB gzipped). Its MIT licence ships as `site/how/THREE-LICENSE.txt` and the bundle's first line points to it. No other runtime dependencies and no requests to other hosts.
- One render pass per frame. No transmission pass, no shadow maps, no post-processing.
  - Clear glass is a premultiplied layer: what the surface reflects (Fresnel, F0 = 0.04) replaces the light the background no longer sends through, and the slab's body thickens to a dark slate-green toward grazing angles, so its edges read on a white page. Back and front faces are two meshes, so three.js never flips a double-sided material twice a frame.
  - The frosted vault is the same layer, rougher, over a milky core (the icon's silhouette, blurred once into a canvas texture) that hides the desk the way ground glass would. The keys inside are their own silhouettes blurred once into a texture and drawn just after the shell, so they stay vermilion instead of turning pink under a white veil. The only sharp key is the copy that is delivered.
  - The reflections come from a small white room rendered once into a prefiltered environment map at load: white walls, a pale desk, a tall four-pane window and a few dark shapes (a shelf, a doorway) so glass and lacquer have something dark to reflect.
  - The desk is one unlit shader: a seamless black walnut texture in its own colour with a satin sheen where the window falls, a procedural four-pane window patch with soft mullion shadows, a broad falloff from the window, and the fade into the page's white. Contact shadows and the red tint under the vault are decals drawn in the opaque pass, so they need no sorting.
- Text in the scene is drawn into canvas textures from a JSON block in the page, so each language renders its own scene. The transcript is a static sheet plus one thin strip per line: typing a character or turning the spinner re-uploads one 2048×104 strip instead of a 2048×1296 page, and fading a line in changes an opacity rather than redrawing.
- A camera rig of key frames (target, view direction, framing radius) on Catmull-Rom splines with a monotone time warp, so the move never stops between frames. Distance is computed from the viewport, so the same shot recomposes for a phone held upright.
- Every visual is a pure function of the film's time and the reader's decision, which makes chapter seeking, replays and the alternate endings exact.
- The approval prompt is real DOM (buttons, Details disclosure with the app's actual rows, Esc to decide later, a pending pill, a live countdown that really expires at 0:00). Labels pinned to scene objects are projected DOM elements, measured once when they appear and written in one pass, so the browser never lays out mid-frame. Status labels are solid paper pills, so nothing re-blurs the scene behind them; the three names are light text with a soft shadow, shown only while the wood is behind them.

## Performance

What it does to stay smooth:

- Pixel ratio capped at 1.5 (1 on a software renderer; antialiasing off there too). The first three frames are timed with a forced GPU sync and the ratio is lowered (down to 0.5) if a frame would cost more than 7.5 ms; while the film plays, a 40-frame window steps it down by 13% whenever the 75th percentile runs over 20.5 ms. It never steps back up, so it cannot oscillate.
- Every shader program and every texture is compiled and uploaded before the film starts (`compileAsync`, `initTexture`, 1×1 stand-ins for images still loading), so nothing appearing mid-film stalls a frame. Verified: 16 programs before the film, 16 after both endings.
- Frames are drawn only when something moves: every frame while the film plays; 20 fps behind the blurred approval prompt (30 when set aside); otherwise only on pointer movement, resize or a texture arriving. Nothing is drawn while the section is off screen or the tab is hidden. Verified: 0 frames in 2 s while an ending sits still.
- No per-frame allocations in the timeline, camera or labels.

Measured in headless Google Chrome 1440×900 at device pixel ratio 2, rAF intervals over the whole film (14 s to the prompt, 1.5 s at the prompt, 14 s of the Allow ending), first 5 frames dropped. "Long" counts frames over 50 ms. The test Mac is an M2 Max under heavy load from other work, so the software-renderer rows in particular are noisy.

| Condition | Before (night, c3) median / p95 / long / fps | After (morning) median / p95 / long / fps |
|---|---|---|
| (a) GPU (ANGLE Metal) | 16.7 ms / 33.3 ms / 9 / 54.8 | 16.7 ms / 16.7 ms / 0 / 60.0 |
| (b) SwiftShader (`--use-angle=swiftshader`) | 4250 ms / 4283 ms / all / 0.3 | 16.7 ms / 33.4 ms / 22–42 / 44–51 (renders at 0.5×; three runs) |
| (c) CPU throttled 4× (`Emulation.setCPUThrottlingRate`) | 16.7 ms / 83.4 ms / 102 / 41.5 | 16.7 ms / 16.7 ms / 0 / 59.9 |

For a like-for-like software check at device pixel ratio 1 (where the night version starts at its lowest resolution): before 417 ms median, 1050 ms p95, 2.2 fps; after 16.7 ms, 33.4 ms, 50 fps.

Where the time went before, and what fixed it:

- CPU: a JS profile of the opening at 4× throttle spent 3.2 s of 10 s in `texSubImage2D`, re-uploading the 2048×1296 transcript texture whenever a character was typed, a line faded or the spinner turned. Now 39 ms (per-line strips). `updateTags` (layout thrash from reading `offsetWidth` per label per frame) went from 420 ms to 31 ms.
- GPU: a synchronous render of a mid-film frame took 11.5 ms at ratio 2, of which the transmission pass was about half (5.6 ms without it); at ratio 1, 7.7 ms. Now 2.6 ms at ratio 1.5 and 2.1 ms at ratio 1, with no transmission pass and no spotlights or point light (one hemisphere and one directional light).

The targets (60 fps locked on an M1 MacBook Air at 1440×900; at least 40 fps without long frames on an Intel Mac with integrated graphics) were not measured on those machines. The headroom above (a full frame at about 2.6 ms of synchronous GPU work on an M2 Max at ratio 1.5, and a smooth film on a software rasteriser) is the evidence; the benchmark and runtime monitor lower the resolution on anything slower.

## Accessibility and fallbacks

- The whole story is real text in an ordered list (`.akhw-steps`); the on-stage caption is a visual copy of it. The prompt is an `alertdialog` with real buttons.
- `prefers-reduced-motion: reduce`: no animation. The stage shows the final composed frame, all six steps are listed in full, and the prompt sits under the scene; choosing Deny re-renders the still for that ending.
- No WebGL2: a pre-rendered poster (`site/how/img/poster-*-wide|tall.webp`, the morning final frame) plus the same still telling.

## Where it lives

- Built files: `site/how/` (`how.js`, `how.css`, `img/`, `THREE-LICENSE.txt`). The section markup and its `akhw-i18n` JSON are in `site/index.html` and `site/zh/index.html`; fonts come from `site/fonts/`.
- Source: this folder. It is not deployed.

## Source and build

This folder holds the readable source, every file under 600 lines:

| File | What it holds |
|---|---|
| `how.src.js` | entry: renderer, render loop, sizing, start-up, debug hook, still telling |
| `timing.js` | the film's clock and easings |
| `rig.js` | camera key frames and rails |
| `world.js` | the timeline: what every object does at a given time |
| `ui.js` | labels, captions, chapter rail, the prompt and countdown, endings |
| `quality.js` | GPU probe, benchmark and runtime resolution control |
| `scene.js` | the objects |
| `layout.js` | wide and portrait layouts and the paths between objects |
| `materials.js` | glass, desk, decal and dissolve shaders |
| `room.js` | the room the objects reflect |
| `transcript.js` | the transcript sheet and its per-line strips |
| `textures.js` | canvas drawing for cards, chip, site, program face, shadows, blurred shapes |

Rebuild (exact versions are pinned in `package.json`):

```sh
cd site-src/how
npm ci
npm run build     # writes site/how/how.js
npm run license   # copies three.js's LICENSE to site/how/THREE-LICENSE.txt
```

`npm run build` also runs `stamp.mjs`, which adds a content hash (`?v=`) to every script and stylesheet URL in both pages, so a browser never pairs new pages with an old cached file. Run `npm run stamp` after editing `site/style.css` or `site/motion.js` by hand.


## Fonts and text in images

Only open fonts are shipped or rasterised:

- Shipped web fonts: Hanken Grotesk (OFL) and IBM Plex Mono Regular, Latin-1 split, as published unmodified by IBM in the IBM/plex repository (OFL, reserved font name "Plex"). Licences are in `site/fonts/`.
- System fonts (PingFang SC, Songti SC, SF Mono and similar) are only named in CSS and canvas font stacks; they render on the visitor's own machine and nothing of them is shipped.
- Images that contain text are made only with open fonts: the vermilion seals (`site/assets/seal-*.webp`, `site/how/img/seal-zhun.webp`) are typeset in Source Han Serif CN Heavy, the No-WebGL posters are rendered with every system family name redirected to Source Han Sans CN, and the share images (`site/assets/og-*.jpg`) are set in Source Han Serif CN, Source Han Sans CN and Hanken Grotesk (Adobe's fonts are OFL). Re-render them the same way; never with a system font.

## Notes

- All secret values are absent by design: the scene shows names, notes and variable names only, and the value slots are empty.
- The walnut texture (`site/how/img/walnut.webp`) was generated for this piece and made seamless (planks meet at the tile edge; the ends are cross-faded); the paper texture, seal and app icon come from the site's own assets. Fonts are the site's Hanken Grotesk and IBM Plex Mono (OFL, licences in `site/fonts/`).
- Verified in headless Google Chrome (Metal) at 1440×900, 1920×1080 and 390×844, both languages, both endings, Esc/pending, Details, chapter seeking and reduced motion, with no console errors and no requests to other hosts. Safari was not tested directly; the code uses WebGL2, standard CSS with `-webkit-` prefixes where needed, and canvas shadows instead of `ctx.filter` for its blurs.

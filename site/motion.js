// A small, self-contained animation. The markup already shows each
// section's final state; these only add motion on wide screens when the
// reader has not asked for reduced motion.
(() => {
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches || innerWidth < 900;
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));

  // The three permissions, stamped in turn.
  const desk = document.querySelector(".desk");
  if (desk) {
    if (!still) {
      desk.classList.add("animated");
      const stone = desk.querySelector(".stone");
      const slips = [...desk.querySelectorAll(".slip")];
      // Settle on the final state: every seal shown, the stone put away.
      const finish = () => {
        stone.getAnimations().forEach((a) => a.cancel());
        stone.style.opacity = 0;
        stone.classList.remove("moving");
        for (const slip of slips) {
          slip.querySelector(".imp").style.opacity = "1";
          if (slip.classList.contains("hidden-slip")) slip.classList.add("gone");
        }
      };
      const run = async () => {
        // If the layout changes while the stone is in the air, stop rather
        // than fly to stale coordinates.
        const stop = () => stone.getAnimations().forEach((a) => a.cancel());
        addEventListener("resize", stop, { once: true });
        try { await stamp(); } catch { /* cancelled */ }
        removeEventListener("resize", stop);
        finish();
      };
      const stamp = async () => {
        // Positions come from layout offsets inside the desk, not from the
        // viewport, so scrolling while the stone is in the air cannot move
        // its target.
        const box = (el) => {
          let x = 0, y = 0;
          for (let e = el; e && e !== desk; e = e.offsetParent) { x += e.offsetLeft; y += e.offsetTop; }
          return { x, y, w: el.offsetWidth, h: el.offsetHeight };
        };
        const dw = desk.offsetWidth;
        // The seal image has a margin of 40/720 around the printed border;
        // the stone's face is as wide as the stone, so size the stone to
        // the printed border and land its face on it.
        const inset = 40 / 720;
        const sw = box(slips[0].querySelector(".imp")).w * (1 - 2 * inset);
        const sh = sw * 2.16;
        stone.style.width = `${sw}px`;
        const spot = (slip) => {
          const r = box(slip.querySelector(".imp"));
          return { x: r.x + r.w / 2 - sw / 2, y: r.y + r.h - r.h * inset - sh };
        };
        const move = (from, to, ms) => stone.animate(
          [{ transform: from, opacity: 1 }, { transform: to, opacity: 1 }],
          { duration: ms, easing: "cubic-bezier(.45,0,.2,1)", fill: "forwards" }).finished;
        let at = `translate(${dw}px, -40px)`;
        stone.classList.add("moving");
        stone.style.opacity = 1;
        for (const [i, slip] of slips.entries()) {
          const s = spot(slip);
          const up = `translate(${s.x}px, ${s.y - 22}px)`;
          const down = `translate(${s.x}px, ${s.y}px)`;
          await move(at, up, i === 0 ? 700 : 520);
          await move(up, down, 170);
          // Commit the shown state on the element itself, so the seal never
          // depends on a finished animation being kept alive.
          const imp = slip.querySelector(".imp");
          imp.style.opacity = "1";
          imp.animate(
            [{ opacity: 0, transform: "scale(1.08)" }, { opacity: 1, transform: "scale(1)" }],
            { duration: 260, easing: "ease-out" });
          await new Promise((r) => setTimeout(r, 120));
          await move(down, up, 260);
          at = up;
          if (slip.classList.contains("hidden-slip")) slip.classList.add("gone");
        }
        await stone.animate(
          [{ transform: at, opacity: 1 }, { transform: `translate(${dw * 0.9}px, -80px)`, opacity: 0 }],
          { duration: 700, easing: "ease-in", fill: "forwards" }).finished;
      };
      const io = new IntersectionObserver((entries) => {
        if (entries.some((e) => e.isIntersecting)) { io.disconnect(); run(); }
      }, { threshold: 0.55 });
      io.observe(desk);
    }
  }

  // The clients: Ask Key in the middle, a red line to each tool it sets up
  // itself, a dotted one to every other tool that speaks MCP. Wide screens
  // put the tools on both sides; narrow ones fan them out to the right.
  const hub = document.querySelector(".hub");
  if (hub) {
    const NS = "http://www.w3.org/2000/svg";
    const svg = hub.querySelector(".hub-lines");
    const autos = [...hub.querySelectorAll(".hub-names.is-auto li")];
    const mcps = [...hub.querySelectorAll(".hub-names.is-mcp li")];
    const line = (d, kind, delay) => {
      const p = document.createElementNS(NS, "path");
      p.setAttribute("d", d);
      p.setAttribute("class", kind);
      svg.appendChild(p);
      p.style.setProperty("--len", p.getTotalLength());
      p.style.setProperty("--d", `${delay}s`);
    };
    const place = (li, x, y, left, delay) => {
      li.style.left = `${x}px`;
      li.style.top = `${y}px`;
      li.classList.toggle("is-left", left);
      li.style.setProperty("--d", `${delay}s`);
    };
    const wide = () => {
      hub.style.height = "";
      const W = hub.clientWidth, H = hub.clientHeight, cx = W / 2, cy = H / 2, r = 56;
      const rows = [0.08, 0.24, 0.76, 0.92];
      autos.forEach((li, i) => {
        const s = i < 2 ? -1 : 1, x = cx + s * W * 0.17, y = H * (i % 2 ? 0.64 : 0.36);
        const ex = cx + s * r, ey = cy + (y / H - 0.5) * 24, mx = (x - s * 14 + ex) / 2;
        place(li, x, y, s < 0, i * 0.14);
        line(`M${x - s * 14},${y} C${mx},${y} ${mx},${ey} ${ex},${ey}`, "is-auto", i * 0.14);
      });
      mcps.forEach((li, i) => {
        // run level, then turn into the top of the icon or below its name
        const s = i < 4 ? -1 : 1, k = i % 4, x = cx + s * W * 0.3, y = H * rows[k];
        const ex = cx + s * (k === 0 || k === 3 ? 44 : 22), ey = k < 2 ? cy - r : cy + r + 58;
        place(li, x, y, s < 0, 0.6 + i * 0.08);
        line(`M${x - s * 14},${y} C${ex},${y} ${ex},${y} ${ex},${ey}`, "is-mcp", 0.6 + i * 0.08);
      });
    };
    const narrow = () => {
      const ix = 36, iy = 36, nx = 116, top = 236, step = 32;
      hub.style.height = `${top + mcps.length * step}px`;
      autos.forEach((li, i) => {
        const y = 18 + i * 48;
        place(li, nx, y, false, i * 0.14);
        line(`M${ix + 36},${iy} C${ix + 66},${iy} ${ix + 50},${y} ${nx - 12},${y}`, "is-auto", i * 0.14);
      });
      // the grey branches leave one shared trunk under the icon
      line(`M${ix},${iy + 66} L${ix},${top + (mcps.length - 1) * step - 26}`, "is-mcp", 0.6);
      mcps.forEach((li, i) => {
        const y = top + i * step;
        place(li, nx, y, false, 0.6 + i * 0.08);
        line(`M${ix},${y - 26} C${ix},${y} ${ix},${y} ${ix + 22},${y} L${nx - 12},${y}`, "is-mcp", 0.6 + i * 0.08);
      });
    };
    const layout = () => {
      svg.replaceChildren();
      hub.classList.add("is-laid");
      const thin = hub.clientWidth < 620;
      hub.classList.toggle("is-narrow", thin);
      svg.setAttribute("viewBox", `0 0 ${hub.clientWidth} ${hub.clientHeight}`);
      (thin ? narrow : wide)();
      svg.setAttribute("viewBox", `0 0 ${hub.clientWidth} ${hub.clientHeight}`);
    };
    if (!matchMedia("(prefers-reduced-motion: reduce)").matches) {
      hub.classList.add("is-pending");
      const io = new IntersectionObserver((entries) => {
        if (entries.some((e) => e.isIntersecting)) { io.disconnect(); hub.classList.remove("is-pending"); }
      }, { threshold: 0.35 });
      io.observe(hub);
    }
    // Manual setup is one copy away; the config only shows if copying fails.
    const copy = document.querySelector(".hub-copy"), conf = document.querySelector(".hub-config");
    if (copy && conf && navigator.clipboard) {
      const label = copy.textContent;
      copy.hidden = false;
      conf.hidden = true;
      copy.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(conf.textContent);
          copy.textContent = copy.dataset.done;
          setTimeout(() => (copy.textContent = label), 1800);
        } catch {
          copy.textContent = copy.dataset.fail;
          conf.hidden = false;
        }
      });
    }
    document.fonts.ready.then(layout);
    let w = innerWidth;
    addEventListener("resize", () => { if (innerWidth !== w) { w = innerWidth; layout(); } });
  }

  // The checksum command, one click to copy.
  const cmd = document.querySelector(".dl-copycmd");
  if (cmd && navigator.clipboard) {
    const label = cmd.textContent;
    cmd.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(cmd.dataset.copy); cmd.textContent = cmd.dataset.done; }
      catch { cmd.textContent = cmd.dataset.fail; }
      setTimeout(() => (cmd.textContent = label), 1800);
    });
  }

  // The access card hangs from its cord. It drops in and swings to rest,
  // turns toward the pointer like a real card in the hand, catches the light
  // as it turns, and swings when brushed. Only transforms change per frame,
  // and the loop sleeps whenever the card is off screen.
  const pass = document.querySelector(".pass");
  if (pass && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
    const swing = pass.querySelector(".pass-swing");
    const tilt = pass.querySelector(".pass-tilt");
    const shadow = pass.querySelector(".pass-shadow");
    const shine = pass.querySelector(".pass-shine");
    let theta = 0, omega = 0, drop = 0, dropV = 0;
    let rx = 0, ry = 0, trx = 0, try_ = 0;
    let px = null, pt = 0, shineAt = -1;
    let visible = false, raf = 0, last = 0, t = 0;

    const frame = (now) => {
      const dt = Math.min(0.034, (now - last) / 1000 || 0.016);
      last = now;
      t += dt;
      // a pendulum with a little air: gravity, damping and a faint draught
      const draught = 0.1 * Math.sin(t * 0.8) + 0.05 * Math.sin(t * 1.9);
      omega += (-14 * Math.sin(theta) - 1.1 * omega + draught) * dt;
      theta += omega * dt;
      // the drop: a spring that settles the card on its cord
      dropV += (-90 * drop - 13 * dropV) * dt;
      drop += dropV * dt;
      const k = Math.min(1, dt * 7);
      rx += (trx - rx) * k;
      ry += (try_ - ry) * k;
      swing.style.transform = `translateY(${drop.toFixed(2)}%) rotate(${theta.toFixed(4)}rad)`;
      tilt.style.transform = `rotateX(${rx.toFixed(2)}deg) rotateY(${ry.toFixed(2)}deg)`;
      shadow.style.transform = `translate(${(14 - ry * 0.9).toFixed(1)}px, ${(26 + rx * 0.7).toFixed(1)}px)`;
      // light: follows the turn, and now and then sweeps across on its own
      // f is where the highlight crosses the card, 0 at its left edge, 1 at its right
      let f = 0.15 + ry * 0.04;
      if (shineAt < 0 && t > 1.2 && (t % 7) < dt) shineAt = t;
      if (shineAt >= 0) {
        const p = (t - shineAt) / 1.3;
        if (p >= 1) shineAt = -1;
        else f = -0.4 + 1.8 * (p * p * (3 - 2 * p));
      }
      shine.style.backgroundPosition = `${((1.5 - f) * 50).toFixed(2)}% 0`;
      raf = visible ? requestAnimationFrame(frame) : 0;
    };
    const wake = () => { if (!raf && visible) { last = performance.now(); raf = requestAnimationFrame(frame); } };

    // Wait above the cord's rest until the card first comes into view.
    drop = -16;
    theta = 0.34;
    swing.style.transform = `translateY(${drop}%) rotate(${theta}rad)`;
    new IntersectionObserver((entries) => {
      visible = entries.some((e) => e.isIntersecting);
      wake();
    }, { threshold: 0.2 }).observe(pass);

    pass.addEventListener("pointermove", (e) => {
      const r = tilt.getBoundingClientRect();
      const nx = (e.clientX - (r.left + r.width / 2)) / (r.width * 0.9);
      const ny = (e.clientY - (r.top + r.height / 2)) / (r.height * 0.9);
      try_ = Math.max(-1, Math.min(1, nx)) * 18;
      trx = Math.max(-1, Math.min(1, -ny)) * 12;
      // brushing past the card sets it swinging
      if (px !== null && e.pointerType === "mouse") {
        const v = (e.clientX - px) / Math.max(1, e.timeStamp - pt);
        omega += Math.max(-0.5, Math.min(0.5, v * 0.04));
      }
      px = e.clientX;
      pt = e.timeStamp;
    });
    pass.addEventListener("pointerleave", () => { trx = 0; try_ = 0; px = null; });
    pass.addEventListener("pointerdown", (e) => {
      const r = pass.getBoundingClientRect();
      omega += (e.clientX < r.left + r.width / 2 ? 1 : -1) * 0.9;
    });
  }
})();

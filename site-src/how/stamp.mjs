// Stamp each script and stylesheet URL in the site's pages with a hash of
// its content, so a browser never pairs new pages with an old cached file.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const site = new URL("../../site/", import.meta.url);
const files = ["style.css", "motion.js", "how/how.css", "how/how.js"];
const hash = Object.fromEntries(files.map((f) => [f, createHash("sha256").update(readFileSync(new URL(f, site))).digest("hex").slice(0, 10)]));
for (const page of ["index.html", "zh/index.html", "404.html"]) {
  const url = new URL(page, site);
  let html = readFileSync(url, "utf8");
  for (const f of files) {
    const re = new RegExp(`(["'])/${f.replace(/[./]/g, "\\$&")}(?:\\?v=[0-9a-f]+)?\\1`, "g");
    html = html.replace(re, (_, q) => `${q}/${f}?v=${hash[f]}${q}`);
  }
  writeFileSync(url, html);
}
console.log(hash);

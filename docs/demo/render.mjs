#!/usr/bin/env node
// Renders docs/demo/scene.html frame by frame with headless Chrome (DevTools
// protocol over Node's built-in WebSocket, no npm packages), then encodes the
// MP4, the GIF and the poster with ffmpeg.
//
//   node docs/demo/render.mjs                 # frames + all outputs
//   node docs/demo/render.mjs --stills 0.3,2.4,4.9,5.9   # only a few PNGs
//
// Options: --frames DIR (default: $TMPDIR/hark-demo-frames), --fps 60 (capture rate; the MP4 is 30),
//          --chrome PATH, --ffmpeg PATH, --gif-fps 20, --gif-width 960,
//          --poster-t 3.65
import { spawn, execFileSync } from "node:child_process";
import { mkdirSync, rmSync, writeFileSync, existsSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { tmpdir } from "node:os";

const here = dirname(fileURLToPath(import.meta.url));
const docs = resolve(here, "..");
const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : true]);
  return acc;
}, []));
const CHROME = args.chrome || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const FFMPEG = args.ffmpeg || "/opt/homebrew/bin/ffmpeg";
const FPS = Number(args.fps || 60);
const GIF_FPS = Number(args["gif-fps"] || 20);
const GIF_W = Number(args["gif-width"] || 960);
const POSTER_T = Number(args["poster-t"] || 3.65);
const FRAMES = resolve(args.frames || join(tmpdir(), "hark-demo-frames"));
const PORT = 9300 + Math.floor(Math.random() * 500);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function launch() {
  const profile = join(tmpdir(), `hark-demo-chrome-${PORT}`);
  const proc = spawn(CHROME, [
    "--headless=new", `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`,
    "--hide-scrollbars", "--force-color-profile=srgb", "--font-render-hinting=none",
    "--no-first-run", "--no-default-browser-check", "--window-size=960,504", "about:blank",
  ], { stdio: "ignore" });
  for (let i = 0; i < 100; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
      const page = list.find((t) => t.type === "page");
      if (page) return { proc, ws: page.webSocketDebuggerUrl, profile };
    } catch {}
    await sleep(100);
  }
  proc.kill();
  throw new Error("Chrome did not start");
}

function cdp(url) {
  const ws = new WebSocket(url);
  let id = 0;
  const pending = new Map();
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { ok, fail } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? fail(new Error(JSON.stringify(msg.error))) : ok(msg.result);
    }
  };
  const ready = new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  const send = (method, params = {}) => new Promise((ok, fail) => {
    const n = ++id;
    pending.set(n, { ok, fail });
    ws.send(JSON.stringify({ id: n, method, params }));
  });
  return { ready, send, close: () => ws.close() };
}

async function main() {
  const { proc, ws, profile } = await launch();
  const c = cdp(ws);
  await c.ready;
  try {
    await c.send("Emulation.setDeviceMetricsOverride", { width: 960, height: 504, deviceScaleFactor: 2, mobile: false });
    await c.send("Page.enable");
    await c.send("Page.navigate", { url: pathToFileURL(join(here, "scene.html")).href + "?still" });
    for (let i = 0; i < 100; i++) {
      const r = await c.send("Runtime.evaluate", { expression: "window.sceneReady === true", returnByValue: true });
      if (r.result.value) break;
      await sleep(100);
    }
    const loop = (await c.send("Runtime.evaluate", { expression: "window.LOOP", returnByValue: true })).result.value;

    const shoot = async (t, file) => {
      await c.send("Runtime.evaluate", { expression: `window.seek(${t})`, awaitPromise: false });
      const { data } = await c.send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false, optimizeForSpeed: false });
      writeFileSync(file, Buffer.from(data, "base64"));
    };

    if (args.stills) {
      const out = resolve(args.out || FRAMES);
      mkdirSync(out, { recursive: true });
      for (const t of String(args.stills).split(",").map(Number)) {
        const f = join(out, `still-${t.toFixed(2)}.png`);
        await shoot(t, f);
        console.log(f);
      }
      return;
    }

    rmSync(FRAMES, { recursive: true, force: true });
    mkdirSync(FRAMES, { recursive: true });
    const n = Math.round(loop * FPS);
    for (let i = 0; i < n; i++) {
      await shoot(i / FPS, join(FRAMES, `f${String(i).padStart(4, "0")}.png`));
      if (i % 30 === 0) process.stdout.write(`frame ${i}/${n}\r`);
    }
    await shoot(POSTER_T, join(docs, "hark-demo-poster.png"));
    console.log(`\n${n} frames at ${FPS} fps in ${FRAMES}`);
  } finally {
    c.close();
    proc.kill();
    await sleep(300);
    rmSync(profile, { recursive: true, force: true });
  }

  const ff = (a) => execFileSync(FFMPEG, ["-hide_banner", "-loglevel", "error", "-y", ...a], { stdio: "inherit" });
  const input = ["-framerate", String(FPS), "-i", join(FRAMES, "f%04d.png")];

  ff([...input, "-c:v", "libx264", "-preset", "veryslow", "-crf", "18", "-tune", "animation",
      "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
      "-vf", "fps=30,scale=in_range=full:out_range=tv:out_color_matrix=bt709",
      "-movflags", "+faststart", "-an", join(docs, "hark-demo.mp4")]);

  // GIF: one palette from every frame, then error-diffusion dither; only changed rectangles are stored.
  const pal = join(FRAMES, "palette.png");
  const scale = `fps=${GIF_FPS},scale=${GIF_W}:-1:flags=lanczos`;
  ff([...input, "-vf", `${scale},palettegen=max_colors=256:stats_mode=full:reserve_transparent=0`, pal]);
  ff([...input, "-i", pal, "-lavfi", `${scale}[x];[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle`,
      "-loop", "0", join(docs, "hark-demo.gif")]);

  for (const f of ["hark-demo.mp4", "hark-demo.gif", "hark-demo-poster.png"]) {
    const p = join(docs, f);
    if (existsSync(p)) console.log(`${f}  ${(statSync(p).size / 1024 / 1024).toFixed(2)} MB`);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });

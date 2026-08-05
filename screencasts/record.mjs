import fs from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { chromium } from "playwright";
import { VIEWPORT, OUT_DIR, WORK_DIR, MANIFEST, LESSON_DIR } from "./config.mjs";
import { createDirector } from "./director.mjs";
import { doctor } from "./doctor.mjs";

const run = promisify(execFile);

async function loadManifest() {
  return JSON.parse(await fs.readFile(MANIFEST, "utf8"));
}

async function loadLesson(entry) {
  const file = path.join(LESSON_DIR, `${entry.id}-${entry.slug}.mjs`);
  return { entry, mod: await import(file) };
}

async function transcode(webm, mp4) {
  await run("ffmpeg", [
    "-y", "-i", webm,
    "-c:v", "libx264", "-crf", "23", "-preset", "slow",
    "-pix_fmt", "yuv420p", "-movflags", "+faststart",
    mp4,
  ]);
}

async function recordOne({ entry, mod }, { dry }) {
  const label = `${entry.id} ${entry.title}`;
  process.stdout.write(`▶ ${label}${dry ? " (dry)" : ""}\n`);

  await fs.mkdir(WORK_DIR, { recursive: true });
  const browser = await chromium.launch();
  const ctx = await browser.newContext({
    viewport: VIEWPORT,
    ...(dry ? {} : { recordVideo: { dir: WORK_DIR, size: VIEWPORT } }),
  });
  const page = await ctx.newPage();
  const d = createDirector(page, { dry });

  try {
    await mod.run(d);
  } finally {
    await ctx.close();
    await browser.close();
  }

  if (dry) return null;

  const video = await page.video();
  const webm = await video.path();
  await fs.mkdir(OUT_DIR, { recursive: true });
  const mp4 = path.join(OUT_DIR, `${entry.id}-${entry.slug}.mp4`);
  await transcode(webm, mp4);
  await fs.rm(webm, { force: true });
  process.stdout.write(`  → ${mp4}\n`);
  return mp4;
}

const args = process.argv.slice(2);
const dry = args.includes("--dry");
const all = args.includes("--all");
const target = args.find((a) => !a.startsWith("--"));

if (args.includes("--doctor")) {
  const problems = await doctor();
  if (problems.length) {
    for (const p of problems) console.error(`✗ ${p}`);
    process.exit(1);
  }
  console.log("✓ all checks passed");
  process.exit(0);
}

const manifest = await loadManifest();
const entries = all
  ? manifest.lessons
  : manifest.lessons.filter((l) => l.id === target);

if (!entries.length) {
  console.error(`No lesson matched "${target}". Known ids: ${manifest.lessons.map((l) => l.id).join(", ")}`);
  process.exit(1);
}

let failed = 0;
for (const entry of entries) {
  try {
    await recordOne(await loadLesson(entry), { dry });
  } catch (e) {
    failed++;
    console.error(`✗ lesson ${entry.id} failed: ${e.message}`);
  }
}
process.exit(failed ? 1 : 0);

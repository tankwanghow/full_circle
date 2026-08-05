import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { BASE_URL, credentials } from "./config.mjs";

const run = promisify(execFile);

export async function doctor() {
  const problems = [];

  try {
    await run("ffmpeg", ["-version"]);
  } catch {
    problems.push("ffmpeg not found on PATH. Install it before recording.");
  }

  try {
    const { chromium } = await import("playwright");
    const browser = await chromium.launch();
    await browser.close();
  } catch (e) {
    problems.push(`Playwright Chromium failed to launch: ${e.message}. Run: npx playwright install chromium`);
  }

  try {
    credentials();
  } catch (e) {
    problems.push(e.message);
  }

  try {
    const res = await fetch(`${BASE_URL}/users/log_in`, { redirect: "manual" });
    if (res.status >= 500) problems.push(`${BASE_URL} returned ${res.status}.`);
  } catch {
    problems.push(`Cannot reach ${BASE_URL}. Start the dev server with: mix phx.server`);
  }

  return problems;
}

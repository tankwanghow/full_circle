import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..");

export const BASE_URL = process.env.SCREENCAST_BASE_URL ?? "http://localhost:4000";
export const VIEWPORT = { width: 1280, height: 720 };
export const OUT_DIR = path.join(repoRoot, "docs", "screencasts");
export const WORK_DIR = path.join(here, ".work");
export const CREATED_LOG = path.join(here, ".created.log");
export const LESSON_DIR = path.join(here, "lessons");
export const MANIFEST = path.join(here, "manifest.json");

export function credentials() {
  const email = process.env.SCREENCAST_EMAIL;
  const password = process.env.SCREENCAST_PASSWORD;
  if (!email) throw new Error("SCREENCAST_EMAIL is not set. Export it before recording.");
  if (!password) throw new Error("SCREENCAST_PASSWORD is not set. Export it before recording.");
  return { email, password };
}

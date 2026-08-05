import { test } from "node:test";
import assert from "node:assert/strict";
import { BASE_URL, VIEWPORT, credentials } from "../config.mjs";

test("viewport is exactly 1280x720", () => {
  assert.deepEqual(VIEWPORT, { width: 1280, height: 720 });
});

test("base url defaults to the dev server", () => {
  assert.equal(BASE_URL, process.env.SCREENCAST_BASE_URL ?? "http://localhost:4000");
});

test("credentials throw a useful error when env is unset", () => {
  const saved = process.env.SCREENCAST_EMAIL;
  delete process.env.SCREENCAST_EMAIL;
  assert.throws(() => credentials(), /SCREENCAST_EMAIL/);
  if (saved !== undefined) process.env.SCREENCAST_EMAIL = saved;
});

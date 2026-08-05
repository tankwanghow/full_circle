import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { chromium } from "playwright";
import { createDirector } from "../director.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = pathToFileURL(path.join(here, "fixtures", "tribute-page.html")).href;

let browser, page, d;
before(async () => {
  browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  page = await ctx.newPage();
  d = createDirector(page, { dry: true });
});
after(async () => { await browser.close(); });
beforeEach(async () => { await d.goto(FIXTURE); });

test("pickAutocomplete opens the menu and selects the matching item", async () => {
  await d.pickAutocomplete("#ac", "Ah Seng Trading");
  assert.equal(await page.locator("#ac").inputValue(), "Ah Seng Trading");
});

test("pickAutocomplete prefers an exact-text match over the first item", async () => {
  await d.pickAutocomplete("#ac", "Ah Seng Holdings");
  assert.equal(await page.locator("#ac").inputValue(), "Ah Seng Holdings");
});

test("fill would NOT open the menu — proves pressSequentially is required", async () => {
  await page.locator("#ac").fill("Ah Seng");
  assert.equal(await page.locator(".tribute-container li").count(), 0);
});

test("click waits for the phx loading class to clear", async () => {
  await d.click("#go");
  assert.equal(await page.locator("#out").innerText(), "done");
});

test("click moves the cursor onto the target", async () => {
  const box = await page.locator("#go").boundingBox();
  await d.click("#go");
  const t = await page.locator("#sc-cursor").evaluate((el) => el.style.transform);
  const x = Number(t.match(/translate\(([\d.]+)px/)[1]);
  assert.ok(Math.abs(x - (box.x + box.width / 2)) < 2, `cursor at ${x}, expected ~${box.x + box.width / 2}`);
});

test("highlight positions the ring over the element", async () => {
  const box = await page.locator("#go").boundingBox();
  await d.highlight("#go");
  const left = await page.locator("#sc-ring").evaluate((el) => parseFloat(el.style.left));
  assert.ok(Math.abs(left - (box.x - 4)) < 2);
});

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { readTime, installOverlay } from "../overlay.mjs";

test("readTime floors at 2000ms for short captions", () => {
  assert.equal(readTime("Save"), 2000);
});

test("readTime scales with word count", () => {
  assert.equal(readTime("one two three four five six seven eight nine ten"), 4800);
});

test("readTime ignores surrounding whitespace", () => {
  assert.equal(readTime("   Save   "), 2000);
});

let browser, page;
before(async () => {
  browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  page = await ctx.newPage();
  await installOverlay(page);
  // addInitScript runs on navigation; setContent does not re-run it and would wipe the DOM.
  await page.goto("data:text/html,<html><body><p>hello</p></body></html>");
  await page.waitForFunction(() => !!document.getElementById("sc-cursor"));
});
after(async () => { await browser.close(); });

test("overlay elements are injected", async () => {
  assert.equal(await page.locator("#sc-cursor").count(), 1);
  assert.equal(await page.locator("#sc-caption").count(), 1);
});

test("say renders the caption text and makes it visible", async () => {
  await page.evaluate(() => window.__sc.say("Pick the customer"));
  await assert.doesNotReject(page.locator("#sc-caption.on").waitFor({ timeout: 2000 }));
  assert.equal(await page.locator("#sc-caption").innerText(), "Pick the customer");
});

test("cursorTo resolves and moves the cursor", async () => {
  await page.evaluate(() => window.__sc.cursorTo(400, 300, 50));
  const t = await page.locator("#sc-cursor").evaluate((el) => el.style.transform);
  assert.match(t, /translate\(400/);
});

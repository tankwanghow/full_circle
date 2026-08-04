# Tutorial Screencast Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Playwright-driven pipeline that records narrated-by-caption screencasts of the real Full Circle app, and ship lesson 1, "Key a sales invoice".

**Architecture:** A `screencasts/` Node project, outside `assets/` so esbuild never touches it. A shared `director.mjs` injects a fake cursor, caption bar, and highlight ring into every page via `page.addInitScript()`, so Playwright's built-in video recorder captures them natively. Each lesson is a small declarative ES module. ffmpeg transcodes the recorded webm to mp4. A manifest drives a generated, self-contained HTML index.

**Tech Stack:** Node 22 (mise), Playwright (Chromium), `node:test` for unit tests, ffmpeg (already at `/usr/bin/ffmpeg`), Phoenix LiveView app under test.

**Spec:** `docs/superpowers/specs/2026-08-04-tutorial-screencasts-design.md`

## Global Constraints

- **Never commit `.mp4` files or `.created.log`.** Videos are reproducible from scripts; committing them bloats the repo permanently.
- **Recordings contain real production-derived data** (dev DB is restored from prod backups). Internal distribution only — no YouTube, no public host.
- Viewport and video size are both exactly **1280×720**.
- Credentials come only from `SCREENCAST_EMAIL` / `SCREENCAST_PASSWORD` env vars. Never hardcode, never commit.
- Base URL defaults to `http://localhost:4000` (dev server HTTP port), overridable via `SCREENCAST_BASE_URL`.
- All new JS is ESM (`.mjs`), Node 22, no TypeScript, no bundler.
- Captions are English only, plain strings inside lesson files.
- Do not modify any file under `lib/` — the pipeline observes the app, it does not change it.

## Verified selectors

These were read off the real code. Do not substitute guesses.

| Purpose | Selector | Source |
|---|---|---|
| Login form | `#login_form` | `user_login_live.ex:19` |
| Email / password | `#user_email`, `#user_password` | `.input` sets `id = field.id`, `core_components.ex:322` |
| Login submit | `#login_form button[type="submit"]` | `user_login_live.ex:37` |
| Post-login URL | `/companies/<uuid>/dashboard` | `user_auth.ex:228` `signed_in_path/1` |
| Dashboard → invoices | `a[href$="/Invoice"]` | `dashboard_live.ex:80` |
| Index → new invoice | `a[href$="/Invoice/new"]` | `invoice_live/index.ex:62` |
| Invoice form | `#object-form` | `invoice_live/form.ex:875` |
| Customer (Tribute) | `#invoice_contact_name` | `form.ex:887` |
| Invoice date | `#invoice_invoice_date` | `form.ex:899` |
| Descriptions | `#invoice_descriptions` | `form.ex:911` |
| Line N good (Tribute) | `#invoice_invoice_details_<N>_good_name` | `detail_component.ex:59` |
| Line N quantity | `#invoice_invoice_details_<N>_quantity` | `detail_component.ex:83` |
| Line N unit price | `#invoice_invoice_details_<N>_unit_price` | `detail_component.ex:102` |
| Add detail line | `a[phx-click="add_detail"]` | `detail_component.ex:150` |
| Save | `#object-form button[type="submit"]` | `core_components.ex:956` |
| Invoice no (hidden) | `#invoice_invoice_no` | `form.ex:881` |
| Page title | `p.text-3xl` | `form.ex:841` |
| Flash | `div[role="alert"]` | `core_components.ex:152` |
| Tribute menu | `.tribute-container li` | Tribute `autocompleteMode: true`, `tri_autocomplete.js:79` |
| LiveView in flight | `.phx-change-loading, .phx-submit-loading, .phx-click-loading` | LiveView core |

**Critical gotcha:** `tri_autocomplete.js` builds Tribute with `autocompleteMode: true`, so it reacts to real key events. Playwright's `fill()` sets `.value` without dispatching keystrokes and the menu never opens. Autocomplete fields **must** use `pressSequentially()`.

---

### Task 1: Project scaffold and dependency doctor

**Files:**
- Create: `screencasts/package.json`
- Create: `screencasts/config.mjs`
- Create: `screencasts/doctor.mjs`
- Create: `screencasts/test/config.test.mjs`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing
- Produces: `config.mjs` exporting `BASE_URL: string`, `VIEWPORT: {width: number, height: number}`, `OUT_DIR: string`, `WORK_DIR: string`, `CREATED_LOG: string`, `credentials(): {email: string, password: string}` (throws if env unset). `doctor.mjs` exporting `async function doctor(): Promise<string[]>` returning an array of problem strings, empty when healthy.

- [ ] **Step 1: Create the package manifest**

`screencasts/package.json`:

```json
{
  "name": "full-circle-screencasts",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --test test/",
    "record": "node record.mjs",
    "index": "node build-index.mjs"
  },
  "devDependencies": {
    "playwright": "^1.50.0"
  }
}
```

- [ ] **Step 2: Write the failing config test**

`screencasts/test/config.test.mjs`:

```js
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
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd screencasts && node --test test/config.test.mjs`
Expected: FAIL — `Cannot find module '../config.mjs'`

- [ ] **Step 4: Write config.mjs**

`screencasts/config.mjs`:

```js
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd screencasts && node --test test/config.test.mjs`
Expected: PASS, 3 tests

- [ ] **Step 6: Install Playwright and its Chromium**

Run:
```bash
cd screencasts && npm install && npx playwright install chromium
```
Expected: `node_modules/` created; Chromium downloaded to `~/.cache/ms-playwright/`.

- [ ] **Step 7: Write the doctor**

`screencasts/doctor.mjs`:

```js
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
```

- [ ] **Step 8: Run the doctor and confirm it reports honestly**

Run: `cd screencasts && node -e 'import("./doctor.mjs").then(m => m.doctor()).then(p => console.log(p.length ? p : "OK"))'`
Expected: with the dev server down and creds unset, it lists exactly those problems and does not falsely report OK. With `mix phx.server` running and both env vars exported, it prints `OK`.

- [ ] **Step 9: Add gitignore entries**

Append to the repository root `.gitignore`:

```gitignore
# Screencast pipeline — videos and scratch are reproducible, never commit
screencasts/node_modules/
screencasts/.work/
screencasts/.created.log
docs/screencasts/*.mp4
docs/screencasts/*.webm
```

- [ ] **Step 10: Verify the ignore rules actually work**

Run:
```bash
mkdir -p docs/screencasts && touch docs/screencasts/probe.mp4
git status --porcelain docs/screencasts/ screencasts/
rm docs/screencasts/probe.mp4
```
Expected: no line mentioning `probe.mp4` or `node_modules`.

- [ ] **Step 11: Commit**

```bash
git add screencasts/package.json screencasts/package-lock.json screencasts/config.mjs \
        screencasts/doctor.mjs screencasts/test/config.test.mjs .gitignore
git commit -m "feat(screencasts): scaffold pipeline config and dependency doctor"
```

---

### Task 2: Overlay layer — cursor, captions, highlight ring

**Files:**
- Create: `screencasts/overlay.mjs`
- Create: `screencasts/test/overlay.test.mjs`

**Interfaces:**
- Consumes: nothing
- Produces: `overlay.mjs` exporting `readTime(text: string): number` (pure) and `installOverlay(page): Promise<void>` which registers an init script. After installation every page exposes `window.__sc` with `say(text: string): void`, `cursorTo(x: number, y: number, ms: number): Promise<void>`, `ring(x, y, w, h): Promise<void>`, and `card(title: string, subtitle: string): void` / `clearCard(): void`.

- [ ] **Step 1: Write the failing tests**

`screencasts/test/overlay.test.mjs`:

```js
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
  await page.goto("about:blank");
  await page.setContent("<html><body><p>hello</p></body></html>");
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd screencasts && node --test test/overlay.test.mjs`
Expected: FAIL — `Cannot find module '../overlay.mjs'`

- [ ] **Step 3: Write overlay.mjs**

`screencasts/overlay.mjs`:

```js
export function readTime(text) {
  const words = text.trim().split(/\s+/).filter(Boolean).length;
  return Math.max(2000, 800 + 400 * words);
}

// Runs inside the page on every navigation. Must be self-contained — it cannot
// close over anything from this module.
function injected() {
  const CURSOR_SVG =
    "data:image/svg+xml;utf8," +
    encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">' +
        '<path d="M5 2l14 10-6.5.9L15 20l-2.6 1-2.6-7.1L5 18z" fill="%23111" stroke="%23fff" stroke-width="1.3"/>' +
        "</svg>"
    );

  const CSS = `
    #sc-cursor { position: fixed; left: 0; top: 0; width: 24px; height: 24px;
      z-index: 2147483647; pointer-events: none;
      background: no-repeat center/contain url("${CURSOR_SVG}");
      filter: drop-shadow(0 1px 2px rgba(0,0,0,.45)); }
    #sc-caption { position: fixed; left: 50%; bottom: 36px; transform: translateX(-50%);
      max-width: 78%; z-index: 2147483646; padding: 12px 22px; border-radius: 10px;
      background: rgba(15,15,15,.9); color: #fff; text-align: center;
      font: 500 22px/1.35 ui-sans-serif, system-ui, sans-serif;
      opacity: 0; transition: opacity .25s ease; pointer-events: none; }
    #sc-caption.on { opacity: 1; }
    #sc-ring { position: fixed; z-index: 2147483645; pointer-events: none;
      border: 3px solid #f59e0b; border-radius: 6px;
      opacity: 0; transition: opacity .3s ease; }
    #sc-ring.on { opacity: 1; }
    #sc-card { position: fixed; inset: 0; z-index: 2147483647; display: none;
      flex-direction: column; align-items: center; justify-content: center; gap: 14px;
      background: #0f172a; color: #fff; text-align: center;
      font-family: ui-sans-serif, system-ui, sans-serif; }
    #sc-card.on { display: flex; }
    #sc-card .t { font-size: 44px; font-weight: 700; }
    #sc-card .s { font-size: 22px; opacity: .8; }
  `;

  function install() {
    if (document.getElementById("sc-cursor")) return;

    const style = document.createElement("style");
    style.id = "sc-style";
    style.textContent = CSS;
    document.head.appendChild(style);

    const cursor = document.createElement("div");
    cursor.id = "sc-cursor";
    cursor.dataset.x = "640";
    cursor.dataset.y = "360";
    cursor.style.transform = "translate(640px, 360px)";

    const caption = document.createElement("div");
    caption.id = "sc-caption";

    const ring = document.createElement("div");
    ring.id = "sc-ring";

    const card = document.createElement("div");
    card.id = "sc-card";
    card.innerHTML = '<div class="t"></div><div class="s"></div>';

    document.body.append(cursor, caption, ring, card);
  }

  window.__sc = {
    say(text) {
      const el = document.getElementById("sc-caption");
      if (!el) return;
      el.textContent = text;
      el.classList.add("on");
    },
    hide() {
      document.getElementById("sc-caption")?.classList.remove("on");
    },
    cursorTo(x, y, ms) {
      return new Promise((resolve) => {
        const el = document.getElementById("sc-cursor");
        if (!el) return resolve();
        const sx = parseFloat(el.dataset.x || "0");
        const sy = parseFloat(el.dataset.y || "0");
        const t0 = performance.now();
        const step = (t) => {
          const p = Math.min(1, (t - t0) / ms);
          const e = p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
          const cx = sx + (x - sx) * e;
          const cy = sy + (y - sy) * e;
          el.style.transform = `translate(${cx}px, ${cy}px)`;
          el.dataset.x = String(cx);
          el.dataset.y = String(cy);
          if (p < 1) requestAnimationFrame(step);
          else resolve();
        };
        requestAnimationFrame(step);
      });
    },
    ring(x, y, w, h) {
      const el = document.getElementById("sc-ring");
      if (!el) return;
      el.style.left = `${x - 4}px`;
      el.style.top = `${y - 4}px`;
      el.style.width = `${w + 8}px`;
      el.style.height = `${h + 8}px`;
      el.classList.add("on");
    },
    clearRing() {
      document.getElementById("sc-ring")?.classList.remove("on");
    },
    card(title, subtitle) {
      const el = document.getElementById("sc-card");
      if (!el) return;
      el.querySelector(".t").textContent = title;
      el.querySelector(".s").textContent = subtitle ?? "";
      el.classList.add("on");
    },
    clearCard() {
      document.getElementById("sc-card")?.classList.remove("on");
    },
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", install);
  } else {
    install();
  }
}

export async function installOverlay(page) {
  await page.addInitScript(injected);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd screencasts && node --test test/overlay.test.mjs`
Expected: PASS, 6 tests

- [ ] **Step 5: Commit**

```bash
git add screencasts/overlay.mjs screencasts/test/overlay.test.mjs
git commit -m "feat(screencasts): page overlay for cursor, captions and highlights"
```

---

### Task 3: Director interaction layer

**Files:**
- Create: `screencasts/director.mjs`
- Create: `screencasts/test/fixtures/tribute-page.html`
- Create: `screencasts/test/director.test.mjs`

**Interfaces:**
- Consumes: `overlay.mjs` — `readTime`, `installOverlay`
- Produces: `director.mjs` exporting `createDirector(page, { dry = false } = {}): Director`. The `Director` object has `say(text)`, `pause(ms)`, `title(t, s)`, `click(sel)`, `type(sel, text)`, `fill(sel, value)`, `pickAutocomplete(sel, text)`, `highlight(sel)`, `settle()`, `goto(url)`, and the raw `page`. Every method returns a Promise. When `dry` is true, `say`, `pause`, `title`, and `highlight` do not hold — they still touch the DOM so selectors are exercised, but at zero delay.

**Note on the fixture:** it reproduces the *contract* the director depends on — an input that, on real key events, appends `.tribute-container > ul > li` items to the body, and a button that transiently adds `.phx-click-loading`. It is not Tribute itself. Testing against the real app happens in Tasks 4 and 7.

- [ ] **Step 1: Write the fixture page**

`screencasts/test/fixtures/tribute-page.html`:

```html
<!doctype html>
<html>
  <body>
    <input id="ac" autocomplete="off" />
    <button id="go">Go</button>
    <div id="out"></div>
    <script>
      const ITEMS = ["Ah Seng Trading", "Ah Seng Holdings", "Bee Huat Sdn Bhd"];
      const ac = document.getElementById("ac");

      // Mimics Tribute autocompleteMode: rebuilds the menu on real key input only.
      ac.addEventListener("input", () => {
        document.querySelector(".tribute-container")?.remove();
        const text = ac.value.trim().toLowerCase();
        if (!text) return;
        const hits = ITEMS.filter((i) => i.toLowerCase().includes(text));
        if (!hits.length) return;
        const box = document.createElement("div");
        box.className = "tribute-container";
        const ul = document.createElement("ul");
        for (const h of hits) {
          const li = document.createElement("li");
          li.textContent = h;
          li.addEventListener("click", () => {
            ac.value = h;
            box.remove();
          });
          ul.appendChild(li);
        }
        box.appendChild(ul);
        document.body.appendChild(box);
      });

      document.getElementById("go").addEventListener("click", (e) => {
        e.target.classList.add("phx-click-loading");
        setTimeout(() => {
          e.target.classList.remove("phx-click-loading");
          document.getElementById("out").textContent = "done";
        }, 300);
      });
    </script>
  </body>
</html>
```

- [ ] **Step 2: Write the failing tests**

`screencasts/test/director.test.mjs`:

```js
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd screencasts && node --test test/director.test.mjs`
Expected: FAIL — `Cannot find module '../director.mjs'`

- [ ] **Step 4: Write director.mjs**

`screencasts/director.mjs`:

```js
import { readTime, installOverlay } from "./overlay.mjs";

const SETTLE_SELECTOR = ".phx-change-loading, .phx-submit-loading, .phx-click-loading";

export function createDirector(page, { dry = false } = {}) {
  const installed = installOverlay(page);
  const hold = (ms) => (dry ? Promise.resolve() : page.waitForTimeout(ms));

  async function settle() {
    await page.waitForFunction(
      (sel) => !document.querySelector(sel),
      SETTLE_SELECTOR,
      { timeout: 15000 }
    );
  }

  async function centreOf(sel) {
    const loc = page.locator(sel).first();
    await loc.waitFor({ state: "visible", timeout: 15000 });
    await loc.scrollIntoViewIfNeeded();
    const box = await loc.boundingBox();
    if (!box) throw new Error(`No bounding box for ${sel} — is it visible?`);
    return { loc, box };
  }

  const d = {
    page,

    async goto(url) {
      await installed;
      await page.goto(url, { waitUntil: "domcontentloaded" });
      await settle();
    },

    async say(text) {
      await page.evaluate((t) => window.__sc.say(t), text);
      await hold(readTime(text));
    },

    async pause(ms) {
      await hold(ms);
    },

    async title(t, s = "") {
      await page.evaluate(([a, b]) => window.__sc.card(a, b), [t, s]);
      await hold(2500);
      await page.evaluate(() => window.__sc.clearCard());
    },

    async click(sel) {
      const { loc, box } = await centreOf(sel);
      await page.evaluate(
        ([x, y]) => window.__sc.cursorTo(x, y, 420),
        [box.x + box.width / 2, box.y + box.height / 2]
      );
      await loc.click();
      await settle();
    },

    // Real keystrokes. Required for anything with the tributeAutoComplete hook.
    async type(sel, text, { delay = 90 } = {}) {
      const { loc } = await centreOf(sel);
      await d.click(sel);
      await loc.pressSequentially(text, { delay: dry ? 0 : delay });
      await settle();
    },

    // Value-set + change event. Fine for date/number inputs, NEVER for Tribute fields.
    async fill(sel, value) {
      const { loc } = await centreOf(sel);
      await d.click(sel);
      await loc.fill(value);
      await settle();
    },

    async pickAutocomplete(sel, text) {
      const { loc } = await centreOf(sel);
      await d.click(sel);
      await loc.fill("");
      await loc.pressSequentially(text, { delay: dry ? 0 : 90 });

      const menu = page.locator(".tribute-container li");
      await menu.first().waitFor({ state: "visible", timeout: 10000 });

      const exact = page.locator(".tribute-container li", { hasText: text });
      const target = (await exact.count()) > 0 ? exact.first() : menu.first();

      const box = await target.boundingBox();
      if (box) {
        await page.evaluate(
          ([x, y]) => window.__sc.cursorTo(x, y, 260),
          [box.x + box.width / 2, box.y + box.height / 2]
        );
      }
      await target.click();
      await settle();
    },

    async highlight(sel) {
      const { box } = await centreOf(sel);
      await page.evaluate(
        ([x, y, w, h]) => window.__sc.ring(x, y, w, h),
        [box.x, box.y, box.width, box.height]
      );
      await hold(1200);
      await page.evaluate(() => window.__sc.clearRing());
    },

    settle,
  };

  return d;
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd screencasts && node --test test/director.test.mjs`
Expected: PASS, 6 tests. In particular the `fill would NOT open the menu` test must pass — it is the regression guard for the Tribute gotcha.

- [ ] **Step 6: Commit**

```bash
git add screencasts/director.mjs screencasts/test/director.test.mjs screencasts/test/fixtures/tribute-page.html
git commit -m "feat(screencasts): director interaction layer with Tribute-safe autocomplete"
```

---

### Task 4: App helpers — login and navigation against the real dev server

**Files:**
- Create: `screencasts/app.mjs`

**Interfaces:**
- Consumes: `config.mjs` — `BASE_URL`, `credentials`; the `Director` from Task 3
- Produces: `app.mjs` exporting `async function login(d): Promise<string>` returning the company UUID, and `async function recordCreated(lessonId, companyId, docId, docNo): Promise<void>` appending a TSV line to `CREATED_LOG`.

This task requires a running dev server. Start it in another terminal with `mix phx.server` and export `SCREENCAST_EMAIL` / `SCREENCAST_PASSWORD` before the verification steps.

- [ ] **Step 1: Write app.mjs**

`screencasts/app.mjs`:

```js
import fs from "node:fs/promises";
import { BASE_URL, CREATED_LOG, credentials } from "./config.mjs";

const COMPANY_URL = /\/companies\/([0-9a-fA-F-]{36})\/dashboard/;

export async function login(d) {
  const { email, password } = credentials();

  await d.goto(`${BASE_URL}/users/log_in`);
  await d.say("Start by signing in with your email and password.");
  await d.type("#user_email", email);
  await d.type("#user_password", password);
  await d.click('#login_form button[type="submit"]');

  await d.page.waitForURL(/\/companies(\/|$)/, { timeout: 20000 });

  const url = d.page.url();
  const match = url.match(COMPANY_URL);
  if (!match) {
    throw new Error(
      `Expected to land on a company dashboard but landed on ${url}. ` +
        `The screencast account needs a default company — set one in Companies before recording.`
    );
  }
  return match[1];
}

export async function recordCreated(lessonId, companyId, docId, docNo) {
  const line = [new Date().toISOString(), lessonId, companyId, docId, docNo].join("\t") + "\n";
  await fs.appendFile(CREATED_LOG, line, "utf8");
}
```

- [ ] **Step 2: Verify login works against the real app**

Run:
```bash
cd screencasts && node -e '
import("playwright").then(async ({ chromium }) => {
  const { createDirector } = await import("./director.mjs");
  const { login } = await import("./app.mjs");
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1280, height: 720 } });
  const d = createDirector(await ctx.newPage(), { dry: true });
  console.log("company:", await login(d));
  await b.close();
});'
```
Expected: prints `company: <uuid>`. If it throws the default-company error, fix the account in the app rather than the script — the message is accurate.

- [ ] **Step 3: Commit**

```bash
git add screencasts/app.mjs
git commit -m "feat(screencasts): login helper and created-document log"
```

---

### Task 5: Lesson 1 and the recorder

**Files:**
- Create: `screencasts/lessons/01-key-a-sales-invoice.mjs`
- Create: `screencasts/manifest.json`
- Create: `screencasts/record.mjs`

**Interfaces:**
- Consumes: `director.mjs` — `createDirector`; `app.mjs` — `login`, `recordCreated`; `doctor.mjs` — `doctor`
- Produces: each lesson module exports `export const id`, `export const title`, `export const description`, and `export async function run(d)`. `record.mjs` is a CLI: `node record.mjs <id>`, `node record.mjs --all`, plus flags `--dry` (no video, no ffmpeg) and `--doctor`.

- [ ] **Step 1: Write lesson 1**

`screencasts/lessons/01-key-a-sales-invoice.mjs`:

```js
import { BASE_URL } from "../config.mjs";
import { login, recordCreated } from "../app.mjs";

export const id = "01";
export const title = "Key a Sales Invoice";
export const description =
  "Sign in, open a new sales invoice, choose the customer, add two goods lines, and save it.";

// Change these to match data that exists in your dev database.
export const CUSTOMER = process.env.SCREENCAST_CUSTOMER ?? "Ah Seng";
export const GOOD_1 = process.env.SCREENCAST_GOOD_1 ?? "Egg";
export const GOOD_2 = process.env.SCREENCAST_GOOD_2 ?? "Feed";

export async function run(d) {
  await d.title("Lesson 1 — Key a Sales Invoice", "Full Circle · about 3 minutes");

  const companyId = await login(d);

  await d.say("This is your dashboard. Everything starts from here.");
  await d.click('a[href$="/Invoice"]');

  await d.say("This is the invoice list. Click New Invoice to start one.");
  await d.click('a[href$="/Invoice/new"]');

  await d.say("First, set the invoice date.");
  await d.fill("#invoice_invoice_date", today());

  await d.say("Now type the customer's name. Wait for the list, then pick from it.");
  await d.pickAutocomplete("#invoice_contact_name", CUSTOMER);
  await d.say("Notice the registration number and tax id fill in by themselves.");
  await d.highlight("#invoice_reg_no");

  await d.say("Add the first line. Type the goods name and pick it from the list.");
  await d.pickAutocomplete("#invoice_invoice_details_0_good_name", GOOD_1);
  await d.say("Enter the quantity.");
  await d.fill("#invoice_invoice_details_0_quantity", "100");
  await d.say("And the unit price. The line total works itself out.");
  await d.fill("#invoice_invoice_details_0_unit_price", "3.50");
  await d.highlight(".detail-amt-col");

  await d.say("Click Add Detail for a second line.");
  await d.click('a[phx-click="add_detail"]');
  await d.pickAutocomplete("#invoice_invoice_details_1_good_name", GOOD_2);
  await d.fill("#invoice_invoice_details_1_quantity", "20");
  await d.fill("#invoice_invoice_details_1_unit_price", "12.00");

  await d.say("Everything looks right. Save the invoice.");
  await d.click('#object-form button[type="submit"]');

  await d.page.waitForURL(/\/Invoice\/[0-9a-fA-F-]{36}\/edit/, { timeout: 20000 });
  await d.settle();

  await d.say("Saved. The system gives the invoice its own number.");
  await d.highlight("p.text-3xl");

  const docId = d.page.url().match(/\/Invoice\/([0-9a-fA-F-]{36})\/edit/)[1];
  const docNo = await d.page.locator("#invoice_invoice_no").inputValue();
  await recordCreated(id, companyId, docId, docNo);

  await d.say("You can open the print view any time from this screen.");
  await d.goto(`${BASE_URL}/companies/${companyId}/Invoice/${docId}/print?pre_print=false`);
  await d.pause(3000);

  await d.title("End of Lesson 1", "Next: recording a receipt");
}

function today() {
  const n = new Date();
  const p = (v) => String(v).padStart(2, "0");
  return `${n.getFullYear()}-${p(n.getMonth() + 1)}-${p(n.getDate())}`;
}
```

- [ ] **Step 2: Write the manifest**

`screencasts/manifest.json`:

```json
{
  "series": "Full Circle — Daily Tasks",
  "lessons": [
    {
      "id": "01",
      "slug": "key-a-sales-invoice",
      "title": "Key a Sales Invoice",
      "description": "Sign in, open a new sales invoice, choose the customer, add two goods lines, and save it."
    }
  ]
}
```

- [ ] **Step 3: Write the recorder**

`screencasts/record.mjs`:

```js
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
```

- [ ] **Step 4: Dry-run lesson 1 to verify every selector resolves**

Run: `cd screencasts && node record.mjs 01 --dry`
Expected: `▶ 01 Key a Sales Invoice (dry)` and exit code 0.

If a `pickAutocomplete` times out, the search text does not match anything in the dev database. Set `SCREENCAST_CUSTOMER`, `SCREENCAST_GOOD_1`, or `SCREENCAST_GOOD_2` to values that exist. Do **not** weaken the selector.

Note: a dry run still saves a real invoice and still appends to `.created.log`.

- [ ] **Step 5: Record for real**

Run: `cd screencasts && node record.mjs 01`
Expected: prints the mp4 path; `docs/screencasts/01-key-a-sales-invoice.mp4` exists.

- [ ] **Step 6: Verify the video is sane**

Run:
```bash
ffprobe -v error -show_entries format=duration:stream=width,height,codec_name \
  -of default=nw=1 docs/screencasts/01-key-a-sales-invoice.mp4
```
Expected: `codec_name=h264`, `width=1280`, `height=720`, duration between 120 and 300 seconds.

- [ ] **Step 7: Extract frames and look at them**

Run:
```bash
mkdir -p /tmp/sc-frames && ffmpeg -y -i docs/screencasts/01-key-a-sales-invoice.mp4 \
  -vf fps=1/15 /tmp/sc-frames/f%03d.png && ls /tmp/sc-frames
```
Then **read the PNG files** and confirm: the caption bar is fully on screen and not clipped, the cursor is visible and lands on the element being discussed, the highlight ring frames the right field, and the form text is legible at 720p. Fix and re-record if any of these fail. Do not proceed on the basis of the file merely existing.

- [ ] **Step 8: Commit**

```bash
git add screencasts/lessons/01-key-a-sales-invoice.mjs screencasts/manifest.json screencasts/record.mjs
git commit -m "feat(screencasts): lesson 1 sales invoice and the recorder CLI"
```

---

### Task 6: Index page generator

**Files:**
- Create: `screencasts/build-index.mjs`
- Create: `screencasts/test/build-index.test.mjs`

**Interfaces:**
- Consumes: `config.mjs` — `OUT_DIR`, `MANIFEST`
- Produces: `build-index.mjs` exporting the pure function `renderIndex(manifest: {series: string, lessons: Array<{id, slug, title, description}>}): string`, and running as a CLI writes `docs/screencasts/index.html`.

- [ ] **Step 1: Write the failing tests**

`screencasts/test/build-index.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { renderIndex } from "../build-index.mjs";

const manifest = {
  series: "Full Circle — Daily Tasks",
  lessons: [
    { id: "01", slug: "key-a-sales-invoice", title: "Key a Sales Invoice", description: "Add two lines & save." },
    { id: "02", slug: "record-a-receipt", title: "Record a Receipt", description: "Match against invoices." },
  ],
};

test("renders one video element per lesson with a relative source", () => {
  const html = renderIndex(manifest);
  assert.match(html, /src="01-key-a-sales-invoice\.mp4"/);
  assert.match(html, /src="02-record-a-receipt\.mp4"/);
  assert.equal((html.match(/<video/g) ?? []).length, 2);
});

test("includes the series name, titles and descriptions", () => {
  const html = renderIndex(manifest);
  assert.match(html, /Full Circle — Daily Tasks/);
  assert.match(html, /Key a Sales Invoice/);
  assert.match(html, /Match against invoices\./);
});

test("is self-contained — no external asset references", () => {
  const html = renderIndex(manifest);
  assert.doesNotMatch(html, /https?:\/\//);
});

test("supports light and dark themes", () => {
  const html = renderIndex(manifest);
  assert.match(html, /prefers-color-scheme:\s*dark/);
});

test("escapes HTML in lesson text", () => {
  const html = renderIndex({ series: "S", lessons: [{ id: "9", slug: "x", title: "A & B", description: "<script>bad</script>" }] });
  assert.match(html, /A &amp; B/);
  assert.doesNotMatch(html, /<script>bad/);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd screencasts && node --test test/build-index.test.mjs`
Expected: FAIL — `Cannot find module '../build-index.mjs'`

- [ ] **Step 3: Write build-index.mjs**

`screencasts/build-index.mjs`:

```js
import fs from "node:fs/promises";
import path from "node:path";
import { OUT_DIR, MANIFEST } from "./config.mjs";

const esc = (s) =>
  String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");

export function renderIndex(manifest) {
  const cards = manifest.lessons
    .map(
      (l) => `
      <article class="lesson">
        <h2><span class="num">${esc(l.id)}</span> ${esc(l.title)}</h2>
        <p>${esc(l.description)}</p>
        <video controls preload="metadata" src="${esc(l.id)}-${esc(l.slug)}.mp4"></video>
      </article>`
    )
    .join("\n");

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${esc(manifest.series)}</title>
<style>
  :root { --bg:#f8fafc; --fg:#0f172a; --muted:#475569; --card:#fff; --line:#e2e8f0; --accent:#b45309; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#0f172a; --fg:#e2e8f0; --muted:#94a3b8; --card:#1e293b; --line:#334155; --accent:#fbbf24; }
  }
  * { box-sizing: border-box; }
  body { margin:0; padding:2.5rem 1.25rem; background:var(--bg); color:var(--fg);
         font:16px/1.6 ui-sans-serif, system-ui, sans-serif; }
  main { max-width: 60rem; margin: 0 auto; }
  h1 { font-size: 2rem; margin: 0 0 .35rem; }
  .sub { color: var(--muted); margin: 0 0 2.5rem; }
  .lesson { background:var(--card); border:1px solid var(--line); border-radius:12px;
            padding:1.25rem; margin-bottom:1.5rem; }
  .lesson h2 { font-size:1.2rem; margin:0 0 .35rem; display:flex; gap:.6rem; align-items:baseline; }
  .num { color:var(--accent); font-variant-numeric:tabular-nums; }
  .lesson p { color:var(--muted); margin:0 0 1rem; }
  video { width:100%; max-width:100%; border-radius:8px; background:#000; display:block; }
  footer { color:var(--muted); font-size:.85rem; margin-top:2.5rem; text-align:center; }
</style>
</head>
<body>
<main>
  <h1>${esc(manifest.series)}</h1>
  <p class="sub">Short lessons for everyday data entry. Internal use only.</p>
${cards}
  <footer>Generated from manifest.json — do not edit by hand.</footer>
</main>
</body>
</html>
`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const manifest = JSON.parse(await fs.readFile(MANIFEST, "utf8"));
  await fs.mkdir(OUT_DIR, { recursive: true });
  const out = path.join(OUT_DIR, "index.html");
  await fs.writeFile(out, renderIndex(manifest), "utf8");
  console.log(`→ ${out}`);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd screencasts && node --test test/build-index.test.mjs`
Expected: PASS, 5 tests

- [ ] **Step 5: Generate and inspect the index**

Run: `cd screencasts && node build-index.mjs`
Expected: `→ /home/tankwanghow/Projects/elixir/full_circle/docs/screencasts/index.html`

Open `file:///home/tankwanghow/Projects/elixir/full_circle/docs/screencasts/index.html` in a browser. Confirm the lesson 1 video plays, and check it in both light and dark system themes.

- [ ] **Step 6: Commit**

```bash
git add screencasts/build-index.mjs screencasts/test/build-index.test.mjs docs/screencasts/index.html
git commit -m "feat(screencasts): self-contained index page generator"
```

---

### Task 7: Drift smoke check and documentation

**Files:**
- Create: `screencasts/README.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything above
- Produces: no new code interfaces — this task delivers the maintenance workflow and its documentation.

- [ ] **Step 1: Verify the full unit suite passes**

Run: `cd screencasts && node --test test/`
Expected: PASS — 20 tests across `config`, `overlay`, `director`, and `build-index`.

- [ ] **Step 2: Verify the whole-series dry run works**

Run: `cd screencasts && node record.mjs --all --dry`
Expected: exit code 0, one `▶` line per lesson.

- [ ] **Step 3: Verify the dry run actually catches breakage**

Temporarily break a selector — in `lessons/01-key-a-sales-invoice.mjs` change `#invoice_contact_name` to `#invoice_contact_name_wrong` — then run `node record.mjs 01 --dry`.
Expected: exit code 1 and `✗ lesson 01 failed:` with a timeout message. **Revert the change.**

This step matters: it proves the smoke check has teeth. A green `--all --dry` that cannot fail is worthless.

- [ ] **Step 4: Write the README**

`screencasts/README.md`:

````markdown
# Screencasts

Generates the tutorial videos in `docs/screencasts/` by driving the real app with
Playwright. Design: `docs/superpowers/specs/2026-08-04-tutorial-screencasts-design.md`.

## Setup (once)

```bash
cd screencasts
npm install
npx playwright install chromium
```

## Recording

The dev server must be running (`mix phx.server`) and these must be exported:

```bash
export SCREENCAST_EMAIL=you@example.com
export SCREENCAST_PASSWORD=...
```

```bash
node record.mjs --doctor    # check deps, creds and server before anything else
node record.mjs 01          # record one lesson to docs/screencasts/
node record.mjs --all       # record everything
node record.mjs 01 --dry    # run the script without recording (fast selector check)
node build-index.mjs        # regenerate docs/screencasts/index.html
```

If a lesson cannot find a customer or a good, point it at data that exists in
your dev database:

```bash
export SCREENCAST_CUSTOMER="Ah Seng"
export SCREENCAST_GOOD_1="Egg"
```

## After changing UI

Run `node record.mjs --all --dry` after touching Billing LiveViews. It runs every
lesson script with no recording and fails loudly on any selector that no longer
resolves, so you learn immediately which lessons need re-recording.

## Adding a lesson

1. Add `lessons/NN-<slug>.mjs` exporting `id`, `title`, `description`, `run(d)`.
2. Add the matching entry to `manifest.json`.
3. `node record.mjs NN --dry`, then `node record.mjs NN`, then `node build-index.mjs`.

## Rules

- **Never commit mp4 files.** They are gitignored and reproducible from these scripts.
- **Recordings show production-derived data.** The dev database is restored from
  prod backups, so videos contain real customer and payroll names. Internal
  distribution only — never upload them anywhere public.
- Lessons that save a document consume a real gapless document number and append
  it to `.created.log` so you can clean up later.
- Autocomplete fields use Tribute in `autocompleteMode`, which only reacts to real
  key events. Always use `d.pickAutocomplete()`, never `fill()`.
````

- [ ] **Step 5: Document the pipeline in CLAUDE.md**

Add this to `CLAUDE.md` immediately after the "Ops scripts" section:

```markdown
### Tutorial screencasts

`screencasts/` generates the staff tutorial videos in `docs/screencasts/` by
driving the dev server with Playwright. See `screencasts/README.md`.

```bash
cd screencasts && node record.mjs --doctor   # verify deps, creds, server
cd screencasts && node record.mjs --all --dry # selector smoke check after UI changes
```

Run the dry check after changing Billing LiveViews — it fails on any selector a
lesson can no longer find. MP4s are gitignored; recordings contain
production-derived data and must stay internal.
```

- [ ] **Step 6: Verify the docs match reality**

Run every command quoted in `screencasts/README.md` and in the `CLAUDE.md` block.
Expected: each behaves exactly as documented. Fix the docs, not your memory of them, on any mismatch.

- [ ] **Step 7: Commit**

```bash
git add screencasts/README.md CLAUDE.md
git commit -m "docs(screencasts): usage, maintenance workflow and drift check"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| `screencasts/` layout outside `assets/` | 1 |
| Playwright + Chromium on demand | 1 |
| 1280×720 viewport and video | 1, 5 |
| Credentials from env, never committed | 1, 4 |
| Fake cursor via `addInitScript` | 2 |
| Captions with computed read time | 2 |
| Highlight ring | 2 |
| LiveView settling on phx loading classes | 3 |
| Tribute `pressSequentially` + `.tribute-container li` | 3 |
| Title/end cards as injected overlays | 2, 5 |
| Lesson 1 beat sheet, all 11 beats | 5 |
| Real save, `.created.log` | 4, 5 |
| ffmpeg webm → H.264 mp4 | 5 |
| Self-contained index, light and dark | 6 |
| MP4s gitignored, scripts committed | 1, 6 |
| `--all --dry` selector smoke check | 5, 7 |
| Frame-level visual verification | 5 |

No spec requirement is unassigned. Out-of-scope items (TTS, Chinese captions, in-app help route, hosting, seeded screencast DB) have no tasks, correctly.

**Type consistency:** `createDirector(page, {dry})` returns the object consumed as `d` by `login(d)` and every `run(d)`. `readTime`/`installOverlay` are used only in `director.mjs`. `renderIndex(manifest)` takes the exact shape `record.mjs` reads from `manifest.json` — `{series, lessons: [{id, slug, title, description}]}`. Lesson filenames are `${id}-${slug}.mjs` and video filenames `${id}-${slug}.mp4`, both derived from the same manifest fields in `record.mjs` and `build-index.mjs`.

**Known risk, accepted:** `d.fill("#invoice_invoice_details_0_quantity", …)` targets the non-readonly branch of `detail_component.ex:83-97`. If the chosen good has a packaging with `unit_multiplier > 0`, quantity renders readonly and the fill will fail. Task 5 Step 4 surfaces this as a dry-run failure; the fix is to pick a good without packaging, or drive `package_qty` instead.

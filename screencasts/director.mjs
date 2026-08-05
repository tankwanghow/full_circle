import { readTime, installOverlay } from "./overlay.mjs";

const SETTLE_SELECTOR = ".phx-change-loading, .phx-submit-loading, .phx-click-loading";

export function createDirector(page, { dry = false } = {}) {
  const installed = installOverlay(page);
  const hold = (ms) => (dry ? Promise.resolve() : page.waitForTimeout(ms));
  let ready = false;

  async function settle() {
    await page.waitForFunction(
      (sel) => !document.querySelector(sel),
      SETTLE_SELECTOR,
      { timeout: 15000 }
    );
  }

  // Init scripts only run after a navigation. Title/say can be called before
  // login, so land on a blank document once so window.__sc exists.
  async function ensureOverlay() {
    await installed;
    if (ready && (await page.evaluate(() => !!window.__sc))) return;
    await page.goto("data:text/html,<html><body></body></html>", {
      waitUntil: "domcontentloaded",
    });
    await page.waitForFunction(() => !!window.__sc, null, { timeout: 5000 });
    ready = true;
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
      ready = true;
      await settle();
    },

    async say(text) {
      await ensureOverlay();
      await page.evaluate((t) => window.__sc.say(t), text);
      await hold(readTime(text));
    },

    async pause(ms) {
      await hold(ms);
    },

    async title(t, s = "") {
      await ensureOverlay();
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

      // Tribute autocompleteMode treats Space as a menu action, so typing
      // "Agri Channel" never reaches the field as two words. The app's fuzzy
      // filter is char-by-char (a.*g.*r.*i.*c.*…), so "AgriChannel" still
      // matches "Agri Channel Sdn. Bhd.". Type without spaces, then pick.
      const typed = String(text).replace(/\s+/g, "");
      // Never use delay 0: Tribute's async values() callback races and the menu
      // never appears (observed against the live app).
      const keyDelay = dry ? 25 : 90;
      await loc.press("Control+a");
      await loc.pressSequentially(typed, { delay: keyDelay });

      // Tribute leaves prior menus in the DOM with display:none. Always target
      // the currently visible container only.
      const menu = page.locator(".tribute-container").locator("li").filter({ visible: true });
      await menu.first().waitFor({ state: "visible", timeout: 15000 });

      // Prefer an item whose full text includes the search string (Tribute wraps
      // matched chars in <span>, so hasText still works on the li).
      const exact = menu.filter({ hasText: text });
      const target = (await exact.count()) > 0 ? exact.first() : menu.first();

      const box = await target.boundingBox();
      if (box) {
        const ms = dry ? 0 : 260;
        await page.evaluate(
          ([x, y, m]) => window.__sc.cursorTo(x, y, m),
          [box.x + box.width / 2, box.y + box.height / 2, ms]
        );
      }
      await target.click();
      // Tab so LiveView fires validate with _target on this field and resolves
      // the hidden *_id / reg_no / tax_id via assign_autocomplete_id(s).
      await loc.press("Tab");
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

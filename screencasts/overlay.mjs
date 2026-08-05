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

// Note files open in a full-screen viewer instead of a new tab. One delegated
// listener for the whole app, so it works in streams, components and modals
// with no hook per tile. Links opt in with data-viewer="image" | "pdf"; the
// viewer pages (← →) through the links in the same [data-viewer-group].
// The overlay lives on document.body, outside every LiveView container, so a
// re-render never touches it. A plain click with no JS still opens the file in
// a new tab (the link keeps target=_blank).

let overlay = null
let group = []
let index = 0

// Android Chrome and some phone browsers cannot show a PDF inside a page; an
// <iframe> there stays blank or starts a download. Those keep the new tab.
const pdfInline = () => navigator.pdfViewerEnabled !== false

function el(tag, attrs = {}, text) {
  const e = document.createElement(tag)
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v)
  if (text) e.textContent = text
  return e
}

const BTN = "rounded-full bg-white/15 px-3 py-1 text-sm text-white hover:bg-white/30"

function build() {
  overlay = el("div", {
    id: "file-viewer",
    role: "dialog",
    "aria-modal": "true",
    class: "fixed inset-0 z-[100] flex flex-col bg-black"
  })
  overlay.innerHTML = `
    <div class="flex items-center gap-2 p-2 text-white">
      <span data-fv="name" class="min-w-0 flex-1 truncate text-sm"></span>
      <span data-fv="count" class="text-xs text-white/70"></span>
      <a data-fv="tab" target="_blank" class="${BTN}" title="Open in new tab">↗</a>
      <a data-fv="download" class="${BTN}" title="Download">⤓</a>
      <button type="button" data-fv="close" class="${BTN}" title="Close (Esc)">✕</button>
    </div>
    <div data-fv="stage" class="relative flex min-h-0 flex-1 items-center justify-center p-2"></div>
    <button type="button" data-fv="prev" class="absolute left-2 top-1/2 ${BTN} text-2xl" title="Previous (←)">‹</button>
    <button type="button" data-fv="next" class="absolute right-2 top-1/2 ${BTN} text-2xl" title="Next (→)">›</button>`
  overlay.addEventListener("click", e => {
    const fv = e.target.closest("[data-fv]")?.dataset.fv
    if (fv === "close" || e.target.dataset.fv === "stage") close()
    else if (fv === "prev") show(index - 1)
    else if (fv === "next") show(index + 1)
  })
  document.body.appendChild(overlay)
}

function part(name) { return overlay.querySelector(`[data-fv="${name}"]`) }

function show(i) {
  index = (i + group.length) % group.length
  const link = group[index]
  const url = link.getAttribute("href")
  const name = link.dataset.viewerName || link.title || ""
  const pdf = link.dataset.viewer === "pdf"
  const stage = part("stage")
  stage.replaceChildren(
    pdf
      ? el("iframe", { src: url, title: name, class: "h-full w-full max-w-5xl rounded bg-white" })
      : el("img", { src: url, alt: name, class: "max-h-full max-w-full object-contain" })
  )
  // The browser's PDF toolbar already shows the name, download and print, so
  // a PDF keeps only the counter and ✕ here; two toolbars read as a muddle.
  part("name").textContent = pdf ? "" : name
  part("count").textContent = group.length > 1 ? `${index + 1} / ${group.length}` : ""
  part("tab").hidden = part("download").hidden = pdf
  part("tab").href = url
  part("download").href = url
  part("download").setAttribute("download", name)
  part("prev").hidden = part("next").hidden = group.length < 2
}

function open(link) {
  if (!overlay) build()
  const box = link.closest("[data-viewer-group]")
  group = box ? Array.from(box.querySelectorAll("a[data-viewer]")) : [link]
  // A PDF this browser cannot show inline is skipped by ← →, not shown blank.
  if (!pdfInline()) group = group.filter(a => a.dataset.viewer !== "pdf")
  overlay.hidden = false
  document.documentElement.style.overflow = "hidden"
  show(Math.max(0, group.indexOf(link)))
}

function close() {
  if (!overlay || overlay.hidden) return
  overlay.hidden = true
  part("stage").replaceChildren()
  document.documentElement.style.overflow = ""
}

export function installFileViewer() {
  document.addEventListener("click", e => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
    const link = e.target.closest("a[data-viewer]")
    if (!link) return
    if (link.dataset.viewer === "pdf" && !pdfInline()) return
    e.preventDefault()
    open(link)
  })
  document.addEventListener("keydown", e => {
    if (!overlay || overlay.hidden) return
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); close() }
    else if (e.key === "ArrowLeft" && group.length > 1) show(index - 1)
    else if (e.key === "ArrowRight" && group.length > 1) show(index + 1)
  }, true)
  // Navigating away (LiveView patch/redirect) must not leave the viewer up.
  window.addEventListener("phx:page-loading-start", close)
}

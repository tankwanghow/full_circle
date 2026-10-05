// A click on a post's empty space (padding, avatar, beside the files) opens
// it, the way X/Twitter posts do. Used by note posts (`note_post`) and task
// rows (`task_row`). Without it a note with no title and no text, say photos
// only, is nearly impossible to open: its text link is empty and the file
// tiles open the viewer instead.
//
// It clicks the row's own [data-post-link], so the feed still navigates in
// place and a record's panel still opens a new tab. Anything interactive keeps
// its own click, and so does a click that ends a text selection.

const OWN_CLICK = "a, button, input, textarea, select, label, summary, [phx-click], [data-no-post-open]"

export function installPostOpen() {
  document.addEventListener("click", e => {
    if (e.defaultPrevented || e.button !== 0) return
    const post = e.target.closest("[data-post-open]")
    if (!post || e.target.closest(OWN_CLICK)) return
    if (String(window.getSelection() || "") !== "") return
    const link = post.querySelector("a[data-post-link]")
    if (!link) return
    if (e.ctrlKey || e.metaKey) window.open(link.href, "_blank")
    else link.click()
  })
}

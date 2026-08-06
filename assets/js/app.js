// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import topbar from "../vendor/topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let Hooks = {}

Hooks.clipCopy = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.getAttribute("id");
      navigator.clipboard.writeText(text).then(() => {
        var elements = document.getElementsByClassName('hero-clipboard-solid');
        for (var i = 0; i < elements.length; i++) {
          elements[i].classList.add('hero-clipboard');
          elements[i].classList.remove('hero-clipboard-solid');
        }
        this.el.classList.remove('hero-clipboard');
        this.el.classList.add('hero-clipboard-solid');

      }).catch(err => {
        console.error('Could not copy text: ', err);
      });
    });
  }
}

Hooks.FaceID = {
  mounted() {
    import("./face_id").then(
      (h) => {
        h.initFaceID(this)
      }
    );
  }
}

Hooks.takePhoto = {
  mounted() {
    import("./take_photo_human").then(
      (h) => {
        this._takePhoto = h
        h.initTakePhoto(this)
      }
    );
  },
  destroyed() {
    if (this._takePhoto?.teardownTakePhoto) this._takePhoto.teardownTakePhoto()
  }
}

Hooks.punchCamera = {
  mounted() {
    import("./qr_attend").then(
      (q) => {
        q.initPunchCamera(this)
      }
    );
  }
}

Hooks.tributeAutoComplete = {
  mounted() {
    import("./tri_autocomplete").then(
      (t) => {
        t.initTributeAutoComplete(this.el)
      }
    )
  }
}

Hooks.tributeTagText = {
  mounted() {
    import("./tri_autocomplete").then(
      (t) => {
        t.initTributeTagText(this.el)
      }
    )
  }
}

Hooks.calculatorInput = {
  mounted() {
    this.el.addEventListener("blur", e => {
      if (!/[a-zA-Z]+/.test(this.el.value)) {
        try {
          var eval2 = eval
          var result = eval2(this.el.value)
          if (result !== undefined && `${result}` !== this.el.value) {
            this.el.value = result
            this.el.dispatchEvent(new Event("input", { bubbles: true }))
          }
        } catch (error) {
          console.log(error)
        }
      }
    })
  }
}

Hooks.localStorageInput = {
  mounted() {
    let key = this.el.getAttribute("data-ls-key")
    let stored = localStorage.getItem(key)
    if (stored !== null && stored !== this.el.value) {
      this.el.value = stored
      this.el.dispatchEvent(new Event("input", { bubbles: true }))
    }
    this.el.addEventListener("input", () => {
      localStorage.setItem(key, this.el.value)
    })
  }
}

// App-wide command palette (Ctrl/Cmd+K) — search + actions + recents
Hooks.CommandPalette = {
  mounted() {
    this.open = () => {
      this.pushEventTo(this.el, "open", {})
    }
    this.onKey = (e) => {
      const mod = e.ctrlKey || e.metaKey

      // Ctrl/Cmd+K → command palette
      if (mod && !e.altKey && !e.shiftKey && (e.key === "k" || e.key === "K")) {
        e.preventDefault()
        this.open()
        return
      }

      // Ctrl/Cmd+Shift+D → company dashboard (Shift avoids browser bookmark Ctrl+D)
      if (mod && e.shiftKey && !e.altKey && (e.key === "d" || e.key === "D")) {
        e.preventDefault()
        e.stopPropagation()
        this.pushEventTo(this.el, "go_dashboard", {})
        return
      }

      if (this.el.dataset.open !== "true") return

      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        return
      }

      // Alt+Enter → print selected (handle here so form submit / LV key quirks don't drop it)
      if (e.key === "Enter" && e.altKey) {
        e.preventDefault()
        e.stopPropagation()
        this.pushEventTo(this.el, "print_selected", {})
      }
    }
    this.onCustom = () => this.open()
    // Capture phase so Alt+Enter beats form submit / other handlers
    window.addEventListener("keydown", this.onKey, true)
    window.addEventListener("fc-open-command-palette", this.onCustom)

    this.handleEvent("palette_load_recents", ({ company_id }) => {
      const key = `fc-palette-recents-${company_id || this.el.dataset.companyId}`
      let items = []
      try {
        items = JSON.parse(localStorage.getItem(key) || "[]")
      } catch (_) {
        items = []
      }
      if (!Array.isArray(items)) items = []
      this.pushEventTo(this.el, "recents", { items })
    })

    this.handleEvent("palette_remember", (item) => {
      const companyId = item.company_id || this.el.dataset.companyId
      if (!companyId || !item.path) return
      const key = `fc-palette-recents-${companyId}`
      let items = []
      try {
        items = JSON.parse(localStorage.getItem(key) || "[]")
      } catch (_) {
        items = []
      }
      if (!Array.isArray(items)) items = []
      items = items.filter((x) => x && x.path !== item.path)
      items.unshift({
        path: item.path,
        title: item.title,
        label: item.label,
        doc_type: item.doc_type,
        doc_id: item.doc_id
      })
      localStorage.setItem(key, JSON.stringify(items.slice(0, 8)))
    })
  },
  updated() {
    if (this.el.dataset.open !== "true") return

    const input = this.el.querySelector("input[type=search]")
    if (input && document.activeElement !== input) {
      requestAnimationFrame(() => input.focus())
    }

    requestAnimationFrame(() => {
      requestAnimationFrame(() => this.scrollSelectedIntoView())
    })
  },
  scrollSelectedIntoView() {
    const selected = this.el.querySelector('[role="option"][aria-selected="true"]')
    if (!selected) return

    const list =
      selected.closest('[role="listbox"]') ||
      this.el.querySelector('[role="listbox"]')
    if (!list) return

    const listRect = list.getBoundingClientRect()
    const itemRect = selected.getBoundingClientRect()
    const pad = 4

    if (itemRect.bottom > listRect.bottom - pad) {
      list.scrollTop += itemRect.bottom - listRect.bottom + pad
    } else if (itemRect.top < listRect.top + pad) {
      list.scrollTop -= listRect.top - itemRect.top + pad
    }
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey, true)
    window.removeEventListener("fc-open-command-palette", this.onCustom)
  }
}


Hooks.ctrlEnterAddDetail = {
  mounted() {
    this.handleKey = (event) => {
      if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
        event.preventDefault()
        this.pushEvent("add_detail", {})
      }
    }
    this.el.addEventListener("keydown", this.handleKey)
  },
  destroyed() {
    this.el.removeEventListener("keydown", this.handleKey)
  }
}

Hooks.copyAndOpen = {
  mounted() {
    this.handleClick = (event) => {
      event.preventDefault() // Prevent default link behavior
      var text = this.el.getAttribute('copy-text')
      var url = this.el.getAttribute('goto-url')
      console.log(text)
      navigator.clipboard.writeText(text).then(() => {
        window.open(url, "_blank") // Open URL in new tab after copying
      }).catch(err => {
        console.error("Failed to copy text: ", err) // Log error if copying fails
        window.open(url, "_blank") // Open URL even if copying fails
      });
    };
    this.el.addEventListener("click", this.handleClick) // Attach click listener
  },
  destroyed() {
    this.el.removeEventListener("click", this.handleClick) // Cleanup listener
  }
};

// Click map / use browser GPS to fill latitude & longitude on location form
Hooks.GpsMapPicker = {
  mounted() {
    import("./gps_map_picker").then((m) => {
      this._gps = m
      m.initGpsMapPicker(this)
    })
  },
  destroyed() {
    if (this._gps?.destroyGpsMapPicker) this._gps.destroyGpsMapPicker(this)
  }
}

// Converts machine .xls (and passes through .xlsx) to .xlsx in-browser, then
// hands the result to the LiveView uploader. Keeps the server on xlsx_reader.
// SheetJS is dynamically imported so it only loads on the import page.
Hooks.XlsToXlsxUpload = {
  mounted() {
    this.el.addEventListener("change", async (e) => {
      const files = Array.from(e.target.files || [])
      if (files.length === 0) return
      try {
        const XLSX = await import("../vendor/sheetjs/xlsx.mjs")
        const converted = []
        for (const f of files) {
          const buf = await f.arrayBuffer()
          const wb = XLSX.read(new Uint8Array(buf), { type: "array" })
          const out = XLSX.write(wb, { bookType: "xlsx", type: "array" })
          const base = f.name.replace(/\.(xls|xlsx)$/i, "")
          converted.push(new File([out], `${base}.xlsx`,
            { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }))
        }
        // this.upload targets the hidden <.live_file_input upload={@uploads.xlsx_file}>
        this.upload("xlsx_file", converted)
        e.target.value = "" // allow re-selecting the same file
      } catch (err) {
        console.error("XlsToXlsxUpload failed:", err)
        alert("Could not read the attendance file: " + ((err && err.message) || err))
      }
    })
  }
}

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken }
})

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" })
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

window.addEventListener("phx:scroll-to", (e) => {
  const el = document.getElementById(e.detail.id)
  if (el) el.scrollIntoView({ behavior: "smooth", block: "start" })
})

window.addEventListener("phx:invalidate_autocomplete_cache", () => {
  import("./tri_autocomplete").then(mod => mod.invalidateAutocompleteCache())
})

window.addEventListener("phx:history_back", () => window.history.back())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket


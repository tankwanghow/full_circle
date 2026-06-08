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
          this.el.value = eval2(this.el.value)
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


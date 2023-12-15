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
import Tribute from "../vendor/tribute"
import { Html5QrcodeScanner } from "../vendor/html5-qrcode/src/html5-qrcode-scanner"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let Hooks = {}

let html5QrcodeScanner;

Hooks.QR_Reply = {
  mounted() {
    this.el.innerHTML = "Scan Employee QR";
    this.el.className += " bg-amber-200 border-amber-600";
  },
  updated() {
    if (this.el.innerText != "Scan Employee QR") {
      reader = document.getElementById("qr-reader");
      reader_class = reader.className;
      reader.className = "hidden";

      setTimeout(() => {
        this.pushEvent("qr-code-scan-resume");
        reader.className = reader_class;
        html5QrcodeScanner.resume();
      }, 3000);
    }
  }
}

Hooks.QR_Scanner = {
  onScanFailure(error) {
  },

  mounted() {
    html5QrcodeScanner = new Html5QrcodeScanner(
      "qr-reader",
      { fps: 2, aspectRatio: 1, qrbox: { width: 220, height: 220 } },
      false
    )

    long = 182;
    lat = 182;

    if (navigator.geolocation) {
      navigator.geolocation.watchPosition(
        (pos) => {
          long = pos.coords.longitude;
          lat = pos.coords.latitude;
        },
        () => {
          long = 182;
          lat = 182;
        },
        { maximumAge: 60000, enableHighAccuracy: true });
    } else {
      long = 182;
      lat = 182;
    }

    onScanSuccess = (decodedText, decodedResult) => {
      decodedResult.gps_long = long;
      decodedResult.gps_lat = lat;
      this.pushEvent("qr-code-scanned", decodedResult);
      html5QrcodeScanner.pause();
    }

    html5QrcodeScanner.render(onScanSuccess, this.onScanFailure);
  }
}

Hooks.tributeTagText = {
  mounted() {
    var tribute = new Tribute({
      trigger: "#",
      values: (t, c) => { remoteSearch(this.el, t, c) },
      lookup: "value",
      fillAttr: "value",
      menuItemLimit: 8
    });
    tribute.attach(this.el)
  }
};

Hooks.tributeAutoComplete = {
  mounted() {
    var tribute = new Tribute({
      values: (t, c) => { remoteSearch(this.el, t, c) },
      autocompleteMode: true,
      lookup: "value",
      fillAttr: "value",
      menuItemLimit: 8
    });
    tribute.attach(this.el)
  }
}

function remoteSearch(el, text, cb) {
  var URL = el.getAttribute('url');
  xhr = new XMLHttpRequest();
  xhr.onreadystatechange = function () {
    if (xhr.readyState === 4) {
      if (xhr.status === 200) {
        var data = JSON.parse(xhr.responseText);
        cb(data);
      } else if (xhr.status === 403) {
        cb([]);
      }
    }
  };
  xhr.open("GET", URL + text, true);
  xhr.send();
}

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken }
})

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" })
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket


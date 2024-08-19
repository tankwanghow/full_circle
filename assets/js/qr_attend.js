import { Html5QrcodeScanner } from "../vendor/html5-qrcode/src/html5-qrcode-scanner"

export function initReply(el, lv) {
  this.el.innerHTML = "Scan Employee QR";
  this.el.className += " bg-amber-200 border-amber-600";
}

export function updateReply(reader, scanner) {
  if (this.el.innerText != "Scan Employee QR") {
    reader = document.getElementById("qr-reader");
    reader_class = reader.className;
    reader.className = "hidden";

    setTimeout(() => {
      lv.pushEvent("qr-code-scan-resume");
      reader.className = reader_class;
      scanner.resume();
    }, 3000);
  }
}


export function initScanner(id, lv) {
  scanner = new Html5QrcodeScanner(
    id,
    { fps: 2, aspectRatio: 1, qrbox: { width: 280, height: 280 } },
    false
  )

  let long = 182;
  let lat = 182;

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
    scanner.pause();
    lv.pushEvent("qr-code-scanned", decodedResult);
  }

  scanner.render(onScanSuccess);
}

export function destroyScanner(scanner) { scanner.clear(); }
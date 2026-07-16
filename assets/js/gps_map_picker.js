// Interactive map picker (Leaflet).
// Default basemap: satellite (Esri World Imagery). Street map optional.
// Click the map (or "Use my location") to fill latitude / longitude.
// Google Maps is used for the open-link only (no Google Maps API key required).

const LEAFLET_CSS = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
const LEAFLET_JS = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"
// Default center: Klang Valley / Malaysia
const DEFAULT_CENTER = [3.1390, 101.6869]
const DEFAULT_ZOOM = 12

// Esri World Imagery (satellite) — free for many non-commercial apps
const SATELLITE_URL =
  "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
const SATELLITE_ATTR =
  "Tiles &copy; Esri — Source: Esri, Maxar, Earthstar Geographics, and the GIS User Community"
// Optional place names over satellite
const LABELS_URL =
  "https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}"
const STREET_URL = "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
const STREET_ATTR =
  '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'


let leafletLoading = null

function loadLeaflet() {
  if (window.L) return Promise.resolve(window.L)
  if (leafletLoading) return leafletLoading

  leafletLoading = new Promise((resolve, reject) => {
    if (!document.querySelector(`link[href="${LEAFLET_CSS}"]`)) {
      const link = document.createElement("link")
      link.rel = "stylesheet"
      link.href = LEAFLET_CSS
      document.head.appendChild(link)
    }

    const existing = document.querySelector(`script[src="${LEAFLET_JS}"]`)
    if (existing) {
      existing.addEventListener("load", () => resolve(window.L))
      return
    }

    const script = document.createElement("script")
    script.src = LEAFLET_JS
    script.async = true
    script.onload = () => resolve(window.L)
    script.onerror = () => reject(new Error("Failed to load Leaflet"))
    document.head.appendChild(script)
  })

  return leafletLoading
}

function parseCoord(value) {
  if (value === null || value === undefined || value === "") return null
  const n = typeof value === "number" ? value : parseFloat(String(value))
  return Number.isFinite(n) ? n : null
}

function setInputValue(input, value) {
  if (!input) return
  input.value = value
  input.dispatchEvent(new Event("input", { bubbles: true }))
  input.dispatchEvent(new Event("change", { bubbles: true }))
}

export function initGpsMapPicker(hook) {
  const el = hook.el
  const mapEl = el.querySelector("[data-gps-map]")
  if (!mapEl) return

  const latInputId = el.dataset.latInput
  const lngInputId = el.dataset.lngInput
  const latInput = latInputId ? document.getElementById(latInputId) : null
  const lngInput = lngInputId ? document.getElementById(lngInputId) : null
  const locateBtn = el.querySelector("[data-gps-locate]")
  const clearBtn = el.querySelector("[data-gps-clear]")
  const statusEl = el.querySelector("[data-gps-status]")

  let map = null
  let marker = null
  let L = null

  const setStatus = (text) => {
    if (statusEl) statusEl.textContent = text || ""
  }

  const readCoords = () => {
    const lat = parseCoord(latInput?.value ?? el.dataset.lat)
    const lng = parseCoord(lngInput?.value ?? el.dataset.lng)
    return { lat, lng }
  }

  const placeMarker = (lat, lng, { pan = true } = {}) => {
    if (!map || !L) return
    if (marker) {
      marker.setLatLng([lat, lng])
    } else {
      marker = L.marker([lat, lng], { draggable: true }).addTo(map)
      marker.on("dragend", () => {
        const pos = marker.getLatLng()
        applyCoords(pos.lat, pos.lng, { fromMarker: true })
      })
    }
    if (pan) map.setView([lat, lng], Math.max(map.getZoom(), 15))
  }

  const applyCoords = (lat, lng, { fromMarker = false } = {}) => {
    const latStr = Number(lat).toFixed(6)
    const lngStr = Number(lng).toFixed(6)
    setInputValue(latInput, latStr)
    setInputValue(lngInput, lngStr)
    // Also notify LiveView so form state stays in sync
    hook.pushEvent("map_pick", { latitude: latStr, longitude: lngStr })
    if (!fromMarker) placeMarker(lat, lng)
    setStatus(`${latStr}, ${lngStr}`)
  }

  const clearCoords = () => {
    setInputValue(latInput, "")
    setInputValue(lngInput, "")
    if (marker && map) {
      map.removeLayer(marker)
      marker = null
    }
    hook.pushEvent("map_pick", { latitude: "", longitude: "" })
    setStatus("")
  }

  loadLeaflet()
    .then((leaflet) => {
      L = leaflet
      const { lat, lng } = readCoords()
      const center = lat != null && lng != null ? [lat, lng] : DEFAULT_CENTER
      const zoom = lat != null && lng != null ? 15 : DEFAULT_ZOOM

      map = L.map(mapEl, { scrollWheelZoom: true }).setView(center, zoom)
      L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
      }).addTo(map)

      if (lat != null && lng != null) placeMarker(lat, lng, { pan: false })

      map.on("click", (e) => {
        applyCoords(e.latlng.lat, e.latlng.lng)
      })

      // Fix tile size when container becomes visible
      setTimeout(() => map.invalidateSize(), 100)
      setTimeout(() => map.invalidateSize(), 400)

      el._gpsMap = map
    })
    .catch((err) => {
      console.error(err)
      setStatus("Map failed to load")
    })

  if (locateBtn) {
    locateBtn.addEventListener("click", (e) => {
      e.preventDefault()
      if (!navigator.geolocation) {
        setStatus("Geolocation not supported")
        return
      }
      setStatus("Locating…")
      navigator.geolocation.getCurrentPosition(
        (pos) => {
          applyCoords(pos.coords.latitude, pos.coords.longitude)
        },
        (err) => {
          setStatus(err.message || "Could not get location")
        },
        { enableHighAccuracy: true, timeout: 15000 }
      )
    })
  }

  if (clearBtn) {
    clearBtn.addEventListener("click", (e) => {
      e.preventDefault()
      clearCoords()
    })
  }

  // Keep marker in sync when user types lat/lng manually
  const onManualInput = () => {
    const { lat, lng } = readCoords()
    if (lat != null && lng != null) placeMarker(lat, lng)
  }
  latInput?.addEventListener("change", onManualInput)
  lngInput?.addEventListener("change", onManualInput)

  el._gpsCleanup = () => {
    latInput?.removeEventListener("change", onManualInput)
    lngInput?.removeEventListener("change", onManualInput)
    if (map) {
      map.remove()
      map = null
    }
  }
}

export function destroyGpsMapPicker(hook) {
  if (hook.el?._gpsCleanup) hook.el._gpsCleanup()
}

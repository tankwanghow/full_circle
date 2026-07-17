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

// Free place search (OpenStreetMap via Photon / Komoot) — no API key
const PHOTON_URL = "https://photon.komoot.io/api/"

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

function formatPlaceLabel(props) {
  if (!props) return "Unknown place"
  const parts = [
    props.name,
    props.city || props.town || props.village || props.municipality,
    props.county || props.state,
    props.country
  ].filter((p, i, arr) => p && arr.indexOf(p) === i)
  return parts.join(", ") || props.type || "Place"
}

function zoomForPlace(props) {
  const t = (props?.osm_value || props?.type || "").toLowerCase()
  if (["country"].includes(t)) return 6
  if (["state", "region"].includes(t)) return 8
  if (["county", "district"].includes(t)) return 10
  if (["city", "town", "municipality"].includes(t)) return 13
  if (["village", "suburb", "neighbourhood", "hamlet"].includes(t)) return 15
  return 14
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
  const searchInput = el.querySelector("[data-gps-search]")
  const searchResults = el.querySelector("[data-gps-search-results]")
  const searchBtn = el.querySelector("[data-gps-search-btn]")

  let map = null
  let marker = null
  let L = null
  let searchTimer = null
  let searchAbort = null

  const setStatus = (text) => {
    if (statusEl) statusEl.textContent = text || ""
  }

  const hideResults = () => {
    if (!searchResults) return
    searchResults.innerHTML = ""
    searchResults.classList.add("hidden")
  }

  const showResults = (items) => {
    if (!searchResults) return
    searchResults.innerHTML = ""
    if (!items.length) {
      searchResults.innerHTML =
        '<div class="px-3 py-2 text-sm text-gray-500">No places found</div>'
      searchResults.classList.remove("hidden")
      return
    }

    items.forEach((item) => {
      const btn = document.createElement("button")
      btn.type = "button"
      btn.className =
        "block w-full text-left px-3 py-2 text-sm hover:bg-amber-100 dark:hover:bg-zinc-700 border-b border-zinc-100 dark:border-zinc-700 last:border-0"
      btn.textContent = item.label
      btn.addEventListener("click", (e) => {
        e.preventDefault()
        e.stopPropagation()
        goToPlace(item)
        hideResults()
        if (searchInput) searchInput.value = item.label
      })
      searchResults.appendChild(btn)
    })
    searchResults.classList.remove("hidden")
  }

  const goToPlace = (item) => {
    if (!map) return
    const zoom = item.zoom || 13
    // Fit bbox when available (better for cities/towns)
    if (item.bbox && L) {
      try {
        // Photon extent is [minLon, minLat, maxLon, maxLat] sometimes missing
        const [west, south, east, north] = item.bbox
        if ([west, south, east, north].every((n) => Number.isFinite(n))) {
          map.fitBounds(
            [
              [south, west],
              [north, east]
            ],
            { padding: [24, 24], maxZoom: 16 }
          )
          // Do not force pin — user clicks exact site; only zoom for navigation
          setStatus(`Zoomed to ${item.label}`)
          return
        }
      } catch (_) {
        /* fall through */
      }
    }
    map.setView([item.lat, item.lng], zoom)
    setStatus(`Zoomed to ${item.label}`)
  }

  const searchPlaces = async (query) => {
    const q = (query || "").trim()
    if (q.length < 2) {
      hideResults()
      return
    }

    if (searchAbort) searchAbort.abort()
    searchAbort = new AbortController()

    setStatus("Searching…")
    try {
      const url = `${PHOTON_URL}?q=${encodeURIComponent(q)}&limit=8&lang=en`
      const res = await fetch(url, { signal: searchAbort.signal })
      if (!res.ok) throw new Error(`Search failed (${res.status})`)
      const data = await res.json()
      const features = data.features || []
      const items = features
        .map((f) => {
          const coords = f.geometry?.coordinates
          if (!coords || coords.length < 2) return null
          const [lng, lat] = coords
          const props = f.properties || {}
          return {
            lat,
            lng,
            label: formatPlaceLabel(props),
            zoom: zoomForPlace(props),
            bbox: props.extent || null
          }
        })
        .filter(Boolean)

      showResults(items)
      setStatus(items.length ? `${items.length} place(s)` : "No places found")
    } catch (err) {
      if (err.name === "AbortError") return
      console.error(err)
      setStatus("Search failed")
      hideResults()
    }
  }

  const scheduleSearch = (query) => {
    if (searchTimer) clearTimeout(searchTimer)
    searchTimer = setTimeout(() => searchPlaces(query), 350)
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

      const satellite = L.tileLayer(SATELLITE_URL, {
        maxZoom: 19,
        attribution: SATELLITE_ATTR
      })
      const labels = L.tileLayer(LABELS_URL, {
        maxZoom: 19,
        pane: "overlayPane",
        opacity: 0.9
      })
      const street = L.tileLayer(STREET_URL, {
        maxZoom: 19,
        attribution: STREET_ATTR
      })

      // Satellite + place labels by default
      satellite.addTo(map)
      labels.addTo(map)

      L.control
        .layers(
          {
            Satellite: satellite,
            Street: street
          },
          {
            Labels: labels
          },
          { position: "topright", collapsed: true }
        )
        .addTo(map)

      if (lat != null && lng != null) placeMarker(lat, lng, { pan: false })

      map.on("click", (e) => {
        applyCoords(e.latlng.lat, e.latlng.lng)
        hideResults()
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

  if (searchInput) {
    searchInput.addEventListener("input", (e) => {
      scheduleSearch(e.target.value)
    })
    searchInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault()
        e.stopPropagation()
        if (searchTimer) clearTimeout(searchTimer)
        searchPlaces(searchInput.value)
      } else if (e.key === "Escape") {
        hideResults()
      }
    })
    // Prevent LiveView form submit / phx-change noise from the search box
    searchInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") e.preventDefault()
    })
  }

  if (searchBtn) {
    searchBtn.addEventListener("click", (e) => {
      e.preventDefault()
      if (searchTimer) clearTimeout(searchTimer)
      searchPlaces(searchInput?.value || "")
    })
  }

  // Close results when clicking elsewhere in the picker (not on results)
  const onDocClick = (e) => {
    if (!searchResults || searchResults.classList.contains("hidden")) return
    if (el.contains(e.target) && !searchResults.contains(e.target) && e.target !== searchInput) {
      hideResults()
    }
  }
  document.addEventListener("click", onDocClick)

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
    if (searchTimer) clearTimeout(searchTimer)
    if (searchAbort) searchAbort.abort()
    document.removeEventListener("click", onDocClick)
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

import Tribute from "../vendor/tribute"

const CACHE_EXPIRY = 60 * 60 * 1000 // 1 hour
const CACHE_KEYS = {
  employee: "auto_employee",
  house: "auto_house",
  contact: "auto_contact",
  account: "auto_account",
  good: "auto_good"
}
const CACHE_INVALIDATE_EVENT = "auto_cache_invalidate"

function now() {
  return new Date().getTime()
}

function getCache(key) {
  const data = localStorage.getItem(key)
  if (!data) return null
  try {
    const { values, ts } = JSON.parse(data)
    if (now() - ts < CACHE_EXPIRY) {
      return values
    }
  } catch (_) {}
  return null
}

function setCache(key, values) {
  localStorage.setItem(key, JSON.stringify({ values, ts: now() }))
}

function clearAllAutoCache() {
  Object.values(CACHE_KEYS).forEach((key) => {
    localStorage.removeItem(key)
  })
}

window.addEventListener("storage", function (e) {
  if (e.key === CACHE_INVALIDATE_EVENT) {
    clearAllAutoCache()
  }
})

export function invalidateAutocompleteCache() {
  clearAllAutoCache()
  localStorage.setItem(CACHE_INVALIDATE_EVENT, String(now()))
}

async function fetchAndCache(url, key, cb, text) {
  const xhr = new XMLHttpRequest();
  xhr.onreadystatechange = function () {
    if (xhr.readyState === 4) {
      if (xhr.status === 200) {
        try {
          var data = JSON.parse(xhr.responseText);
          setCache(key, data)
          cb(filter(data, text));
        } catch (e) {
          cb([])
        }
      } else if (xhr.status === 403) {
        cb([])
      }
    }
  };
  xhr.open("GET", url, true);
  xhr.send();
}

function filter(data, text) {
  text = text.trim().toLowerCase()
  if (!text) return data
  return data.filter(item => (item.value||"").replace(/\s/g, "").toLowerCase().includes(text))
}

export function initTributeAutoComplete(el) {
  var tribute = new Tribute({
    values: (t, c) => { cacheSearch(el, t, c) },
    autocompleteMode: true,
    lookup: "value",
    fillAttr: "value",
    menuItemLimit: 8
  });
  tribute.attach(el)
}

function cacheSearch(el, text, cb) {
  var URL = el.getAttribute('url')
  if (!URL) return cb([])
  if (URL.includes('schema=employee')) {
    handleCache(CACHE_KEYS.employee, URL, text, cb)
  } else if (URL.includes('schema=house')) {
    handleCache(CACHE_KEYS.house, URL, text, cb)
  } else if (URL.includes('schema=contact')) {
    handleCache(CACHE_KEYS.contact, URL, text, cb)
  } else if (URL.includes('schema=account')) {
    handleCache(CACHE_KEYS.account, URL, text, cb)
  } else if (URL.includes('schema=good')) {
    handleCache(CACHE_KEYS.good, URL, text, cb)
  } else {
    remoteSearch(el, text, cb)
  }
}

function handleCache(key, URL, text, cb) {
  const cache = getCache(key)
  if (cache) {
    cb(filter(cache, text))
  } else {
    fetchAndCache(URL, key, cb, text)
  }
}

function remoteSearch(el, text, cb) {
  var URL = el.getAttribute('url');
  var xhr = new XMLHttpRequest();
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

export function initTributeTagText(el) {
  var tribute = new Tribute({
    trigger: "#",
    values: (t, c) => { remoteSearch(el, t, c) },
    lookup: "value",
    fillAttr: "value",
    menuItemLimit: 8
  });
  tribute.attach(el)
}

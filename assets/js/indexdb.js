let db // instance of indexdb

const database = "full_circle"
const table = "employee_photos"

const log = (...msg) => console.log("indexdb", ...msg) // eslint-disable-line no-console

export async function open() {
  if (db) return true
  return new Promise(resolve => {
    const request = indexedDB.open(database, 1)
    request.onerror = evt => log("error:", evt)
    request.onupgradeneeded = evt => {
      // create if doesnt exist
      log("create:", evt.target)
      db = evt.target.result
      db.createObjectStore(table, { keyPath: "id", autoIncrement: true })
    }
    request.onsuccess = evt => {
      // open
      db = evt.target.result
      log("open:", db)
      resolve(true)
    }
  })
}

export async function load() {
  const faceDB = []
  if (!db) await open() // open or create if not already done
  return new Promise(resolve => {
    const cursor = db
      .transaction([table], "readwrite")
      .objectStore(table)
      .openCursor(null, "next")
    cursor.onerror = evt => log("load error:", evt)
    cursor.onsuccess = evt => {
      if (evt.target.result) {
        faceDB.push(evt.target.result.value)
        evt.target.result.continue()
      } else {
        resolve(faceDB)
      }
    }
  })
}

export async function count() {
  if (!db) await open() // open or create if not already done
  return new Promise(resolve => {
    const store = db
      .transaction([table], "readwrite")
      .objectStore(table)
      .count()
    store.onerror = evt => log("count error:", evt)
    store.onsuccess = () => resolve(store.result)
  })
}

export async function save(faceRecord) {
  if (!db) await open() // open or create if not already done
  const newRecord = {
    id: faceRecord.id,
    name: faceRecord.employee_name,
    descriptor: faceRecord.photo_descriptor,
    image: faceRecord.photo_data,
    employee_id: faceRecord.employee_id
  } // omit id as its autoincrement
  db.transaction([table], "readwrite")
    .objectStore(table)
    .put(newRecord)
  // log("save:", newRecord)
}

export async function remove(faceRecord) {
  if (!db) await open() // open or create if not already done
  db.transaction([table], "readwrite")
    .objectStore(table)
    .delete(faceRecord.id) // delete based on id
  // log("delete:", faceRecord)
}

export async function clear() {
  if (!db) await open() // open or create if not already done
  db.transaction([table], "readwrite")
    .objectStore(table)
    .clear()
}

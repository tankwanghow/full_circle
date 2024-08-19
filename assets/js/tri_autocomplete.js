import Tribute from "../vendor/tribute"

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


export function initTributeAutoComplete(el) {
  var tribute = new Tribute({
    values: (t, c) => { remoteSearch(el, t, c) },
    autocompleteMode: true,
    lookup: "value",
    fillAttr: "value",
    menuItemLimit: 8
  });
  tribute.attach(el)
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
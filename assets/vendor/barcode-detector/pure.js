var Le = (c, p, i) => {
  if (!p.has(c))
    throw TypeError("Cannot " + i);
};
var qt = (c, p, i) => (Le(c, p, "read from private field"), i ? i.call(c) : p.get(c)), ze = (c, p, i) => {
  if (p.has(c))
    throw TypeError("Cannot add the same private member more than once");
  p instanceof WeakSet ? p.add(c) : p.set(c, i);
}, Ye = (c, p, i, v) => (Le(c, p, "write to private field"), v ? v.call(c, i) : p.set(c, i), i);
const Ne = [
  "aztec",
  "code_128",
  "code_39",
  "code_93",
  "codabar",
  "data_matrix",
  "ean_13",
  "ean_8",
  "itf",
  "pdf417",
  "qr_code",
  "upc_a",
  "upc_e",
  "unknown"
];
function Oa(c) {
  if (Qe(c))
    return {
      width: c.naturalWidth,
      height: c.naturalHeight
    };
  if (Ze(c))
    return {
      width: c.width.baseVal.value,
      height: c.height.baseVal.value
    };
  if (Ke(c))
    return {
      width: c.videoWidth,
      height: c.videoHeight
    };
  if (er(c))
    return {
      width: c.width,
      height: c.height
    };
  if (nr(c))
    return {
      width: c.displayWidth,
      height: c.displayHeight
    };
  if (tr(c))
    return {
      width: c.width,
      height: c.height
    };
  if (rr(c))
    return {
      width: c.width,
      height: c.height
    };
  throw new TypeError(
    "The provided value is not of type '(Blob or HTMLCanvasElement or HTMLImageElement or HTMLVideoElement or ImageBitmap or ImageData or OffscreenCanvas or SVGImageElement or VideoFrame)'."
  );
}
function Qe(c) {
  try {
    return c instanceof HTMLImageElement;
  } catch {
    return !1;
  }
}
function Ze(c) {
  try {
    return c instanceof SVGImageElement;
  } catch {
    return !1;
  }
}
function Ke(c) {
  try {
    return c instanceof HTMLVideoElement;
  } catch {
    return !1;
  }
}
function tr(c) {
  try {
    return c instanceof HTMLCanvasElement;
  } catch {
    return !1;
  }
}
function er(c) {
  try {
    return c instanceof ImageBitmap;
  } catch {
    return !1;
  }
}
function rr(c) {
  try {
    return c instanceof OffscreenCanvas;
  } catch {
    return !1;
  }
}
function nr(c) {
  try {
    return c instanceof VideoFrame;
  } catch {
    return !1;
  }
}
function ar(c) {
  try {
    return c instanceof Blob;
  } catch {
    return !1;
  }
}
function Fa(c) {
  try {
    return c instanceof ImageData;
  } catch {
    return !1;
  }
}
function Ma(c, p) {
  try {
    const i = new OffscreenCanvas(c, p);
    if (i.getContext("2d") instanceof OffscreenCanvasRenderingContext2D)
      return i;
    throw void 0;
  } catch {
    const i = document.createElement("canvas");
    return i.width = c, i.height = p, i;
  }
}
async function or(c) {
  if (Qe(c) && !await Ra(c))
    throw new DOMException(
      "Failed to load or decode HTMLImageElement.",
      "InvalidStateError"
    );
  if (Ze(c) && !await Wa(c))
    throw new DOMException(
      "Failed to load or decode SVGImageElement.",
      "InvalidStateError"
    );
  if (nr(c) && ka(c))
    throw new DOMException("VideoFrame is closed.", "InvalidStateError");
  if (Ke(c) && (c.readyState === 0 || c.readyState === 1))
    throw new DOMException("Invalid element or state.", "InvalidStateError");
  if (er(c) && Ua(c))
    throw new DOMException(
      "The image source is detached.",
      "InvalidStateError"
    );
  const { width: p, height: i } = Oa(c);
  if (p === 0 || i === 0)
    return null;
  const $ = Ma(p, i).getContext("2d");
  $.drawImage(c, 0, 0);
  try {
    return $.getImageData(0, 0, p, i);
  } catch {
    throw new DOMException("Source would taint origin.", "SecurityError");
  }
}
async function ja(c) {
  let p;
  try {
    if (createImageBitmap)
      p = await createImageBitmap(c);
    else if (Image) {
      p = new Image();
      let v = "";
      try {
        v = URL.createObjectURL(c), p.src = v, await p.decode();
      } finally {
        URL.revokeObjectURL(v);
      }
    } else
      return c;
  } catch {
    throw new DOMException(
      "Failed to load or decode Blob.",
      "InvalidStateError"
    );
  }
  return await or(p);
}
function Ia(c) {
  const { width: p, height: i } = c;
  if (p === 0 || i === 0)
    return null;
  const v = c.getContext("2d");
  try {
    return v.getImageData(0, 0, p, i);
  } catch {
    throw new DOMException("Source would taint origin.", "SecurityError");
  }
}
async function Ha(c) {
  if (ar(c))
    return await ja(c);
  if (Fa(c)) {
    if (Ba(c))
      throw new DOMException(
        "The image data has been detached.",
        "InvalidStateError"
      );
    return c;
  }
  return tr(c) || rr(c) ? Ia(c) : await or(c);
}
async function Ra(c) {
  try {
    return await c.decode(), !0;
  } catch {
    return !1;
  }
}
async function Wa(c) {
  var p;
  try {
    return await ((p = c.decode) == null ? void 0 : p.call(c)), !0;
  } catch {
    return !1;
  }
}
function ka(c) {
  return c.format === null;
}
function Ba(c) {
  return c.data.buffer.byteLength === 0;
}
function Ua(c) {
  return c.width === 0 && c.height === 0;
}
function Ge(c, p) {
  return c instanceof DOMException ? new DOMException(`${p}: ${c.message}`, c.name) : c instanceof Error ? new c.constructor(`${p}: ${c.message}`) : new Error(`${p}: ${c}`);
}
const Xe = (c) => {
  let p;
  const i = /* @__PURE__ */ new Set(), v = (O, Y) => {
    const j = typeof O == "function" ? O(p) : O;
    if (!Object.is(j, p)) {
      const F = p;
      p = Y ?? typeof j != "object" ? j : Object.assign({}, p, j), i.forEach((L) => L(p, F));
    }
  }, $ = () => p, w = { setState: v, getState: $, subscribe: (O) => (i.add(O), () => i.delete(O)), destroy: () => {
    i.clear();
  } };
  return p = c(v, $, w), w;
}, Va = (c) => c ? Xe(c) : Xe, La = {
  locateFile: (c, p) => {
    var i;
    const v = (i = c.match(/_(.+?)\.wasm$/)) == null ? void 0 : i[1];
    return v ? `https://fastly.jsdelivr.net/npm/@sec-ant/zxing-wasm@2.1.5/dist/${v}/${c}` : p + c;
  }
}, st = Va()(() => ({
  zxingModuleWeakMap: /* @__PURE__ */ new WeakMap(),
  zxingModuleOverrides: La
}));
function Qa(c) {
  st.setState({
    zxingModuleOverrides: c
  });
}
function Qt(c, p = st.getState().zxingModuleOverrides) {
  const { zxingModuleWeakMap: i } = st.getState(), v = i.get(
    c
  );
  if (v && Object.is(p, st.getState().zxingModuleOverrides))
    return v;
  {
    st.setState({
      zxingModuleOverrides: p
    });
    const $ = c(p);
    return i.set(c, $), $;
  }
}
const qe = [
  "Aztec",
  "Codabar",
  "Code128",
  "Code39",
  "Code93",
  "DataBar",
  "DataBarExpanded",
  "DataMatrix",
  "EAN-13",
  "EAN-8",
  "ITF",
  "Linear-Codes",
  "Matrix-Codes",
  "MaxiCode",
  "MicroQRCode",
  "None",
  "PDF417",
  "QRCode",
  "UPC-A",
  "UPC-E"
], U = {
  tryHarder: !0,
  formats: [],
  maxSymbols: 255
};
async function za(c, {
  tryHarder: p = U.tryHarder,
  formats: i = U.formats,
  maxSymbols: v = U.maxSymbols
} = U, $) {
  const w = await Qt(
    $,
    st.getState().zxingModuleOverrides
  ), { size: O } = c, Y = new Uint8Array(await c.arrayBuffer()), j = w._malloc(O);
  w.HEAP8.set(Y, j);
  const F = w.readBarcodesFromImage(
    j,
    O,
    p,
    ir(i),
    v
  );
  w._free(j);
  const L = [];
  for (let z = 0; z < F.size(); ++z) {
    const V = F.get(z);
    L.push({
      ...V,
      format: sr(V.format)
    });
  }
  return L;
}
async function Ya(c, {
  tryHarder: p = U.tryHarder,
  formats: i = U.formats,
  maxSymbols: v = U.maxSymbols
} = U, $) {
  const w = await Qt(
    $,
    st.getState().zxingModuleOverrides
  ), {
    data: O,
    width: Y,
    height: j,
    data: { byteLength: F }
  } = c, L = w._malloc(F);
  w.HEAP8.set(O, L);
  const z = w.readBarcodesFromPixmap(
    L,
    Y,
    j,
    p,
    ir(i),
    v
  );
  w._free(L);
  const V = [];
  for (let N = 0; N < z.size(); ++N) {
    const J = z.get(N);
    V.push({
      ...J,
      format: sr(J.format)
    });
  }
  return V;
}
function ir(c) {
  return c.join("|");
}
function sr(c) {
  const p = Je(c);
  let i = 0, v = qe.length - 1;
  for (; i <= v; ) {
    const $ = Math.floor((i + v) / 2), w = qe[$], O = Je(w);
    if (O === p)
      return w;
    O < p ? i = $ + 1 : v = $ - 1;
  }
  return "None";
}
function Je(c) {
  return c.toLowerCase().replace(/_-\[\]/g, "");
}
var Zt = (() => {
  var c = import.meta.url;
  return function(p = {}) {
    var i = p, v, $;
    i.ready = new Promise((t, e) => {
      v = t, $ = e;
    });
    var w = Object.assign({}, i), O = "./this.program", Y = typeof window == "object", j = typeof importScripts == "function";
    typeof process == "object" && typeof process.versions == "object" && process.versions.node;
    var F = "";
    function L(t) {
      return i.locateFile ? i.locateFile(t, F) : F + t;
    }
    var z;
    (Y || j) && (j ? F = self.location.href : typeof document < "u" && document.currentScript && (F = document.currentScript.src), c && (F = c), F.indexOf("blob:") !== 0 ? F = F.substr(0, F.replace(/[?#].*/, "").lastIndexOf("/") + 1) : F = "", j && (z = (t) => {
      var e = new XMLHttpRequest();
      return e.open("GET", t, !1), e.responseType = "arraybuffer", e.send(null), new Uint8Array(e.response);
    })), i.print || console.log.bind(console);
    var V = i.printErr || console.error.bind(console);
    Object.assign(i, w), w = null, i.arguments && i.arguments, i.thisProgram && (O = i.thisProgram), i.quit && i.quit;
    var N;
    i.wasmBinary && (N = i.wasmBinary), i.noExitRuntime, typeof WebAssembly != "object" && bt("no native wasm support detected");
    var J, ft = !1, G, W, dt, $t, k, D, Kt, te;
    function ee() {
      var t = J.buffer;
      i.HEAP8 = G = new Int8Array(t), i.HEAP16 = dt = new Int16Array(t), i.HEAPU8 = W = new Uint8Array(t), i.HEAPU16 = $t = new Uint16Array(t), i.HEAP32 = k = new Int32Array(t), i.HEAPU32 = D = new Uint32Array(t), i.HEAPF32 = Kt = new Float32Array(t), i.HEAPF64 = te = new Float64Array(t);
    }
    var re = [], ne = [], ae = [];
    function ur() {
      if (i.preRun)
        for (typeof i.preRun == "function" && (i.preRun = [i.preRun]); i.preRun.length; )
          fr(i.preRun.shift());
      Ht(re);
    }
    function cr() {
      Ht(ne);
    }
    function lr() {
      if (i.postRun)
        for (typeof i.postRun == "function" && (i.postRun = [i.postRun]); i.postRun.length; )
          hr(i.postRun.shift());
      Ht(ae);
    }
    function fr(t) {
      re.unshift(t);
    }
    function dr(t) {
      ne.unshift(t);
    }
    function hr(t) {
      ae.unshift(t);
    }
    var rt = 0, ht = null;
    function pr(t) {
      rt++, i.monitorRunDependencies && i.monitorRunDependencies(rt);
    }
    function mr(t) {
      if (rt--, i.monitorRunDependencies && i.monitorRunDependencies(rt), rt == 0 && ht) {
        var e = ht;
        ht = null, e();
      }
    }
    function bt(t) {
      i.onAbort && i.onAbort(t), t = "Aborted(" + t + ")", V(t), ft = !0, t += ". Build with -sASSERTIONS for more info.";
      var e = new WebAssembly.RuntimeError(t);
      throw $(e), e;
    }
    var yr = "data:application/octet-stream;base64,";
    function oe(t) {
      return t.startsWith(yr);
    }
    var nt;
    i.locateFile ? (nt = "zxing_reader.wasm", oe(nt) || (nt = L(nt))) : nt = new URL("/reader/zxing_reader.wasm", self.location).href;
    function ie(t) {
      if (t == nt && N)
        return new Uint8Array(N);
      if (z)
        return z(t);
      throw "both async and sync fetching of the wasm failed";
    }
    function vr(t) {
      return !N && (Y || j) && typeof fetch == "function" ? fetch(t, { credentials: "same-origin" }).then((e) => {
        if (!e.ok)
          throw "failed to load wasm binary file at '" + t + "'";
        return e.arrayBuffer();
      }).catch(() => ie(t)) : Promise.resolve().then(() => ie(t));
    }
    function se(t, e, r) {
      return vr(t).then((n) => WebAssembly.instantiate(n, e)).then((n) => n).then(r, (n) => {
        V(`failed to asynchronously prepare wasm: ${n}`), bt(n);
      });
    }
    function gr(t, e, r, n) {
      return !t && typeof WebAssembly.instantiateStreaming == "function" && !oe(e) && typeof fetch == "function" ? fetch(e, { credentials: "same-origin" }).then((a) => {
        var o = WebAssembly.instantiateStreaming(a, r);
        return o.then(n, function(s) {
          return V(`wasm streaming compile failed: ${s}`), V("falling back to ArrayBuffer instantiation"), se(e, r, n);
        });
      }) : se(e, r, n);
    }
    function wr() {
      var t = { a: Zn };
      function e(n, a) {
        return S = n.exports, J = S.qa, ee(), be = S.ua, dr(S.ra), mr(), S;
      }
      pr();
      function r(n) {
        e(n.instance);
      }
      if (i.instantiateWasm)
        try {
          return i.instantiateWasm(t, e);
        } catch (n) {
          V(`Module.instantiateWasm callback failed with error: ${n}`), $(n);
        }
      return gr(N, nt, t, r).catch($), {};
    }
    var Ht = (t) => {
      for (; t.length > 0; )
        t.shift()(i);
    }, Ct = [], _t = 0, $r = (t) => {
      var e = new Tt(t);
      return e.get_caught() || (e.set_caught(!0), _t--), e.set_rethrown(!1), Ct.push(e), Re(e.excPtr), e.get_exception_ptr();
    }, Q = 0, br = () => {
      b(0, 0);
      var t = Ct.pop();
      He(t.excPtr), Q = 0;
    };
    function Tt(t) {
      this.excPtr = t, this.ptr = t - 24, this.set_type = function(e) {
        D[this.ptr + 4 >> 2] = e;
      }, this.get_type = function() {
        return D[this.ptr + 4 >> 2];
      }, this.set_destructor = function(e) {
        D[this.ptr + 8 >> 2] = e;
      }, this.get_destructor = function() {
        return D[this.ptr + 8 >> 2];
      }, this.set_caught = function(e) {
        e = e ? 1 : 0, G[this.ptr + 12 >> 0] = e;
      }, this.get_caught = function() {
        return G[this.ptr + 12 >> 0] != 0;
      }, this.set_rethrown = function(e) {
        e = e ? 1 : 0, G[this.ptr + 13 >> 0] = e;
      }, this.get_rethrown = function() {
        return G[this.ptr + 13 >> 0] != 0;
      }, this.init = function(e, r) {
        this.set_adjusted_ptr(0), this.set_type(e), this.set_destructor(r);
      }, this.set_adjusted_ptr = function(e) {
        D[this.ptr + 16 >> 2] = e;
      }, this.get_adjusted_ptr = function() {
        return D[this.ptr + 16 >> 2];
      }, this.get_exception_ptr = function() {
        var e = ke(this.get_type());
        if (e)
          return D[this.excPtr >> 2];
        var r = this.get_adjusted_ptr();
        return r !== 0 ? r : this.excPtr;
      };
    }
    var Cr = (t) => {
      throw Q || (Q = t), Q;
    }, Rt = (t) => {
      var e = Q;
      if (!e)
        return wt(0), 0;
      var r = new Tt(e);
      r.set_adjusted_ptr(e);
      var n = r.get_type();
      if (!n)
        return wt(0), e;
      for (var a in t) {
        var o = t[a];
        if (o === 0 || o === n)
          break;
        var s = r.ptr + 16;
        if (We(o, n, s))
          return wt(o), e;
      }
      return wt(n), e;
    }, _r = () => Rt([]), Tr = (t) => Rt([t]), Pr = (t, e) => Rt([t, e]), Er = (t) => {
      var e = new Tt(t).get_exception_ptr();
      return e;
    }, xr = () => {
      var t = Ct.pop();
      t || bt("no exception to throw");
      var e = t.excPtr;
      throw t.get_rethrown() || (Ct.push(t), t.set_rethrown(!0), t.set_caught(!1), _t++), Q = e, Q;
    }, Ar = (t, e, r) => {
      var n = new Tt(t);
      throw n.init(e, r), Q = t, _t++, Q;
    }, Dr = () => _t, Pt = {}, ue = (t) => {
      for (; t.length; ) {
        var e = t.pop(), r = t.pop();
        r(e);
      }
    };
    function Wt(t) {
      return this.fromWireType(k[t >> 2]);
    }
    var ut = {}, at = {}, Et = {}, ce, xt = (t) => {
      throw new ce(t);
    }, ot = (t, e, r) => {
      t.forEach(function(u) {
        Et[u] = e;
      });
      function n(u) {
        var l = r(u);
        l.length !== t.length && xt("Mismatched type converter count");
        for (var f = 0; f < t.length; ++f)
          Z(t[f], l[f]);
      }
      var a = new Array(e.length), o = [], s = 0;
      e.forEach((u, l) => {
        at.hasOwnProperty(u) ? a[l] = at[u] : (o.push(u), ut.hasOwnProperty(u) || (ut[u] = []), ut[u].push(() => {
          a[l] = at[u], ++s, s === o.length && n(a);
        }));
      }), o.length === 0 && n(a);
    }, Sr = (t) => {
      var e = Pt[t];
      delete Pt[t];
      var r = e.rawConstructor, n = e.rawDestructor, a = e.fields, o = a.map((s) => s.getterReturnType).concat(a.map((s) => s.setterArgumentType));
      ot([t], o, (s) => {
        var u = {};
        return a.forEach((l, f) => {
          var h = l.fieldName, y = s[f], g = l.getter, T = l.getterContext, x = s[f + a.length], H = l.setter, A = l.setterContext;
          u[h] = { read: (R) => y.fromWireType(g(T, R)), write: (R, d) => {
            var m = [];
            H(A, R, x.toWireType(m, d)), ue(m);
          } };
        }), [{ name: e.name, fromWireType: (l) => {
          var f = {};
          for (var h in u)
            f[h] = u[h].read(l);
          return n(l), f;
        }, toWireType: (l, f) => {
          for (var h in u)
            if (!(h in f))
              throw new TypeError(`Missing field: "${h}"`);
          var y = r();
          for (h in u)
            u[h].write(y, f[h]);
          return l !== null && l.push(n, y), y;
        }, argPackAdvance: K, readValueFromPointer: Wt, destructorFunction: n }];
      });
    }, Or = (t, e, r, n, a) => {
    }, Fr = () => {
      for (var t = new Array(256), e = 0; e < 256; ++e)
        t[e] = String.fromCharCode(e);
      le = t;
    }, le, B = (t) => {
      for (var e = "", r = t; W[r]; )
        e += le[W[r++]];
      return e;
    }, ct, P = (t) => {
      throw new ct(t);
    };
    function Mr(t, e, r = {}) {
      var n = e.name;
      if (t || P(`type "${n}" must have a positive integer typeid pointer`), at.hasOwnProperty(t)) {
        if (r.ignoreDuplicateRegistrations)
          return;
        P(`Cannot register type '${n}' twice`);
      }
      if (at[t] = e, delete Et[t], ut.hasOwnProperty(t)) {
        var a = ut[t];
        delete ut[t], a.forEach((o) => o());
      }
    }
    function Z(t, e, r = {}) {
      if (!("argPackAdvance" in e))
        throw new TypeError("registerType registeredInstance requires argPackAdvance");
      return Mr(t, e, r);
    }
    var K = 8, jr = (t, e, r, n) => {
      e = B(e), Z(t, { name: e, fromWireType: function(a) {
        return !!a;
      }, toWireType: function(a, o) {
        return o ? r : n;
      }, argPackAdvance: K, readValueFromPointer: function(a) {
        return this.fromWireType(W[a]);
      }, destructorFunction: null });
    }, Ir = (t) => ({ count: t.count, deleteScheduled: t.deleteScheduled, preservePointerOnDelete: t.preservePointerOnDelete, ptr: t.ptr, ptrType: t.ptrType, smartPtr: t.smartPtr, smartPtrType: t.smartPtrType }), kt = (t) => {
      function e(r) {
        return r.$$.ptrType.registeredClass.name;
      }
      P(e(t) + " instance already deleted");
    }, Bt = !1, fe = (t) => {
    }, Hr = (t) => {
      t.smartPtr ? t.smartPtrType.rawDestructor(t.smartPtr) : t.ptrType.registeredClass.rawDestructor(t.ptr);
    }, de = (t) => {
      t.count.value -= 1;
      var e = t.count.value === 0;
      e && Hr(t);
    }, he = (t, e, r) => {
      if (e === r)
        return t;
      if (r.baseClass === void 0)
        return null;
      var n = he(t, e, r.baseClass);
      return n === null ? null : r.downcast(n);
    }, pe = {}, Rr = () => Object.keys(yt).length, Wr = () => {
      var t = [];
      for (var e in yt)
        yt.hasOwnProperty(e) && t.push(yt[e]);
      return t;
    }, pt = [], Ut = () => {
      for (; pt.length; ) {
        var t = pt.pop();
        t.$$.deleteScheduled = !1, t.delete();
      }
    }, mt, kr = (t) => {
      mt = t, pt.length && mt && mt(Ut);
    }, Br = () => {
      i.getInheritedInstanceCount = Rr, i.getLiveInheritedInstances = Wr, i.flushPendingDeletes = Ut, i.setDelayFunction = kr;
    }, yt = {}, Ur = (t, e) => {
      for (e === void 0 && P("ptr should not be undefined"); t.baseClass; )
        e = t.upcast(e), t = t.baseClass;
      return e;
    }, Vr = (t, e) => (e = Ur(t, e), yt[e]), At = (t, e) => {
      (!e.ptrType || !e.ptr) && xt("makeClassHandle requires ptr and ptrType");
      var r = !!e.smartPtrType, n = !!e.smartPtr;
      return r !== n && xt("Both smartPtrType and smartPtr must be specified"), e.count = { value: 1 }, vt(Object.create(t, { $$: { value: e } }));
    };
    function Lr(t) {
      var e = this.getPointee(t);
      if (!e)
        return this.destructor(t), null;
      var r = Vr(this.registeredClass, e);
      if (r !== void 0) {
        if (r.$$.count.value === 0)
          return r.$$.ptr = e, r.$$.smartPtr = t, r.clone();
        var n = r.clone();
        return this.destructor(t), n;
      }
      function a() {
        return this.isSmartPointer ? At(this.registeredClass.instancePrototype, { ptrType: this.pointeeType, ptr: e, smartPtrType: this, smartPtr: t }) : At(this.registeredClass.instancePrototype, { ptrType: this, ptr: t });
      }
      var o = this.registeredClass.getActualType(e), s = pe[o];
      if (!s)
        return a.call(this);
      var u;
      this.isConst ? u = s.constPointerType : u = s.pointerType;
      var l = he(e, this.registeredClass, u.registeredClass);
      return l === null ? a.call(this) : this.isSmartPointer ? At(u.registeredClass.instancePrototype, { ptrType: u, ptr: l, smartPtrType: this, smartPtr: t }) : At(u.registeredClass.instancePrototype, { ptrType: u, ptr: l });
    }
    var vt = (t) => typeof FinalizationRegistry > "u" ? (vt = (e) => e, t) : (Bt = new FinalizationRegistry((e) => {
      de(e.$$);
    }), vt = (e) => {
      var r = e.$$, n = !!r.smartPtr;
      if (n) {
        var a = { $$: r };
        Bt.register(e, a, e);
      }
      return e;
    }, fe = (e) => Bt.unregister(e), vt(t)), zr = () => {
      Object.assign(Dt.prototype, { isAliasOf(t) {
        if (!(this instanceof Dt) || !(t instanceof Dt))
          return !1;
        var e = this.$$.ptrType.registeredClass, r = this.$$.ptr;
        t.$$ = t.$$;
        for (var n = t.$$.ptrType.registeredClass, a = t.$$.ptr; e.baseClass; )
          r = e.upcast(r), e = e.baseClass;
        for (; n.baseClass; )
          a = n.upcast(a), n = n.baseClass;
        return e === n && r === a;
      }, clone() {
        if (this.$$.ptr || kt(this), this.$$.preservePointerOnDelete)
          return this.$$.count.value += 1, this;
        var t = vt(Object.create(Object.getPrototypeOf(this), { $$: { value: Ir(this.$$) } }));
        return t.$$.count.value += 1, t.$$.deleteScheduled = !1, t;
      }, delete() {
        this.$$.ptr || kt(this), this.$$.deleteScheduled && !this.$$.preservePointerOnDelete && P("Object already scheduled for deletion"), fe(this), de(this.$$), this.$$.preservePointerOnDelete || (this.$$.smartPtr = void 0, this.$$.ptr = void 0);
      }, isDeleted() {
        return !this.$$.ptr;
      }, deleteLater() {
        return this.$$.ptr || kt(this), this.$$.deleteScheduled && !this.$$.preservePointerOnDelete && P("Object already scheduled for deletion"), pt.push(this), pt.length === 1 && mt && mt(Ut), this.$$.deleteScheduled = !0, this;
      } });
    };
    function Dt() {
    }
    var Yr = 48, Nr = 57, me = (t) => {
      if (t === void 0)
        return "_unknown";
      t = t.replace(/[^a-zA-Z0-9_]/g, "$");
      var e = t.charCodeAt(0);
      return e >= Yr && e <= Nr ? `_${t}` : t;
    };
    function ye(t, e) {
      return t = me(t), { [t]: function() {
        return e.apply(this, arguments);
      } }[t];
    }
    var ve = (t, e, r) => {
      if (t[e].overloadTable === void 0) {
        var n = t[e];
        t[e] = function() {
          return t[e].overloadTable.hasOwnProperty(arguments.length) || P(`Function '${r}' called with an invalid number of arguments (${arguments.length}) - expects one of (${t[e].overloadTable})!`), t[e].overloadTable[arguments.length].apply(this, arguments);
        }, t[e].overloadTable = [], t[e].overloadTable[n.argCount] = n;
      }
    }, ge = (t, e, r) => {
      i.hasOwnProperty(t) ? ((r === void 0 || i[t].overloadTable !== void 0 && i[t].overloadTable[r] !== void 0) && P(`Cannot register public name '${t}' twice`), ve(i, t, t), i.hasOwnProperty(r) && P(`Cannot register multiple overloads of a function with the same number of arguments (${r})!`), i[t].overloadTable[r] = e) : (i[t] = e, r !== void 0 && (i[t].numArguments = r));
    };
    function Gr(t, e, r, n, a, o, s, u) {
      this.name = t, this.constructor = e, this.instancePrototype = r, this.rawDestructor = n, this.baseClass = a, this.getActualType = o, this.upcast = s, this.downcast = u, this.pureVirtualFunctions = [];
    }
    var Vt = (t, e, r) => {
      for (; e !== r; )
        e.upcast || P(`Expected null or instance of ${r.name}, got an instance of ${e.name}`), t = e.upcast(t), e = e.baseClass;
      return t;
    };
    function Xr(t, e) {
      if (e === null)
        return this.isReference && P(`null is not a valid ${this.name}`), 0;
      e.$$ || P(`Cannot pass "${Yt(e)}" as a ${this.name}`), e.$$.ptr || P(`Cannot pass deleted object as a pointer of type ${this.name}`);
      var r = e.$$.ptrType.registeredClass, n = Vt(e.$$.ptr, r, this.registeredClass);
      return n;
    }
    function qr(t, e) {
      var r;
      if (e === null)
        return this.isReference && P(`null is not a valid ${this.name}`), this.isSmartPointer ? (r = this.rawConstructor(), t !== null && t.push(this.rawDestructor, r), r) : 0;
      e.$$ || P(`Cannot pass "${Yt(e)}" as a ${this.name}`), e.$$.ptr || P(`Cannot pass deleted object as a pointer of type ${this.name}`), !this.isConst && e.$$.ptrType.isConst && P(`Cannot convert argument of type ${e.$$.smartPtrType ? e.$$.smartPtrType.name : e.$$.ptrType.name} to parameter type ${this.name}`);
      var n = e.$$.ptrType.registeredClass;
      if (r = Vt(e.$$.ptr, n, this.registeredClass), this.isSmartPointer)
        switch (e.$$.smartPtr === void 0 && P("Passing raw pointer to smart pointer is illegal"), this.sharingPolicy) {
          case 0:
            e.$$.smartPtrType === this ? r = e.$$.smartPtr : P(`Cannot convert argument of type ${e.$$.smartPtrType ? e.$$.smartPtrType.name : e.$$.ptrType.name} to parameter type ${this.name}`);
            break;
          case 1:
            r = e.$$.smartPtr;
            break;
          case 2:
            if (e.$$.smartPtrType === this)
              r = e.$$.smartPtr;
            else {
              var a = e.clone();
              r = this.rawShare(r, et.toHandle(() => a.delete())), t !== null && t.push(this.rawDestructor, r);
            }
            break;
          default:
            P("Unsupporting sharing policy");
        }
      return r;
    }
    function Jr(t, e) {
      if (e === null)
        return this.isReference && P(`null is not a valid ${this.name}`), 0;
      e.$$ || P(`Cannot pass "${Yt(e)}" as a ${this.name}`), e.$$.ptr || P(`Cannot pass deleted object as a pointer of type ${this.name}`), e.$$.ptrType.isConst && P(`Cannot convert argument of type ${e.$$.ptrType.name} to parameter type ${this.name}`);
      var r = e.$$.ptrType.registeredClass, n = Vt(e.$$.ptr, r, this.registeredClass);
      return n;
    }
    function we(t) {
      return this.fromWireType(D[t >> 2]);
    }
    var Qr = () => {
      Object.assign(St.prototype, { getPointee(t) {
        return this.rawGetPointee && (t = this.rawGetPointee(t)), t;
      }, destructor(t) {
        this.rawDestructor && this.rawDestructor(t);
      }, argPackAdvance: K, readValueFromPointer: we, deleteObject(t) {
        t !== null && t.delete();
      }, fromWireType: Lr });
    };
    function St(t, e, r, n, a, o, s, u, l, f, h) {
      this.name = t, this.registeredClass = e, this.isReference = r, this.isConst = n, this.isSmartPointer = a, this.pointeeType = o, this.sharingPolicy = s, this.rawGetPointee = u, this.rawConstructor = l, this.rawShare = f, this.rawDestructor = h, !a && e.baseClass === void 0 ? n ? (this.toWireType = Xr, this.destructorFunction = null) : (this.toWireType = Jr, this.destructorFunction = null) : this.toWireType = qr;
    }
    var $e = (t, e, r) => {
      i.hasOwnProperty(t) || xt("Replacing nonexistant public symbol"), i[t].overloadTable !== void 0 && r !== void 0 ? i[t].overloadTable[r] = e : (i[t] = e, i[t].argCount = r);
    }, Zr = (t, e, r) => {
      var n = i["dynCall_" + t];
      return r && r.length ? n.apply(null, [e].concat(r)) : n.call(null, e);
    }, Ot = [], be, E = (t) => {
      var e = Ot[t];
      return e || (t >= Ot.length && (Ot.length = t + 1), Ot[t] = e = be.get(t)), e;
    }, Kr = (t, e, r) => {
      if (t.includes("j"))
        return Zr(t, e, r);
      var n = E(e).apply(null, r);
      return n;
    }, tn = (t, e) => {
      var r = [];
      return function() {
        return r.length = 0, Object.assign(r, arguments), Kr(t, e, r);
      };
    }, q = (t, e) => {
      t = B(t);
      function r() {
        return t.includes("j") ? tn(t, e) : E(e);
      }
      var n = r();
      return typeof n != "function" && P(`unknown function pointer with signature ${t}: ${e}`), n;
    }, en = (t, e) => {
      var r = ye(e, function(n) {
        this.name = e, this.message = n;
        var a = new Error(n).stack;
        a !== void 0 && (this.stack = this.toString() + `
` + a.replace(/^Error(:[^\n]*)?\n/, ""));
      });
      return r.prototype = Object.create(t.prototype), r.prototype.constructor = r, r.prototype.toString = function() {
        return this.message === void 0 ? this.name : `${this.name}: ${this.message}`;
      }, r;
    }, Ce, _e = (t) => {
      var e = Ie(t), r = B(e);
      return tt(e), r;
    }, Ft = (t, e) => {
      var r = [], n = {};
      function a(o) {
        if (!n[o] && !at[o]) {
          if (Et[o]) {
            Et[o].forEach(a);
            return;
          }
          r.push(o), n[o] = !0;
        }
      }
      throw e.forEach(a), new Ce(`${t}: ` + r.map(_e).join([", "]));
    }, rn = (t, e, r, n, a, o, s, u, l, f, h, y, g) => {
      h = B(h), o = q(a, o), u && (u = q(s, u)), f && (f = q(l, f)), g = q(y, g);
      var T = me(h);
      ge(T, function() {
        Ft(`Cannot construct ${h} due to unbound types`, [n]);
      }), ot([t, e, r], n ? [n] : [], function(x) {
        x = x[0];
        var H, A;
        n ? (H = x.registeredClass, A = H.instancePrototype) : A = Dt.prototype;
        var R = ye(T, function() {
          if (Object.getPrototypeOf(this) !== d)
            throw new ct("Use 'new' to construct " + h);
          if (m.constructor_body === void 0)
            throw new ct(h + " has no accessible constructor");
          var It = m.constructor_body[arguments.length];
          if (It === void 0)
            throw new ct(`Tried to invoke ctor of ${h} with invalid number of parameters (${arguments.length}) - expected (${Object.keys(m.constructor_body).toString()}) parameters instead!`);
          return It.apply(this, arguments);
        }), d = Object.create(A, { constructor: { value: R } });
        R.prototype = d;
        var m = new Gr(h, R, d, g, H, o, u, f);
        m.baseClass && (m.baseClass.__derivedClasses === void 0 && (m.baseClass.__derivedClasses = []), m.baseClass.__derivedClasses.push(m));
        var M = new St(h, m, !0, !1, !1), I = new St(h + "*", m, !1, !1, !1), it = new St(h + " const*", m, !1, !0, !1);
        return pe[t] = { pointerType: I, constPointerType: it }, $e(T, R), [M, I, it];
      });
    }, Lt = (t, e) => {
      for (var r = [], n = 0; n < t; n++)
        r.push(D[e + n * 4 >> 2]);
      return r;
    };
    function zt(t, e, r, n, a, o) {
      var s = e.length;
      s < 2 && P("argTypes array size mismatch! Must at least get return value and 'this' types!");
      for (var u = e[1] !== null && r !== null, l = !1, f = 1; f < e.length; ++f)
        if (e[f] !== null && e[f].destructorFunction === void 0) {
          l = !0;
          break;
        }
      var h = e[0].name !== "void", y = s - 2, g = new Array(y), T = [], x = [];
      return function() {
        arguments.length !== y && P(`function ${t} called with ${arguments.length} arguments, expected ${y}`), x.length = 0;
        var H;
        T.length = u ? 2 : 1, T[0] = a, u && (H = e[1].toWireType(x, this), T[1] = H);
        for (var A = 0; A < y; ++A)
          g[A] = e[A + 2].toWireType(x, arguments[A]), T.push(g[A]);
        var R = n.apply(null, T);
        function d(m) {
          if (l)
            ue(x);
          else
            for (var M = u ? 1 : 2; M < e.length; M++) {
              var I = M === 1 ? H : g[M - 2];
              e[M].destructorFunction !== null && e[M].destructorFunction(I);
            }
          if (h)
            return e[0].fromWireType(m);
        }
        return d(R);
      };
    }
    var nn = (t, e, r, n, a, o) => {
      var s = Lt(e, r);
      a = q(n, a), ot([], [t], function(u) {
        u = u[0];
        var l = `constructor ${u.name}`;
        if (u.registeredClass.constructor_body === void 0 && (u.registeredClass.constructor_body = []), u.registeredClass.constructor_body[e - 1] !== void 0)
          throw new ct(`Cannot register multiple constructors with identical number of parameters (${e - 1}) for class '${u.name}'! Overload resolution is currently only performed using the parameter count, not actual type info!`);
        return u.registeredClass.constructor_body[e - 1] = () => {
          Ft(`Cannot construct ${u.name} due to unbound types`, s);
        }, ot([], s, (f) => (f.splice(1, 0, null), u.registeredClass.constructor_body[e - 1] = zt(l, f, null, a, o), [])), [];
      });
    }, an = (t, e, r, n, a, o, s, u, l) => {
      var f = Lt(r, n);
      e = B(e), o = q(a, o), ot([], [t], function(h) {
        h = h[0];
        var y = `${h.name}.${e}`;
        e.startsWith("@@") && (e = Symbol[e.substring(2)]), u && h.registeredClass.pureVirtualFunctions.push(e);
        function g() {
          Ft(`Cannot call ${y} due to unbound types`, f);
        }
        var T = h.registeredClass.instancePrototype, x = T[e];
        return x === void 0 || x.overloadTable === void 0 && x.className !== h.name && x.argCount === r - 2 ? (g.argCount = r - 2, g.className = h.name, T[e] = g) : (ve(T, e, y), T[e].overloadTable[r - 2] = g), ot([], f, function(H) {
          var A = zt(y, H, h, o, s);
          return T[e].overloadTable === void 0 ? (A.argCount = r - 2, T[e] = A) : T[e].overloadTable[r - 2] = A, [];
        }), [];
      });
    };
    function on() {
      Object.assign(Te.prototype, { get(t) {
        return this.allocated[t];
      }, has(t) {
        return this.allocated[t] !== void 0;
      }, allocate(t) {
        var e = this.freelist.pop() || this.allocated.length;
        return this.allocated[e] = t, e;
      }, free(t) {
        this.allocated[t] = void 0, this.freelist.push(t);
      } });
    }
    function Te() {
      this.allocated = [void 0], this.freelist = [];
    }
    var X = new Te(), Pe = (t) => {
      t >= X.reserved && --X.get(t).refcount === 0 && X.free(t);
    }, sn = () => {
      for (var t = 0, e = X.reserved; e < X.allocated.length; ++e)
        X.allocated[e] !== void 0 && ++t;
      return t;
    }, un = () => {
      X.allocated.push({ value: void 0 }, { value: null }, { value: !0 }, { value: !1 }), X.reserved = X.allocated.length, i.count_emval_handles = sn;
    }, et = { toValue: (t) => (t || P("Cannot use deleted val. handle = " + t), X.get(t).value), toHandle: (t) => {
      switch (t) {
        case void 0:
          return 1;
        case null:
          return 2;
        case !0:
          return 3;
        case !1:
          return 4;
        default:
          return X.allocate({ refcount: 1, value: t });
      }
    } }, cn = (t, e) => {
      e = B(e), Z(t, { name: e, fromWireType: (r) => {
        var n = et.toValue(r);
        return Pe(r), n;
      }, toWireType: (r, n) => et.toHandle(n), argPackAdvance: K, readValueFromPointer: Wt, destructorFunction: null });
    }, Yt = (t) => {
      if (t === null)
        return "null";
      var e = typeof t;
      return e === "object" || e === "array" || e === "function" ? t.toString() : "" + t;
    }, ln = (t, e) => {
      switch (e) {
        case 4:
          return function(r) {
            return this.fromWireType(Kt[r >> 2]);
          };
        case 8:
          return function(r) {
            return this.fromWireType(te[r >> 3]);
          };
        default:
          throw new TypeError(`invalid float width (${e}): ${t}`);
      }
    }, fn = (t, e, r) => {
      e = B(e), Z(t, { name: e, fromWireType: (n) => n, toWireType: (n, a) => a, argPackAdvance: K, readValueFromPointer: ln(e, r), destructorFunction: null });
    }, dn = (t, e, r, n, a, o, s) => {
      var u = Lt(e, r);
      t = B(t), a = q(n, a), ge(t, function() {
        Ft(`Cannot call ${t} due to unbound types`, u);
      }, e - 1), ot([], u, function(l) {
        var f = [l[0], null].concat(l.slice(1));
        return $e(t, zt(t, f, null, a, o), e - 1), [];
      });
    }, hn = (t, e, r) => {
      switch (e) {
        case 1:
          return r ? (n) => G[n >> 0] : (n) => W[n >> 0];
        case 2:
          return r ? (n) => dt[n >> 1] : (n) => $t[n >> 1];
        case 4:
          return r ? (n) => k[n >> 2] : (n) => D[n >> 2];
        default:
          throw new TypeError(`invalid integer width (${e}): ${t}`);
      }
    }, pn = (t, e, r, n, a) => {
      e = B(e);
      var o = (h) => h;
      if (n === 0) {
        var s = 32 - 8 * r;
        o = (h) => h << s >>> s;
      }
      var u = e.includes("unsigned"), l = (h, y) => {
      }, f;
      u ? f = function(h, y) {
        return l(y, this.name), y >>> 0;
      } : f = function(h, y) {
        return l(y, this.name), y;
      }, Z(t, { name: e, fromWireType: o, toWireType: f, argPackAdvance: K, readValueFromPointer: hn(e, r, n !== 0), destructorFunction: null });
    }, mn = (t, e, r) => {
      var n = [Int8Array, Uint8Array, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array], a = n[e];
      function o(s) {
        var u = D[s >> 2], l = D[s + 4 >> 2];
        return new a(G.buffer, l, u);
      }
      r = B(r), Z(t, { name: r, fromWireType: o, argPackAdvance: K, readValueFromPointer: o }, { ignoreDuplicateRegistrations: !0 });
    }, Ee = (t, e, r, n) => {
      if (!(n > 0))
        return 0;
      for (var a = r, o = r + n - 1, s = 0; s < t.length; ++s) {
        var u = t.charCodeAt(s);
        if (u >= 55296 && u <= 57343) {
          var l = t.charCodeAt(++s);
          u = 65536 + ((u & 1023) << 10) | l & 1023;
        }
        if (u <= 127) {
          if (r >= o)
            break;
          e[r++] = u;
        } else if (u <= 2047) {
          if (r + 1 >= o)
            break;
          e[r++] = 192 | u >> 6, e[r++] = 128 | u & 63;
        } else if (u <= 65535) {
          if (r + 2 >= o)
            break;
          e[r++] = 224 | u >> 12, e[r++] = 128 | u >> 6 & 63, e[r++] = 128 | u & 63;
        } else {
          if (r + 3 >= o)
            break;
          e[r++] = 240 | u >> 18, e[r++] = 128 | u >> 12 & 63, e[r++] = 128 | u >> 6 & 63, e[r++] = 128 | u & 63;
        }
      }
      return e[r] = 0, r - a;
    }, yn = (t, e, r) => Ee(t, W, e, r), xe = (t) => {
      for (var e = 0, r = 0; r < t.length; ++r) {
        var n = t.charCodeAt(r);
        n <= 127 ? e++ : n <= 2047 ? e += 2 : n >= 55296 && n <= 57343 ? (e += 4, ++r) : e += 3;
      }
      return e;
    }, Ae = typeof TextDecoder < "u" ? new TextDecoder("utf8") : void 0, vn = (t, e, r) => {
      for (var n = e + r, a = e; t[a] && !(a >= n); )
        ++a;
      if (a - e > 16 && t.buffer && Ae)
        return Ae.decode(t.subarray(e, a));
      for (var o = ""; e < a; ) {
        var s = t[e++];
        if (!(s & 128)) {
          o += String.fromCharCode(s);
          continue;
        }
        var u = t[e++] & 63;
        if ((s & 224) == 192) {
          o += String.fromCharCode((s & 31) << 6 | u);
          continue;
        }
        var l = t[e++] & 63;
        if ((s & 240) == 224 ? s = (s & 15) << 12 | u << 6 | l : s = (s & 7) << 18 | u << 12 | l << 6 | t[e++] & 63, s < 65536)
          o += String.fromCharCode(s);
        else {
          var f = s - 65536;
          o += String.fromCharCode(55296 | f >> 10, 56320 | f & 1023);
        }
      }
      return o;
    }, Nt = (t, e) => t ? vn(W, t, e) : "", gn = (t, e) => {
      e = B(e);
      var r = e === "std::string";
      Z(t, { name: e, fromWireType(n) {
        var a = D[n >> 2], o = n + 4, s;
        if (r)
          for (var u = o, l = 0; l <= a; ++l) {
            var f = o + l;
            if (l == a || W[f] == 0) {
              var h = f - u, y = Nt(u, h);
              s === void 0 ? s = y : (s += String.fromCharCode(0), s += y), u = f + 1;
            }
          }
        else {
          for (var g = new Array(a), l = 0; l < a; ++l)
            g[l] = String.fromCharCode(W[o + l]);
          s = g.join("");
        }
        return tt(n), s;
      }, toWireType(n, a) {
        a instanceof ArrayBuffer && (a = new Uint8Array(a));
        var o, s = typeof a == "string";
        s || a instanceof Uint8Array || a instanceof Uint8ClampedArray || a instanceof Int8Array || P("Cannot pass non-string to std::string"), r && s ? o = xe(a) : o = a.length;
        var u = Xt(4 + o + 1), l = u + 4;
        if (D[u >> 2] = o, r && s)
          yn(a, l, o + 1);
        else if (s)
          for (var f = 0; f < o; ++f) {
            var h = a.charCodeAt(f);
            h > 255 && (tt(l), P("String has UTF-16 code units that do not fit in 8 bits")), W[l + f] = h;
          }
        else
          for (var f = 0; f < o; ++f)
            W[l + f] = a[f];
        return n !== null && n.push(tt, u), u;
      }, argPackAdvance: K, readValueFromPointer: we, destructorFunction(n) {
        tt(n);
      } });
    }, De = typeof TextDecoder < "u" ? new TextDecoder("utf-16le") : void 0, wn = (t, e) => {
      for (var r = t, n = r >> 1, a = n + e / 2; !(n >= a) && $t[n]; )
        ++n;
      if (r = n << 1, r - t > 32 && De)
        return De.decode(W.subarray(t, r));
      for (var o = "", s = 0; !(s >= e / 2); ++s) {
        var u = dt[t + s * 2 >> 1];
        if (u == 0)
          break;
        o += String.fromCharCode(u);
      }
      return o;
    }, $n = (t, e, r) => {
      if (r === void 0 && (r = 2147483647), r < 2)
        return 0;
      r -= 2;
      for (var n = e, a = r < t.length * 2 ? r / 2 : t.length, o = 0; o < a; ++o) {
        var s = t.charCodeAt(o);
        dt[e >> 1] = s, e += 2;
      }
      return dt[e >> 1] = 0, e - n;
    }, bn = (t) => t.length * 2, Cn = (t, e) => {
      for (var r = 0, n = ""; !(r >= e / 4); ) {
        var a = k[t + r * 4 >> 2];
        if (a == 0)
          break;
        if (++r, a >= 65536) {
          var o = a - 65536;
          n += String.fromCharCode(55296 | o >> 10, 56320 | o & 1023);
        } else
          n += String.fromCharCode(a);
      }
      return n;
    }, _n = (t, e, r) => {
      if (r === void 0 && (r = 2147483647), r < 4)
        return 0;
      for (var n = e, a = n + r - 4, o = 0; o < t.length; ++o) {
        var s = t.charCodeAt(o);
        if (s >= 55296 && s <= 57343) {
          var u = t.charCodeAt(++o);
          s = 65536 + ((s & 1023) << 10) | u & 1023;
        }
        if (k[e >> 2] = s, e += 4, e + 4 > a)
          break;
      }
      return k[e >> 2] = 0, e - n;
    }, Tn = (t) => {
      for (var e = 0, r = 0; r < t.length; ++r) {
        var n = t.charCodeAt(r);
        n >= 55296 && n <= 57343 && ++r, e += 4;
      }
      return e;
    }, Pn = (t, e, r) => {
      r = B(r);
      var n, a, o, s, u;
      e === 2 ? (n = wn, a = $n, s = bn, o = () => $t, u = 1) : e === 4 && (n = Cn, a = _n, s = Tn, o = () => D, u = 2), Z(t, { name: r, fromWireType: (l) => {
        for (var f = D[l >> 2], h = o(), y, g = l + 4, T = 0; T <= f; ++T) {
          var x = l + 4 + T * e;
          if (T == f || h[x >> u] == 0) {
            var H = x - g, A = n(g, H);
            y === void 0 ? y = A : (y += String.fromCharCode(0), y += A), g = x + e;
          }
        }
        return tt(l), y;
      }, toWireType: (l, f) => {
        typeof f != "string" && P(`Cannot pass non-string to C++ string type ${r}`);
        var h = s(f), y = Xt(4 + h + e);
        return D[y >> 2] = h >> u, a(f, y + 4, h + e), l !== null && l.push(tt, y), y;
      }, argPackAdvance: K, readValueFromPointer: Wt, destructorFunction(l) {
        tt(l);
      } });
    }, En = (t, e, r, n, a, o) => {
      Pt[t] = { name: B(e), rawConstructor: q(r, n), rawDestructor: q(a, o), fields: [] };
    }, xn = (t, e, r, n, a, o, s, u, l, f) => {
      Pt[t].fields.push({ fieldName: B(e), getterReturnType: r, getter: q(n, a), getterContext: o, setterArgumentType: s, setter: q(u, l), setterContext: f });
    }, An = (t, e) => {
      e = B(e), Z(t, { isVoid: !0, name: e, argPackAdvance: 0, fromWireType: () => {
      }, toWireType: (r, n) => {
      } });
    }, Dn = {}, Sn = (t) => {
      var e = Dn[t];
      return e === void 0 ? B(t) : e;
    }, Se = () => {
      if (typeof globalThis == "object")
        return globalThis;
      function t(e) {
        e.$$$embind_global$$$ = e;
        var r = typeof $$$embind_global$$$ == "object" && e.$$$embind_global$$$ == e;
        return r || delete e.$$$embind_global$$$, r;
      }
      if (typeof $$$embind_global$$$ == "object" || (typeof global == "object" && t(global) ? $$$embind_global$$$ = global : typeof self == "object" && t(self) && ($$$embind_global$$$ = self), typeof $$$embind_global$$$ == "object"))
        return $$$embind_global$$$;
      throw Error("unable to get global object.");
    }, On = (t) => t === 0 ? et.toHandle(Se()) : (t = Sn(t), et.toHandle(Se()[t])), Fn = (t) => {
      t > 4 && (X.get(t).refcount += 1);
    }, Oe = (t, e) => {
      var r = at[t];
      return r === void 0 && P(e + " has unknown type " + _e(t)), r;
    }, Mn = (t) => {
      var e = new Array(t + 1);
      return function(r, n, a) {
        e[0] = r;
        for (var o = 0; o < t; ++o) {
          var s = Oe(D[n + o * 4 >> 2], "parameter " + o);
          e[o + 1] = s.readValueFromPointer(a), a += s.argPackAdvance;
        }
        var u = new (r.bind.apply(r, e))();
        return et.toHandle(u);
      };
    }, Fe = {}, jn = (t, e, r, n) => {
      t = et.toValue(t);
      var a = Fe[e];
      return a || (a = Mn(e), Fe[e] = a), a(t, r, n);
    }, In = (t, e) => {
      t = Oe(t, "_emval_take_value");
      var r = t.readValueFromPointer(e);
      return et.toHandle(r);
    }, Hn = () => {
      bt("");
    }, Rn = (t, e, r) => W.copyWithin(t, e, e + r), Wn = () => 2147483648, kn = (t) => {
      var e = J.buffer, r = (t - e.byteLength + 65535) / 65536;
      try {
        return J.grow(r), ee(), 1;
      } catch {
      }
    }, Bn = (t) => {
      var e = W.length;
      t >>>= 0;
      var r = Wn();
      if (t > r)
        return !1;
      for (var n = (l, f) => l + (f - l % f) % f, a = 1; a <= 4; a *= 2) {
        var o = e * (1 + 0.2 / a);
        o = Math.min(o, t + 100663296);
        var s = Math.min(r, n(Math.max(t, o), 65536)), u = kn(s);
        if (u)
          return !0;
      }
      return !1;
    }, Gt = {}, Un = () => O || "./this.program", gt = () => {
      if (!gt.strings) {
        var t = (typeof navigator == "object" && navigator.languages && navigator.languages[0] || "C").replace("-", "_") + ".UTF-8", e = { USER: "web_user", LOGNAME: "web_user", PATH: "/", PWD: "/", HOME: "/home/web_user", LANG: t, _: Un() };
        for (var r in Gt)
          Gt[r] === void 0 ? delete e[r] : e[r] = Gt[r];
        var n = [];
        for (var r in e)
          n.push(`${r}=${e[r]}`);
        gt.strings = n;
      }
      return gt.strings;
    }, Vn = (t, e) => {
      for (var r = 0; r < t.length; ++r)
        G[e++ >> 0] = t.charCodeAt(r);
      G[e >> 0] = 0;
    }, Ln = (t, e) => {
      var r = 0;
      return gt().forEach((n, a) => {
        var o = e + r;
        D[t + a * 4 >> 2] = o, Vn(n, o), r += n.length + 1;
      }), 0;
    }, zn = (t, e) => {
      var r = gt();
      D[t >> 2] = r.length;
      var n = 0;
      return r.forEach((a) => n += a.length + 1), D[e >> 2] = n, 0;
    }, Yn = (t) => t, Mt = (t) => t % 4 === 0 && (t % 100 !== 0 || t % 400 === 0), Nn = (t, e) => {
      for (var r = 0, n = 0; n <= e; r += t[n++])
        ;
      return r;
    }, Me = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31], je = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31], Gn = (t, e) => {
      for (var r = new Date(t.getTime()); e > 0; ) {
        var n = Mt(r.getFullYear()), a = r.getMonth(), o = (n ? Me : je)[a];
        if (e > o - r.getDate())
          e -= o - r.getDate() + 1, r.setDate(1), a < 11 ? r.setMonth(a + 1) : (r.setMonth(0), r.setFullYear(r.getFullYear() + 1));
        else
          return r.setDate(r.getDate() + e), r;
      }
      return r;
    };
    function Xn(t, e, r) {
      var n = r > 0 ? r : xe(t) + 1, a = new Array(n), o = Ee(t, a, 0, a.length);
      return e && (a.length = o), a;
    }
    var qn = (t, e) => {
      G.set(t, e);
    }, Jn = (t, e, r, n) => {
      var a = D[n + 40 >> 2], o = { tm_sec: k[n >> 2], tm_min: k[n + 4 >> 2], tm_hour: k[n + 8 >> 2], tm_mday: k[n + 12 >> 2], tm_mon: k[n + 16 >> 2], tm_year: k[n + 20 >> 2], tm_wday: k[n + 24 >> 2], tm_yday: k[n + 28 >> 2], tm_isdst: k[n + 32 >> 2], tm_gmtoff: k[n + 36 >> 2], tm_zone: a ? Nt(a) : "" }, s = Nt(r), u = { "%c": "%a %b %d %H:%M:%S %Y", "%D": "%m/%d/%y", "%F": "%Y-%m-%d", "%h": "%b", "%r": "%I:%M:%S %p", "%R": "%H:%M", "%T": "%H:%M:%S", "%x": "%m/%d/%y", "%X": "%H:%M:%S", "%Ec": "%c", "%EC": "%C", "%Ex": "%m/%d/%y", "%EX": "%H:%M:%S", "%Ey": "%y", "%EY": "%Y", "%Od": "%d", "%Oe": "%e", "%OH": "%H", "%OI": "%I", "%Om": "%m", "%OM": "%M", "%OS": "%S", "%Ou": "%u", "%OU": "%U", "%OV": "%V", "%Ow": "%w", "%OW": "%W", "%Oy": "%y" };
      for (var l in u)
        s = s.replace(new RegExp(l, "g"), u[l]);
      var f = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"], h = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
      function y(d, m, M) {
        for (var I = typeof d == "number" ? d.toString() : d || ""; I.length < m; )
          I = M[0] + I;
        return I;
      }
      function g(d, m) {
        return y(d, m, "0");
      }
      function T(d, m) {
        function M(it) {
          return it < 0 ? -1 : it > 0 ? 1 : 0;
        }
        var I;
        return (I = M(d.getFullYear() - m.getFullYear())) === 0 && (I = M(d.getMonth() - m.getMonth())) === 0 && (I = M(d.getDate() - m.getDate())), I;
      }
      function x(d) {
        switch (d.getDay()) {
          case 0:
            return new Date(d.getFullYear() - 1, 11, 29);
          case 1:
            return d;
          case 2:
            return new Date(d.getFullYear(), 0, 3);
          case 3:
            return new Date(d.getFullYear(), 0, 2);
          case 4:
            return new Date(d.getFullYear(), 0, 1);
          case 5:
            return new Date(d.getFullYear() - 1, 11, 31);
          case 6:
            return new Date(d.getFullYear() - 1, 11, 30);
        }
      }
      function H(d) {
        var m = Gn(new Date(d.tm_year + 1900, 0, 1), d.tm_yday), M = new Date(m.getFullYear(), 0, 4), I = new Date(m.getFullYear() + 1, 0, 4), it = x(M), It = x(I);
        return T(it, m) <= 0 ? T(It, m) <= 0 ? m.getFullYear() + 1 : m.getFullYear() : m.getFullYear() - 1;
      }
      var A = { "%a": (d) => f[d.tm_wday].substring(0, 3), "%A": (d) => f[d.tm_wday], "%b": (d) => h[d.tm_mon].substring(0, 3), "%B": (d) => h[d.tm_mon], "%C": (d) => {
        var m = d.tm_year + 1900;
        return g(m / 100 | 0, 2);
      }, "%d": (d) => g(d.tm_mday, 2), "%e": (d) => y(d.tm_mday, 2, " "), "%g": (d) => H(d).toString().substring(2), "%G": (d) => H(d), "%H": (d) => g(d.tm_hour, 2), "%I": (d) => {
        var m = d.tm_hour;
        return m == 0 ? m = 12 : m > 12 && (m -= 12), g(m, 2);
      }, "%j": (d) => g(d.tm_mday + Nn(Mt(d.tm_year + 1900) ? Me : je, d.tm_mon - 1), 3), "%m": (d) => g(d.tm_mon + 1, 2), "%M": (d) => g(d.tm_min, 2), "%n": () => `
`, "%p": (d) => d.tm_hour >= 0 && d.tm_hour < 12 ? "AM" : "PM", "%S": (d) => g(d.tm_sec, 2), "%t": () => "	", "%u": (d) => d.tm_wday || 7, "%U": (d) => {
        var m = d.tm_yday + 7 - d.tm_wday;
        return g(Math.floor(m / 7), 2);
      }, "%V": (d) => {
        var m = Math.floor((d.tm_yday + 7 - (d.tm_wday + 6) % 7) / 7);
        if ((d.tm_wday + 371 - d.tm_yday - 2) % 7 <= 2 && m++, m) {
          if (m == 53) {
            var M = (d.tm_wday + 371 - d.tm_yday) % 7;
            M != 4 && (M != 3 || !Mt(d.tm_year)) && (m = 1);
          }
        } else {
          m = 52;
          var I = (d.tm_wday + 7 - d.tm_yday - 1) % 7;
          (I == 4 || I == 5 && Mt(d.tm_year % 400 - 1)) && m++;
        }
        return g(m, 2);
      }, "%w": (d) => d.tm_wday, "%W": (d) => {
        var m = d.tm_yday + 7 - (d.tm_wday + 6) % 7;
        return g(Math.floor(m / 7), 2);
      }, "%y": (d) => (d.tm_year + 1900).toString().substring(2), "%Y": (d) => d.tm_year + 1900, "%z": (d) => {
        var m = d.tm_gmtoff, M = m >= 0;
        return m = Math.abs(m) / 60, m = m / 60 * 100 + m % 60, (M ? "+" : "-") + ("0000" + m).slice(-4);
      }, "%Z": (d) => d.tm_zone, "%%": () => "%" };
      s = s.replace(/%%/g, "\0\0");
      for (var l in A)
        s.includes(l) && (s = s.replace(new RegExp(l, "g"), A[l](o)));
      s = s.replace(/\0\0/g, "%");
      var R = Xn(s, !1);
      return R.length > e ? 0 : (qn(R, t), R.length - 1);
    }, Qn = (t, e, r, n, a) => Jn(t, e, r, n);
    ce = i.InternalError = class extends Error {
      constructor(t) {
        super(t), this.name = "InternalError";
      }
    }, Fr(), ct = i.BindingError = class extends Error {
      constructor(t) {
        super(t), this.name = "BindingError";
      }
    }, zr(), Br(), Qr(), Ce = i.UnboundTypeError = en(Error, "UnboundTypeError"), on(), un();
    var Zn = { q: $r, u: br, a: _r, h: Tr, l: Pr, I: Er, P: xr, n: Ar, ba: Dr, d: Cr, oa: Sr, Y: Or, fa: jr, na: rn, ma: nn, D: an, ea: cn, W: fn, J: dn, w: pn, s: mn, V: gn, L: Pn, Q: En, pa: xn, ga: An, U: Pe, la: On, R: Fn, ia: jn, ka: In, K: Hn, da: Rn, ca: Bn, $: Ln, aa: zn, H: va, T: Ea, B: wa, p: pa, b: Kn, C: ya, ha: ba, c: aa, j: ia, i: ra, x: ga, O: ma, v: da, G: _a, N: Ta, A: $a, F: xa, Z: Da, X: Sa, k: oa, f: na, e: ea, g: ta, M: Pa, m: fa, o: sa, S: ua, t: la, ja: ha, y: Ca, r: ca, E: Aa, z: Yn, _: Qn }, S = wr(), tt = i._free = (t) => (tt = i._free = S.sa)(t), Xt = i._malloc = (t) => (Xt = i._malloc = S.ta)(t), Ie = (t) => (Ie = S.va)(t);
    i.__embind_initialize_bindings = () => (i.__embind_initialize_bindings = S.wa)();
    var b = (t, e) => (b = S.xa)(t, e), wt = (t) => (wt = S.ya)(t), C = () => (C = S.za)(), _ = (t) => (_ = S.Aa)(t), He = (t) => (He = S.Ba)(t), Re = (t) => (Re = S.Ca)(t), We = (t, e, r) => (We = S.Da)(t, e, r), ke = (t) => (ke = S.Ea)(t);
    i.dynCall_viijii = (t, e, r, n, a, o, s) => (i.dynCall_viijii = S.Fa)(t, e, r, n, a, o, s);
    var Be = i.dynCall_jiii = (t, e, r, n) => (Be = i.dynCall_jiii = S.Ga)(t, e, r, n), Ue = i.dynCall_jiiii = (t, e, r, n, a) => (Ue = i.dynCall_jiiii = S.Ha)(t, e, r, n, a);
    i.dynCall_iiiiij = (t, e, r, n, a, o, s) => (i.dynCall_iiiiij = S.Ia)(t, e, r, n, a, o, s), i.dynCall_iiiiijj = (t, e, r, n, a, o, s, u, l) => (i.dynCall_iiiiijj = S.Ja)(t, e, r, n, a, o, s, u, l), i.dynCall_iiiiiijj = (t, e, r, n, a, o, s, u, l, f) => (i.dynCall_iiiiiijj = S.Ka)(t, e, r, n, a, o, s, u, l, f);
    function Kn(t, e) {
      var r = C();
      try {
        return E(t)(e);
      } catch (n) {
        if (_(r), n !== n + 0)
          throw n;
        b(1, 0);
      }
    }
    function ta(t, e, r, n) {
      var a = C();
      try {
        E(t)(e, r, n);
      } catch (o) {
        if (_(a), o !== o + 0)
          throw o;
        b(1, 0);
      }
    }
    function ea(t, e, r) {
      var n = C();
      try {
        E(t)(e, r);
      } catch (a) {
        if (_(n), a !== a + 0)
          throw a;
        b(1, 0);
      }
    }
    function ra(t, e, r, n, a) {
      var o = C();
      try {
        return E(t)(e, r, n, a);
      } catch (s) {
        if (_(o), s !== s + 0)
          throw s;
        b(1, 0);
      }
    }
    function na(t, e) {
      var r = C();
      try {
        E(t)(e);
      } catch (n) {
        if (_(r), n !== n + 0)
          throw n;
        b(1, 0);
      }
    }
    function aa(t, e, r) {
      var n = C();
      try {
        return E(t)(e, r);
      } catch (a) {
        if (_(n), a !== a + 0)
          throw a;
        b(1, 0);
      }
    }
    function oa(t) {
      var e = C();
      try {
        E(t)();
      } catch (r) {
        if (_(e), r !== r + 0)
          throw r;
        b(1, 0);
      }
    }
    function ia(t, e, r, n) {
      var a = C();
      try {
        return E(t)(e, r, n);
      } catch (o) {
        if (_(a), o !== o + 0)
          throw o;
        b(1, 0);
      }
    }
    function sa(t, e, r, n, a, o) {
      var s = C();
      try {
        E(t)(e, r, n, a, o);
      } catch (u) {
        if (_(s), u !== u + 0)
          throw u;
        b(1, 0);
      }
    }
    function ua(t, e, r, n, a, o, s) {
      var u = C();
      try {
        E(t)(e, r, n, a, o, s);
      } catch (l) {
        if (_(u), l !== l + 0)
          throw l;
        b(1, 0);
      }
    }
    function ca(t, e, r, n, a, o, s, u, l, f, h) {
      var y = C();
      try {
        E(t)(e, r, n, a, o, s, u, l, f, h);
      } catch (g) {
        if (_(y), g !== g + 0)
          throw g;
        b(1, 0);
      }
    }
    function la(t, e, r, n, a, o, s, u) {
      var l = C();
      try {
        E(t)(e, r, n, a, o, s, u);
      } catch (f) {
        if (_(l), f !== f + 0)
          throw f;
        b(1, 0);
      }
    }
    function fa(t, e, r, n, a) {
      var o = C();
      try {
        E(t)(e, r, n, a);
      } catch (s) {
        if (_(o), s !== s + 0)
          throw s;
        b(1, 0);
      }
    }
    function da(t, e, r, n, a, o, s) {
      var u = C();
      try {
        return E(t)(e, r, n, a, o, s);
      } catch (l) {
        if (_(u), l !== l + 0)
          throw l;
        b(1, 0);
      }
    }
    function ha(t, e, r, n, a, o, s, u, l) {
      var f = C();
      try {
        E(t)(e, r, n, a, o, s, u, l);
      } catch (h) {
        if (_(f), h !== h + 0)
          throw h;
        b(1, 0);
      }
    }
    function pa(t) {
      var e = C();
      try {
        return E(t)();
      } catch (r) {
        if (_(e), r !== r + 0)
          throw r;
        b(1, 0);
      }
    }
    function ma(t, e, r, n, a, o, s) {
      var u = C();
      try {
        return E(t)(e, r, n, a, o, s);
      } catch (l) {
        if (_(u), l !== l + 0)
          throw l;
        b(1, 0);
      }
    }
    function ya(t, e, r, n) {
      var a = C();
      try {
        return E(t)(e, r, n);
      } catch (o) {
        if (_(a), o !== o + 0)
          throw o;
        b(1, 0);
      }
    }
    function va(t, e, r, n) {
      var a = C();
      try {
        return E(t)(e, r, n);
      } catch (o) {
        if (_(a), o !== o + 0)
          throw o;
        b(1, 0);
      }
    }
    function ga(t, e, r, n, a, o) {
      var s = C();
      try {
        return E(t)(e, r, n, a, o);
      } catch (u) {
        if (_(s), u !== u + 0)
          throw u;
        b(1, 0);
      }
    }
    function wa(t, e, r, n, a, o) {
      var s = C();
      try {
        return E(t)(e, r, n, a, o);
      } catch (u) {
        if (_(s), u !== u + 0)
          throw u;
        b(1, 0);
      }
    }
    function $a(t, e, r, n, a, o, s, u, l, f) {
      var h = C();
      try {
        return E(t)(e, r, n, a, o, s, u, l, f);
      } catch (y) {
        if (_(h), y !== y + 0)
          throw y;
        b(1, 0);
      }
    }
    function ba(t, e, r) {
      var n = C();
      try {
        return E(t)(e, r);
      } catch (a) {
        if (_(n), a !== a + 0)
          throw a;
        b(1, 0);
      }
    }
    function Ca(t, e, r, n, a, o, s, u, l, f) {
      var h = C();
      try {
        E(t)(e, r, n, a, o, s, u, l, f);
      } catch (y) {
        if (_(h), y !== y + 0)
          throw y;
        b(1, 0);
      }
    }
    function _a(t, e, r, n, a, o, s, u) {
      var l = C();
      try {
        return E(t)(e, r, n, a, o, s, u);
      } catch (f) {
        if (_(l), f !== f + 0)
          throw f;
        b(1, 0);
      }
    }
    function Ta(t, e, r, n, a, o, s, u, l) {
      var f = C();
      try {
        return E(t)(e, r, n, a, o, s, u, l);
      } catch (h) {
        if (_(f), h !== h + 0)
          throw h;
        b(1, 0);
      }
    }
    function Pa(t, e, r, n, a, o, s) {
      var u = C();
      try {
        E(t)(e, r, n, a, o, s);
      } catch (l) {
        if (_(u), l !== l + 0)
          throw l;
        b(1, 0);
      }
    }
    function Ea(t, e, r, n) {
      var a = C();
      try {
        return E(t)(e, r, n);
      } catch (o) {
        if (_(a), o !== o + 0)
          throw o;
        b(1, 0);
      }
    }
    function xa(t, e, r, n, a, o, s, u, l, f, h, y) {
      var g = C();
      try {
        return E(t)(e, r, n, a, o, s, u, l, f, h, y);
      } catch (T) {
        if (_(g), T !== T + 0)
          throw T;
        b(1, 0);
      }
    }
    function Aa(t, e, r, n, a, o, s, u, l, f, h, y, g, T, x, H) {
      var A = C();
      try {
        E(t)(e, r, n, a, o, s, u, l, f, h, y, g, T, x, H);
      } catch (R) {
        if (_(A), R !== R + 0)
          throw R;
        b(1, 0);
      }
    }
    function Da(t, e, r, n) {
      var a = C();
      try {
        return Be(t, e, r, n);
      } catch (o) {
        if (_(a), o !== o + 0)
          throw o;
        b(1, 0);
      }
    }
    function Sa(t, e, r, n, a) {
      var o = C();
      try {
        return Ue(t, e, r, n, a);
      } catch (s) {
        if (_(o), s !== s + 0)
          throw s;
        b(1, 0);
      }
    }
    var jt;
    ht = function t() {
      jt || Ve(), jt || (ht = t);
    };
    function Ve() {
      if (rt > 0 || (ur(), rt > 0))
        return;
      function t() {
        jt || (jt = !0, i.calledRun = !0, !ft && (cr(), v(i), i.onRuntimeInitialized && i.onRuntimeInitialized(), lr()));
      }
      i.setStatus ? (i.setStatus("Running..."), setTimeout(function() {
        setTimeout(function() {
          i.setStatus("");
        }, 1), t();
      }, 1)) : t();
    }
    if (i.preInit)
      for (typeof i.preInit == "function" && (i.preInit = [i.preInit]); i.preInit.length > 0; )
        i.preInit.pop()();
    return Ve(), p.ready;
  };
})();
function Na(c) {
  return Qt(Zt, c);
}
async function Ga(c, {
  tryHarder: p = U.tryHarder,
  formats: i = U.formats,
  maxSymbols: v = U.maxSymbols
} = U) {
  return za(
    c,
    {
      tryHarder: p,
      formats: i,
      maxSymbols: v
    },
    Zt
  );
}
async function Xa(c, {
  tryHarder: p = U.tryHarder,
  formats: i = U.formats,
  maxSymbols: v = U.maxSymbols
} = U) {
  return Ya(
    c,
    {
      tryHarder: p,
      formats: i,
      maxSymbols: v
    },
    Zt
  );
}
const Jt = /* @__PURE__ */ new Map([
  ["aztec", "Aztec"],
  ["code_128", "Code128"],
  ["code_39", "Code39"],
  ["code_93", "Code93"],
  ["codabar", "Codabar"],
  ["data_matrix", "DataMatrix"],
  ["ean_13", "EAN-13"],
  ["ean_8", "EAN-8"],
  ["itf", "ITF"],
  ["pdf417", "PDF417"],
  ["qr_code", "QRCode"],
  ["upc_a", "UPC-A"],
  ["upc_e", "UPC-E"]
]);
function qa(c) {
  for (const [p, i] of Jt)
    if (c === i)
      return p;
  return "unknown";
}
var lt;
class Za extends EventTarget {
  constructor(i = {}) {
    var v;
    super();
    ze(this, lt, void 0);
    try {
      const $ = (v = i == null ? void 0 : i.formats) == null ? void 0 : v.filter(
        (w) => w !== "unknown"
      );
      if (($ == null ? void 0 : $.length) === 0)
        throw new TypeError("Hint option provided, but is empty.");
      $ == null || $.forEach((w) => {
        if (!Ne.includes(w))
          throw new TypeError(
            `Failed to read the 'formats' property from 'BarcodeDetectorOptions': The provided value '${w}' is not a valid enum value of type BarcodeFormat.`
          );
      }), Ye(this, lt, $ ?? []), Na().then((w) => {
        this.dispatchEvent(
          new CustomEvent("load", {
            detail: w
          })
        );
      }).catch((w) => {
        this.dispatchEvent(new CustomEvent("error", { detail: w }));
      });
    } catch ($) {
      throw Ge(
        $,
        "Failed to construct 'BarcodeDetector'"
      );
    }
  }
  static async getSupportedFormats() {
    return Ne.filter((i) => i !== "unknown");
  }
  async detect(i) {
    try {
      const v = await Ha(i);
      if (v === null)
        return [];
      let $;
      try {
        ar(v) ? $ = await Ga(v, {
          tryHarder: !0,
          formats: qt(this, lt).map(
            (w) => Jt.get(w)
          )
        }) : $ = await Xa(v, {
          tryHarder: !0,
          formats: qt(this, lt).map(
            (w) => Jt.get(w)
          )
        });
      } catch (w) {
        throw console.error(w), new DOMException(
          "Barcode detection service unavailable.",
          "NotSupportedError"
        );
      }
      return $.map((w) => {
        const {
          topLeft: { x: O, y: Y },
          topRight: { x: j, y: F },
          bottomLeft: { x: L, y: z },
          bottomRight: { x: V, y: N }
        } = w.position, J = Math.min(O, j, L, V), ft = Math.min(Y, F, z, N), G = Math.max(O, j, L, V), W = Math.max(Y, F, z, N);
        return {
          boundingBox: new DOMRectReadOnly(
            J,
            ft,
            G - J,
            W - ft
          ),
          rawValue: new TextDecoder().decode(w.bytes),
          format: qa(w.format),
          cornerPoints: [
            {
              x: O,
              y: Y
            },
            {
              x: j,
              y: F
            },
            {
              x: V,
              y: N
            },
            {
              x: L,
              y: z
            }
          ]
        };
      });
    } catch (v) {
      throw Ge(
        v,
        "Failed to execute 'detect' on 'BarcodeDetector'"
      );
    }
  }
}
lt = new WeakMap();
export {
  Za as BarcodeDetector,
  Qa as setZXingModuleOverrides
};

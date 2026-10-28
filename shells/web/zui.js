// Fixed web shim for every zui app. It keeps one DOM element per view, puts it exactly where the
// Zig layout engine says, measures text, and passes events back. It never changes per screen:
// everything visible is decided in Zig.
//
// The page sets the fonts with CSS variables: --zui-font and --zui-mono.
//
// start(wasm, mount, options): the app fills the window (mount = document.body), or, inside any
// other element, fills that element and leaves the page alone (its address, its background):
// a library on someone else's page. `wasm` is a URL or a compiled WebAssembly.Module (several
// maps on a page compile once). options.onPost receives the app's fx.post messages (else they
// go to the parent page); the returned send(json) reaches the app's hostMessage.

const KIND_VIEW = 0, KIND_TEXT = 1, KIND_INPUT = 2, KIND_SCROLL = 3, KIND_SCROLL_X = 4, KIND_IMAGE = 5, KIND_PATH = 6, KIND_VIDEO = 7, KIND_TEXT_AREA = 8, KIND_TEXT_SELECT = 9;
// Input types: keyboards (tree.Keyboard) and enter-key labels (tree.ReturnKey).
const INPUT_MODE = ['text', 'email', 'numeric', 'tel', 'url', 'decimal'];
const ENTER_HINT = ['', 'done', 'go', 'next', 'search', 'send'];
const PICK_DATE = 1, PICK_TIME = 2, PICK_OPTION = 3;
const POINTER_DOWN = 1, POINTER_MOVE = 2, POINTER_UP = 3, POINTER_CANCEL = 4, POINTER_WHEEL = 5;
const SVG = 'http://www.w3.org/2000/svg';
const EVENT_PRESS_IN = 1, EVENT_PRESS_OUT = 2, EVENT_PRESS = 3;
const INPUT_FOCUS = 1, INPUT_BLUR = 2, INPUT_SUBMIT = 3;
const ALIGN = ['left', 'center', 'right'];

const css = (argb) => {
  const a = argb >>> 24;
  if (a === 0) return 'transparent';
  return `rgba(${(argb >>> 16) & 255},${(argb >>> 8) & 255},${argb & 255},${(a / 255).toFixed(3)})`;
};

// Placeholders use the text color at 45% opacity on every platform.
const faded = (argb) => css(((Math.round((argb >>> 24) * 0.45) << 24) | (argb & 0xffffff)) >>> 0);

function setFont(el, size, weight, lineHeight, mono, letter = 0) {
  el.style.letterSpacing = letter ? letter + "px" : "";
  el.style.fontSize = size + 'px';
  el.style.fontWeight = String(weight);
  el.style.lineHeight = lineHeight + 'px';
  el.style.fontFamily = mono ? 'var(--zui-mono, monospace)' : 'var(--zui-font, system-ui, sans-serif)';
}

function setMaxLines(el, n) {
  if (n > 0) {
    el.style.display = '-webkit-box';
    el.style.webkitBoxOrient = 'vertical';
    el.style.webkitLineClamp = String(n);
    el.style.overflow = 'hidden';
  } else {
    el.style.display = '';
    el.style.webkitLineClamp = '';
    el.style.overflow = '';
  }
}

export async function start(wasm, mount = document.body, options = {}) {
  const embedded = mount !== document.body;
  let ex, memory;
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  // Empty Zig slices may carry any pointer, so they are never dereferenced.
  const str = (ptr, len) => (len === 0 ? '' : decoder.decode(new Uint8Array(memory.buffer, ptr >>> 0, len)));

  const root = document.createElement('div');
  root.style.cssText = embedded ? 'position:absolute;inset:0;overflow:hidden;' : 'position:fixed;inset:0;overflow:hidden;';
  if (embedded && getComputedStyle(mount).position === 'static') mount.style.position = 'relative';
  mount.replaceChildren(root);
  const sheet = document.createElement('style');
  sheet.textContent = 'input::placeholder,textarea::placeholder{color:var(--zui-placeholder);opacity:1}' +
    // Borders are drawn over the box, not around its content: children stay where zui put them.
    '.zui-b::before{content:"";position:absolute;inset:0;box-sizing:border-box;border-style:var(--zui-bs,solid);border-width:var(--zui-bw);border-color:var(--zui-bc);border-radius:inherit;pointer-events:none}' +
    '.zui-sel,.zui-sel *{user-select:text;-webkit-user-select:text;cursor:text}';
  document.head.appendChild(sheet);
  const views = new Map([[0, root]]);
  let frameRequested = false;

  // Text is measured in an invisible element with the same font and wrapping as text views.
  const measurer = document.createElement('div');
  measurer.style.cssText = 'position:absolute;left:0;top:0;visibility:hidden;white-space:pre-wrap;overflow-wrap:break-word;';
  measurer.dir = 'auto';
  mount.appendChild(measurer);

  // Pickers (fx.pickDate/Time/Option) open where the pointer last went down.
  let lastPointer = [innerWidth / 2, innerHeight / 2], picker = null;
  const onPointer = (e) => { lastPointer = [e.clientX, e.clientY]; };
  document.addEventListener('pointerdown', onPointer, true);
  // Browsers without <select>.showPicker() get a plain list in the page, in the system font.
  const menu = (select, options, selected, title) => {
    const dark = matchMedia('(prefers-color-scheme: dark)').matches;
    const cover = document.createElement('div');
    cover.style.cssText = 'position:fixed;inset:0;z-index:2147483647;display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,.3);font-family:system-ui,sans-serif;';
    const list = document.createElement('div');
    list.style.cssText = `min-width:240px;max-width:90vw;max-height:70vh;overflow:auto;border-radius:12px;padding:6px 0;background:${dark ? '#1f1f1f' : '#fff'};color:${dark ? '#eee' : '#111'};`;
    if (title) {
      const h = document.createElement('div');
      h.textContent = title;
      h.style.cssText = 'padding:10px 16px;font-weight:600;font-size:15px;';
      list.appendChild(h);
    }
    options.forEach((o, i) => {
      const b = document.createElement('div');
      b.textContent = o;
      b.dir = 'auto';
      b.style.cssText = `padding:12px 16px;font-size:16px;cursor:pointer;${i === selected ? 'font-weight:600;' : ''}`;
      b.onclick = (e) => { e.stopPropagation(); cover.remove(); select.selectedIndex = i; select.dispatchEvent(new Event('change')); };
      list.appendChild(b);
    });
    cover.onclick = () => { cover.remove(); select.remove(); };
    cover.appendChild(list);
    document.body.appendChild(cover);
  };

  // Files (fx.pickPhoto, pickFile): a hidden <input type=file>, opened during the press.
  let fileInput = null;
  const chooseFile = (accept, capture, then) => {
    fileInput?.remove();
    const el = document.createElement('input');
    el.type = 'file';
    if (accept) el.accept = accept;
    if (capture) el.setAttribute('capture', 'environment');
    el.style.cssText = 'position:fixed;left:-100px;top:0;width:1px;height:1px;opacity:0;';
    document.body.appendChild(el);
    fileInput = el;
    el.addEventListener('change', () => {
      const f = el.files && el.files[0];
      el.remove();
      if (fileInput === el) fileInput = null;
      if (f) then(f);
    });
    el.click();
  };
  const fileDone = (data, name, mime, w = 0, h = 0) => withBytes(data, (dp, dn) => withBytes(encoder.encode(name), (np, nn) =>
    withBytes(encoder.encode(mime), (mp, mn) => ex.zui_file_done(dp, dn, np, nn, mp, mn, w, h))));
  // A photo scaled to fit max x max, as JPEG; the browser turns it upright (EXIF) when decoding.
  const toJpeg = async (file, max, quality) => {
    const bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' });
    const k = Math.min(1, max / Math.max(bitmap.width, bitmap.height));
    const w = Math.max(1, Math.round(bitmap.width * k)), h = Math.max(1, Math.round(bitmap.height * k));
    const canvas = document.createElement('canvas');
    canvas.width = w;
    canvas.height = h;
    const g = canvas.getContext('2d');
    g.imageSmoothingQuality = 'high';
    g.drawImage(bitmap, 0, 0, w, h);
    bitmap.close?.();
    // Quality 0: PNG (transparency kept).
    const blob = await new Promise((r) => (quality === 0 ? canvas.toBlob(r, 'image/png') : canvas.toBlob(r, 'image/jpeg', quality / 100)));
    return { data: new Uint8Array(await blob.arrayBuffer()), w, h };
  };

  // Request headers travel as "name: value\n" lines (fetch, images, event streams).
  const headerLines = (text) => {
    const out = {};
    for (const line of text.split('\n')) {
      const at = line.indexOf(': ');
      if (at > 0) out[line.slice(0, at)] = line.slice(at + 2);
    }
    return out;
  };
  // Pictures that need headers (a Bearer token) are fetched and shown from a blob URL, kept for
  // the next view that wants the same one (the newest 200).
  const authImages = new Map();
  const authImage = (url, headers) => {
    const key = url + '\n' + headers;
    let p = authImages.get(key);
    if (p) { authImages.delete(key); authImages.set(key, p); return p; }
    p = fetch(url, { headers: headerLines(headers) })
      .then((r) => (r.ok ? r.blob() : Promise.reject(r.status)))
      .then((b) => URL.createObjectURL(b));
    p.catch(() => authImages.delete(key));
    authImages.set(key, p);
    if (authImages.size > 200) {
      const [oldest, op] = authImages.entries().next().value;
      authImages.delete(oldest);
      op.then((u) => setTimeout(() => URL.revokeObjectURL(u), 10000), () => {});
    }
    return p;
  };
  // Event streams: fetch() reads the answer as it arrives (EventSource cannot send headers).
  const streams = new Map();

  // Secure keys (zui/keys.zig): WebCrypto keys made non-extractable, kept in IndexedDB, so the
  // page can use them and nobody can read them. Requests answer later through zui_key_done.
  let keyDbP = null, keyChain = Promise.resolve();
  const keyStore = (mode, fn) => (keyDbP ||= new Promise((res, rej) => {
    const r = indexedDB.open('zui-keys', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('keys');
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  })).then((db) => new Promise((res, rej) => {
    const tx = db.transaction('keys', mode);
    const req = fn(tx.objectStore('keys'));
    tx.oncomplete = () => res(req.result);
    tx.onerror = () => rej(tx.error);
  }));
  const KEY_ALG = { 1: { name: 'ECDH', namedCurve: 'P-256' }, 2: { name: 'ECDSA', namedCurve: 'P-256' }, 3: { name: 'AES-GCM', length: 256 } };
  const KEY_USE = { 1: ['deriveBits'], 2: ['sign'], 3: ['encrypt', 'decrypt'] };
  const OK = 0, MISSING = 1, FAILED = 2;
  const subtle = globalThis.crypto?.subtle;
  const keyGet = async (name, kind) => {
    const k = await keyStore('readonly', (st) => st.get(name));
    return k && (!kind || k.kind === kind) ? k : null;
  };
  const keyPut = (name, v) => keyStore('readwrite', (st) => st.put(v, name));
  // The public key of a PKCS#8 private key: imported once extractable (as JWK), then forgotten.
  const publicOf = async (der, alg) => {
    const jwk = await subtle.exportKey('jwk', await subtle.importKey('pkcs8', der, alg, true, alg.name === 'ECDH' ? ['deriveBits'] : ['sign']));
    const b = (s) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
    const out = new Uint8Array(65);
    out[0] = 4;
    out.set(b(jwk.x), 1);
    out.set(b(jwk.y), 33);
    return out;
  };
  const runKey = async (op, kind, name, data, peer, iv, aad, salt, info, into) => {
    switch (op) {
      case 1: { // generate
        if (kind === 3) {
          await keyPut(name, { kind, key: await subtle.generateKey(KEY_ALG[3], false, KEY_USE[3]), pub: null });
          return [OK];
        }
        const pair = await subtle.generateKey(KEY_ALG[kind], false, KEY_USE[kind]);
        const pub = new Uint8Array(await subtle.exportKey('raw', pair.publicKey));
        await keyPut(name, { kind, key: pair.privateKey, pub });
        return [OK, pub];
      }
      case 2: { // import
        if (kind === 3) {
          await keyPut(name, { kind, key: await subtle.importKey('raw', data, 'AES-GCM', false, KEY_USE[3]), pub: null });
          return [OK];
        }
        const pub = await publicOf(data, KEY_ALG[kind]);
        await keyPut(name, { kind, key: await subtle.importKey('pkcs8', data, KEY_ALG[kind], false, KEY_USE[kind]), pub });
        return [OK, pub];
      }
      case 3: { // public
        const k = await keyGet(name);
        return k ? (k.pub ? [OK, k.pub] : [FAILED]) : [MISSING];
      }
      case 4: await keyStore('readwrite', (st) => st.delete(name)); return [OK];
      case 5: { // sign
        const k = await keyGet(name, 2);
        if (!k) return [MISSING];
        return [OK, new Uint8Array(await subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, k.key, data))];
      }
      case 6: { // ecdh
        const k = await keyGet(name, 1);
        if (!k) return [MISSING];
        const other = await subtle.importKey('raw', peer, KEY_ALG[1], false, []);
        const bits = await subtle.deriveBits({ name: 'ECDH', public: other }, k.key, 256);
        if (!into) return [OK, new Uint8Array(bits)];
        const base = await subtle.importKey('raw', bits, 'HKDF', false, ['deriveKey']);
        const aes = await subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt, info }, base, KEY_ALG[3], false, KEY_USE[3]);
        await keyPut(into, { kind: 3, key: aes, pub: null });
        return [OK];
      }
      case 7: case 8: { // encrypt, decrypt
        const k = await keyGet(name, 3);
        if (!k || iv.length !== 12) return [MISSING];
        const f = op === 7 ? subtle.encrypt : subtle.decrypt;
        return [OK, new Uint8Array(await f.call(subtle, { name: 'AES-GCM', iv, additionalData: aad }, k.key, data))];
      }
    }
    return [FAILED];
  };

  // Copies bytes into wasm memory for one call.
  const withBytes = (bytes, fn) => {
    const ptr = ex.zui_alloc(Math.max(1, bytes.length));
    new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
    try { fn(ptr, bytes.length); } finally { ex.zui_free(ptr, Math.max(1, bytes.length)); }
  };
  const sendText = (id, s) => withBytes(encoder.encode(s), (p, n) => ex.zui_text_event(id, p, n));
  // Selections: the app counts in UTF-8 bytes, the field in UTF-16 units.
  const bytesAt = (s, units) => encoder.encode(s.slice(0, units)).length;
  const unitsAt = (s, bytes) => {
    let b = 0, i = 0;
    while (i < s.length && b < bytes) {
      const c = s.codePointAt(i);
      b += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
      i += c >= 0x10000 ? 2 : 1;
    }
    return i;
  };
  const sendSelection = (id, el) => {
    if (!ex.zui_select_event || el.selectionStart == null) return;
    const s = bytesAt(el.value, el.selectionStart), e = bytesAt(el.value, el.selectionEnd);
    if (el._sel === s + ':' + e) return;
    el._sel = s + ':' + e;
    ex.zui_select_event(id, s, e);
  };
  let watchId = null;
  const sockets = new Map();
  const calls = webCalls(() => ex, () => memory, withBytes, encoder, str);
  const style = webStyle(views, () => ex, () => memory, str, decoder, measurer);
  const scan = webScan(() => ex, () => memory, withBytes, encoder, calls.streams);
  const recordings = webMedia(() => ex, () => memory, withBytes, encoder, str, calls.streams);
  const notes = new Map();
  let pushListening = false;

  // Navigation: fx.setLink replaces the address, fx.pushLink adds a history entry. While the app
  // handles Back (ui.onBack) one more entry with the same address sits on top, so the browser's
  // back button lands in the app: leaving that entry is the app's Back.
  const here = () => location.pathname + location.search;
  let currentLink = embedded ? '' : here();
  let guard = false, wantGuard = false, ignorePops = 0;
  const GUARD = { zuiBack: true };
  const pushGuard = () => { history.pushState(GUARD, '', currentLink); guard = true; };
  const onPop = (e) => {
    if (ignorePops > 0) { ignorePops--; return; }
    if (guard) {
      guard = false;
      if (here() !== currentLink) history.replaceState(null, '', currentLink);
      ex.zui_back();
      if (wantGuard && !guard) pushGuard();
      return;
    }
    // Forward into a guard entry left from before: step back over it.
    if (e.state && e.state.zuiBack) { ignorePops++; history.back(); return; }
    currentLink = here();
    withBytes(encoder.encode(currentLink), (p, n) => ex.zui_link_event(p, n));
  };

  // The screen kept on (fx.keepAwake): the lock is dropped when the tab hides, so it is asked
  // for again when it shows.
  let wakeWanted = false, wakeLock = null, audio = null;
  const requestWake = () => navigator.wakeLock?.request('screen').then((l) => { if (wakeWanted) wakeLock = l; else l.release(); }, () => {});
  // Escape, Enter, the arrows and Tab go to the app first (zui.KeyEvent); what it takes, the
  // browser does not act on.
  const KEYS = { Escape: 1, Esc: 1, Enter: 2, ArrowUp: 3, Up: 3, ArrowDown: 4, Down: 4, ArrowLeft: 5, Left: 5, ArrowRight: 6, Right: 6, Tab: 7 };
  document.addEventListener('keydown', (e) => {
    // Letters with Ctrl or Command (shortcuts such as Ctrl+B): 'A'..'Z'.
    const letter = (e.ctrlKey || e.metaKey) && /^Key[A-Z]$/.test(e.code) ? e.code.charCodeAt(3) : 0;
    const code = KEYS[e.key] || letter;
    if (!code || e.isComposing || !ex.zui_key_event) return;
    const t = e.target;
    const typing = t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable);
    const mods = (e.shiftKey ? 1 : 0) | (e.ctrlKey || e.metaKey ? 2 : 0) | (e.altKey ? 4 : 0) | (typing ? 8 : 0);
    if (ex.zui_key_event(code, mods)) e.preventDefault();
  });
  const onOnline = () => ex.zui_device_event(1);
  const onOffline = () => ex.zui_device_event(2);
  const onVisibility = () => {
    ex.zui_device_event(document.hidden ? 4 : 3);
    if (!document.hidden && wakeWanted && (!wakeLock || wakeLock.released)) requestWake();
  };

  const imports = {
    zui: {
      zui_create(id, kind) {
        const el = kind === KIND_PATH ? document.createElementNS(SVG, 'svg')
          : document.createElement(kind === KIND_INPUT ? 'input' : kind === KIND_TEXT_AREA ? 'textarea' : kind === KIND_IMAGE ? 'img' : kind === KIND_VIDEO ? 'video' : 'div');
        el.style.position = 'absolute';
        el.style.boxSizing = 'border-box';
        el.style.margin = '0';
        // Elements that cannot draw their border over themselves (a ::before) use a real one.
        el._realBorder = kind === KIND_INPUT || kind === KIND_TEXT_AREA || kind === KIND_IMAGE || kind === KIND_VIDEO || kind === KIND_PATH || kind === KIND_SCROLL || kind === KIND_SCROLL_X;
        if (kind === KIND_TEXT || kind === KIND_TEXT_SELECT) {
          el.style.whiteSpace = 'pre-wrap';
          el.style.overflowWrap = 'break-word';
          el.dir = 'auto';
          if (kind === KIND_TEXT_SELECT) el.className = 'zui-sel';
        } else if (kind === KIND_INPUT || kind === KIND_TEXT_AREA) {
          el.style.border = '0';
          el.style.padding = '0';
          el.style.background = 'transparent';
          el.style.outline = 'none';
          el.dir = 'auto';
          el.addEventListener('input', () => sendText(id, el.value));
          for (const ev of ['select', 'selectionchange', 'keyup', 'pointerup']) el.addEventListener(ev, () => sendSelection(id, el));
          el._zuiSelect = () => sendSelection(id, el);
          el.addEventListener('focus', () => ex.zui_input_event(id, INPUT_FOCUS));
          el.addEventListener('blur', () => { if (!el._removed) ex.zui_input_event(id, INPUT_BLUR); });
          if (kind === KIND_INPUT) el.addEventListener('keydown', (e) => { if (e.key === 'Enter') ex.zui_input_event(id, INPUT_SUBMIT); });
          else {
            // Wraps like a text view (zui measured it that way) and scrolls only past its frame.
            el.style.resize = 'none';
            el.style.display = 'block';
            el.style.whiteSpace = 'pre-wrap';
            el.style.overflowWrap = 'break-word';
            el.style.overflowY = 'auto';
            el.style.overflowX = 'hidden';
            el.style.scrollbarWidth = 'thin';
          }
        } else if (kind === KIND_IMAGE) {
          el.draggable = false;
          el.alt = '';
          el.decoding = 'async';
          el.style.userSelect = 'none';
          el.style.pointerEvents = 'none';
        } else if (kind === KIND_VIDEO) {
          // Sound plays through the peer's own audio element, so a video never doubles it.
          el.autoplay = true;
          el.playsInline = true;
          el.muted = true;
          el.style.pointerEvents = 'none';
          el.style.background = '#000';
        } else if (kind === KIND_PATH) {
          el.style.overflow = 'visible';
          el.style.pointerEvents = 'none';
          el._line = document.createElementNS(SVG, 'path');
          el.appendChild(el._line);
        } else if (kind === KIND_SCROLL || kind === KIND_SCROLL_X) {
          el.style.overflow = 'hidden';
          el.style.overscrollBehavior = 'contain';
          el.style.scrollbarWidth = 'thin';
          // Where it is, for zui (anchoring, the app's on_scroll).
          el._horizontal = kind === KIND_SCROLL_X;
          el.addEventListener('scroll', () => ex.zui_scroll(id, el._horizontal ? el.scrollLeft : el.scrollTop), { passive: true });
          const content = document.createElement('div');
          content.style.cssText = 'position:relative;';
          el.appendChild(content);
          el._content = content;
        }
        views.set(id, el);
      },
      zui_destroy(id) {
        const el = views.get(id);
        views.delete(id);
        if (!el) return;
        // Removing a focused input makes the browser report "blur" at once: not news to zui.
        el._removed = true;
        el.remove();
      },
      zui_insert(parent, id, index) {
        const p = views.get(parent);
        const box = p._content || p;
        const el = views.get(id);
        // Already there: moving it would take the focus from an input inside it.
        if (box.children[index] === el) return;
        if (el.parentNode === box) el.remove();
        box.insertBefore(el, box.children[index] || null);
      },
      zui_frame(id, x, y, w, h) {
        const s = views.get(id).style;
        s.left = x + 'px';
        s.top = y + 'px';
        s.width = w + 'px';
        s.height = h + 'px';
      },
      zui_box(id, bg, radius, borderWidth, borderColor, opacity) {
        const el = views.get(id), s = el.style;
        // Resets what a decoration (zui_decor, called after this when there is one) sets.
        s.background = css(bg);
        s.borderRadius = radius + 'px';
        s.boxShadow = '';
        setBorders(el, [borderWidth, borderWidth, borderWidth, borderWidth], [borderColor, borderColor, borderColor, borderColor]);
        s.opacity = String(opacity);
      },
      zui_pressable(id, on) {
        const el = views.get(id);
        el.style.cursor = on ? 'pointer' : '';
        el.style.userSelect = on ? 'none' : '';
        if (!on) {
          el.onpointerdown = el.onpointerup = el.onpointercancel = el.onpointerleave = el.onkeydown = null;
          el.removeAttribute('role');
          el.removeAttribute('tabindex');
          return;
        }
        el.setAttribute('role', 'button');
        el.tabIndex = 0;
        let down = false;
        el.onpointerdown = (e) => {
          // The innermost pressable takes the press (not the ones around it), and only with the
          // main button: a right click is a context menu.
          e.stopPropagation();
          if (e.button !== 0) return;
          down = true;
          el.setPointerCapture?.(e.pointerId);
          ex.zui_event(id, EVENT_PRESS_IN);
        };
        el.onpointerup = (e) => {
          if (!down) return;
          down = false;
          ex.zui_event(id, EVENT_PRESS_OUT);
          const r = el.getBoundingClientRect();
          if (e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom) ex.zui_event(id, EVENT_PRESS);
        };
        el.onpointercancel = () => { if (down) { down = false; ex.zui_event(id, EVENT_PRESS_OUT); } };
        el.onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); ex.zui_event(id, EVENT_PRESS); } };
      },
      zui_text(id, ptr, len, size, weight, lineHeight, mono, maxLines, color, align, letter) {
        const el = views.get(id);
        el.textContent = str(ptr, len);
        setFont(el, size, weight, lineHeight, mono, letter);
        setMaxLines(el, maxLines);
        el.style.color = css(color);
        el.style.textAlign = ALIGN[align];
      },
      zui_input(id, vptr, vlen, pptr, plen, size, weight, lineHeight, mono, color, align) {
        const el = views.get(id);
        const value = str(vptr, vlen);
        if (el.value !== value) el.value = value;
        el.placeholder = str(pptr, plen);
        setFont(el, size, weight, lineHeight, mono);
        el.style.color = css(color);
        el.style.setProperty('--zui-placeholder', faded(color));
        el.style.textAlign = ALIGN[align];
      },
      zui_input_type(id, keyboard, returnKey, secure, maxLength) {
        const el = views.get(id);
        if (maxLength > 0) el.maxLength = maxLength; else el.removeAttribute('maxlength');
        if (el.tagName === 'INPUT') el.type = secure ? 'password' : 'text';
        el.inputMode = INPUT_MODE[keyboard] || 'text';
        if (ENTER_HINT[returnKey]) el.enterKeyHint = ENTER_HINT[returnKey]; else el.removeAttribute('enterkeyhint');
        // Addresses and passwords are typed as they are.
        const plain = secure || keyboard === 1 || keyboard === 4;
        el.autocapitalize = plain ? 'none' : '';
        el.spellcheck = !plain && keyboard === 0;
        if (secure) el.autocomplete = 'current-password'; else el.removeAttribute('autocomplete');
      },
      zui_pick(kind, vptr, vlen, minPtr, minLen, maxPtr, maxLen, tptr, tlen, optr, olen, selected) {
        picker?.remove();
      fileInput?.remove();
        const options = kind === PICK_OPTION ? str(optr, olen).split('\n') : [];
        const el = document.createElement(kind === PICK_OPTION ? 'select' : 'input');
        // Invisible, where the finger or mouse last went down: the browser opens its picker there.
        el.style.cssText = `position:fixed;left:${lastPointer[0]}px;top:${lastPointer[1]}px;width:1px;height:1px;opacity:0;border:0;padding:0;margin:0;`;
        if (kind === PICK_OPTION) {
          for (const o of options) el.appendChild(new Option(o));
          el.selectedIndex = selected;
        } else {
          el.type = kind === PICK_DATE ? 'date' : 'time';
          el.value = str(vptr, vlen);
          if (minLen) el.min = str(minPtr, minLen);
          if (maxLen) el.max = str(maxPtr, maxLen);
        }
        document.body.appendChild(el);
        picker = el;
        el.addEventListener('change', () => {
          const v = kind === PICK_OPTION ? String(el.selectedIndex) : el.value;
          el.remove();
          if (picker === el) picker = null;
          if (v !== '' && v !== '-1') withBytes(encoder.encode(v), (p, n) => ex.zui_pick_done(p, n));
        });
        if (typeof el.showPicker === 'function') {
          try { el.showPicker(); return; } catch {}
        }
        if (kind === PICK_OPTION) return void menu(el, options, selected, str(tptr, tlen));
        el.focus();
        el.click();
      },
      zui_pick_photo(camera, max, quality) {
        chooseFile('image/*', !!camera, (f) => {
          toJpeg(f, max, quality).then(({ data, w, h }) => {
            const png = quality === 0;
            const name = (f.name || 'photo').replace(/\.[^.]*$/, '') + (png ? '.png' : '.jpg');
            fileDone(data, name, png ? 'image/png' : 'image/jpeg', w, h);
          }, (e) => console.error('zui: photo', e));
        });
      },
      zui_pick_file(ptr, len) {
        chooseFile(str(ptr, len), false, (f) => {
          f.arrayBuffer().then((b) => fileDone(new Uint8Array(b), f.name, f.type || 'application/octet-stream'));
        });
      },
      zui_save_file(nptr, nlen, mptr, mlen, dptr, dlen, share) {
        const name = str(nptr, nlen), type = str(mptr, mlen) || 'application/octet-stream';
        const data = dlen === 0 ? new Uint8Array(0) : new Uint8Array(memory.buffer, dptr >>> 0, dlen).slice();
        const file = new File([data], name, { type });
        if (share && navigator.canShare?.({ files: [file] })) return void navigator.share({ files: [file] }).catch(() => {});
        const url = URL.createObjectURL(file);
        const a = document.createElement('a');
        a.href = url;
        a.download = name;
        a.style.display = 'none';
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 60000);
      },
      zui_key(id, op, kind, np, nl, dp, dl, pp, pl, ip, il, ap, al, sp, sl, fp, fl, tp, tl) {
        // Copied now: the request outlives this call.
        const bytes = (ptr, len) => (len === 0 ? new Uint8Array(0) : new Uint8Array(memory.buffer, ptr >>> 0, len).slice());
        const args = [op, kind, str(np, nl), bytes(dp, dl), bytes(pp, pl), bytes(ip, il), bytes(ap, al), bytes(sp, sl), bytes(fp, fl), str(tp, tl)];
        const reply = ([status, data = new Uint8Array(0)]) => withBytes(data, (p, n) => ex.zui_key_done(id, status, p, n));
        // One at a time, in order: a key imported or derived is there for the next request.
        keyChain = keyChain.then(() => (subtle ? runKey(...args) : [3])).then(reply, () => reply([FAILED]));
      },
      zui_content(id, w, h) {
        const el = views.get(id);
        const s = el._content.style;
        s.width = w + 'px';
        s.height = h + 'px';
        // Scroll only along the axes where the content is bigger than the view.
        el.style.overflowX = w > parseFloat(el.style.width) ? 'auto' : 'hidden';
        el.style.overflowY = h > parseFloat(el.style.height) ? 'auto' : 'hidden';
      },
      zui_transform(id, rotate, tilt, perspective, hasOrigin, ox, oy) {
        views.get(id).style.transformOrigin = hasOrigin ? `${ox}px ${oy}px` : '';
        const parts = [];
        if (perspective > 0) parts.push(`perspective(${perspective}px)`);
        if (tilt) parts.push(`rotateX(${tilt}deg)`);
        if (rotate) parts.push(`rotate(${rotate}deg)`);
        views.get(id).style.transform = parts.join(' ');
      },
      zui_clip(id, on) {
        views.get(id).style.overflow = on ? 'hidden' : '';
      },
      zui_pointer_listen(id, on) {
        const el = views.get(id);
        if (!on) {
          el.onpointerdown = el.onpointermove = el.onpointerup = el.onpointercancel = el._wheel = null;
          return;
        }
        el.style.touchAction = 'none';
        el.style.userSelect = 'none';
        const send = (kind, e, wheel = 0) => {
          const r = el.getBoundingClientRect();
          ex.zui_pointer(id, kind, e.pointerId >>> 0 || 0, e.clientX - r.left, e.clientY - r.top, wheel, e.timeStamp);
        };
        el.onpointerdown = (e) => { el.setPointerCapture?.(e.pointerId); send(POINTER_DOWN, e); };
        el.onpointermove = (e) => { if (el.hasPointerCapture?.(e.pointerId)) send(POINTER_MOVE, e); };
        el.onpointerup = (e) => send(POINTER_UP, e);
        el.onpointercancel = (e) => send(POINTER_CANCEL, e);
        if (!el._wheel) el.addEventListener('wheel', (e) => el._wheel?.(e), { passive: false });
        el._wheel = (e) => {
          e.preventDefault();
          send(POINTER_WHEEL, e, e.deltaMode === 1 ? e.deltaY * 16 : e.deltaY);
        };
      },
      zui_image(id, ptr, len, hptr, hlen) {
        const el = views.get(id);
        const url = str(ptr, len), headers = str(hptr, hlen);
        el._want = url + '\n' + headers;
        if (!headers) {
          if (el.getAttribute('src') !== url) el.src = url;
          return;
        }
        const want = el._want;
        el.removeAttribute('src');
        authImage(url, headers).then((blob) => { if (el._want === want) el.src = blob; }, () => {});
      },
      zui_stream_open(id, uptr, ulen, hptr, hlen) {
        const control = new AbortController();
        const s = { control, live: true };
        streams.set(id, s);
        const end = () => { if (s.live) { s.live = false; streams.delete(id); ex.zui_stream_end(id); } };
        fetch(str(uptr, ulen), { headers: headerLines(str(hptr, hlen)), cache: 'no-store', signal: control.signal })
          .then(async (res) => {
            if (!s.live) return;
            ex.zui_stream_status(id, res.status);
            const reader = res.body.getReader();
            for (;;) {
              const { done, value } = await reader.read();
              if (done || !s.live) break;
              withBytes(value, (p, n) => ex.zui_stream_data(id, p, n));
            }
            end();
          })
          .catch(end);
      },
      zui_stream_close(id) {
        const s = streams.get(id);
        if (!s) return;
        s.live = false;
        streams.delete(id);
        s.control.abort();
      },
      zui_path(id, ptr, count, color, width, dashOn, dashOff, round, fill) {
        const line = views.get(id)._line;
        const f = count === 0 ? [] : new Float32Array(memory.buffer, ptr >>> 0, count * 2);
        // A NaN x starts a new sub-path; filled shapes are closed.
        let d = '', move = true;
        for (let i = 0; i < count; i++) {
          const x = f[2 * i], y = f[2 * i + 1];
          if (Number.isNaN(x)) { if (fill >>> 24 && d) d += 'Z'; move = true; continue; }
          d += `${move ? 'M' : 'L'}${x.toFixed(2)},${y.toFixed(2)}`;
          move = false;
        }
        if (fill >>> 24 && d) d += 'Z';
        line.setAttribute('d', d);
        line.setAttribute('fill', fill >>> 24 ? css(fill) : 'none');
        line.setAttribute('stroke', width > 0 ? css(color) : 'none');
        line.setAttribute('stroke-width', String(width));
        line.setAttribute('stroke-linecap', round ? 'round' : 'butt');
        line.setAttribute('stroke-linejoin', round ? 'round' : 'miter');
        if (dashOn > 0) line.setAttribute('stroke-dasharray', `${dashOn} ${dashOff}`);
        else line.removeAttribute('stroke-dasharray');
      },
      zui_request_frame() {
        if (frameRequested) return;
        frameRequested = true;
        requestAnimationFrame((t) => { frameRequested = false; ex.zui_frame(t); });
      },
      zui_fetch(id, mptr, mlen, uptr, ulen, bptr, blen, cptr, clen, hptr, hlen) {
        const method = str(mptr, mlen), url = str(uptr, ulen);
        const init = { method, headers: headerLines(str(hptr, hlen)) };
        if (blen > 0) {
          init.body = new Uint8Array(memory.buffer, bptr >>> 0, blen).slice();
          init.headers['content-type'] = str(cptr, clen);
        }
        fetch(url, init)
          .then(async (res) => ({ status: res.status, body: new Uint8Array(await res.arrayBuffer()), headers: [...res.headers].map(([k, v]) => `${k}: ${v}\n`).join('') }))
          .catch(() => ({ status: 0, body: new Uint8Array(0), headers: '' }))
          .then(({ status, body, headers }) => withBytes(body, (p, n) => withBytes(encoder.encode(headers), (hp, hn) => ex.zui_fetch_done_headers(id, status, p, n, hp, hn))));
      },
      zui_storage_get(kptr, klen, outLen) {
        let v = null;
        try { v = localStorage.getItem('zui:' + str(kptr, klen)); } catch {}
        if (v === null) return 0;
        const bytes = encoder.encode(v);
        const p = ex.zui_alloc(Math.max(1, bytes.length));
        new Uint8Array(memory.buffer, p, bytes.length).set(bytes);
        new Uint32Array(memory.buffer, outLen, 1)[0] = bytes.length;
        return p;
      },
      zui_storage_set(kptr, klen, vptr, vlen) {
        try { localStorage.setItem('zui:' + str(kptr, klen), str(vptr, vlen)); } catch {}
      },
      zui_storage_remove(kptr, klen) {
        try { localStorage.removeItem('zui:' + str(kptr, klen)); } catch {}
      },
      zui_timer(id, ms) {
        setTimeout(() => ex.zui_timer_done(id), ms);
      },
      zui_location(on) {
        if (!on) {
          if (watchId !== null) navigator.geolocation?.clearWatch(watchId);
          watchId = null;
          return;
        }
        if (!navigator.geolocation) return ex.zui_location_error(0);
        watchId = navigator.geolocation.watchPosition(
          (p) => ex.zui_location_fix(p.coords.latitude, p.coords.longitude, p.coords.accuracy || 0, p.coords.heading ?? NaN, p.coords.speed ?? NaN),
          (e) => ex.zui_location_error(e.code === 1 ? 1 : 0),
          { enableHighAccuracy: true, maximumAge: 5000, timeout: 20000 },
        );
      },
      zui_speak(tptr, tlen, lptr, llen) {
        if (!('speechSynthesis' in window)) return;
        speechSynthesis.cancel();
        const u = new SpeechSynthesisUtterance(str(tptr, tlen));
        u.lang = str(lptr, llen);
        speechSynthesis.speak(u);
      },
      zui_set_link(ptr, len) {
        if (embedded) return;
        const link = str(ptr, len) || location.pathname;
        currentLink = link;
        if (link !== here()) history.replaceState(history.state, '', link);
      },
      zui_push_link(ptr, len) {
        if (embedded) return;
        const link = str(ptr, len) || location.pathname;
        currentLink = link;
        // A guard on top becomes the new entry, and a new guard goes above it.
        if (guard) { history.replaceState(null, '', link); history.pushState(GUARD, '', link); }
        else history.pushState(null, '', link);
      },
      zui_back_state(handler) {
        wantGuard = !!handler;
        if (embedded) return;
        if (wantGuard && !guard) pushGuard();
        else if (!wantGuard && guard) { guard = false; ignorePops++; history.back(); }
      },
      zui_now() {
        return Date.now();
      },
      zui_tz_offset() {
        return -new Date().getTimezoneOffset();
      },
      zui_vibrate(ms) {
        try { navigator.vibrate?.(ms); } catch {}
      },
      zui_beep() {
        try {
          audio = audio || new AudioContext();
          audio.resume?.();
          const t = audio.currentTime, o = audio.createOscillator(), g = audio.createGain();
          o.frequency.value = 880;
          g.gain.setValueAtTime(0.25, t);
          g.gain.exponentialRampToValueAtTime(0.001, t + 0.15);
          o.connect(g).connect(audio.destination);
          o.start(t);
          o.stop(t + 0.16);
        } catch {}
      },
      zui_keep_awake(on) {
        wakeWanted = !!on;
        if (wakeWanted) { if (!wakeLock || wakeLock.released) requestWake(); }
        else { wakeLock?.release().catch(() => {}); wakeLock = null; }
      },
      zui_image_filter(id, s, c, b) {
        views.get(id).style.filter = s === 1 && c === 1 && b === 1 ? '' : `saturate(${s}) contrast(${c}) brightness(${b})`;
      },
      zui_label(id, ptr, len) {
        const el = views.get(id);
        if (!el) return;
        const s = str(ptr, len);
        if (s) { el.title = s; el.setAttribute('aria-label', s); } else { el.removeAttribute('title'); el.removeAttribute('aria-label'); }
      },
      zui_focus(id) {
        views.get(id)?.focus();
      },
      zui_selection(id, end) {
        const el = views.get(id);
        if (!el || el.selectionStart == null) return -1;
        return bytesAt(el.value, end ? el.selectionEnd : el.selectionStart);
      },
      zui_select(id, start, end) {
        const el = views.get(id);
        if (!el || el.setSelectionRange == null) return;
        el.focus();
        el.setSelectionRange(unitsAt(el.value, start >>> 0), unitsAt(el.value, end >>> 0));
        el._zuiSelect?.();
      },
      zui_notify(id, tptr, tlen, bptr, blen, urgent) {
        if (!('Notification' in window)) return;
        const show = () => {
          notes.get(id)?.close();
          const n = new Notification(str(tptr, tlen), { body: str(bptr, blen), tag: 'zui-' + id, requireInteraction: !!urgent, renotify: true });
          n.onclick = () => { window.focus(); n.close(); };
          notes.set(id, n);
        };
        const title = str(tptr, tlen), body = str(bptr, blen);
        if (Notification.permission === 'granted') show();
        else if (Notification.permission !== 'denied') Notification.requestPermission().then((p) => {
          if (p !== 'granted') return;
          const n = new Notification(title, { body, tag: 'zui-' + id, requireInteraction: !!urgent });
          n.onclick = () => { window.focus(); n.close(); };
          notes.set(id, n);
        });
      },
      // fx.registerPush: the page's service worker subscribes to Web Push with the server's
      // VAPID key; the subscription's JSON is the token (kind 4, web). The app's own sw.js shows
      // the pushes; one it posts to the page as {type:'zui-push', data} reaches pushMessage.
      zui_register_push(kptr, klen) {
        const key = str(kptr, klen);
        if (!key || !('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)) return;
        const bytes = (b64) => {
          const s = atob(b64.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (b64.length % 4)) % 4));
          return Uint8Array.from(s, (c) => c.charCodeAt(0));
        };
        const subscribe = async () => {
          const reg = await navigator.serviceWorker.ready;
          let sub = await reg.pushManager.getSubscription();
          const want = bytes(key);
          if (sub && sub.options && sub.options.applicationServerKey) {
            const have = new Uint8Array(sub.options.applicationServerKey);
            if (have.length !== want.length || have.some((v, i) => v !== want[i])) { await sub.unsubscribe(); sub = null; }
          }
          if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: want });
          withBytes(encoder.encode(JSON.stringify(sub)), (p, n) => ex.zui_push_token(p, n, 4));
        };
        const go = () => subscribe().catch((e) => console.warn('zui push:', e));
        if (Notification.permission === 'granted') go();
        else if (Notification.permission !== 'denied') {
          // Browsers want a click before asking: the next one.
          const ask = () => Notification.requestPermission().then((p) => { if (p === 'granted') go(); });
          addEventListener('pointerdown', ask, { once: true });
        }
        if (!pushListening) {
          pushListening = true;
          navigator.serviceWorker.addEventListener('message', (e) => {
            if (e.data && e.data.type === 'zui-push') withBytes(encoder.encode(JSON.stringify(e.data.data ?? {})), (p, n) => ex.zui_push_message(p, n));
          });
        }
      },
      zui_cancel_notify(id) {
        notes.get(id)?.close();
        notes.delete(id);
      },
      zui_copy(ptr, len) {
        navigator.clipboard?.writeText(str(ptr, len)).catch(() => {});
      },
      zui_open_url(ptr, len, newWindow) {
        const url = str(ptr, len);
        if (newWindow) window.open(url, '_blank', 'noopener'); else location.href = url;
      },
      zui_post(ptr, len) {
        if (options.onPost) return options.onPost(str(ptr, len));
        if (window.parent === window) return;
        try { window.parent.postMessage(JSON.parse(str(ptr, len)), '*'); } catch {}
      },
      zui_socket_open(id, ptr, len) {
        let url = str(ptr, len);
        // Relative to the page, as fetch() is.
        if (url.startsWith('/')) url = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + url;
        const s = new WebSocket(url);
        sockets.set(id, s);
        s.onopen = () => ex.zui_socket_event(id, 1, 0, 0);
        s.onmessage = (e) => { if (typeof e.data === 'string') withBytes(encoder.encode(e.data), (p, n) => ex.zui_socket_event(id, 2, p, n)); };
        s.onclose = () => { sockets.delete(id); ex.zui_socket_event(id, 3, 0, 0); };
      },
      zui_socket_send(id, ptr, len) {
        const s = sockets.get(id);
        if (s && s.readyState === 1) s.send(str(ptr, len));
      },
      zui_socket_close(id) {
        sockets.get(id)?.close();
        sockets.delete(id);
      },
      ...calls.imports,
      ...style.imports,
      ...scan.imports,
      ...recordings.imports,
      zui_video(id, stream, mirror, cover) {
        const el = views.get(id);
        // u32 from wasm arrives as i32: remote ids (from 0x80000000) would be negative.
        // The wanted id stays on the element: a stream that is not ready yet attaches later.
        el._stream = stream >>> 0;
        el.style.transform = mirror ? 'scaleX(-1)' : '';
        el.style.objectFit = cover ? 'cover' : 'contain';
        // A video player plays in the view that shows it.
        if (recordings.bindVideo(el, el._stream)) return;
        const s = calls.streams.get(el._stream) || null;
        if (el.srcObject !== s) el.srcObject = s;
      },
      zui_root_background(argb) {
        const c = css(argb);
        root.style.background = c;
        if (!embedded) document.documentElement.style.background = c;
      },
      zui_rtl(on) {
        // The writing direction of the page (or, embedded, of the mount) follows the app's
        // language, so the page's CSS can pick the Arabic font with [dir="rtl"].
        (embedded ? mount : document.documentElement).dir = on ? 'rtl' : 'ltr';
      },
      zui_log(ptr, len) {
        console.error(str(ptr, len));
      },
      zui_measure(ptr, len, size, weight, lineHeight, mono, maxLines, maxWidth, out, letter) {
        measurer.textContent = str(ptr, len);
        setFont(measurer, size, weight, lineHeight, mono, letter);
        measurer.style.maxWidth = Number.isFinite(maxWidth) ? maxWidth + 'px' : 'none';
        const r = measurer.getBoundingClientRect();
        let h = r.height;
        if (maxLines > 0) h = Math.min(h, maxLines * lineHeight);
        // Rounded up so the text never wraps differently once placed.
        new Float32Array(memory.buffer, out, 2).set([Math.ceil(r.width), Math.ceil(h)]);
      },
    },
  };

  const instance = wasm instanceof WebAssembly.Module
    ? await WebAssembly.instantiate(wasm, imports)
    : (await WebAssembly.instantiateStreaming(fetch(wasm), imports)).instance;
  ex = instance.exports;
  memory = ex.memory;
  // A web font that arrives after the first layout changes every text's size: lay out again.
  document.fonts?.addEventListener('loadingdone', () => ex.zui_relayout?.());

  // Safe-area insets (notches) come from CSS env() through a probe element.
  const probe = document.createElement('div');
  probe.style.cssText = 'position:fixed;visibility:hidden;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);';
  mount.appendChild(probe);
  const insets = () => {
    if (embedded) return [0, 0, 0, 0];
    const s = getComputedStyle(probe);
    return [s.paddingTop, s.paddingRight, s.paddingBottom, s.paddingLeft].map(parseFloat);
  };
  const dark = matchMedia('(prefers-color-scheme: dark)');

  const lang = encoder.encode(navigator.language || 'en');
  const langPtr = ex.zui_alloc(lang.length);
  new Uint8Array(memory.buffer, langPtr, lang.length).set(lang);
  const size = () => (embedded ? [mount.clientWidth, mount.clientHeight] : [innerWidth, innerHeight]);
  const isDark = () => (options.dark ?? dark.matches) ? 1 : 0;
  const link = encoder.encode(options.link ?? (embedded ? '' : location.pathname + location.search));
  withBytes(link, (linkPtr, linkLen) => ex.zui_start(...size(), isDark(), ...insets(), langPtr, lang.length, linkPtr, linkLen));
  ex.zui_free(langPtr, lang.length);
  const onResize = () => {
    ex.zui_insets(...insets());
    ex.zui_resize(...size());
  };
  let observer = null;
  if (embedded) {
    observer = new ResizeObserver(onResize);
    observer.observe(mount);
  } else addEventListener('resize', onResize);
  const onDark = () => ex.zui_dark(isDark());
  dark.addEventListener('change', onDark);
  const send = (text) => withBytes(encoder.encode(text), (p, n) => ex.zui_host_message(p, n));
  // Messages from the page this one is embedded in (an iframe).
  const onMessage = (e) => {
    if (e.source !== window.parent || window.parent === window) return;
    let text;
    try { text = typeof e.data === 'string' ? e.data : JSON.stringify(e.data); } catch { return; }
    send(text);
  };
  if (!embedded) addEventListener('message', onMessage);
  if (!embedded) addEventListener('popstate', onPop);
  addEventListener('online', onOnline);
  addEventListener('offline', onOffline);
  document.addEventListener('visibilitychange', onVisibility);
  if (!navigator.onLine) onOffline();
  if (document.hidden) ex.zui_device_event(4);
  return {
    instance,
    send,
    destroy() {
      observer?.disconnect();
      removeEventListener('resize', onResize);
      removeEventListener('message', onMessage);
      removeEventListener('popstate', onPop);
      document.removeEventListener('pointerdown', onPointer, true);
      picker?.remove();
      removeEventListener('online', onOnline);
      removeEventListener('offline', onOffline);
      document.removeEventListener('visibilitychange', onVisibility);
      wakeLock?.release().catch(() => {});
      audio?.close().catch(() => {});
      dark.removeEventListener('change', onDark);
      if (watchId !== null) navigator.geolocation?.clearWatch(watchId);
      for (const s of sockets.values()) s.close();
      for (const s of streams.values()) { s.live = false; s.control.abort(); }
      calls.destroy();
      scan.destroy();
      recordings.destroy();
      mount.replaceChildren();
    },
  };
}

// Calls: the browser's own WebRTC (part of the browser, not a library). Streams have ids: the app's
// for its own (fx.openMedia), and ids from 0x80000000 up for the ones peers send.
const MEDIA_READY = 1, MEDIA_FAILED = 2, MEDIA_ENDED = 3;
const PEER_SIGNAL = 1, PEER_STATE = 2, PEER_TRACK = 3;

// Voice and video messages: MediaRecorder (MP4 where the browser can, WebM otherwise) with a
// level meter, and playback through media elements. A video player plays inside the video view
// showing it; a video recording's camera shows through the calls' stream map.
function webMedia(getEx, getMemory, withBytes, encoder, str, streams) {
  const REC_STARTED = 1, REC_LEVEL = 2, REC_DONE = 3, REC_FAILED = 4;
  const PLAY_READY = 1, PLAY_PROGRESS = 2, PLAY_ENDED = 3, PLAY_FAILED = 4;
  const recorders = new Map();
  const players = new Map();
  const none = new Uint8Array(0);
  const recordEvent = (id, kind, level = 0, ms = 0, bytes = none, mime = '') =>
    withBytes(encoder.encode(mime), (mp, mn) => withBytes(bytes, (p, n) => getEx().zui_record_event(id, kind, level, ms >>> 0, p, n, mp, mn)));
  const playEvent = (id, kind, el, text = '') => withBytes(encoder.encode(text), (p, n) =>
    getEx().zui_play_event(id, kind, Math.round((el?.currentTime || 0) * 1000) >>> 0, Math.round(isFinite(el?.duration) ? el.duration * 1000 : 0) >>> 0, p, n));
  const attach = (id, s) => {
    for (const v of document.querySelectorAll('video')) if (v._stream === id && v.srcObject !== s) v.srcObject = s;
  };
  const pickType = (video) => (video
    ? ['video/mp4;codecs=avc1,mp4a', 'video/mp4', 'video/webm;codecs=vp8,opus', 'video/webm']
    : ['audio/mp4;codecs=mp4a.40.2', 'audio/mp4', 'audio/webm;codecs=opus', 'audio/webm'])
    .find((t) => window.MediaRecorder?.isTypeSupported?.(t)) || '';

  const finish = (id) => {
    const r = recorders.get(id);
    if (!r) return;
    clearInterval(r.meter);
    clearTimeout(r.limit);
    r.audio?.close().catch(() => {});
    for (const t of r.stream.getTracks()) t.stop();
    streams.delete(id);
  };

  const listen = (id, p) => {
    const el = p.el;
    el.onloadedmetadata = () => playEvent(id, PLAY_READY, el);
    el.ontimeupdate = () => {
      const now = performance.now();
      if (now - p.lastProgress < 240) return;
      p.lastProgress = now;
      playEvent(id, PLAY_PROGRESS, el);
    };
    el.onended = () => playEvent(id, PLAY_ENDED, el);
    el.onerror = () => playEvent(id, PLAY_FAILED, el, el.error?.message || 'unavailable');
  };

  const imports = {
    zui_record_start(id, video, back, maxMs) {
      const ask = navigator.mediaDevices?.getUserMedia?.({
        audio: { echoCancellation: true, noiseSuppression: true },
        video: video ? { facingMode: back ? 'environment' : 'user', width: { ideal: 640 }, height: { ideal: 480 } } : false,
      });
      if (!ask || !window.MediaRecorder) return void setTimeout(() => recordEvent(id, REC_FAILED, 0, 0, encoder.encode('unsupported')));
      ask.then((stream) => {
        const type = pickType(!!video);
        let rec;
        try { rec = new MediaRecorder(stream, type ? { mimeType: type } : undefined); } catch {
          for (const t of stream.getTracks()) t.stop();
          return recordEvent(id, REC_FAILED, 0, 0, encoder.encode('unsupported'));
        }
        const r = { stream, rec, chunks: [], start: performance.now(), cancel: false };
        recorders.set(id, r);
        if (video) { streams.set(id, stream); attach(id, stream); }
        rec.ondataavailable = (e) => { if (e.data.size) r.chunks.push(e.data); };
        rec.onstop = async () => {
          const ms = performance.now() - r.start;
          finish(id);
          recorders.delete(id);
          if (r.cancel) return;
          const blob = new Blob(r.chunks, { type: rec.mimeType || type });
          const bytes = new Uint8Array(await blob.arrayBuffer());
          recordEvent(id, REC_DONE, 0, ms, bytes, (rec.mimeType || type || (video ? 'video/webm' : 'audio/webm')).split(';')[0]);
        };
        rec.start(250);
        // Loudness: the RMS of the microphone signal, ten times a second.
        try {
          r.audio = new AudioContext();
          const analyser = r.audio.createAnalyser();
          analyser.fftSize = 1024;
          r.audio.createMediaStreamSource(stream).connect(analyser);
          const buf = new Float32Array(analyser.fftSize);
          r.meter = setInterval(() => {
            analyser.getFloatTimeDomainData(buf);
            let sum = 0;
            for (const x of buf) sum += x * x;
            recordEvent(id, REC_LEVEL, Math.min(1, Math.sqrt(sum / buf.length) * 3), performance.now() - r.start);
          }, 100);
        } catch {}
        r.limit = setTimeout(() => { if (rec.state !== 'inactive') rec.stop(); }, maxMs);
        recordEvent(id, REC_STARTED);
      }, (e) => recordEvent(id, REC_FAILED, 0, 0, encoder.encode(e?.name === 'NotAllowedError' ? 'denied' : 'unavailable')));
    },
    zui_record_stop(id, cancel) {
      const r = recorders.get(id);
      if (!r) return;
      r.cancel = !!cancel;
      if (r.rec.state !== 'inactive') r.rec.stop();
    },
    zui_play(id, uptr, ulen, dptr, dlen, mptr, mlen, video, autoplay, loop) {
      let url = str(uptr, ulen);
      let owned = false;
      if (dlen) {
        const bytes = new Uint8Array(getMemory().buffer, dptr >>> 0, dlen).slice();
        url = URL.createObjectURL(new Blob([bytes], { type: str(mptr, mlen) || (video ? 'video/mp4' : 'audio/mp4') }));
        owned = true;
      }
      const el = document.createElement(video ? 'video' : 'audio');
      el.preload = 'auto';
      el.playsInline = true;
      el.loop = !!loop;
      el.src = url;
      const p = { el, url, owned, lastProgress: 0 };
      players.set(id, p);
      listen(id, p);
      p.autoplay = !!autoplay;
      // AbortError: the player moved into a video view before it started (it plays there).
      if (autoplay) el.play().catch((e) => { if (e?.name !== 'AbortError' && p.el === el) playEvent(id, PLAY_FAILED, el, e?.name || 'unavailable'); });
    },
    zui_playback(id, op, value) {
      const p = players.get(id);
      if (!p) return;
      if (op === 1) p.el.pause();
      else if (op === 2) p.el.play().catch(() => {});
      else if (op === 3) p.el.currentTime = (value >>> 0) / 1000;
      else if (op === 5) { p.el.preservesPitch = true; p.el.playbackRate = Math.max(0.25, Math.min(4, (value >>> 0) / 100)); }
      else if (op === 4) {
        p.el.pause();
        p.el.onloadedmetadata = p.el.ontimeupdate = p.el.onended = p.el.onerror = null;
        p.el.removeAttribute('src');
        p.el.load();
        if (p.owned) URL.revokeObjectURL(p.url);
        players.delete(id);
      }
    },
  };

  return {
    imports,
    /** A video view showing player `id`: the player moves into it, keeping its place. */
    bindVideo(view, id) {
      const p = players.get(id);
      if (!p) return false;
      if (p.el === view) return true;
      const at = p.el.currentTime, playing = !p.el.paused, old = p.el;
      old.pause();
      old.onloadedmetadata = old.ontimeupdate = old.onended = old.onerror = null;
      view.srcObject = null;
      view.muted = false;
      view.loop = old.loop;
      view.src = p.url;
      p.el = view;
      listen(id, p);
      view.addEventListener('loadedmetadata', () => {
        view.currentTime = at;
        if (playing || p.autoplay) view.play().catch(() => {});
      }, { once: true });
      return true;
    },
    destroy() {
      for (const id of [...recorders.keys()]) { recorders.get(id).cancel = true; imports.zui_record_stop(id, 1); }
      for (const id of [...players.keys()]) imports.zui_playback(id, 4, 0);
    },
  };
}

function webCalls(getEx, getMemory, withBytes, encoder, str) {
  const streams = new Map();
  const peers = new Map();
  let nextRemote = 0x80000000;
  const mediaEvent = (id, kind, text = '') => withBytes(encoder.encode(text), (p, n) => getEx().zui_media_event(id, kind, p, n));
  const peerEvent = (id, kind, text = '', stream = 0) => withBytes(encoder.encode(text), (p, n) => getEx().zui_peer_event(id, kind, p, n, stream));
  // Video views that asked for a stream before it existed (zui_video ran first) get it now.
  const attach = (id, s) => {
    for (const v of document.querySelectorAll('video')) if (v._stream === id && v.srcObject !== s) v.srcObject = s;
  };

  const camera = (back) => ({ width: { ideal: 1280 }, height: { ideal: 720 }, facingMode: back ? 'environment' : 'user' });
  // The loudspeaker chosen for calls (setSinkId), for the audio of connections opened later too.
  let sinkId = '';

  // Hardware-friendly H.264 first, where the browser lets the page choose.
  const preferH264 = (pc) => {
    const caps = window.RTCRtpReceiver?.getCapabilities?.('video');
    if (!caps) return;
    const codecs = [...caps.codecs].sort((a, b) => (b.mimeType === 'video/H264') - (a.mimeType === 'video/H264'));
    for (const t of pc.getTransceivers()) {
      if (t.receiver.track?.kind === 'video' && t.setCodecPreferences) try { t.setCodecPreferences(codecs); } catch {}
    }
  };

  // Puts a stream's tracks on a connection, replacing what it sent before.
  const send = (peer, stream) => {
    const s = streams.get(stream);
    const senders = peer.pc.getSenders();
    for (const kind of ['audio', 'video']) {
      const track = s?.getTracks().find((t) => t.kind === kind) || null;
      const sender = senders.find((x) => x.track?.kind === kind || (x._kind === kind));
      if (sender) sender.replaceTrack(track).catch(() => {});
      else if (track) peer.pc.addTrack(track, s)._kind = kind;
    }
    peer.stream = stream;
    preferH264(peer.pc);
  };

  const imports = {
    zui_media_open(id, audio, video, screen, back) {
      const ask = screen
        ? navigator.mediaDevices?.getDisplayMedia?.({ video: true, audio: !!audio })
        : navigator.mediaDevices?.getUserMedia?.({ audio: audio ? { echoCancellation: true, noiseSuppression: true } : false, video: video ? camera(back) : false });
      if (!ask) return void setTimeout(() => mediaEvent(id, MEDIA_FAILED, 'unsupported'));
      ask.then((s) => {
        s._back = !!back;
        streams.set(id, s);
        attach(id, s);
        for (const t of s.getTracks()) t.onended = () => { if (streams.get(id) === s && t.kind === 'video') mediaEvent(id, MEDIA_ENDED); };
        mediaEvent(id, MEDIA_READY);
      }, (e) => mediaEvent(id, MEDIA_FAILED, e?.name === 'NotAllowedError' ? 'denied' : 'unavailable'));
    },
    zui_media_enable(id, audio, video) {
      const s = streams.get(id);
      if (!s) return;
      for (const t of s.getAudioTracks()) t.enabled = !!audio;
      for (const t of s.getVideoTracks()) t.enabled = !!video;
    },
    zui_media_switch(id) {
      const s = streams.get(id);
      const old = s?.getVideoTracks()[0];
      if (!old) return;
      navigator.mediaDevices.getUserMedia({ video: camera(!s._back) }).then((fresh) => {
        const track = fresh.getVideoTracks()[0];
        track.enabled = old.enabled;
        s._back = !s._back;
        s.removeTrack(old);
        old.stop();
        s.addTrack(track);
        for (const p of peers.values()) if (p.stream === id) send(p, id);
        // Video elements showing this stream pick up the new track.
        for (const v of document.querySelectorAll('video')) if (v.srcObject === s) { v.srcObject = null; v.srcObject = s; }
      }, () => {});
    },
    zui_media_devices(id) {
      const s = streams.get(id);
      const using = { 1: s?.getAudioTracks()[0]?.getSettings?.().deviceId, 2: s?.getVideoTracks()[0]?.getSettings?.().deviceId };
      const kinds = { audioinput: 1, videoinput: 2, audiooutput: 3 };
      const canSink = 'setSinkId' in HTMLMediaElement.prototype;
      const answer = (list) => withBytes(encoder.encode(JSON.stringify(list)), (p, n) => getEx().zui_devices_event(p, n));
      if (!navigator.mediaDevices?.enumerateDevices) return void setTimeout(() => answer([]));
      navigator.mediaDevices.enumerateDevices().then((all) => {
        const list = [];
        for (const d of all) {
          const k = kinds[d.kind];
          if (!k || (k === 3 && !canSink) || !d.deviceId) continue;
          if (d.deviceId === 'communications') continue;
          const current = k === 3 ? (sinkId || 'default') === d.deviceId : using[k] === d.deviceId;
          list.push({ k, id: d.deviceId, l: d.label || '', t: '', c: current });
        }
        answer(list);
      }, () => answer([]));
    },
    zui_media_use(id, kind, ptr, len) {
      const deviceId = str(ptr, len);
      if (kind === 3) {
        sinkId = deviceId;
        for (const p of peers.values()) for (const a of p.audio) a.setSinkId?.(deviceId).catch(() => {});
        return;
      }
      const s = streams.get(id);
      const video = kind === 2;
      const old = video ? s?.getVideoTracks()[0] : s?.getAudioTracks()[0];
      if (!old) return;
      const ask = video ? { video: { ...camera(s._back), facingMode: undefined, deviceId: { exact: deviceId } } } : { audio: { echoCancellation: true, noiseSuppression: true, deviceId: { exact: deviceId } } };
      navigator.mediaDevices.getUserMedia(ask).then((fresh) => {
        const track = video ? fresh.getVideoTracks()[0] : fresh.getAudioTracks()[0];
        track.enabled = old.enabled;
        s.removeTrack(old);
        old.stop();
        s.addTrack(track);
        for (const p of peers.values()) if (p.stream === id) send(p, id);
        if (video) for (const v of document.querySelectorAll('video')) if (v.srcObject === s) { v.srcObject = null; v.srcObject = s; }
      }, () => {});
    },
    zui_media_close(id) {
      for (const t of streams.get(id)?.getTracks() || []) t.stop();
      streams.delete(id);
    },
    zui_peer_open(id, iptr, ilen, polite, stream) {
      let iceServers = [];
      try { iceServers = JSON.parse(str(iptr, ilen)); } catch {}
      const pc = new RTCPeerConnection({ iceServers, bundlePolicy: 'max-bundle' });
      const peer = { pc, polite: !!polite, makingOffer: false, ignoreOffer: false, stream: 0, queue: Promise.resolve(), remote: new Map(), audio: [] };
      peers.set(id, peer);
      const signal = (obj) => peerEvent(id, PEER_SIGNAL, JSON.stringify(obj));
      pc.onnegotiationneeded = async () => {
        try {
          peer.makingOffer = true;
          await pc.setLocalDescription();
          signal({ description: pc.localDescription });
        } catch {} finally { peer.makingOffer = false; }
      };
      pc.onicecandidate = ({ candidate }) => { if (candidate) signal({ candidate: candidate.toJSON() }); };
      pc.onconnectionstatechange = () => {
        if (!peers.has(id)) return;
        const state = pc.connectionState;
        if (state === 'failed') pc.restartIce();
        if (state !== 'new') peerEvent(id, PEER_STATE, state);
      };
      pc.ontrack = (e) => {
        const s = e.streams[0] || new MediaStream([e.track]);
        let sid = peer.remote.get(s);
        if (!sid) {
          sid = nextRemote++;
          peer.remote.set(s, sid);
          streams.set(sid, s);
          attach(sid, s);
          const a = document.createElement('audio');
          a.autoplay = true;
          if (sinkId && a.setSinkId) a.setSinkId(sinkId).catch(() => {});
          a.srcObject = s;
          a.style.display = 'none';
          document.body.appendChild(a);
          peer.audio.push(a);
        }
        peerEvent(id, PEER_TRACK, '', sid);
      };
      if (stream) send(peer, stream);
      else {
        // Receive both even when sending nothing.
        pc.addTransceiver('audio', { direction: 'recvonly' });
        pc.addTransceiver('video', { direction: 'recvonly' });
        preferH264(pc);
      }
    },
    zui_peer_signal(id, ptr, len) {
      const peer = peers.get(id);
      if (!peer) return;
      let msg;
      try { msg = JSON.parse(str(ptr, len)); } catch { return; }
      const { pc } = peer;
      // One signal at a time, in order: descriptions must not interleave.
      peer.queue = peer.queue.then(async () => {
        if (msg.description) {
          const d = msg.description;
          const collision = d.type === 'offer' && (peer.makingOffer || pc.signalingState !== 'stable');
          peer.ignoreOffer = !peer.polite && collision;
          if (peer.ignoreOffer) return;
          await pc.setRemoteDescription(d);
          if (d.type === 'offer') {
            await pc.setLocalDescription();
            peerEvent(id, PEER_SIGNAL, JSON.stringify({ description: pc.localDescription }));
          }
        } else if (msg.candidate) {
          try { await pc.addIceCandidate(msg.candidate); } catch (e) { if (!peer.ignoreOffer) throw e; }
        }
      }).catch(() => {});
    },
    zui_peer_stream(id, stream) {
      const peer = peers.get(id);
      if (peer) send(peer, stream);
    },
    zui_peer_close(id) {
      const peer = peers.get(id);
      if (!peer) return;
      peers.delete(id);
      peer.pc.close();
      for (const a of peer.audio) a.remove();
      for (const sid of peer.remote.values()) streams.delete(sid);
    },
  };

  return {
    imports,
    streams,
    destroy() {
      for (const id of [...peers.keys()]) imports.zui_peer_close(id);
      for (const id of [...streams.keys()]) imports.zui_media_close(id);
    },
  };
}

// Borders are drawn over the box (a ::before), as Android and iOS draw them, so children stay
// where zui put them; inputs, pictures and scroll views keep real ones.
function setBorders(el, widths, colors, dashed) {
  const style = dashed ? 'dashed' : 'solid';
  if (el._realBorder) {
    const sides = ['Top', 'Right', 'Bottom', 'Left'];
    for (let k = 0; k < 4; k++) el.style['border' + sides[k]] = widths[k] > 0 ? `${widths[k]}px ${style} ${css(colors[k])}` : '0';
    return;
  }
  if (!(widths[0] > 0 || widths[1] > 0 || widths[2] > 0 || widths[3] > 0)) {
    if (el._bordered) {
      el.classList.remove('zui-b');
      el._bordered = false;
    }
    return;
  }
  el._bordered = true;
  el.classList.add('zui-b');
  el.style.setProperty('--zui-bw', widths.map((w) => w + 'px').join(' '));
  el.style.setProperty('--zui-bc', colors.map(css).join(' '));
  if (dashed) el.style.setProperty('--zui-bs', 'dashed'); else el.style.removeProperty('--zui-bs');
}

// Styling and interaction: decorations (per-corner radii, per-side borders, a shadow, a
// gradient), rich text with links, long press / context menu / hover, pictures from memory,
// how pictures fit, transitions, spinners, scrolling.
function webStyle(views, getEx, getMemory, str, decoder, measurer) {
  // Spans travel as 5 words: start, length (bytes), flags, colour, link.
  const fillRich = (el, ptr, len, sptr, count, weight, id) => {
    const mem = getMemory().buffer;
    const w = count === 0 ? [] : new Int32Array(mem, sptr >>> 0, count * 5);
    const bytes = len === 0 ? new Uint8Array(0) : new Uint8Array(mem, ptr >>> 0, len);
    const text = (a, b) => decoder.decode(bytes.subarray(a, b));
    const parts = [];
    let at = 0;
    for (let k = 0; k < count; k++) {
      const start = w[5 * k], n = w[5 * k + 1], flags = w[5 * k + 2], color = w[5 * k + 3] >>> 0, link = w[5 * k + 4];
      if (start > at) parts.push(document.createTextNode(text(at, start)));
      const sp = document.createElement('span');
      sp.textContent = text(start, start + n);
      if (flags & 1) sp.style.fontWeight = String(Math.max(weight, 700));
      if (flags & 2) sp.style.fontStyle = 'italic';
      if (flags & 4) sp.style.fontFamily = 'var(--zui-mono, monospace)';
      const lines = [flags & 8 ? 'underline' : '', flags & 16 ? 'line-through' : ''].filter(Boolean).join(' ');
      if (lines) sp.style.textDecoration = lines;
      if (color >>> 24) sp.style.color = css(color);
      if (link >= 0 && id) {
        sp.style.cursor = 'pointer';
        // The link takes the press, not a pressable view around the text.
        sp.onpointerdown = (e) => e.stopPropagation();
        sp.onclick = (e) => { e.stopPropagation(); getEx().zui_span_press(id, link); };
      }
      parts.push(sp);
      at = start + n;
    }
    if (at < len) parts.push(document.createTextNode(text(at, len)));
    el.replaceChildren(...parts);
  };

  const memImages = new Map();

  const imports = {
    zui_decor(id, ptr) {
      const el = views.get(id), s = el.style;
      const mem = getMemory().buffer;
      const f = new Float32Array(mem, ptr >>> 0, 31), u = new Uint32Array(mem, ptr >>> 0, 31);
      s.borderRadius = `${f[0]}px ${f[1]}px ${f[2]}px ${f[3]}px`;
      setBorders(el, [f[4], f[5], f[6], f[7]], [u[8], u[9], u[10], u[11]], u[30] !== 0);
      s.boxShadow = u[12] >>> 24 ? `${f[13]}px ${f[14]}px ${f[15]}px ${css(u[12])}` : '';
      const n = u[17];
      if (n > 0) {
        const stops = [];
        for (let k = 0; k < n; k++) stops.push(`${css(u[18 + k])} ${(f[24 + k] * 100).toFixed(3)}%`);
        s.backgroundImage = `linear-gradient(${f[16]}deg, ${stops.join(', ')})`;
      }
    },
    zui_rich_text(id, ptr, len, sptr, count, size, weight, lineHeight, mono, maxLines, color, align, letter) {
      const el = views.get(id);
      fillRich(el, ptr, len, sptr, count, weight, id);
      setFont(el, size, weight, lineHeight, mono, letter);
      setMaxLines(el, maxLines);
      el.style.color = css(color);
      el.style.textAlign = ALIGN[align];
    },
    zui_measure_rich(ptr, len, sptr, count, size, weight, lineHeight, mono, maxLines, maxWidth, out, letter) {
      fillRich(measurer, ptr, len, sptr, count, weight, 0);
      setFont(measurer, size, weight, lineHeight, mono, letter);
      measurer.style.maxWidth = Number.isFinite(maxWidth) ? maxWidth + 'px' : 'none';
      const r = measurer.getBoundingClientRect();
      let h = r.height;
      if (maxLines > 0) h = Math.min(h, maxLines * lineHeight);
      new Float32Array(getMemory().buffer, out, 2).set([Math.ceil(r.width), Math.ceil(h)]);
    },
    zui_gestures(id, flags) {
      const el = views.get(id);
      // Long press (1) or context menu (2): the browser's own menu (and iOS's callout) give way.
      const menu = (flags & 3) !== 0;
      el.oncontextmenu = menu ? (e) => { e.preventDefault(); e.stopPropagation(); getEx().zui_event(id, 4); } : null;
      el.style.webkitTouchCallout = menu ? 'none' : '';
      // Hover (4): the mouse only, not a finger.
      el._hover = (flags & 4) !== 0;
      if (el._hover && !el._hoverListening) {
        el._hoverListening = true;
        el.addEventListener('pointerenter', (e) => { if (el._hover && e.pointerType === 'mouse') getEx().zui_event(id, 5); });
        el.addEventListener('pointerleave', (e) => { if (el._hover && e.pointerType === 'mouse') getEx().zui_event(id, 6); });
      }
    },
    zui_image_bytes(id, kptr, klen, bptr, blen) {
      const el = views.get(id);
      const key = str(kptr, klen);
      el._want = '\n' + key;
      let url = memImages.get(key);
      if (url) {
        memImages.delete(key);
        memImages.set(key, url);
      } else {
        const data = blen === 0 ? new Uint8Array(0) : new Uint8Array(getMemory().buffer, bptr >>> 0, blen).slice();
        url = URL.createObjectURL(new Blob([data]));
        memImages.set(key, url);
        if (memImages.size > 200) {
          const [oldest, u] = memImages.entries().next().value;
          memImages.delete(oldest);
          setTimeout(() => URL.revokeObjectURL(u), 10000);
        }
      }
      if (el.getAttribute('src') !== url) el.src = url;
    },
    zui_image_fit(id, fit) {
      views.get(id).style.objectFit = ['fill', 'cover', 'contain'][fit] || 'fill';
    },
    zui_transition(id, ms, x1, y1, x2, y2) {
      const el = views.get(id);
      if (!ms) return void (el.style.transition = '');
      const how = `${ms}ms cubic-bezier(${x1},${y1},${x2},${y2})`;
      el.style.transition = ['opacity', 'transform', 'left', 'top', 'width', 'height'].map((p) => `${p} ${how}`).join(',');
    },
    zui_spin(id, ms) {
      const el = views.get(id);
      el._spin?.cancel();
      // The `rotate` property turns on top of the view's own transform.
      el._spin = ms ? el.animate([{ rotate: '0deg' }, { rotate: '360deg' }], { duration: ms, iterations: Infinity }) : null;
    },
    zui_scroll_to(id, offset, animated) {
      const el = views.get(id);
      el.scrollTo({ [el._horizontal ? 'left' : 'top']: offset, behavior: animated ? 'smooth' : 'instant' });
    },
  };
  return { imports };
}

// Barcode scanners (fx.scanBarcode): the camera's stream is kept under the scanner's id, so
// ui.video(id) shows it; five times a second a frame goes to the browser's BarcodeDetector where
// it has one, else to zui.barcode in the app (its luminance, at most 960 wide).
function webScan(getEx, getMemory, withBytes, encoder, streams) {
  const scanners = new Map();
  const FORMATS = [['code_128', 1], ['qr_code', 2]];
  const state = (id, kind, why = '') => withBytes(encoder.encode(why), (p, n) => getEx().zui_scan_state(id, kind, p, n));
  const imports = {
    zui_scan_open(id, formats, back) {
      const s = { live: true, timer: 0, stream: null, detector: null };
      scanners.set(id, s);
      const ask = navigator.mediaDevices?.getUserMedia?.({ video: { facingMode: back ? 'environment' : 'user', width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false });
      if (!ask) return void setTimeout(() => state(id, 3, 'unsupported'));
      ask.then(async (stream) => {
        if (!s.live) return void stream.getTracks().forEach((t) => t.stop());
        s.stream = stream;
        streams.set(id, stream);
        for (const v of document.querySelectorAll('video')) if (v._stream === id && v.srcObject !== stream) v.srcObject = stream;
        // Frames come from a video element of our own: the app may show none.
        const video = document.createElement('video');
        video.muted = true;
        video.playsInline = true;
        video.srcObject = stream;
        await video.play().catch(() => {});
        const wanted = FORMATS.filter(([, bit]) => formats & bit).map(([name]) => name);
        if ('BarcodeDetector' in window) {
          try {
            const supported = await window.BarcodeDetector.getSupportedFormats();
            if (wanted.every((f) => supported.includes(f))) s.detector = new window.BarcodeDetector({ formats: wanted });
          } catch {}
        }
        const canvas = document.createElement('canvas');
        const g = canvas.getContext('2d', { willReadFrequently: true });
        state(id, 1);
        const tick = async () => {
          if (!s.live) return;
          if (video.videoWidth > 0) {
            if (s.detector) {
              try {
                for (const code of await s.detector.detect(video)) {
                  const fmt = code.format === 'qr_code' ? 2 : 1;
                  withBytes(encoder.encode(code.rawValue), (p, n) => getEx().zui_scan_found(id, fmt, p, n));
                  break;
                }
              } catch {}
            } else {
              const k = Math.min(1, 960 / video.videoWidth);
              const w = Math.round(video.videoWidth * k), h = Math.round(video.videoHeight * k);
              canvas.width = w;
              canvas.height = h;
              g.drawImage(video, 0, 0, w, h);
              const rgba = g.getImageData(0, 0, w, h).data;
              const gray = new Uint8Array(w * h);
              for (let i = 0, j = 0; j < gray.length; i += 4, j++) gray[j] = (rgba[i] * 77 + rgba[i + 1] * 150 + rgba[i + 2] * 29) >> 8;
              withBytes(gray, (p) => getEx().zui_scan_frame(id, p, w, h));
            }
          }
          if (s.live) s.timer = setTimeout(tick, 200);
        };
        tick();
      }, (e) => { if (s.live) state(id, 3, e?.name === 'NotAllowedError' ? 'denied' : 'unavailable'); });
    },
    zui_scan_close(id) {
      const s = scanners.get(id);
      if (!s) return;
      scanners.delete(id);
      s.live = false;
      clearTimeout(s.timer);
      s.stream?.getTracks().forEach((t) => t.stop());
      streams.delete(id);
    },
  };
  return { imports, destroy() { for (const id of [...scanners.keys()]) imports.zui_scan_close(id); } };
}

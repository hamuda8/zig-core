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

const KIND_VIEW = 0, KIND_TEXT = 1, KIND_INPUT = 2, KIND_SCROLL = 3, KIND_SCROLL_X = 4, KIND_IMAGE = 5, KIND_PATH = 6;
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

function setFont(el, size, weight, lineHeight, mono) {
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
  sheet.textContent = 'input::placeholder{color:var(--zui-placeholder);opacity:1}';
  document.head.appendChild(sheet);
  const views = new Map([[0, root]]);
  let frameRequested = false;

  // Text is measured in an invisible element with the same font and wrapping as text views.
  const measurer = document.createElement('div');
  measurer.style.cssText = 'position:absolute;left:0;top:0;visibility:hidden;white-space:pre-wrap;overflow-wrap:break-word;';
  measurer.dir = 'auto';
  mount.appendChild(measurer);

  // Copies bytes into wasm memory for one call.
  const withBytes = (bytes, fn) => {
    const ptr = ex.zui_alloc(Math.max(1, bytes.length));
    new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
    try { fn(ptr, bytes.length); } finally { ex.zui_free(ptr, Math.max(1, bytes.length)); }
  };
  const sendText = (id, s) => withBytes(encoder.encode(s), (p, n) => ex.zui_text_event(id, p, n));
  let watchId = null;
  const sockets = new Map();

  const imports = {
    zui: {
      zui_create(id, kind) {
        const el = kind === KIND_PATH ? document.createElementNS(SVG, 'svg')
          : document.createElement(kind === KIND_INPUT ? 'input' : kind === KIND_IMAGE ? 'img' : 'div');
        el.style.position = 'absolute';
        el.style.boxSizing = 'border-box';
        el.style.margin = '0';
        if (kind === KIND_TEXT) {
          el.style.whiteSpace = 'pre-wrap';
          el.style.overflowWrap = 'break-word';
          el.dir = 'auto';
        } else if (kind === KIND_INPUT) {
          el.style.border = '0';
          el.style.padding = '0';
          el.style.background = 'transparent';
          el.style.outline = 'none';
          el.dir = 'auto';
          el.addEventListener('input', () => sendText(id, el.value));
          el.addEventListener('focus', () => ex.zui_input_event(id, INPUT_FOCUS));
          el.addEventListener('blur', () => { if (!el._removed) ex.zui_input_event(id, INPUT_BLUR); });
          el.addEventListener('keydown', (e) => { if (e.key === 'Enter') ex.zui_input_event(id, INPUT_SUBMIT); });
        } else if (kind === KIND_IMAGE) {
          el.draggable = false;
          el.alt = '';
          el.decoding = 'async';
          el.style.userSelect = 'none';
          el.style.pointerEvents = 'none';
        } else if (kind === KIND_PATH) {
          el.style.overflow = 'visible';
          el.style.pointerEvents = 'none';
          el._line = document.createElementNS(SVG, 'path');
          el.appendChild(el._line);
        } else if (kind === KIND_SCROLL || kind === KIND_SCROLL_X) {
          el.style.overflow = 'hidden';
          el.style.overscrollBehavior = 'contain';
          el.style.scrollbarWidth = 'thin';
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
        const s = views.get(id).style;
        s.background = css(bg);
        s.borderRadius = radius + 'px';
        s.border = borderWidth > 0 ? `${borderWidth}px solid ${css(borderColor)}` : '0';
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
        el.onpointerdown = (e) => { down = true; el.setPointerCapture?.(e.pointerId); ex.zui_event(id, EVENT_PRESS_IN); };
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
      zui_text(id, ptr, len, size, weight, lineHeight, mono, maxLines, color, align) {
        const el = views.get(id);
        el.textContent = str(ptr, len);
        setFont(el, size, weight, lineHeight, mono);
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
      zui_image(id, ptr, len) {
        const el = views.get(id);
        const url = str(ptr, len);
        if (el.getAttribute('src') !== url) el.src = url;
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
        const init = { method, headers: {} };
        for (const line of str(hptr, hlen).split('\n')) {
          const at = line.indexOf(': ');
          if (at > 0) init.headers[line.slice(0, at)] = line.slice(at + 2);
        }
        if (blen > 0) {
          init.body = new Uint8Array(memory.buffer, bptr >>> 0, blen).slice();
          init.headers['content-type'] = str(cptr, clen);
        }
        fetch(url, init)
          .then(async (res) => ({ status: res.status, body: new Uint8Array(await res.arrayBuffer()) }))
          .catch(() => ({ status: 0, body: new Uint8Array(0) }))
          .then(({ status, body }) => withBytes(body, (p, n) => ex.zui_fetch_done(id, status, p, n)));
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
        if (link !== location.pathname + location.search) history.replaceState(null, '', link);
      },
      zui_image_filter(id, s, c, b) {
        views.get(id).style.filter = s === 1 && c === 1 && b === 1 ? '' : `saturate(${s}) contrast(${c}) brightness(${b})`;
      },
      zui_focus(id) {
        views.get(id)?.focus();
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
      zui_root_background(argb) {
        const c = css(argb);
        root.style.background = c;
        if (!embedded) document.documentElement.style.background = c;
      },
      zui_log(ptr, len) {
        console.error(str(ptr, len));
      },
      zui_measure(ptr, len, size, weight, lineHeight, mono, maxLines, maxWidth, out) {
        measurer.textContent = str(ptr, len);
        setFont(measurer, size, weight, lineHeight, mono);
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
  return {
    instance,
    send,
    destroy() {
      observer?.disconnect();
      removeEventListener('resize', onResize);
      removeEventListener('message', onMessage);
      dark.removeEventListener('change', onDark);
      if (watchId !== null) navigator.geolocation?.clearWatch(watchId);
      for (const s of sockets.values()) s.close();
      mount.replaceChildren();
    },
  };
}

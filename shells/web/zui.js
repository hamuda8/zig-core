// Fixed web shim for every zui app. It keeps one DOM element per view, puts it exactly where the
// Zig layout engine says, measures text, and passes events back. It never changes per screen:
// everything visible is decided in Zig.
//
// The page sets the fonts with CSS variables: --zui-font and --zui-mono.

const KIND_VIEW = 0, KIND_TEXT = 1, KIND_INPUT = 2, KIND_SCROLL = 3, KIND_SCROLL_X = 4, KIND_IMAGE = 5, KIND_PATH = 6;
const POINTER_DOWN = 1, POINTER_MOVE = 2, POINTER_UP = 3, POINTER_CANCEL = 4, POINTER_WHEEL = 5;
const SVG = 'http://www.w3.org/2000/svg';
const EVENT_PRESS_IN = 1, EVENT_PRESS_OUT = 2, EVENT_PRESS = 3;
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

export async function start(wasmUrl, mount = document.body) {
  let ex, memory;
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  // Empty Zig slices may carry any pointer, so they are never dereferenced.
  const str = (ptr, len) => (len === 0 ? '' : decoder.decode(new Uint8Array(memory.buffer, ptr >>> 0, len)));

  const root = document.createElement('div');
  root.style.cssText = 'position:fixed;inset:0;overflow:hidden;';
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

  const sendText = (id, s) => {
    const bytes = encoder.encode(s);
    const ptr = ex.zui_alloc(Math.max(1, bytes.length));
    new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
    ex.zui_text_event(id, ptr, bytes.length);
    ex.zui_free(ptr, Math.max(1, bytes.length));
  };

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
        } else if (kind === KIND_IMAGE) {
          el.draggable = false;
          el.alt = '';
          el.decoding = 'async';
          el.style.userSelect = 'none';
          el.style.pointerEvents = 'none';
        } else if (kind === KIND_PATH) {
          el.style.overflow = 'visible';
          el.style.pointerEvents = 'none';
          el._line = document.createElementNS(SVG, 'polyline');
          el._line.setAttribute('fill', 'none');
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
        views.get(id)?.remove();
        views.delete(id);
      },
      zui_insert(parent, id, index) {
        const p = views.get(parent);
        const box = p._content || p;
        const el = views.get(id);
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
      zui_transform(id, rotate, tilt, perspective) {
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
      zui_path(id, ptr, count, color, width, dashOn, dashOff, round) {
        const line = views.get(id)._line;
        const f = new Float32Array(memory.buffer, ptr >>> 0, count * 2);
        let points = '';
        for (let i = 0; i < count; i++) points += `${f[2 * i].toFixed(1)},${f[2 * i + 1].toFixed(1)} `;
        line.setAttribute('points', points);
        line.setAttribute('stroke', css(color));
        line.setAttribute('stroke-width', String(width));
        line.setAttribute('stroke-linecap', round ? 'round' : 'butt');
        line.setAttribute('stroke-linejoin', round ? 'round' : 'miter');
        if (dashOn > 0) line.setAttribute('stroke-dasharray', `${dashOn} ${dashOff}`);
        else line.removeAttribute('stroke-dasharray');
      },
      zui_request_frame() {
        if (frameRequested) return;
        frameRequested = true;
        requestAnimationFrame(() => { frameRequested = false; ex.zui_frame(); });
      },
      zui_root_background(argb) {
        const c = css(argb);
        root.style.background = c;
        document.documentElement.style.background = c;
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

  const { instance } = await WebAssembly.instantiateStreaming(fetch(wasmUrl), imports);
  ex = instance.exports;
  memory = ex.memory;

  // Safe-area insets (notches) come from CSS env() through a probe element.
  const probe = document.createElement('div');
  probe.style.cssText = 'position:fixed;visibility:hidden;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);';
  mount.appendChild(probe);
  const insets = () => {
    const s = getComputedStyle(probe);
    return [s.paddingTop, s.paddingRight, s.paddingBottom, s.paddingLeft].map(parseFloat);
  };
  const dark = matchMedia('(prefers-color-scheme: dark)');

  const lang = encoder.encode(navigator.language || 'en');
  const langPtr = ex.zui_alloc(lang.length);
  new Uint8Array(memory.buffer, langPtr, lang.length).set(lang);
  ex.zui_start(innerWidth, innerHeight, dark.matches ? 1 : 0, ...insets(), langPtr, lang.length);
  ex.zui_free(langPtr, lang.length);
  addEventListener('resize', () => {
    ex.zui_insets(...insets());
    ex.zui_resize(innerWidth, innerHeight);
  });
  dark.addEventListener('change', () => ex.zui_dark(dark.matches ? 1 : 0));
  return instance;
}

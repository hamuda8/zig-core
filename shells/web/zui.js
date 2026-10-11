// Fixed web shim for every zui app. It loads the app's wasm module and provides the few DOM
// calls the module imports. It never changes per screen: everything visible is decided in Zig.

export async function start(wasmUrl, root = document.body) {
  let memory;
  const decoder = new TextDecoder();
  const str = (ptr, len) => decoder.decode(new Uint8Array(memory.buffer, ptr, len));

  const imports = {
    zui: {
      zui_show_text(ptr, len) {
        const el = document.createElement('div');
        el.className = 'zui-text';
        el.textContent = str(ptr, len);
        root.replaceChildren(el);
      },
    },
  };

  const { instance } = await WebAssembly.instantiateStreaming(fetch(wasmUrl), imports);
  memory = instance.exports.memory;
  instance.exports.zui_start();
  return instance;
}

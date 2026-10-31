// Yomitan's code resolves bundled assets with chrome.runtime.getURL; serve them from our scheme instead.
globalThis.chrome ??= {};
globalThis.chrome.runtime ??= {};
globalThis.chrome.runtime.getURL ??= (path) => new URL(path, location.href).href;

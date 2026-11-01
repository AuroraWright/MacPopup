Vendored from https://github.com/yomidevs/yomitan at commit d3c54c10264673eca0d66b970ef74cd5c8b048e3 (GPL-3.0).

Every file under `ext/` is identical to that commit, except `ext/lib/handlebars.js` and `ext/lib/linkedom.js`,
which Yomitan builds from its npm dependencies (`npm run build-libs`) instead of checking them in.

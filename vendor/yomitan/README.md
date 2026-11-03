Vendored from https://github.com/yomidevs/yomitan at commit ac1d839f9fe4d7f852381b693bba2b159b5c943a (GPL-3.0).

Every file under `ext/` is identical to that commit, except `ext/lib/handlebars.js` and `ext/lib/linkedom.js`,
which Yomitan builds from its npm dependencies (`npm run build-libs`) instead of checking them in.

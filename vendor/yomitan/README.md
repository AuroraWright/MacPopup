Vendored from OwOtan (https://github.com/AuroraWright/owotan), a fork of Yomitan (https://github.com/yomidevs/yomitan),
at commit bdf2c8422aab43e61cc5ff8acdfa6cfa3b336fba, which is based on Yomitan's commit
ee81f8dcf13e985bb4d7961009fb49a764b4d924 (GPL-3.0).

Every file under `ext/` is identical to that commit, except `ext/lib/handlebars.js` and `ext/lib/linkedom.js`,
which Yomitan builds from its npm dependencies (`npm run build-libs`) instead of checking them in.

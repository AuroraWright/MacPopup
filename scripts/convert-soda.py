#!/usr/bin/env python3
"""Packages Chrome's Live Caption (SODA) language packs for MacPopup's "Read text from audio".

Downloads the packs from Chrome's update server, the way Chrome's component updater does, and packs them into a zip.
In MacPopup, load it in Settings > Transcription > Live Caption models. MacPopup runs the packs' models itself; Chrome
isn't needed.

The packs are Google's: they're for your own use, don't share them or the zip.

Needs Python 3 with marisa-trie (to read the packs' symbol tables):
    python3 -m venv ~/soda-venv
    ~/soda-venv/bin/pip install marisa-trie
    ~/soda-venv/bin/python scripts/convert-soda.py ja-JP en-US [-o SODA.zip]

LOCALE is one or more of the packs below, or "all" (1.8 GB in all, 100-200 MB each). MacPopup reads a language with
its pack; one Live Caption has no pack for gets the first one listed.
"""

import argparse
import json
import shutil
import struct
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

try:
    import marisa_trie
except ImportError:
    sys.exit("marisa-trie is missing. Install it first:\n    pip install marisa-trie")

UPDATE_URL = "https://update.googleapis.com/service/update2/json"
# The component ids of Chrome's SODA language packs.
APP_IDS = {
    "ja-JP": "onhpjgkfgajmkkeniaoflicgokpaebfa",
    "en-US": "oegebmmcimckjhkhbggblnkjloogjdfg",
    "de-DE": "jclgnikdalajmocbnlgieibfmlejnhmg",
    "fr-FR": "goaoclndmgofblfopkopecdpfhljclbd",
    "es-ES": "jkcckmaejhmbhagbcebpejbihcnighdb",
    "it-IT": "jhefnhlmpagbceldaobdpcjhkknfjohi",
    "ru-RU": "njmnbpiilokhobofgcilobdmpgdkfefo",
    "ko-KR": "cogjdigcnchhklfjkhalghhfebjpdjhb",
    "hi-IN": "aolgaekiiglfhnjgagdljeilgegpfecn",
    "pt-BR": "anfcoadblmjplmkgmahlkhgnngkhoben",
    "id-ID": "kcganlnenpblkkhbnppfigiochoedgnh",
    "pl-PL": "dpkgmjeebdgklolimcncdakahbaoklpm",
    "th-TH": "olcokbjilkakbaknajbfokboieipblel",
    "tr-TR": "ifacfjnibplkincdecpkkedmekgfeoaj",
    "vi-VN": "bpnckojighgibleldbofdjmfdipfeiak",
    "cmn-Hans-CN": "plffpkkhdibnpffncjpflnolflkpgjno",
    "cmn-Hant-TW": "jblddigdjechninjlbkjjeiadfgmlpoc",
}


def update_check(app_id):
    """The pack's current version and download URL."""
    request = {"request": {
        "protocol": "3.1", "acceptformat": "crx3,puff", "prodversion": "157.0.8103.79",
        "os": {"platform": "Mac OS X", "arch": "arm64"}, "arch": "arm64", "nacl_arch": "arm64",
        "apps": [{"appid": app_id, "version": "0.0.0.0", "updatecheck": {}}]}}
    req = urllib.request.Request(UPDATE_URL, data=json.dumps(request).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        reply = json.loads(r.read()[4:])  # after the )]}' guard
    check = reply["response"]["app"][0]["updatecheck"]
    if check.get("status") != "ok":
        raise RuntimeError(f"the update server has no pack ({check.get('status')})")
    package = check["manifest"]["packages"]["package"][0]
    return check["manifest"]["version"], check["urls"]["url"][-1]["codebase"] + package["name"]


def fetch(locale, tmp, target):
    """Downloads the pack and moves its SODAModels folder to `target`; returns the version."""
    version, url = update_check(APP_IDS[locale])
    print(f"Downloading {locale} {version}", flush=True)
    crx = tmp / "pack.crx3"
    urllib.request.urlretrieve(url, crx)
    data = crx.read_bytes()
    # The CRX3 header is checked, not its signature.
    if data[:4] != b"Cr24":
        raise RuntimeError(f"{url} isn't a CRX3 file")
    header = struct.unpack("<I", data[8:12])[0]
    archive = tmp / "pack.zip"
    archive.write_bytes(data[12 + header:])
    crx.unlink()
    unpacked = (tmp / "pack").resolve()
    with zipfile.ZipFile(archive) as z:
        for name in z.namelist():
            if not (unpacked / name).resolve().is_relative_to(unpacked):
                raise RuntimeError(f"{url} has an unsafe path: {name!r}")
        z.extractall(unpacked)
    archive.unlink()
    if not (unpacked / "SODAModels").is_dir():
        raise RuntimeError(f"{url} has no SODAModels folder")
    (unpacked / "SODAModels").rename(target)
    return version


def symbols(buf):
    """A CompactSymbolTable (a MARISA trie of the strings and their ids) as a list: symbol id -> string."""
    off = 4
    for _ in range(2):
        n, = struct.unpack_from("<i", buf, off)
        off += 4 + n
    trie_size, = struct.unpack_from("<Q", buf, off)
    off = (off + 8 + 15) & ~15
    trie = marisa_trie.Trie()
    trie.frombytes(bytes(buf[off:off + trie_size]))
    off += trie_size + 8
    off = (off + 15) & ~15
    element, _ = struct.unpack_from("<QQ", buf, off)
    off += 16
    n = len(trie)
    keys = struct.unpack_from(f"<{n}{'H' if element == 2 else 'I'}", buf, off)
    return [trie.restore_key(k - 1) if 0 < k <= n else "" for k in keys]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog="Packs: " + " ".join(APP_IDS))
    ap.add_argument("locales", nargs="+", metavar="LOCALE", help='packs to download, or "all"')
    ap.add_argument("-o", "--output", default="SODA.zip", help="the archive to write")
    a = ap.parse_args()
    locales = list(APP_IDS) if a.locales == ["all"] else list(dict.fromkeys(a.locales))
    unknown = [l for l in locales if l not in APP_IDS]
    if unknown:
        ap.error(f"no pack {', '.join(unknown)}; the packs are: {' '.join(APP_IDS)}")
    output = Path(a.output).expanduser().resolve()

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        root = tmp / "zip"
        root.mkdir()
        versions = {}
        for index, locale in enumerate(locales):
            work = tmp / f"download{index}"
            work.mkdir()
            try:
                versions[locale] = fetch(locale, work, root / locale)
            except Exception as error:
                sys.exit(f"{locale}: {error}")
            # MacPopup reads the symbol tables as JSON, next to Chrome's: x.syms.compact -> x.syms.json.
            for table in (root / locale).rglob("*.syms.compact"):
                table.with_suffix(".json").write_text(
                    json.dumps(symbols(table.read_bytes()), ensure_ascii=False))
        (root / "soda.json").write_text(json.dumps(
            {"format": 1, "languages": locales, "versions": versions}, indent=1))
        print("Packing", flush=True)
        partial = output.with_name(output.name + ".partial")
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED) as z:
            for path in sorted(root.rglob("*")):
                if path.is_file():
                    z.write(path, path.relative_to(root).as_posix())
        partial.replace(output)
    print(f"Wrote {output}")
    print("In MacPopup, choose Settings > Transcription > Live Caption models > Load, and pick this file.")


if __name__ == "__main__":
    main()

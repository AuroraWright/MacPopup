# Converts the C++ table includes of screen_ai_research/cpp/src into Swift arrays.
import re, sys, os
src, dst = sys.argv[1], sys.argv[2]
BIDI = "kL kR kEN kES kET kAN kCS kB kS kWS kON kLRE kLRO kAL kRLE kRLO kPDF kNSM kBN kFSI kLRI kRLI kPDI kENL kENR".split()
def arrays(text):
    # name, element C type, body
    for m in re.finditer(r'(?:static\s+)?(?:constexpr|const)\s+(?:static\s+)?([\w:<>, ]+?)\s+(k\w+)(\[\d*\])+\s*=\s*\{(.*?)\n\};', text, re.S):
        yield m.group(2), m.group(1), m.group(4)
def header(f, srcname):
    f.write(f"// Generated from screen_ai_research/cpp/src/{srcname} by scripts/gen-screenai-tables.py. Do not edit.\n\n")
def ints(body, enum=None):
    body = re.sub(r'//.*', '', body)
    toks = re.findall(r'0x[0-9A-Fa-f]+(?:ull|u)?|\d+(?:ull|u)?|k[A-Z]+', body)
    out = []
    for t in toks:
        if t.startswith('k'):
            out.append(str(BIDI.index(t)))
        else:
            out.append(t.rstrip('ul'))
    return out
def strs(body):
    body = re.sub(r'^\s*//.*$', '', body, flags=re.M)
    return re.findall(r'"((?:[^"\\]|\\.)*)"', body)
def emit(f, name, typ, vals, per_line=8):
    f.write(f"let {name}: [{typ}] = [\n")
    for i in range(0, len(vals), per_line):
        f.write("    " + ", ".join(vals[i:i + per_line]) + ",\n")
    f.write("]\n\n")
for inc in ["rune_tables.inc", "recognizer_unicode.inc", "recognizer_bidi.inc", "recognizer_langcode.inc"]:
    text = open(os.path.join(src, inc)).read()
    base = {"rune_tables.inc": "RuneTables", "recognizer_unicode.inc": "UnicodeTables",
            "recognizer_bidi.inc": "BidiTables", "recognizer_langcode.inc": "LangcodeTables"}[inc]
    with open(os.path.join(dst, base + ".swift"), "w") as f:
        header(f, inc)
        for name, ctype, body in arrays(text):
            if "string_view" in ctype:
                vals = ['"' + s + '"' for s in strs(body)]
                emit(f, name, "String", vals, 8)
            elif "uint64" in ctype:
                emit(f, name, "UInt64", ints(body), 4)
            elif "uint32" in ctype:
                emit(f, name, "UInt32", ints(body), 12)
            else:
                emit(f, name, "Int32", ints(body), 12)
        print(base, [n for n, _, _ in arrays(text)])

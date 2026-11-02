"""Writes Sources/OneOCR/CRTTables.swift from the tables of oneocr_native's crtmath.py (the CRT math routines that
oneocr.dll links statically: ARM optimized-routines and AMD libm).
usage: gen-oneocr-tables.py <folder containing oneocr_native> > Sources/OneOCR/CRTTables.swift"""
import struct
import sys

sys.path.insert(0, sys.argv[1])
from oneocr_native import crtmath as c

def bits(x):
    if isinstance(x, int):
        return x
    return struct.unpack("<Q", struct.pack("<d", x))[0]

def arr(name, vals, per=4):
    vals = [bits(v) for v in vals]
    out = [f"    static let {name}: [UInt64] = ["]
    for i in range(0, len(vals), per):
        out.append("        " + ", ".join(f"0x{v:016x}" for v in vals[i:i + per]) + ",")
    out.append("    ]")
    return "\n".join(out)

def iarr(name, vals, per=12):
    out = [f"    static let {name}: [Int] = ["]
    for i in range(0, len(vals), per):
        out.append("        " + ", ".join(f"0x{v:x}" for v in vals[i:i + per]) + ",")
    out.append("    ]")
    return "\n".join(out)

flat = lambda t: [x for p in t for x in p]
parts = [
    "// Generated: tables of the CRT math routines statically linked into oneocr.dll (ARM optimized-routines",
    "// and AMD libm), as IEEE double bit patterns, written by scripts/gen-oneocr-tables.py. See CRTMath.swift.",
    "",
    "enum CRTTables {",
    arr("log2T", flat(c._LOG2_T), 2),
    arr("log2A", c._LOG2_A),
    arr("exp2T", c._EXP2_T),
    arr("exp2C", c._EXP2_C + [c._EXP2_INVLN2_SCALED]),
    arr("logfT", flat(c._LOGF_T), 2),
    arr("logfA", c._LOGF_A + [c._LOGF_LN2]),
    arr("atanLead", c._ATAN_LEAD),
    arr("atanTail", c._ATAN_TAIL),
    arr("atanfT", c._ATANF_T),
    arr("sincosf0", c._SINCOSF_T[0]),
    arr("sincosf1", c._SINCOSF_T[1]),
    arr("sinS", c._S),
    arr("cosC", c._C),
    iarr("invPio4", c._INV_PIO4, 8),
    iarr("piBits", c._PIBITS),
    arr("powLogHdr", c._POW_LOG_HDR),
    arr("powLogTab", c._POW_LOG_TAB, 3),
    arr("powExpHdr", c._POW_EXP_HDR),
    arr("powExpTab", c._POW_EXP_TAB),
    "}",
    "",
]
print("\n".join(parts))

# Checks that every setting is used: each key of web/src/lib/settings-defaults.js's defaultSettings is read somewhere in
# web/src or Sources (besides the defaults, Settings' schema and Import Yomitan, which only show or write it), and every
# key read from the settings or shown in Settings is defined there. Prints what's wrong and exits with 1, else prints
# PASS. Usage: python3 -I scripts/check-settings.py [repo] (the repo this script is in by default; not part of
# scripts/build.sh). See Tests/README.md.
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULTS = 'web/src/lib/settings-defaults.js'
SCHEMA = 'Sources/MacPopup/SettingsSchema.swift'
# Files that name settings without acting on them: their reads don't count as uses.
NOT_USES = {DEFAULTS, SCHEMA, 'web/src/lib/yomitan-import.js'}
# Settings' field kinds that aren't settings (a row of others, or buttons and statuses).
NOT_SETTINGS = {'group', 'permission', 'convertedModels', 'iinaPlugin', 'iinaTranscripts'}
# Read from the settings without a default: the dictionaries' summaries a Yomitan with dictionaryInfo gives
# (yomitan-profile.js, and Import Yomitan).
UNDEFINED_READS = {'yomitanDictionaryInfo'}


def read(path):
    with open(os.path.join(ROOT, path), encoding='utf-8', errors='replace') as file:
        return file.read()


def without_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'(^|\s)//.*', r'\1', text, flags=re.M)


def sources():
    """(path, text) of the web code and the Swift sources, without comments ("see settings.js")."""
    for top in ('web/src', 'Sources'):
        for directory, _, names in os.walk(os.path.join(ROOT, top)):
            for name in sorted(names):
                if name.endswith(('.js', '.swift', '.css', '.html')):
                    path = os.path.relpath(os.path.join(directory, name), ROOT)
                    yield path, without_comments(read(path))


def defined():
    """defaultSettings' keys: the object's lines at one tab's indent."""
    text = read(DEFAULTS)
    body = re.search(r'^export const defaultSettings = \{\n(.*?)^\};', text, re.M | re.S)
    if not body:
        sys.exit(f'FAIL: no defaultSettings in {DEFAULTS}')
    return set(re.findall(r'^\t([A-Za-z_]\w*)\s*:', body.group(1), re.M))


def schema_keys():
    """The keys of Settings' fields that are settings, and the settings that fields name by argument (a shortcut's
    buttons, a font's size and effects)."""
    text = read(SCHEMA)
    keys = {key for key, kind in re.findall(r'SettingsField\(\s*"(\w+)",\s*"[^"\n]*",\s*\.(\w+)', text) if kind not in NOT_SETTINGS}
    keys |= set(re.findall(r'\b(?:buttons|size|effects):\s*"(\w+)"', text))
    return keys


def read_keys(path, text):
    """Keys the file reads from the settings: settings["key"] and SettingsStore's in Swift (and the schema's closures'
    values["key"]), settings.key and settings['key'] in the web code."""
    if path.endswith('.swift'):
        names = r'settings|values' if path == SCHEMA else r'settings'
        keys = re.findall(rf'\b(?:{names})\??\["(\w+)"\]', text)
        keys += re.findall(r'SettingsStore\.shared\.(?:string|int)\("(\w+)"\)', text)
        keys += re.findall(r'SettingsStore\.shared\.dictionary\["(\w+)"\]', text)
        return set(keys)
    if path.endswith('.js'):
        # Not a file name ('./settings.js') or a method.
        settings = r'(?:(?<![\w./])settings|\bgetSettings\(\))\??'
        keys = re.findall(rf'{settings}\.([A-Za-z_]\w*)\b(?!\s*\()', text)
        keys += re.findall(rf'{settings}\.?\[\s*[\'"](\w+)[\'"]\s*\]', text)
        return set(keys)
    return set()


def main():
    keys = defined()
    files = list(sources())
    problems = []
    # Defined, never read: the key in any form outside the files that only name it.
    for key in sorted(keys):
        k = re.escape(key)
        pattern = re.compile(rf"\.{k}\b|\[\s*['\"]{k}['\"]\s*\]|['\"]{k}['\"]|\{{[^{{}}]*\b{k}\b[^{{}}]*\}}\s*=\s*\w")
        if not any(pattern.search(text) for path, text in files if path not in NOT_USES):
            problems.append(f'defined but never read: {key}')
    # Read or shown in Settings, not defined.
    for key in sorted(schema_keys() - keys):
        problems.append(f'in Settings but not defined: {key} ({SCHEMA})')
    for path, text in files:
        if path == DEFAULTS:
            continue
        for key in sorted(read_keys(path, text) - keys - UNDEFINED_READS):
            problems.append(f'read but not defined: {key} ({path})')
    for problem in problems:
        print(problem)
    print(f'FAIL: {len(problems)} problems' if problems else f'PASS ({len(keys)} settings)')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())

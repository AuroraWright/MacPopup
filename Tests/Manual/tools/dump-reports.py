# Dumps a gamepad recording's reports between two times, with the bytes that changed from the first one marked, and
# GameController's state changes: dump-reports.py <recording.json> <from> <to> [bytes, e.g. 1-20]
import json, sys
path, start, end = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
data = json.load(open(path))
picked = None
if len(sys.argv) > 4:
    a, b = map(int, sys.argv[4].split('-')); picked = range(a, b + 1)
reports = [r for r in data['reports'] if start <= r['time'] <= end]
states = [s for s in data.get('states', []) if start <= s['time'] <= end]
base = reports[0]['bytes'] if reports else []
events = [(r['time'], 'r', r) for r in reports] + [(s['time'], 's', s) for s in states]
for time, kind, item in sorted(events, key=lambda e: e[0]):
    if kind == 's':
        print(f"{time:8.3f}  state {sorted(item['pressed'])} {dict((k, round(v, 2)) for k, v in item.get('analog', {}).items() if abs(v) > 0.05)}")
        continue
    bytes_ = item['bytes']
    indices = picked or range(len(bytes_))
    print(f"{time:8.3f}  " + ' '.join(('%02x' % bytes_[i]) + ('*' if i < len(base) and bytes_[i] != base[i] else ' ') for i in indices if i < len(bytes_)))

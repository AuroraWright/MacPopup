# profile-driver.py <idle|lookups>, for profile/*.test.js: samples the test instance's memory (phys_footprint, as
# Activity Monitor's Memory column) and CPU time every second, MacPopup's own and its WebKit processes' (the ones macOS
# holds it responsible for, or, when it was started from a shell as here, the WebKit services with the same
# responsible app started after it), and checks them against ceilings. The samples go to $RUN/samples.jsonl.
#   idle: the instance left alone (the Floating Window, nothing to read) for 15 s, then sampled for 45 s more;
#   lookups: from the start until the page's test is done (10 s after its lookups), then 5 s more; CPU per lookup is
#     from a sample taken when the page is about to look up (it logs "lookups ready" and waits for the driver's
#     "sampling") to one at its "lookups end".
# Ceilings: about 1.5x the most measured (2026-11-23, a release development build on an M1 Max, macOS 15; WebContent's
# peaks also 1.5x the 2026-11-20 profile's), see CEILINGS.
import ctypes, ctypes.util, json, os, subprocess, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import PID, RUN, check, log, logged, running, until

MODE = sys.argv[1]
MB = 1048576
# (Measured: see the comment of each.)
CEILINGS = {
    'idle': {
        'app': 45,           # MacPopup's footprint, MB (measured 26-30)
        'web': 100,          # WebContent's (the overlay's page), MB (measured 60-64; 64 in the 2026-11-20 profile)
        'all': 180,          # every process together, MB (measured 105-121)
        'growth': 4,         # how much the total may grow over the 45 s sampled, MB (measured +0.3 to +2.4)
        # CPU, % of one core: the median of the seconds sampled (steady even when someone moves the pointer, which the
        # app follows: seconds of 3-5% then), and the mean.
        'app_cpu': 1.9,      # MacPopup's median (measured 0.57-1.24)
        'all_cpu': 3.1,      # every process's median (measured 0.58-2.08)
        'app_cpu_mean': 2.7,  # MacPopup's mean (measured 0.76-1.79)
        'all_cpu_mean': 3.7,  # every process's mean (measured 0.93-2.48)
    },
    'lookups': {
        'app': 50,           # MacPopup's peak footprint, MB (measured 30-31)
        'web': 600,          # WebContent's peak, MB (measured 254-261; ~400 in the 2026-11-20 profile)
        'all': 750,          # every process's peak together, MB (measured 321-324; WebContent's 400 + the rest)
        'cpu_per_lookup': 490,  # CPU per lookup (each a hover, 0.4 s shown, then away), all processes, ms (measured 324)
    },
}[MODE]

libc = ctypes.CDLL(ctypes.util.find_library('c'))


class RUsageV4(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        'user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins', 'wired_size', 'resident_size',
        'phys_footprint', 'proc_start_abstime', 'proc_exit_abstime', 'child_user_time', 'child_system_time',
        'child_pkg_idle_wkups', 'child_interrupt_wkups', 'child_pageins', 'child_elapsed_abstime', 'diskio_bytesread',
        'diskio_byteswritten', 'cpu_time_qos_default', 'cpu_time_qos_maintenance', 'cpu_time_qos_background',
        'cpu_time_qos_utility', 'cpu_time_qos_legacy', 'cpu_time_qos_user_initiated', 'cpu_time_qos_user_interactive',
        'billed_system_time', 'serviced_system_time', 'logical_writes', 'lifetime_max_phys_footprint', 'instructions',
        'cycles', 'billed_energy', 'serviced_energy', 'interval_max_phys_footprint', 'runnable_time')]


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


timebase = Timebase()
libc.mach_timebase_info(ctypes.byref(timebase))
TICK_NS = timebase.numer / timebase.denom
responsible = ctypes.CDLL('/usr/lib/system/libquarantine.dylib').responsibility_get_pid_responsible_for_pid
responsible.argtypes = [ctypes.c_int]


def usage(pid):
    """(footprint MB, CPU seconds, start time in ticks) or None once it's gone."""
    info = RUsageV4()
    if libc.proc_pid_rusage(pid, 4, ctypes.byref(info)) != 0:
        return None
    return info.phys_footprint / MB, (info.user_time + info.system_time) * TICK_NS / 1e9, info.proc_start_abstime


def webkit_processes(app):
    """MacPopup's WebKit processes: {pid: name}."""
    owner, started = responsible(app), usage(app)[2]
    found = {}
    for line in subprocess.run(['ps', '-A', '-o', 'pid=,comm='], capture_output=True, text=True).stdout.splitlines():
        pid, _, command = line.strip().partition(' ')
        pid, name = int(pid), command.rsplit('/', 1)[-1]
        if pid == app or not name.startswith('com.apple.WebKit.'):
            continue
        u = usage(pid)
        if u and (responsible(pid) == app or (owner != app and responsible(pid) == owner and u[2] >= started)):
            found[pid] = name.removeprefix('com.apple.WebKit.')
    return found


app = int(PID)
until(lambda: webkit_processes(app), timeout=20)
names = {}
samples = []


def sample():
    for pid, name in webkit_processes(app).items():
        names.setdefault(pid, name)
    row = {'t': round(time.monotonic(), 2), 'procs': {}}
    for pid in [app, *names]:
        u = usage(pid)
        if u:
            row['procs'][f"{'MacPopup' if pid == app else names[pid]}:{pid}"] = {'mb': round(u[0], 1), 'cpu': round(u[1], 3)}
    samples.append(row)
    with open(f'{RUN}/samples.jsonl', 'a') as f:
        f.write(json.dumps(row) + '\n')
    return row


def total(row, kind=None):
    """MB of the processes of a kind ('MacPopup', 'WebContent', …; all when None) in a sample."""
    return sum(v['mb'] for k, v in row['procs'].items() if kind is None or k.startswith(kind + ':'))


def cpu(first, last, kind=None):
    """CPU seconds used between two samples by the processes of a kind (all when None), the ones in both."""
    return sum(v['cpu'] - first['procs'][k]['cpu'] for k, v in last['procs'].items()
               if k in first['procs'] and (kind is None or k.startswith(kind + ':')))


if MODE == 'idle':
    time.sleep(15)
    end = time.monotonic() + 45
    while time.monotonic() < end and running():
        sample()
        time.sleep(1)
else:
    sample()
    lookups_start = lookups_end = None
    next_sample = time.monotonic() + 1
    while running() and not logged('done', timeout=0):
        if lookups_start is None and logged('lookups ready', timeout=0):
            lookups_start = sample()
            log('sampling')
        elif lookups_start and lookups_end is None and logged('lookups end', timeout=0):
            lookups_end = sample()
        elif time.monotonic() >= next_sample:
            sample()
            next_sample += 1
        time.sleep(0.1)
    for _ in range(5):
        sample()
        time.sleep(1)

if not check(len(samples) >= 10 and running(), f'{len(samples)} samples, the app still running'):
    sys.exit(0)
# Without its WebContent process (e.g. WebKit's services renamed), its footprint and CPU would count as nothing.
if not check(any(k.startswith('WebContent:') for row in samples for k in row['procs']), "the instance's WebContent process found"):
    sys.exit(0)
log('processes: ' + ', '.join(sorted({k for row in samples for k in row['procs']})))
first, last = samples[0], samples[-1]
seconds = last['t'] - first['t']
c = CEILINGS
if MODE == 'idle':
    check(total(last, 'MacPopup') <= c['app'], f"MacPopup's footprint {total(last, 'MacPopup'):.1f} MB (ceiling {c['app']})")
    check(max(total(r, 'WebContent') for r in samples) <= c['web'],
          f"WebContent's footprint at most {max(total(r, 'WebContent') for r in samples):.1f} MB (ceiling {c['web']})")
    check(max(total(r) for r in samples) <= c['all'], f"all processes' at most {max(total(r) for r in samples):.1f} MB (ceiling {c['all']})")
    growth = total(last) - total(first)
    check(growth <= c['growth'], f'growth over {seconds:.0f} s: {growth:+.1f} MB (ceiling {c["growth"]})')
    pairs = list(zip(samples, samples[1:]))
    for kind, name, key in (('MacPopup', "MacPopup's", 'app_cpu'), (None, "all processes'", 'all_cpu')):
        per_second = sorted(100 * cpu(a, b, kind) / (b['t'] - a['t']) for a, b in pairs)
        median = per_second[len(per_second) // 2]
        mean = 100 * cpu(first, last, kind) / seconds
        check(median <= c[key], f"{name} CPU, median second: {median:.2f}% of a core (ceiling {c[key]})")
        check(mean <= c[key + '_mean'], f"{name} CPU, mean: {mean:.2f}% of a core (ceiling {c[key + '_mean']})")
else:
    shown = logged('popups ', timeout=0)
    lookups = int(shown.split()[1].split('/')[0]) if shown else 0
    peak_app = max(total(r, 'MacPopup') for r in samples)
    peak_web = max(total(r, 'WebContent') for r in samples)
    peak_all = max(total(r) for r in samples)
    check(peak_app <= c['app'], f"MacPopup's peak footprint {peak_app:.1f} MB (ceiling {c['app']})")
    check(peak_web <= c['web'], f"WebContent's peak footprint {peak_web:.1f} MB (ceiling {c['web']})")
    check(peak_all <= c['all'], f"all processes' peak {peak_all:.1f} MB (ceiling {c['all']})")
    log(f'at the end: MacPopup {total(last, "MacPopup"):.1f} MB, WebContent {total(last, "WebContent"):.1f} MB')
    if check(lookups > 0 and lookups_start and lookups_end, f'{lookups} lookups, sampled from before them to their end'):
        per = 1000 * cpu(lookups_start, lookups_end) / lookups
        check(per <= c['cpu_per_lookup'], f"CPU per lookup, all processes: {per:.0f} ms (ceiling {c['cpu_per_lookup']})")

# parallels-pause-driver.py, for parallels-pause.test.js: has the person open a Windows app in Parallels' Coherence
# mode, gives the page its window (tools/winapps.swift), and samples every process's state (ps) until the page is done:
# then checks the VM's processes were stopped while paused and only then, and that nothing else was stopped.
import json, os, re, subprocess, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
sys.path.insert(0, os.path.join(os.environ['REPO'], 'Tests/Manual'))
from driver import check, until
from manual import built, done, here, page_logs, prompt

VM = 'Parallels VM.app/Contents/MacOS/prl_vm_app'


def stopped():
    """The pids of the processes stopped now (ps state T)."""
    out = subprocess.run(['ps', '-axo', 'pid=,stat='], capture_output=True, text=True).stdout
    return {int(pid) for pid, stat in (line.split() for line in out.splitlines() if line.strip()) if stat.startswith('T')}


def page_time(name):
    return next((int(m.group(1)) for line in page_logs() if (m := re.match(rf'^{name} (\d+)$', line))), None)


try:
    prompt('Open a Windows app in Parallels in Coherence mode (a game, or Notepad), and leave its window on screen.')
    winapps = built(here('tools/winapps.swift'))
    found = until(lambda: subprocess.run([winapps], capture_output=True, text=True).stdout.splitlines(), timeout=300,
                  interval=1)
    if check(bool(found), f'a Coherence window is on screen: {found[0] if found else None}'):
        pid, owner, title, size = found[0].split('\t')
        before = stopped()
        vm = {int(p) for p in subprocess.run(['pgrep', '-f', VM], capture_output=True, text=True).stdout.split()}
        check(bool(vm), f"Parallels' VM processes: {sorted(vm)}")
        print('game: ' + json.dumps({'ownerName': owner, 'title': title}, ensure_ascii=False), flush=True)
        prompt(f'Watch {owner}: MacPopup pauses it for 8 s, then continues it. Don\'t click anything meanwhile.')
        print('watching', flush=True)
        samples = []
        end = time.monotonic() + 120
        while time.monotonic() < end and not any(line.startswith('done') for line in page_logs()):
            samples.append((int(time.time() * 1000), stopped()))
            time.sleep(0.2)
        paused, resuming = page_time('paused'), page_time('resuming')
        if check(bool(paused and resuming), f'the page paused and resumed: {paused}, {resuming}'):
            during = [s for t, s in samples if paused + 500 <= t <= resuming]
            check(during and all(vm <= s for s in during),
                  f'the VM is stopped while paused: {sum(vm <= s for s in during)} of {len(during)} samples')
            after = [s for t, s in samples if t >= resuming + 2000]
            check(after and not any(vm & s for s in after), f'the VM runs again after: {len(after)} samples')
            others = set().union(*(s for _, s in samples)) - before - vm
            names = {p: subprocess.run(['ps', '-o', 'comm=', '-p', str(p)], capture_output=True, text=True).stdout.strip()
                     for p in others}
            check(not others, f'nothing else was stopped: {names}')
        still = vm & stopped()
        if not check(not still, 'the VM is running at the end'):
            prompt("The VM is still stopped: it continues when the test instance quits (the pause helper's crash guard).")
finally:
    done()

# foreign-client-driver.py, for foreign-client.test.js: has pause-client (signed ad hoc) ask the pause helper to stop a
# sleep process of its own, and checks the helper was reached (launchd started it: its run count went up) and refused:
# no "stopped" reply, the process not stopped, the helper not crashed. (The helper takes the connection with a
# code-signing requirement on its messages; the client's request fails, the helper is idle and exits, and the client
# sees the connection interrupted: NSCocoaErrorDomain 4097.)
import os, re, signal, subprocess, sys, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import check, log, tool


def helper():
    """launchctl's record of the pause helper: {'runs': n, 'last exit code': ...}, or None when launchd doesn't know it."""
    out = subprocess.run(['launchctl', 'print', 'system/com.aury.macpopup.pause-helper'], capture_output=True, text=True)
    if out.returncode:
        return None
    return dict(re.findall(r'^\s+(runs|last exit code|state) = (.*)$', out.stdout, re.M))


before = helper()
if check(before is not None, 'the pause helper is loaded (launchd knows it; else allow it in Settings → Permissions)'):
    target = subprocess.Popen(['sleep', '60'])
    try:
        client = tool(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pause-client.swift'))
        signature = subprocess.run(['codesign', '-dv', client], capture_output=True, text=True).stderr
        check('Signature=adhoc' in signature, 'pause-client is signed ad hoc')
        answer = subprocess.run([client, str(target.pid)], capture_output=True, text=True, timeout=20).stdout.strip()
        log(f'pause-client: {answer}')
        state = subprocess.run(['ps', '-o', 'stat=', '-p', str(target.pid)], capture_output=True, text=True).stdout.strip()
        check(not answer.startswith('stopped'), f"the helper didn't take the request: {answer!r}")
        check(state and not state.startswith('T'), f'the process kept running: state {state!r}')
        # Once launchd has the run and the helper has exited again (its last exit code is then this run's).
        end = time.monotonic() + 15
        after = helper() or {}
        while (int(after.get('runs', 0)) <= int(before.get('runs', 0)) or after.get('state') == 'running') and time.monotonic() < end:
            time.sleep(0.3)
            after = helper() or {}
        check(int(after.get('runs', 0)) > int(before.get('runs', 0)),
              f"the helper was reached (launchd started it): runs {before.get('runs')} → {after.get('runs')}")
        check(after.get('last exit code') == '0', f"the helper didn't crash: last exit code {after.get('last exit code')}")
    finally:
        # (Should the helper ever take the request, the process goes on and ends here.)
        target.send_signal(signal.SIGCONT)
        target.kill()

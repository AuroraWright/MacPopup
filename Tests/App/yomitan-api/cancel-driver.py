# cancel-driver.py, for cancel.test.js: the app's Yomitan API host (a copy in $RUN/host, as it writes .crowbar next to
# itself) on port 59883 with a fake Yomitan whose tokenize takes 3 s, until the page's test is done; then checks which
# lines' tokenize reached Yomitan.
import json, os, shutil, struct, subprocess, sys, threading, time
sys.dont_write_bytecode = True  # (no __pycache__ in the repo)
sys.path.insert(0, os.environ['HARNESS'] + '/tools')
from driver import RUN, check, equal, log, running, until

os.makedirs(f'{RUN}/host', exist_ok=True)
# The tested app's host (launch.sh runs the driver beside the instance whose pid is PID).
app = subprocess.run(['ps', '-o', 'comm=', '-p', os.environ['PID']], capture_output=True, text=True).stdout.strip()
shutil.copy2(f"{app.split('/Contents/MacOS/')[0]}/Contents/Helpers/yomitan_api", f'{RUN}/host/yomitan_api')
host = subprocess.Popen([f'{RUN}/host/yomitan_api'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env={'YOMITAN_API_PORT': '59883'})
lock = threading.Lock()
received = []


def write(message):
    data = json.dumps(message, ensure_ascii=False).encode()
    with lock:
        host.stdin.write(struct.pack('=I', len(data)) + data)
        host.stdin.flush()


def answer(message):
    action = message['action']
    if action == 'tokenize':
        text = json.loads(message['body'])['text']
        time.sleep(3)
        write({**message, 'data': [{'index': 0, 'content': [[{'text': text, 'reading': ''}]]}], 'responseStatusCode': 200})
    elif action == 'yomitanVersion':
        write({**message, 'data': {'version': 'fake'}, 'responseStatusCode': 200})
    else:
        # As a Yomitan without this path (the API's own answer to an unknown action).
        write({**message, 'data': None, 'responseStatusCode': 400})


def fake_yomitan():
    while True:
        header = host.stdout.read(4)
        if len(header) < 4:
            return
        message = json.loads(host.stdout.read(struct.unpack('=I', header)[0]))
        log(f"{time.time():.2f} yomitan got {message['action']} {message['body'][:80]}")
        if message['action'] == 'tokenize':
            received.append(json.loads(message['body'])['text'])
        threading.Thread(target=answer, args=(message,), daemon=True).start()


threading.Thread(target=fake_yomitan, daemon=True).start()


def page_done():
    try:
        return 'TEST done' in open(f'{RUN}/app.log', errors='replace').read() or not running()
    except OSError:
        return False


until(page_done, timeout=80, interval=0.5)
lines = [f'テスト{n}' for n in '一二三四五六七八']
check(len(received) > 0, f'tokenize requests reached Yomitan: {received}')
equal(received, lines[:4] + lines[6:], "the lines whose tokenize reached Yomitan (5 and 6 were dropped while they waited their turn)")
host.stdin.close()
try:
    host.wait(timeout=5)
except subprocess.TimeoutExpired:
    host.kill()

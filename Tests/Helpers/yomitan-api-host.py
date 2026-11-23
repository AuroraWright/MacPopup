#!/usr/bin/env python3 -I
"""The Yomitan API's native messaging host (Sources/YomitanAPI) on its own, with a fake browser and Yomitan on its stdin
and stdout: HTTP handling (methods, paths, query, status codes, CORS, large bodies), Yomitan's data passed on byte for
byte, up to 4 requests at once in arrival order with each answer routed to its own client, a request whose client went
away while it waited its turn never reaching Yomitan, a 504 after 30 s without an answer, the .crowbar file, and quitting
when stdin closes. Prints PASS or FAIL for each check and exits with 1 on a failure. Takes about 45 s.

Usage: python3 -I Tests/Helpers/yomitan-api-host.py [host binary] [port]
The binary defaults to build/test/MacPopup.app/Contents/Helpers/yomitan_api, which must be a development build
(scripts/test.sh app makes one): only those read YOMITAN_API_PORT. It's copied into a temporary folder and run from
there, as it writes .crowbar and error.log next to itself. The port defaults to 59897. It doesn't start the app.

The fake Yomitan answers "slow" after body.seconds with {"tag": body.tag}, never answers "never", answers "bad" without
a status, "missing" with a 404, and the rest at once with data that echoes the message.
"""
import http.client
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = sys.argv[1] if len(sys.argv) > 1 else f'{REPO}/build/test/MacPopup.app/Contents/Helpers/yomitan_api'
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 59897
if not os.access(SOURCE, os.X_OK):
    sys.exit(f'NOT RUN: no host at {SOURCE}')
try:
    socket.create_connection(('127.0.0.1', PORT), timeout=0.5).close()
    sys.exit(f'NOT RUN: something already listens on port {PORT}')
except OSError:
    pass

folder = tempfile.TemporaryDirectory(prefix='yomitan-api-host-')
HOST = os.path.join(folder.name, 'yomitan_api')
shutil.copy2(SOURCE, HOST)
CROWBAR = os.path.join(folder.name, '.crowbar')
host = subprocess.Popen([HOST], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env={'YOMITAN_API_PORT': str(PORT)})

lock = threading.Lock()
received = []  # (time, action, tag)
messages = []  # every message Yomitan got
in_flight = 0
max_in_flight = 0
start = time.monotonic()
# The data the fake sent for an echoed action, as it wrote it.
echo_data = {}


def now():
    return time.monotonic() - start


def write(reply):
    data = json.dumps(reply, ensure_ascii=False).encode()
    with lock:
        host.stdin.write(struct.pack('=I', len(data)) + data)
        host.stdin.flush()


def parsed(body):
    try:
        value = json.loads(body)
        return value if isinstance(value, dict) else {}
    except ValueError:
        return {}


def answer(message):
    global in_flight
    body = parsed(message['body'])
    action = message['action']
    if action == 'slow':
        time.sleep(body.get('seconds', 0))
        reply = {**message, 'data': {'tag': body.get('tag')}, 'responseStatusCode': 200}
    elif action == 'bad':
        reply = {'params': message['params'], 'oops': 1}
    else:
        data = {'echo': message, 'text': '日本語 \\u3042 "q" \\\\ /', 'n': [1, 2.5, 1e100, -0.0, True, None], 'order': {'z': 1, 'a': 2}}
        echo_data[action] = json.dumps(data, ensure_ascii=False).encode()
        reply = {**message, 'data': data, 'responseStatusCode': 404 if action == 'missing' else 200}
    with lock:
        in_flight -= 1
    write(reply)


def fake_yomitan():
    global in_flight, max_in_flight
    while True:
        header = host.stdout.read(4)
        if len(header) < 4:
            return
        message = json.loads(host.stdout.read(struct.unpack('=I', header)[0]))
        tag = parsed(message['body']).get('tag')
        with lock:
            messages.append(message)
            received.append((now(), message['action'], tag))
            in_flight += 1
            max_in_flight = max(max_in_flight, in_flight)
        if message['action'] != 'never':
            threading.Thread(target=answer, args=(message,), daemon=True).start()


def request(method, path, body=b'', timeout=60):
    """(status, headers, body bytes, seconds)."""
    began = now()
    connection = http.client.HTTPConnection('127.0.0.1', PORT, timeout=timeout)
    connection.request(method, path, body=body)
    response = connection.getresponse()
    data = response.read()
    connection.close()
    return response.status, {k.lower(): v for k, v in response.getheaders()}, data, now() - began


def post(path, body=None):
    status, _, data, seconds = request('POST', f'/{path}', json.dumps(body or {}).encode())
    try:
        data = json.loads(data)
    except ValueError:
        data = data.decode(errors='replace')
    return status, data, seconds


def run_all(calls):
    """Runs (path, body, stagger) posts on threads, each started stagger seconds after the previous one."""
    results = [None] * len(calls)

    def run(index, path, body):
        results[index] = post(path, body)

    threads = []
    for index, (path, body, stagger) in enumerate(calls):
        time.sleep(stagger)
        thread = threading.Thread(target=run, args=(index, path, body))
        thread.start()
        threads.append(thread)
    for thread in threads:
        thread.join()
    return results


failures = []


def check(name, condition, detail=''):
    print('PASS' if condition else 'FAIL', name, '' if condition else detail, flush=True)
    if not condition:
        failures.append(name)


threading.Thread(target=fake_yomitan, daemon=True).start()
for _ in range(100):
    try:
        socket.create_connection(('127.0.0.1', PORT), timeout=1).close()
        break
    except OSError:
        time.sleep(0.05)

# HTTP handling, by the host itself.
status, headers, data, _ = request('POST', '/serverVersion')
check('serverVersion', (status, json.loads(data)) == (200, {'version': 1}), (status, data))
check('CORS headers', headers.get('access-control-allow-origin') == '*' and headers.get('access-control-allow-methods') == '*'
      and headers.get('access-control-allow-headers') == '*', headers)
status, _, data, _ = request('POST', '/')
check('empty path answers the version', (status, json.loads(data)) == (200, {'version': 1}), (status, data))
status, _, _, _ = request('POST', '/favicon.ico')
check('favicon.ico refused', status == 400, status)
status, headers, data, _ = request('GET', '/termEntries')
check('GET refused with Allow: POST', status == 405 and headers.get('allow') == 'POST', (status, headers, data))
status, _, _, _ = request('OPTIONS', '/termEntries')
check('OPTIONS refused', status == 405, status)
status, _, data, _ = request('BREW', '/termEntries')
check('unknown method not implemented', status == 501 and b'BREW' in data, (status, data))
check('none of these reached Yomitan', messages == [], [m['action'] for m in messages])

# Requests passed to Yomitan.
status, headers, data, _ = request('POST', '/termEntries', json.dumps({'term': '読む'}, ensure_ascii=False).encode())
message = messages[-1] if messages else {}
check('a request reaches Yomitan as action, params and body',
      message.get('action') == 'termEntries' and message.get('body') == '{"term": "読む"}'
      and list(message.get('params', {})) == ['__macpopupRequestId'], message)
check("Yomitan's data passed on byte for byte", status == 200 and data == echo_data.get('termEntries'), (status, data[:200]))
check('JSON content type', headers.get('content-type') == 'application/json', headers)
request('POST', '/termEntries?x=1&x=2&y=&z&a+b=c%20d%E3%81%82&bad=%zz', '{"term":"日本"}'.encode())
params = {k: v for k, v in messages[-1]['params'].items() if k != '__macpopupRequestId'}
check('query parsed as parse_qs does', params == {'x': ['1', '2'], 'a b': ['c dあ'], 'bad': ['%zz']}, params)
request('POST', '/a/b?q=1#frag')
message = messages[-1]
check('path and query without the fragment', message['action'] == 'a/b' and message['params'].get('q') == ['1'], message)
status, _, data, _ = request('POST', '/missing', b'{}')
check("Yomitan's status passed on", status == 404 and data == echo_data.get('missing'), status)
status, _, _, _ = request('POST', '/bad')
check('an answer without a status is a 500', status == 500, status)
status, _, _, _ = request('POST', '/after-bad')
check('answers again after a bad one', status == 200, status)
big = json.dumps({'t': 'あ' * 3_000_000}, ensure_ascii=False).encode()
status, _, data, _ = request('POST', '/big', big)
check('a 9 MB body passed on', status == 200 and messages[-1]['body'].encode() == big and data == echo_data.get('big'),
      (status, len(messages[-1]['body'].encode()), len(big)))

# 1. A quick request isn't held up by a slow one.
results = run_all([('slow', {'seconds': 3, 'tag': 'long'}, 0), ('yomitanVersion', {}, 0.2)])
check('slow answered', results[0][:2] == (200, {'tag': 'long'}), results[0])
check('quick request answered during a slow one', results[1][0] == 200 and results[1][2] < 0.5, results[1][0::2])

# 2. Up to 4 at once, in arrival order, each client with its own answer (answered in reverse order).
received.clear()
max_in_flight = 0
durations = [2.0, 1.5, 1.0, 0.5, 0.5, 0.5]
results = run_all([('slow', {'seconds': d, 'tag': i}, 0.05) for i, d in enumerate(durations)])
check('answers routed to their own clients', [r[1] for r in results] == [{'tag': i} for i in range(6)], [r[:2] for r in results])
check('at most 4 at once', max_in_flight == 4, max_in_flight)
check('handed to Yomitan in arrival order', [tag for _, _, tag in received] == list(range(6)), received)
check('the 5th waits for a free place', len(received) == 6 and received[4][0] - received[0][0] > 0.4,
      [round(t, 2) for t, _, _ in received])

# 3. A request whose client went away while waiting its turn never reaches Yomitan.
received.clear()
threads = [threading.Thread(target=post, args=('slow', {'seconds': 3, 'tag': f'busy{i}'})) for i in range(4)]
for thread in threads:
    thread.start()
time.sleep(0.3)
body = json.dumps({'seconds': 0, 'tag': 'abandoned'}).encode()
client = socket.create_connection(('127.0.0.1', PORT))
client.sendall(b'POST /slow HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n' % len(body) + body)
time.sleep(0.5)
client.close()
late = post('slow', {'seconds': 0, 'tag': 'after'})
for thread in threads:
    thread.join()
time.sleep(0.5)
tags = [tag for _, _, tag in received]
check('an abandoned request is dropped', 'abandoned' not in tags, tags)
check('the next one is answered', late[:2] == (200, {'tag': 'after'}), late)

# 4. 504 when Yomitan doesn't answer in 30 s, and the others still work meanwhile.
results = run_all([('never', {}, 0), ('yomitanVersion', {}, 1)])
check('504 after 30 s', results[0][0] == 504 and 29.5 < results[0][2] < 31.5, results[0])
check('others answered meanwhile', results[1][0] == 200 and results[1][2] < 0.5, results[1][0::2])

# 5. The .crowbar file has the host's pid while it runs, and goes when it quits on stdin closing.
try:
    crowbar = open(CROWBAR).read().strip()
except OSError as error:
    crowbar = str(error)
check('.crowbar has the pid', crowbar == str(host.pid), (crowbar, host.pid))
host.stdin.close()
try:
    host.wait(timeout=5)
    check('quits when stdin closes', True)
except subprocess.TimeoutExpired:
    host.kill()
    check('quits when stdin closes', False)
check('.crowbar removed', not os.path.exists(CROWBAR))
try:
    errors = open(os.path.join(folder.name, 'error.log')).read().splitlines()
except OSError:
    errors = []
check('error.log has only the answer without a status', len(errors) == 1 and 'Unexpected reply' in errors[0] and 'oops' in errors[0], errors)
folder.cleanup()

print(f'FAIL: {len(failures)} ({", ".join(failures)})' if failures else 'PASS')
sys.exit(1 if failures else 0)

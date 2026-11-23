# serve.py: the IINA tests' web server (iina.py beside starts it): <dir> on 127.0.0.1:59885 with Range requests (mpv
# seeks with them), and an HTTP proxy on 59886, each request logged to <log>. From scratch-tools/iina/streams serve.py
# and proxy.py.
# - /live/<folder>.m3u8 plays <folder>/index.m3u8 as a live stream: the segments that have aired since its first
#   request (two to begin with), without an end, so players go back only as far as their cache.
# - /gate-proxy/<path> serves <path> only through the proxy (Via: test-proxy), /gate-cookie/<path> only with the cookie
#   macpopup=yes from 3 s after its first request (mpv doesn't send its cookies file's cookies on a port other than 80:
#   it reads the file before then, and MacPopup's requests come later); else 403.
import http.server, io, os, re, threading, time, urllib.error, urllib.request

PORT, PROXY_PORT = 59885, 59886
LIVE_START = {}


def serve(root, log_path):
    root = os.path.abspath(root)
    log_file = open(log_path, 'a', buffering=1)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k):
            super().__init__(*a, directory=root, **k)

        def log_message(self, format, *args):
            log_file.write(f'{time.time() * 1000:.0f} serve {format % args}\n')

        def send_head(self):
            gate = re.match(r'/gate-(proxy|cookie)/', self.path)
            if gate:
                self.log_message('%s via=%s cookie=%s', self.path, self.headers.get('Via'), self.headers.get('Cookie'))
                first = LIVE_START.setdefault('gate-cookie', time.monotonic()) if gate.group(1) == 'cookie' else None
                if (self.headers.get('Via') != 'test-proxy' if gate.group(1) == 'proxy'
                        else 'macpopup=yes' not in (self.headers.get('Cookie') or '') and time.monotonic() - first > 3):
                    self.send_error(403)
                    return None
                self.path = self.path[gate.end() - 1:]
            live = re.fullmatch(r'/live/([\w-]+)\.m3u8', self.path)
            if live:
                return self.live_playlist(live.group(1))
            path = self.translate_path(self.path)
            rng = self.headers.get('Range')
            if not rng or not os.path.isfile(path):
                return super().send_head()
            size = os.path.getsize(path)
            m = re.match(r'bytes=(\d*)-(\d*)', rng)
            start = int(m.group(1)) if m.group(1) else size - int(m.group(2))
            end = int(m.group(2)) if m.group(1) and m.group(2) else size - 1
            f = open(path, 'rb')
            f.seek(start)
            self.send_response(206)
            self.send_header('Content-Type', self.guess_type(path))
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.send_header('Content-Length', str(end - start + 1))
            self.send_header('Accept-Ranges', 'bytes')
            self.end_headers()
            self.remaining = end - start + 1
            return f

        def live_playlist(self, folder):
            lines = open(os.path.join(root, folder, 'index.m3u8')).read().splitlines()
            header = [l for l in lines if l.startswith('#EXT') and not l.startswith(('#EXTINF', '#EXT-X-ENDLIST', '#EXT-X-PLAYLIST-TYPE'))]
            segments = [(lines[i], lines[i + 1]) for i, l in enumerate(lines) if l.startswith('#EXTINF')]
            started = LIVE_START.setdefault(folder, time.monotonic())
            aired, total = 0, 0.0
            for info, _ in segments:
                if aired >= 2 and total > time.monotonic() - started:
                    break
                total += float(info.split(':')[1].rstrip(','))
                aired += 1
            body = '\n'.join(header + [f'{info}\n/{folder}/{name}' for info, name in segments[:aired]]) + '\n'
            self.send_response(200)
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            return io.BytesIO(body.encode())

        def copyfile(self, source, outputfile):
            n = getattr(self, 'remaining', None)
            if n is None:
                return super().copyfile(source, outputfile)
            while n > 0:
                chunk = source.read(min(65536, n))
                if not chunk:
                    break
                outputfile.write(chunk)
                n -= len(chunk)

    class Proxy(http.server.BaseHTTPRequestHandler):
        """An HTTP proxy for http:// URLs (absolute-URI requests), adding "Via: test-proxy"."""

        def log_message(self, format, *args):
            log_file.write(f'{time.time() * 1000:.0f} proxy {format % args}\n')

        def do_GET(self):
            self.log_message('%s cookie=%s range=%s', self.path, self.headers.get('Cookie'), self.headers.get('Range'))
            if not self.path.startswith('http://127.0.0.1:'):
                self.send_error(400)
                return
            request = urllib.request.Request(self.path, headers={k: v for k, v in self.headers.items()
                                                                 if k.lower() not in ('host', 'proxy-connection', 'connection')})
            request.add_header('Via', 'test-proxy')
            try:
                response = urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=20)
            except urllib.error.HTTPError as error:
                response = error
            body = response.read()
            self.send_response(response.status)
            for k, v in response.headers.items():
                if k.lower() not in ('transfer-encoding', 'connection', 'content-length'):
                    self.send_header(k, v)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    for port, handler in ((PORT, Handler), (PROXY_PORT, Proxy)):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', port), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()

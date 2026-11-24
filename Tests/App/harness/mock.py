# mock.py <log>: the services a test instance talks to, until it's stopped: AnkiConnect on 59877, the Yomitan API on
# 59878 (150 entries for any lookup, matching MOCK_MATCH_LENGTH characters, 2 by default) and an audio server on 59879
# (logs each request's time, answers with 0.1 s of silence). Each request goes to <log>, which GET /__log on 59879
# answers with. A test's "// mock:" line sets the MOCK_* switches below (images, notes, an Anki editor, a Yomitan
# profile, tokenizing, an added note's id, the run folder's files, WebSocket lines, WebSocket servers that stay connected,
# a screenshot field, a note that has sentence audio already).
import base64, io, json, os, struct, sys, threading, time, wave, zlib
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
log_path = sys.argv[1]
def entry(i):
    term = f'晴れる{i}' if i else '晴れる'
    return {
        'type': 'term', 'isPrimary': True, 'textProcessorRuleChainCandidates': [], 'inflectionRuleChainCandidates': [{'source': 'algorithm', 'inflectionRules': []}],
        'score': -i, 'frequencyOrder': 0, 'dictionaryIndex': 0, 'dictionaryAlias': 'Mock', 'sourceTermExactMatchCount': 1, 'matchPrimaryReading': False, 'maxOriginalTextLength': 2,
        'headwords': [{'index': 0, 'term': term, 'reading': 'はれる', 'sources': [{'originalText': '晴れ', 'transformedText': '晴れ', 'deinflectedText': '晴れる', 'matchType': 'exact', 'matchSource': 'term', 'isPrimary': True}], 'tags': [], 'wordClasses': []}],
        'definitions': [{'index': d, 'headwordIndices': [0], 'dictionary': 'Mock', 'dictionaryIndex': 0, 'dictionaryAlias': 'Mock', 'id': i * 10 + d, 'score': 0, 'frequencyOrder': 0, 'sequences': [i], 'isPrimary': True, 'tags': [],
                         'entries': [f'meaning {i}.{d}: ' + 'to clear up, to become sunny; ' * 12, 'another gloss ' * 20]} for d in range(6)],
        'pronunciations': [], 'frequencies': [],
    }
entries = [entry(i) for i in range(150)]
def png(width, height, rgba):
    rows = b''.join(b'\0' + bytes(rgba) * width for _ in range(height))
    chunk = lambda kind, data: struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
# MOCK_IMAGES=1: the first entry's first definition has a red image and a black one shown monochrome, which
# ankiFields' dictionaryMedia has.
media = []
# MOCK_NOTES=1: a card format (first field "x") whose notes 111 and 222 already exist for every entry.
card_formats = []
def anki_result(action, params):
    return {'version': 6}.get(action)
if os.environ.get('MOCK_NOTES') == '1':
    card_formats = [{'type': 'term', 'model': 'Mock', 'name': 'Mock', 'deck': 'Mock', 'fields': {'Word': {'value': 'x'}}}]
    def anki_result(action, params):
        if action == 'multi':
            return [[111, 222] if a.get('action') == 'findNotes' else None for a in params.get('actions', [])]
        if action == 'notesInfo':
            return [{'noteId': n, 'tags': [], 'cards': [n * 10]} for n in params.get('notes', [])]
        if action == 'cardsInfo':
            return [{'cardId': c, 'note': c // 10, 'queue': 2, 'flags': 0} for c in params.get('cards', [])]
        return {'version': 6}.get(action)
# MOCK_EDITOR=browser|closed: AnkiConnect as it is with a card browser open on the note (browser) or no browser open
# (closed): note 333, added today, with a sentence and an empty SentenceAudio field; guiBrowse changes the browser's
# selection (nid:1 none, nid:<ids> those), and updateNoteFields refuses a note selected there, as AnkiConnect refuses
# notes open in an editor. Every lookup's note exists as 333 (for duplicateBehavior overwrite). MOCK_OVER=1: note 333
# already has sentence audio ([sound:old.m4a]) and, with MOCK_SHOT, a picture (Anki Audio's overwrite rules).
if os.environ.get('MOCK_EDITOR') in ('browser', 'closed'):
    card_formats = [{'type': 'term', 'model': 'Mock', 'name': 'Mock', 'deck': 'Mock',
                     'fields': {'Word': {'value': '{expression}'}, 'Sentence': {'value': '{sentence}'}, 'SentenceAudio': {'value': ''}}}]
    browser = {'open': os.environ['MOCK_EDITOR'] == 'browser', 'selected': [333] if os.environ['MOCK_EDITOR'] == 'browser' else []}
    def anki_result(action, params):
        if action == 'multi':
            return [[333] if a.get('action') == 'findNotes' else None for a in params.get('actions', [])]
        if action == 'cardsInfo':
            return [{'cardId': c, 'note': c // 10, 'queue': 2, 'flags': 0} for c in params.get('cards', [])]
        if action == 'findNotes':
            return [333]
        if action == 'notesInfo':
            fields = {'Word': {'value': '晴れる', 'order': 0}, 'Sentence': {'value': '明日も<b>晴れる</b>といいね', 'order': 1}, 'SentenceAudio': {'value': '', 'order': 2}}
            # MOCK_OVER=1: note 333 already has sentence audio (and, with MOCK_SHOT, a picture).
            if os.environ.get('MOCK_OVER') == '1':
                fields['SentenceAudio']['value'] = '[sound:old.m4a]'
                if os.environ.get('MOCK_SHOT') == '1':
                    fields['Picture'] = {'value': '<img src="old.jpg">', 'order': 3}
            return [{'noteId': 333, 'modelName': 'Mock', 'tags': [], 'cards': [3330], 'fields': fields}]
        if action == 'storeMediaFile':
            return params.get('filename')
        if action == 'guiSelectedNotes':
            return browser['selected']
        if action == 'guiBrowse':
            browser['open'] = True
            query = params.get('query') or ''
            browser['selected'] = [int(n) for n in query[4:].split(',') if n.isdigit() and n != '1'] if query.startswith('nid:') else []
            return [n * 10 for n in browser['selected']]
        if action == 'updateNoteFields':
            if params['note']['id'] in browser['selected']:
                raise ValueError('Close the affected editor before this API write, even if its content is saved.')
            return None
        return {'version': 6}.get(action)
# MOCK_SHOT=1 (with MOCK_EDITOR): the card format also has a Picture field with {screenshot} (Anki Screenshot); the
# screenshot comes in a storeMediaFile request, logged with its data.
if os.environ.get('MOCK_SHOT') == '1' and card_formats:
    card_formats[0]['fields']['Picture'] = {'value': '{screenshot}'}
if os.environ.get('MOCK_IMAGES') == '1':
    images = [('mock/red.png', (255, 0, 0, 255), 'auto'), ('mock/mono.png', (0, 0, 0, 255), 'monochrome')]
    entries[0]['definitions'][0]['entries'].insert(0, {'type': 'structured-content', 'content': [
        {'tag': 'img', 'path': path, 'width': 32, 'height': 32, 'appearance': appearance, 'collapsible': False} for path, _, appearance in images]})
    media = [{'dictionary': 'Mock', 'path': path, 'mediaType': 'image/png', 'content': base64.b64encode(png(32, 32, color)).decode()} for path, color, _ in images]
# MOCK_ADD_NOTE=<id>: addNote answers with note <id> (with MOCK_EDITOR, as a card added from a popup).
if os.environ.get('MOCK_ADD_NOTE'):
    added_note, other_result = int(os.environ['MOCK_ADD_NOTE']), anki_result
    def anki_result(action, params):
        return added_note if action == 'addNote' else other_result(action, params)
# MOCK_PROFILE=1: the API paths of a Yomitan with yomitan-api-endpoints.patch (displayOptions, dictionaryInfo,
# dictionaryMedia); without it, they're answered 400 as by an older Yomitan (as is any path Yomitan doesn't have).
profile = os.environ.get('MOCK_PROFILE') == '1'
# ankiFields' copies of the images: with MOCK_PROFILE, green ones, so that a popup's red image shows it came from
# dictionaryMedia.
anki_media = [{**m, 'content': base64.b64encode(png(32, 32, (0, 160, 0, 255))).decode()} for m in media] if profile else media
# MOCK_PROFILE_FAIL=n: the first n displayOptions requests are answered 503, as a request that fails once.
profile_fails = [int(os.environ.get('MOCK_PROFILE_FAIL') or 0)]
display_options = {'general': {
    'language': 'ja', 'resultOutputMode': 'split', 'glossaryLayoutMode': 'compact', 'compactTags': True, 'averageFrequency': False,
    'frequencyDisplayMode': 'list', 'termDisplayMode': 'term-and-reading', 'showPitchAccentDownstepNotation': False,
    'showPitchAccentPositionNotation': False, 'showPitchAccentGraph': True, 'popupDisplayMode': 'default', 'popupTheme': 'dark',
    'popupOuterTheme': 'dark', 'fontFamily': 'Georgia', 'fontSize': 21, 'lineHeight': '1.8', 'popupScalingFactor': 1.25,
    'customPopupCss': '.entry { outline: 3px solid rgb(0, 0, 255); }', 'customPopupOuterCss': '.yomitan-popup { outline: 3px solid rgb(255, 0, 255) !important; }',
    'popupCurrentIndicatorMode': 'asterisk', 'popupActionBarVisibility': 'always', 'popupActionBarLocation': 'bottom'},
    'scanning': {'enableSearchTags': True}}
dictionary_info = [
    {'title': 'Mock', 'revision': 'mock.1', 'sequenced': True, 'version': 3, 'importDate': 0, 'prefixWildcardsSupported': False,
     'author': 'Mock Author', 'description': 'A mock dictionary', 'url': 'https://example.com',
     'counts': {'terms': {'total': 150}, 'termMeta': {'total': 0}, 'kanji': {'total': 0}, 'kanjiMeta': {'total': 0}, 'tagMeta': {'total': 0}, 'media': {'total': 2}},
     'styles': '.gloss-content { color: rgb(0, 160, 0); }', 'options': {'alias': 'Mock', 'enabled': True, 'definitionsCollapsible': 'force-collapsed'}},
    {'title': 'Unlisted', 'revision': '1', 'sequenced': False, 'version': 3, 'importDate': 0, 'prefixWildcardsSupported': False,
     'counts': {}, 'styles': '.gloss-content { color: rgb(255, 0, 0); }', 'options': None},
]
buf = io.BytesIO()
with wave.open(buf, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050); w.writeframes(b'\0\0' * 2205)
silence = buf.getvalue()
# (Requests are handled on threads of their own: a line is written whole before the log is read.)
log_lock = threading.Lock()
def log(line):
    with log_lock, open(log_path, 'a') as f: f.write(line + '\n')
class H(BaseHTTPRequestHandler):
    def reply(self, data, kind='application/json'):
        self.send_response(200); self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        # The log so far, for the test to check (test-lib.js mockLog).
        if self.path == '/__log':
            with log_lock, open(log_path, 'a+') as f:
                f.seek(0)
                data = f.read().encode()
            return self.reply(data, 'text/plain')
        # MOCK_RUN_FILES=1: GET /__run/<name> answers with that file of the run folder (the log's), e.g. debug.jsonl or
        # app.log, empty when there's none yet (test-lib.js runFile).
        if os.environ.get('MOCK_RUN_FILES') == '1' and self.path.startswith('/__run/'):
            name = os.path.basename(self.path[len('/__run/'):])
            try:
                with open(os.path.join(os.path.dirname(os.path.abspath(log_path)), name), 'rb') as f: data = f.read()
            except OSError:
                data = b''
            return self.reply(data, 'text/plain')
        log(f'audio {time.time() * 1000:.0f} {self.path}')
        self.reply(silence, 'audio/wav')
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)) or b'{}')
        if self.server.server_address[1] == 59878:
            path = self.path.strip('/')
            log(f'yomitan {time.time() * 1000:.0f} {path}')
            out = {'yomitanVersion': {'version': 'mock'}, 'ankiCardFormats': card_formats, 'termEntries': {'dictionaryEntries': entries, 'originalTextLength': int(os.environ.get('MOCK_MATCH_LENGTH', 2))},
                   'kanjiEntries': [], 'tokenize': [], 'ankiFields': {'fields': [], 'dictionaryMedia': [{**m, 'ankiFilename': m['path'].replace('/', '_')} for m in anki_media], 'audioMedia': []}}
            if profile:
                targets = {(t.get('dictionary'), t.get('path')) for t in body.get('targets', [])}
                out.update({'displayOptions': display_options, 'dictionaryInfo': dictionary_info,
                            'dictionaryMedia': [m for m in media if (m['dictionary'], m['path']) in targets]})
            if path == 'displayOptions' and profile_fails[0] > 0:
                profile_fails[0] -= 1
                log(f'yomitan-503 {path}')
                self.send_response(503); self.send_header('Content-Length', '0'); self.end_headers()
                return
            # MOCK_TOKENIZE=1: one token per character, with the reading よみ on each kanji (furigana in the text box).
            if path == 'tokenize' and os.environ.get('MOCK_TOKENIZE'):
                out['tokenize'] = [{'index': 0, 'content': [[{'text': c, 'reading': 'よみ' if '\u4e00' <= c <= '\u9fff' else ''}] for c in body.get('text', '')]}]
            if path not in out:
                log(f'yomitan-400 {path}')
                self.send_response(400); self.send_header('Content-Length', '0'); self.end_headers()
                return
            if path == 'dictionaryMedia':
                log(f'yomitan-media {sorted(targets)}')
            out = out[path]
        else:
            action = body.get('action')
            log(f'anki {time.time() * 1000:.0f} {action} {json.dumps(body.get("params", {}))}')
            try:
                out = {'result': anki_result(action, body.get('params', {})), 'error': None}
            except ValueError as e:
                out = {'result': None, 'error': str(e)}
            log(f'anki-reply {action} {json.dumps(out)[:200]}')
        self.reply(json.dumps(out).encode())
    def log_message(self, *a): pass
for port in (59877, 59878, 59879):
    threading.Thread(target=ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever, daemon=True).start()
# MOCK_WEBSOCKET=1: a WebSocket server on 59880 (settings: "websocketUrls":["ws://127.0.0.1:59880"]) sending each line
# POSTed to http://127.0.0.1:59881/ to every connection: the body, or the string in it when it's a JSON string, as
# native('http', {url, body: JSON.stringify(line)}) sends it. Each line sent is logged ("websocket <ms> <line>").
if os.environ.get('MOCK_WEBSOCKET') == '1':
    import hashlib, socket
    ws_clients = []
    def ws_frame(text):
        data = text.encode()
        return b'\x81' + (bytes([len(data)]) if len(data) < 126 else b'\x7e' + struct.pack('>H', len(data))) + data
    def ws_read(conn):
        try:
            while conn.recv(4096): pass
        except OSError: pass
    def ws_serve():
        server = socket.socket(); server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(('127.0.0.1', 59880)); server.listen()
        while True:
            conn, _ = server.accept()
            request = conn.recv(4096).decode(errors='replace')
            keys = [l.split(':', 1)[1].strip() for l in request.split('\r\n') if l.lower().startswith('sec-websocket-key:')]
            if not keys:
                conn.close(); continue
            accept = base64.b64encode(hashlib.sha1((keys[0] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            conn.sendall(f'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n'.encode())
            ws_clients.append(conn)
            log(f'websocket-connected {time.time() * 1000:.0f}')
            threading.Thread(target=ws_read, args=(conn,), daemon=True).start()
    class WS(BaseHTTPRequestHandler):
        def do_POST(self):
            text = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode()
            try:
                value = json.loads(text)
                text = value if isinstance(value, str) else value.get('line', text)
            except Exception: pass
            log(f'websocket {time.time() * 1000:.0f} {text}')
            for c in list(ws_clients):
                try: c.sendall(ws_frame(text))
                except OSError: ws_clients.remove(c)
            self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'{}')
        def log_message(self, *a): pass
    threading.Thread(target=ws_serve, daemon=True).start()
    threading.Thread(target=ThreadingHTTPServer(('127.0.0.1', 59881), WS).serve_forever, daemon=True).start()
# MOCK_WEBSOCKET_PORTS=<port>,…: WebSocket servers on those ports that accept connections and keep them open, sending
# nothing; each connection is logged ("websocket-port <port> <ms>"), and its end ("websocket-port-closed <port> <ms>").
def ws_hold(port):
    import hashlib, socket
    server = socket.socket(); server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('127.0.0.1', port)); server.listen()
    def read(conn):
        try:
            while conn.recv(4096): pass
        except OSError: pass
        log(f'websocket-port-closed {port} {time.time() * 1000:.0f}')
    while True:
        conn, _ = server.accept()
        request = conn.recv(4096).decode(errors='replace')
        keys = [l.split(':', 1)[1].strip() for l in request.split('\r\n') if l.lower().startswith('sec-websocket-key:')]
        if not keys:
            conn.close(); continue
        accept = base64.b64encode(hashlib.sha1((keys[0] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        conn.sendall(f'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n'.encode())
        log(f'websocket-port {port} {time.time() * 1000:.0f}')
        threading.Thread(target=read, args=(conn,), daemon=True).start()
for port in filter(None, os.environ.get('MOCK_WEBSOCKET_PORTS', '').split(',')):
    threading.Thread(target=ws_hold, args=(int(port),), daemon=True).start()
threading.Event().wait()

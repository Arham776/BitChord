import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        self.server.count += 1
        if self.path.startswith('/same'):
            self.send_response(302); self.send_header('Location','/target'); self.end_headers(); return
        if self.path.startswith('/cross'):
            self.send_response(302); self.send_header('Location',f'http://127.0.0.1:{other.server_port}/target'); self.end_headers(); return
        if self.path == '/counts': body = json.dumps({'other':other.count}).encode()
        else: body = json.dumps({'authenticated':bool(self.headers.get('Authorization')), 'cookie':bool(self.headers.get('Cookie')), 'cookieValue':self.headers.get('Cookie')}).encode()
        self.send_response(200)
        if self.path == '/set-jar': self.send_header('Set-Cookie','fixture=jar-stale; Path=/')
        if self.path == '/clear-jar': self.send_header('Set-Cookie','fixture=; Max-Age=0; Path=/')
        self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
first=ThreadingHTTPServer(('127.0.0.1',0),Handler); first.count=0
other=ThreadingHTTPServer(('127.0.0.1',0),Handler); other.count=0
threading.Thread(target=other.serve_forever,daemon=True).start()
Path(sys.argv[1]).write_text(json.dumps({'first':first.server_port,'other':other.server_port}))
first.serve_forever()

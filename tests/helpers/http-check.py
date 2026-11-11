"""A stand-in for a project's production, for team-uptime's checks.

Usage: python3 -I http-check.py <dir> <port file>
Listens on a free port of 127.0.0.1, writes the port to <port file>, and serves until killed, each
request on a thread of its own, so a hung answer blocks no other.
GET /<name> answers from <dir>/<name>.json, {"status": <n>, "body": "<text>", "hang": <bool>}
(hang sleeps 60 s before answering, past the tests' 1 s timeout), read at each request, so a test
rewrites it between runs; a path with no file answers 404 with an empty body.
Every request is appended to <dir>/requests.jsonl as one JSON line, {path, method, headers}, the
headers an object of each name as sent to its value.
"""

import http.server
import json
import os
import socketserver
import sys
import threading
import time

root, port_path = sys.argv[1], sys.argv[2]
log_lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def answer(self):
        with log_lock, open(os.path.join(root, "requests.jsonl"), "a") as log:
            log.write(json.dumps({"path": self.path, "method": self.command, "headers": dict(self.headers.items())}) + "\n")
        status, body = 404, ""
        name = self.path.lstrip("/")
        file = os.path.join(root, name + ".json")
        if name and "/" not in name and os.path.isfile(file):
            with open(file) as f:
                spec = json.load(f)
            if spec.get("hang"):
                time.sleep(60)
            status, body = spec.get("status", 200), spec.get("body", "")
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    do_GET = do_HEAD = do_POST = answer

    def log_message(self, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    # HTTPServer's own server_bind asks for the host's fully qualified name, a reverse lookup
    # that can take seconds on macOS; the handler needs only the address.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


server = Server(("127.0.0.1", 0), Handler)
with open(port_path, "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()

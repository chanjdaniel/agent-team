"""A stand-in for GitHub answering every request with one HTTP status, for the heartbeat's probe.

Usage: python3 -I http-status.py <status> <port file>
Listens on a free port of 127.0.0.1, writes the port to <port file>, and serves until killed.
"""

import http.server
import socketserver
import sys

status = int(sys.argv[1])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


class Server(http.server.HTTPServer):
    # HTTPServer's own server_bind asks for the host's fully qualified name, a reverse lookup
    # that can take seconds on macOS; the handler needs only the address.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


server = Server(("127.0.0.1", 0), Handler)
with open(sys.argv[2], "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()

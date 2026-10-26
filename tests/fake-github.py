"""A tiny fake GitHub API for tests/test-updates.sh (offline).

usage: fake-github.py FIXTURE_DIR PORT_FILE
GET /a/b?q  serves FIXTURE_DIR/a__b (404 when absent). Every other method is appended to FIXTURE_DIR/requests.log as
"METHOD PATH BODY"; POST .../pulls answers {"number": N} with N counting from 100; everything else 201/204 with {}.
"""
import http.server, os, sys

fix = sys.argv[1]

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body=b"{}"):
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        path = self.path.split("?")[0]
        f = os.path.join(fix, path.strip("/").replace("/", "__"))
        if os.path.isfile(f): self.reply(200, open(f, "rb").read())
        else: self.reply(404, b'{"message":"Not Found"}')
    def other(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        with open(os.path.join(fix, "requests.log"), "a") as l: l.write("%s %s %s\n" % (self.command, self.path, body.replace("\n", "\\n")))
        if self.command == "POST" and self.path.endswith("/pulls"):
            c = os.path.join(fix, ".counter")
            k = int(open(c).read()) + 1 if os.path.exists(c) else 100
            open(c, "w").write(str(k)); self.reply(201, ('{"number": %d}' % k).encode())
        elif self.command == "DELETE": self.reply(204, b"")
        else: self.reply(201)
    do_POST = do_PATCH = do_PUT = do_DELETE = other

s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[2], "w").write(str(s.server_address[1]))
s.serve_forever()

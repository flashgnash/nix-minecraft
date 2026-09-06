# Collector for mc-router's connection webhook: appends one JSON line per
# connect/disconnect event (player name, uuid, client IP, requested server)
# to logins.jsonl in the state directory. Loopback only; the router posts
# with -webhook-require-user so server-list pings never land here.
#
# Usage: login-log.py <port> <log-file>
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG_PATH = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            ev = json.loads(self.rfile.read(n))
        except Exception:
            self.send_response(400)
            self.end_headers()
            return
        client = ev.get("client") or {}
        player = ev.get("player") or {}
        entry = {
            "timestamp": ev.get("timestamp"),
            "event": ev.get("event"),
            "player": player.get("name"),
            "uuid": player.get("uuid"),
            "ip": client.get("host"),
            "server": ev.get("server"),
            "backend": ev.get("backend"),
        }
        with open(LOG_PATH, "a") as f:
            f.write(json.dumps(entry) + "\n")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):  # journald noise
        pass


def main():
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()


if __name__ == "__main__":
    main()

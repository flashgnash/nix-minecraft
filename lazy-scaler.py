#!/usr/bin/env python3
# Wake-on-join / sleep-when-idle for servers with `lazy = true`.
#
# mc-router's webhook auto-scaler POSTs {"action":"up"|"down", "backend":
# "127.0.0.1:<port>", "serverAddress": ...} here (loopback only). This
# receiver owns the systemctl privilege (scoped sudo rules) so the router
# stays unprivileged.
#
#   up    Lazy server stopped -> start its unit and hold the request open
#         until RCON answers (the world is loaded), so mc-router keeps showing
#         the loading MOTD for the whole boot. The client that triggered the
#         wake usually times out first (30s) and simply reconnects.
#         Always-on server -> 200 if its unit is active, 503 if not, so a
#         dead always-on server fails fast exactly as it did before.
#   down  Ignored. Idleness is decided here instead, from the server's own
#         player count over RCON: mc-router never arms its idle timer when a
#         wake's client gave up mid-boot, which would leave that server up
#         forever.
#
# Idle monitor: every POLL seconds each running lazy server is asked `list`
# over RCON. Empty for idleSeconds -> stopped. RCON still not answering
# bootTimeoutSeconds after the unit came up -> stopped (a boot that never
# finishes shouldn't burn RAM forever; systemd's own restart loop is left to
# its start limit). Timers start when this process first sees the server
# running, so a restarted receiver never stops anything early.
#
# Usage: lazy-scaler.py <config.json>
# Stdlib only.

import json
import re
import socket
import struct
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

POLL = 30

CONFIG = {}
BY_BACKEND = {}
LOCKS = {}
# name -> {"since": first seen running, "ready": first RCON answer,
#          "busy": last time players were online}
STATE = {}
STATE_LOCK = threading.Lock()


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# ---- RCON --------------------------------------------------------------------

def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("socket closed during payload")
        buf += chunk
    return buf


def rcon_command(port, password, command, timeout=5.0):
    def packet(pid, ptype, body):
        data = struct.pack("<ii", pid, ptype) + body.encode() + b"\x00\x00"
        return struct.pack("<i", len(data)) + data

    def read_packet(sock):
        (length,) = struct.unpack("<i", _recv_exact(sock, 4))
        data = _recv_exact(sock, length)
        pid, ptype = struct.unpack("<ii", data[:8])
        return pid, ptype, data[8:-2].decode("utf-8", "replace")

    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(packet(1, 3, password))
        pid, _, _ = read_packet(sock)
        if pid == -1:
            raise ValueError("rcon auth failed")
        sock.sendall(packet(2, 2, command))
        _, _, resp = read_packet(sock)
        return resp


def player_count(server):
    """Players online via RCON `list`, or None if RCON isn't answering."""
    try:
        with open(server["rconPasswordFile"]) as f:
            password = f.read().strip()
        resp = rcon_command(server["rconPort"], password, "list")
    except Exception:
        return None
    # Vanilla/Forge/NeoForge/Paper: "There are 0 of a max of 20 players online: "
    m = re.search(r"(\d+)", re.sub(r"§.", "", resp))
    return int(m.group(1)) if m else None


# ---- systemd -----------------------------------------------------------------

def unit_state(server):
    r = subprocess.run(
        [CONFIG["systemctl"], "is-active", server["unit"]],
        capture_output=True, text=True,
    )
    return r.stdout.strip() or "unknown"


def run(cmd):
    try:
        subprocess.run(cmd, timeout=120, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        return True
    except Exception as e:
        log("command failed: %s: %s" % (" ".join(cmd), e))
        return False


def mark_running(name, now):
    with STATE_LOCK:
        STATE.setdefault(name, {"since": now, "ready": None, "busy": None})


def wake(server):
    """Start a lazy server if needed and block until RCON answers."""
    name = server["name"]
    with LOCKS[name]:
        state = unit_state(server)
        if state not in ("active", "activating", "reloading"):
            log("wake: starting %s" % name)
            with STATE_LOCK:
                STATE.pop(name, None)
            if not run(server["startCmd"]):
                return False
        mark_running(name, time.time())
    deadline = time.time() + CONFIG["bootTimeoutSeconds"]
    while time.time() < deadline:
        if player_count(server) is not None:
            return True
        if unit_state(server) in ("inactive", "failed"):
            log("wake: %s stopped during boot" % name)
            return False
        time.sleep(2)
    log("wake: %s not ready after %ds" % (name, CONFIG["bootTimeoutSeconds"]))
    return False


# ---- idle monitor ------------------------------------------------------------

def check_idle(server, now):
    name = server["name"]
    if unit_state(server) not in ("active", "activating", "reloading"):
        with STATE_LOCK:
            STATE.pop(name, None)
        return
    mark_running(name, now)
    count = player_count(server)
    with STATE_LOCK:
        st = STATE[name]
        if count is None:
            # Booting, or wedged. Only give up on a server that never came up.
            if st["ready"] is None and now - st["since"] >= CONFIG["bootTimeoutSeconds"]:
                reason = "never became ready"
            else:
                return
        else:
            if st["ready"] is None:
                st["ready"] = now
            if count > 0:
                st["busy"] = now
                return
            empty_since = max(st["ready"], st["busy"] or 0)
            if now - empty_since < CONFIG["idleSeconds"]:
                return
            reason = "empty for %dmin" % ((now - empty_since) // 60)
    # Don't stop a server a wake request is currently holding.
    if not LOCKS[name].acquire(blocking=False):
        return
    try:
        log("sleep: stopping %s (%s)" % (name, reason))
        if run(server["stopCmd"]):
            with STATE_LOCK:
                STATE.pop(name, None)
    finally:
        LOCKS[name].release()


def monitor():
    while True:
        now = time.time()
        for server in CONFIG["servers"]:
            if server["lazy"]:
                try:
                    check_idle(server, now)
                except Exception as e:
                    log("monitor: %s: %s" % (server["name"], e))
        time.sleep(POLL)


# ---- webhook -----------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def reply(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n))
        except Exception:
            return self.reply(400)
        server = BY_BACKEND.get(body.get("backend"))
        if server is None:
            return self.reply(200)  # not ours: don't interfere
        if body.get("action") != "up":
            return self.reply(200)  # "down": the idle monitor decides
        if not server["lazy"]:
            ok = unit_state(server) == "active"
            return self.reply(200 if ok else 503)
        return self.reply(200 if wake(server) else 504)

    def log_message(self, *args):  # journald noise
        pass


def main():
    global CONFIG
    with open(sys.argv[1]) as f:
        CONFIG = json.load(f)
    for server in CONFIG["servers"]:
        LOCKS[server["name"]] = threading.Lock()
        for backend in server["backends"]:
            BY_BACKEND[backend] = server
    threading.Thread(target=monitor, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", CONFIG["port"]), Handler).serve_forever()


if __name__ == "__main__":
    main()

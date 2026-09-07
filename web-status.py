#!/usr/bin/env python3
# Status poller for the minecraft-web listing site.
#
# ONE poller runs on the host (systemd service) and refreshes a single cached
# status.json that every visitor's browser reads via nginx -- browsers never
# touch the Minecraft servers directly, so a page open by 100 people is still
# just one scrape per interval.
#
# Per server it collects:
#   * Server List Ping (SLP)  -> MOTD, online/max players, version   (all loaders)
#   * Prometheus /metrics      -> real TPS (delta of the tick counter) (opt-in)
#   * pack icon                -> downloaded once into icons/          (client packs)
#
# Stdlib only (socket, urllib, json) so it needs no Python packages.

import base64
import hashlib
import html
import json
import os
import re
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

CONFIG_PATH = sys.argv[1]
INTERVAL = float(os.environ.get("POLL_INTERVAL", "30"))
STATE_DIR = os.environ.get("STATE_DIRECTORY", "/var/lib/minecraft-web")
OUT_PATH = os.path.join(STATE_DIR, "status.json")
ICON_DIR = os.path.join(STATE_DIR, "icons")
TPS_STATE_PATH = os.path.join(STATE_DIR, ".tps-state.json")
LAG_REPORT_PATH = os.path.join(STATE_DIR, "lag-reports.jsonl")
REPORTS_DIR = os.path.join(STATE_DIR, "spark-reports")

# Lag auto-profiler: sustained low TPS triggers a spark profile over RCON.
LAG_TPS = float(os.environ.get("LAG_TPS_THRESHOLD", "15"))
LAG_COOLDOWN = float(os.environ.get("LAG_COOLDOWN_SECONDS", "1800"))
LAG_PROFILE_SECS = float(os.environ.get("LAG_PROFILE_SECONDS", "60"))
SPARK_PARSER = os.environ.get("SPARK_PARSER")  # spark-report.py store path

# Filled from the config file in main(): grafana annotation credentials and
# the external base URL the report files are served under (tailnet-only).
GRAFANA_CONF = None
REPORTS_BASE_URL = None


def load_json(path, default):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return default


def atomic_write_json(path, obj):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f)
        # mkstemp creates 0600; nginx (other user) must be able to read it
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise


# ---- Server List Ping (modern, MC 1.7+) --------------------------------------

def _write_varint(value):
    out = bytearray()
    v = value & 0xFFFFFFFF
    while True:
        temp = v & 0x7F
        v >>= 7
        if v:
            out.append(temp | 0x80)
        else:
            out.append(temp)
            break
    return bytes(out)


def _read_varint(sock):
    num = 0
    for i in range(5):
        b = sock.recv(1)
        if not b:
            raise EOFError("socket closed during varint")
        val = b[0]
        num |= (val & 0x7F) << (7 * i)
        if not (val & 0x80):
            break
    return num


def _recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("socket closed during payload")
        buf.extend(chunk)
    return bytes(buf)


def _pack_string(s):
    data = s.encode("utf-8")
    return _write_varint(len(data)) + data


def _flatten_motd(desc):
    # description can be a plain string or a chat-component tree.
    if desc is None:
        return ""
    if isinstance(desc, str):
        return desc
    if isinstance(desc, list):
        return "".join(_flatten_motd(x) for x in desc)
    if isinstance(desc, dict):
        text = desc.get("text", "")
        text += "".join(_flatten_motd(x) for x in desc.get("extra", []))
        return text
    return ""


def _strip_codes(s):
    # drop legacy section-sign colour codes
    out = []
    skip = False
    for ch in s:
        if skip:
            skip = False
            continue
        if ch == "§":
            skip = True
            continue
        out.append(ch)
    return "".join(out).strip()


def ping(host, port, timeout=2.0, proxy_protocol=False):
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        if proxy_protocol:
            # Backends behind the router with proxyProtocol on (paper/folia)
            # require a PROXY header on every connection, pings included.
            sock.sendall(b"PROXY TCP4 127.0.0.1 127.0.0.1 49152 %d\r\n" % port)
        handshake = (
            b"\x00"
            + _write_varint(47)
            + _pack_string(host)
            + struct.pack(">H", port)
            + _write_varint(1)
        )
        sock.sendall(_write_varint(len(handshake)) + handshake)
        sock.sendall(_write_varint(1) + b"\x00")

        _read_varint(sock)          # packet length (ignored)
        packet_id = _read_varint(sock)
        if packet_id != 0:
            raise ValueError("unexpected packet id %d" % packet_id)
        str_len = _read_varint(sock)
        raw = _recv_exact(sock, str_len)
    data = json.loads(raw.decode("utf-8", "replace"))
    players = data.get("players", {}) or {}
    favicon = data.get("favicon")
    # favicon is the server-icon.png as a "data:image/png;base64,..." URI.
    if not (isinstance(favicon, str) and favicon.startswith("data:image")):
        favicon = None
    return {
        "online": True,
        "motd": _strip_codes(_flatten_motd(data.get("description"))),
        "players_online": players.get("online"),
        "players_max": players.get("max"),
        # SLP "sample": up to 12 online player names (server picks which)
        "player_names": [
            _strip_codes(p["name"])
            for p in (players.get("sample") or [])
            if isinstance(p, dict) and isinstance(p.get("name"), str)
        ],
        "version": (data.get("version", {}) or {}).get("name"),
        "favicon": favicon,
    }


# ---- Prometheus scrape (real TPS from the tick counter) ----------------------

def scrape_tick_count(port, timeout=2.0):
    url = "http://127.0.0.1:%d/metrics" % port
    req = urllib.request.Request(url, headers={"User-Agent": "minecraft-web"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        text = r.read().decode("utf-8", "replace")
    for line in text.splitlines():
        # unlabelled series: "mc_server_tick_seconds_count 12345.0"
        if line.startswith("mc_server_tick_seconds_count "):
            try:
                return float(line.split()[-1])
            except Exception:
                return None
    return None


# ---- pack icon (fetched once, then served statically) ------------------------

IMG_EXTS = ("png", "jpg", "jpeg", "webp", "gif")


def existing_icon(name):
    for ext in IMG_EXTS:
        if os.path.exists(os.path.join(ICON_DIR, name + "." + ext)):
            return name + "." + ext
    return None


def ensure_icon(name, urls):
    have = existing_icon(name)
    if have:
        return have
    os.makedirs(ICON_DIR, exist_ok=True)
    for u in urls:
        try:
            req = urllib.request.Request(u, headers={"User-Agent": "minecraft-web"})
            with urllib.request.urlopen(req, timeout=5.0) as r:
                ctype = r.headers.get("Content-Type", "")
                data = r.read()
        except Exception:
            continue
        if not data or len(data) < 64 or "image" not in ctype:
            continue
        ext = "png"
        if "jpeg" in ctype or "jpg" in ctype:
            ext = "jpg"
        elif "webp" in ctype:
            ext = "webp"
        elif "gif" in ctype:
            ext = "gif"
        dest = os.path.join(ICON_DIR, name + "." + ext)
        try:
            with open(dest, "wb") as f:
                f.write(data)
            return name + "." + ext
        except Exception:
            continue
    return None


# ---- lag auto-profiler (spark over RCON) -------------------------------------
#
# When a server's TPS sits below LAG_TPS, run `spark profiler` on it for
# LAG_PROFILE_SECS via RCON and append the viewer URL (which names the chunks
# and entities burning the tick) to lag-reports.jsonl. One profile per server
# per LAG_COOLDOWN. Needs the spark mod in the pack (from Modrinth) and RCON
# on loopback — both wired up by the nix module when sparkOnLag is set.

_lag_lock = threading.Lock()
_lag_state = {}  # name -> {"running": bool, "last": ts}


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


def parse_top_mods(path):
    if not SPARK_PARSER:
        return None
    try:
        out = subprocess.run(
            [sys.executable, SPARK_PARSER, "--json", path],
            capture_output=True, timeout=120, check=True,
        )
        return json.loads(out.stdout).get("mods")
    except Exception as e:
        print("lag-profiler: mod extraction failed: %s" % e, file=sys.stderr)
        return None


def regenerate_report_index():
    entries = []
    try:
        with open(LAG_REPORT_PATH) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if e.get("file"):
                    entries.append(e)
    except FileNotFoundError:
        pass
    entries.reverse()
    rows = []
    for e in entries:
        mods = ", ".join(
            "%s %.1fms" % (m["name"], m["ms_per_tick"]) for m in (e.get("top_mods") or [])[:5]
        )
        rows.append(
            "<tr><td>%s</td><td>%s</td><td>%.1f</td><td>%s</td>"
            '<td><a href="/%s">download</a></td></tr>'
            % (html.escape(e["timestamp"]), html.escape(e["server"]), e.get("tps") or 0,
               html.escape(mods), html.escape(e["file"]))
        )
    page = (
        "<!doctype html><html><head><meta charset=utf-8><title>Lag reports</title><style>"
        "body{font-family:ui-monospace,monospace;background:#192227;color:#fff;padding:2rem}"
        "table{border-collapse:collapse;width:100%}td,th{border:1px solid #3a4a52;"
        "padding:.4rem .7rem;text-align:left;font-size:.9rem}th{color:#9dff00}"
        "a{color:#9dff00}p{color:rgba(255,255,255,.55)}"
        "</style></head><body><h1>Lag reports</h1>"
        "<p>Captured automatically when TPS dips below %s. Open a .sparkprofile in the "
        '<a href="https://spark.lucko.me">spark viewer</a> for the full flame graph; '
        "top mods by ms/tick are extracted below.</p>"
        "<table><tr><th>when</th><th>server</th><th>tps</th><th>top mods (ms/tick)</th><th>profile</th></tr>%s</table>"
        "</body></html>" % (LAG_TPS, "".join(rows))
    )
    with open(os.path.join(REPORTS_DIR, "index.html"), "w") as f:
        f.write(page)


def post_grafana_annotation(entry, at_ms):
    if not GRAFANA_CONF:
        return
    try:
        with open(GRAFANA_CONF["passwordFile"]) as f:
            password = f.read().strip()
        text = "Lag spike on %s (TPS %.1f)" % (entry["server"], entry.get("tps") or 0)
        if entry.get("top_mods"):
            text += " — top: " + ", ".join(
                "%s %.1fms" % (m["name"], m["ms_per_tick"]) for m in entry["top_mods"][:3]
            )
        if REPORTS_BASE_URL and entry.get("file"):
            text += ' <a href="%s/%s">profile</a> (<a href="%s/">all reports</a>)' % (
                REPORTS_BASE_URL, entry["file"], REPORTS_BASE_URL)
        body = json.dumps({
            "time": at_ms,
            "tags": ["lag-report", "server:" + entry["server"]],
            "text": text,
        }).encode()
        req = urllib.request.Request(
            GRAFANA_CONF["url"] + "/api/annotations",
            data=body,
            headers={
                "Content-Type": "application/json",
                "Authorization": "Basic "
                + base64.b64encode(b"admin:" + password.encode()).decode(),
            },
        )
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE  # loopback; cert is for the tailnet name
        urllib.request.urlopen(req, timeout=10, context=ctx).read()
    except Exception as e:
        print("lag-profiler: annotation failed: %s" % e, file=sys.stderr)


def _run_lag_profile(name, rcon_port, password_file, tps):
    try:
        with open(password_file) as f:
            password = f.read().strip()
        rcon_command(rcon_port, password, "spark profiler start")
        time.sleep(LAG_PROFILE_SECS)
        started_ms = int((time.time() - LAG_PROFILE_SECS) * 1000)
        resp = _strip_codes(
            rcon_command(rcon_port, password, "spark profiler stop --save-to-file", timeout=30.0)
        )
        entry = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "server": name,
            "tps": tps,
        }
        m = re.search(r"(/\S+\.sparkprofile)", resp)
        if m:
            os.makedirs(REPORTS_DIR, exist_ok=True)
            fname = "%s-%s.sparkprofile" % (time.strftime("%Y%m%d-%H%M%S"), name)
            shutil.move(m.group(1), os.path.join(REPORTS_DIR, fname))
            os.chmod(os.path.join(REPORTS_DIR, fname), 0o644)
            entry["file"] = fname
            entry["top_mods"] = parse_top_mods(os.path.join(REPORTS_DIR, fname))
            regenerate_report_index()
        else:
            entry["response"] = resp[:400]
        with open(LAG_REPORT_PATH, "a") as f:
            f.write(json.dumps(entry) + "\n")
        post_grafana_annotation(entry, started_ms)
        print("lag-profiler: %s tps=%.1f -> %s" % (name, tps, entry.get("file") or "no file"),
              file=sys.stderr)
    except Exception as e:
        print("lag-profiler: %s failed: %s" % (name, e), file=sys.stderr)
    finally:
        with _lag_lock:
            _lag_state[name] = {"running": False, "last": time.time()}


def maybe_profile_lag(server_conf, tps):
    rcon_port = server_conf.get("rconPort")
    password_file = server_conf.get("rconPasswordFile")
    if not rcon_port or not password_file or tps is None or tps >= LAG_TPS:
        return
    name = server_conf["name"]
    with _lag_lock:
        st = _lag_state.get(name, {})
        if st.get("running") or time.time() - st.get("last", 0) < LAG_COOLDOWN:
            return
        _lag_state[name] = {"running": True, "last": st.get("last", 0)}
    print("lag-profiler: %s tps=%.1f — starting spark profile" % (name, tps), file=sys.stderr)
    threading.Thread(
        target=_run_lag_profile,
        args=(name, rcon_port, password_file, tps),
        daemon=True,
    ).start()


# ---- packwiz metadata (name, description, mod list) --------------------------
#
# pack.toml gives name/version/description; the index.toml it points at lists
# every file, and mods show up as mods/<slug>.pw.toml metafiles. Fetching each
# metafile would be hundreds of requests, so the mod list is the prettified
# slugs. Cached in memory and refreshed hourly.

PACK_META_TTL = 3600
_pack_meta_cache = {}


def _fetch_bytes(url, timeout=5.0):
    req = urllib.request.Request(url, headers={"User-Agent": "minecraft-web"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def _fetch_text(url, timeout=5.0):
    return _fetch_bytes(url, timeout).decode("utf-8", "replace")


def pack_meta(packwiz_url):
    if not packwiz_url:
        return None
    cached = _pack_meta_cache.get(packwiz_url)
    if cached and time.time() - cached["t"] < PACK_META_TTL:
        return cached["data"]

    data = None
    try:
        import tomllib

        # Raw bytes: the sha256 must be byte-exact with what preStart's
        # `curl | sha256sum` recorded, so hash before any decode.
        raw = _fetch_bytes(packwiz_url)
        pack = tomllib.loads(raw.decode("utf-8", "replace"))
        base = packwiz_url.rsplit("/", 1)[0]
        mods = []
        try:
            index_file = (pack.get("index") or {}).get("file", "index.toml")
            index = tomllib.loads(_fetch_text(base + "/" + index_file))
            for f in index.get("files") or []:
                path = f.get("file", "")
                if path.startswith("mods/") and path.endswith(".pw.toml"):
                    slug = path[len("mods/") : -len(".pw.toml")]
                    mods.append(slug.replace("-", " ").replace("_", " ").title())
        except Exception:
            pass
        data = {
            "name": pack.get("name"),
            "version": pack.get("version"),
            "description": pack.get("description"),
            "mod_count": len(mods) if mods else None,
            "mods": sorted(mods),
            # Consumed by the update auto-restart; pack.toml is public anyway.
            "raw_sha256": hashlib.sha256(raw).hexdigest(),
        }
    except Exception:
        # keep serving a stale copy if the refresh fails
        if cached:
            return cached["data"]
    _pack_meta_cache[packwiz_url] = {"t": time.time(), "data": data}
    return data


# ---- pack-update auto-restart ------------------------------------------------
#
# Servers configured with autoRestartOnUpdate get restarted (via a sudo rule
# scoped to exactly that systemctl command) when the remote pack.toml's hash
# diverges from the one the server's last start applied — but only while the
# server is up and has been empty for its idle window, so nobody is kicked.
# The restarted server's preStart runs packwiz and refreshes the applied-hash
# marker; one attempt is made per remote revision (persisted), so a fetch
# failure or broken update can't restart-loop the server.

RESTART_STATE_PATH = os.path.join(STATE_DIR, ".autorestart-state.json")
_restart_last_active = {}  # name -> ts of the last poll that wasn't "online and empty"
_poller_started = time.time()


def maybe_auto_restart(server_conf, entry, remote_hash):
    ar = server_conf.get("autoRestart")
    if not ar:
        return
    name = server_conf["name"]
    now = time.time()
    # Counting starts at poller startup: a fresh poller must observe a full
    # idle window itself before it may restart anything.
    last_active = _restart_last_active.setdefault(name, _poller_started)
    if not (entry.get("online") and entry.get("players_online") == 0):
        _restart_last_active[name] = now
        return
    if now - last_active < ar.get("idleSeconds", 900) or not remote_hash:
        return
    try:
        with open(ar["appliedHashFile"]) as f:
            applied = f.read().strip()
    except OSError:
        return
    if not applied or applied == remote_hash:
        return
    state = load_json(RESTART_STATE_PATH, {})
    if state.get(name) == remote_hash:
        return  # this revision was already attempted — don't loop
    state[name] = remote_hash
    atomic_write_json(RESTART_STATE_PATH, state)
    print(
        "auto-restart: %s empty %dmin with pack update pending (%s.. -> %s..) — restarting"
        % (name, int(now - last_active) // 60, applied[:12], remote_hash[:12]),
        file=sys.stderr,
    )
    try:
        subprocess.run(
            ar["restartCmd"], timeout=180, check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
        )
    except Exception as e:
        print("auto-restart: %s failed: %s" % (name, e), file=sys.stderr)


# ---- main loop ---------------------------------------------------------------

def poll_once(servers):
    tps_state = load_json(TPS_STATE_PATH, {})
    new_tps_state = {}
    now = time.time()
    result = []

    for s in servers:
        name = s["name"]
        entry = {
            "name": name,
            "loader": s.get("loader"),
            "address": s.get("address"),
            "online": False,
            "motd": None,
            "players_online": None,
            "players_max": None,
            "player_names": [],
            "version": None,
            "tps": None,
            "icon": existing_icon(name),
            "favicon": None,
            "pack": pack_meta(s.get("packwizUrl")),
        }

        try:
            p = ping("127.0.0.1", s["port"], proxy_protocol=bool(s.get("proxyProtocol")))
            entry.update(
                online=True,
                motd=p["motd"] or None,
                players_online=p["players_online"],
                players_max=p["players_max"],
                player_names=p["player_names"],
                version=p["version"],
                favicon=p["favicon"],
            )
        except Exception:
            entry["online"] = False

        mport = s.get("metricsPort")
        if mport:
            try:
                count = scrape_tick_count(int(mport))
            except Exception:
                count = None
            if count is not None:
                prev = tps_state.get(name)
                if prev and count >= prev.get("count", 0) and now > prev.get("t", 0):
                    dt = now - prev["t"]
                    dc = count - prev["count"]
                    if dt > 0:
                        entry["tps"] = round(max(0.0, min(20.0, dc / dt)), 1)
                new_tps_state[name] = {"count": count, "t": now}
            maybe_profile_lag(s, entry["tps"])

        maybe_auto_restart(s, entry, (entry["pack"] or {}).get("raw_sha256"))

        # Only client packs carry a pack icon.
        if s.get("iconUrls"):
            got = ensure_icon(name, s["iconUrls"])
            if got:
                entry["icon"] = got

        result.append(entry)

    atomic_write_json(TPS_STATE_PATH, new_tps_state)
    atomic_write_json(
        OUT_PATH,
        {"updated": int(now), "servers": result},
    )


def main():
    global GRAFANA_CONF, REPORTS_BASE_URL
    cfg = load_json(CONFIG_PATH, {"servers": []})
    servers = cfg.get("servers", [])
    GRAFANA_CONF = cfg.get("grafana")
    REPORTS_BASE_URL = cfg.get("reportsBaseUrl")
    os.makedirs(STATE_DIR, exist_ok=True)
    os.makedirs(ICON_DIR, exist_ok=True)
    while True:
        try:
            poll_once(servers)
        except Exception as e:
            sys.stderr.write("poll failed: %r\n" % (e,))
            sys.stderr.flush()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()

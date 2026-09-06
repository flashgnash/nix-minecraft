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

import json
import os
import socket
import struct
import sys
import tempfile
import time
import urllib.request

CONFIG_PATH = sys.argv[1]
INTERVAL = float(os.environ.get("POLL_INTERVAL", "30"))
STATE_DIR = os.environ.get("STATE_DIRECTORY", "/var/lib/minecraft-web")
OUT_PATH = os.path.join(STATE_DIR, "status.json")
ICON_DIR = os.path.join(STATE_DIR, "icons")
TPS_STATE_PATH = os.path.join(STATE_DIR, ".tps-state.json")


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


def ping(host, port, timeout=2.0):
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
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
            "version": None,
            "tps": None,
            "icon": existing_icon(name),
            "favicon": None,
        }

        try:
            p = ping("127.0.0.1", s["port"])
            entry.update(
                online=True,
                motd=p["motd"] or None,
                players_online=p["players_online"],
                players_max=p["players_max"],
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
    cfg = load_json(CONFIG_PATH, {"servers": []})
    servers = cfg.get("servers", [])
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

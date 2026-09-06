#!/usr/bin/env python3
# Minimal stdlib-only reader for spark .sparkprofile payloads (SamplerData
# protobuf): extracts profile metadata and aggregates "ms per tick per mod"
# the same way the viewer's Mods view does — for each source, sum the total
# time of frames attributed to it, skipping frames whose ancestor was already
# attributed to the same source, then divide by the tick count.
import gzip
import json
import struct
import sys


def read_varint(buf, i):
    result = 0
    shift = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def walk(buf, handlers):
    i = 0
    n = len(buf)
    while i < n:
        tag, i = read_varint(buf, i)
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            val, i = read_varint(buf, i)
        elif wire == 1:
            val = buf[i : i + 8]
            i += 8
        elif wire == 2:
            ln, i = read_varint(buf, i)
            val = buf[i : i + ln]
            i += ln
        elif wire == 5:
            val = buf[i : i + 4]
            i += 4
        else:
            raise ValueError("wire type %d" % wire)
        h = handlers.get(field)
        if h:
            h(val)


def parse_map_entry(buf):
    kv = {}
    walk(buf, {1: lambda v: kv.__setitem__("k", v.decode("utf-8", "replace")),
               2: lambda v: kv.__setitem__("v", v.decode("utf-8", "replace"))})
    return kv.get("k"), kv.get("v")


def packed_doubles(buf):
    return [struct.unpack("<d", buf[j : j + 8])[0] for j in range(0, len(buf) - 7, 8)]


def packed_varints(buf):
    out = []
    i = 0
    while i < len(buf):
        v, i = read_varint(buf, i)
        out.append(v)
    return out


def parse_stack_node(buf):
    node = {"class": None, "times": [], "refs": []}
    walk(buf, {
        3: lambda v: node.__setitem__("class", v.decode("utf-8", "replace")),
        8: lambda v: node.__setitem__("times", packed_doubles(v)),
        9: lambda v: node.__setitem__("refs", packed_varints(v)),
    })
    return node


def parse_thread(buf):
    t = {"name": None, "pool": [], "roots": []}
    walk(buf, {
        1: lambda v: t.__setitem__("name", v.decode("utf-8", "replace")),
        3: lambda v: t["pool"].append(parse_stack_node(v)),
        4: lambda v: t.__setitem__("times", packed_doubles(v)),
        5: lambda v: t.__setitem__("roots", packed_varints(v)),
    })
    return t


def parse_metadata(buf):
    md = {}
    walk(buf, {
        2: lambda v: md.__setitem__("start_time", v),
        11: lambda v: md.__setitem__("end_time", v),
        12: lambda v: md.__setitem__("number_of_ticks", v),
        3: lambda v: md.__setitem__("interval", v),
    })
    return md


def parse(path):
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    data = {"threads": [], "class_sources": {}, "metadata": {}}
    walk(raw, {
        1: lambda v: data.__setitem__("metadata", parse_metadata(v)),
        2: lambda v: data["threads"].append(parse_thread(v)),
        3: lambda v: data["class_sources"].__setitem__(*parse_map_entry(v)),
    })
    return data


def mod_times(data):
    sources = data["class_sources"]
    ticks = data["metadata"].get("number_of_ticks") or 0
    totals = {}
    for t in data["threads"]:
        pool = t["pool"]

        def visit(idx, ancestor_source):
            node = pool[idx]
            src = sources.get(node["class"])
            if src is not None and src != ancestor_source:
                totals[src] = totals.get(src, 0.0) + sum(node["times"])
                nxt = src
            else:
                nxt = ancestor_source if src is None else src
            for r in node["refs"]:
                visit(r, nxt)

        sys.setrecursionlimit(100000)
        for r in t.get("roots", []):
            visit(r, None)
    if not ticks:
        return {}
    return {k: v / ticks for k, v in totals.items()}


if __name__ == "__main__":
    # spark-report.py [--json] <file.sparkprofile>
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv
    data = parse(args[0])
    md = data["metadata"]
    per_mod = mod_times(data)
    top = sorted(per_mod.items(), key=lambda kv: -kv[1])
    if as_json:
        print(json.dumps({
            "ticks": md.get("number_of_ticks"),
            "mods": [{"name": n, "ms_per_tick": round(v, 2)} for n, v in top],
        }))
    else:
        print("ticks:", md.get("number_of_ticks"), "threads:", len(data["threads"]),
              "classes mapped:", len(data["class_sources"]))
        for name, ms in top[:20]:
            print("%8.2f ms/tick  %s" % (ms, name))

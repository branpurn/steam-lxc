#!/usr/bin/env python3
"""B1 (offline): steam-lxc-vrclass against synthetic appinfo.vdf fixtures (v29 with string table, and v28).
Field layout mirrors a real Steam cache: flat game = no VR keys; VR-optional = openvrsupport/openxrsupport +
category_53; VR-only = onlyvrsupport + category_54; SteamVR = type Tool + category_53."""
import importlib.machinery, importlib.util, os, struct, sys, tempfile
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("vrclass", os.path.join(HERE, "..", "bin", "steam-lxc-vrclass"))
spec = importlib.util.spec_from_loader("vrclass", loader); V = importlib.util.module_from_spec(spec); loader.exec_module(V)

APPS = {
    1001: {"common": {"type": "game", "name": "Flat Game", "category": {"category_1": "1"}}},
    1002: {"common": {"type": "Game", "name": "VR Optional", "openvrsupport": 1, "openxrsupport": 1,
                      "controllervr": {"steamvr": 1}, "category": {"category_53": "1"}}},
    1003: {"common": {"type": "Game", "name": "VR Only", "openvrsupport": 1, "onlyvrsupport": 1,
                      "category": {"category_54": "1"}}},
    1004: {"common": {"type": "Game", "name": "Cat only", "category": {"category_54": "1"}}},
    1005: {"common": {"type": "Game", "name": "XR only", "openxrsupport": "1"}},
    1006: {"common": {"type": "Tool", "name": "Some tool"}},
    1007: {"extended": {"x": "y"}},
    250820: {"common": {"type": "Tool", "name": "SteamVR", "category": {"category_53": "1"}}},
}

def kv(d, strings):
    out = b""
    for k, v in d.items():
        if strings is not None:
            if k not in strings: strings.append(k)
            key = struct.pack("<I", strings.index(k))
        else:
            key = k.encode() + b"\0"
        if isinstance(v, dict): out += b"\0" + key + kv(v, strings)
        elif isinstance(v, int): out += b"\2" + key + struct.pack("<i", v)
        else: out += b"\1" + key + str(v).encode() + b"\0"
    return out + b"\x08"

def build(version):
    strings = [] if version == 29 else None
    body = b""
    for appid, d in APPS.items():
        payload = struct.pack("<IIQ", 2, 0, 0) + b"\0" * 20 + struct.pack("<I", 1) + b"\0" * 20 + kv({"appinfo": {"appid": appid, **d}}, strings)
        body += struct.pack("<II", appid, len(payload)) + payload
    body += struct.pack("<I", 0)
    if version == 29:
        head = struct.pack("<II", 0x07564429, 1)
        off = len(head) + 8 + len(body)
        tab = struct.pack("<I", len(strings)) + b"".join(s.encode() + b"\0" for s in strings)
        return head + struct.pack("<q", off) + body + tab
    return struct.pack("<II", 0x07564428, 1) + body

WANT = {"1001": "flat", "1002": "vr", "1003": "vr", "1004": "vr", "1005": "vr", "1006": "unknown",
        "1007": "unknown", "250820": "ignore", "9999": "unknown"}
fails = 0
def check(name, got, want):
    global fails
    ok = got == want; fails += not ok
    print(("PASS" if ok else "FAIL"), name, got, f"(want {want})")

with tempfile.TemporaryDirectory() as t:
    for ver in (29, 28):
        p = os.path.join(t, f"appinfo{ver}.vdf"); open(p, "wb").write(build(ver))
        infos = V.read_appinfo(p, set(WANT))
        for app, want in WANT.items():
            check(f"v{ver} app {app}", V.classify(app, infos.get(app))[0], want)
    # Overrides win (VR list over everything, FLAT list over appinfo VR).
    infos = V.read_appinfo(os.path.join(t, "appinfo29.vdf"), None)
    check("override flat over VR-only", V.classify("1003", infos["1003"], set(), {"1003"})[0], "flat")
    check("override vr over flat", V.classify("1001", infos["1001"], {"1001"}, set())[0], "vr")
    check("override vr over unknown", V.classify("9999", None, {"9999"}, set())[0], "vr")
    # Unreadable / unsupported cache -> unknown (which yields), never a crash.
    bad = os.path.join(t, "bad.vdf"); open(bad, "wb").write(b"\x01\x02\x03\x04" * 4)
    try: V.read_appinfo(bad, None); check("bad magic raises", "no-raise", "raise")
    except ValueError: check("bad magic raises", "raise", "raise")
    # CLI path end-to-end with a defaults file holding override lists.
    d = os.path.join(t, "defaults"); open(d, "w").write("FRAME_SHIM_STEAMVR_YIELD_FLAT=\"1002, 1005\"\n")
    import subprocess
    r = subprocess.run([sys.executable, loader.path, "--appinfo", os.path.join(t, "appinfo29.vdf"), "1002", "1003", "1001"],
                       env={**os.environ, "STEAM_LXC_DEFAULTS": d}, capture_output=True, text=True)
    got = {l.split()[0]: l.split()[1] for l in r.stdout.splitlines()}
    check("cli overrides", got, {"1002": "flat", "1003": "vr", "1001": "flat"})
    r = subprocess.run([sys.executable, loader.path, "--appinfo", bad, "1001"], env={**os.environ, "STEAM_LXC_DEFAULTS": "/nonexistent"},
                       capture_output=True, text=True)
    check("cli unreadable cache", r.stdout.split()[1] if r.stdout else "", "unknown")
print("B1", "OK" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)

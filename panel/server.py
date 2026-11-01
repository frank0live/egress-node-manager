#!/usr/bin/env python3
# small web panel for egress-node-manager.
# stdlib only, nothing to install.
# shows one row per node like check-psiphon.sh does.

import argparse
import glob
import html
import json
import os
import socket
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
MGR = os.path.join(os.path.dirname(HERE), "egress-node-manager.sh")
META_DIR = "/etc/egress-nodes/nodes"


# read one KEY="value" meta file into a dict
def read_meta(path):
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"')
    return out


def list_nodes():
    nodes = []
    for path in sorted(glob.glob(os.path.join(META_DIR, "*.env"))):
        try:
            nodes.append(read_meta(path))
        except OSError:
            continue
    return nodes


def svc_active(svc):
    try:
        r = subprocess.run(
            ["systemctl", "is-active", svc],
            capture_output=True, text=True, timeout=10,
        )
        return r.stdout.strip() == "active"
    except Exception:
        return False


# quick egress check through the local socks port
def socks_lookup(port, timeout=8):
    start = time.monotonic()
    try:
        s = socket.create_connection(("127.0.0.1", int(port)), timeout=timeout)
        s.settimeout(timeout)
        s.sendall(b"\x05\x01\x00")
        if s.recv(2) != b"\x05\x00":
            raise OSError("socks hello failed")
        host = "ip-api.com"
        req = b"\x05\x01\x00\x03" + bytes([len(host)]) + host.encode() + b"\x00\x50"
        s.sendall(req)
        rep = s.recv(10)
        if len(rep) < 2 or rep[1] != 0:
            raise OSError("socks connect failed")
        s.sendall(
            b"GET /json?fields=query,countryCode HTTP/1.0\r\n"
            b"Host: ip-api.com\r\nConnection: close\r\n\r\n"
        )
        raw = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            raw += chunk
        s.close()
        ms = int((time.monotonic() - start) * 1000)
        body = raw.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in raw else b""
        info = json.loads(body.decode("utf-8", "replace") or "{}")
        return info.get("query", "") or "", info.get("countryCode", "") or "", ms
    except Exception:
        return "", "", 0


def node_status(meta):
    cc = (meta.get("COUNTRY_CODE") or "").lower()
    want = (meta.get("COUNTRY_CODE_UPPER") or cc.upper()).upper()
    port = meta.get("SOCKS_PORT", "")
    svc = meta.get("SERVICE_NAME", "")
    active = svc_active(svc) if svc else False
    ip, ecc, ms = socks_lookup(port) if active and port else ("", "", 0)
    return {
        "cc": cc,
        "service": svc,
        "active": active,
        "port": port,
        "egress_ip": ip,
        "egress_cc": ecc,
        "latency_ms": ms,
        "mismatch": bool(ip and ecc and ecc.upper() != want),
    }


PAGE = """<!doctype html>
<html><head><meta charset="utf-8">
<title>egress nodes</title>
<style>
body{font-family:monospace;max-width:900px;margin:30px auto;padding:0 15px}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid #ccc;padding:6px 8px;text-align:left}
.bad{color:#b00;font-weight:bold}
.ok{color:#080}
button{font-family:inherit;cursor:pointer}
</style></head>
<body>
<h2>egress nodes</h2>
<p><button onclick="load()">refresh</button> <span id="ts"></span></p>
<table>
<tr><th>LOC</th><th>SERVICE</th><th>PORT</th><th>EGRESS-IP</th><th>CC</th><th>SPEED</th></tr>
<tbody id="rows"><tr><td colspan="6">loading...</td></tr></tbody>
</table>
<script>
async function load(){
  const r = await fetch('/api/status');
  const j = await r.json();
  const tb = document.getElementById('rows');
  tb.innerHTML = '';
  for (const n of j.nodes){
    const tr = document.createElement('tr');
    const mark = n.mismatch ? ' <span class="bad">&lt;-- MISMATCH (want ' + n.cc.toUpperCase() + ')</span>' : '';
    const st = n.active ? '<span class="ok">active</span>' : 'inactive';
    tr.innerHTML = '<td>' + n.cc + '</td><td>' + st + '</td><td>' + n.port +
      '</td><td>' + (n.egress_ip || '-') + '</td><td>' + (n.egress_cc || '-') +
      '</td><td>' + n.latency_ms + 'ms' + mark + '</td>';
    tb.appendChild(tr);
  }
  document.getElementById('ts').textContent = new Date().toLocaleTimeString();
}
load();
setInterval(load, 30000);
</script>
</body></html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send(self, code, body, ctype="text/html"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/":
            self._send(200, PAGE)
        elif self.path == "/api/status":
            nodes = list_nodes()
            with ThreadPoolExecutor(max_workers=8) as pool:
                out = list(pool.map(node_status, nodes))
            self._send(200, json.dumps({"nodes": out}), "application/json")
        else:
            self._send(404, "not found", "text/plain")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8787)
    args = ap.parse_args()
    srv = HTTPServer((args.host, args.port), Handler)
    print("listening on http://%s:%d" % (args.host, srv.server_port))
    srv.serve_forever()


if __name__ == "__main__":
    main()

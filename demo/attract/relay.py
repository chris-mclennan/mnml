#!/usr/bin/env python3
"""The published port, for a container that has no network.

`demo/run-local.sh` runs the demo with `--network none`: no interface but
loopback, so nothing in it can reach anything — and nothing can reach it
either, because docker discards published ports on that network. This
relay runs as a second container from the same image, on the default
bridge, with the demo's socket volume mounted: it accepts TCP on
MNML_DEMO_PORT and splices each connection to the attract runner's unix
socket. It reads nothing and runs nothing else.

A host (Fly, Cloudflare Containers) gives the demo its own ingress and an
egress policy instead; there the runner listens on TCP and this is not
used (demo/README.md).
"""

import os
import selectors
import socket
import sys
import threading

PORT = int(os.environ.get("MNML_DEMO_PORT", "7681"))
SOCK = os.environ.get("MNML_DEMO_SOCK", "/run/mnml-demo/http.sock")


def splice(down):
    try:
        up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        up.connect(SOCK)
    except OSError:
        down.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 18\r\nConnection: close\r\n\r\nthe demo is not up")
        down.close()
        return
    sel = selectors.DefaultSelector()
    sel.register(down, selectors.EVENT_READ, up)
    sel.register(up, selectors.EVENT_READ, down)
    try:
        while True:
            for key, _ in sel.select():
                data = key.fileobj.recv(65536)
                if not data:
                    return
                key.data.sendall(data)
    except OSError:
        pass
    finally:
        sel.close()
        up.close()
        down.close()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT))
    srv.listen(64)
    print(f"relay: :{PORT} -> {SOCK}", file=sys.stderr, flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=splice, args=(c,), daemon=True).start()


if __name__ == "__main__":
    main()

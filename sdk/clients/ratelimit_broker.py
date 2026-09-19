"""Ask mnml's local broker for an API token; fall back to the file bucket.

The shared token bucket (`<service>-ratelimit.json`) already makes every
process on this machine draw from one budget. What it cannot do is decide
who goes NEXT: it is first-come, so the pane a human is looking at queues
behind whatever sweep asked a millisecond earlier.

mnml hosts a broker while it runs — one Unix socket per service, four
classes, the pane first — and this is the twenty lines that talk to it.
`acquire` returns True when a token was granted and False when it was
not; False is the same fail-open the file bucket gives, so the caller
should send anyway and let its own 429 handling decide.

**It is not a dependency.** No broker (mnml closed, another platform, the
socket missing) is a clean False from `acquire_via_broker`, and the caller
goes on to the file bucket exactly as before.

How `bb_ratelimit.py` would use it — two lines, nothing else changed:

    from ratelimit_broker import acquire_via_broker

    class _Bucket:
        def acquire(self, timeout: float = MAX_BLOCK) -> bool:
            if acquire_via_broker("bitbucket", "batch", "sweep", timeout):
                return True
            ...                       # the existing file-bucket loop

Pick the class by who is waiting: "interactive" (a human is), "refresh"
(wanted soon), "warm" (speculative), "batch" (a script — the default, and
the back of the queue on purpose).

Where the socket is, in the order the state file resolves:
`<SERVICE>_BROKER_SOCKET`, else `<service>-broker.sock` beside the
ratelimit state file -- and, when that path is too long for a
`sockaddr_un`, `/tmp/mnml-broker-<service>.sock`, which both ends
derive from the service alone so they still meet. `MNML_BROKER=0`
turns it off entirely.
"""

import json
import os
import socket


def broker_socket(service: str) -> str:
    """The socket path for a service, or "" when the broker is off."""
    if os.environ.get("MNML_BROKER", "1").lower() in ("0", "off", "false", "no"):
        return ""
    named = os.environ.get(f"{service.upper()}_BROKER_SOCKET")
    if named:
        return named
    root = os.environ.get("TATTLE_ARTIFACTS_ROOT") or os.path.expanduser(
        "~/.tattle-claude-artifacts")
    path = os.path.join(root, f"{service}-broker.sock")
    # sun_path is 104 bytes on macOS and 108 on Linux, so a deep root
    # cannot hold a socket. Both sides fall back to the same short name
    # derived from the service alone -- drop this and the two ends
    # silently stop meeting on any long path.
    return path if len(path) <= 100 else f"/tmp/mnml-broker-{service}.sock"


def acquire_via_broker(service: str, cls: str = "batch", reason: str = "batch",
                       timeout: float = 120.0) -> bool:
    """True if the broker granted a token. False means fall back."""
    path = broker_socket(service)
    if not path or not hasattr(socket, "AF_UNIX"):
        return False
    req = {"v": 1, "op": "acquire", "service": service, "class": cls,
           "client": f"{os.path.basename(__file__)}:{os.getpid()}",
           "reason": reason, "timeout_ms": int(timeout * 1000)}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout + 5.0)
            s.connect(path)
            s.sendall((json.dumps(req) + "\n").encode())
            return json.loads(s.makefile("r").readline() or "{}").get("ok", False)
    except (OSError, ValueError):
        return False                                  # no broker: use the file


def broker_status(service: str) -> dict:
    """The broker's own numbers, or {} when there is none."""
    path = broker_socket(service)
    if not path or not hasattr(socket, "AF_UNIX"):
        return {}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2.0)
            s.connect(path)
            s.sendall((json.dumps({"v": 1, "op": "status",
                                   "service": service}) + "\n").encode())
            return json.loads(s.makefile("r").readline() or "{}")
    except (OSError, ValueError):
        return {}


if __name__ == "__main__":
    import sys
    svc = sys.argv[1] if len(sys.argv) > 1 else "bitbucket"
    st = broker_status(svc)
    if not st:
        print(f"{svc}: no broker at {broker_socket(svc) or '(off)'}")
    else:
        q = st.get("queue", {})
        print(f"{svc}: queue {sum(q.values())} · {st.get('tokens', 0):.1f} of "
              f"{st.get('capacity', 0):.0f} tokens · {st.get('served', 0)} served")

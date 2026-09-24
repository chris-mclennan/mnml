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

    from ratelimit_broker import try_broker

    class _Bucket:
        def acquire(self, timeout: float = MAX_BLOCK) -> bool:
            answer = try_broker("bitbucket", "batch", "sweep", timeout)
            if answer is not None:    # a broker answered: its word is final
                return answer
            ...                       # no broker: the existing file-bucket loop

Pick the class by who is waiting: "interactive" (a human is), "refresh"
(wanted soon), "warm" (speculative), "batch" (a script — the default, and
the back of the queue on purpose).

Where the socket is, in the order the state file resolves:
`<SERVICE>_BROKER_SOCKET`, else `<service>-broker.sock` beside the
ratelimit state file -- and, when that path is too long for a
`sockaddr_un`, `/tmp/mnml-broker-<service>-<hash>.sock`, which both
ends derive from the service and the long path so they still meet. `MNML_BROKER=0`
turns it off entirely.

The `/tmp` fallback is the DERIVED path's only. A `<SERVICE>_BROKER_SOCKET`
set by hand is used exactly as set -- a socket somewhere other than the
place you named would be worse than none -- so one past the limit raises
`BrokerPathTooLong`, naming the variable and both lengths. The two
callers below catch it, warn once and fall through to the file bucket,
because a misconfigured broker must still not be a dependency.
"""

import hashlib
import json
import os
import socket
import sys

# What this platform's `sockaddr_un.sun_path` holds, NUL included --
# and, one fewer, the longest path that can go in it. The Zig side's
# `broker.os_path_len` / `os_max_path_len`, same numbers.
OS_PATH_LEN = 104 if sys.platform == "darwin" else 108
OS_MAX_PATH_LEN = OS_PATH_LEN - 1

# How long a DERIVED path may be before the short /tmp name is used
# instead. Under OS_MAX_PATH_LEN and the same on every platform,
# because both ends derive it independently and have to agree.
MAX_DERIVED_PATH_LEN = 100


class BrokerPathTooLong(ValueError):
    """`<SERVICE>_BROKER_SOCKET` names a path no `sockaddr_un` holds."""


def _too_long(service: str, path: str) -> BrokerPathTooLong:
    return BrokerPathTooLong(
        f"socket path is {len(path)} bytes; the OS allows {OS_MAX_PATH_LEN}"
        f" -- set {service.upper()}_BROKER_SOCKET shorter or unset it"
        " for the default")


def broker_socket(service: str) -> str:
    """The socket path for a service, or "" when the broker is off.

    Raises BrokerPathTooLong when an explicit override names a path a
    `sockaddr_un` cannot hold -- a connect to it fails as a bare OSError
    that reads exactly like "no broker running", and the reader then
    goes looking for a process instead of at their own environment."""
    if os.environ.get("MNML_BROKER", "1").lower() in ("0", "off", "false", "no"):
        return ""
    named = os.environ.get(f"{service.upper()}_BROKER_SOCKET")
    if named:
        if len(named) > OS_MAX_PATH_LEN:
            raise _too_long(service, named)
        return named
    root = os.environ.get("TATTLE_ARTIFACTS_ROOT") or os.path.expanduser(
        "~/.tattle-claude-artifacts")
    path = os.path.join(root, f"{service}-broker.sock")
    # sun_path is 104 bytes on macOS and 108 on Linux, so a deep root
    # cannot hold a socket. Both sides fall back to the same short name,
    # derived from the service and the long path (the Zig side's
    # `broker.fallbackPath`: SHA-256 of the path, first six bytes in hex)
    # -- drop this and the two ends silently stop meeting on any long
    # path; hash the service alone and every deep bucket on the machine
    # shares one broker.
    if len(path) <= MAX_DERIVED_PATH_LEN:
        return path
    digest = hashlib.sha256(path.encode()).hexdigest()[:12]
    return f"/tmp/mnml-broker-{service}-{digest}.sock"


_warned: set = set()


def _warn_once(service: str, exc: BrokerPathTooLong) -> None:
    """One line on stderr per service, then never again. A sweep that
    makes a thousand calls must say this once, not a thousand times --
    and must not stop: the file bucket is still there."""
    if service in _warned:
        return
    _warned.add(service)
    print(f"{service}: {exc} (falling back to the file bucket)",
          file=sys.stderr)


def _socket_or_warn(service: str) -> str:
    try:
        return broker_socket(service)
    except BrokerPathTooLong as exc:
        _warn_once(service, exc)
        return ""


def try_broker(service: str, cls: str = "batch", reason: str = "batch",
               timeout: float = 120.0):
    """Ask the broker. True: a token was granted. False: the broker
    answered and refused (its timeout -- the same fail-open the file
    bucket gives, so send anyway). None: there is no broker to ask, and
    the caller should draw from the file bucket instead.

    The three answers matter: a False must not be followed by a file
    draw, or a queued script waits its timeout twice and then spends a
    token the broker already counted."""
    path = _socket_or_warn(service)
    if not path or not hasattr(socket, "AF_UNIX"):
        return None
    req = {"v": 1, "op": "acquire", "service": service, "class": cls,
           "client": f"{os.path.basename(__file__)}:{os.getpid()}",
           "reason": reason, "timeout_ms": int(timeout * 1000)}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout + 5.0)
            s.connect(path)
            s.sendall((json.dumps(req) + "\n").encode())
            reply = json.loads(s.makefile("r").readline() or "{}")
    except (OSError, ValueError):
        return None                                   # no broker: use the file
    if reply.get("ok"):
        return True
    return None if reply.get("why") in ("bad_request", "wrong_service") else False


def acquire_via_broker(service: str, cls: str = "batch", reason: str = "batch",
                       timeout: float = 120.0) -> bool:
    """True if the broker granted a token. False means fall back."""
    return try_broker(service, cls, reason, timeout) is True


def broker_status(service: str) -> dict:
    """The broker's own numbers, or {} when there is none."""
    path = _socket_or_warn(service)
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
    svc = sys.argv[1] if len(sys.argv) > 1 else "bitbucket"
    # The message, not a traceback: a path-length mistake is the user's
    # own setting and the stack it happened on tells them nothing.
    try:
        where = broker_socket(svc)
    except BrokerPathTooLong as exc:
        sys.exit(f"{svc}: {exc}")
    st = broker_status(svc)
    if not st:
        print(f"{svc}: no broker at {where or '(off)'}")
    else:
        q = st.get("queue", {})
        print(f"{svc}: queue {sum(q.values())} · {st.get('tokens', 0):.1f} of "
              f"{st.get('capacity', 0):.0f} tokens · {st.get('served', 0)} served")

"""Is the harness older than its sources? `tools/tour.sh` and
`tools/look.sh` ask before they launch anything.

The driver: `mnml-drive version` prints `source <hash>`, the hash of the
sources it was built from (build.zig `driveSourceHash`); this module
hashes the checkout the same way. A driver that disagrees — or one too
old to know the verb — is rebuilt with `zig build -Ddrive`, or, under
`MNML_DRIVE_NO_REBUILD=1`, refused with a one-line reason. The run that
motivated it: a driver built the day before the driver changed, whose
launch never wrote `allow_input`, so every state failed with "the
channel refused input".

The app: when no `--exe` is given, a `zig-out/bin/mnml-zig` older than
the newest file under `src/` earns a warning — not a refusal: shooting
an older build on purpose is a thing people do.

    python3 tools/tour/stamp.py drive     exit 0 fresh (or rebuilt), 64 refused
    python3 tools/tour/stamp.py app       prints the warning, if any; exit 0
"""

import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))


def drive_sources(repo=REPO):
    """The files build.zig hashes, repo-relative, in path order."""
    rels = ["src/core/key.zig"]
    d = os.path.join(repo, "tools", "drive")
    for name in os.listdir(d):
        if name.endswith(".zig") and os.path.isfile(os.path.join(d, name)):
            rels.append("tools/drive/" + name)
    return sorted(rels)


def source_hash(repo=REPO):
    """build.zig `driveSourceHash`: SHA-256 over `path NUL contents NUL`
    per file, the first sixteen hex digits."""
    h = hashlib.sha256()
    for rel in drive_sources(repo):
        with open(os.path.join(repo, rel), "rb") as f:
            data = f.read()
        h.update(rel.encode() + b"\0" + data + b"\0")
    return h.hexdigest()[:16]


def built_hash(drive):
    """What the driver says it was built from, or None when it cannot say
    (a driver older than the `version` verb prints its usage and exits 2)."""
    try:
        r = subprocess.run([drive, "version"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    out = r.stdout.strip()
    if r.returncode != 0 or not out.startswith("source "):
        return None
    return out.split()[1]


def check_drive(who, repo=REPO):
    """0 when the driver matches its sources (rebuilding it if needed),
    64 with a one-line reason on stderr otherwise."""
    drive = os.path.join(repo, "zig-out", "bin", "mnml-drive")
    want = source_hash(repo)
    got = built_hash(drive) if os.access(drive, os.X_OK) else None
    if got == want:
        return 0
    was = f"built from {got}" if got else "too old to report its sources"
    if os.environ.get("MNML_DRIVE_NO_REBUILD") == "1":
        print(f"{who}: zig-out/bin/mnml-drive is stale ({was}; tools/drive is {want}) — rebuild: zig build -Ddrive",
              file=sys.stderr)
        return 64
    log = os.path.join(repo, ".verify", "drive-rebuild.log")
    os.makedirs(os.path.dirname(log), exist_ok=True)
    print(f"{who}: zig-out/bin/mnml-drive is stale ({was}; tools/drive is {want}); rebuilding: zig build -Ddrive",
          file=sys.stderr, flush=True)
    with open(log, "w", encoding="utf-8") as f:
        # $MNML_ZIG, as run.sh reads it: a test points it at a fake.
        zig = os.environ.get("MNML_ZIG") or "zig"
        try:
            r = subprocess.run([zig, "build", "-Ddrive"], cwd=repo, stdout=f, stderr=subprocess.STDOUT)
        except OSError as e:
            print(f"{who}: could not run {zig}: {e}", file=sys.stderr)
            return 64
    if r.returncode != 0:
        print(f"{who}: zig build -Ddrive failed (exit {r.returncode}); see {log}", file=sys.stderr)
        return 64
    got = built_hash(drive)
    if got != want:
        print(f"{who}: rebuilt mnml-drive still reports {got}, not {want} — build.zig and tools/tour/stamp.py hash differently",
              file=sys.stderr)
        return 64
    return 0


def newest_under(root):
    best, best_path = 0.0, None
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            p = os.path.join(dirpath, name)
            try:
                m = os.stat(p).st_mtime
            except OSError:
                continue
            if m > best:
                best, best_path = m, p
    return best, best_path


def app_warning(repo=REPO):
    """The warning for a default app binary older than `src/`, or None."""
    exe = os.path.join(repo, "zig-out", "bin", "mnml-zig")
    try:
        built = os.stat(exe).st_mtime
    except OSError:
        return None  # the launch reports a missing binary itself
    newest, path = newest_under(os.path.join(repo, "src"))
    if path and newest > built:
        return (f"warning: zig-out/bin/mnml-zig is older than {os.path.relpath(path, repo)} "
                f"— the shots are of an older build (`zig build` first, or pass --exe)")
    return None


def warn_app(who, repo=REPO):
    w = app_warning(repo)
    if w:
        print(f"{who}: {w}", file=sys.stderr, flush=True)
    return w


def main(argv):
    who = os.environ.get("MNML_STAMP_WHO", "stamp")
    if argv[:1] == ["drive"]:
        return check_drive(who)
    if argv[:1] == ["app"]:
        warn_app(who)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

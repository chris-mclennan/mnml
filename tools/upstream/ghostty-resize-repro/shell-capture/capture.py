# Records the exact bytes a real shell writes when its terminal is resized
# at an idle prompt. Used to check the repro's shell model; not part of it.
import os, pty, sys, time, fcntl, termios, struct, select

def setsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def drain(fd, t=0.6):
    out = b""; end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: out += os.read(fd, 65536)
            except OSError: break
    return out

def run(argv, env):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, env)
    setsize(fd, 12, 40)
    print("startup:", drain(fd, 1.5))
    for cols in (20, 40, 20):
        setsize(fd, 12, cols)
        os.kill(pid, 28)  # SIGWINCH, in case the shell is not the fg group leader
        print(f"after resize to {cols} cols:", drain(fd))
    os.write(fd, b"exit\r"); drain(fd, 0.5)
    try: os.kill(pid, 9)
    except ProcessLookupError: pass
    os.waitpid(pid, 0)

which = sys.argv[1]
base = {"PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": os.getcwd()}
if which == "zsh1":
    run(["/bin/zsh", "-f", "-i"], dict(base, PS1="PROMPT-user@host:~/some/path $ "))
elif which == "zsh2":
    run(["/bin/zsh", "-f", "-i"], dict(base, PS1="PROMPT-user@host:~/some/path\n> "))
elif which == "bash1":
    run(["/bin/bash", "--norc", "--noprofile", "-i"], dict(base, PS1="PROMPT-user@host:~/some/path $ "))

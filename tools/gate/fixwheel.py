# Resolve tests/e2e/settings_wheel.test: the notch count is main's count plus this branch's own delta (cwd = a worktree mid-rebase).
import subprocess, re, sys
p='tests/e2e/settings_wheel.test'
def stage(n):
    return subprocess.run(['git','show',f':{n}:{p}'],capture_output=True,text=True).stdout
base, ours, theirs = stage(1), stage(2), stage(3)
LINE='scroll 60 20 down'
nb, no, nt = base.count(LINE+'\n'), ours.count(LINE+'\n'), theirs.count(LINE+'\n')
delta = nt - nb
lines = ours.split('\n')
# the notch block ends right before the Editor-header expectation
idx = next(i for i,l in enumerate(lines) if l.startswith('expect screen contains "── Editor ──"'))
insert = [LINE]*delta if delta > 0 else []
note = f'# (+{delta} notches: this branch\'s own Settings rows, summed onto main\'s count at merge)' if delta else None
new = lines[:idx] + insert + ([note] if note else []) + lines[idx:]
open(p,'w').write('\n'.join(new))
print(f'wheel: base={nb} main={no} branch={nt} -> merged={no+delta}')

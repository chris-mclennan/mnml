import sys
for p in sys.argv[1:]:
    L=open(p).read().split('\n')
    out=[x for x in L if not (x.startswith('<<<<<<< ') or x=='=======' or x.startswith('>>>>>>> '))]
    open(p,'w').write('\n'.join(out))

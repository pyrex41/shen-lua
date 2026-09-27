"""Bounded, sequential fresh-process experiments. No profiling during timings."""
import hashlib, itertools, json, os, statistics, subprocess
from pathlib import Path
out=Path('bench/results')
def run(args, env=None):
    p=subprocess.run(args, env=env, capture_output=True, text=True, timeout=90)
    if p.returncode:
        raise RuntimeError(p.stdout[-2000:]+p.stderr[-2000:])
    lines=[s for s in p.stdout.splitlines() if s.startswith('RESULT ')]
    assert len(lines)==1, p.stdout[-2000:]
    return dict(s.split('=',1) for s in lines[0].split()[1:])
# Check the unchanged controls in fresh compilers, including generated names.
control='''local C,R=require('compiler'),require('runtime'); require('prims'); C.CLOSURES=%s
for _,s in ipairs{'(defun ctrl (N) (let F (lambda X (+ N X)) (do (set escaped F) (F 3))))', '(defun ctrl (N) (let F (lambda X (+ N X)) (thaw (freeze (F 3)))))'} do print(C.cdefun(R.read_all(s)[1])) end'''
sources=[subprocess.check_output(['luajit','-e',control % m],timeout=15) for m in ['false','true']]
assert sources[0]==sources[1], 'unchanged controls differ in generated source'
print('controls identical source sha256='+hashlib.sha256(sources[0]).hexdigest(),flush=True)
app=[]; objects=[]
for round in range(6):
    for mode in (['off','on'] if round%2==0 else ['on','off']):
        env=dict(os.environ,SHEN_MAP_CLOSURES=mode,SHEN_CLOSURES='off',SHEN_FASL='off',SHEN_KERNEL_CACHE='off')
        row=run(['luajit','bench/closure_application.lua'],env)
        row.update(round=round,mode=mode); app.append(row)
        print('app', row,flush=True)
    order=list(itertools.permutations(['ordinary','optimized','manual']))[round]
    for mode in order:
        env=dict(os.environ,SHEN_MAP_CLOSURES='off',SHEN_CLOSURES='off')
        row=run(['luajit','bench/closure_objects.lua',mode],env)
        row.update(round=round); objects.append(row)
        print('objects',row,flush=True)
    (out/'closure-experiments.json').write_text(json.dumps(dict(application=app,objects=objects),indent=2))
assert len({r['semantic'] for r in app})==1, 'same inferred type in every mode'
for group,rows,metric in [('application',app,'load'),('typecheck',app,'typecheck'),('objects',objects,'seconds')]:
    for mode in sorted({r['mode'] for r in rows}):
        vals=[float(r[metric]) for r in rows if r['mode']==mode]
        print(group,mode,'median=',statistics.median(vals),'range=',min(vals),max(vals),flush=True)

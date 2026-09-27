"""History controls: separate processes, balanced order, bounded queries."""
import os,json,statistics,subprocess
from pathlib import Path
rows=[]
for round in range(3):
    for history in ['keep','flush','off']:
        for mode in (['off','on'] if round%2==0 else ['on','off']):
            env=dict(os.environ,SHEN_MAP_CLOSURES=mode,SHEN_CLOSURES='off',SHEN_FASL='off',SHEN_KERNEL_CACHE='off')
            env['SHEN_DATATYPE_LOOP']='off'
            env.pop('SHEN_TC_MAXRECORD',None)
            env['SHEN_DATATYPE_DISPATCH']='off'
            env.pop('SHEN_TC_TRACE',None)
            env.pop('SHEN_TC_PROFILE',None)
            p=subprocess.run(['luajit','bench/typecheck_specialization.lua',history,'12'],env=env,text=True,capture_output=True,timeout=90)
            if p.returncode: raise RuntimeError(p.stderr+p.stdout[-2000:])
            samples=[dict(x.split('=',1) for x in line.split()[1:]) for line in p.stdout.splitlines() if line.startswith('QUERY ')]
            assert len(samples)==12
            row=dict(round=round,history=history,mode=mode,samples=samples)
            row['median']=statistics.median(float(s['seconds']) for s in samples[6:])
            rows.append(row)
            print(round,history,mode,row['median'],flush=True)
            Path('bench/results/typecheck-audit.json').write_text('[\n'+',\n'.join(json.dumps(r,separators=(',',':')) for r in rows)+'\n]\n')
for history in ['keep','flush','off']:
    for mode in ['off','on']:
        v=[r['median'] for r in rows if r['history']==history and r['mode']==mode]
        print(history,mode,statistics.median(v),v)

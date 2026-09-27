"""Bound recorder growth; compare independent processes in rotated order."""
import os,json,statistics,subprocess
from pathlib import Path
rows=[]
for round in range(4):
    modes=['default','8000','16000']
    modes=modes[round%3:]+modes[:round%3]
    for mode in modes:
        env=dict(os.environ,SHEN_MAP_CLOSURES='off',SHEN_CLOSURES='off',SHEN_FASL='off',SHEN_KERNEL_CACHE='off',SHEN_DATATYPE_DISPATCH='off')
        env.pop('SHEN_TC_MAXRECORD',None)
        if mode!='default':env['SHEN_TC_MAXRECORD']=mode
        env['SHEN_DATATYPE_LOOP']='off'
        env.pop('SHEN_TC_TRACE',None)
        env.pop('SHEN_TC_PROFILE',None)
        p=subprocess.run(['luajit','bench/typecheck_specialization.lua','flush','12'],env=env,text=True,capture_output=True,timeout=90)
        if p.returncode:raise RuntimeError(p.stderr+p.stdout[-2000:])
        samples=[dict(x.split('=',1) for x in l.split()[1:]) for l in p.stdout.splitlines() if l.startswith('QUERY ')]
        row=dict(round=round,mode=mode,samples=samples)
        row['median']=statistics.median(float(s['seconds']) for s in samples[6:]);rows.append(row)
        print(round,mode,row['median'],flush=True)
        Path('bench/results/typecheck-record-ab.json').write_text('[\n'+',\n'.join(json.dumps(r,separators=(',',':')) for r in rows)+'\n]\n')
for mode in ['default','8000','16000']:
    v=[r['median'] for r in rows if r['mode']==mode]
    print(mode,statistics.median(v),v)

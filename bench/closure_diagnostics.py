"""Allocation counters and JIT diagnostics. These runs are not timing evidence."""
import os, subprocess
from pathlib import Path
out=Path('bench/results')
lines=[]
for mode in ['off','on']:
    env=dict(os.environ,SHEN_CLOSURES='off',SHEN_CALLBACK_COUNTS='1',SHEN_MAP_CLOSURES=mode,SHEN_FASL='off',SHEN_KERNEL_CACHE='off')
    p=subprocess.run(['luajit','bench/closure_application.lua'],env=env,capture_output=True,text=True,timeout=90,check=True)
    lines.append('application '+mode+' '+p.stdout.strip())
for mode in ['ordinary','optimized','manual']:
    env=dict(os.environ,SHEN_CLOSURES='off',SHEN_CALLBACK_COUNTS='1',SHEN_TRACE_MARKERS='1',SHEN_MAP_CLOSURES='off')
    p=subprocess.run(['luajit','-jv','bench/closure_objects.lua',mode],env=env,capture_output=True,text=True,timeout=60,check=True)
    lines.append('objects '+mode+' '+p.stdout.strip())
    log=p.stderr
    assert len(log)<1000000, 'trace log exceeds budget'
    (out/('closure-traces-'+mode+'.txt')).write_text(log)
    measured=log.split('WORKLOAD_BEGIN\n')[1].split('WORKLOAD_END\n')[0]
    lines.append(mode+' workload_trace_abort_FNEW='+str(measured.count('NYI: bytecode FNEW'))+' workload_trace_lines='+str(len(measured.splitlines())))
(out/'closure-diagnostics.txt').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines))

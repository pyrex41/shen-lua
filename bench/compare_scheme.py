#!/usr/bin/env python3
"""Run the same complete typecheck corpus on LuaJIT and Shen/Scheme packages."""
import argparse, hashlib, json, os, platform, resource, statistics, subprocess, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--scheme', type=Path, required=True)
ap.add_argument('--bundle', type=Path, required=True)
ap.add_argument('--out', type=Path, required=True)
ap.add_argument('--pairs', type=int, default=5)
ap.add_argument('--repeats', type=int, default=11)
a = ap.parse_args()
a.scheme = a.scheme.resolve(); a.bundle = a.bundle.resolve(); a.out = a.out.resolve()
a.out.mkdir(exist_ok=False, parents=True)
assert a.pairs >= 1 and a.repeats >= 2

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def identity():
    files = [*ROOT.glob('*.lua'), *ROOT.glob('bench/*.lua'), *ROOT.glob('bench/*.py'),
             *ROOT.glob('klambda/*.kl'), ROOT/'bench/golden_typecheck.golden',
             ROOT/'bench/fixtures.sha256', a.bundle, a.scheme]
    files += list(a.scheme.parent.parent.glob('lib/shen-scheme/**/*.so'))
    files += list(a.scheme.parent.parent.glob('lib/shen-scheme/*.boot'))
    return {str(p):sha(p) for p in files}
initial = identity()
inputs = json.loads(subprocess.check_output(['python3','bench/verify_inputs.py'], cwd=ROOT))
assert inputs['kernel_commit'] == 'ec16a9fa4fc2e87e2aa336fb1ae30e8ac2266394'
corpus = json.loads(subprocess.check_output(['luajit','-e',
 'print(require("bench.typecheck_harness").json(require("bench.typecheck_corpus")))'], cwd=ROOT))
golden = dict(line.split('\t',1) for line in (ROOT/'bench/golden_typecheck.golden').read_text().splitlines())
(a.out/'identity-before.json').write_text(json.dumps(dict(files=initial,inputs=inputs,host=platform.platform(),
    lua=subprocess.check_output(['luajit','-v'],stderr=subprocess.STDOUT,text=True).strip(),
    scheme=subprocess.check_output([str(a.scheme),'--version'],text=True).strip(),
    source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
    load=os.getloadavg()),indent=2)+'\n')
(a.out/'source.diff').write_bytes(subprocess.check_output(['git','diff','HEAD'],cwd=ROOT))
# Read both expression and type in judgment context, exactly as the Lua API does.
header = r'''
(import (chezscheme) (shen-scheme runtime))
(define (clock) (let ([x (current-time 'time-process)])
 (+ (time-second x) (/ (time-nanosecond x) 1000000000.0))))
(printf "CROSS_PHASE\tbootstrap\t~a\n" (clock))
(printf "CROSS_RUNTIME\t~a\t~a\n" (scheme-version) (kl:version))
(kl:set '*hush* #t)
(define (ser x)
 (let ([vars (make-eq-hashtable)] [n 0])
  (define (walk x)
   (cond [(null? x) "()"] [(eq? x #t) "true"] [(eq? x #f) "false"]
    [(pair? x) (string-append "(" (walk (car x)) " . " (walk (cdr x)) ")")]
    [(and (vector? x) (> (vector-length x) 0) (eq? (vector-ref x 0) 'shen.pvar))
     (or (hashtable-ref vars x #f)
      (begin (set! n (+ n 1))
       (let ([s (string-append "?" (number->string n))]) (hashtable-set! vars x s) s)))]
    [(symbol? x) (symbol->string x)]
    [(string? x) (format "~s" x)] [(number? x) (number->string x)]
    [else (error 'serialize "unexpected complete result" x)]))
  (walk x)))
(define (fixture path)
 (kl:set 'shen.*tc* #t) (kl:set 'shen.*infs* 0)
 (let ([start (clock)]) (kl:load path)
  (printf "CROSS_LOAD\t~a\t~a\n" path (- (clock) start))))
(define (query name source expected repeats)
 (let* ([start (clock)] [forms (kl:read-from-string source)] [read (- (clock) start)]
        [expr (car forms)] [ty (caddr forms)])
  (unless (= (length forms) 3) (error 'corpus "bad judgment" forms))
  (printf "CROSS_READ\t~a\t~a\n" name read)
  (do ([i 1 (+ i 1)]) ((> i repeats))
   (kl:set 'shen.*infs* 0)
   (let* ([start (clock)] [result (kl:shen.typecheck expr ty)]
          [cpu (- (clock) start)] [infs (kl:value 'shen.*infs*)] [verdict (ser result)])
    (printf "CROSS_QUERY\t~a\t~a\t~a\t~a\t~a\n" name i cpu infs verdict)
    (unless (string=? verdict expected) (error 'corpus "complete verdict mismatch" name verdict expected))))))
'''
lines = [header]
for stage in corpus:
    if stage.get('fixture'): lines.append('(fixture '+json.dumps(stage['fixture'])+')')
    for case in stage['cases']:
        lines.append('(query '+ ' '.join(json.dumps(v) for v in [case[0],case[1]+' : '+case[2],golden[case[0]]])+f' {a.repeats})')
lines.append('(display "CROSS_PASS\\n")')
driver=a.out/'driver.ss'; driver.write_text('\n'.join(lines)+'\n')
rows=[]
for pair in range(a.pairs):
    for engine in (['lua','scheme'] if pair%2==0 else ['scheme','lua']):
        env=os.environ.copy()
        for key in list(env):
            if key.startswith('SHEN_'): del env[key]
        env.update(SHEN_KERNEL_CACHE='off',SHEN_FASL='off',SHEN_BENCH_REPEATS=str(a.repeats))
        if engine=='lua':
            env.update(SHEN_TYPECHECK_NATIVE='require', SHEN_BENCH_BUNDLE=str(a.bundle))
            cmd=['luajit','bench/typecheck_time.lua']
        else:
            # scm. is the port's documented escape to Scheme; no runtime changes.
            source='(eval-kl [scm. "(load c#34;'+str(driver)+'c#34;)"])'
            cmd=[str(a.scheme),'eval','-q','-e',source]
        label=f'{pair:02d}-{engine}'
        before=resource.getrusage(resource.RUSAGE_CHILDREN); started=time.monotonic()
        proc=subprocess.run(cmd,cwd=ROOT,env=env,capture_output=True,timeout=240)
        wall=time.monotonic()-started; after=resource.getrusage(resource.RUSAGE_CHILDREN)
        (a.out/(label+'.stdout')).write_bytes(proc.stdout); (a.out/(label+'.stderr')).write_bytes(proc.stderr)
        row=dict(pair=pair,engine=engine,command=cmd,settings={k:v for k,v in env.items() if k.startswith('SHEN_')},
            exit=proc.returncode,process_wall=wall,process_cpu=after.ru_utime+after.ru_stime-before.ru_utime-before.ru_stime,
            load=os.getloadavg())
        (a.out/(label+'.json')).write_text(json.dumps(row,indent=2)+'\n')
        assert proc.returncode==0, f'{label} failed; see complete stdout/stderr'
        if engine=='lua':
            report=json.loads(next(s[16:] for s in proc.stdout.decode().splitlines() if s.startswith('SHEN_BENCH_JSON ')))
            row['report']=report
            assert all(q['route']['engine']=='native' and q['ok'] for q in report['queries'])
            bootstrap=sum(report['phases'][k] for k in ['require','kernel_load','initialise'])
        else:
            report=dict(phases={},loads=[],queries=[])
            for line in proc.stdout.decode().splitlines():
                f=line.split('\t')
                if f[0]=='CROSS_PHASE': report['phases'][f[1]]=float(f[2])
                elif f[0]=='CROSS_LOAD': report['loads'].append(dict(path=f[1],cpu=float(f[2])))
                elif f[0]=='CROSS_READ': report['phases']['query_read']=report['phases'].get('query_read',0)+float(f[2])
                elif f[0]=='CROSS_QUERY': report['queries'].append(dict(name=f[1],request=int(f[2]),cpu=float(f[3]),inferences=int(f[4]),result=f[5]))
            row['report']=report; bootstrap=report['phases']['bootstrap']
        assert len(report['queries'])==20*a.repeats
        assert all(q['result']==golden[q['name']] for q in report['queries'])
        row['metrics']=dict(bootstrap=bootstrap,fixture_load=sum(x['cpu'] for x in report['loads']),
            driver_compile=report['phases'].get('driver_compile',0),query_read=report['phases']['query_read'],
            first=sum(q['cpu'] for q in report['queries'] if q['request']==1),
            persistent=sum(q['cpu'] for q in report['queries'] if q['request']>1),
            process_cpu=row['process_cpu'],process_wall=wall)
        (a.out/(label+'.json')).write_text(json.dumps(row,indent=2)+'\n'); rows.append(row)
        print(label,json.dumps(row['metrics']),flush=True)
final=identity(); (a.out/'identity-after.json').write_text(json.dumps(final,indent=2)+'\n');assert initial==final
summary=dict(pairs=a.pairs,repeats=a.repeats,metrics={},cases={})
for metric in rows[0]['metrics']:
    lua=[r['metrics'][metric] for r in rows if r['engine']=='lua']
    scm=[r['metrics'][metric] for r in rows if r['engine']=='scheme']
    ratios=[lua[i]/scm[i] for i in range(a.pairs)] if all(scm) else []
    summary['metrics'][metric]=dict(lua_median=statistics.median(lua),scheme_median=statistics.median(scm),
        lua_over_scheme_ratios=ratios,median_ratio=statistics.median(ratios) if ratios else None)
for name in golden:
    samples={}
    for engine in ['lua','scheme']:
        samples[engine]=[sum(q['cpu'] for q in r['report']['queries'] if q['name']==name and q['request']>1)/(a.repeats-1)
                         for r in rows if r['engine']==engine]
    ratios=[l/s for l,s in zip(samples['lua'],samples['scheme'])]
    summary['cases'][name]=dict(samples=samples,lua_median=statistics.median(samples['lua']),scheme_median=statistics.median(samples['scheme']),
        median_ratio=statistics.median(ratios),ratios=ratios)
(a.out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('PASS: complete matched verdicts; source identities unchanged',flush=True)

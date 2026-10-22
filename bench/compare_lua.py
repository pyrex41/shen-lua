#!/usr/bin/env python3
"""Compare complete native typecheck requests in two isolated Lua checkouts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--baseline', type=Path, required=True)
ap.add_argument('--candidate', type=Path, default=Path(__file__).resolve().parents[1])
ap.add_argument('--baseline-bundle', type=Path)
ap.add_argument('--candidate-bundle', type=Path)
ap.add_argument('--out', type=Path, required=True)
ap.add_argument('--pairs', type=int, default=7)
ap.add_argument('--repeats', type=int, default=51)
ap.add_argument('--mode', choices=['time', 'alloc'], default='time')
a = ap.parse_args()
assert a.pairs > 0 and 2 <= a.repeats <= 100
assert bool(a.baseline_bundle) == bool(a.candidate_bundle), 'supply both bundles'
roots = {'baseline': a.baseline.resolve(), 'candidate': a.candidate.resolve()}
bundles = {'baseline': a.baseline_bundle, 'candidate': a.candidate_bundle}
bundles = {k: v.resolve() if v else None for k, v in bundles.items()}
a.out = a.out.resolve()
a.out.mkdir(parents=True, exist_ok=False)


def identity():
    result = {}
    for mode, root in roots.items():
        files = [*root.glob('*.lua'), *root.glob('klambda/*.kl'),
                 *root.glob('bench/*.lua'), *root.glob('bench/*.py')]
        if bundles[mode]:
            files.append(bundles[mode])
        inputs = json.loads(subprocess.check_output(
            ['python3', 'bench/verify_inputs.py'], cwd=root))
        result[mode] = dict(
            commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
            files={str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
            inputs=inputs,
            diff=subprocess.check_output(['git', 'diff', 'HEAD'], cwd=root, text=True))
    return result


initial = identity()
(a.out / 'identity-before.json').write_text(json.dumps(initial, indent=2) + '\n')
rows, oracle = [], None
for pair in range(a.pairs):
    order = ['baseline', 'candidate'] if pair % 2 == 0 else ['candidate', 'baseline']
    for mode in order:
        env = {k: v for k, v in os.environ.items() if not k.startswith('SHEN_')}
        env.update(SHEN_KERNEL_CACHE='off', SHEN_FASL='off',
                   SHEN_TYPECHECK_NATIVE='require', SHEN_BENCH_REPEATS=str(a.repeats))
        if bundles[mode]:
            env['SHEN_BENCH_BUNDLE'] = str(bundles[mode])
        cmd = ['luajit', 'bench/typecheck_' + a.mode + '.lua']
        label = f'{pair:02d}-{mode}'
        start = time.monotonic()
        try:
            proc = subprocess.run(cmd, cwd=roots[mode], env=env,
                                  capture_output=True, timeout=180)
        except subprocess.TimeoutExpired as exc:
            (a.out / (label + '.stdout')).write_bytes(exc.stdout or b'')
            (a.out / (label + '.stderr')).write_bytes(exc.stderr or b'')
            (a.out / (label + '.json')).write_text(json.dumps(dict(
                command=cmd, status='TIMEOUT', timeout=180, settings={
                    k: v for k, v in env.items() if k.startswith('SHEN_')}), indent=2) + '\n')
            raise
        (a.out / (label + '.stdout')).write_bytes(proc.stdout)
        (a.out / (label + '.stderr')).write_bytes(proc.stderr)
        row = dict(pair=pair, mode=mode, command=cmd, exit=proc.returncode,
                   wall=time.monotonic() - start, load=os.getloadavg(),
                   settings={k: v for k, v in env.items() if k.startswith('SHEN_')})
        path = a.out / (label + '.json')
        path.write_text(json.dumps(row, indent=2) + '\n')
        assert proc.returncode == 0, label + ': see complete stdout/stderr'
        report = json.loads(next(line[16:] for line in proc.stdout.decode().splitlines()
                                 if line.startswith('SHEN_BENCH_JSON ')))
        assert len(report['queries']) == 20 * a.repeats
        assert all(q['ok'] and q['route']['engine'] == 'native' for q in report['queries'])
        actual = [(q['name'], q['request'], q['result'], q['inferences'])
                  for q in report['queries']]
        if oracle is None:
            oracle = actual
        assert actual == oracle, label + ': complete verdict/inference mismatch'
        row['report'] = report
        row['metrics'] = {}
        for field in ['cpu'] + (['allocated_bytes'] if a.mode == 'alloc' else []):
            for group in ['first', 'persistent', 'smaller', 'heavy']:
                queries = [q for q in report['queries'] if
                           (q['request'] == 1 if group == 'first' else q['request'] > 1)
                           and (group != 'smaller' or q['name'] != 'interpreter-y-inferred')
                           and (group != 'heavy' or q['name'] == 'interpreter-y-inferred')]
                row['metrics'][group + '_' + field] = sum(q[field] for q in queries)
        row['metrics']['fixture_load_cpu'] = sum(x['cpu'] for x in report['loads'])
        path.write_text(json.dumps(row, indent=2) + '\n')
        rows.append(row)
        print(label, row['metrics'], flush=True)
final = identity()
(a.out / 'identity-after.json').write_text(json.dumps(final, indent=2) + '\n')
assert initial == final, 'input sources or working diff changed during cohort'
summary = {}
for key in rows[0]['metrics']:
    values = {mode: [r['metrics'][key] for r in rows if r['mode'] == mode] for mode in roots}
    ratios = [b / c for b, c in zip(values['baseline'], values['candidate'])]
    summary[key] = dict(samples=values, baseline_over_candidate=ratios,
                        median_ratio=statistics.median(ratios))
(a.out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print('PASS: complete native verdicts/inferences and unchanged sources', flush=True)

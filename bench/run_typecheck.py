#!/usr/bin/env python3
"""Fresh-process paired typechecker measurements. Python standard library only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time
from verify_inputs import verify

ROOT = Path(__file__).resolve().parents[1]
SWITCHES = ('SHEN_PROLOG_ENGINE', 'SHEN_TYPECHECK_NATIVE', 'SHEN_JIT', 'SHEN_JIT_OPT',
            'SHEN_GC', 'SHEN_TRMC', 'SHEN_NO_STDLIB', 'SHEN_KL_DIR',
            'SHEN_KERNEL_CACHE', 'SHEN_FASL', 'SHEN_FASL_DIR', 'SHEN_BENCH_BUNDLE')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identity():
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()
    kernel = Path(os.environ.get('SHEN_KL_DIR', ROOT / 'klambda')).resolve()
    inputs = [*ROOT.glob('*.lua'), *ROOT.glob('bench/*.lua'),
              ROOT / 'bench/run_typecheck.py', ROOT / 'bench/verify_inputs.py', ROOT / 'bench/kernel-431.sha256.json', ROOT / 'test/fixtures/kernel-ec16a9f/sha256.json', ROOT / 'bench/fixtures.sha256',
              ROOT / 'bench/golden_typecheck.golden', *kernel.glob('*.kl')]
    for line in (ROOT / 'bench/fixtures.sha256').read_text().splitlines():
        expected, name = line.split('  ', 1)
        path = ROOT / name
        if sha(path) != expected:
            raise RuntimeError(f'fixture SHA-256 mismatch: {name}')
        inputs.append(path)
    if os.environ.get('SHEN_BENCH_BUNDLE'):
        inputs.append(Path(os.environ['SHEN_BENCH_BUNDLE']).resolve())
    return dict(source_sha=git('rev-parse', 'HEAD'), diff=git('diff', '--binary', 'HEAD'),
                status=git('status', '--porcelain'), kernel_dir=str(kernel),
                kernel_provenance=(ROOT / 'klambda/PROVENANCE.md').read_text(),
                hashes={str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p): sha(p)
                        for p in sorted(set(inputs))},
                host=dict(platform=platform.platform(), machine=platform.machine(),
                          cpu_count=os.cpu_count(), load=os.getloadavg()))


def verdicts(report):
    return [(q['name'], q['request'], q['expr'], q['type'], q['ok'], q['result'])
            for q in report['queries']]


def metrics(report):
    result = {f'phase/{k}': v for k, v in report['phases'].items()}
    result.update({f'load/{v["path"]}': v['cpu'] for v in report['loads']})
    for phase in ('first', 'persistent'):
        times = [q['cpu'] for q in report['queries'] if q['phase'] == phase]
        result[phase] = sum(times)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--lua', default='luajit')
    ap.add_argument('--pairs', type=int, default=5)
    ap.add_argument('--repeats', type=int, default=3)
    ap.add_argument('--timeout', type=float, default=180)
    ap.add_argument('--states', nargs='+', choices=['off', 'cold', 'hit'], default=['off', 'cold', 'hit'])
    ap.add_argument('--mode', choices=['time', 'alloc', 'diagnostic'], default='time')
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    if not 1 <= args.pairs <= 100 or not 2 <= args.repeats <= 100 or not 0 < args.timeout <= 3600:
        ap.error('bounded pairs 1..100, repeats 2..100, timeout (0,3600] required')
    args.out.mkdir(parents=True, exist_ok=False)
    verify()
    before = identity()
    (args.out / 'identity-before.json').write_text(json.dumps(before, indent=2) + '\n')
    oracle = dict(line.split('\t', 1) for line in (ROOT / 'bench/golden_typecheck.golden').read_text().splitlines())
    samples = []
    inference_reference = {}
    # A fresh private cache for each process unit, warmed only by its own
    # unmeasured matching prime. No shared/default cache is read or removed.
    with tempfile.TemporaryDirectory(prefix='shen-typecheck-') as tmp:
        for state in args.states:
            for pair in range(args.pairs):
                paired = {}
                for engine in (('legacy', 'native') if pair % 2 == 0 else ('native', 'legacy')):
                    name = f'{state}-{pair:03d}-{engine}'
                    private = Path(tmp) / name
                    private.mkdir()
                    env = os.environ.copy()
                    env.update(SHEN_KERNEL_CACHE='off' if state == 'off' else str(private / 'kernel'),
                               SHEN_FASL='off' if state == 'off' else 'on',
                               SHEN_FASL_DIR=str(private / 'fasl'),
                               SHEN_PROLOG_ENGINE=engine,
                               SHEN_TYPECHECK_NATIVE='require' if engine == 'native' else 'off',
                               SHEN_BENCH_REPEATS=str(args.repeats))
                    script = {'time': 'typecheck_time.lua', 'alloc': 'typecheck_alloc.lua',
                              'diagnostic': 'typecheck_diagnostic.lua'}[args.mode]
                    cmd = [args.lua, f'bench/{script}']
                    def run(label, prime=False):
                        start = time.monotonic()
                        try:
                            proc = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, timeout=args.timeout)
                        except subprocess.TimeoutExpired as e:
                            (args.out / f'{label}.stdout').write_bytes(e.stdout or b'')
                            (args.out / f'{label}.stderr').write_bytes(e.stderr or b'')
                            (args.out / f'{label}.json').write_text(json.dumps(dict(command=cmd, state=state, engine=engine, pair=pair, prime=prime, timeout=args.timeout, status='TIMEOUT', settings={k: env.get(k) for k in sorted(env) if k.startswith('SHEN_')}), indent=2)+'\n')
                            raise RuntimeError(f'{label}: timed out; outputs retained') from e
                        (args.out / f'{label}.stdout').write_bytes(proc.stdout)
                        (args.out / f'{label}.stderr').write_bytes(proc.stderr)
                        receipt = dict(name=label, engine=engine, state=state, pair=pair, prime=prime,
                                       command=cmd, settings={k: env.get(k) for k in sorted(set(SWITCHES) | {k for k in env if k.startswith('SHEN_')})},
                                       wall=time.monotonic()-start, returncode=proc.returncode,
                                       load=os.getloadavg())
                        # Save failure receipts too; a failed process is never discarded.
                        (args.out / f'{label}.json').write_text(json.dumps(receipt, indent=2)+'\n')
                        if proc.returncode:
                            raise RuntimeError(f'{label}: exit {proc.returncode}; outputs retained')
                        lines = [s.removeprefix('SHEN_BENCH_JSON ') for s in proc.stdout.decode().splitlines()
                                 if s.startswith('SHEN_BENCH_JSON ')]
                        if len(lines) != 1:
                            raise RuntimeError(f'{label}: missing/duplicate complete report')
                        report = json.loads(lines[0])
                        receipt['report'] = report
                        (args.out / f'{label}.json').write_text(json.dumps(receipt, indent=2)+'\n')
                        expected_cache = 'compile-off' if state == 'off' else ('miss' if state == 'cold' or prime else 'hit')
                        if not env.get('SHEN_BENCH_BUNDLE') and report['kernel_cache'] != expected_cache:
                            raise RuntimeError(f'{label}: kernel cache {report["kernel_cache"]}, expected {expected_cache}')
                        expected_fasl = 'off' if state == 'off' else ('miss' if state == 'cold' or prime else 'hit')
                        if any(v['cache'] != expected_fasl for v in report['loads']):
                            raise RuntimeError(f'{label}: unexpected fixture cache routing: {report["loads"]}')
                        for load in report['loads']:
                            infs = load['inferences']
                            if not isinstance(infs, int) or infs < 0:
                                raise RuntimeError(f'{label}: invalid load inference counter {infs}')
                            transitions = load['dispatch_transitions']
                            if engine == 'native':
                                if any(r['engine'] not in ('preparing', 'native') for r in transitions):
                                    raise RuntimeError(f'{label}: source load left native dispatch')
                                # FASL hits replay declarations directly; they
                                # can incur inferences without dispatcher calls.
                                if infs and not transitions and load['cache'] != 'hit':
                                    raise RuntimeError(f'{label}: missing source-load routing evidence')
                            elif transitions:
                                raise RuntimeError(f'{label}: legacy source load used native dispatcher')
                        counts = {}
                        for q in report['queries']:
                            infs = q['inferences']
                            if not isinstance(infs, int) or infs <= 0:
                                raise RuntimeError(f'{label}: invalid inference counter {infs}')
                            if q['name'] in counts and counts[q['name']] != infs:
                                raise RuntimeError(f'{label}: persistent inference count changed')
                            counts[q['name']] = infs
                        if engine in inference_reference and inference_reference[engine] != counts:
                            raise RuntimeError(f'{label}: per-engine inference counts changed across processes/cache states')
                        inference_reference[engine] = counts
                        first = {q['name']: q['result'] for q in report['queries'] if q['request'] == 1}
                        if first != oracle:
                            raise RuntimeError(f'{label}: complete golden mismatch')
                        if any(not q['ok'] or q['route']['engine'] != engine for q in report['queries']):
                            raise RuntimeError(f'{label}: unexpected query route or error')
                        (args.out / f'{label}.json').write_text(json.dumps(receipt, indent=2)+'\n')
                        return receipt
                    if state == 'hit':
                        run(name + '-prime', prime=True)
                    sample = run(name)
                    paired[engine] = sample
                    samples.append(sample)
                    print(name, f'{sample["wall"]:.3f}s', flush=True)
                if verdicts(paired['native']['report']) != verdicts(paired['legacy']['report']):
                    raise RuntimeError(f'{state}/{pair}: native/legacy verdict difference')
    after = identity()
    (args.out / 'identity-after.json').write_text(json.dumps(after, indent=2)+'\n')
    if any(before[k] != after[k] for k in ('source_sha', 'diff', 'status', 'hashes')):
        raise RuntimeError('source/input identity changed during cohort')
    summaries = {}
    for state in args.states:
        rows = [s for s in samples if s['state'] == state]
        stats = {}
        for key in ['process_wall', *metrics(rows[0]['report'])]:
            def val(s):
                return s['wall'] if key == 'process_wall' else metrics(s['report'])[key]
            legacy = [val(next(s for s in rows if s['pair'] == p and s['engine'] == 'legacy')) for p in range(args.pairs)]
            native = [val(next(s for s in rows if s['pair'] == p and s['engine'] == 'native')) for p in range(args.pairs)]
            ratios = [a/b if b else None for a, b in zip(legacy, native)]
            valid = [r for r in ratios if r is not None]
            stats[key] = dict(legacy_median=statistics.median(legacy), native_median=statistics.median(native),
                              paired_legacy_over_native=ratios, median_ratio=statistics.median(valid) if valid else None,
                              ratio_range=[min(valid), max(valid)] if valid else None,
                              native_wins=sum(b < a for a, b in zip(legacy, native)))
        summaries[state] = stats
    (args.out / 'summary.json').write_text(json.dumps(dict(mode=args.mode, pairs=args.pairs,
        statistical_unit='fresh process; persistent requests aggregated within process',
        timing_qualified=args.mode == 'time', inference_counts=inference_reference, host_contention='uncontrolled; exploratory', states=summaries), indent=2)+'\n')


if __name__ == '__main__':
    main()

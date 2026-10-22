#!/usr/bin/env python3
"""Authenticate selected full kernel and benchmark fixtures before execution."""
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def verify():
    fixtures = {}
    for line in (ROOT / 'bench/fixtures.sha256').read_text().splitlines():
        expected, name = line.split('  ', 1)
        actual = digest(ROOT / name)
        if actual != expected:
            raise RuntimeError('fixture SHA-256 mismatch: ' + name)
        fixtures[name] = actual
    kernel = Path(os.environ.get('SHEN_KL_DIR', ROOT / 'klambda')).resolve()
    actual = {p.name: digest(p) for p in sorted(kernel.glob('*.kl'))}
    for label, manifest in [('715824a52b55e9c81a9501df8548ff3edd8411f5', ROOT / 'bench/kernel-431.sha256.json'),
                            ('ec16a9fa4fc2e87e2aa336fb1ae30e8ac2266394', ROOT / 'test/fixtures/kernel-ec16a9f/sha256.json')]:
        if actual == json.loads(manifest.read_text()):
            return dict(kernel_commit=label, kernel_sha256=actual, fixtures_sha256=fixtures)
    raise RuntimeError('selected full kernel does not match either authenticated 23-file manifest')

if __name__ == '__main__':
    print(json.dumps(verify(), sort_keys=True))

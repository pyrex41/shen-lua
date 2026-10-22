#!/usr/bin/env python3
"""Verify every exact-kernel fixture and community test against its pinned archive."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile

root = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('archive', type=Path)
args = ap.parse_args()
expected = '060066a8f84d9a2f7d41cb3b37b986a8d4653279752b739b5063cd648d9baacd'
assert hashlib.sha256(args.archive.read_bytes()).hexdigest() == expected, 'archive SHA-256 mismatch'
fixture = root / 'test/fixtures/kernel-ec16a9f'
manifest = json.loads((fixture / 'sha256.json').read_text())
prefix = 'ShenOSKernel-43.1-ec16a9f/'
with tarfile.open(args.archive, 'r:gz') as archive:
    official = {Path(m.name).name for m in archive.getmembers()
                if m.isfile() and m.name.startswith(prefix + 'klambda/') and m.name.endswith('.kl')}
    assert official == set(manifest) and len(official) == 23
    for name, sha in manifest.items():
        data = archive.extractfile(prefix + 'klambda/' + name).read()
        assert hashlib.sha256(data).hexdigest() == sha
        assert (fixture / name).read_bytes() == data, name
    tests = [m for m in archive.getmembers() if m.isfile() and m.name.startswith(prefix + 'tests/')]
    for member in tests:
        path = root / member.name.removeprefix(prefix)
        assert path.read_bytes() == archive.extractfile(member).read(), str(path)
print(json.dumps(dict(archive_sha256=expected, official_kl_files=len(official),
                     community_test_files=len(tests), result='byte-identical'), sort_keys=True))

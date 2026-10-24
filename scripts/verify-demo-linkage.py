#!/usr/bin/env python3
"""Verify every built demo embeds the SHA-256 of its current static framework."""
from pathlib import Path
import argparse
import hashlib
import json
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent / 'build/VerificationDerivedData/demo')
args = parser.parse_args()
checks = []
for framework in sorted(args.root.glob('*/Build/Products/*/SGPlayer.framework')):
    archive = framework / 'SGPlayer'
    app = framework.parent / 'SGPlayer.app'
    executable = app / ('Contents/MacOS/SGPlayer' if (app / 'Contents').is_dir() else 'SGPlayer')
    if not executable.is_file():
        continue
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    passed = digest.encode() in executable.read_bytes()
    checks.append(dict(sdk=framework.parents[3].name, configuration=framework.parent.name,
                       archive_sha256=digest, passed=passed))
report = dict(passed=bool(checks) and all(c['passed'] for c in checks), checks=checks)
args.root.mkdir(parents=True, exist_ok=True)
(args.root / 'linkage-verification.json').write_text(json.dumps(report, indent=2) + '\n')
for check in checks:
    print(('PASS' if check['passed'] else 'FAIL'), check['sdk'], check['configuration'])
raise SystemExit(0 if report['passed'] else 1)

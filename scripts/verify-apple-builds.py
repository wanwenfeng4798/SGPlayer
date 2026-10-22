#!/usr/bin/env python3
"""Verify SGPlayer with the pinned Xcode toolchain across all Apple platforms."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
PLATFORMS = [
    ('macOS', 'macosx', 'macOS', 'arm64 x86_64', 'demo-macos'),
    ('iOS', 'iphoneos', 'iOS', 'arm64', 'demo-ios'),
    ('iOS', 'iphonesimulator', 'iOS Simulator', 'arm64 x86_64', 'demo-ios'),
    ('tvOS', 'appletvos', 'tvOS', 'arm64', 'demo-tvos'),
    ('tvOS', 'appletvsimulator', 'tvOS Simulator', 'arm64 x86_64', 'demo-tvos'),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--include-demos', action='store_true')
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    required = (ROOT / '.xcode-version').read_text().strip()
    actual = subprocess.check_output(['xcodebuild', '-version'], text=True).splitlines()[0]
    if actual != f'Xcode {required}':
        raise SystemExit(f'Requires Xcode {required}; got {actual}')
    destination = ROOT / 'build' / 'verification' / f'xcode-{required}'
    destination.mkdir(parents=True, exist_ok=True)

    def verify(spec):
        platform, sdk, name, architectures, demo = spec
        results = []
        targets = [('framework', f'SGPlayer {platform}', c) for c in ['Debug', 'Release']]
        if args.include_demos:
            targets += [('demo', demo, c) for c in ['Debug', 'Release']]
        for kind, scheme, config in targets:
            log = destination / f'{kind}-{sdk}-{config}.log'
            command = ['xcodebuild']
            if kind == 'framework':
                command += ['-project', 'SGPlayer.xcodeproj']
            else:
                command += ['-workspace', 'demo/demo.xcworkspace']
            command += ['-scheme', scheme, '-configuration', config, '-sdk', sdk,
                        '-destination', f'generic/platform={name}', '-derivedDataPath',
                        str(ROOT / 'build' / 'VerificationDerivedData' / kind / sdk),
                        'CODE_SIGNING_ALLOWED=NO', 'ONLY_ACTIVE_ARCH=NO',
                        f'ARCHS={architectures}', 'build']
            with log.open('w') as stream:
                result = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
            entry = dict(kind=kind, platform=platform, sdk=sdk, configuration=config,
                         architectures=architectures.split(), exit_code=result.returncode,
                         command=command, log=str(log.relative_to(ROOT)))
            results.append(entry)
            print(f'{kind} {sdk} {config}: {"PASS" if result.returncode == 0 else "FAIL"}', flush=True)
        return results

    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        results = [r for group in executor.map(verify, PLATFORMS) for r in group]
    (destination / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    raise SystemExit(any(r['exit_code'] for r in results))


if __name__ == '__main__':
    main()

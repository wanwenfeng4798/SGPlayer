#!/usr/bin/env python3
"""Run every bundled demo on this Mac or a booted tvOS simulator."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent


def run(command, **kwargs):
    return subprocess.run(list(map(str, command)), cwd=ROOT, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['macos', 'tvos'])
    parser.add_argument('--simulator', help='Booted Apple TV simulator UDID (required for tvOS)')
    args = parser.parse_args()
    version = subprocess.check_output(['xcodebuild', '-version'], text=True).splitlines()[0]
    if version != 'Xcode ' + (ROOT / '.xcode-version').read_text().strip():
        raise SystemExit('Select the pinned Xcode version first')
    tv = args.platform == 'tvos'
    if tv and not args.simulator:
        parser.error('tvOS requires --simulator')
    output = ROOT / ('build/RuntimeTV' if tv else 'build/RuntimeMac')
    output.mkdir(parents=True, exist_ok=True)
    sdk = 'appletvsimulator' if tv else 'macosx'
    destination = 'generic/platform=tvOS Simulator' if tv else 'platform=macOS,arch=arm64'
    with (output / 'runtime-build.log').open('w') as log:
        run(['xcodebuild', '-workspace', 'demo/demo.xcworkspace', '-scheme', f'demo-{args.platform}',
             '-configuration', 'Debug', '-sdk', sdk, '-destination', destination,
             '-derivedDataPath', output, 'ARCHS=arm64',
             'CODE_SIGNING_ALLOWED=NO' if tv else 'CODE_SIGN_IDENTITY=-', 'build'],
            stdout=log, stderr=subprocess.STDOUT)
    app = output / ('Build/Products/Debug-appletvsimulator/SGPlayer.app' if tv else 'Build/Products/Debug/SGPlayer.app')
    run_id = str(uuid.uuid4())
    arguments = ['--sgplayer-smoke-test', f'--sgplayer-smoke-run={run_id}']
    if tv:
        bundle = 'com.libobjc.SGPlayer.demo-tvos'
        run(['xcrun', 'simctl', 'install', args.simulator, app])
        run(['xcrun', 'simctl', 'launch', '--terminate-running-process', args.simulator, bundle, *arguments])
        container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.simulator, bundle, 'data'], text=True).strip()
        directory = Path(container) / 'Documents'
    else:
        directory = ROOT / 'build/runtime-macos'
        arguments.append(f'--sgplayer-test-output={directory}')
        run(['open', '-n', app, '--args', *arguments])
    result_file = directory / 'sgplayer-device-smoke.json'
    for _ in range(84):
        time.sleep(5)
        if not result_file.exists():
            continue
        result = json.loads(result_file.read_text())
        if result.get('runID') != run_id:
            continue
        (output / 'runtime-result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
        if result.get('ffmpegVersion') != '9.0.2' or not result.get('passed') or len(result.get('cases', [])) != 7:
            raise SystemExit('Demo regression failed')
        if tv:
            run(['xcrun', 'simctl', 'io', args.simulator, 'screenshot', output / 'rendered-screen.png'])
        print('PASS: every bundled demo completed playback controls and EOF checks.')
        return
    raise SystemExit('No matching test result within 420 seconds')


if __name__ == '__main__':
    main()

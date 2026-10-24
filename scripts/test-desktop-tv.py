#!/usr/bin/env python3
"""Run every bundled demo on this Mac or a booted iPhone/tvOS simulator."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent


def run(command, **kwargs):
    return subprocess.run(list(map(str, command)), cwd=ROOT, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['macos', 'ios', 'tvos'])
    parser.add_argument('--simulator', help='Booted iPhone/Apple TV simulator UDID')
    args = parser.parse_args()
    tv = args.platform == 'tvos'
    simulator = args.platform != 'macos'
    if simulator and not args.simulator:
        parser.error('iOS/tvOS requires --simulator')
    output = ROOT / ('build/RuntimeTV' if tv else 'build/RuntimeIOS' if simulator else 'build/RuntimeMac')
    output.mkdir(parents=True, exist_ok=True)
    run_id = str(uuid.uuid4())
    status = output / 'runtime-status.json'
    status.write_text(json.dumps(dict(passed=None, status='preparing', runID=run_id)) + '\n')
    if not simulator:
        console = subprocess.check_output(['ioreg', '-n', 'Root', '-d', '1'], text=True)
        if '"CGSSessionScreenIsLocked"=Yes' in console:
            status.write_text(json.dumps(dict(passed=None, status='blocked-screen-locked', runID=run_id)) + '\n')
            raise SystemExit('Unlock this Mac for foreground demo verification')
    version = subprocess.check_output(['xcodebuild', '-version'], text=True).splitlines()[0]
    if version != 'Xcode ' + (ROOT / '.xcode-version').read_text().strip():
        raise SystemExit('Select the pinned Xcode version first')
    sdk = 'appletvsimulator' if tv else 'iphonesimulator' if simulator else 'macosx'
    destination = 'generic/platform=tvOS Simulator' if tv else 'generic/platform=iOS Simulator' if simulator else 'platform=macOS,arch=arm64'
    with (output / 'runtime-build.log').open('w') as log:
        run(['xcodebuild', '-workspace', 'demo/demo.xcworkspace', '-scheme', f'demo-{args.platform}',
             '-configuration', 'Debug', '-sdk', sdk, '-destination', destination,
             '-derivedDataPath', output, 'ARCHS=arm64',
             'CODE_SIGNING_ALLOWED=NO' if simulator else 'CODE_SIGN_IDENTITY=-', 'build'],
            stdout=log, stderr=subprocess.STDOUT)
    products = output / ('Build/Products/Debug-' + sdk if simulator else 'Build/Products/Debug')
    app = products / 'SGPlayer.app'
    binary = app / ('SGPlayer' if simulator else 'Contents/MacOS/SGPlayer')
    archive = products / 'SGPlayer.framework/SGPlayer'
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest.encode() not in binary.read_bytes():
        raise SystemExit('Demo does not embed the current framework digest')
    info = app / ('Info.plist' if simulator else 'Contents/Info.plist')
    bundle = plistlib.loads(info.read_bytes())['CFBundleIdentifier']
    if args.platform == 'ios' and bundle != 'com.omnilink.fufucard':
        raise SystemExit('Unexpected iPhone bundle identifier')
    arguments = ['--sgplayer-smoke-test', f'--sgplayer-smoke-run={run_id}']
    process, temporary, console_log = None, None, None
    try:
        if simulator:
            run(['xcrun', 'simctl', 'install', args.simulator, app])
            run(['xcrun', 'simctl', 'launch', '--terminate-running-process', args.simulator, bundle, *arguments])
            container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.simulator, bundle, 'data'], text=True).strip()
            directory = Path(container) / 'Documents'
        else:
            temporary = tempfile.TemporaryDirectory(prefix='sgplayer-runtime-')
            directory = Path(temporary.name)
            arguments.append(f'--sgplayer-test-output={directory}')
            console_log = (output / 'runtime-console.log').open('w')
            process = subprocess.Popen([str(binary), *arguments], stdout=console_log, stderr=subprocess.STDOUT)
        status.write_text(json.dumps(dict(passed=None, status='running', runID=run_id)) + '\n')
        result_file = directory / 'sgplayer-device-smoke.json'
        for _ in range(84):
            time.sleep(5)
            if not result_file.exists():
                if process and process.poll() is not None:
                    raise SystemExit('Demo exited without a matching report')
                continue
            result = json.loads(result_file.read_text())
            if result.get('runID') != run_id:
                continue
            result['artifactValidation'] = dict(framework_sha256=digest,
                executable_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), embedded_framework_matches=True)
            (output / 'runtime-result.json').write_text(json.dumps(result, indent=2) + '\n')
            passed = result.get('ffmpegVersion') == '9.0.2' and result.get('passed') and len(result.get('cases', [])) == 7
            status.write_text(json.dumps(dict(passed=bool(passed), status='complete', runID=run_id)) + '\n')
            print(json.dumps(result, indent=2))
            if not passed:
                raise SystemExit('Demo regression failed')
            if simulator:
                run(['xcrun', 'simctl', 'io', args.simulator, 'screenshot', output / 'rendered-screen.png'])
            print('PASS: every bundled demo completed playback controls and EOF checks.')
            return
        raise SystemExit('No matching test result within 420 seconds')
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if console_log:
            console_log.close()
        if temporary:
            temporary.cleanup()


if __name__ == '__main__':
    main()

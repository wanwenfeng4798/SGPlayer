#!/usr/bin/env python3
"""Sign, install and exercise the iPhone demo using the configured Xcode team."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = 'com.omnilink.fufucard'


def run(command, **kwargs):
    print('+', ' '.join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, cwd=ROOT, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='Connected iPhone UDID or CoreDevice identifier')
    args = parser.parse_args()
    required = (ROOT / '.xcode-version').read_text().strip()
    version = subprocess.check_output(['xcodebuild', '-version'], text=True).splitlines()[0]
    if version != f'Xcode {required}':
        raise SystemExit(f'Requires Xcode {required}; got {version}')
    output = ROOT / 'build/iPhoneDevice'
    output.mkdir(parents=True, exist_ok=True)
    with (output / 'signed-build.log').open('w') as log:
        run(['xcodebuild', '-workspace', 'demo/demo.xcworkspace', '-scheme', 'demo-ios',
             '-configuration', 'Debug', '-destination', f'id={args.device}',
             '-derivedDataPath', output, '-allowProvisioningUpdates',
             '-allowProvisioningDeviceRegistration', 'build'], stdout=log, stderr=subprocess.STDOUT)
    app = output / 'Build/Products/Debug-iphoneos/SGPlayer.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != BUNDLE:
        raise SystemExit('Unexpected application bundle identifier')
    run(['codesign', '--verify', '--deep', '--strict', app])
    with tempfile.TemporaryDirectory(dir=output) as tmp:
        payload = Path(tmp) / 'Payload'
        payload.mkdir()
        shutil.copytree(app, payload / app.name)
        run(['ditto', '-c', '-k', '--keepParent', payload, output / f'{BUNDLE}-development.ipa'])
    device = ['xcrun', 'devicectl', 'device']
    run([*device, 'install', 'app', '--device', args.device, app,
         '--json-output', output / 'install.json'])
    run_id = str(uuid.uuid4())
    run([*device, 'process', 'launch', '--device', args.device, '--terminate-existing',
         '--json-output', output / 'launch.json', BUNDLE, '--', '--sgplayer-smoke-test',
         f'--sgplayer-smoke-run={run_id}'])
    result_file = output / 'smoke-result.json'
    result = None
    for _ in range(84):
        time.sleep(5)
        command = [*device, 'copy', 'from', '--device', args.device, '--domain-type',
                   'appDataContainer', '--domain-identifier', BUNDLE, '--source',
                   'Documents/sgplayer-device-smoke.json', '--destination', result_file]
        received = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True)
        if received.returncode == 0:
            candidate = json.loads(result_file.read_text())
            if candidate.get('runID') == run_id:
                result = candidate
                break
    if not result:
        raise SystemExit('No result from the current iPhone playback test within 420 seconds')
    print(json.dumps(result, indent=2), flush=True)
    if not result.get('passed') or result.get('ffmpegVersion') != '9.0.2':
        raise SystemExit('iPhone playback regression failed')
    run([*device, 'copy', 'from', '--device', args.device, '--domain-type', 'appDataContainer',
         '--domain-identifier', BUNDLE, '--source', 'Documents/sgplayer-device-smoke.png',
         '--destination', output / 'smoke-frame.png'])
    # Leave the normal demo UI ready for manual testing.
    run([*device, 'process', 'launch', '--device', args.device, '--terminate-existing',
         '--json-output', output / 'normal-launch.json', BUNDLE])
    print('PASS: signed iPhone playback, VideoToolbox frames, seek and screenshot.', flush=True)


if __name__ == '__main__':
    main()

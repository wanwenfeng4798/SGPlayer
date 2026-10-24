#!/usr/bin/env python3
"""Validate the generated Swift package in a real macOS application display loop."""
from pathlib import Path
import shutil
import plistlib
import json
import hashlib
import tempfile
import uuid
import subprocess
ROOT = Path(__file__).resolve().parent.parent
out = ROOT / 'build/SwiftUISmoke'
out.mkdir(parents=True, exist_ok=True)
report_out = out / 'results.json'
history = out / 'runs'
history.mkdir(exist_ok=True)
run_report = history / (str(uuid.uuid4()) + '.json')
if report_out.exists():
    shutil.copy2(report_out, history / (str(uuid.uuid4()) + '-previous.json'))
report_out.unlink(missing_ok=True)
console = subprocess.check_output(['ioreg', '-n', 'Root', '-d', '1'], text=True)
if '"CGSSessionScreenIsLocked"=Yes' in console:
    report_out.write_text(json.dumps(dict(passed=None, status='blocked-screen-locked')) + '\n')
    shutil.copy2(report_out, run_report)
    raise SystemExit('Mac is locked: unlock before foreground SwiftUI acceptance')
(out / 'Sources/Smoke').mkdir(parents=True, exist_ok=True)
(out / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Smoke", platforms: [.macOS(.v12)],
    dependencies: [.package(path: "../Package")],
    targets: [.executableTarget(name: "Smoke", dependencies: [.product(name: "SGPlayerUI", package: "Package")])])
''')
shutil.copy2(ROOT / 'tests/swiftui-smoke.swift', out / 'Sources/Smoke/main.swift')
subprocess.run(['swift', 'build', '--package-path', str(out)], check=True, cwd=ROOT)
binpath = Path(subprocess.check_output(['swift', 'build', '--package-path', str(out), '--show-bin-path'], text=True).strip())
runtime = Path(tempfile.mkdtemp(prefix='sgplayer-swiftui-'))
app = runtime / 'SGPlayerUISmoke.app'
(app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
shutil.copy2(binpath / 'Smoke', app / 'Contents/MacOS/Smoke')
resources = app / 'Contents/Resources'
resources.mkdir()
bundle = binpath / 'SGPlayer_SGPlayerUI.bundle'
if not bundle.is_dir():
    bundle = next(out.rglob('SGPlayer_SGPlayerUI.bundle'))
shutil.copytree(bundle, resources / bundle.name)
fixture = runtime / 'orientation.mp4'
shutil.copy2(ROOT / 'tests/fixtures/orientation.mp4', fixture)
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(dict(CFBundleIdentifier='com.omnilink.sgplayer.swiftui-smoke', CFBundleExecutable='Smoke', CFBundleName='SGPlayerUISmoke', CFBundlePackageType='APPL', NSPrincipalClass='NSApplication'), f)
report = runtime / 'results.json'
report.unlink(missing_ok=True)
process = subprocess.Popen([str(app / 'Contents/MacOS/Smoke'), str(fixture), str(report)])
try:
    code = process.wait(timeout=100)
    if report.exists():
        shutil.copy2(report, report_out)
    else:
        report_out.write_text(json.dumps(dict(passed=False, status='no-report', exit_code=code)) + '\n')
    native_report = json.loads(report_out.read_text())
    shutil.copy2(report_out, run_report.with_name(run_report.stem + '-native.json'))
    package_report = json.loads((ROOT / 'build/Package/build-report.json').read_text())
    native_report['package_framework_sha256'] = package_report['framework_sha256']['macosx']
    native_report['swift_ui_source_sha256'] = package_report['swift_source_sha256']
    native_report['smoke_source_sha256'] = hashlib.sha256((ROOT / 'tests/swiftui-smoke.swift').read_bytes()).hexdigest()
    native_report['executable_sha256'] = hashlib.sha256((app / 'Contents/MacOS/Smoke').read_bytes()).hexdigest()
    report_out.write_text(json.dumps(native_report, indent=2) + '\n')
    shutil.copy2(report_out, run_report)
    if code == 0 and json.loads(report_out.read_text()).get('passed'):
        shutil.copy2(report_out, out / 'last-passed.json')
    print(report_out.read_text())
    if code or not json.loads(report_out.read_text()).get('passed'):
        raise SystemExit('SwiftUI application playback failed; inspect build/SwiftUISmoke/results.json')
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    shutil.rmtree(runtime)

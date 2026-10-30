#!/usr/bin/env python3
"""Check real AppKit PiP visible left/right edges in a source view with a different aspect ratio."""
from pathlib import Path
import subprocess
import tempfile
import plistlib
import os
import sys

ROOT = Path(__file__).resolve().parent.parent
frameworks = ROOT / 'build/VerificationDerivedData/framework/macosx/Build/Products/Release'
if not (frameworks / 'SGPlayer.framework').exists():
    raise SystemExit('Build the local Release SGPlayer macOS framework first.')
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='sg-toolbar-') as temp:
    app = Path(temp) / 'SGPiPValidation.app'
    executable = app / 'Contents/MacOS/pip-layout'
    executable.parent.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.sgplayer.tests.pip-layout','CFBundleExecutable':'pip-layout','CFBundleName':'SGPlayer PiP Validation','CFBundlePackageType':'APPL','CFBundleVersion':'1','NSHighResolutionCapable':True}))
    binary = str(executable)
    subprocess.run(['xcrun', 'clang', '-isysroot', sdk, '-fobjc-arc', '-framework', 'AppKit',
                    '-F', str(frameworks), '-framework', 'SGPlayer', '-lz', '-lbz2', '-liconv', '-lc++',
                    str(ROOT / 'tests/pip-layout.m'), '-o', binary], check=True)
    subprocess.run(['codesign','--force','--sign','-',str(app)], check=True)
    for kernel in ['native', 'ffmpeg']:
        environment = dict(os.environ, SG_PIP_KERNEL=kernel)
        if '--logic-only' in sys.argv:
            environment['SG_PIP_LOGIC_ONLY'] = '1'
        result = subprocess.run([binary], env=environment, timeout=120)
        if result.returncode == 77:
            raise SystemExit(77)
        result.check_returncode()

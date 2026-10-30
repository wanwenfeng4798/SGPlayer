#!/usr/bin/env python3
"""Check real AppKit native ad scheduling, pure mode, cover and presentation policies using local media."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
frameworks = ROOT / 'build/VerificationDerivedData/framework/macosx/Build/Products/Release'
if not (frameworks / 'SGPlayer.framework').exists():
    raise SystemExit('Build the local Release SGPlayer macOS framework first.')
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='sg-policy-') as temp:
    for name in ['playback-policy', 'presentation-layout', 'overlay-style', 'vr-render']:
        binary = str(Path(temp) / name)
        subprocess.run(['xcrun', 'clang', '-isysroot', sdk, '-fobjc-arc', '-framework', 'AppKit', '-framework', 'VideoToolbox',
                        '-F', str(frameworks), '-framework', 'SGPlayer', '-lz', '-lbz2', '-liconv', '-lc++',
                        str(ROOT / ('tests/' + name + '.m')), '-o', binary], check=True)
        subprocess.run([binary], check=True, timeout=90)

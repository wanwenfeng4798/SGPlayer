#!/usr/bin/env python3
"""Check real AppKit toolbar geometry, locking and volume without network media."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
frameworks = ROOT / 'build/VerificationDerivedData/framework/macosx/Build/Products/Release'
if not (frameworks / 'SGPlayer.framework').exists():
    raise SystemExit('Build the local Release SGPlayer macOS framework first.')
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='sg-toolbar-') as temp:
    binary = str(Path(temp) / 'toolbar-layout')
    subprocess.run(['xcrun', 'clang', '-isysroot', sdk, '-fobjc-arc', '-framework', 'AppKit',
                    '-F', str(frameworks), '-framework', 'SGPlayer', '-lz', '-lbz2', '-liconv', '-lc++',
                    str(ROOT / 'tests/toolbar-layout.m'), '-o', binary], check=True)
    subprocess.run([binary], check=True)

#!/usr/bin/env python3
"""Embed a freshly compiled Metal library for the selected Apple SDK."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sdk', required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
targets = {'macosx': 'macos12.0', 'iphoneos': 'ios15.0',
           'iphonesimulator': 'ios15.0-simulator', 'appletvos': 'tvos15.0',
           'appletvsimulator': 'tvos15.0-simulator'}
sdk = next((k for k in targets if args.sdk.startswith(k)), None)
if not sdk:
    raise SystemExit(f'Unsupported SDK: {args.sdk}')
air = args.output / 'SGMetalShader.air'
library = args.output / 'SGMetalShader.metallib'
subprocess.run(['xcrun', '--sdk', args.sdk, 'metal', '-target', 'air64-apple-' + targets[sdk],
                '-c', str(ROOT / 'SGPlayer/Classes/Core/SGMetal/SGMetalShader.metal'), '-o', str(air)], check=True)
subprocess.run(['xcrun', '--sdk', args.sdk, 'metallib', str(air), '-o', str(library)], check=True)
data = library.read_bytes()
content = 'static const unsigned char metallib[] = {\n' + ',\n'.join(
    ','.join(f'0x{b:02x}' for b in data[i:i+24]) for i in range(0, len(data), 24)) + '\n};\n'
header = args.output / 'SGMetalShader.h'
if not header.exists() or header.read_text() != content:
    header.write_text(content)

#!/usr/bin/env python3
"""Run the macOS FFmpeg 9 migration regression executable.

Uses the source list of the macOS Xcode target. Metal shaders are not needed by
these CPU/data-path tests. --asan instruments SGPlayer as well as the tests.
"""
import argparse
import hashlib
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import platform
import functools
import http.server
import ssl
import threading
import wave

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--asan', action='store_true')
    parser.add_argument('--network', action='store_true', help='Test HTTPS on a local TLS server')
    parser.add_argument('--hardware', action='store_true', help='Require H.264/HEVC VideoToolbox encode/decode')
    args = parser.parse_args()
    build = ROOT / 'build' / ('tests-asan' if args.asan else 'tests')
    build.mkdir(parents=True, exist_ok=True)
    objects = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-',
                        str(ROOT / 'SGPlayer.xcodeproj/project.pbxproj')]))['objects']
    target = next(v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v['name'] == 'SGPlayer macOS')
    phase = next(objects[p] for p in target['buildPhases'] if objects[p]['isa'] == 'PBXSourcesBuildPhase')
    sources = []
    for ref in phase['files']:
        name = objects[objects[ref]['fileRef']]['path']
        if Path(name).suffix not in ('.m', '.c'):
            continue
        matches = list((ROOT / 'SGPlayer').rglob(name))
        if len(matches) != 1:
            raise SystemExit(f'Ambiguous source: {name}')
        sources.append(matches[0])
    sources.append(ROOT / 'tests/ffmpeg-migration.m')
    includes = sorted({p.parent for p in (ROOT / 'SGPlayer/Classes').rglob('*.h')})
    subprocess.run(['python3', str(ROOT / 'scripts/build-metal.py'), '--sdk', 'macosx', '--output', str(build / 'metal')], check=True)
    includes.append(build / 'metal')
    includes.append(ROOT / 'build/libs/macOS/universal/include')
    flags = ['-fblocks', '-g', '-O1', '-Wno-deprecated-declarations', '-Wno-documentation',
             '-arch', platform.machine(), '-mmacosx-version-min=12.0']
    for path in includes:
        flags += ['-I', str(path)]
    if args.asan:
        flags += ['-fsanitize=address', '-fno-omit-frame-pointer']

    header_hash = hashlib.sha256()
    for header in sorted({h for directory in includes for h in directory.rglob('*.h')}):
        header_hash.update(str(header).encode())
        header_hash.update(header.read_bytes())
    header_hash.update(subprocess.check_output(['xcrun', 'clang', '--version']))

    def compile_source(source):
        obj = build / (source.name + '.o')
        stamp = obj.with_suffix('.inputs')
        digest = hashlib.sha256(header_hash.digest() + source.read_bytes() + repr(flags).encode()).hexdigest()
        if obj.exists() and stamp.exists() and stamp.read_text() == digest:
            return str(obj)
        command = ['xcrun', 'clang', *flags]
        if source.suffix == '.m':
            command += ['-fobjc-arc']
        subprocess.run(command + ['-c', str(source), '-o', str(obj)], check=True)
        stamp.write_text(digest)
        return str(obj)

    with ThreadPoolExecutor(max_workers=4) as executor:
        compiled = list(executor.map(compile_source, sources))
    frameworks = ['Cocoa', 'AVFoundation', 'AudioToolbox', 'VideoToolbox', 'CoreMedia',
                  'CoreVideo', 'Metal', 'MetalKit', 'GLKit', 'QuartzCore', 'Security', 'CoreFoundation']
    command = ['xcrun', 'clang', *flags, *compiled, '-o', str(build / 'ffmpeg-migration'),
               '-L', str(ROOT / 'build/libs/macOS/universal/lib'),
               '-lavformat', '-lavcodec', '-lavfilter', '-lswscale', '-lswresample', '-lavutil', '-lz']
    for framework in frameworks:
        command += ['-framework', framework]
    subprocess.run(command, check=True)
    with wave.open(str(build / 'silence.wav'), 'wb') as audio:
        audio.setnchannels(2)
        audio.setsampwidth(2)
        audio.setframerate(44100)
        audio.writeframes(bytes(44100 * 4))
    server = None
    url = ''
    if args.network:
        key, cert = build / 'test-key.pem', build / 'test-cert.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-keyout', str(key), '-out', str(cert), '-subj', '/CN=localhost'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        class PlayerHandler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/player.wav':
                    if self.headers.get('User-Agent') != 'SGPlayer':
                        self.send_error(403, 'Incorrect player User-Agent')
                        return
                    self.path = '/silence.wav'
                super().do_GET()
        handler = functools.partial(PlayerHandler, directory=str(build))
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = f'https://127.0.0.1:{server.server_port}/silence.wav'
    try:
        subprocess.run([str(build / 'ffmpeg-migration'), str(build / 'bframes.mp4'), url,
                        'hardware' if args.hardware else '', str(build / 'silence.wav')], check=True, timeout=120)
    finally:
        if server:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()

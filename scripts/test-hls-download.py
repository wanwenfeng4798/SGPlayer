#!/usr/bin/env python3
"""Verify actual macOS HLS download, offline frames and restoration across app processes."""
import functools
import http.server
import json
from pathlib import Path
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent

class MediaFiles(http.server.SimpleHTTPRequestHandler):
    requests = 0
    offline = False
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, '.m3u8': 'application/vnd.apple.mpegurl', '.ts': 'video/mp2t'}
    def log_message(self, *_args):
        pass
    def do_GET(self):
        type(self).requests += 1
        if type(self).offline:
            self.send_error(503)
        else:
            super().do_GET()

def main():
    build = ROOT / 'build/hls-verification'
    build.mkdir(parents=True, exist_ok=True)
    includes = ROOT / 'build/libs/macOS/universal/include'
    libraries = ROOT / 'build/libs/macOS/universal/lib'
    command = ['xcrun', 'clang', str(ROOT / 'tests/hls-fixture.c'), '-I', str(includes), '-L', str(libraries),
               '-lavformat', '-lavcodec', '-lswscale', '-lswresample', '-lavutil', '-lz', '-liconv']
    for framework in ['VideoToolbox', 'AudioToolbox', 'CoreMedia', 'CoreVideo', 'CoreFoundation', 'Security', 'Foundation']:
        command += ['-framework', framework]
    subprocess.run(command + ['-o', str(build / 'make-hls')], check=True)
    subprocess.run([str(build / 'make-hls'), str(ROOT / 'tests/fixtures/orientation.mp4'), str(build)], check=True)
    app = ROOT / 'build/ExpansionUIMac/Build/Products/Debug/SGPlayer.app/Contents/MacOS/SGPlayer'
    if not app.is_file():
        raise SystemExit('Build the features-ui-macos scheme into build/ExpansionUIMac first')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(MediaFiles, directory=str(build)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    result = build / 'hls-test.json'
    reports = []
    identifier = 'hls-test-' + str(uuid.uuid4())
    try:
        for phase in ['download', 'offline-restoration']:
            result.unlink(missing_ok=True)
            before = MediaFiles.requests
            with (build / f'{phase}.log').open('w') as log:
                arguments = [str(app), '--sgplayer-features', '--sgplayer-session-controls', '--sgplayer-no-resume', '--sgplayer-hls-test-id=' + identifier,
                    '--sgplayer-test-output=' + str(build), f'--sgplayer-hls-test=http://127.0.0.1:{server.server_port}/index.m3u8']
                if phase == 'offline-restoration':
                    arguments.append('--sgplayer-hls-test-cleanup')
                process = subprocess.Popen(arguments, stdout=log, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 180
                    while not result.is_file() and time.monotonic() < deadline and process.poll() is None:
                        time.sleep(.2)
                    if not result.is_file():
                        raise RuntimeError(f'{phase}: no result; see {log.name}')
                    report = json.loads(result.read_text())
                    report['scenario'] = phase
                    report['networkRequests'] = MediaFiles.requests - before
                    if not report.get('passed'):
                        raise RuntimeError(f'{phase}: {report}; see {log.name}')
                    if phase == 'download' and (report.get('phase') != 'downloaded' or report['networkRequests'] == 0):
                        raise RuntimeError(f'Expected a new HLS download: {report}')
                    if phase == 'offline-restoration' and (report['networkRequests'] or report.get('phase') != 'restored'):
                        raise RuntimeError(f'Offline restoration fetched the network or did not restore: {report}')
                    reports.append(report)
                    print('PASS', phase, report, flush=True)
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            MediaFiles.offline = True
    finally:
        server.shutdown()
        (build / 'results.json').write_text(json.dumps({'passed': len(reports) == 2, 'checks': reports}, indent=2) + '\n')

if __name__ == '__main__':
    main()

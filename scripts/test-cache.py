#!/usr/bin/env python3
"""Exercise the real URLSession disk cache against a loopback media-file server."""
import http.server
from pathlib import Path
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent

class MediaFiles(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        path = self.path.rsplit('/', 1)[-1]
        if path == '404.bin':
            self.send_error(404)
            return
        status = 206 if path == 'partial.bin' else 200
        data = bytes(range(256)) * (1024 if path == 'huge.bin' else 256)
        if path in ('index.m3u8', 'disguised.bin'):
            data = b'#EXTM3U\n#EXTINF:1,\nsegment.ts\n'
        self.send_response(status)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            if path == 'slow.bin':
                for offset in range(0, len(data), 1024):
                    self.wfile.write(data[offset:offset + 1024])
                    self.wfile.flush()
                    time.sleep(.02)
            else:
                self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

def main():
    build = ROOT / 'build/cache-tests'
    build.mkdir(parents=True, exist_ok=True)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-g', '-Wno-deprecated-declarations',
                    '-I', str(ROOT / 'SGPlayer/Classes/Features'),
                    str(ROOT / 'SGPlayer/Classes/Features/SGMediaCache.m'),
                    str(ROOT / 'tests/media-cache.m'), '-framework', 'Foundation',
                    '-o', str(build / 'media-cache')], check=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), MediaFiles)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(dir=build) as directory:
            subprocess.run([str(build / 'media-cache'), f'http://127.0.0.1:{server.server_port}/', directory], check=True)
    finally:
        server.shutdown()

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Build the pinned FFmpeg release for Apple devices and simulators."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
VERSION = '9.0.2'
SHA256 = '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e'
BASE = ROOT / 'build' / 'ffmpeg' / VERSION
LIBS = ('avcodec', 'avfilter', 'avformat', 'avutil', 'swresample', 'swscale')
TARGETS = {
    'macOS': [('macosx', 'arm64', 'arm64-apple-macos12.0'), ('macosx', 'x86_64', 'x86_64-apple-macos12.0')],
    'iOS': [('iphoneos', 'arm64', 'arm64-apple-ios15.0'), ('iphonesimulator', 'arm64', 'arm64-apple-ios15.0-simulator'), ('iphonesimulator', 'x86_64', 'x86_64-apple-ios15.0-simulator')],
    'tvOS': [('appletvos', 'arm64', 'arm64-apple-tvos15.0'), ('appletvsimulator', 'arm64', 'arm64-apple-tvos15.0-simulator'), ('appletvsimulator', 'x86_64', 'x86_64-apple-tvos15.0-simulator')],
}


def run(args, **kwargs):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, **kwargs)


def output(args):
    return subprocess.check_output(args, text=True).strip()


def source():
    cache = ROOT / 'build' / 'downloads'
    cache.mkdir(parents=True, exist_ok=True)
    archive = Path(os.environ.get('FFMPEG_ARCHIVE', cache / f'ffmpeg-{VERSION}.tar.xz')).resolve()
    if not archive.exists():
        partial = archive.with_suffix('.download')
        run(['curl', '--fail', '--location', '--retry', '3', '--output', partial,
             f'https://ffmpeg.org/releases/ffmpeg-{VERSION}.tar.xz'])
        partial.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise SystemExit(f'FFmpeg archive checksum mismatch: {archive}')
    destination = BASE / 'source'
    if not destination.exists():
        BASE.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=BASE) as tmp:
            run(['tar', '-xJf', archive, '-C', tmp])
            Path(tmp, f'ffmpeg-{VERSION}').rename(destination)
    return destination


def build_slice(src, sdk, arch, target, jobs):
    work = BASE / sdk / arch
    prefix = work / 'output'
    work.mkdir(parents=True, exist_ok=True)
    sdkpath = output(['xcrun', '--sdk', sdk, '--show-sdk-path'])
    compiler = output(['xcrun', '--sdk', sdk, '--find', 'clang'])
    flags = f'-target {target} -isysroot {sdkpath}'
    cfg = [str(src / 'configure'), f'--prefix={prefix}', f'--arch={arch}', '--target-os=darwin',
           '--enable-cross-compile', f'--cc={compiler}', f'--extra-cflags={flags}',
           f'--extra-ldflags={flags}', '--enable-static', '--disable-shared', '--enable-pic',
           '--disable-autodetect', '--disable-gpl', '--disable-nonfree', '--disable-programs',
           '--disable-doc', '--disable-avdevice', '--disable-devices', '--disable-filters',
           '--enable-filter=buffer,buffersink,format,scale,lutrgb,lut3d,colorchannelmixer,hflip,vflip,gblur,split,blend',
           '--disable-audiotoolbox', '--enable-videotoolbox', '--enable-securetransport',
           '--enable-network', '--enable-zlib', '--disable-bzlib', '--disable-iconv']
    # Apple's toolchain has no NASM. Keep compiler intrinsics/ARM assembly enabled.
    if arch == 'x86_64' and not shutil.which('nasm'):
        cfg.append('--disable-x86asm')
    fingerprint = {'archive_sha256': SHA256, 'configure': cfg,
                   'xcode': output(['xcodebuild', '-version']),
                   'sdk': output(['xcrun', '--sdk', sdk, '--show-sdk-version']),
                   'compiler': output([compiler, '--version'])}
    stamp = work / 'build-inputs.json'
    if not stamp.exists() or json.loads(stamp.read_text()) != fingerprint:
        if (work / 'Makefile').exists():
            run(['make', 'distclean'], cwd=work)
        run(cfg, cwd=work)
        stamp.write_text(json.dumps(fingerprint, indent=2) + '\n')
    run(['make', f'-j{jobs}'], cwd=work)
    run(['make', 'install'], cwd=work)
    return prefix


def combine(platform, sdk, slices):
    destination = ROOT / 'build' / 'libs' / platform / ('simulator' if 'simulator' in sdk else 'universal')
    # Recreate only generated output, so stale headers/libraries cannot survive an upgrade.
    if destination.exists():
        shutil.rmtree(destination)
    (destination / 'lib').mkdir(parents=True)
    shutil.copytree(slices[0][1] / 'include', destination / 'include')
    for name in LIBS:
        run(['xcrun', 'lipo', '-create', *[p / 'lib' / f'lib{name}.a' for _, p in slices],
             '-output', destination / 'lib' / f'lib{name}.a'])
    # avconfig.h contains architecture-specific values, even within one platform.
    inc = destination / 'include' / 'libavutil'
    dispatch = []
    for index, (arch, prefix) in enumerate(slices):
        shutil.copyfile(prefix / 'include/libavutil/avconfig.h', inc / f'avconfig-{arch}.h')
        macro = '__aarch64__' if arch == 'arm64' else '__x86_64__'
        dispatch += [f'#{"if" if index == 0 else "elif"} defined({macro})', f'#include "avconfig-{arch}.h"']
    dispatch += ['#else', '#error Unsupported architecture', '#endif', '']
    (inc / 'avconfig.h').write_text('\n'.join(dispatch))
    (destination / 'version.json').write_text(json.dumps({'ffmpeg': VERSION, 'sha256': SHA256,
        'sdk': sdk, 'architectures': [a for a, _ in slices], 'tls': 'securetransport'}, indent=2) + '\n')
    return destination


def package(platform, variants):
    destination = ROOT / 'build' / 'xcframeworks' / platform
    destination.mkdir(parents=True, exist_ok=True)
    for name in LIBS:
        path = destination / f'lib{name}.xcframework'
        if path.exists():
            shutil.rmtree(path)
        args = ['xcodebuild', '-create-xcframework']
        for variant in variants:
            args += ['-library', variant / 'lib' / f'lib{name}.a', '-headers', variant / 'include']
        run(args + ['-output', path])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=[*TARGETS, 'all'])
    parser.add_argument('action', choices=['build', 'clean'])
    parser.add_argument('--jobs', type=int, default=min(os.cpu_count() or 4, 8))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    platforms = list(TARGETS) if args.platform == 'all' else [args.platform]
    if args.action == 'clean':
        for platform in platforms:
            for sdk, arch, _ in TARGETS[platform]:
                shutil.rmtree(BASE / sdk / arch, ignore_errors=True)
            shutil.rmtree(ROOT / 'build/libs' / platform, ignore_errors=True)
            shutil.rmtree(ROOT / 'build/xcframeworks' / platform, ignore_errors=True)
        return
    required = (ROOT / '.xcode-version').read_text().strip()
    actual = output(['xcodebuild', '-version']).splitlines()[0]
    if actual != f'Xcode {required}':
        raise SystemExit(f'Requires Xcode {required}; selected toolchain reports {actual}. Set DEVELOPER_DIR to the required Xcode Developer directory.')
    src = source()
    for platform in platforms:
        groups = {}
        for sdk, arch, target in TARGETS[platform]:
            prefix = build_slice(src, sdk, arch, target, args.jobs)
            groups.setdefault(sdk, []).append((arch, prefix))
        variants = [combine(platform, sdk, slices) for sdk, slices in groups.items()]
        package(platform, variants)


if __name__ == '__main__':
    main()

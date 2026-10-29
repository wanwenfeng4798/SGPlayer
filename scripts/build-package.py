#!/usr/bin/env python3
"""Build a self-contained local Swift package (binary core, SwiftUI and resource bundle)."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SLICES = [('macOS', 'macosx', 'macOS', 'arm64 x86_64'),
          ('iOS', 'iphoneos', 'iOS', 'arm64'),
          ('iOS', 'iphonesimulator', 'iOS Simulator', 'arm64 x86_64'),
          ('tvOS', 'appletvos', 'tvOS', 'arm64'),
          ('tvOS', 'appletvsimulator', 'tvOS Simulator', 'arm64 x86_64')]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["all", "iOS", "macOS", "tvOS"], default="all")
    args = parser.parse_args()
    slices = [row for row in SLICES if args.platform == "all" or row[0] == args.platform]
    required = (ROOT / '.xcode-version').read_text().strip()
    actual = subprocess.check_output(['xcodebuild', '-version'], text=True).splitlines()[0]
    if actual != f'Xcode {required}':
        raise SystemExit(f'Requires Xcode {required}; got {actual}')
    output = ROOT / 'build' / ('Package' if args.platform == 'all' else 'Package-' + args.platform)
    output.mkdir(parents=True, exist_ok=True)
    frameworks = []
    framework_digests = {}
    for platform, sdk, destination, archs in slices:
        derived = ROOT / 'build/VerificationDerivedData/framework' / sdk
        with (output / f'{sdk}.log').open('w') as log:
            subprocess.run(['xcodebuild', '-project', 'SGPlayer.xcodeproj', '-scheme', f'SGPlayer {platform}',
                            '-configuration', 'Release', '-sdk', sdk, '-destination', f'generic/platform={destination}',
                            '-derivedDataPath', str(derived), 'CODE_SIGNING_ALLOWED=NO', 'ONLY_ACTIVE_ARCH=NO',
                            f'ARCHS={archs}', 'build'], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        suffix = '' if sdk == 'macosx' else '-' + sdk
        framework = derived / f'Build/Products/Release{suffix}/SGPlayer.framework'
        defined = subprocess.check_output(['xcrun', 'nm', '-arch', 'arm64', '-gU', str(framework / 'SGPlayer')], text=True)
        for symbol in ['_avcodec_version', '_ass_library_init', '_OBJC_CLASS_$_SGPlaybackSession', '_OBJC_CLASS_$_SGMediaTranscoder', '_OBJC_CLASS_$_SGPlaybackCover']:
            if symbol not in defined:
                raise SystemExit(f'Framework is not self-contained: missing {symbol} in {sdk}')
        framework_digests[sdk] = hashlib.sha256((framework / 'SGPlayer').read_bytes()).hexdigest()
        frameworks.append(framework)
        print(f'PASS package framework {sdk}', flush=True)
    artifact = output / 'Artifacts/SGPlayer.xcframework'
    artifact.parent.mkdir(parents=True, exist_ok=True)
    # Only replace the generated artifact after the new one was successfully assembled.
    staging = output / 'Artifacts/SGPlayer-new.xcframework'
    if staging.exists():
        shutil.rmtree(staging)
    command = ['xcodebuild', '-create-xcframework']
    for framework in frameworks:
        command += ['-framework', str(framework)]
    subprocess.run(command + ['-output', str(staging)], check=True)
    if artifact.exists():
        shutil.rmtree(artifact)
    staging.rename(artifact)
    shutil.copy2(ROOT / 'packaging/Package.swift', output / 'Package.swift')
    sources = output / 'Sources/SGPlayerUI'
    shutil.copytree(ROOT / 'Swift/SGPlayerUI', sources, dirs_exist_ok=True)
    shutil.copytree(ROOT / 'SGPlayer/Resources/Fonts', sources / 'Resources/Fonts', dirs_exist_ok=True)
    shutil.copytree(ROOT / 'licenses', sources / 'Resources/Licenses', dirs_exist_ok=True)
    shutil.copy2(ROOT / 'LICENSE', sources / 'Resources/Licenses/SGPlayer-LICENSE')
    tests = output / 'Tests/SGPlayerUITests'
    shutil.copytree(ROOT / 'Swift/Tests', tests, dirs_exist_ok=True)
    (tests / 'Fixtures').mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'tests/fixtures/orientation.mp4', tests / 'Fixtures/orientation.mp4')
    report = {'xcode': actual, 'framework_sha256': framework_digests, 'sdks': [row[1] for row in slices],
              'swift_source_sha256': hashlib.sha256((ROOT / 'Swift/SGPlayerUI/SGPlayerView.swift').read_bytes()).hexdigest()}
    (output / 'build-report.json').write_text(json.dumps(report, indent=2) + '\n')
    shutil.copy2(ROOT / 'LICENSE', output / 'LICENSE')
    (output / 'README.md').write_text("SGPlayer local Swift package\n\nAdd this extracted folder as a local package in Xcode. Import SGPlayerUI and use SGPlayerModel() for automatic engine selection, or import SGPlayer for Objective-C APIs. Binary-only integrations may use Artifacts/SGPlayer.xcframework; copy Sources/SGPlayerUI/Resources/Fonts and Licenses into the host application's resources. Minimum deployment: iOS/tvOS 15, macOS 12.\n")
    # Preserve macOS versioned framework symlinks (Headers, Modules, Versions/Current).
    # shutil.make_archive records linked directories as empty ZIP directories.
    archive = output.with_suffix('.zip')
    archive.unlink(missing_ok=True)
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(output), str(archive)], check=True)
    print(f'Package ready: {archive}', flush=True)

if __name__ == '__main__':
    main()

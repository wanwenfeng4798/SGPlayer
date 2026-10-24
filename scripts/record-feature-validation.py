#!/usr/bin/env python3
"""Record evidence without conflating a passing batch with complete feature scope."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--date', required=True, help='Client-local calendar date, YYYY-MM-DD')
args = parser.parse_args()
artifacts = ROOT / 'build/feature-expansion-artifacts'
artifacts.mkdir(parents=True, exist_ok=True)
logs = {
    'macos_complete_with_transcode': '/tmp/sgplayer-transcode-complete-ui-macos.log',
    'macos_ui_build': '/tmp/sgplayer-transcode-macos-test-build.log',
    'macos_ui': '/tmp/sgplayer-expansion-unlocked-ui-macos.log',
    'ios_ui': '/tmp/sgplayer-expansion-final-ui-ios.log',
    'tvos_ui': '/tmp/sgplayer-expansion-final-ui-tvos.log',
    'ios_touch': '/tmp/sgplayer-touch-ui-ios.log',
    'ios_cover_and_touch': '/tmp/sgplayer-cover-touch-ui-ios.log',
    'tvos_cover': '/tmp/sgplayer-cover-ui-tvos.log',
    'ios_transcode': '/tmp/sgplayer-transcode-h264-ui-ios.log',
    'tvos_transcode': '/tmp/sgplayer-transcode-h264-ui-tvos.log',
    'ios_complete_with_transcode': '/tmp/sgplayer-transcode-complete-ui-ios.log',
    'tvos_complete_with_transcode': '/tmp/sgplayer-transcode-complete-ui-tvos.log',
    'data_asan': '/tmp/sgplayer-audio-export-accepted-data.log',
    'cache': '/tmp/sgplayer-cache-final-tests.log',
    'hls': '/tmp/sgplayer-hls-final-test.log',
    'swift_app': '/tmp/sgplayer-audio-export-swift-runtime.log',
    'swift_tests': '/tmp/sgplayer-audio-export-swift-tests.log',
    'swift_ios_build': '/tmp/sgplayer-controls-swift-ios-build.log',
    'build_matrix': '/tmp/sgplayer-audio-export-final-builds.log',
    'demo_linkage': '/tmp/sgplayer-audio-export-linkage.log',
    'package': '/tmp/sgplayer-audio-export-package.log',
    'macos_audio_export': '/tmp/sgplayer-audio-export-ui-macos.log',
    'ios_audio_export': '/tmp/sgplayer-audio-export-ui-ios.log',
    'tvos_audio_export': '/tmp/sgplayer-audio-export-ui-tvos.log',
    'ios_progress_position': '/tmp/sgplayer-progress-position-final-ios.log',
    'historical_macos_progress_best_effort': '/tmp/sgplayer-tracking-macos-best-effort-diagnostic.log',
    'macos_tracking': '/tmp/sgplayer-tracking-final-ui-macos.log',
    'ios_tracking_held': '/tmp/sgplayer-tracking-held-ui-ios.log',
    'ios_tracking': '/tmp/sgplayer-tracking-final-ui-ios.log',
    'historical_ios_tracking_initial': '/tmp/sgplayer-tracking-ui-ios.log',
    'historical_ios_progress_diagnostic': '/tmp/sgplayer-progress-diagnostic-ios.log',
    'historical_ios_progress_ready': '/tmp/sgplayer-progress-ready-ios.log',
    'historical_macos_tracking_locked': '/tmp/sgplayer-tracking-ui-macos.log',
    'macos_controls_complete': '/tmp/sgplayer-controls-complete-ui-macos.log',
    'ios_controls_complete': '/tmp/sgplayer-controls-complete-ui-ios.log',
    'tvos_controls_complete': '/tmp/sgplayer-controls-complete-ui-tvos.log',
    'original_demos_macos': '/tmp/sgplayer-original-demos-macos.log',
    'original_demos_ios': '/tmp/sgplayer-original-demos-ios.log',
    'original_demos_tvos': '/tmp/sgplayer-original-demos-tvos.log',
    'swift_tvos_build': '/tmp/sgplayer-controls-swift-tvos-build.log',
    'macos_keyboard': '/tmp/sgplayer-keyboard-final-ui-macos.log',
    'historical_macos_keyboard_ime': '/tmp/sgplayer-keyboard-focus-corrected-ui-macos.log',
    'macos_gif_isolated': '/tmp/sgplayer-gif-isolated-output-ui-macos.log',
    'historical_macos_gif_stack': '/tmp/sgplayer-gif-ui-stack.txt',
    'historical_macos_gif_repro': '/tmp/sgplayer-gif-isolated-ui-macos.log',
    'historical_macos_publication_attempt': '/tmp/sgplayer-gif-fixed-ui-macos.log',
    'historical_macos_gif_timeout': '/tmp/sgplayer-transcode-initial-ui-macos.log',
    'historical_ios_mpeg4_native_rejection': '/tmp/sgplayer-transcode-ui-ios.log',
    'historical_tvos_mpeg4_native_rejection': '/tmp/sgplayer-transcode-ui-tvos.log',
    'historical_sar_pixel_failure': '/tmp/sgplayer-transcode-sar-repro.log',
    'incremental_changed': '/tmp/sgplayer-link-stamp-changed.log',
    'incremental_unchanged': '/tmp/sgplayer-link-stamp-unchanged.log',
}
ui_names = ['macos_tracking', 'ios_progress_position', 'macos_audio_export', 'ios_audio_export', 'tvos_audio_export', 'ios_tracking', 'ios_tracking_held', 'macos_controls_complete', 'ios_controls_complete', 'tvos_controls_complete', 'macos_keyboard', 'macos_gif_isolated', 'macos_complete_with_transcode', 'macos_ui', 'ios_ui', 'tvos_ui', 'ios_touch', 'ios_cover_and_touch', 'tvos_cover', 'ios_transcode', 'tvos_transcode', 'ios_complete_with_transcode', 'tvos_complete_with_transcode']
record = {'client_date': args.date, 'timezone': 'Asia/Shanghai',
          'overall_scope': 'incomplete-see-bilingual-implementation-ledger',
          'physical_iphone': {'status': 'pending', 'planned_connection_date': '2026-10-26'},
          'logs': {}, 'ui': {}}
for name, source in logs.items():
    path = Path(source)
    if not path.exists():
        record['logs'][name] = {'status': 'missing'}
        continue
    target = artifacts / f'{name}.log'
    shutil.copy2(path, target)
    record['logs'][name] = str(target.relative_to(ROOT))
    if name in ui_names:
        text = path.read_text(errors='replace')
        cases = [dict(case=m[0], status=m[1]) for m in re.findall(r"Test Case '-\[SGFeatureUITests (\w+)\]' (passed|failed|skipped)", text)]
        results = re.findall(r'\t(/[^\n]+\.xcresult)', text)
        record['ui'][name] = dict(suite_succeeded='** TEST SUCCEEDED **' in text, cases=cases,
            passed=sum(c['status']=='passed' for c in cases), skipped=sum(c['status']=='skipped' for c in cases),
            failed=sum(c['status']=='failed' for c in cases), xcresult=results[-1] if results else None)
for name, path in {
    'original_demos_macos': 'build/RuntimeMac/runtime-result.json',
    'original_demos_ios': 'build/RuntimeIOS/runtime-result.json',
    'original_demos_tvos': 'build/RuntimeTV/runtime-result.json',
    'original_status_macos': 'build/RuntimeMac/runtime-status.json',
    'original_status_ios': 'build/RuntimeIOS/runtime-status.json',
    'original_status_tvos': 'build/RuntimeTV/runtime-status.json',
    'simulator_exports': 'build/feature-expansion-artifacts/simulator-export-results.json',
    'simulator_audio': 'build/feature-expansion-artifacts/simulator-audio-results.json',
    'audio_only': 'build/tests-asan/features/audio-only-validation.json',
    'ios_held_progress': 'build/feature-expansion-artifacts/ios-progress-during-hold.json',
    'transcode': 'build/tests-asan/features/transcode-validation.json',
    'build_matrix': 'build/verification/xcode-27.1/results.json',
    'demo_linkage': 'build/VerificationDerivedData/demo/linkage-verification.json',
    'package': 'build/Package/build-report.json',
    'swift_real_app': 'build/SwiftUISmoke/results.json',
    'swift_last_preserved_pass': 'build/SwiftUISmoke/last-passed.json',
    'hls_real_app': 'build/hls-verification/results.json',
    'baseline_artifact_hashes': 'build/feature-expansion-artifacts/baseline-artifact-hashes.json',
}.items():
    file = ROOT / path
    record[name] = json.loads(file.read_text()) if file.exists() else None
def read_log(name):
    path = Path(logs[name])
    return path.read_text(errors='replace') if path.exists() else ''
export_cases = [case for cases in (record['simulator_exports'] or {}).values() for case in cases]
audio_cases = [case for cases in (record.get('simulator_audio') or {}).values() for case in cases]
record['checks'] = {
    'simulator_audio': len(audio_cases)==4 and all(c.get('passed') and c.get('includeVideo') is False and c.get('videoFrames')==0 and c.get('audioSamples',0)>0 for c in audio_cases),
    'simulator_exports': len(export_cases)==4 and all(c.get('passed') and c.get('videoCodec')==1 and c.get('videoFrames',0)>=5 and c.get('audioSamples',0)>0 for c in export_cases),
    'macos_latest_full_ui': bool(record['ui'].get('macos_complete_with_transcode', {}).get('suite_succeeded')),
    'macos_ui_build': '** TEST BUILD SUCCEEDED **' in read_log('macos_ui_build'),
    'transcode': bool(record['transcode'] and record['transcode'].get('passed')) and 'PASS effect export snapshots' in read_log('data_asan'),
    'data_asan': 'PASS FFmpeg 9.0.2 migration regression suite' in read_log('data_asan'),
    'cache': 'PASS cache download/quota/pins/LRU/checksum' in read_log('cache'),
    'hls': bool(record['hls_real_app'] and record['hls_real_app'].get('passed')),
    'swift_real_app': bool(record['swift_real_app'] and record['swift_real_app'].get('passed') and record['package'] and record['swift_real_app'].get('package_framework_sha256') == record['package'].get('framework_sha256', {}).get('macosx')),
    'swift_package_tests': bool(re.search(r'Executed 3 tests, with 0 failures', read_log('swift_tests'))),
    'swift_tvos_cross_build': 'Build complete!' in read_log('swift_tvos_build'),
    'swift_ios_cross_build': 'Build complete!' in read_log('swift_ios_build'),
    'build_matrix': len(record['build_matrix'] or []) == 20 and all(x['exit_code']==0 for x in record['build_matrix']),
    'demo_linkage': bool(record['demo_linkage'] and record['demo_linkage'].get('passed') and len(record['demo_linkage']['checks'])==10),
    'package': 'Package ready:' in read_log('package'),
    'macos_tracking_foreground': '** TEST SUCCEEDED **' in read_log('macos_tracking'),
    'audio_only': bool(record.get('audio_only') and record['audio_only'].get('passed')) and 'PASS audio-only AAC' in read_log('data_asan'),
    'ios_tracking_targeted': bool(record['ui'].get('ios_tracking', {}).get('suite_succeeded')),
    'incremental_relink': bool(re.search(r'^Ld .*SGPlayer.app/SGPlayer ', read_log('incremental_changed'), re.MULTILINE)) and '** BUILD SUCCEEDED **' in read_log('incremental_unchanged') and not re.search(r'^Ld ', read_log('incremental_unchanged'), re.MULTILINE),
}
for platform in ['macos', 'ios', 'tvos']:
    result, state = record['original_demos_'+platform], record['original_status_'+platform]
    record['checks']['original_demos_'+platform] = bool(result and state and state.get('passed') and result.get('runID')==state.get('runID') and result.get('passed') and len(result.get('cases', []))==7 and result.get('artifactValidation', {}).get('embedded_framework_matches'))
record['batch_validation_passed'] = all(record['checks'].values()) and all(x['suite_succeeded'] and x['failed']==0 for x in record['ui'].values()) and len(record['ui'])==len(ui_names)
files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
selected = [f for f in files if f and (f.startswith(('SGPlayer/Classes/', 'Swift/', 'tests/', 'scripts/', 'packaging/', 'demo/')) or f.endswith('project.pbxproj')) and Path(f).suffix in ('.h', '.m', '.c', '.swift', '.py', '.json', '.pbxproj') and (ROOT/f).is_file()]
record['macos_ui_outputs'] = []
root_temp = Path(tempfile.gettempdir()).resolve()
for source in sorted(set(re.findall(r'SGPLAYER_UI_OUTPUT=(/[^\r\n]*?/SGPlayerUI-[0-9A-Fa-f-]{36})', read_log('macos_controls_complete') + read_log('macos_audio_export')))):
    folder = Path(source.strip())
    if folder.parent.resolve()!=root_temp or not folder.name.startswith('SGPlayerUI-') or not folder.is_dir():
        continue
    target = artifacts/'macos-ui-outputs'/folder.name
    shutil.copytree(folder, target, dirs_exist_ok=True, symlinks=True)
    record['macos_ui_outputs'].append(str(target.relative_to(ROOT)))
record['macos_transcode_reports'] = [json.loads(path.read_text()) for relative in record['macos_ui_outputs'] for path in sorted((ROOT/relative).glob('transcode-demo-*.json'))]
record['macos_audio_reports'] = [json.loads(path.read_text()) for relative in record['macos_ui_outputs'] for path in sorted((ROOT/relative).glob('audio-demo-*.json'))]
record['transcode_artifacts'] = {str(path.relative_to(ROOT)): dict(bytes=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for path in sorted((ROOT/'build/tests-asan/features').glob('*transcod*.*')) if path.suffix in ['.mkv','.mp4','.ts']}
console = subprocess.check_output(['ioreg', '-n', 'Root', '-d', '1'], text=True)
record['macos_foreground_prerequisite'] = 'screen-locked' if '"CGSSessionScreenIsLocked"=Yes' in console else 'desktop-unlocked'
record['current_ui_artifact_hashes'] = {}
for platform, relative in [('macos', 'build/ExpansionUIMac/Build/Products/Debug'), ('ios', 'build/ExpansionUIIOS/Build/Products/Debug-iphonesimulator'), ('tvos', 'build/ExpansionUITV/Build/Products/Debug-appletvsimulator')]:
    products = ROOT / relative
    archive = products/'SGPlayer.framework/SGPlayer'
    executable = products/('SGPlayer.app/Contents/MacOS/SGPlayer' if platform=='macos' else 'SGPlayer.app/SGPlayer')
    if archive.is_file() and executable.is_file():
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        record['current_ui_artifact_hashes'][platform] = dict(archive_sha256=digest, executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(), embedded_framework_matches=digest.encode() in executable.read_bytes())
record['source_snapshot_sha256'] = {f: hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in sorted(selected)}
record['source_snapshot_digest'] = hashlib.sha256(json.dumps(record['source_snapshot_sha256'], sort_keys=True).encode()).hexdigest()
record['limits'] = [
    'Passing batch tests do not mean the union of requested features is implemented.',
    'Unsupported simulator PiP skips do not replace supported physical-device start/background/restore acceptance.',
    'The complete UI suites precede the additional iPhone touch test; the latter is recorded separately.',
    'Baseline UI archive/executable hashes were captured before rebuilding the iPhone touch test.',
    'Swift package XCTest drives Metal explicitly; the separate unlocked real app verifies default automatic rendering.',
    'Native ABR preferences are validated against real AVPlayerItem properties; variant transitions/adverse-network behavior remain pending.',
    'The new complete simulator UI suites include H.264/AAC exports; their binaries precede the isolated SAR correction, which has decoded-pixel ASan and cross-SDK build acceptance.',
    'Historical MPEG-4 native-playback rejection and SAR-pixel failure are preserved as diagnostics, not passing acceptance.',
    'Mac keyboard UI uses ABC for deterministic text-key injection and restores the original input source; other IME composition behaviors are not accepted by that result.',
    'The current complete control suites include Mac keyboard/auto-hide, tvOS remote auto-hide and iPhone touch controls; earlier batch runs are preserved separately.',
    'Historical Desktop GIF replacement stalls are unresolved outside isolated test output; private-directory success does not establish every protected-directory/cross-signature overwrite scenario.',
    'The new long-tracking and progress adjustment fixes have separate targeted acceptance; Mac foreground progress acceptance passed after unlocking; historical locked runs remain diagnostic evidence.',
    'XCTest slider adjustment is best effort: assertions compare the actual final thumb position to the media clock; physical VoiceOver remains unaccepted.',
    'Audio-only exports and video-export regression have separate two-kernel targeted UI runs on Mac/iPhone simulator/tvOS simulator; the earlier complete suites precede this addition.',
    'Audio UI binaries precede only the unused-video-budget guard; its invalid-video-settings boundary passed final ASan and cross-SDK builds.',
    'Source snapshot describes the current workspace; individual tested binary revisions are recorded separately.',
]
output = ROOT / 'documents/feature-expansion-validation.json'
output.write_text(json.dumps(record, indent=2, ensure_ascii=False) + '\n')
print(output)

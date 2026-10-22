#!/usr/bin/env python3
"""Build the pinned ASS/font stack for the same Apple slices as FFmpeg."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys

ROOT=Path(__file__).resolve().parent.parent
BASE=ROOT/'build/subtitle-deps'
TOOLS=ROOT/'build/feature-tools/bin'
SLICES={
 'macOS':[('macosx','arm64','arm64-apple-macos12.0'),('macosx','x86_64','x86_64-apple-macos12.0')],
 'iOS':[('iphoneos','arm64','arm64-apple-ios15.0'),('iphonesimulator','arm64','arm64-apple-ios15.0-simulator'),('iphonesimulator','x86_64','x86_64-apple-ios15.0-simulator')],
 'tvOS':[('appletvos','arm64','arm64-apple-tvos15.0'),('appletvsimulator','arm64','arm64-apple-tvos15.0-simulator'),('appletvsimulator','x86_64','x86_64-apple-tvos15.0-simulator')]}
PACKAGES={
 'freetype':['-Dbrotli=disabled','-Dbzip2=disabled','-Dharfbuzz=disabled','-Dpng=disabled','-Dzlib=internal','-Dtests=disabled'],
 'fribidi':['-Ddocs=false','-Dbin=false','-Dtests=false'],
 'harfbuzz':['-Dglib=disabled','-Dgobject=disabled','-Dcairo=disabled','-Dicu=disabled','-Dgraphite2=disabled','-Dfreetype=enabled','-Dtests=disabled','-Dutilities=disabled','-Ddocs=disabled'],
 'libass':['-Dfontconfig=disabled','-Ddirectwrite=disabled','-Dcoretext=enabled','-Dasm=disabled','-Dlibunibreak=disabled','-Dtest=disabled','-Dcompare=disabled','-Dprofile=disabled','-Dfuzz=disabled','-Dcheckasm=disabled']}
LIBS=['libass.a','libharfbuzz.a','libfreetype.a','libfribidi.a']
def output(command):return subprocess.check_output(command,text=True).strip()
def prepare_sources():
 if not (TOOLS/'meson').exists():
  subprocess.run([sys.executable,'-m','venv',str(TOOLS.parent)],check=True)
  subprocess.run([str(TOOLS/'python'),'-m','pip','install','-r',str(ROOT/'scripts/feature-build-requirements.txt')],check=True)
 specs=json.loads((ROOT/'scripts/subtitle-sources.json').read_text())
 for spec in specs:
  archive=BASE/'downloads'/spec['filename'];archive.parent.mkdir(parents=True,exist_ok=True)
  if not archive.exists():
   temporary=archive.with_suffix(archive.suffix+'.partial')
   subprocess.run(['curl','--fail','--location','--retry','2','--output',str(temporary),spec['url']],check=True)
   temporary.replace(archive)
  if hashlib.sha256(archive.read_bytes()).hexdigest()!=spec['sha256']:
   raise SystemExit('Subtitle dependency checksum mismatch: '+str(archive))
  destination=BASE/'source'/spec['name']
  if not destination.exists():
   destination.parent.mkdir(parents=True,exist_ok=True)
   with tempfile.TemporaryDirectory(dir=destination.parent) as temp:
    subprocess.run(['tar','-xf',str(archive),'-C',temp],check=True)
    entries=list(Path(temp).iterdir())
    if len(entries)!=1 or not entries[0].is_dir():raise SystemExit('Unexpected source archive layout')
    entries[0].rename(destination)

def build_slice(spec,packages,jobs):
 sdk,arch,target=spec
 directory=BASE/sdk/arch;directory.mkdir(parents=True,exist_ok=True)
 prefix=directory/'output'
 sdkpath=output(['xcrun','--sdk',sdk,'--show-sdk-path'])
 cc=output(['xcrun','--sdk',sdk,'--find','clang'])
 cxx=output(['xcrun','--sdk',sdk,'--find','clang++'])
 flags=['-target',target,'-isysroot',sdkpath]
 machine=directory/'cross.ini'
 machine.write_text("[binaries]\nc = "+repr(cc)+"\ncpp = "+repr(cxx)+"\nar = 'ar'\nstrip = 'strip'\npkg-config = "+repr(shutil.which('pkg-config'))+"\n[host_machine]\nsystem = 'darwin'\ncpu_family = "+repr('aarch64' if arch=='arm64' else 'x86_64')+"\ncpu = "+repr(arch)+"\nendian = 'little'\n[properties]\nneeds_exe_wrapper = true\n[built-in options]\nc_args = "+repr(flags)+"\ncpp_args = "+repr(flags)+"\nc_link_args = "+repr(flags)+"\ncpp_link_args = "+repr(flags)+"\n")
 env=os.environ.copy();env['PATH']=str(TOOLS)+os.pathsep+env['PATH'];env['PKG_CONFIG_LIBDIR']=str(prefix/'lib/pkgconfig');env['PKG_CONFIG_PATH']=''
 for package in packages:
  build=directory/package
  digest=hashlib.sha256((machine.read_text()+repr(PACKAGES[package])+(ROOT/'scripts/subtitle-sources.json').read_text()+(ROOT/'scripts/feature-build-requirements.txt').read_text()+output(['xcodebuild','-version'])).encode()).hexdigest()
  stamp=build/'sgplayer-inputs'
  with (directory/(package+'.log')).open('w') as log:
   if not (build/'build.ninja').exists() or not stamp.exists() or stamp.read_text()!=digest:
    command=[str(TOOLS/'meson'),'setup',str(build),str(BASE/'source'/package),'--cross-file',str(machine),'--prefix',str(prefix),'--libdir','lib','--buildtype','release','--default-library','static','--wrap-mode','nofallback',*PACKAGES[package]]
    if (build/'meson-private/coredata.dat').exists():command.append('--wipe')
    subprocess.run(command,env=env,check=True,stdout=log,stderr=subprocess.STDOUT)
    stamp.write_text(digest)
   subprocess.run([str(TOOLS/'ninja'),'-C',str(build),'-j',str(jobs),'install'],env=env,check=True,stdout=log,stderr=subprocess.STDOUT)
  print(f'PASS {sdk}/{arch} {package}',flush=True)
 return prefix

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('platform',choices=[*SLICES,'all']);parser.add_argument('action',nargs='?',choices=['build','clean'],default='build');parser.add_argument('--packages',default=','.join(PACKAGES));parser.add_argument('--jobs',type=int,default=4);args=parser.parse_args()
 packages=args.packages.split(',')
 for package in packages:
  if package not in PACKAGES:parser.error('Unknown package: '+package)
 if args.action=='clean':
  for platform in (list(SLICES) if args.platform=='all' else [args.platform]):
   for sdk,arch,target in SLICES[platform]:shutil.rmtree(BASE/sdk/arch,ignore_errors=True)
  return
 for tool in ['xcrun','xcodebuild','curl','tar','pkg-config']:
  if not shutil.which(tool):parser.error('Required tool not found: '+tool+' (install pkg-config before building subtitles)')
 if args.jobs<1:parser.error('--jobs must be positive')
 font=json.loads((ROOT/'scripts/subtitle-font.json').read_text())
 font_path=ROOT/font['file']
 if not font_path.is_file() or hashlib.sha256(font_path.read_bytes()).hexdigest()!=font['sha256']:
  parser.error('Bundled subtitle font missing or checksum mismatch: '+str(font_path))
 prepare_sources()
 platforms=list(SLICES) if args.platform=='all' else [args.platform]
 for platform in platforms:
  specs=SLICES[platform]
  with ThreadPoolExecutor(max_workers=2) as pool:prefixes=list(pool.map(lambda spec:build_slice(spec,packages,args.jobs),specs))
  if packages!=list(PACKAGES):continue
  for variant in ['universal','simulator']:
   sources=[prefix for spec,prefix in zip(specs,prefixes) if ('simulator' in spec[0])==(variant=='simulator')]
   if not sources:continue
   destination=ROOT/'build/libs'/platform/variant
   shutil.copytree(sources[0]/'include',destination/'include',dirs_exist_ok=True)
   (destination/'lib').mkdir(parents=True,exist_ok=True)
   for library in LIBS:subprocess.run(['xcrun','lipo','-create',*[str(p/'lib'/library) for p in sources],'-output',str(destination/'lib'/library)],check=True)
   print(f'PASS package {platform}/{variant}',flush=True)
if __name__=='__main__':main()

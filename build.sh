#!/bin/sh
set -eu
cd "$(dirname "$0")"
python3 scripts/build-ffmpeg.py "$@"
exec python3 scripts/build-subtitles.py "$@"

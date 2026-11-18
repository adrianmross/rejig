#!/usr/bin/env bash
# Films the launch clips: reel/build.sh. Needs reel on PATH, Rejig running and
# the screen unlocked. The windows filmed are Rejig's practice windows on its
# agent screen; nothing of yours is in the picture or moved.
cd "$(dirname "$0")" || exit 1
./w start && reel build "$@" launch.json
status=$?
./w end
exit $status

#!/usr/bin/env bash
# Runs the window commands against a practice window of the running app and
# checks each one did something: `make smoke`. It moves only that window.
set -u
fail=0
frame() { rejig list-windows | python3 -c "
import json,sys
w=[w for w in json.load(sys.stdin) if w['id']==$1]
print(w[0]['state'], w[0]['frame']['x'], w[0]['frame']['y'], w[0]['frame']['w'], w[0]['frame']['h']) if w else print('gone')"; }
rejig practice close  # one practice window only: two at the same frame can't be told apart
id=$(rejig practice) || exit 1
sleep 1.5
check() { # check <what it should change: frame|state|none> <command...>
  local want=$1; shift
  local before after
  before=$(frame "$id")
  if ! out=$(rejig "$@" --window-id "$id" 2>&1); then echo "FAIL  $*: $out"; fail=1; return; fi
  sleep 0.6
  after=$(frame "$id")
  if [ "$want" != none ] && [ "$before" = "$after" ]; then echo "FAIL  $*: nothing changed ($after)"; fail=1; else echo "ok    $*"; fi
}
check frame move left
check frame move right
check frame snap top-left
check frame snap center
check frame snap restore
check frame fullscreen
check frame fullscreen
check frame move --frame 300,200,500,320
check state layout floating tiling
check state layout floating tiling
check state hold --by smoke
check state release
check none focus right
for q in list-windows list-workspaces api; do rejig $q >/dev/null 2>&1 && echo "ok    $q" || { echo "FAIL  $q"; fail=1; }; done
rejig bogus >/dev/null 2>&1 && { echo "FAIL  an unknown command was accepted"; fail=1; } || echo "ok    unknown command refused"
rejig practice close
exit $fail

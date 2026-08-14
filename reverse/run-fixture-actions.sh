#!/bin/zsh
set -euo pipefail

fixture=${1:-"${0:A:h:h}/dist/Open History Fixture.app"}
driver="$fixture/Contents/MacOS/Open History Fixture Driver"

osascript -e 'tell application "Open History Fixture" to quit' \
  >/dev/null 2>&1 || true
sleep 1
open "$fixture"
sleep 2
osascript -e 'tell application "Open History Fixture" to activate'
sleep 1
"$driver"

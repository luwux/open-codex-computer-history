#!/bin/zsh
# Alternates Chromium/Electron AX mode off/on for one app and reports
# proc_pid_rusage energy / CPU / wakeups / footprint medians per mode.
# AX mode is always restored to off at the end.
#
#   scripts/perf/ax-mode-energy.sh --bundle com.anthropic.claudefordesktop --windows 4 --seconds 60 --probe
#   scripts/perf/ax-mode-energy.sh --bundle com.google.Chrome --attrs eui --windows 4 --seconds 60
#
# Needs Accessibility permission for the terminal. See
# docs/perf/chromium-ax-mode.md for interpretation and caveats.
set -euo pipefail
here=${0:A:h}
bin=${TMPDIR:-/tmp}/ax-mode-energy
if [[ ! -x $bin || $here/ax-mode-energy.swift -nt $bin ]]; then
  swiftc -O "$here/ax-mode-energy.swift" -o "$bin"
fi
exec "$bin" "$@"

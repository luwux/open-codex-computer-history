#!/bin/zsh
# Measures the recorder's per-event accessibility cost against a deterministic
# target (the repo's fixture app with a long, mailbox-like list) and,
# optionally, real apps given by bundle id.
#
#   scripts/perf-bench.sh [--json] [--iterations N] [--rows N] [bundle-id ...]
#
# Needs Accessibility permission for the terminal running it. The fixture is
# launched in the background (no focus change) and quit afterwards. With
# --json, results are written to docs/perf-results/<UTC timestamp>.json.
set -euo pipefail

root=${0:A:h:h}
iterations=10
rows=2000
write_json=0
targets=()
while (( $# )); do
  case $1 in
    --json) write_json=1 ;;
    --iterations) iterations=$2; shift ;;
    --rows) rows=$2; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) targets+=("$1") ;;
  esac
  shift
done

scratch=${OPEN_HISTORY_PERF_SCRATCH:-"$root/collector/.build"}
work=$(mktemp -d -t open-history-perf)
fixture_pid=""
cleanup() {
  [[ -n $fixture_pid ]] && kill "$fixture_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "Building release binaries..."
swift build -c release --package-path "$root/collector" --scratch-path "$scratch" \
  --product open-history >/dev/null
swift build -c release --package-path "$root/collector" --scratch-path "$scratch" \
  --product open-history-fixture >/dev/null
bin="$scratch/release"

fixture_id=dev.opencomputerhistory.fixture.perf
app="$work/Open History Perf Fixture.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/open-history-fixture" "$app/Contents/MacOS/Open History Perf Fixture"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Open History Perf Fixture</string>
  <key>CFBundleIdentifier</key><string>$fixture_id</string>
  <key>CFBundleName</key><string>Open History Perf Fixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1

echo "Launching fixture with $rows list rows (background)..."
open -g -n -F --env "OPEN_HISTORY_FIXTURE_ROWS=$rows" "$app"
for _ in {1..50}; do
  fixture_pid=$(pgrep -f "$app/Contents/MacOS/" | head -1 || true)
  [[ -n $fixture_pid ]] && break
  sleep 0.2
done
[[ -n $fixture_pid ]] || { echo "Fixture did not start." >&2; exit 1; }
sleep 2

results=()
run() {
  local target=$1 label=$2
  echo "\n== $label"
  local out="$work/$label.json"
  if "$bin/open-history" bench "$target" "$iterations" --json "$out"; then
    results+=("$out")
  else
    echo "(skipped: $target is not running)"
  fi
}

run "pid:$fixture_pid" fixture
for target in "${targets[@]}"; do
  run "$target" "$target"
done

if (( write_json )); then
  mkdir -p "$root/docs/perf-results"
  stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
  dest="$root/docs/perf-results/$stamp.json"
  /usr/bin/python3 - "$dest" "$rows" "${results[@]}" <<'PY'
import json, platform, subprocess, sys
dest, rows, files = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
reports = [json.load(open(f)) for f in files]
for report in reports:
    if report["target"].startswith("pid:"):
        report["target"] = f"fixture ({rows} rows)"
commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                        capture_output=True, text=True).stdout.strip()
json.dump({"commit": commit, "machine": platform.machine(),
           "macOS": platform.mac_ver()[0], "results": reports},
          open(dest, "w"), indent=2, sort_keys=True)
print(f"\nWrote {dest}")
PY
fi

#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
output_dir=${1:-"$project_root/reverse/evidence"}
installed_app="$HOME/.codex/computer-use/Codex Computer Use.app"
bundled_app="/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app"

if [[ -d "$installed_app" ]]; then
  app="$installed_app"
elif [[ -d "$bundled_app" ]]; then
  app="$bundled_app"
else
  print -u2 "Codex Computer Use.app was not found."
  exit 1
fi

binary="$app/Contents/MacOS/SkyComputerUseService"
mkdir -p "$output_dir"

plutil -convert json -o "$output_dir/info.json" "$app/Contents/Info.plist"
codesign -d --entitlements :- "$app" 2>"$output_dir/entitlements.plist" || true
nm -arch arm64 -j "$binary" 2>/dev/null |
  xcrun swift-demangle >"$output_dir/swift-symbols.txt"
strings -a "$binary" >"$output_dir/strings.txt"

rg '^ComputerUse\.(EventStream|Skysight)|^ComputerUseClient\.ComputerUseIPC(Skysight|EventStream)' \
  "$output_dir/swift-symbols.txt" >"$output_dir/recovered-api.txt"
rg -n 'computer_history_|session\.started|window\.changed|mouse\.|keyboard\.|selection\.changed|terminal\.value_changed|debug\.error' \
  "$output_dir/strings.txt" >"$output_dir/recovered-constants.txt"

node "$project_root/reverse/original-ipc.mjs" snapshot >"$output_dir/ipc-snapshot.json"

print "Evidence written to $output_dir"

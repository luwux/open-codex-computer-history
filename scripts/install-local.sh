#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
app_source="$root/dist/Open Computer History.app"
install_root="$HOME/.local/share"
app_target="$install_root/Open Computer History.app"
launch_agents="$HOME/Library/LaunchAgents"
logs="$HOME/Library/Logs/OpenComputerHistory"
node_bin=$(command -v node)
mcp_use_bin="$root/node_modules/.bin/mcp-use"
uid=$(id -u)

npm --prefix "$root" install
npm --prefix "$root" run build
"$root/scripts/package-macos-app.sh" release >/dev/null

mkdir -p "$install_root" "$launch_agents" "$logs"
rm -rf "$app_target"
ditto "$app_source" "$app_target"

write_agent() {
  local label=$1
  local working_directory=$2
  shift 2
  local plist="$launch_agents/$label.plist"
  {
    print '<?xml version="1.0" encoding="UTF-8"?>'
    print '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    print '<plist version="1.0"><dict>'
    print '<key>Label</key><string>'"$label"'</string>'
    print '<key>ProgramArguments</key><array>'
    for argument in "$@"; do
      print '<string>'"${argument//&/&amp;}"'</string>'
    done
    print '</array>'
    print '<key>WorkingDirectory</key><string>'"$working_directory"'</string>'
    print '<key>RunAtLoad</key><true/>'
    print '<key>KeepAlive</key><true/>'
    print '<key>EnvironmentVariables</key><dict>'
    print '<key>HOME</key><string>'"$HOME"'</string>'
    print '<key>OPEN_COMPUTER_HISTORY_HOME</key><string>'"$HOME/.open-codex-computer-history"'</string>'
    print '<key>PATH</key><string>'"${node_bin:h}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"'</string>'
    print '</dict>'
    print '<key>StandardOutPath</key><string>'"$logs/$label.out.log"'</string>'
    print '<key>StandardErrorPath</key><string>'"$logs/$label.err.log"'</string>'
    print '</dict></plist>'
  } >"$plist"
  launchctl bootout "gui/$uid" "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/$uid" "$plist"
}

write_agent \
  dev.opencomputerhistory.menu \
  "$HOME" \
  "$app_target/Contents/MacOS/Open Computer History"

write_agent \
  dev.opencomputerhistory.ipc \
  "$root" \
  "$node_bin" --import tsx "$root/scripts/native-ipc.ts"

write_agent \
  dev.opencomputerhistory.pipeline \
  "$root" \
  "$node_bin" --import tsx "$root/scripts/pipeline.ts" run

write_agent \
  dev.opencomputerhistory.mcp \
  "$root" \
  "$mcp_use_bin" start --host 127.0.0.1 --port 3317 --path "$root"

print "Installed Open Computer History."
print "MCP endpoint: http://127.0.0.1:3317/mcp"
print "Grant Accessibility and Input Monitoring to:"
print "$app_target"

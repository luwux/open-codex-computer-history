#!/bin/zsh
set -euo pipefail

uid=$(id -u)
launch_agents="$HOME/Library/LaunchAgents"

for label in \
  dev.opencomputerhistory.menu \
  dev.opencomputerhistory.ipc \
  dev.opencomputerhistory.pipeline \
  dev.opencomputerhistory.mcp
do
  plist="$launch_agents/$label.plist"
  launchctl bootout "gui/$uid" "$plist" 2>/dev/null || true
  rm -f "$plist"
done

rm -rf "$HOME/.local/share/Open Computer History.app"
print "Uninstalled Open Computer History services."
print "History data remains in $HOME/.open-codex-computer-history"

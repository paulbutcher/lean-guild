#!/usr/bin/env bash
# Copyright (c) 2026 Paul Butcher. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# On a Mac, install (or, with --remove, remove) the launchd job that runs scripts/backup.sh daily
# at 03:30, or when the Mac next wakes, with this deployment's KIT and KIT_ENV. Docker must be
# running then; if a backup fails you get a notification. Elsewhere it prints a crontab line.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
kit="$(pwd)"
log="$STATE_DIR/control/backup.log"
if [ "$(uname)" != Darwin ]; then
  echo "launchd is macOS's. Elsewhere, add this to your crontab (crontab -e):"
  echo "30 3 * * * KIT='$KIT' KIT_ENV='$KIT_ENV' KIT_NO_BUILD=1 '$kit/scripts/backup.sh' >> '$log' 2>&1"
  exit 1
fi
label="guild.$COMPOSE_PROJECT_NAME.backup"
plist="$HOME/Library/LaunchAgents/$label.plist"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
if [ "${1:-}" = --remove ]; then
  rm -f "$plist"
  echo "Removed the daily backup."
  exit 0
fi
mkdir -p "$HOME/Library/LaunchAgents" "$STATE_DIR/control"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>date; "$kit/scripts/backup.sh" || osascript -e 'display notification "The daily backup failed: see $log" with title "The guild: $COMPOSE_PROJECT_NAME"'</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$PATH</string>
    <key>KIT</key><string>$KIT</string>
    <key>KIT_ENV</key><string>$KIT_ENV</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "The kit backs up daily at 03:30 into ${BACKUP_DIR:-$STATE_DIR/backups}; its log is $log."

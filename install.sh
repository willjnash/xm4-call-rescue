#!/bin/zsh
# Builds xm4-call-rescue and installs it as a per-user LaunchAgent (starts at login).
# Usage: ./install.sh [--address AA:BB:CC:DD:EE:FF]   |   ./install.sh --uninstall
set -euo pipefail
LABEL=com.user.xm4-call-rescue
BIN="$HOME/.local/bin/xm4-call-rescue"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/xm4-call-rescue.log"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$PLIST" "$BIN"; echo "Uninstalled."; exit 0
fi

cd "${0:A:h}"
mkdir -p "${BIN:h}" "${PLIST:h}" "${LOG:h}"
swiftc -O main.swift -o "$BIN"

EXTRA=""
for a in "$@"; do EXTRA+="<string>$a</string>"; done
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string><string>-v</string>$EXTRA</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Installed. Logs: $LOG"

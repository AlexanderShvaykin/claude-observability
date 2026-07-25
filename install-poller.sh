#!/usr/bin/env bash
# Ставит poll-limits.sh на расписание: launchd на macOS, cron на Linux.
# Нужен там, где Claude Code запускают в headless-режиме (claude -p) — statusline
# в нём не работает, а значит лимиты подписки иначе собрать нечем.
#
#   ./install-poller.sh                  # каждые 10 минут
#   ./install-poller.sh --interval 30    # каждые 30 минут
#   ./install-poller.sh --uninstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL_MIN=10
UNINSTALL=0
LABEL="com.claude-observability.poll-limits"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CRON_MARK="# claude-observability poll-limits"

while [ $# -gt 0 ]; do
  case "$1" in
    --interval)  INTERVAL_MIN="$2"; shift ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ "$(uname -s)" = "Darwin" ]; then
  if [ "$UNINSTALL" = 1 ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "launchd-агент снят: $LABEL"
    exit 0
  fi

  mkdir -p "$(dirname "$PLIST")"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_DIR/poll-limits.sh</string>
  </array>
  <key>StartInterval</key><integer>$((INTERVAL_MIN * 60))</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/tmp/claude-obs-poller.log</string>
  <key>StandardErrorPath</key><string>/tmp/claude-obs-poller.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$PATH</string>
  </dict>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
  echo "launchd-агент установлен: $LABEL, каждые $INTERVAL_MIN мин"
  echo "  plist: $PLIST"
  echo "  лог:   /tmp/claude-obs-poller.log"
else
  CURRENT=$(crontab -l 2>/dev/null | grep -v "$CRON_MARK" || true)
  if [ "$UNINSTALL" = 1 ]; then
    printf '%s\n' "$CURRENT" | crontab -
    echo "cron-задание снято"
    exit 0
  fi
  { printf '%s\n' "$CURRENT"
    echo "*/$INTERVAL_MIN * * * * /bin/bash $SCRIPT_DIR/poll-limits.sh >>/tmp/claude-obs-poller.log 2>&1 $CRON_MARK"
  } | crontab -
  echo "cron-задание установлено: каждые $INTERVAL_MIN мин"
  echo "  лог: /tmp/claude-obs-poller.log"
fi

echo
echo "Проверить: дождаться следующего запуска и посмотреть stream claude_code_limits"
echo "с source = usage-cli, либо запустить вручную: $SCRIPT_DIR/poll-limits.sh"

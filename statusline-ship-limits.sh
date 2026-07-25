#!/usr/bin/env bash
# Statusline Claude Code + отправка лимитов подписки в мониторинг.
#
# Почему именно statusline: лимиты (rate_limits.five_hour / .seven_day) не приходят
# ни в OTel-телеметрию, ни в хуки — проверено, у хуков в payload только session_id,
# transcript_path, cwd, prompt и permission_mode. Единственный свежий источник —
# JSON, который Claude Code передаёт statusline-скрипту на stdin.
#
# Скрипт ничего не ломает на чужом хосте: он вызывает существующий statusline,
# если он есть, и печатает минимальную строку, если своего нет.
#
# Подключение (делается автоматически через ./install.sh):
#   "statusLine": { "type": "command", "command": "bash /path/to/statusline-ship-limits.sh" }
#
# Переменные окружения:
#   CLAUDE_OBS_STATUSLINE — команда исходного statusline (путь к скрипту или строка
#                           команды). По умолчанию ~/.claude/statusline-command.sh,
#                           если он существует. install.sh проставляет её сам,
#                           если на хосте уже был свой statusline.
#   остальные CLAUDE_OBS_* — см. ship-limits.sh

INPUT=$(cat)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE="${CLAUDE_OBS_STATUSLINE:-$HOME/.claude/statusline-command.sh}"

# 1. Отправка лимитов — в фоне, чтобы не задерживать отрисовку строки.
printf '%s' "$INPUT" | "$SCRIPT_DIR/ship-limits.sh" >/dev/null 2>&1 &

# 2. Отрисовка. Исходный statusline может быть как путём к скрипту, так и командой
#    с аргументами, поэтому запускаем через sh -c. Ведущую ~ разворачиваем сами —
#    иначе проверка существования файла не сработает.
STATUSLINE_PATH="${STATUSLINE/#\~/$HOME}"
if [ -n "$STATUSLINE" ] && [ -e "${STATUSLINE_PATH%% *}" ]; then
  printf '%s' "$INPUT" | sh -c "$STATUSLINE_PATH"
else
  printf '%s' "$INPUT" | jq -r '
    [(.model.display_name // "claude"),
     (if .rate_limits.five_hour then "5h:\(.rate_limits.five_hour.used_percentage | floor)%" else empty end),
     (if .context_window.used_percentage then "ctx:\(.context_window.used_percentage | floor)%" else empty end)]
    | join(" · ")'
fi

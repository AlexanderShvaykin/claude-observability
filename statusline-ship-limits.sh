#!/usr/bin/env bash
# Обёртка над statusline-скриптом Claude Code.
#
# Зачем: лимиты подписки (rate_limits) НЕ приходят в OTel-телеметрию Claude Code —
# единственное место, где они отдаются, это JSON на stdin у statusline-скрипта.
# Обёртка рисует обычный statusline и не чаще раза в минуту отправляет лимиты
# в OpenObserve (stream claude_code_limits).
#
# Подключается в ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "bash /path/to/statusline-ship-limits.sh" }
#
# Переменные окружения (все опциональны):
#   CLAUDE_OBS_STATUSLINE — свой statusline-скрипт (по умолчанию ~/.claude/statusline-command.sh)
#   CLAUDE_OBS_ENV        — файл с ZO_ROOT_USER_* (по умолчанию .env рядом с этим скриптом)
#   CLAUDE_OBS_ENDPOINT   — куда слать (по умолчанию локальный OpenObserve)
#   CLAUDE_OBS_INTERVAL   — минимальный интервал между отправками, сек (по умолчанию 60)

INPUT=$(cat)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE="${CLAUDE_OBS_STATUSLINE:-$HOME/.claude/statusline-command.sh}"
ENV_FILE="${CLAUDE_OBS_ENV:-$SCRIPT_DIR/.env}"
ENDPOINT="${CLAUDE_OBS_ENDPOINT:-http://localhost:5080/api/default/claude_code_limits/_json}"
INTERVAL="${CLAUDE_OBS_INTERVAL:-60}"

# Фиксированный путь, а не $TMPDIR: у разных сессий/терминалов TMPDIR свой,
# и троттлинг бы не работал между ними.
STAMP="/tmp/claude-code-limits-last-ship"

# 1. Обычный statusline — вывод не меняется. Если своего скрипта нет,
#    печатаем минимальную строку, чтобы statusline не был пустым.
if [ -x "$STATUSLINE" ]; then
  printf '%s' "$INPUT" | "$STATUSLINE"
else
  printf '%s' "$INPUT" | jq -r '
    [(.model.display_name // "claude"),
     (if .rate_limits.five_hour then "5h:\(.rate_limits.five_hour.used_percentage | floor)%" else empty end),
     (if .context_window.used_percentage then "ctx:\(.context_window.used_percentage | floor)%" else empty end)]
    | join(" · ")'
fi

# 2. Отгрузка лимитов в фоне, с троттлингом.
ship_limits() {
  local now last payload b64
  now=$(date +%s)
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  [ $((now - last)) -lt "$INTERVAL" ] && return 0

  payload=$(printf '%s' "$INPUT" | jq -c '
    select(.rate_limits != null) | [{
      five_hour_used:       .rate_limits.five_hour.used_percentage,
      five_hour_resets_at:  .rate_limits.five_hour.resets_at,
      seven_day_used:       .rate_limits.seven_day.used_percentage,
      seven_day_resets_at:  .rate_limits.seven_day.resets_at,
      session_id:           .session_id,
      model:                .model.display_name,
      version:              .version
    }]')
  [ -z "$payload" ] && return 0

  echo "$now" >"$STAMP"

  # shellcheck source=/dev/null
  . "$ENV_FILE" || return 0
  b64=$(printf '%s' "$ZO_ROOT_USER_EMAIL:$ZO_ROOT_USER_PASSWORD" | base64)

  curl -s -m 3 -o /dev/null -X POST \
    -H "Authorization: Basic $b64" -H 'Content-Type: application/json' \
    "$ENDPOINT" -d "$payload"
}

ship_limits >/dev/null 2>&1 &

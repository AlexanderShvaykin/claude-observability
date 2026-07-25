#!/usr/bin/env bash
# Транспорт: читает JSON statusline'а Claude Code со stdin и отправляет лимиты
# подписки (rate_limits) в OpenObserve, stream claude_code_limits.
#
# Ничего не печатает и ничего не знает про отрисовку статусной строки —
# подключается к любому statusline-скрипту (см. statusline-ship-limits.sh)
# или вызывается вручную:
#
#   echo "$JSON" | ./ship-limits.sh
#
# Переменные окружения (все опциональны):
#   CLAUDE_OBS_ENV      — файл с ZO_ROOT_USER_* (по умолчанию .env рядом со скриптом)
#   CLAUDE_OBS_ENDPOINT — куда слать (по умолчанию локальный OpenObserve)
#   CLAUDE_OBS_INTERVAL — минимальный интервал между отправками, сек (по умолчанию 60)
#   CLAUDE_OBS_STAMP    — файл-отметка троттлинга

INPUT=$(cat)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CLAUDE_OBS_ENV:-$SCRIPT_DIR/.env}"
ENDPOINT="${CLAUDE_OBS_ENDPOINT:-http://localhost:5080/api/default/claude_code_limits/_json}"
INTERVAL="${CLAUDE_OBS_INTERVAL:-60}"
# Фиксированный путь, а не $TMPDIR: у разных сессий и терминалов TMPDIR свой,
# и троттлинг бы не работал между ними.
STAMP="${CLAUDE_OBS_STAMP:-/tmp/claude-code-limits-last-ship}"

now=$(date +%s)
last=$(cat "$STAMP" 2>/dev/null || echo 0)
[ $((now - last)) -lt "$INTERVAL" ] && exit 0

payload=$(printf '%s' "$INPUT" | jq -c \
  --arg source "${CLAUDE_OBS_SOURCE:-statusline}" \
  --arg host "$(hostname -s 2>/dev/null || echo unknown)" '
  select(.rate_limits != null) | [{
    five_hour_used:       .rate_limits.five_hour.used_percentage,
    five_hour_resets_at:  .rate_limits.five_hour.resets_at,
    seven_day_used:       .rate_limits.seven_day.used_percentage,
    seven_day_resets_at:  .rate_limits.seven_day.resets_at,
    weekly_scoped_used:   .rate_limits.weekly_scoped.used_percentage,
    weekly_scoped_model:  .rate_limits.weekly_scoped.model,
    session_id:           .session_id,
    model:                .model.display_name,
    version:              .version,
    source:               $source,
    host:                 $host
  } | with_entries(select(.value != null))]' 2>/dev/null)
[ -z "$payload" ] && exit 0

echo "$now" >"$STAMP"

# shellcheck source=/dev/null
. "$ENV_FILE" 2>/dev/null || exit 0
b64=$(printf '%s' "$ZO_ROOT_USER_EMAIL:$ZO_ROOT_USER_PASSWORD" | base64)

curl -s -m 3 -o /dev/null -X POST \
  -H "Authorization: Basic $b64" -H 'Content-Type: application/json' \
  "$ENDPOINT" -d "$payload"

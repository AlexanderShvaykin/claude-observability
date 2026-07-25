#!/usr/bin/env bash
# Идемпотентная настройка Claude Code на отправку телеметрии в OpenObserve.
#
# Правит ~/.claude/settings.json через jq: добавляет env-блок телеметрии и
# подключает statusline-обёртку для сбора лимитов подписки. Существующие
# настройки сохраняются, прежний statusline не теряется — он прописывается
# в CLAUDE_OBS_STATUSLINE и вызывается обёрткой.
#
# Запускать можно повторно: результат не меняется.
#
#   ./install.sh                       # телеметрия + события + промпты + лимиты
#   ./install.sh --no-prompts          # без текстов промптов и ответов
#   ./install.sh --no-limits           # не трогать statusline
#   ./install.sh --base-url http://host:5080 --org default
#   CLAUDE_SETTINGS=/tmp/test.json ./install.sh    # прогон на копии настроек

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
BASE_URL="http://localhost:5080"
ORG="default"
LOG_PROMPTS=1
WIRE_LIMITS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-prompts) LOG_PROMPTS=0 ;;
    --no-limits)  WIRE_LIMITS=0 ;;
    --base-url)   BASE_URL="$2"; shift ;;
    --org)        ORG="$2"; shift ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
  shift
done

command -v jq >/dev/null || { echo "Нужен jq" >&2; exit 1; }
[ -f "$SCRIPT_DIR/.env" ] || { echo "Нет $SCRIPT_DIR/.env — скопируйте .env.example и задайте пароль" >&2; exit 1; }

# shellcheck source=/dev/null
set -a; . "$SCRIPT_DIR/.env"; set +a
B64=$(printf '%s' "$ZO_ROOT_USER_EMAIL:$ZO_ROOT_USER_PASSWORD" | base64)

WRAPPER="$SCRIPT_DIR/statusline-ship-limits.sh"
chmod +x "$WRAPPER" "$SCRIPT_DIR/ship-limits.sh" "$SCRIPT_DIR/import-dashboards.sh" 2>/dev/null || true

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || { echo "$SETTINGS не парсится как JSON" >&2; exit 1; }

BACKUP="$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BACKUP"

# Прежний statusline: сохраняем, если он был и это не наша обёртка.
PREV=""
if [ "$WIRE_LIMITS" = 1 ]; then
  PREV=$(jq -r '.statusLine.command // empty' "$SETTINGS")
  case "$PREV" in
    *statusline-ship-limits.sh*) PREV="" ;;   # уже подключено, ничего не сохраняем
  esac
fi

TMP=$(mktemp)
jq \
  --arg b64 "$B64" \
  --arg endpoint "$BASE_URL/api/$ORG" \
  --arg limits_endpoint "$BASE_URL/api/$ORG/claude_code_limits/_json" \
  --arg wrapper "$WRAPPER" \
  --arg prev "$PREV" \
  --argjson prompts "$LOG_PROMPTS" \
  --argjson limits "$WIRE_LIMITS" '
  .env = ((.env // {}) + {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": $endpoint,
    "OTEL_EXPORTER_OTLP_HEADERS": ("Authorization=Basic " + $b64 + ",stream-name=claude_code"),
    "OTEL_METRIC_EXPORT_INTERVAL": "10000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000"
  })
  | if $prompts == 1 then .env.OTEL_LOG_USER_PROMPTS = "1"
    else .env |= del(.OTEL_LOG_USER_PROMPTS) end
  | if $limits == 1 then
      .env.CLAUDE_OBS_ENDPOINT = $limits_endpoint
      | (if $prev != "" then .env.CLAUDE_OBS_STATUSLINE = $prev else . end)
      | .statusLine = { "type": "command", "command": ("bash " + $wrapper) }
    else . end
' "$SETTINGS" >"$TMP"

jq empty "$TMP" || { echo "Результат не парсится, настройки не тронуты (бэкап: $BACKUP)" >&2; rm -f "$TMP"; exit 1; }
mv "$TMP" "$SETTINGS"

echo "Настройки обновлены: $SETTINGS"
echo "  бэкап:      $BACKUP"
echo "  телеметрия: $BASE_URL/api/$ORG (события + метрики)"
echo "  промпты:    $([ "$LOG_PROMPTS" = 1 ] && echo 'пишутся в базу' || echo 'не пишутся')"
if [ "$WIRE_LIMITS" = 1 ]; then
  echo "  лимиты:     через statusline-обёртку"
  [ -n "$PREV" ] && echo "  прежний statusline сохранён в CLAUDE_OBS_STATUSLINE: $PREV"
else
  echo "  лимиты:     не подключены (--no-limits)"
fi
echo
echo "Переменные подхватят только НОВЫЕ сессии claude — текущие нужно перезапустить."

#!/usr/bin/env bash
# Опрос лимитов подписки без statusline — работает на любом хосте, в том числе там,
# где Claude Code запускают только в headless-режиме (claude -p).
#
# Как: `claude -p "/usage"` печатает лимиты текстом и в headless-режиме тоже.
# Скрипт парсит вывод, приводит его к тому же виду, что даёт statusline, и отдаёт
# в ship-limits.sh — то есть данные ложатся в тот же stream claude_code_limits,
# отличаясь только полем source (`usage-cli` вместо `statusline`).
#
# Запускать по расписанию (см. install-poller.sh). Запуск идёт из каталога poller/,
# где лежит .claude/settings.json с выключенной телеметрией — иначе каждый опрос
# создавал бы лишнюю «сессию» в метриках (проверено: project-level настройки
# перебивают пользовательские, а переменные окружения — нет).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_BIN="${CLAUDE_OBS_CLAUDE_BIN:-claude}"

command -v "$CLAUDE_BIN" >/dev/null || { echo "claude не найден в PATH" >&2; exit 1; }

USAGE_TEXT=$(cd "$SCRIPT_DIR/poller" && "$CLAUDE_BIN" -p "/usage" </dev/null 2>/dev/null)
[ -z "$USAGE_TEXT" ] && { echo "пустой ответ /usage" >&2; exit 1; }

JSON=$(printf '%s' "$USAGE_TEXT" | python3 "$SCRIPT_DIR/parse-usage.py") || exit 1
[ -z "$JSON" ] && { echo "не разобрал вывод /usage" >&2; exit 1; }

printf '%s' "$JSON" | CLAUDE_OBS_SOURCE=usage-cli \
  CLAUDE_OBS_STAMP="${CLAUDE_OBS_STAMP:-/tmp/claude-code-limits-last-poll}" \
  CLAUDE_OBS_INTERVAL="${CLAUDE_OBS_INTERVAL:-60}" \
  "$SCRIPT_DIR/ship-limits.sh"

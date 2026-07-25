#!/usr/bin/env bash
# Импорт дашбордов из dashboards/*.json в локальный OpenObserve.
# Каждый запуск создаёт НОВЫЙ дашборд (у API нет upsert по имени) — перед
# повторным импортом удалите старый в UI: Dashboards → ⋮ → Delete.
set -euo pipefail
cd "$(dirname "$0")"

set -a; . ./.env; set +a
B64=$(printf '%s' "$ZO_ROOT_USER_EMAIL:$ZO_ROOT_USER_PASSWORD" | base64)

for f in dashboards/*.json; do
  echo -n "$f -> "
  curl -s -o /dev/null -w '%{http_code}\n' \
    -X POST -H "Authorization: Basic $B64" -H 'Content-Type: application/json' \
    "http://localhost:5080/api/default/dashboards?folder=default" --data-binary "@$f"
done

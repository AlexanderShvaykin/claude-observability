# Claude Code → OpenObserve

Локальный OpenObserve, в который Claude Code пишет метрики и события напрямую по OTLP/HTTP.
Коллектор OpenTelemetry не нужен — OpenObserve сам является OTLP-приёмником.

## Запуск

```bash
cp .env.example .env      # и поменять пароль
docker compose up -d      # UI: http://localhost:5080
docker compose logs -f    # логи сервера
docker compose down       # остановить (данные остаются в ./data)
```

Учётка root'а — в `.env` (файл в `.gitignore`, пароль в открытом виде).
OpenObserve не стартует, если email без домена верхнего уровня или пароль слабее,
чем 8–128 символов с заглавной, строчной, цифрой и спецсимволом.

Развернуть то же самое на другом хосте: отдать агенту Claude Code промпт из
[`AGENT_SETUP.md`](AGENT_SETUP.md).

Данные лежат в `./data` (том хоста). Удалить всю историю: `docker compose down && rm -rf data`.

`ZO_TELEMETRY: "false"` в compose отключает отправку статистики самого OpenObserve наружу.

## Как настроен Claude Code

Блок `env` в `~/.claude/settings.json` (применяется ко всем проектам):

```json
"env": {
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:5080/api/default",
  "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Basic <base64(email:password)>,stream-name=claude_code",
  "OTEL_METRIC_EXPORT_INTERVAL": "10000",
  "OTEL_LOGS_EXPORT_INTERVAL": "5000",
  "OTEL_LOG_USER_PROMPTS": "1"
}
```

Детали:

- `OTEL_EXPORTER_OTLP_ENDPOINT` — база **без** завершающего слэша; SDK сам дописывает `/v1/metrics` и `/v1/logs`.
- `stream-name=claude_code` — куда складывать события; иначе они падают в общий stream `default`.
  На метрики не влияет: метрика = отдельный stream по своему имени.
- `OTEL_LOG_USER_PROMPTS=1` — **в базу пишется текст промптов** (поле `prompt`). Убрать эту строку,
  если такого не надо.
- Пересчитать заголовок при смене пароля:
  `printf '%s' "root@example.com:PASSWORD" | base64`
- Изменения подхватываются новыми сессиями `claude`, текущая работает со старым конфигом.

## Что собирается

Метрики (streams типа `metrics`):

| Stream | Что |
| --- | --- |
| `claude_code_session_count` | старты сессий |
| `claude_code_token_usage` | токены, разрез по `model` и `type` (input/output/cacheRead/cacheCreation) |
| `claude_code_cost_usage` | стоимость в USD |
| `claude_code_active_time_total` | активное время, сек |
| `claude_code_lines_of_code_count` | изменённые строки (появится после первой правки файла) |
| `claude_code_commit_count`, `claude_code_pull_request_count`, `claude_code_code_edit_tool_decision` | коммиты, PR, решения по разрешениям |

События (stream `claude_code`, тип logs), поле `event_name`:
`user_prompt`, `assistant_response`, `api_request`, `tool_result`, `tool_decision`,
`hook_execution_start/complete`, `mcp_server_connection`, `plugin_loaded`, `subagent_*` и др.

Общие атрибуты и там, и там: `session_id`, `user_email`, `organization_id`, `terminal_type`,
`service_name`, `os_type`, `host_arch`.

## Стартовая страница

Встроенную Home в OpenObserve подменить нельзя — это захардкоженная вьюха
(`HomeView.vue`), настройки «дашборд вместо главной» в OSS нет. Вместо неё —
дашборд **Claude Code · Обзор**: лимиты, расход, активные сессии, топ инструментов,
последние промпты на одном экране. Открывать по закладке:

```
http://localhost:5080/web/dashboards/view?org_identifier=default&folder=default&tab=default&dashboard=<ID обзора>&refresh=30
```

ID берётся из адресной строки при открытии дашборда. У «Обзора» зашит период
по умолчанию 6 часов (`defaultDatetimeDuration` в JSON), так что данные видно сразу.

Опционально можно убрать из левого меню неиспользуемые разделы — переменная
`ZO_CUSTOM_HIDE_MENUS` в compose принимает список имён через запятую
(`traces,rum,iam,reports,pipeline`); работает и в self-hosted.

## Дашборды

Готовые дашборды в папке `default` (UI → **Dashboards**):

- **Claude Code · Обзор** — сводный экран, см. выше.

- **Claude Code · Расходы** — стоимость / токены / сессии / активное время за период,
  стоимость во времени по моделям, донат по моделям, токены по типам (input, output,
  cacheRead, cacheCreation), таблица стоимости по сессиям.
- **Claude Code · Активность** — промпты, запросы к API, средняя задержка, события во
  времени и по типам, задержка API по моделям, срабатывания хуков, таблица последних промптов.

- **Claude Code · Сессии** — список сессий: статус, последняя активность, промптов,
  вызовов инструментов, стоимость, модель. Клик по строке → меню **«Открыть сессию»** →
  детальный дашборд по этой сессии.
- **Claude Code · Сессия** — что происходило внутри одной сессии: стоимость / промпты /
  вызовы инструментов / длительность, диалог (промпт → ответы), таблица вызовов инструментов
  с решением по разрешению, токены, задержка API и полный таймлайн событий.
  Сессия выбирается в выпадающем списке **Сессия** вверху (переменная `session_id`)
  или приходит из drilldown'а.

Исходники — `dashboards/*.json` (схема dashboard v8). Импорт:

```bash
./import-dashboards.sh          # или UI → Dashboards → Import → выбрать JSON
```

Повторный запуск создаёт **дубликаты** — старый дашборд сначала удалить в UI.

Все панели на custom SQL, поэтому их легко править: в UI открыть панель → Edit → вкладка
запроса. Метрики стоимости и токенов приходят с delta-температурностью, поэтому `SUM(value)`
корректен и ничего не задваивает.

## Лимиты подписки

В OTel-телеметрии Claude Code лимитов подписки **нет** — ни метрики, ни поля события.
Единственное место, где Claude Code их отдаёт, — JSON на stdin у statusline-скрипта:

```json
"rate_limits": {
  "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
  "seven_day": { "used_percentage": 41.2, "resets_at": 1738425600 }
}
```

Поле есть только у подписчиков Claude.ai (Pro/Max) и появляется после первого ответа API.

Поэтому лимиты забирает `statusline-ship-limits.sh`: он вызывает старый
`~/.claude/statusline-command.sh` (вывод строки не меняется) и не чаще **раза в минуту**
шлёт `rate_limits` в OpenObserve, в stream `claude_code_limits`. Подключено в
`~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "bash ~/develop/claude-observability/statusline-ship-limits.sh" }
```

Дашборд **Claude Code · Лимиты подписки**: два gauge (5-часовое и недельное окно),
время до сброса каждого окна, график расхода во времени и таблица замеров.

Важные ограничения:

- Замеры идут только пока открыта интерактивная сессия Claude Code — statusline
  не запускается в headless-режиме (`claude -p`). В простое график не обновляется.
- Троттлинг хранит отметку времени в `/tmp/claude-code-limits-last-ship` (одна на все
  сессии). Удалить файл = следующий рендер statusline отправит замер сразу.
- Значения приходят от Claude Code как есть; это доля израсходованного окна, а не токены.
- OpenObserve кэширует результаты панелей: после удаления/добавления данных панель может
  какое-то время показывать старое (в углу написано «3m ago»). Кнопка **Refresh** в шапке
  дашборда перечитывает данные. По той же причине при первом открытии дашборда панели
  иногда показывают «No Data» (успевают отработать со старым временным окном) — помогает
  тот же Refresh.

## Наблюдение за живыми сессиями

«Активна» = у сессии было хоть одно событие за последние 5 минут (`_timestamp >= now() - 5m`
в SQL панели). Отдельного события «сессия закончилась» Claude Code не шлёт, поэтому статус
считается по свежести событий.

Задержка данных: события уходят раз в 5 секунд (`OTEL_LOGS_EXPORT_INTERVAL`), метрики —
раз в 10 секунд (`OTEL_METRIC_EXPORT_INTERVAL`). Автообновление дашборда включается кнопкой
**Off** в шапке (10s / 30s / 1m) либо параметром в URL:

```
http://localhost:5080/web/dashboards/view?org_identifier=default&dashboard=<ID>&folder=default&tab=default&period=1h&refresh=30
```

Для «сырого» просмотра одной сессии есть Logs: stream `claude_code`, запрос
`session_id='<uuid>'` — там видно каждое событие со всеми полями.

Промпты и ответы в диалоге видны только потому, что включён `OTEL_LOG_USER_PROMPTS=1`
(поля `prompt` и `response`). Без него эти колонки будут пустыми.

## Готовые запросы

UI → **Logs**, stream `claude_code` (для событий) или **Metrics** (для метрик).
Не забыть выставить временной диапазон.

Расход по моделям за период (Metrics → SQL, stream `claude_code_cost_usage`):

```sql
select model, sum(value) as usd from "claude_code_cost_usage" group by model order by usd desc
```

Токены по типу:

```sql
select model, type, sum(value) as tokens
from "claude_code_token_usage" group by model, type order by tokens desc
```

Топ промптов по длине (Logs, stream `claude_code`):

```sql
select event_timestamp, prompt_length, prompt from "claude_code"
where event_name = 'user_prompt' order by prompt_length desc
```

Активность по типам событий за период:

```sql
select event_name, count(*) as c from "claude_code" group by event_name order by c desc
```

## Проверка, что телеметрия доходит

```bash
B64=$(printf '%s' "root@example.com:$(grep ZO_ROOT_USER_PASSWORD .env | cut -d= -f2-)" | base64)
curl -s -H "Authorization: Basic $B64" http://localhost:5080/api/default/streams | jq '.list[].name'
docker logs openobserve 2>&1 | grep 'POST /api/default/v1/'   # должны быть 200
```

Если пусто — открыть новую сессию `claude`, выполнить `/status` (там видны ошибки OTLP-экспорта)
или запустить `claude --debug`.

## Ретеншн

Глобально 30 дней — `ZO_COMPACT_DATA_RETENTION_DAYS: "30"` в compose. Проверить:

```bash
curl -s -H "Authorization: Basic $B64" http://localhost:5080/config | jq .data_retention_days
```

Для отдельного stream'а можно задать своё значение в UI: Streams → stream → Retention
(`0` в настройках stream'а = «использовать глобальное»).

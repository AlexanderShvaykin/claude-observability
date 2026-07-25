# Промпт для агента: развернуть мониторинг Claude Code на хосте

Отдай текст ниже (всё, что после разделителя) агенту Claude Code на том хосте, где нужен
мониторинг. Агент склонирует репозиторий, поднимет OpenObserve, пропишет телеметрию
и импортирует дашборды.

Требования к хосту: Docker, `jq`, `curl`, `git`, установленный Claude Code.

---

Разверни на этом хосте мониторинг Claude Code через OpenObserve.
Репозиторий: `git@github.com:AlexanderShvaykin/claude-observability.git`
(если SSH недоступен — `gh repo clone AlexanderShvaykin/claude-observability`).

Работай по шагам, каждый проверяй фактически, а не «должно работать».
Ничего не выдумывай: все команды и форматы описаны в README репозитория.

## 1. Клонировать и подготовить окружение

- Клонируй репозиторий в `~/develop/claude-observability` (или скажи, куда положил).
- Скопируй `.env.example` в `.env` и сгенерируй пароль.
  OpenObserve упадёт при старте, если нарушить его правила:
  - email обязан быть с доменом верхнего уровня — `root@localhost` не подойдёт;
  - пароль 8–128 символов, минимум одна строчная, одна заглавная, цифра и спецсимвол.

## 2. Поднять OpenObserve

- `docker compose up -d` в каталоге репозитория.
- Проверь фактически: `curl -s -o /dev/null -w '%{http_code}' http://localhost:5080/web/`
  должен вернуть `200`. Если нет — смотри `docker logs openobserve`.
- Порт 5080 должен быть свободен; если занят, поменяй маппинг в `docker-compose.yml`
  и дальше используй новый порт везде.

## 3. Включить телеметрию Claude Code

Посчитай токен: `B64=$(printf '%s' "$ZO_ROOT_USER_EMAIL:$ZO_ROOT_USER_PASSWORD" | base64)`.

Добавь в `~/.claude/settings.json` блок `env` — именно **добавь через jq**, не перезаписывай
файл целиком, там уже есть настройки пользователя:

```json
"env": {
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_METRICS_EXPORTER": "otlp",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:5080/api/default",
  "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Basic <B64>,stream-name=claude_code",
  "OTEL_METRIC_EXPORT_INTERVAL": "10000",
  "OTEL_LOGS_EXPORT_INTERVAL": "5000",
  "OTEL_LOG_USER_PROMPTS": "1"
}
```

Важное:

- `OTEL_EXPORTER_OTLP_ENDPOINT` — база **без** завершающего слэша, SDK сам допишет
  `/v1/metrics` и `/v1/logs`. Со слэшем будет 404.
- `stream-name=claude_code` разводит события в отдельный stream; без него они падают
  в общий `default`.
- `OTEL_LOG_USER_PROMPTS=1` пишет в базу **тексты промптов и ответов**. Спроси у
  пользователя, нужно ли это; если нет — убери строку.

## 4. Подключить сбор лимитов подписки (опционально, только для Pro/Max)

Лимитов нет в OTel-телеметрии — они приходят только в JSON для statusline
(`rate_limits.five_hour` / `.seven_day`). Их собирает `statusline-ship-limits.sh`.

- Если у пользователя уже есть свой statusline-скрипт, обёртка вызовет его сама
  (по умолчанию `~/.claude/statusline-command.sh`), вывод строки не изменится.
- Пропиши в `~/.claude/settings.json`:
  `"statusLine": { "type": "command", "command": "bash <путь к репо>/statusline-ship-limits.sh" }`
- Проверить, не дожидаясь живой сессии: скорми скрипту синтетический JSON с полем
  `rate_limits` на stdin и убедись, что в OpenObserve появился stream `claude_code_limits`.
  Тестовые записи потом удали: `DELETE /api/default/streams/claude_code_limits?type=logs`.

## 5. Импортировать дашборды

- `./import-dashboards.sh` (или UI → Dashboards → Import).
- Скрипт создаёт дашборды заново при каждом запуске — повторный импорт даст дубликаты.
- Проверь, что появились все шесть: Обзор, Расходы, Активность, Сессии, Сессия,
  Лимиты подписки.

## 6. Проверить сквозной поток

- Переменные окружения подхватываются **только новыми сессиями** `claude`.
  Запусти headless-сессию: `claude -p "Answer with one word: ping"`.
- Через ~15 секунд проверь фактически:
  - `docker logs openobserve | grep 'POST /api/default/v1/'` — должны быть `200`;
  - `curl -s -H "Authorization: Basic $B64" http://localhost:5080/api/default/streams`
    — должны появиться `claude_code` (logs) и `claude_code_*` (metrics).
- Открой дашборд «Claude Code · Обзор» и убедись, что панели наполнены. Если пусто —
  нажми Refresh в шапке: OpenObserve кэширует результаты панелей, и при первом
  открытии данные иногда не подтягиваются.

## 7. Что сообщить в конце

- Куда склонирован репозиторий и на каком порту UI, логин от OpenObserve.
- Включён ли сбор текстов промптов и сбор лимитов.
- Результаты проверок из шага 6 — что именно ты видел, а не «всё работает».
- Напомни, что телеметрия появится только в новых сессиях Claude Code.

## Подводные камни, уже проверенные на практике

- Метрики стоимости и токенов приходят с delta-температурностью, поэтому `SUM(value)`
  корректен; не переписывай запросы на «взять максимум по сессии».
- Часть полей событий — строки (`duration_ms`, `prompt_length`), для агрегатов нужен
  `CAST(... AS DOUBLE)`, иначе `AVG` падает с ошибкой планировщика.
- Поля вроде `tool_name` появляются в схеме stream'а только после первого события
  такого типа; запрос к несуществующей колонке падает.
- Статус «активна» у сессии считается по свежести событий (5 минут) — отдельного
  события «сессия завершилась» Claude Code не шлёт.
- Statusline не запускается в headless-режиме (`claude -p`), поэтому лимиты
  собираются только в интерактивных сессиях.

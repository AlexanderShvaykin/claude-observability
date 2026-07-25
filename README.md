# Claude Code → OpenObserve

A local OpenObserve instance that Claude Code writes metrics and events to directly over OTLP/HTTP.
No OpenTelemetry Collector is needed — OpenObserve itself acts as the OTLP receiver.

## Running

Requirements: Docker, `jq`, `curl`, and `python3` (the latter only for the limits poller).

```bash
cp .env.example .env      # and change the password
docker compose up -d      # UI: http://localhost:5080
docker compose logs -f    # server logs
docker compose down       # stop (data stays in ./data)
```

The root account credentials live in `.env` (the file is in `.gitignore`, the password is stored in plaintext).
OpenObserve refuses to start if the email has no top-level domain, or the password doesn't meet
the 8–128 character requirement with an uppercase letter, lowercase letter, digit, and special character.

Wire up telemetry in Claude Code:

```bash
./install.sh                  # env block + limits collection via the statusline
./install.sh --no-prompts     # without prompt and response text
./install.sh --no-limits      # leave the statusline alone
./install.sh --base-url http://host:5080 --org default
```

The script edits `~/.claude/settings.json` via jq: existing settings are preserved,
the previous statusline is not lost (it moves to `CLAUDE_OBS_STATUSLINE`, and the wrapper calls
it itself), and a backup is placed alongside. Running it again is a no-op.

To set up the same thing on another host: hand a Claude Code agent the prompt from
[`AGENT_SETUP.md`](AGENT_SETUP.md).

Data lives in `./data` (a host volume). To delete all history: `docker compose down && rm -rf data`.

`ZO_TELEMETRY: "false"` in the compose file disables OpenObserve's own outbound telemetry.

The compose file publishes port 5080 on all interfaces. That's fine on a laptop, but on a shared
host both the UI and the ingestion endpoint become reachable from the network, protected only by
the credentials in `.env`. Bind to `127.0.0.1:5080` and use an SSH tunnel instead.

## How Claude Code is configured

The `env` block in `~/.claude/settings.json` (applies to all projects):

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

Details:

- `OTEL_EXPORTER_OTLP_ENDPOINT` — the base URL **without** a trailing slash; the SDK appends `/v1/metrics` and `/v1/logs` itself.
- `stream-name=claude_code` — which stream events are written to; otherwise they fall into the general `default` stream.
  Doesn't affect metrics: each metric is its own stream, named after itself.
- `OTEL_LOG_USER_PROMPTS=1` — **prompt text gets written to the database** (the `prompt` field). Remove this line
  if you don't want that.
- Recompute the header when the password changes:
  `printf '%s' "root@example.com:PASSWORD" | base64`
- Changes take effect for new `claude` sessions; the current session keeps running with the old config.

## What gets collected

Metrics (streams of type `metrics`):

| Stream | What |
| --- | --- |
| `claude_code_session_count` | session starts |
| `claude_code_token_usage` | tokens, broken down by `model` and `type` (input/output/cacheRead/cacheCreation) |
| `claude_code_cost_usage` | cost in USD |
| `claude_code_active_time_total` | active time, sec |
| `claude_code_lines_of_code_count` | changed lines (appears after the first file edit) |
| `claude_code_commit_count`, `claude_code_pull_request_count`, `claude_code_code_edit_tool_decision` | commits, PRs, permission decisions |

Events (stream `claude_code`, type logs), field `event_name`:
`user_prompt`, `assistant_response`, `api_request`, `tool_result`, `tool_decision`,
`hook_execution_start/complete`, `mcp_server_connection`, `plugin_loaded`, `subagent_*`, and others.

Common attributes in both: `session_id`, `user_email`, `organization_id`, `terminal_type`,
`service_name`, `os_type`, `host_arch`.

## Home page

OpenObserve's built-in Home page can't be replaced — it's a hardcoded view
(`HomeView.vue`), and OSS has no "dashboard as home" setting. Instead, use the
**Claude Code · Обзор** (Overview) dashboard: rate limits, spend, active sessions, top tools,
and recent prompts on one screen. Open it via a bookmark:

```
http://localhost:5080/web/dashboards/view?org_identifier=default&folder=default&tab=default&dashboard=<overview ID>&refresh=30
```

The ID comes from the address bar when you open the dashboard. The Overview dashboard has a
default period of 6 hours baked in (`defaultDatetimeDuration` in the JSON), so data is visible right away.

Optionally, you can remove unused sections from the left menu — the
`ZO_CUSTOM_HIDE_MENUS` variable in the compose file accepts a comma-separated list of names
(`traces,rum,iam,reports,pipeline`); this works in self-hosted too.

## Dashboards

Ready-made dashboards live in the `default` folder (UI → **Dashboards**):

- **Claude Code · Обзор** — the summary screen described above.

- **Claude Code · Расходы** (Cost) — cost / tokens / sessions / active time for the period,
  cost over time by model, a donut chart broken down by model, tokens by type (input, output,
  cacheRead, cacheCreation), a per-session cost table.
- **Claude Code · Активность** (Activity) — prompts, API requests, average latency, events over
  time and by type, API latency by model, hook triggers, a table of recent prompts.

- **Claude Code · Сессии** (Sessions) — a list of sessions: status, last activity, prompt count,
  tool call count, cost, model. Clicking a row → the **«Открыть сессию»** ("Open session") menu →
  a detailed dashboard for that session.
- **Claude Code · Сессия** (Session) — what happened inside a single session: cost / prompts /
  tool calls / duration, the dialogue (prompt → responses), a table of tool calls
  with the permission decision, tokens, API latency, and a full event timeline.
  The session is picked from the **Сессия** ("Session") dropdown at the top (the `session_id` variable)
  or arrives via drilldown.

Sources: `dashboards/*.json` (dashboard schema v8). Import:

```bash
./import-dashboards.sh          # or UI → Dashboards → Import → pick the JSON
```

Running it again creates **duplicates** — delete the old dashboard in the UI first.

All panels use custom SQL, so they're easy to edit: in the UI, open the panel → Edit → the query
tab. Cost and token metrics arrive with delta temporality, so `SUM(value)`
is correct and doesn't double-count anything.

## Subscription limits

Claude Code's OTel telemetry **has no** subscription-limit data — no metric, no event field.
The only place Claude Code exposes it is the JSON it feeds to the statusline script on stdin:

```json
"rate_limits": {
  "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
  "seven_day": { "used_percentage": 41.2, "resets_at": 1738425600 }
}
```

The field is only present for Claude.ai subscribers (Pro/Max) and appears after the first API response.

**Why not hooks.** Verified empirically (a throwaway project with hooks that dumped stdin):
`SessionStart`, `UserPromptSubmit`, `Stop`, and `SessionEnd` receive only `session_id`,
`prompt_id`, `transcript_path`, `cwd`, `permission_mode`, and their own event's fields — no
rate limits, no spend data. Session transcripts (`~/.claude/projects/*/*.jsonl`) don't
contain limits either, and `cachedUsageUtilization` in `~/.claude.json` updates rarely
(observed to be two days stale), so it doesn't work as a source.

Collection is split across two files:

- `ship-limits.sh` — the transport: reads JSON from stdin, ships `rate_limits`
  to the `claude_code_limits` stream no more often than **once a minute**. It prints nothing and
  depends on nothing; if another source of the same data shows up, it can be hooked up to this same script.
- `statusline-ship-limits.sh` — the statusline wrapper: feeds the JSON to the transport and renders
  the status line. If the host has its own statusline, it calls it (path or command with arguments
  in `CLAUDE_OBS_STATUSLINE`, `~` is expanded), and its output is unchanged. If there isn't one,
  it prints a minimal `Opus 5 · 5h:63% · ctx:7%` line.

Wired up via `./install.sh` — nothing needs to be edited by hand.

### Hosts without a statusline (headless, `claude -p`)

The statusline **does not run** in headless mode (verified: a stub hook on `statusLine`
gets nothing under `claude -p`). For such hosts there's a second collector — polling:

```bash
./poll-limits.sh                    # one-off poll
./install-poller.sh                 # scheduled, every 10 minutes
./install-poller.sh --interval 30
./install-poller.sh --uninstall
```

`claude -p "/usage"` prints the limits as text in headless mode too — including
the per-model weekly limit, which the statusline doesn't have. `parse-usage.py`
parses the output (percentages + reset time, timezone-aware) and hands it to the same
`ship-limits.sh`, so the data lands in the same stream and the same panels; the only
difference is the `source` field (`usage-cli` vs `statusline`) and `host`.

Polling runs out of the `poller/` directory, which has a `.claude/settings.json` with telemetry
turned off: otherwise every poll would create a spurious "session" in the metrics. This can't be
done via environment variables — the `env` block from `~/.claude/settings.json` overrides them,
and project-level settings override user-level ones (verified both ways).

`install-poller.sh` installs a launchd agent on macOS and a cron job on Linux.
Polling itself doesn't spend tokens: `/usage` doesn't call the model.

The **Claude Code · Лимиты подписки** (Subscription limits) dashboard: two gauges (the 5-hour
and weekly windows), time to reset for each window, a usage-over-time chart, and a table of
measurements.

Important limitations:

- The statusline collector only produces measurements while an interactive Claude Code session
  is open, so the chart doesn't update while idle. On hosts that only run `claude -p`, use the
  poller described above instead.
- Throttling keeps a timestamp in `/tmp/claude-code-limits-last-ship` (one file shared across all
  sessions). Deleting the file means the next statusline render ships a measurement immediately.
- Values come from Claude Code as-is; they're the fraction of the window consumed, not token counts.
- OpenObserve caches panel results: after data is deleted/added, a panel may keep showing
  stale results for a while (the corner shows "3m ago"). The **Refresh** button in the dashboard
  header re-reads the data. For the same reason, on first opening a dashboard panels
  sometimes show "No Data" (they run before the time window catches up) — the same Refresh
  fixes it.

## Watching live sessions

"Active" means the session had at least one event in the last 5 minutes (`_timestamp >= now() - 5m`
in the panel's SQL). Claude Code doesn't send a separate "session ended" event, so status
is derived from event recency.

Data lag: events are sent every 5 seconds (`OTEL_LOGS_EXPORT_INTERVAL`), metrics
every 10 seconds (`OTEL_METRIC_EXPORT_INTERVAL`). Dashboard auto-refresh is turned on via the
**Off** button in the header (10s / 30s / 1m) or via a URL parameter:

```
http://localhost:5080/web/dashboards/view?org_identifier=default&dashboard=<ID>&folder=default&tab=default&period=1h&refresh=30
```

For a "raw" view of a single session, there's Logs: stream `claude_code`, query
`session_id='<uuid>'` — shows every event with all its fields.

Prompts and responses are visible in the dialogue only because `OTEL_LOG_USER_PROMPTS=1` is
enabled (the `prompt` and `response` fields). Without it, these columns will be empty.

## Ready-made queries

UI → **Logs**, stream `claude_code` (for events) or **Metrics** (for metrics).
Don't forget to set the time range.

Spend by model for the period (Metrics → SQL, stream `claude_code_cost_usage`):

```sql
select model, sum(value) as usd from "claude_code_cost_usage" group by model order by usd desc
```

Tokens by type:

```sql
select model, type, sum(value) as tokens
from "claude_code_token_usage" group by model, type order by tokens desc
```

Top prompts by length (Logs, stream `claude_code`):

```sql
select event_timestamp, prompt_length, prompt from "claude_code"
where event_name = 'user_prompt' order by prompt_length desc
```

Activity by event type for the period:

```sql
select event_name, count(*) as c from "claude_code" group by event_name order by c desc
```

## Verifying telemetry is arriving

```bash
B64=$(printf '%s' "root@example.com:$(grep ZO_ROOT_USER_PASSWORD .env | cut -d= -f2-)" | base64)
curl -s -H "Authorization: Basic $B64" http://localhost:5080/api/default/streams | jq '.list[].name'
docker logs openobserve 2>&1 | grep 'POST /api/default/v1/'   # should be 200s
```

If it's empty, open a new `claude` session, run `/status` (it shows OTLP export errors),
or run `claude --debug`.

## Retention

Globally 30 days — `ZO_COMPACT_DATA_RETENTION_DAYS: "30"` in the compose file. To check:

```bash
curl -s -H "Authorization: Basic $B64" http://localhost:5080/config | jq .data_retention_days
```

A specific stream can have its own value set in the UI: Streams → stream → Retention
(`0` in the stream's settings means "use the global value").

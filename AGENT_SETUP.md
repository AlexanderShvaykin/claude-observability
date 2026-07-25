# Prompt for an agent: deploy Claude Code monitoring on a host

Hand the text below (everything after the divider) to a Claude Code agent on the host where
monitoring is needed. The agent will clone the repository, bring up OpenObserve, wire up
telemetry, and import the dashboards.

Host requirements: Docker with a running daemon, `jq`, `curl`, `git`, `python3`, Claude Code
installed, and access to the private repository (an SSH key for the GitHub account, or an
authenticated `gh`).

---

Set up Claude Code monitoring on this host using OpenObserve.
Repository: `git@github.com:AlexanderShvaykin/claude-observability.git`
(if SSH isn't available — `gh repo clone AlexanderShvaykin/claude-observability`).

Work through the steps one at a time, and verify each one for real — not "it should work."
Don't make anything up: every command and format is documented in the repo's README.

## 1. Clone and prepare the environment

- Clone the repository into `~/develop/claude-observability` (or say where you put it).
- Copy `.env.example` to `.env` and generate a password.
  OpenObserve will fail to start if you violate its rules:
  - the email must have a top-level domain — `root@localhost` won't work;
  - the password must be 8–128 characters, with at least one lowercase letter, one uppercase
    letter, a digit, and a special character.

## 2. Bring up OpenObserve

- `docker compose up -d` in the repository directory.
- Verify for real: `curl -s -o /dev/null -w '%{http_code}' http://localhost:5080/web/`
  should return `200`. If not, check `docker logs openobserve`.
- Port 5080 must be free; if it's taken, change the mapping in `docker-compose.yml`
  and use the new port everywhere from then on.
- The compose file publishes the port on all interfaces. If this host isn't isolated, change the
  mapping to `127.0.0.1:5080:5080` — otherwise the UI and the ingestion endpoint are reachable
  from the network, protected only by the credentials in `.env`. Tell the user what you chose.

## 3. Wire up telemetry in Claude Code

Run `./install.sh` — it idempotently edits `~/.claude/settings.json` via jq:
adds the telemetry `env` block, wires up subscription-limit collection through the statusline
wrapper, and drops a backup alongside. The user's existing settings are preserved; if the host
already had its own statusline, it moves to `CLAUDE_OBS_STATUSLINE` and gets called by the
wrapper, so the status line's output stays unchanged.

- Ask the user whether **prompt and response text** should be written to the database. If not —
  `./install.sh --no-prompts`.
- If limit collection isn't needed, or the statusline must not be touched — `./install.sh --no-limits`.
- If OpenObserve isn't on `localhost:5080` — `--base-url http://host:port`.

Verify the result: `jq '{env, statusLine}' ~/.claude/settings.json` — and confirm that
the user's previous settings are still there.

Don't rewrite `settings.json` wholesale, and don't edit it by hand — it holds the user's
plugins, hooks, and permissions.

## 4. On subscription limits: don't try to replace the statusline with hooks

This has already been verified empirically — don't waste time on it:

- hooks (`SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd`) receive only
  `session_id`, `prompt_id`, `transcript_path`, `cwd`, `permission_mode` — no limits;
- session transcripts don't have them either;
- `cachedUsageUtilization` in `~/.claude.json` updates rarely and can be a day stale.

There are exactly two working sources; pick based on how Claude Code runs on this host:

**Interactive sessions** — the statusline. `install.sh` already wired everything up: the
transport `ship-limits.sh` reads JSON from stdin, the `statusline-ship-limits.sh` wrapper
renders the status line and feeds the transport. To verify without waiting for a live session:
feed the wrapper a synthetic JSON with a `rate_limits` field on stdin and check that the
`claude_code_limits` stream appears.

**Headless only (`claude -p`)** — polling. The statusline doesn't run at all in headless mode,
but `claude -p "/usage"` prints the limits as text. Set up scheduled polling:

```bash
./poll-limits.sh          # one-off run, check that a record shows up
./install-poller.sh       # launchd on macOS, cron on Linux, every 10 minutes
```

Polling by itself doesn't spend tokens and doesn't create extra sessions in the metrics — it
runs out of the `poller/` directory with a project-level `CLAUDE_CODE_ENABLE_TELEMETRY=0`
setting. Don't try to disable telemetry via an environment variable: the `env` block from
`~/.claude/settings.json` overrides it — only project-level settings work.

Delete the test records afterward: `DELETE /api/default/streams/claude_code_limits?type=logs`.

## 5. Import the dashboards

- `./import-dashboards.sh` (or UI → Dashboards → Import).
- The script creates the dashboards fresh on every run — importing again produces duplicates.
- Verify that all six appeared: Обзор (Overview), Расходы (Cost), Активность (Activity),
  Сессии (Sessions), Сессия (Session), Лимиты подписки (Subscription limits).

## 6. Verify the end-to-end flow

- Environment variables are picked up **only by new `claude` sessions**.
  Start a headless session: `claude -p "Answer with one word: ping"`.
- After ~15 seconds, verify for real:
  - `docker logs openobserve | grep 'POST /api/default/v1/'` — should show `200`s;
  - `curl -s -H "Authorization: Basic $B64" http://localhost:5080/api/default/streams`
    — `claude_code` (logs) and `claude_code_*` (metrics) should appear.
- Open the **Claude Code · Обзор** (Overview) dashboard and confirm the panels are populated.
  If it's empty, click Refresh in the header: OpenObserve caches panel results, and on first
  open the data sometimes doesn't catch up.

## 7. What to report at the end

- Where the repository was cloned and what port the UI is on, and the OpenObserve login.
- Whether prompt/response text collection and limit collection are enabled.
- The results of the checks from step 6 — what you actually saw, not "everything works."
- Remind them that telemetry will only show up in new Claude Code sessions.

## Gotchas already verified in practice

- Cost and token metrics arrive with delta temporality, so `SUM(value)`
  is correct; don't rewrite queries to "take the max per session."
- Some event fields are strings (`duration_ms`, `prompt_length`); aggregates need
  `CAST(... AS DOUBLE)`, otherwise `AVG` fails with a planner error.
- Fields like `tool_name` only appear in the stream's schema after the first event
  of that type; querying a column that doesn't exist yet fails.
- A session's "active" status is derived from event recency (5 minutes) — Claude Code
  doesn't send a separate "session ended" event.
- The statusline doesn't run in headless mode (`claude -p`), so on such hosts limits come from
  the poller, not from the statusline.

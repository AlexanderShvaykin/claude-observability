#!/usr/bin/env python3
"""Разбирает вывод `claude -p "/usage"` в JSON той же формы, что statusline отдаёт скриптам.

На вход (stdin) ожидается текст вида:

    Current session: 63% used · resets Jul 25 at 2:09pm (Europe/Moscow)
    Current week (all models): 55% used · resets Jul 28 at 1:59pm (Europe/Moscow)
    Current week (Fable): 10% used · resets Jul 28 at 2pm (Europe/Moscow)

На выход — JSON с ключом rate_limits, который понимает ship-limits.sh.
Строки, которые не разобрались, просто пропускаются: лучше отдать часть метрик,
чем ничего.
"""

import json
import re
import sys
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except ImportError:  # python < 3.9
    ZoneInfo = None

LINE = re.compile(
    r"^Current (?P<what>session|week)"
    r"(?: \((?P<scope>[^)]+)\))?"
    r":\s*(?P<pct>[\d.]+)%\s*used"
    r"(?:.*?resets\s+(?P<date>\w+\s+\d+)\s+at\s+(?P<time>\d{1,2}(?::\d{2})?\s*[ap]m)"
    r"(?:\s*\((?P<tz>[^)]+)\))?)?",
    re.IGNORECASE,
)


def to_epoch(date_s, time_s, tz_s):
    """'Jul 25' + '2:09pm' + 'Europe/Moscow' -> unix epoch. None, если не вышло."""
    if not date_s or not time_s:
        return None
    time_s = time_s.replace(" ", "").upper()
    fmt = "%b %d %Y %I:%M%p" if ":" in time_s else "%b %d %Y %I%p"
    now = datetime.now(ZoneInfo(tz_s)) if (ZoneInfo and tz_s) else datetime.now()
    try:
        dt = datetime.strptime(f"{date_s} {now.year} {time_s}", fmt)
    except ValueError:
        return None
    if ZoneInfo and tz_s:
        try:
            dt = dt.replace(tzinfo=ZoneInfo(tz_s))
        except Exception:
            return None
    # год в выводе не печатается: если дата уехала далеко в прошлое, это следующий год
    if (now - dt).days > 30:
        dt = dt.replace(year=dt.year + 1)
    return int(dt.timestamp())


def main():
    limits = {}
    for line in sys.stdin:
        m = LINE.match(line.strip())
        if not m:
            continue
        g = m.groupdict()
        entry = {"used_percentage": float(g["pct"])}
        epoch = to_epoch(g["date"], g["time"], g["tz"])
        if epoch:
            entry["resets_at"] = epoch

        if g["what"].lower() == "session":
            limits["five_hour"] = entry
        elif (g["scope"] or "").lower() == "all models":
            limits["seven_day"] = entry
        elif g["scope"]:
            entry["model"] = g["scope"]
            limits["weekly_scoped"] = entry

    if not limits:
        return 1

    json.dump({"session_id": "usage-cli", "rate_limits": limits}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())

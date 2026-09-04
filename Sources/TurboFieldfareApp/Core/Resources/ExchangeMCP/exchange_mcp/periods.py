from __future__ import annotations

from datetime import datetime, time, timedelta, timezone
from typing import Literal
from zoneinfo import ZoneInfo

Period = Literal["today", "yesterday", "this_week", "custom"]


def aware_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("Datetime must include a UTC offset, for example 2026-09-04T00:00:00+03:00")
    return parsed


def resolve_period(
    period: Period,
    timezone_name: str,
    start_datetime: str | None = None,
    end_datetime: str | None = None,
    *,
    now: datetime | None = None,
) -> tuple[datetime, datetime]:
    """Return [start, end), with Monday as the beginning of the week."""
    zone = ZoneInfo(timezone_name)  # Invalid configuration must not silently use UTC.
    if period == "custom":
        if not start_datetime or not end_datetime:
            raise ValueError("custom requires start_datetime and end_datetime")
        start = aware_datetime(start_datetime).astimezone(zone)
        end = aware_datetime(end_datetime).astimezone(zone)
    else:
        if start_datetime is not None or end_datetime is not None:
            raise ValueError("Explicit datetimes require period=custom")
        current = now if now is not None else datetime.now(timezone.utc)
        if current.tzinfo is None or current.utcoffset() is None:
            raise ValueError("now must be timezone-aware")
        current = current.astimezone(zone)
        today = datetime.combine(current.date(), time.min, tzinfo=zone)
        if period == "today":
            start, end = today, current
        elif period == "yesterday":
            start = datetime.combine(current.date() - timedelta(days=1), time.min, tzinfo=zone)
            end = today
        elif period == "this_week":
            monday = current.date() - timedelta(days=current.weekday())
            start, end = datetime.combine(monday, time.min, tzinfo=zone), current
        else:
            raise ValueError("period must be today, yesterday, this_week, or custom")
    if start.astimezone(timezone.utc) > end.astimezone(timezone.utc):
        raise ValueError("start_datetime must not be after end_datetime")
    if period == "custom" and start.astimezone(timezone.utc) == end.astimezone(timezone.utc):
        raise ValueError("custom period must have a positive duration")
    return start, end

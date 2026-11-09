"""The kill switch state, stored as JSON in the SSM parameter /cost-kill-switch/state."""

import copy
import json
import re
from datetime import datetime

ARMED = "armed"
TRIPPED = "tripped"
KEYS = frozenset(
    {"status", "month", "acknowledged_usd", "tripped_at", "reason", "estimate_usd", "disabled_distributions", "concurrency"}
)
_MONTH = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")


class StateError(ValueError):
    """The stored state is missing or malformed. Never treated as armed."""


def _number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def armed(month: str, acknowledged: float = 0.0) -> dict:
    return {
        "status": ARMED,
        "month": month,
        "acknowledged_usd": float(acknowledged),
        "tripped_at": None,
        "reason": None,
        "estimate_usd": None,
        "disabled_distributions": [],
        "concurrency": {},
    }


def tripped(s: dict, *, reason: str, now: datetime, estimate: float | None) -> dict:
    new = copy.deepcopy(s)
    new.update(
        status=TRIPPED,
        reason=reason,
        tripped_at=now.isoformat(timespec="seconds"),
        estimate_usd=None if estimate is None else round(estimate, 4),
    )
    return new


def validate(doc) -> dict:
    if not isinstance(doc, dict) or set(doc) != KEYS:
        raise StateError("state must have exactly the documented keys")
    if doc["status"] not in (ARMED, TRIPPED):
        raise StateError("unknown status")
    if not isinstance(doc["month"], str) or not _MONTH.match(doc["month"]):
        raise StateError("month must be YYYY-MM")
    if not _number(doc["acknowledged_usd"]) or doc["acknowledged_usd"] < 0:
        raise StateError("acknowledged_usd must be a number >= 0")
    if doc["estimate_usd"] is not None and not _number(doc["estimate_usd"]):
        raise StateError("estimate_usd must be a number or null")
    for key in ("tripped_at", "reason"):
        if doc[key] is not None and not isinstance(doc[key], str):
            raise StateError(f"{key} must be a string or null")
    dists = doc["disabled_distributions"]
    if not isinstance(dists, list) or not all(isinstance(d, str) for d in dists):
        raise StateError("disabled_distributions must be a list of IDs")
    conc = doc["concurrency"]
    if not isinstance(conc, dict) or not all(
        isinstance(k, str) and (v is None or (isinstance(v, int) and not isinstance(v, bool) and v >= 0))
        for k, v in conc.items()
    ):
        raise StateError("concurrency must map function names to an int >= 0 or null")
    if doc["status"] == ARMED and (dists or conc or doc["tripped_at"] or doc["reason"]):
        raise StateError("an armed state carries no trip details")
    return doc


def parse(text: str) -> dict:
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as e:
        raise StateError("state is not JSON") from e
    return validate(doc)


def dump(s: dict) -> str:
    return json.dumps(validate(s), sort_keys=True, separators=(",", ":"))


def month_of(now: datetime) -> str:
    return now.strftime("%Y-%m")


def month_start(now: datetime) -> datetime:
    return now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def roll_month(s: dict, now: datetime) -> dict:
    """A new month starts with nothing acknowledged. A tripped state stays tripped."""
    month = month_of(now)
    if s["month"] == month:
        return s
    new = copy.deepcopy(s)
    new["month"] = month
    new["acknowledged_usd"] = 0.0
    return new

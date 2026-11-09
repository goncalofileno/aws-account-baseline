"""Turns a Lambda event into (action, reason)."""

ACTIONS = frozenset({"check", "status", "trip", "rearm"})
MAX_REASON = 200


def parse_event(event, trigger_topic_arn: str) -> tuple[str, str | None]:
    if isinstance(event, dict) and "Records" in event:
        for record in event["Records"]:
            if record.get("EventSource") == "aws:sns" and record.get("Sns", {}).get("TopicArn") == trigger_topic_arn:
                return "trip", "budget"
        return "ignore", None
    action = event.get("action") if isinstance(event, dict) else None
    if action not in ACTIONS:
        raise ValueError(f"unknown action: {action!r}")
    if action in ("trip", "rearm"):
        reason = event.get("reason")
        if not isinstance(reason, str) or not reason.strip() or len(reason.strip()) > MAX_REASON:
            raise ValueError(f"{action} needs a reason of 1 to {MAX_REASON} characters")
        return action, reason.strip()
    return action, None

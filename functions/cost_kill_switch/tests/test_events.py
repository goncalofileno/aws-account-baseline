import pytest

from events import parse_event

TRIGGER = "arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-trigger"


def sns(topic):
    return {"Records": [{"EventSource": "aws:sns", "Sns": {"TopicArn": topic, "Message": "{}"}}]}


@pytest.mark.parametrize("action", ["check", "status"])
def test_actions_without_a_reason(action):
    assert parse_event({"action": action}, TRIGGER) == (action, None)


@pytest.mark.parametrize("action", ["trip", "rearm"])
def test_trip_and_rearm_carry_a_stripped_reason(action):
    assert parse_event({"action": action, "reason": "  drill  "}, TRIGGER) == (action, "drill")


@pytest.mark.parametrize("reason", [None, "", "   ", 5, "x" * 201])
@pytest.mark.parametrize("action", ["trip", "rearm"])
def test_trip_and_rearm_need_a_reason_of_1_to_200_characters(action, reason):
    with pytest.raises(ValueError):
        parse_event({"action": action, "reason": reason}, TRIGGER)


@pytest.mark.parametrize("event", [{}, {"action": "explode"}, {"action": None}, "check", None])
def test_unknown_events_raise(event):
    with pytest.raises(ValueError):
        parse_event(event, TRIGGER)


def test_a_record_from_the_trigger_topic_trips_with_reason_budget():
    assert parse_event(sns(TRIGGER), TRIGGER) == ("trip", "budget")


def test_records_from_any_other_topic_are_ignored():
    other = "arn:aws:sns:eu-north-1:123456789012:something-else"
    assert parse_event(sns(other), TRIGGER) == ("ignore", None)

import copy
import json
from datetime import datetime, timezone

import pytest

import state as st

NOW = datetime(2026, 11, 9, 14, 30, 5, 123456, tzinfo=timezone.utc)

# Exactly what kill-switch.tf creates: jsonencode() sorts keys and writes 0, not 0.0.
TERRAFORM_INITIAL = (
    '{"acknowledged_usd":0,"concurrency":{},"disabled_distributions":[],"estimate_usd":null,'
    '"month":"1970-01","reason":null,"status":"armed","tripped_at":null}'
)


def a_tripped_state():
    s = st.tripped(st.armed("2026-11"), reason="drill", now=NOW, estimate=1.23456)
    s["disabled_distributions"] = ["E1"]
    s["concurrency"] = {"cv-site-contact": 2, "other": None}
    return s


def test_the_terraform_initial_value_is_a_valid_armed_state():
    s = st.parse(TERRAFORM_INITIAL)
    assert s["status"] == st.ARMED
    assert s["month"] == "1970-01"


def test_armed_has_exactly_the_documented_fields():
    assert st.armed("2026-11", acknowledged=1.5) == {
        "status": "armed",
        "month": "2026-11",
        "acknowledged_usd": 1.5,
        "tripped_at": None,
        "reason": None,
        "estimate_usd": None,
        "disabled_distributions": [],
        "concurrency": {},
    }


def test_dump_is_compact_sorted_and_round_trips():
    s = a_tripped_state()
    text = st.dump(s)
    assert text == json.dumps(s, sort_keys=True, separators=(",", ":"))
    assert st.parse(text) == s


def test_tripped_records_reason_time_and_rounded_estimate_without_touching_the_input():
    armed = st.armed("2026-11", acknowledged=2.0)
    before = copy.deepcopy(armed)
    s = st.tripped(armed, reason="budget", now=NOW, estimate=1.23456)
    assert armed == before
    assert s["status"] == st.TRIPPED
    assert s["reason"] == "budget"
    assert s["tripped_at"] == "2026-11-09T14:30:05+00:00"
    assert s["estimate_usd"] == 1.2346
    assert s["acknowledged_usd"] == 2.0


def test_tripped_accepts_an_unknown_estimate():
    assert st.tripped(st.armed("2026-11"), reason="x", now=NOW, estimate=None)["estimate_usd"] is None


def _with(**changes):
    s = a_tripped_state()
    s.update(changes)
    return s


@pytest.mark.parametrize(
    "doc",
    [
        [],
        {k: v for k, v in st.armed("2026-11").items() if k != "reason"},
        {**st.armed("2026-11"), "extra": 1},
        _with(status="off"),
        _with(month="2026-13"),
        _with(month="26-11"),
        _with(acknowledged_usd=-1),
        _with(acknowledged_usd=True),
        _with(acknowledged_usd="1"),
        _with(estimate_usd="1"),
        _with(tripped_at=5),
        _with(reason=5),
        _with(disabled_distributions="E1"),
        _with(disabled_distributions=[1]),
        _with(concurrency=[]),
        _with(concurrency={"f": -1}),
        _with(concurrency={"f": True}),
        _with(concurrency={"f": 1.5}),
        {**st.armed("2026-11"), "disabled_distributions": ["E1"]},
        {**st.armed("2026-11"), "concurrency": {"f": 1}},
        {**st.armed("2026-11"), "reason": "left over"},
    ],
)
def test_validate_rejects_malformed_documents(doc):
    with pytest.raises(st.StateError):
        st.validate(doc)


def test_parse_rejects_text_that_is_not_json():
    with pytest.raises(st.StateError):
        st.parse("not json")


def test_dump_refuses_an_invalid_state():
    with pytest.raises(st.StateError):
        st.dump({"status": "armed"})


def test_month_helpers():
    assert st.month_of(NOW) == "2026-11"
    assert st.month_start(NOW) == datetime(2026, 11, 1, tzinfo=timezone.utc)


def test_roll_month_keeps_the_same_object_within_the_month():
    s = st.armed("2026-11", acknowledged=3.0)
    assert st.roll_month(s, NOW) is s


def test_roll_month_resets_acknowledged_and_keeps_the_status():
    s = a_tripped_state()
    s["month"] = "2026-10"
    s["acknowledged_usd"] = 3.0
    rolled = st.roll_month(s, NOW)
    assert rolled is not s
    assert rolled["month"] == "2026-11"
    assert rolled["acknowledged_usd"] == 0.0
    assert rolled["status"] == st.TRIPPED
    assert rolled["disabled_distributions"] == ["E1"]
    assert s["month"] == "2026-10"

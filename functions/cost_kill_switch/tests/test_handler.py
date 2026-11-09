import json
import logging
from datetime import datetime, timezone

import pytest
from botocore.exceptions import ClientError

import handler
import state as st
from fakes import ALERTS, PARAM, SELF, TRIGGER, World

NOW = datetime(2026, 11, 9, 14, 30, tzinfo=timezone.utc)
FLOOD = {("AWS/CloudFront", "BytesDownloaded", "E1"): 50e9}  # 50 GB -> USD 6.00
QUIET = {("AWS/CloudFront", "BytesDownloaded", "E1"): 1e9}  # 1 GB -> USD 0.12


def budget_event(topic=TRIGGER):
    return {"Records": [{"EventSource": "aws:sns", "Sns": {"TopicArn": topic, "Message": "{}"}}]}


def test_check_below_the_threshold_changes_nothing():
    w = World(cf_sums=QUIET)
    result = w.switch.run({"action": "check"}, NOW)
    assert result["status"] == "armed"
    assert result["estimate_usd"] == pytest.approx(0.12)
    assert w.cloudfront.updates == []
    assert w.lambda_.reserved["cv-site-contact"] == 2
    assert w.sns.published == []
    assert w.ssm.writes == []


def test_check_over_the_threshold_trips_records_first_and_alerts_once():
    w = World(dists={"E1": True, "E2": False}, functions={"cv-site-contact": (128, 2), "other": (256, None)}, cf_sums=FLOOD)
    result = w.switch.run({"action": "check"}, NOW)
    s = w.ssm.state
    assert s["status"] == "tripped"
    assert s["reason"] == "estimated spend USD 6.00 this month is over the USD 5 threshold"
    assert s["disabled_distributions"] == ["E1"]  # E2 was already off: not ours to restore
    assert s["concurrency"] == {"cv-site-contact": 2, "other": None}
    assert w.cloudfront.enabled == {"E1": False, "E2": False}
    assert w.lambda_.reserved == {SELF: 1, "cv-site-contact": 0, "other": 0}
    assert [subject for subject, _ in w.sns.published] == ["Cost kill switch TRIPPED"]
    # The first write is the bare trip, before any resource was changed.
    assert w.ssm.writes[0]["status"] == "tripped"
    assert w.ssm.writes[0]["disabled_distributions"] == []
    assert result == {
        "status": "tripped",
        "reason": s["reason"],
        "tripped_at": "2026-11-09T14:30:00+00:00",
        "estimate_usd": 6.0,
        "acknowledged_usd": 0.0,
        "distributions": 1,
        "functions": 2,
    }


def test_a_function_already_at_zero_is_not_recorded():
    w = World(functions={"cv-site-contact": (128, 0)}, cf_sums=FLOOD)
    w.switch.run({"action": "check"}, NOW)
    assert w.ssm.state["concurrency"] == {}


def test_while_tripped_enforcement_catches_what_came_back_without_a_second_email():
    w = World(cf_sums=FLOOD)
    w.switch.run({"action": "check"}, NOW)
    w.cloudfront.enabled["E1"] = True  # e.g. a deploy slipped through
    w.cloudfront.enabled["E9"] = True  # a new distribution
    w.lambda_.reserved["cv-site-contact"] = 5
    w.switch.run({"action": "check"}, NOW)
    s = w.ssm.state
    assert w.cloudfront.enabled == {"E1": False, "E9": False}
    assert s["disabled_distributions"] == ["E1", "E9"]
    assert s["concurrency"] == {"cv-site-contact": 2}  # the original value, never overwritten by the 5
    assert w.lambda_.reserved["cv-site-contact"] == 0
    assert len(w.sns.published) == 1


def test_enforcement_keeps_going_after_one_failure_then_raises():
    w = World(dists={"E1": True, "E2": True}, cf_sums=FLOOD)

    def flaky(Id, IfMatch, DistributionConfig):
        if Id == "E1":
            raise ClientError({"Error": {"Code": "PreconditionFailed", "Message": "x"}}, "UpdateDistribution")
        w.cloudfront.enabled[Id] = DistributionConfig["Enabled"]

    w.cloudfront.update_distribution = flaky
    with pytest.raises(RuntimeError, match="1 enforcement action"):
        w.switch.run({"action": "check"}, NOW)
    assert w.ssm.state["status"] == "tripped"
    assert w.cloudfront.enabled["E2"] is False
    assert w.lambda_.reserved["cv-site-contact"] == 0


def test_rearm_restores_exactly_what_was_changed_and_acknowledges_the_estimate():
    w = World(dists={"E1": True, "E2": False}, functions={"cv-site-contact": (128, 2), "other": (256, None)}, cf_sums=FLOOD)
    w.switch.run({"action": "check"}, NOW)
    result = w.switch.run({"action": "rearm", "reason": "flood over"}, NOW)
    assert w.cloudfront.enabled == {"E1": True, "E2": False}
    assert w.lambda_.reserved == {SELF: 1, "cv-site-contact": 2, "other": None}
    s = w.ssm.state
    assert s["acknowledged_usd"] == pytest.approx(6.0)
    assert {**s, "acknowledged_usd": 0.0} == st.armed("2026-11")
    assert result["status"] == "armed"
    assert [subject for subject, _ in w.sns.published] == ["Cost kill switch TRIPPED", "Cost kill switch rearmed"]
    # The same flood no longer trips: only new spend counts.
    w.switch.run({"action": "check"}, NOW)
    assert w.ssm.state["status"] == "armed"


def test_rearm_while_armed_is_a_no_op():
    w = World(cf_sums=QUIET)
    result = w.switch.run({"action": "rearm", "reason": "just in case"}, NOW)
    assert result["status"] == "armed"
    assert w.ssm.writes == []
    assert w.sns.published == []


def test_rearm_skips_resources_that_no_longer_exist():
    s = st.tripped(st.armed("2026-11"), reason="drill", now=NOW, estimate=0.0)
    s["disabled_distributions"] = ["GONE"]
    s["concurrency"] = {"gone-function": 3}
    w = World(state=s)
    result = w.switch.run({"action": "rearm", "reason": "after drill"}, NOW)
    assert result["status"] == "armed"


def test_a_budget_notification_trips_even_below_the_estimate_threshold():
    w = World(cf_sums=QUIET)
    w.switch.run(budget_event(), NOW)
    assert w.ssm.state["status"] == "tripped"
    assert w.ssm.state["reason"] == "budget"


def test_a_record_from_another_topic_is_ignored_without_reading_anything():
    w = World(cf_sums=FLOOD)
    assert w.switch.run(budget_event("arn:aws:sns:eu-north-1:123456789012:other"), NOW) == {"status": "ignored"}
    assert w.cw_us.calls == []
    assert w.ssm.writes == []


def test_a_manual_trip_works_even_when_metrics_cannot_be_read():
    w = World(cw_fail=True)
    result = w.switch.run({"action": "trip", "reason": "drill"}, NOW)
    assert result["status"] == "tripped"
    assert result["estimate_usd"] is None
    assert w.cloudfront.enabled["E1"] is False


def test_check_fails_open_when_metrics_cannot_be_read():
    w = World(cw_fail=True)
    with pytest.raises(ClientError):
        w.switch.run({"action": "check"}, NOW)
    assert w.ssm.writes == []
    assert w.cloudfront.updates == []


def test_a_new_month_resets_acknowledged_before_deciding():
    w = World(cf_sums=QUIET, state=st.armed("2026-10", acknowledged=3.0))
    w.switch.run({"action": "check"}, NOW)
    assert w.ssm.state == st.armed("2026-11", acknowledged=0.0)


def test_status_reads_but_never_enforces_and_never_returns_ids():
    s = st.tripped(st.armed("2026-11"), reason="drill", now=NOW, estimate=1.0)
    s["disabled_distributions"] = ["E1SECRETID"]
    w = World(dists={"E1SECRETID": True}, state=s)
    result = w.switch.run({"action": "status"}, NOW)
    assert result["distributions"] == 1
    assert "E1SECRETID" not in json.dumps(result)
    assert w.cloudfront.updates == []


def test_a_malformed_state_raises():
    w = World()
    w.ssm.value = '{"status": "armed"}'
    with pytest.raises(st.StateError):
        w.switch.run({"action": "check"}, NOW)


def test_usage_reads_every_resource_with_the_right_dimensions():
    w = World(
        dists={"E1": True, "E2": False},
        functions={"cv-site-contact": (1024, 2)},
        apis=["api1"],
        cf_sums={
            ("AWS/CloudFront", "BytesDownloaded", "E1"): 3e9,
            ("AWS/CloudFront", "BytesUploaded", "E2"): 1e9,
            ("AWS/CloudFront", "Requests", "E1"): 10_000,
        },
        sums={
            ("AWS/ApiGateway", "Count", "api1"): 1e6,
            ("AWS/Lambda", "Invocations", "cv-site-contact"): 1e6,
            ("AWS/Lambda", "Duration", "cv-site-contact"): 2_000,  # ms at 1024 MB -> 2 GB-s
        },
    )
    usage = w.switch.usage(NOW)
    assert usage == handler.Usage(
        cloudfront_bytes=4e9, cloudfront_requests=10_000, api_requests=1e6, lambda_invocations=1e6, lambda_gb_seconds=2.0
    )
    cf = w.cw_us.calls[0]
    assert cf["Dimensions"] == [{"Name": "DistributionId", "Value": "E1"}, {"Name": "Region", "Value": "Global"}]
    assert cf["StartTime"] == datetime(2026, 11, 1, tzinfo=timezone.utc)
    assert cf["EndTime"] == datetime(2026, 11, 9, 14, 31, tzinfo=timezone.utc)
    assert all(c["Dimensions"][0]["Value"] != SELF for c in w.cw.calls)
    assert len(w.cw_us.calls) == 6  # 3 metrics x 2 distributions
    assert len(w.cw.calls) == 3  # Count + Invocations + Duration


def test_more_than_20_reads_logs_a_warning(caplog):
    w = World(dists={f"E{i}": True for i in range(7)}, cf_sums=QUIET)
    with caplog.at_level(logging.WARNING):
        w.switch.usage(NOW)
    assert "metric reads" in caplog.text


def test_lambda_handler_wires_the_environment(monkeypatch):
    w = World(cf_sums=QUIET)
    monkeypatch.setenv("STATE_PARAMETER", PARAM)
    monkeypatch.setenv("ALERTS_TOPIC_ARN", ALERTS)
    monkeypatch.setenv("TRIGGER_TOPIC_ARN", TRIGGER)
    monkeypatch.setenv("THRESHOLD_USD", "5")
    monkeypatch.setenv("AWS_LAMBDA_FUNCTION_NAME", SELF)
    monkeypatch.setattr(handler, "make_clients", lambda: w.switch.c)
    monkeypatch.setattr(handler, "_SWITCH", None)
    assert handler.lambda_handler({"action": "status"}, None)["status"] == "armed"
    assert handler._SWITCH.threshold_usd == 5.0


def test_a_distribution_and_a_function_are_recorded_before_they_are_changed():
    w = World(functions={"cv-site-contact": (128, 2)}, cf_sums=FLOOD)
    seen = []
    update, put = w.cloudfront.update_distribution, w.lambda_.put_function_concurrency

    def update_checked(Id, IfMatch, DistributionConfig):
        seen.append(("E1" in w.ssm.state["disabled_distributions"]))
        update(Id, IfMatch, DistributionConfig)

    def put_checked(FunctionName, ReservedConcurrentExecutions):
        seen.append(w.ssm.state["concurrency"].get(FunctionName) == 2)
        put(FunctionName, ReservedConcurrentExecutions)

    w.cloudfront.update_distribution = update_checked
    w.lambda_.put_function_concurrency = put_checked
    w.switch.run({"action": "check"}, NOW)
    assert seen == [True, True]

import json
import logging
from datetime import datetime, timezone

import pytest
from botocore.exceptions import ClientError, EndpointConnectionError

import handler
import state as st
from fakes import ALERTS, PARAM, SELF, TRIGGER, World

NOW = datetime(2026, 11, 9, 14, 30, tzinfo=timezone.utc)
FLOOD = {("AWS/CloudFront", "BytesDownloaded", "E1"): 50e9}  # 50 GB -> USD 6.00
NEW_ENV = {
    "MAX_DISTRIBUTIONS": "1",
    "MAX_APIS": "2",
    "MAX_FUNCTIONS": "3",
    "FREE_CLOUDFRONT_BYTES": "1000000000000",
    "FREE_CLOUDFRONT_REQUESTS": "10000000",
}
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
        "apis": 0,
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
    for k, v in NEW_ENV.items():
        monkeypatch.setenv(k, v)
    monkeypatch.setenv("AWS_LAMBDA_FUNCTION_NAME", SELF)
    monkeypatch.setattr(handler, "make_clients", lambda: w.switch.c)
    monkeypatch.setattr(handler, "_SWITCH", None)
    assert handler.lambda_handler({"action": "status"}, None)["status"] == "armed"
    assert handler._SWITCH.threshold_usd == 5.0
    sw = handler._SWITCH
    assert (sw.max_distributions, sw.max_apis, sw.max_functions) == (1, 2, 3)
    assert (sw.free_cloudfront_bytes, sw.free_cloudfront_requests) == (1e12, 1e7)


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


def _tripped_world(**kw):
    s = st.tripped(st.armed("2026-11"), reason="drill", now=NOW, estimate=1.0)
    s["disabled_distributions"] = ["E1"]
    return World(state=s, **kw)


def test_a_tripped_check_enforces_even_when_metrics_cannot_be_read():
    w = _tripped_world(cw_fail=True)
    result = w.switch.run({"action": "check"}, NOW)
    assert w.cloudfront.enabled["E1"] is False
    assert result["estimate_usd"] is None
    assert w.sns.published == []


def test_a_tripped_check_enforces_when_a_read_times_out():
    w = _tripped_world()

    def timeout(**_):
        raise EndpointConnectionError(endpoint_url="https://monitoring.example")

    w.cw_us.get_metric_statistics = timeout
    w.switch.run({"action": "check"}, NOW)
    assert w.cloudfront.enabled["E1"] is False


def test_status_and_rearm_still_fail_open_when_metrics_cannot_be_read():
    for action in ({"action": "status"}, {"action": "rearm", "reason": "x"}):
        w = _tripped_world(cw_fail=True)
        with pytest.raises(ClientError):
            w.switch.run(action, NOW)
        assert w.cloudfront.updates == []


def test_enforcement_counts_a_connection_error_as_a_failure_and_keeps_going():
    w = World(dists={"E1": True, "E2": True}, cf_sums=FLOOD)

    def flaky(Id, IfMatch, DistributionConfig):
        if Id == "E1":
            raise EndpointConnectionError(endpoint_url="https://cloudfront.example")
        w.cloudfront.enabled[Id] = DistributionConfig["Enabled"]

    w.cloudfront.update_distribution = flaky
    with pytest.raises(RuntimeError, match="1 enforcement action"):
        w.switch.run({"action": "check"}, NOW)
    assert w.cloudfront.enabled["E2"] is False


def _env(monkeypatch, clients):
    monkeypatch.setenv("STATE_PARAMETER", PARAM)
    monkeypatch.setenv("ALERTS_TOPIC_ARN", ALERTS)
    monkeypatch.setenv("TRIGGER_TOPIC_ARN", TRIGGER)
    monkeypatch.setenv("THRESHOLD_USD", "5")
    for k, v in NEW_ENV.items():
        monkeypatch.setenv(k, v)
    monkeypatch.setenv("AWS_LAMBDA_FUNCTION_NAME", SELF)
    monkeypatch.setattr(handler, "make_clients", lambda: clients)
    monkeypatch.setattr(handler, "_SWITCH", None)


def test_errors_leaving_the_lambda_carry_a_code_but_no_aws_text(monkeypatch):
    class Boom:
        def get_parameter(self, **_):
            raise ClientError(
                {"Error": {"Code": "AccessDenied", "Message": "not allowed: arn:aws:sts::123456789012:assumed-role/x"}},
                "GetParameter",
            )

    _env(monkeypatch, {"ssm": Boom()})
    with pytest.raises(RuntimeError) as info:
        handler.lambda_handler({"action": "check"}, None)
    assert "AccessDenied" in str(info.value)
    assert "123456789012" not in str(info.value)
    assert info.value.__suppress_context__ is True
    assert info.value.__cause__ is None


def test_an_unknown_action_surfaces_as_its_type_name(monkeypatch):
    _env(monkeypatch, World().switch.c)
    with pytest.raises(RuntimeError) as info:
        handler.lambda_handler({"action": "explode"}, None)
    assert str(info.value) == "kill switch failed: ValueError"


def test_a_trip_email_is_sent_even_when_enforcement_fails():
    w = World(dists={"E1": True, "E2": True}, cf_sums=FLOOD)

    def flaky(Id, IfMatch, DistributionConfig):
        if Id == "E1":
            raise ClientError({"Error": {"Code": "PreconditionFailed", "Message": "x"}}, "UpdateDistribution")
        w.cloudfront.enabled[Id] = DistributionConfig["Enabled"]

    w.cloudfront.update_distribution = flaky
    with pytest.raises(RuntimeError, match="1 enforcement action"):
        w.switch.run({"action": "check"}, NOW)
    assert [subject for subject, _ in w.sns.published] == ["Cost kill switch TRIPPED"]


def test_enforcement_is_complete_when_the_trip_email_cannot_be_sent():
    w = World(cf_sums=FLOOD)

    def down(**_):
        raise client_error_sns()

    def client_error_sns():
        return ClientError({"Error": {"Code": "InternalError", "Message": "x"}}, "Publish")

    w.sns.publish = down
    with pytest.raises(ClientError):
        w.switch.run({"action": "check"}, NOW)
    assert w.cloudfront.enabled["E1"] is False
    assert w.lambda_.reserved["cv-site-contact"] == 0
    assert w.ssm.state["status"] == "tripped"


def test_a_trip_enforces_once_per_run():
    w = World(cf_sums=FLOOD)
    calls = []
    original = w.switch.enforce
    w.switch.enforce = lambda s: calls.append(1) or original(s)
    w.switch.run({"action": "check"}, NOW)
    assert calls == [1]


def test_make_clients_use_short_timeouts_and_bounded_retries(monkeypatch):
    for k, v in {"AWS_DEFAULT_REGION": "eu-north-1", "AWS_ACCESS_KEY_ID": "x", "AWS_SECRET_ACCESS_KEY": "x"}.items():
        monkeypatch.setenv(k, v)
    clients = handler.make_clients()
    for client in clients.values():
        cfg = client.meta.config
        # botocore normalises max_attempts=3 (retries) to total_max_attempts=4 (calls)
        assert (cfg.connect_timeout, cfg.read_timeout) == (5, 10)
        assert cfg.retries == {"mode": "standard", "total_max_attempts": 4}
    assert clients["cloudwatch_us_east_1"].meta.region_name == "us-east-1"


def test_a_tripped_check_reads_no_metrics_and_still_re_disables():
    w = _tripped_world(cf_sums=FLOOD)
    w.cloudfront.enabled["E1"] = True  # re-enabled behind the switch's back
    result = w.switch.run({"action": "check"}, NOW)
    assert w.cw_us.calls == [] and w.cw.calls == []
    assert w.cloudfront.enabled["E1"] is False
    assert result["estimate_usd"] is None
    assert w.sns.published == []


def test_a_manual_trip_enforces_before_reading_any_metric():
    w = World(cf_sums=QUIET)
    seen = []
    original = w.cw_us.get_metric_statistics

    def checked(**kw):
        seen.append(w.cloudfront.enabled["E1"])
        return original(**kw)

    w.cw_us.get_metric_statistics = checked
    result = w.switch.run({"action": "trip", "reason": "drill"}, NOW)
    assert seen and not any(seen)  # every read happened after the distribution was disabled
    assert result["estimate_usd"] == pytest.approx(0.12)
    assert w.ssm.state["estimate_usd"] is None  # the late estimate is never persisted
    assert all(write["estimate_usd"] is None for write in w.ssm.writes)
    assert "USD 0.12" in w.sns.published[0][1]
    assert [subject for subject, _ in w.sns.published] == ["Cost kill switch TRIPPED"]


def test_a_budget_trip_still_trips_and_alerts_when_metrics_fail():
    w = World(cw_fail=True)
    result = w.switch.run(budget_event(), NOW)
    assert result["status"] == "tripped" and result["estimate_usd"] is None
    assert w.cloudfront.enabled["E1"] is False
    assert "unknown" in w.sns.published[0][1]


def test_a_trip_logs_an_enforcement_failure(caplog):
    w = World(dists={"E1": True}, cw_fail=True)
    w.cloudfront.update_distribution = lambda **_: (_ for _ in ()).throw(client_error_("UpdateDistribution"))
    with caplog.at_level(logging.ERROR), pytest.raises(RuntimeError):
        w.switch.run({"action": "trip", "reason": "drill"}, NOW)
    assert "enforcement failed during the trip" in caplog.text
    assert len(w.sns.published) == 1


def client_error_(op):
    return ClientError({"Error": {"Code": "PreconditionFailed", "Message": "x"}}, op)


def test_more_than_20_reads_in_a_run_raises_after_acting():
    w = World(dists={f"E{i}": True for i in range(7)}, cf_sums={("AWS/CloudFront", "BytesDownloaded", "E0"): 50e9})
    with pytest.raises(RuntimeError, match="metric reads in one run"):
        w.switch.run({"action": "check"}, NOW)
    assert w.ssm.state["status"] == "tripped"
    assert not any(w.cloudfront.enabled.values())
    assert [subject for subject, _ in w.sns.published] == ["Cost kill switch TRIPPED"]


def test_the_read_cap_error_leaves_the_lambda_sanitised(monkeypatch):
    w = World(dists={f"E{i}": True for i in range(7)}, cf_sums=QUIET)
    _env(monkeypatch, w.switch.c)
    with pytest.raises(RuntimeError) as info:
        handler.lambda_handler({"action": "check"}, None)
    assert str(info.value) == "kill switch failed: RuntimeError"


def test_a_partial_enforcement_failure_keeps_its_records_and_rearm_restores_them():
    w = World(dists={"E1": True, "E2": True}, cf_sums=QUIET)
    ok = w.cloudfront.update_distribution
    fail = True

    def flaky(Id, IfMatch, DistributionConfig):
        if Id == "E2" and fail:
            raise client_error_("UpdateDistribution")
        ok(Id, IfMatch, DistributionConfig)

    w.cloudfront.update_distribution = flaky
    with pytest.raises(RuntimeError, match="1 enforcement action"):
        w.switch.run({"action": "trip", "reason": "drill"}, NOW)
    s = w.ssm.state
    assert s["disabled_distributions"] == ["E1", "E2"]
    assert s["concurrency"] == {"cv-site-contact": 2}
    assert [subject for subject, _ in w.sns.published] == ["Cost kill switch TRIPPED"]
    assert "USD 0.12" in w.sns.published[0][1]
    fail = False
    w.switch.run({"action": "rearm", "reason": "test"}, NOW)
    assert w.cloudfront.enabled == {"E1": True, "E2": True}
    assert w.lambda_.reserved["cv-site-contact"] == 2


# --- hardening: HTTP API endpoint, inventory limits, CloudFront allowance


def _api_listing_call_counts(w):
    counts = {"cloudfront": 0, "lambda": 0, "apigatewayv2": 0}
    for key in counts:
        client = w.switch.c[key]
        original = client.get_paginator

        def counted(name, _o=original, _k=key):
            counts[_k] += 1
            return _o(name)

        client.get_paginator = counted
    return counts


def test_a_trip_disables_the_api_endpoint_and_a_rearm_restores_it():
    w = World(apis=["api1"], cf_sums=FLOOD)
    result = w.switch.run({"action": "check"}, NOW)
    assert w.apigw.disabled == {"api1": True}
    assert w.ssm.state["disabled_apis"] == ["api1"]
    assert result["apis"] == 1
    assert "api1" not in json.dumps(result)
    assert "HTTP API" in w.sns.published[0][1]
    assert "api1" not in w.sns.published[0][1]
    result = w.switch.run({"action": "rearm", "reason": "over"}, NOW)
    assert w.apigw.disabled == {"api1": False}
    assert w.ssm.state["disabled_apis"] == []
    assert result["apis"] == 0
    body = w.sns.published[1][1]
    assert "1 distribution(s)" in body and "1 HTTP API(s)" in body and "1 function(s)" in body
    assert "api1" not in body


def test_enforcement_goes_distributions_then_apis_then_functions():
    w = World(apis=["api1"], cf_sums=FLOOD)
    order = []
    cf_update, api_update, put = w.cloudfront.update_distribution, w.apigw.update_api, w.lambda_.put_function_concurrency
    w.cloudfront.update_distribution = lambda **kw: order.append("cf") or cf_update(**kw)
    w.apigw.update_api = lambda **kw: order.append("api") or api_update(**kw)
    w.lambda_.put_function_concurrency = lambda **kw: order.append("fn") or put(**kw)
    w.switch.run({"action": "check"}, NOW)
    assert order == ["cf", "api", "fn"]


def test_an_api_is_recorded_before_its_endpoint_is_changed():
    w = World(apis=["api1"], cf_sums=FLOOD)
    seen = []
    update = w.apigw.update_api

    def checked(ApiId, DisableExecuteApiEndpoint):
        seen.append(ApiId in w.ssm.state["disabled_apis"])
        update(ApiId, DisableExecuteApiEndpoint)

    w.apigw.update_api = checked
    w.switch.run({"action": "check"}, NOW)
    assert seen == [True]


def test_an_api_whose_endpoint_is_already_disabled_is_not_recorded_or_touched():
    w = World(apis={"api1": True, "api2": False}, cf_sums=FLOOD)
    w.switch.run({"action": "check"}, NOW)
    assert w.ssm.state["disabled_apis"] == ["api2"]
    assert w.apigw.updates == [("api2", True)]
    w.switch.run({"action": "rearm", "reason": "x"}, NOW)
    assert w.apigw.disabled == {"api1": True, "api2": False}  # api1 was never ours to restore


def test_while_tripped_a_re_enabled_endpoint_is_disabled_again_without_a_duplicate_record():
    w = World(apis=["api1"], cf_sums=FLOOD)
    w.switch.run({"action": "check"}, NOW)
    w.apigw.disabled["api1"] = False  # re-enabled behind the switch's back
    w.apigw.disabled["api9"] = False  # a new API
    w.switch.run({"action": "check"}, NOW)
    assert w.apigw.disabled == {"api1": True, "api9": True}
    assert w.ssm.state["disabled_apis"] == ["api1", "api9"]
    assert len(w.sns.published) == 1


def test_rearm_restores_only_recorded_apis_and_skips_a_missing_one():
    s = st.tripped(st.armed("2026-11"), reason="drill", now=NOW, estimate=0.0)
    s["disabled_apis"] = ["gone", "api1"]
    w = World(state=s, apis={"api1": True, "other": True})
    result = w.switch.run({"action": "rearm", "reason": "after drill"}, NOW)
    assert result["status"] == "armed"
    assert w.apigw.disabled == {"api1": False, "other": True}
    assert w.ssm.state["disabled_apis"] == []


def test_rearm_does_not_swallow_other_api_errors_and_stays_tripped():
    s = st.tripped(st.armed("2026-11"), reason="drill", now=NOW, estimate=0.0)
    s["disabled_apis"] = ["api1"]
    w = World(state=s, apis={"api1": True})
    w.apigw.update_api = lambda **_: (_ for _ in ()).throw(client_error_("UpdateApi"))
    with pytest.raises(ClientError):
        w.switch.run({"action": "rearm", "reason": "x"}, NOW)
    assert w.ssm.state["status"] == "tripped" and w.ssm.state["disabled_apis"] == ["api1"]


def test_a_partial_api_enforcement_failure_keeps_its_records_and_rearm_restores_them():
    w = World(apis=["api1", "api2"], cf_sums=QUIET)
    ok = w.apigw.update_api
    fail = True

    def flaky(ApiId, DisableExecuteApiEndpoint):
        if ApiId == "api2" and fail:
            raise client_error_("UpdateApi")
        ok(ApiId, DisableExecuteApiEndpoint)

    w.apigw.update_api = flaky
    with pytest.raises(RuntimeError, match="1 enforcement action"):
        w.switch.run({"action": "trip", "reason": "drill"}, NOW)
    assert w.ssm.state["disabled_apis"] == ["api1", "api2"]
    assert w.lambda_.reserved["cv-site-contact"] == 0  # the later phase still ran
    assert [subject for subject, _ in w.sns.published] == ["Cost kill switch TRIPPED"]
    fail = False
    w.switch.run({"action": "rearm", "reason": "test"}, NOW)
    assert w.apigw.disabled == {"api1": False, "api2": False}


INVENTORY_CASES = [
    ({"dists": {"E1": True, "E2": True}}, (1, 100, 100), "inventory: 2 distributions (limit 1)"),
    ({"apis": ["a1", "a2"]}, (100, 1, 100), "inventory: 2 HTTP APIs (limit 1)"),
    ({"functions": {"f1": (128, 2), "f2": (128, None)}}, (100, 100, 1), "inventory: 2 functions (limit 1)"),
]


def _inventory_world(kwargs, limits, cf_sums=FLOOD, **extra):
    return World(**{"apis": ["a0"], **kwargs}, limits=limits, cf_sums=cf_sums, **extra)


def _fully_enforced(w):
    return (
        not any(w.cloudfront.enabled.values())
        and all(w.apigw.disabled.values())
        and all(r == 0 for n, r in w.lambda_.reserved.items() if n != SELF)
    )


@pytest.mark.parametrize("kwargs, limits, reason", INVENTORY_CASES)
def test_an_inventory_over_its_limit_trips_and_enforces_without_any_metric_read(kwargs, limits, reason):
    w = _inventory_world(kwargs, limits, cw_fail=True)  # a read would raise: enforcement must not wait on one
    result = w.switch.run({"action": "check"}, NOW)
    assert w.ssm.state["status"] == "tripped"
    assert w.ssm.state["reason"] == reason
    assert result["reason"] == reason and result["estimate_usd"] is None
    assert w.cw_us.calls == [] and w.cw.calls == []
    assert _fully_enforced(w)
    assert [subject for subject, _ in w.sns.published] == ["Cost kill switch TRIPPED"]
    assert reason in w.sns.published[0][1]
    assert w.ssm.writes[0]["status"] == "tripped" and w.ssm.writes[0]["disabled_distributions"] == []


@pytest.mark.parametrize("kwargs, limits, reason", INVENTORY_CASES)
def test_an_inventory_trip_reads_metrics_only_after_enforcement_for_the_email(kwargs, limits, reason):
    w = _inventory_world(kwargs, limits)
    states = []
    original = w.cw_us.get_metric_statistics

    def checked(**kw):
        states.append(_fully_enforced(w))
        return original(**kw)

    w.cw_us.get_metric_statistics = checked
    result = w.switch.run({"action": "check"}, NOW)
    assert states and all(states)
    assert result["estimate_usd"] == pytest.approx(6.0)
    assert "USD 6.00" in w.sns.published[0][1]
    assert w.ssm.state["estimate_usd"] is None


@pytest.mark.parametrize("kwargs, limits, reason", INVENTORY_CASES)
def test_exactly_at_the_limit_does_not_trip(kwargs, limits, reason):
    at_limit = tuple(2 if lim == 1 else lim for lim in limits)  # the kind with 2 items now has limit 2
    w = _inventory_world(kwargs, at_limit, cf_sums=QUIET)
    result = w.switch.run({"action": "check"}, NOW)
    assert result["status"] == "armed"
    assert w.ssm.writes == [] and w.sns.published == []


def test_the_first_kind_over_its_limit_is_reported_in_order_distributions_apis_functions():
    w = World(
        dists={"E1": True, "E2": True},
        apis=["a1", "a2"],
        functions={"f1": (128, 2), "f2": (128, 2)},
        limits=(1, 1, 1),
    )
    w.switch.run({"action": "check"}, NOW)
    assert w.ssm.state["reason"] == "inventory: 2 distributions (limit 1)"
    w = World(apis=["a1", "a2"], functions={"f1": (128, 2), "f2": (128, 2)}, limits=(1, 1, 1))
    w.switch.run({"action": "check"}, NOW)
    assert w.ssm.state["reason"] == "inventory: 2 HTTP APIs (limit 1)"


def test_the_inventory_counts_functions_other_than_the_switch():
    w = World(functions={"cv-site-contact": (128, 2)}, limits=(1, 1, 1), cf_sums=QUIET)  # SELF + 1 function
    assert w.switch.run({"action": "check"}, NOW)["status"] == "armed"


def test_an_armed_check_lists_each_kind_once_and_reuses_the_listings_for_the_metric_reads():
    w = World(apis=["api1"], cf_sums=QUIET)
    counts = _api_listing_call_counts(w)
    w.switch.run({"action": "check"}, NOW)
    assert counts == {"cloudfront": 1, "lambda": 1, "apigatewayv2": 1}
    assert len(w.cw_us.calls) == 3 and len(w.cw.calls) == 3


def test_a_failing_listing_while_armed_raises_and_changes_nothing():
    w = World(cf_sums=FLOOD)

    def broken(name):
        raise client_error_("ListDistributions")

    w.cloudfront.get_paginator = broken
    with pytest.raises(ClientError):
        w.switch.run({"action": "check"}, NOW)
    assert w.ssm.writes == [] and w.lambda_.reserved["cv-site-contact"] == 2


def test_while_tripped_the_inventory_check_does_not_run():
    s = st.tripped(st.armed("2026-11"), reason="drill", now=NOW, estimate=1.0)
    w = World(state=s, dists={"E1": True, "E2": True}, apis=["a1", "a2"], limits=(1, 1, 1))
    result = w.switch.run({"action": "check"}, NOW)
    assert result["reason"] == "drill"  # not replaced by an inventory reason
    assert w.sns.published == []
    assert _fully_enforced(w)  # enforcement still ran, as it does for any tripped check


def test_a_status_never_trips_on_inventory():
    w = World(dists={"E1": True, "E2": True}, limits=(1, 1, 1), cf_sums=QUIET)
    assert w.switch.run({"action": "status"}, NOW)["status"] == "armed"


# CloudFront free allowance: USD 6.00 of bytes is 50 GB; a 1 TB allowance covers it.
def test_a_flood_under_the_allowance_does_not_trip_when_the_allowance_is_configured():
    without = World(cf_sums=FLOOD)
    without.switch.run({"action": "check"}, NOW)
    assert without.ssm.state["status"] == "tripped"
    w = World(cf_sums=FLOOD, allowances=(1e12, 1e7))
    result = w.switch.run({"action": "check"}, NOW)
    assert result["status"] == "armed" and result["estimate_usd"] == 0.0
    assert w.sns.published == []


def test_a_flood_over_the_allowance_trips_on_the_billable_part_only():
    w = World(cf_sums={("AWS/CloudFront", "BytesDownloaded", "E1"): 1e12 + 50e9}, allowances=(1e12, 1e7))
    result = w.switch.run({"action": "check"}, NOW)
    assert result["status"] == "tripped" and result["estimate_usd"] == pytest.approx(6.0)
    assert w.ssm.state["reason"] == "estimated spend USD 6.00 this month is over the USD 5 threshold"


def test_the_allowance_applies_to_status_rearm_acknowledgement_and_the_email():
    w = World(cf_sums={("AWS/CloudFront", "BytesDownloaded", "E1"): 1e12 + 50e9}, allowances=(1e12, 1e7))
    w.switch.run({"action": "check"}, NOW)
    assert w.switch.run({"action": "status"}, NOW)["estimate_usd"] == pytest.approx(6.0)
    w.switch.run({"action": "rearm", "reason": "ok"}, NOW)
    assert w.ssm.state["acknowledged_usd"] == pytest.approx(6.0)
    assert "USD 6.00" in w.sns.published[0][1]


def test_a_manual_trip_estimate_uses_the_allowance():
    w = World(cf_sums=FLOOD, allowances=(1e12, 1e7))
    assert w.switch.run({"action": "trip", "reason": "drill"}, NOW)["estimate_usd"] == 0.0


def test_the_trip_email_mentions_the_api_endpoints():
    w = World(cf_sums=FLOOD)
    w.switch.run({"action": "check"}, NOW)
    assert "HTTP API" in w.sns.published[0][1]


def test_a_missing_new_environment_variable_fails_sanitised(monkeypatch):
    for missing in NEW_ENV:
        _env(monkeypatch, World().switch.c)
        monkeypatch.delenv(missing)
        with pytest.raises(RuntimeError) as info:
            handler.lambda_handler({"action": "status"}, None)
        assert str(info.value) == "kill switch failed: KeyError"

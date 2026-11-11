"""The real boto3 call shapes, validated by botocore Stubber against the service models."""

import copy
from datetime import datetime, timezone

import boto3
from botocore.stub import Stubber

from fakes import ALERTS, PARAM, TRIGGER
from handler import KillSwitch

NOW = datetime(2026, 11, 9, 14, 30, tzinfo=timezone.utc)
# The smallest DistributionConfig botocore accepts.
MIN_CONFIG = {
    "CallerReference": "ref",
    "Comment": "",
    "Enabled": True,
    "Origins": {"Quantity": 1, "Items": [{"Id": "o", "DomainName": "example.com"}]},
    "DefaultCacheBehavior": {"TargetOriginId": "o", "ViewerProtocolPolicy": "redirect-to-https"},
}


def client(name, region="eu-north-1"):
    return boto3.client(name, region_name=region, aws_access_key_id="x", aws_secret_access_key="x")


def switch_with(**clients):
    base = {k: None for k in ("cloudwatch_us_east_1", "cloudwatch", "cloudfront", "lambda", "apigatewayv2", "ssm", "sns")}
    base.update(clients)
    return KillSwitch(
        base,
        self_name="cost-kill-switch",
        state_parameter=PARAM,
        alerts_topic_arn=ALERTS,
        trigger_topic_arn=TRIGGER,
        threshold_usd=5.0,
        max_distributions=1,
        max_apis=1,
        max_functions=1,
        free_cloudfront_bytes=0.0,
        free_cloudfront_requests=0.0,
    )


def test_disabling_a_distribution_sends_the_config_back_with_its_etag():
    cf = client("cloudfront", "us-east-1")
    with Stubber(cf) as stub:
        # A copy: the code flips Enabled on the config it receives.
        stub.add_response("get_distribution_config", {"DistributionConfig": copy.deepcopy(MIN_CONFIG), "ETag": "ETAG1"}, {"Id": "E1"})
        stub.add_response(
            "update_distribution", {}, {"Id": "E1", "IfMatch": "ETAG1", "DistributionConfig": {**MIN_CONFIG, "Enabled": False}}
        )
        switch_with(cloudfront=cf).set_distribution_enabled("E1", False)
        stub.assert_no_pending_responses()


def test_metric_sum_asks_for_hourly_sums():
    cw = client("cloudwatch", "us-east-1")
    dims = [{"Name": "DistributionId", "Value": "E1"}, {"Name": "Region", "Value": "Global"}]
    start, end = datetime(2026, 11, 1, tzinfo=timezone.utc), NOW
    with Stubber(cw) as stub:
        stub.add_response(
            "get_metric_statistics",
            {"Datapoints": [{"Sum": 2.0}, {"Sum": 3.0}]},
            {
                "Namespace": "AWS/CloudFront",
                "MetricName": "Requests",
                "Dimensions": dims,
                "StartTime": start,
                "EndTime": end,
                "Period": 3600,
                "Statistics": ["Sum"],
            },
        )
        assert switch_with(cloudwatch_us_east_1=cw).metric_sum("cloudwatch_us_east_1", "AWS/CloudFront", "Requests", dims, start, end) == 5.0


def test_concurrency_calls():
    lam = client("lambda")
    with Stubber(lam) as stub:
        stub.add_response("get_function_concurrency", {"ReservedConcurrentExecutions": 2}, {"FunctionName": "cv-site-contact"})
        stub.add_response(
            "put_function_concurrency",
            {"ReservedConcurrentExecutions": 0},
            {"FunctionName": "cv-site-contact", "ReservedConcurrentExecutions": 0},
        )
        stub.add_response("delete_function_concurrency", {}, {"FunctionName": "other"})
        s = switch_with(**{"lambda": lam})
        assert s.reserved_concurrency("cv-site-contact") == 2
        s.set_reserved_concurrency("cv-site-contact", 0)
        s.set_reserved_concurrency("other", None)
        stub.assert_no_pending_responses()


def test_api_endpoint_calls():
    api = client("apigatewayv2")
    with Stubber(api) as stub:
        stub.add_response("update_api", {}, {"ApiId": "a1", "DisableExecuteApiEndpoint": True})
        stub.add_response("update_api", {}, {"ApiId": "a1", "DisableExecuteApiEndpoint": False})
        s = switch_with(apigatewayv2=api)
        s.set_api_endpoint_disabled("a1", True)
        s.set_api_endpoint_disabled("a1", False)
        stub.assert_no_pending_responses()


def test_listing_apis_reads_the_endpoint_flag_and_treats_a_missing_one_as_enabled():
    api = client("apigatewayv2")
    with Stubber(api) as stub:
        stub.add_response(
            "get_apis",
            {"Items": [{"ApiId": "a1", "Name": "n", "ProtocolType": "HTTP", "RouteSelectionExpression": "x", "DisableExecuteApiEndpoint": True}, {"ApiId": "a2", "Name": "m", "ProtocolType": "HTTP", "RouteSelectionExpression": "x"}]},
        )
        assert switch_with(apigatewayv2=api).apis() == [
            {"ApiId": "a1", "DisableExecuteApiEndpoint": True},
            {"ApiId": "a2", "DisableExecuteApiEndpoint": False},
        ]
        stub.assert_no_pending_responses()


def test_state_and_alert_calls():
    ssm, sns = client("ssm"), client("sns")
    with Stubber(ssm) as s_stub, Stubber(sns) as n_stub:
        s_stub.add_response("put_parameter", {"Version": 2}, {"Name": PARAM, "Value": '{"x":1}', "Type": "String", "Overwrite": True})
        n_stub.add_response("publish", {"MessageId": "m"}, {"TopicArn": ALERTS, "Subject": "S", "Message": "M"})
        s = switch_with(ssm=ssm, sns=sns)
        s.put_state_text('{"x":1}')
        s.alert("S", "M")
        s_stub.assert_no_pending_responses()
        n_stub.assert_no_pending_responses()

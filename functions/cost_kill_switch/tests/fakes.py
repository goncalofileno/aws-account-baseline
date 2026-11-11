"""In-memory stand-ins for the boto3 clients the kill switch uses (flow tests).

The exact call shapes are checked separately against botocore's models (test_contracts.py).
"""

from botocore.exceptions import ClientError

import state as st
from handler import KillSwitch

SELF = "cost-kill-switch"
PARAM = "/cost-kill-switch/state"
ALERTS = "arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-alerts"
TRIGGER = "arn:aws:sns:eu-north-1:123456789012:cost-kill-switch-trigger"


def client_error(code, op):
    return ClientError({"Error": {"Code": code, "Message": code}}, op)


class Paginator:
    def __init__(self, pages):
        self.pages = pages

    def paginate(self, **_):
        return iter(self.pages)


class CloudFront:
    def __init__(self, dists):
        self.enabled = dict(dists)  # id -> Enabled
        self.updates = []

    def get_paginator(self, name):
        assert name == "list_distributions"
        items = [{"Id": i, "Enabled": e} for i, e in self.enabled.items()]
        return Paginator([{"DistributionList": {"Items": items} if items else {}}])

    def get_distribution_config(self, Id):
        if Id not in self.enabled:
            raise client_error("NoSuchDistribution", "GetDistributionConfig")
        return {"DistributionConfig": {"Enabled": self.enabled[Id], "Comment": ""}, "ETag": f"etag-{Id}"}

    def update_distribution(self, Id, IfMatch, DistributionConfig):
        assert IfMatch == f"etag-{Id}"
        self.enabled[Id] = DistributionConfig["Enabled"]
        self.updates.append((Id, DistributionConfig["Enabled"]))


class Lambda:
    def __init__(self, functions):
        # name -> (memory_mb, reserved concurrency or None)
        self.memory = {n: m for n, (m, _) in functions.items()}
        self.reserved = {n: r for n, (_, r) in functions.items()}

    def get_paginator(self, name):
        assert name == "list_functions"
        return Paginator([{"Functions": [{"FunctionName": n, "MemorySize": m} for n, m in self.memory.items()]}])

    def _check(self, name, op):
        assert name != SELF, "the kill switch must never touch its own concurrency"
        if name not in self.reserved:
            raise client_error("ResourceNotFoundException", op)

    def get_function_concurrency(self, FunctionName):
        self._check(FunctionName, "GetFunctionConcurrency")
        r = self.reserved[FunctionName]
        return {} if r is None else {"ReservedConcurrentExecutions": r}

    def put_function_concurrency(self, FunctionName, ReservedConcurrentExecutions):
        self._check(FunctionName, "PutFunctionConcurrency")
        self.reserved[FunctionName] = ReservedConcurrentExecutions

    def delete_function_concurrency(self, FunctionName):
        self._check(FunctionName, "DeleteFunctionConcurrency")
        self.reserved[FunctionName] = None


class ApiGateway:
    def __init__(self, apis):
        # A list of API IDs (endpoint enabled) or a dict id -> DisableExecuteApiEndpoint.
        self.disabled = dict(apis) if isinstance(apis, dict) else {a: False for a in apis}
        self.updates = []

    def get_paginator(self, name):
        assert name == "get_apis"
        # The field is absent from a response item when it was never set: represent False that way.
        items = [{"ApiId": a, **({"DisableExecuteApiEndpoint": True} if d else {})} for a, d in self.disabled.items()]
        return Paginator([{"Items": items}])

    def update_api(self, ApiId, DisableExecuteApiEndpoint):
        if ApiId not in self.disabled:
            raise client_error("NotFoundException", "UpdateApi")
        self.disabled[ApiId] = DisableExecuteApiEndpoint
        self.updates.append((ApiId, DisableExecuteApiEndpoint))


class CloudWatch:
    def __init__(self, sums, fail=False):
        self.sums = sums  # (namespace, metric, first dimension value) -> sum
        self.fail = fail
        self.calls = []

    def get_metric_statistics(self, **kw):
        if self.fail:
            raise client_error("Throttling", "GetMetricStatistics")
        assert kw["Period"] == 3600 and kw["Statistics"] == ["Sum"]
        self.calls.append(kw)
        v = self.sums.get((kw["Namespace"], kw["MetricName"], kw["Dimensions"][0]["Value"]), 0.0)
        return {"Datapoints": [{"Sum": v}] if v else []}


class Ssm:
    def __init__(self, value):
        self.value = value
        self.writes = []

    def get_parameter(self, Name):
        assert Name == PARAM
        if self.value is None:
            raise client_error("ParameterNotFound", "GetParameter")
        return {"Parameter": {"Value": self.value}}

    def put_parameter(self, Name, Value, Type, Overwrite):
        assert (Name, Type, Overwrite) == (PARAM, "String", True)
        self.value = Value
        self.writes.append(st.parse(Value))

    @property
    def state(self):
        return st.parse(self.value)


class Sns:
    def __init__(self):
        self.published = []

    def publish(self, TopicArn, Subject, Message):
        assert TopicArn == ALERTS
        self.published.append((Subject, Message))


class World:
    """One fake account: distributions, functions, APIs, metric sums and the stored state."""

    def __init__(
        self,
        *,
        dists=None,
        functions=None,
        apis=(),
        cf_sums=None,
        sums=None,
        state=None,
        cw_fail=False,
        limits=(100, 100, 100),  # distributions, APIs, functions: high so old scenarios never hit them
        allowances=(0.0, 0.0),  # CloudFront bytes, requests
    ):
        functions = {SELF: (128, 1), **(functions if functions is not None else {"cv-site-contact": (128, 2)})}
        self.cloudfront = CloudFront(dists if dists is not None else {"E1": True})
        self.lambda_ = Lambda(functions)
        self.cw_us = CloudWatch(cf_sums or {}, fail=cw_fail)
        self.cw = CloudWatch(sums or {}, fail=cw_fail)
        self.ssm = Ssm(st.dump(state if state is not None else st.armed("2026-11")))
        self.sns = Sns()
        self.apigw = ApiGateway(apis)
        self.switch = KillSwitch(
            {
                "cloudwatch_us_east_1": self.cw_us,
                "cloudwatch": self.cw,
                "cloudfront": self.cloudfront,
                "lambda": self.lambda_,
                "apigatewayv2": self.apigw,
                "ssm": self.ssm,
                "sns": self.sns,
            },
            self_name=SELF,
            state_parameter=PARAM,
            alerts_topic_arn=ALERTS,
            trigger_topic_arn=TRIGGER,
            threshold_usd=5.0,
            max_distributions=limits[0],
            max_apis=limits[1],
            max_functions=limits[2],
            free_cloudfront_bytes=allowances[0],
            free_cloudfront_requests=allowances[1],
        )

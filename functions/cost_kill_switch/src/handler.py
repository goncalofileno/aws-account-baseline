"""Cost kill switch: estimates this month's AWS spend and takes the site offline above a threshold.

Design: docs/specs/2026-11-09-cost-kill-switch-design.md. Read failures raise (fail open, the errors
alarm emails); the state is written before any resource is changed.
"""

import copy
import json
import logging
import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

import state as st
from events import parse_event
from pricing import Usage, estimate_usd, over_threshold

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

READS_WARNING = 20  # at one run a minute, more than this per run leaves the 1M free reads a month
STATE_MAX_BYTES = 3800  # an SSM Standard parameter holds 4096 bytes; the rest is headroom
MIN_REMAINING_MS = 10_000  # enforcement stops with this much time left, so the alert still goes out
REARM_HINT = "Rearm: GitHub, aws-account-baseline, Actions, kill-switch workflow, action rearm."


def _code(error: ClientError) -> str:
    return error.response.get("Error", {}).get("Code", "")


def _usd(value) -> str:
    return "unknown" if value is None else f"USD {value:.2f}"


def summary(s: dict, estimate: float | None) -> dict:
    """What callers see: counts, never resource IDs."""
    return {
        "status": s["status"],
        "reason": s["reason"],
        "tripped_at": s["tripped_at"],
        "estimate_usd": None if estimate is None else round(estimate, 4),
        "acknowledged_usd": s["acknowledged_usd"],
        "distributions": len(s["disabled_distributions"]),
        "apis": len(s["disabled_apis"]),
        "functions": len(s["concurrency"]),
    }


class KillSwitch:
    def __init__(
        self,
        clients,
        *,
        self_name,
        state_parameter,
        alerts_topic_arn,
        trigger_topic_arn,
        threshold_usd,
        max_distributions,
        max_apis,
        max_functions,
        free_cloudfront_bytes,
        free_cloudfront_requests,
    ):
        self.c = clients
        self.self_name = self_name
        self.state_parameter = state_parameter
        self.alerts_topic_arn = alerts_topic_arn
        self.trigger_topic_arn = trigger_topic_arn
        self.threshold_usd = float(threshold_usd)
        self.max_distributions = int(max_distributions)
        self.max_apis = int(max_apis)
        self.max_functions = int(max_functions)
        self.free_cloudfront_bytes = float(free_cloudfront_bytes)
        self.free_cloudfront_requests = float(free_cloudfront_requests)
        self.reads = 0
        self.unrecorded = 0
        self._remaining_ms = None

    # --- state and alerts

    def load_state(self) -> dict:
        return st.parse(self.c["ssm"].get_parameter(Name=self.state_parameter)["Parameter"]["Value"])

    def put_state_text(self, text: str) -> None:
        self.c["ssm"].put_parameter(Name=self.state_parameter, Value=text, Type="String", Overwrite=True)

    def save_state(self, s: dict) -> None:
        self.put_state_text(st.dump(s))

    def alert(self, subject: str, message: str) -> None:
        self.c["sns"].publish(TopicArn=self.alerts_topic_arn, Subject=subject[:100], Message=message)

    # --- inventory

    def distributions(self) -> list[dict]:
        out = []
        for page in self.c["cloudfront"].get_paginator("list_distributions").paginate():
            out += [{"Id": d["Id"], "Enabled": d["Enabled"]} for d in page["DistributionList"].get("Items", [])]
        return out

    def functions(self) -> list[dict]:
        out = []
        for page in self.c["lambda"].get_paginator("list_functions").paginate():
            out += [
                {"FunctionName": f["FunctionName"], "MemorySize": f["MemorySize"]}
                for f in page["Functions"]
                if f["FunctionName"] != self.self_name
            ]
        return out

    def apis(self) -> list[dict]:
        out = []
        for page in self.c["apigatewayv2"].get_paginator("get_apis").paginate():
            out += [
                {"ApiId": a["ApiId"], "DisableExecuteApiEndpoint": bool(a.get("DisableExecuteApiEndpoint", False))}
                for a in page.get("Items", [])
            ]
        return out

    def inventory(self) -> dict:
        """One listing of each kind; the metric reads of the same run reuse it."""
        return {"distributions": self.distributions(), "apis": self.apis(), "functions": self.functions()}

    def inventory_breach(self, inv: dict) -> str | None:
        """The reason to trip when a kind is over its limit (first in the order distributions, APIs, functions)."""
        for key, kind, limit in (
            ("distributions", "distributions", self.max_distributions),
            ("apis", "HTTP APIs", self.max_apis),
            ("functions", "functions", self.max_functions),
        ):
            if len(inv[key]) > limit:
                return f"inventory: {len(inv[key])} {kind} (limit {limit})"
        return None

    def estimate(self, usage: Usage) -> float:
        return estimate_usd(
            usage,
            free_cloudfront_bytes=self.free_cloudfront_bytes,
            free_cloudfront_requests=self.free_cloudfront_requests,
        )

    # --- metrics

    def metric_sum(self, client_key, namespace, metric, dimensions, start, end) -> float:
        self.reads += 1
        response = self.c[client_key].get_metric_statistics(
            Namespace=namespace,
            MetricName=metric,
            Dimensions=dimensions,
            StartTime=start,
            EndTime=end,
            Period=3600,
            Statistics=["Sum"],
        )
        return sum(p["Sum"] for p in response["Datapoints"])

    def usage(self, now: datetime, inv: dict | None = None) -> Usage:
        inv = inv if inv is not None else self.inventory()
        self.reads = 0
        start, end = st.month_start(now), now + timedelta(minutes=1)
        cf_down = cf_up = cf_requests = api_requests = invocations = gb_seconds = 0.0
        for d in inv["distributions"]:
            dims = [{"Name": "DistributionId", "Value": d["Id"]}, {"Name": "Region", "Value": "Global"}]
            cf_down += self.metric_sum("cloudwatch_us_east_1", "AWS/CloudFront", "BytesDownloaded", dims, start, end)
            cf_up += self.metric_sum("cloudwatch_us_east_1", "AWS/CloudFront", "BytesUploaded", dims, start, end)
            cf_requests += self.metric_sum("cloudwatch_us_east_1", "AWS/CloudFront", "Requests", dims, start, end)
        for api in inv["apis"]:
            dims = [{"Name": "ApiId", "Value": api["ApiId"]}]
            api_requests += self.metric_sum("cloudwatch", "AWS/ApiGateway", "Count", dims, start, end)
        for f in inv["functions"]:
            dims = [{"Name": "FunctionName", "Value": f["FunctionName"]}]
            invocations += self.metric_sum("cloudwatch", "AWS/Lambda", "Invocations", dims, start, end)
            duration_ms = self.metric_sum("cloudwatch", "AWS/Lambda", "Duration", dims, start, end)
            gb_seconds += duration_ms / 1000 * f["MemorySize"] / 1024
        if self.reads > READS_WARNING:
            LOG.warning("%d metric reads in one run: above the free tier at one run a minute", self.reads)
        return Usage(cf_down, cf_up, cf_requests, api_requests, invocations, gb_seconds)

    # --- actions

    def set_distribution_enabled(self, dist_id: str, enabled: bool) -> None:
        cf = self.c["cloudfront"]
        response = cf.get_distribution_config(Id=dist_id)
        config = response["DistributionConfig"]
        if config["Enabled"] == enabled:
            return
        config["Enabled"] = enabled
        cf.update_distribution(Id=dist_id, IfMatch=response["ETag"], DistributionConfig=config)

    def set_api_endpoint_disabled(self, api_id: str, disabled: bool) -> None:
        self.c["apigatewayv2"].update_api(ApiId=api_id, DisableExecuteApiEndpoint=disabled)

    def reserved_concurrency(self, name: str) -> int | None:
        return self.c["lambda"].get_function_concurrency(FunctionName=name).get("ReservedConcurrentExecutions")

    def set_reserved_concurrency(self, name: str, value: int | None) -> None:
        if value is None:
            self.c["lambda"].delete_function_concurrency(FunctionName=name)
        else:
            self.c["lambda"].put_function_concurrency(FunctionName=name, ReservedConcurrentExecutions=value)

    def _time_is_low(self) -> bool:
        return self._remaining_ms is not None and self._remaining_ms() < MIN_REMAINING_MS

    def enforce(self, s: dict) -> dict:
        """Disable every enabled distribution, every API Gateway v2 API's default endpoint and every other
        function's concurrency (in that order), recording each ID first.

        The kinds are independent: a listing, a record save or a change that fails is counted and logged and
        the rest carries on. Enforcement stops, counted as a failure, when the remaining time runs low, so the
        alert still goes out; the next run continues.
        """
        s = copy.deepcopy(s)
        failures = 0
        self.unrecorded = 0
        out_of_time = False

        def halt() -> bool:
            nonlocal failures, out_of_time
            if not out_of_time and self._time_is_low():
                LOG.warning("out of time; the next run continues")
                out_of_time = True
                failures += 1
            return out_of_time

        def record(items, key, value=None) -> bool:
            """Record before changing. False: the record could not be saved, so leave the resource alone.

            Deliberate exception to record-before-change: if the document would outgrow the SSM parameter,
            the resource is still stopped but not recorded (cost over restoration; only reachable with
            dozens of long-named resources). It is counted in self.unrecorded and reported in the alert.
            """
            nonlocal failures
            add = (lambda: items.append(key)) if isinstance(items, list) else (lambda: items.__setitem__(key, value))
            add()
            if len(st.dump(s).encode()) > STATE_MAX_BYTES:
                items.remove(key) if isinstance(items, list) else items.pop(key)
                self.unrecorded += 1
                return True
            try:
                self.save_state(s)
            except (ClientError, BotoCoreError):
                LOG.exception("could not save a record; leaving its resource unchanged")
                items.remove(key) if isinstance(items, list) else items.pop(key)
                failures += 1
                return False
            return True

        try:
            dists = self.distributions()
        except (ClientError, BotoCoreError):
            LOG.exception("could not list distributions")
            failures += 1
            dists = []
        for d in dists:
            if halt():
                break
            if not d["Enabled"]:
                continue
            if d["Id"] not in s["disabled_distributions"] and not record(s["disabled_distributions"], d["Id"]):
                continue
            try:
                self.set_distribution_enabled(d["Id"], False)
            except (ClientError, BotoCoreError):
                LOG.exception("could not disable a distribution")
                failures += 1
        try:
            apis = self.apis()
        except (ClientError, BotoCoreError):
            LOG.exception("could not list APIs")
            failures += 1
            apis = []
        for a in apis:
            if halt():
                break
            if a["DisableExecuteApiEndpoint"]:
                continue
            if a["ApiId"] not in s["disabled_apis"] and not record(s["disabled_apis"], a["ApiId"]):
                continue
            try:
                self.set_api_endpoint_disabled(a["ApiId"], True)
            except (ClientError, BotoCoreError):
                LOG.exception("could not disable an API endpoint")
                failures += 1
        try:
            funcs = self.functions()
        except (ClientError, BotoCoreError):
            LOG.exception("could not list functions")
            failures += 1
            funcs = []
        for f in funcs:
            if halt():
                break
            name = f["FunctionName"]
            try:
                current = self.reserved_concurrency(name)
                if current == 0:
                    continue
            except (ClientError, BotoCoreError):
                LOG.exception("could not read a function's concurrency")
                failures += 1
                continue
            if name not in s["concurrency"] and not record(s["concurrency"], name, current):
                continue
            try:
                self.set_reserved_concurrency(name, 0)
            except (ClientError, BotoCoreError):
                LOG.exception("could not zero a function's concurrency")
                failures += 1
        if self.unrecorded:
            LOG.warning("%d resource(s) were stopped without a record: the state is full", self.unrecorded)
        if failures:
            suffix = " (out of time; the next run continues)" if out_of_time else ""
            raise RuntimeError(f"{failures} enforcement action(s) failed{suffix}; the next run retries")
        return s

    def rearm(self, s: dict, estimate: float, reason: str, now: datetime) -> dict:
        # Backend first, the public entry point last: the site never comes back with a stopped backend.
        for api_id in s["disabled_apis"]:
            try:
                self.set_api_endpoint_disabled(api_id, False)
            except ClientError as e:
                if _code(e) != "NotFoundException":
                    raise
                LOG.warning("a recorded API no longer exists")
        for name, previous in s["concurrency"].items():
            try:
                self.set_reserved_concurrency(name, previous)
            except ClientError as e:
                if _code(e) != "ResourceNotFoundException":
                    raise
                LOG.warning("a recorded function no longer exists")
        for dist_id in s["disabled_distributions"]:
            try:
                self.set_distribution_enabled(dist_id, True)
            except ClientError as e:
                if _code(e) != "NoSuchDistribution":
                    raise
                LOG.warning("a recorded distribution no longer exists")
        new = st.armed(st.month_of(now), acknowledged=estimate)
        self.save_state(new)
        self.alert(
            "Cost kill switch rearmed",
            f"Reason: {reason}\nRestored {len(s['disabled_distributions'])} distribution(s), "
            f"{len(s['disabled_apis'])} HTTP API(s) and {len(s['concurrency'])} function(s).\nSpend so far this month ({_usd(estimate)}) is acknowledged; "
            f"the switch trips again after another USD {self.threshold_usd:g}.",
        )
        return new

    # --- flow

    def _unrecorded_note(self) -> str:
        if not self.unrecorded:
            return ""
        return (
            f"{self.unrecorded} resource(s) were stopped without a record because the state is full; "
            "a rearm will not restore them.\n"
        )

    def _estimate_or_none(self, now: datetime) -> float | None:
        """Best effort, after enforcement, for the email and summary only. Nothing slow before the alert:
        no read when time is low or when the inventory is over a limit (too many resources to read)."""
        if self._time_is_low():
            return None
        try:
            inv = self.inventory()
            breach = self.inventory_breach(inv)
            if breach is not None:
                LOG.warning("%s: not reading metrics for the estimate", breach)
                return None
            return self.estimate(self.usage(now, inv))
        except (ClientError, BotoCoreError):
            LOG.exception("could not read metrics; tripping without an estimate")
            return None

    def run(self, event, now: datetime, remaining_ms=None) -> dict:
        """remaining_ms: a callable returning the milliseconds left (Lambda context), or None."""
        self._remaining_ms = remaining_ms
        action, reason = parse_event(event, self.trigger_topic_arn)
        if action == "ignore":
            LOG.info(json.dumps({"action": "ignore"}))
            return {"status": "ignored"}
        enforced = False
        self.reads = 0
        loaded = self.load_state()
        s = st.roll_month(loaded, now)
        if s is not loaded:
            self.save_state(s)
        # Enforcement never waits on metric reads: a tripped check reads none, and a trip reads its
        # estimate only after enforcing. Everything else fails open when they can't be read.
        estimate = None
        inv = None
        inventory_trip = False
        if action == "check" and s["status"] == st.ARMED:
            # One listing per kind per run. Over a limit trips like a manual trip: before any metric read.
            inv = self.inventory()
            breach = self.inventory_breach(inv)
            if breach is not None:
                action, reason, inventory_trip = "trip", breach, True
        if action == "check" and s["status"] == st.TRIPPED:
            pass
        elif action != "trip":
            estimate = self.estimate(self.usage(now, inv))
        if action == "check" and s["status"] == st.ARMED and over_threshold(estimate, s["acknowledged_usd"], self.threshold_usd):
            action = "trip"
            reason = (
                f"estimated spend USD {estimate - s['acknowledged_usd']:.2f} this month "
                f"is over the USD {self.threshold_usd:g} threshold"
            )
        if action == "rearm" and s["status"] == st.TRIPPED:
            s = self.rearm(s, estimate, reason, now)
        elif action == "trip" and s["status"] == st.ARMED:
            s = st.tripped(s, reason=reason, now=now, estimate=estimate)
            self.save_state(s)
            # Enforce first (no metric read before it), then the best-effort estimate (email and summary
            # only, never saved), then the alert: nothing that can fail sits between enforcement and
            # the alert, and a failed enforcement can't swallow it; the error is raised afterwards.
            enforce_error = None
            try:
                s = self.enforce(s)
            except Exception as e:  # noqa: BLE001
                LOG.exception("enforcement failed during the trip")
                enforce_error = e
            enforced = True
            # An inventory trip means too many resources: reading their metrics could time the Lambda out
            # before the alert, so it reads none at all.
            if estimate is None and not inventory_trip:
                estimate = self._estimate_or_none(now)  # for the email and the summary only, never saved
            self.alert(
                "Cost kill switch TRIPPED",
                f"Reason: {reason}\nTime: {s['tripped_at']}\nEstimated spend this month: "
                f"{'unknown (not read: inventory trip)' if inventory_trip else _usd(estimate)}\n"
                "The site is going offline: every CloudFront distribution is being disabled, every HTTP API's "
                "default endpoint is being disabled and every other Lambda function's reserved concurrency "
                f"set to 0.\n{self._unrecorded_note()}{REARM_HINT}",
            )
            if enforce_error is not None:
                raise enforce_error
        if s["status"] == st.TRIPPED and action != "status" and not enforced:
            s = self.enforce(s)
        result = summary(s, estimate)
        LOG.info(json.dumps({"action": action, **result, **({"unrecorded": self.unrecorded} if self.unrecorded else {})}))
        if self.reads > READS_WARNING:
            # After everything was decided and saved, so the errors alarm emails without delaying a stop.
            raise RuntimeError(
                f"{self.reads} metric reads in one run: over the free tier at one run a minute; "
                "reduce resources or raise the cap"
            )
        return result


def make_clients() -> dict:
    config = Config(connect_timeout=5, read_timeout=10, retries={"mode": "standard", "max_attempts": 3})
    return {
        "cloudwatch_us_east_1": boto3.client("cloudwatch", region_name="us-east-1", config=config),  # CloudFront metrics
        "cloudwatch": boto3.client("cloudwatch", config=config),
        "cloudfront": boto3.client("cloudfront", config=config),
        "lambda": boto3.client("lambda", config=config),
        "apigatewayv2": boto3.client("apigatewayv2", config=config),
        "ssm": boto3.client("ssm", config=config),
        "sns": boto3.client("sns", config=config),
    }


_SWITCH = None


def lambda_handler(event, context):
    global _SWITCH
    try:
        if _SWITCH is None:
            _SWITCH = KillSwitch(
                make_clients(),
                self_name=os.environ["AWS_LAMBDA_FUNCTION_NAME"],
                state_parameter=os.environ["STATE_PARAMETER"],
                alerts_topic_arn=os.environ["ALERTS_TOPIC_ARN"],
                trigger_topic_arn=os.environ["TRIGGER_TOPIC_ARN"],
                threshold_usd=float(os.environ["THRESHOLD_USD"]),
                max_distributions=int(os.environ["MAX_DISTRIBUTIONS"]),
                max_apis=int(os.environ["MAX_APIS"]),
                max_functions=int(os.environ["MAX_FUNCTIONS"]),
                free_cloudfront_bytes=float(os.environ["FREE_CLOUDFRONT_BYTES"]),
                free_cloudfront_requests=float(os.environ["FREE_CLOUDFRONT_REQUESTS"]),
            )
        remaining = getattr(context, "get_remaining_time_in_millis", None)
        return _SWITCH.run(event, datetime.now(timezone.utc), remaining)
    except Exception as e:
        # Full detail stays in CloudWatch Logs; a synchronous caller only gets a code, never AWS text
        # (which can carry account and resource ARNs).
        LOG.exception("kill switch run failed")
        code = e.response.get("Error", {}).get("Code", "ClientError") if isinstance(e, ClientError) else type(e).__name__
        raise RuntimeError(f"kill switch failed: {code}") from None

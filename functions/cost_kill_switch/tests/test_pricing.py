import pytest

from pricing import Usage, estimate_usd, over_threshold


def test_zero_usage_costs_nothing():
    assert estimate_usd(Usage()) == 0


@pytest.mark.parametrize(
    "usage, expected",
    [
        (Usage(cloudfront_bytes=40e9), 4.8),
        (Usage(cloudfront_requests=2_000_000), 5.0),
        (Usage(api_requests=1_000_000), 1.2),
        (Usage(lambda_invocations=1_000_000), 0.2),
        (Usage(lambda_gb_seconds=100_000), 1.67),
    ],
)
def test_each_component_uses_its_price(usage, expected):
    assert estimate_usd(usage) == pytest.approx(expected)


def test_components_add_up():
    usage = Usage(
        cloudfront_bytes=1e9,
        cloudfront_requests=10_000,
        api_requests=1e6,
        lambda_invocations=1e6,
        lambda_gb_seconds=1e5,
    )
    assert estimate_usd(usage) == pytest.approx(0.12 + 0.025 + 1.2 + 0.2 + 1.67)


@pytest.mark.parametrize(
    "usage, free_bytes, free_requests, expected",
    [
        # bytes: below, exactly at, above the allowance
        (Usage(cloudfront_bytes=0.5e12), 1e12, 0, 0.0),
        (Usage(cloudfront_bytes=1e12), 1e12, 0, 0.0),
        (Usage(cloudfront_bytes=1e12 + 10e9), 1e12, 0, 1.2),
        # requests: below, exactly at, above the allowance
        (Usage(cloudfront_requests=5_000_000), 0, 10_000_000, 0.0),
        (Usage(cloudfront_requests=10_000_000), 0, 10_000_000, 0.0),
        (Usage(cloudfront_requests=12_000_000), 0, 10_000_000, 5.0),
        # both together, each floored on its own
        (Usage(cloudfront_bytes=1e12 + 10e9, cloudfront_requests=12_000_000), 1e12, 10_000_000, 1.2 + 5.0),
        (Usage(cloudfront_bytes=0.5e12, cloudfront_requests=12_000_000), 1e12, 10_000_000, 5.0),
    ],
)
def test_the_cloudfront_free_allowance_is_subtracted_and_floored_at_zero(usage, free_bytes, free_requests, expected):
    got = estimate_usd(usage, free_cloudfront_bytes=free_bytes, free_cloudfront_requests=free_requests)
    assert got == pytest.approx(expected)


def test_the_allowance_does_not_reduce_api_gateway_or_lambda():
    usage = Usage(api_requests=1e6, lambda_invocations=1e6, lambda_gb_seconds=1e5)
    assert estimate_usd(usage, free_cloudfront_bytes=1e12, free_cloudfront_requests=1e7) == pytest.approx(1.2 + 0.2 + 1.67)


def test_the_allowances_default_to_zero():
    usage = Usage(cloudfront_bytes=1e9, cloudfront_requests=10_000)
    assert estimate_usd(usage) == estimate_usd(usage, free_cloudfront_bytes=0.0, free_cloudfront_requests=0.0)
    assert estimate_usd(usage) == pytest.approx(0.145)


def test_a_normal_month_is_far_below_the_threshold():
    # About 2,000 requests and 17 MB a day (November 2026 traffic), over 31 days.
    usage = Usage(cloudfront_bytes=17e6 * 31, cloudfront_requests=2_000 * 31)
    assert estimate_usd(usage) < 0.25


@pytest.mark.parametrize(
    "estimate, acknowledged, expected",
    [(0, 0, False), (4.99, 0, False), (5.0, 0, True), (7.49, 2.5, False), (7.5, 2.5, True)],
)
def test_over_threshold_is_inclusive_and_relative_to_acknowledged(estimate, acknowledged, expected):
    assert over_threshold(estimate, acknowledged, 5.0) is expected

"""Conservative USD prices for the spend estimate (checked 2026-11-09).

The prices are above the real ones on purpose (the top of the common CloudFront edge regions),
and free tiers are ignored, so the estimate overstates spend.
"""

from dataclasses import dataclass

CLOUDFRONT_PER_GB = 0.12  # data transfer out; 1 GB = 10^9 bytes
CLOUDFRONT_PER_10K_REQUESTS = 0.025
API_GATEWAY_HTTP_PER_MILLION = 1.20
LAMBDA_PER_MILLION_INVOCATIONS = 0.20
LAMBDA_PER_GB_SECOND = 0.0000167


@dataclass(frozen=True)
class Usage:
    cloudfront_bytes: float = 0.0
    cloudfront_requests: float = 0.0
    api_requests: float = 0.0
    lambda_invocations: float = 0.0
    lambda_gb_seconds: float = 0.0


def estimate_usd(usage: Usage) -> float:
    return (
        usage.cloudfront_bytes / 1e9 * CLOUDFRONT_PER_GB
        + usage.cloudfront_requests / 10_000 * CLOUDFRONT_PER_10K_REQUESTS
        + usage.api_requests / 1e6 * API_GATEWAY_HTTP_PER_MILLION
        + usage.lambda_invocations / 1e6 * LAMBDA_PER_MILLION_INVOCATIONS
        + usage.lambda_gb_seconds * LAMBDA_PER_GB_SECOND
    )


def over_threshold(estimate: float, acknowledged: float, threshold: float) -> bool:
    """Trip when the spend since the last rearm (or since the month began) reaches the threshold."""
    return estimate - acknowledged >= threshold

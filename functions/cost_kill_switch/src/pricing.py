"""Conservative USD prices for the spend estimate (checked 2026-11-09).

The prices are above the real ones on purpose (the top of the common CloudFront edge regions),
and free tiers are ignored (except the CloudFront allowance passed to estimate_usd), so the estimate
overstates spend.
"""

from dataclasses import dataclass

CLOUDFRONT_PER_GB = 0.12  # data transfer out; 1 GB = 10^9 bytes
CLOUDFRONT_PER_10K_REQUESTS = 0.025
API_GATEWAY_HTTP_PER_MILLION = 1.20
LAMBDA_PER_MILLION_INVOCATIONS = 0.20
LAMBDA_PER_GB_SECOND = 0.0000167


@dataclass(frozen=True)
class Usage:
    cloudfront_bytes_down: float = 0.0  # BytesDownloaded: the only bytes the free allowance covers
    cloudfront_bytes_up: float = 0.0  # BytesUploaded: priced in full
    cloudfront_requests: float = 0.0
    api_requests: float = 0.0
    lambda_invocations: float = 0.0
    lambda_gb_seconds: float = 0.0


def estimate_usd(usage: Usage, *, free_cloudfront_bytes: float = 0.0, free_cloudfront_requests: float = 0.0) -> float:
    """The CloudFront free allowance (a monthly tier) comes off downloaded bytes and requests only, floored
    at zero. Uploaded bytes are priced in full, at the same per-GB price."""
    billable_bytes = max(0.0, usage.cloudfront_bytes_down - free_cloudfront_bytes) + usage.cloudfront_bytes_up
    billable_requests = max(0.0, usage.cloudfront_requests - free_cloudfront_requests)
    return (
        billable_bytes / 1e9 * CLOUDFRONT_PER_GB
        + billable_requests / 10_000 * CLOUDFRONT_PER_10K_REQUESTS
        + usage.api_requests / 1e6 * API_GATEWAY_HTTP_PER_MILLION
        + usage.lambda_invocations / 1e6 * LAMBDA_PER_MILLION_INVOCATIONS
        + usage.lambda_gb_seconds * LAMBDA_PER_GB_SECOND
    )


def over_threshold(estimate: float, acknowledged: float, threshold: float) -> bool:
    """Trip when the spend since the last rearm (or since the month began) reaches the threshold."""
    return estimate - acknowledged >= threshold

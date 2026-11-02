"""Connectivity probes — so the panel can tell the user why nothing is
answering (proxy down) instead of failing on the first request."""

from __future__ import annotations


def probe_http_endpoint(url: str, timeout_seconds: float = 2.0) -> bool:
    """True when `url` answers quickly with any HTTP response — including
    404/405/401 from the Worker (any HTTP response proves the process is up).

    Notes:
    - `trust_env=False` is required: otherwise a system-wide HTTP proxy env
      var routes localhost requests through the proxy and any proxy answer
      counts as "reachable", even for closed ports.
    - A timeout counts as unreachable: for a local wrangler dev instance a
      2-second silence means the service is down or blocked for the app.
    """
    import httpx  # lazily so pure-Python tests skip the dependency

    try:
        httpx.get(url, timeout=timeout_seconds, trust_env=False)
        return True
    except Exception:
        return False

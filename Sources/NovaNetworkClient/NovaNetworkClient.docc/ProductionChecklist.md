# Production Checklist

Review identity, resilience, security, observability, and lifecycle choices before shipping.

## Overview

### Client lifetime and configuration

- Keep a client alive for the scope in which requests should share work and cache state.
- Prefer ``NetworkClientConfiguration`` when many settings vary by environment.
- Validate a composed ``NetworkClientPreset`` if you use production profile generation.

### Request identity and authentication

- Use stable, non-secret `authScope` values that separate users and tenants.
- Include every response-varying header in ``FingerprintPolicy``.
- Keep tokens in middleware or authentication-refresh code, not in scope labels, logs, or metrics.
- Configure single-flight authentication refresh when access tokens can expire.

### Retries and writes

- Bound attempts, delay, jitter, and any global retry budget.
- Respect `Retry-After` unless your service contract requires otherwise.
- Retry writes only with a server-supported idempotency key or equivalent guarantee.
- Set a deadline budget when the full operation must complete within a known time.

### Cache behavior

- Choose freshness and stale windows from product requirements, not arbitrary constants.
- Verify user-specific responses cannot cross authentication scopes.
- Test invalidation after writes and memory-pressure handling where applicable.
- Use disk caching only after defining storage capacity and data-sensitivity requirements.

### Security

- Use HTTPS and platform trust by default.
- Adopt certificate pinning only with backup pins and a rotation/runbook plan.
- Never persist credentials in transfer journals or offline write stores.
- Treat mutual TLS identities and offline-store encryption keys as application-owned secrets.

### Observability

- Observe retries, exhausted retries, cache results, circuit-breaker transitions, and failures.
- Use stable identifiers and sanitized reasons; don't record URLs or headers containing secrets.
- Verify failure and cancellation paths never emit success telemetry.

### Testing and rollout

- Cover the happy path, HTTP failures, transport failures, decoding, cancellation, and concurrency.
- Use `NovaNetworkClientTestSupport` for deterministic unit tests.
- Keep E2E tests limited to real public APIs, as required by the package test policy.
- Define rollback triggers for cache corruption, duplicate writes, auth leakage, and retry storms.

## See Also

- <doc:AddResilience>
- ``NetworkClientProductionProfileGenerator``
- ``NetworkClientPresetValidator``
- ``NetworkTelemetryHooks``

# Test Matrix Example

Use this as a reference for mapping DFR requirements to tests.

## Feature
- Name: Request Retry Improvements
- DFR: `docs/dfr/REQUEST_RETRY_IMPROVEMENTS.md`

## Requirement-to-Test Mapping
| Requirement ID | Requirement summary | Test ID | Test type (`unit/integration/ui`) | Owner | Status |
|---|---|---|---|---|---|
| FR-1 | Retry failed request up to 3 times | T-1.1 | unit | iOS | passing |
| FR-1 | Retry failed request up to 3 times | T-1.2 | integration | iOS | passing |
| FR-2 | Stop retry after success | T-2.1 | unit | iOS | passing |
| UR-1 | Show loading while retry in progress | T-3.1 | ui | iOS | passing |
| UR-2 | Show final error state after last failed attempt | T-3.2 | ui | iOS | passing |
| AR-1 | Emit `retry_started` event once per retry cycle | T-4.1 | integration | iOS | passing |
| AR-2 | Emit `retry_succeeded` only on success | T-4.2 | integration | iOS | passing |
| AR-3 | Never emit `retry_succeeded` on terminal failure | T-4.3 | integration | iOS | passing |
| NFR-1 | Retry logic overhead under threshold | T-5.1 | unit | iOS | passing |
| EC-1 | Network unavailable from first attempt | T-6.1 | integration | iOS | passing |
| EC-2 | Server returns malformed payload on second retry | T-6.2 | integration | iOS | passing |

## Negative Tests
- T-6.1: When network is offline, verify retries stop at policy limit and error state is shown.
- T-6.2: When payload decoding fails, verify no success state or success analytics are emitted.
- T-4.3: Verify `retry_succeeded` event is not sent on all-failure path.

## Regression Risks and Coverage Strategy
| Risk | Impact | Mitigation tests |
|---|---|---|
| Duplicate request execution under race | High | T-1.2, T-2.1 |
| Incorrect UI state transition after retry | Medium | T-3.1, T-3.2 |
| Analytics inflation from duplicate events | High | T-4.1, T-4.2, T-4.3 |

## Coverage Gate
- Unit coverage target: `> 90%`
- E2E coverage target (`RUN_E2E_TESTS=1`, `E2ECoverageTests`): `>= 50%`
- Current unit coverage: `<fill from CI/local report>`
- Current E2E coverage: `<fill from CI/local report>`
- Action if below threshold: add targeted unit tests before merge.

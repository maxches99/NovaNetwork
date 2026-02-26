# Unit Test Policy

This policy defines how unit tests are created and maintained in `NovaNetworkClient`.

## Goals

- Protect public behavior from regressions.
- Keep tests deterministic, fast, and readable.
- Maintain high practical coverage without writing fragile tests.

## Scope

- Applies to all source files in `Sources/NovaNetworkClient/`.
- Applies to all tests in `Tests/NovaNetworkClientTests/`.

## Coverage Targets

- Minimum CI gate: `>= 80%` line coverage.
- Team target: `>= 90%` line coverage.
- Practical stretch target: as close to 100% as possible for business logic.
- Do not force unrealistic tests for platform-only or non-deterministic branches; document those gaps.

## Test Design Rules

- Prefer behavior-driven tests over implementation-coupled tests.
- Each test should verify one behavior (single clear assertion theme).
- Test names must describe expected behavior (`given_when_then` style is recommended).
- Use deterministic clocks/random generators for retry/time-dependent logic.
- Avoid sleeps unless unavoidable; use short bounded waits and explicit deadlines.
- Never depend on external network/services in unit tests.

## What Must Be Tested

- Public API behavior and error mapping.
- Concurrency behavior: coalescing, cancellation, retry paths.
- Cache behavior: hit/miss, invalidation, stale/revalidation branches.
- Fingerprint stability and canonicalization.
- Critical edge cases and previously reported bugs.

## Test Organization

- Group tests by module/behavior area, not by “miscellaneous” buckets.
- Keep helper fakes/stubs local to the relevant test file unless reused widely.
- Use separate files for large domains:
  - `APIRequest...Tests`
  - `Fingerprint...Tests`
  - `Cache...Tests`
  - `Networking...Tests`

## Stability and Performance

- Unit tests should be fast; avoid long delays and large fixtures.
- Tests must be deterministic on repeated local and CI runs.
- Flaky tests must be fixed or quarantined immediately; do not ignore flakiness.

## Change Policy

- Any behavior change in production code requires corresponding test updates.
- Any bug fix requires:
  - a regression test that fails before the fix,
  - and passes after the fix.
- If public behavior changes, update docs (`README.md` and/or `docs/`).

## Review Checklist for PRs

- New/changed behavior has tests.
- No new flaky/time-race assumptions.
- Coverage does not regress without explanation.
- Test naming and structure remain clear and consistent.

## Local Validation Commands

```bash
swift build
swift test --enable-code-coverage
```

Optional coverage report:

```bash
xcrun llvm-cov report \
  .build/arm64-apple-macosx/debug/NovaNetworkClientPackageTests.xctest/Contents/MacOS/NovaNetworkClientPackageTests \
  -instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata \
  Sources/NovaNetworkClient/**/*.swift
```

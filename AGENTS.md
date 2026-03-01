# AGENTS.md

## Purpose
This repository contains a Swift Package (`NovaNetworkClient`).
Use this file as the default operating guide for coding agents.

## Project Layout
- `Sources/` - library source code
- `Tests/` - unit tests
- `Package.swift` - SwiftPM manifest
- `README.md` - usage and examples
- `docs/` - additional documentation

## Environment
- Platform: macOS
- Language: Swift
- Build tool: Swift Package Manager

## Commands
- Build: `swift build`
- Test: `swift test`
- Run a specific test: `swift test --filter <TestName>`

## Working Rules
- Keep changes minimal and focused on the requested task.
- Prefer fixing root causes over adding workarounds.
- Do not break public API without updating tests and docs.
- Add or update tests for behavior changes.
- Follow `docs/UNIT_TEST_POLICY.md` when creating and maintaining tests.
- Keep code style consistent with surrounding files.
- Avoid adding dependencies unless explicitly requested.

## Product-Driven Delivery (DFR-First)
Treat DFR (Design/Functional Requirements) as the source of truth and contract across Product, Design, Engineering, and QA.

### Required DFR Structure
- Metadata: feature name, owner, stakeholders, goal/non-goals, Definition of Done, rollout plan, dependencies, risks.
- User value: problem statement, success metrics, scope split (MVP/V1/nice-to-have).
- Requirements with IDs and acceptance criteria:
  - Functional (FR-*), UX (UR-*), Data (DR-*), Analytics (AR-*), Non-functional (NFR-*), Edge cases (EC-*).
- State/flow definition: states, transitions, and `state -> UI -> actions -> analytics` mapping.
- Test matrix: `Requirement ID -> Test IDs -> Owner`, including negative tests and regression risks.

### Mandatory Process Rules
- No spec, no dev: do not start implementation without DFR requirements, acceptance criteria, state flow, risk section, and analytics section when applicable.
- Change control: behavior changes must be updated in DFR first, then in code/tests/release notes.
- Traceability: every implementation and test task must reference Requirement IDs.
- DoD completeness: done means DFR + code + tests + telemetry + release notes + rollout plan.

### Task Decomposition
- Derive implementation tasks from DFR by layer (UI/Domain/Data) and by flow (happy path/edge cases).
- Derive test tasks for unit/integration/UI and analytics validation.
- Derive release tasks for feature flags, docs, monitoring, and "What's New".

### Spec-First Implementation Pattern
- Define interfaces/use cases from required scenarios.
- Define state model directly from DFR state machine.
- Implement happy path first, then edge cases by DFR priority.
- Document uncovered engineering decisions in DFR engineering notes (no hidden rules).

### DFR-Driven Testing
- Every testable FR/UR/AR/NFR requires at least one test.
- Edge cases should be covered by explicit tests.
- Validate analytics as contract:
  - correct trigger timing,
  - correct payload schema/properties,
  - no false "success" events on failures.

### PR and Review Compliance
- PRs must include:
  - DFR link,
  - list of implemented Requirement IDs,
  - mapping to test IDs,
  - analytics verification,
  - "What's New" update,
  - rollout/feature-flag notes.
- Code review is split into:
  - product compliance against DFR,
  - engineering quality (architecture, readability, testability, performance).

### Release and Learn
- After release, monitor success metrics defined in DFR.
- Track dashboard/alerts for key events.
- Bug fixes that change behavior must update DFR and tests.

### Templates to Keep in Repo/Workspace
- DFR template.
- PR template with mandatory DFR and traceability fields.
- Test matrix section in DFR.
- "What's New" markdown template.

## Test Coverage Policy
- Unit test coverage must stay above 90%.
- E2E tests (`RUN_E2E_TESTS=1`) must run only against real public APIs.
- Mocks/stubs/custom fake transports are not allowed in E2E tests.
- Any change that drops coverage below 90% is blocked until coverage is restored.

## Validation Checklist
Before finishing:
1. Build succeeds (`swift build`).
2. Tests pass (`swift test`).
3. Unit test coverage is above 90%.
4. E2E suite is green against real public APIs (`RUN_E2E_TESTS=1 swift test --filter E2ECoverageTests`), with no mocks/stubs.
5. `README.md` is updated if user-facing behavior changed.

## Git Hygiene
- Do not revert unrelated local changes.
- Do not use destructive git commands unless explicitly requested.
- Keep commits small and task-focused.

## What's New Policy
- For user-facing changes and releases, always update or create a versioned "What's New" file in `docs/` using the existing naming format: `WHATS_NEW_v<major>.<minor>.md` (for example, `docs/WHATS_NEW_v1.3.md`).
- Keep "What's New" aligned with implemented behavior, DFR scope, and release notes in PR metadata.

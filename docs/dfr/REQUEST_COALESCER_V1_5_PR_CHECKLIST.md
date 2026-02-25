# RequestCoalescer v1.5 PR Checklist

Use this checklist in every PR that implements any part of v1.5.

## PR Metadata
- [ ] PR title includes scope marker (example: `[v1.5][FR-1][FR-2] Deadline budget in retry flow`).
- [ ] DFR link included: `docs/dfr/REQUEST_COALESCER_V1_5_DFR.md`
- [ ] Task decomposition link included: `docs/dfr/REQUEST_COALESCER_V1_5_IMPLEMENTATION_TASKS.md`
- [ ] Rollout flag referenced: `requestCoalescer.v1_5`

## Requirement Traceability
- [ ] Implemented Requirement IDs are listed (`FR-*`, `UR-*`, `DR-*`, `AR-*`, `NFR-*`, `EC-*`).
- [ ] For each Requirement ID, matching Test IDs are listed.
- [ ] Out-of-scope Requirement IDs are explicitly marked as deferred.

## Engineering Quality
- [ ] Public API changes reviewed for source compatibility (`UR-1`) or migration notes included.
- [ ] Edge-case behavior is explicitly tested for touched flows.
- [ ] No hidden behavior changes outside DFR scope.
- [ ] No new dependency added unless explicitly approved.

## Analytics Verification
- [ ] Event names verified for touched flows (`request_failed`, `request_retry_exhausted`, breaker events, etc.).
- [ ] Payload schema verified (`failure_reason`, `attempt_count`, `remaining_budget_ms`, `coalescing_mode`, breaker fields).
- [ ] Verified that no false `request_succeeded` is emitted on non-success terminal paths (`AR-3`).
- [ ] Telemetry failure isolation validated where relevant (`EC-5`).

## Tests and Validation
- [ ] `swift build` passes.
- [ ] `swift test` passes.
- [ ] Coverage remains above 90% (`NFR-1`).
- [ ] Added/updated tests align with DFR test matrix entries.

## Docs and Release
- [ ] `docs/WHATS_NEW_v1.5.md` updated for user-facing changes in this PR.
- [ ] README/docs updated for any new public controls or behavior (`UR-2`).
- [ ] Release/rollout notes included (flag behavior, canary plan, rollback trigger).

## Risk and Rollback
- [ ] Main risks for touched scope documented in PR body.
- [ ] Rollback condition and rollback path documented.

---

## PR Description Template (Copy/Paste)

```md
## Summary
- 

## DFR
- `docs/dfr/REQUEST_COALESCER_V1_5_DFR.md`

## Implemented Requirement IDs
- 

## Requirement -> Tests Mapping
| Requirement ID | Test IDs |
|---|---|
|  |  |

## Analytics Verification
- Events verified:
- Payload fields verified:
- Negative verification (`AR-3` no false success):

## Rollout Notes
- Feature flag: `requestCoalescer.v1_5`
- Segment:
- Ramp step:
- Rollback trigger:

## What's New
- Updated: `docs/WHATS_NEW_v1.5.md` (yes/no; details)
```

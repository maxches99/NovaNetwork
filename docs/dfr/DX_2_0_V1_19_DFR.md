# DFR: DX 2.0 (v1.19)

## 1. Metadata
- Feature name: DX 2.0 Production Setup Acceleration
- Owner: Networking Platform
- Stakeholders: iOS Platform, QA, Developer Experience
- Status: `In Development`
- Target version/build: `v1.19`
- Related links:
  - Design: `N/A (repo-driven)`
  - API contract: `Sources/NovaNetworkClient/Networking/Client/NetworkClientPresetDX.swift`
  - Experiment: `N/A`
  - Legal/compliance: `N/A`

## 2. Goal and Scope
### Goal
Reduce time-to-first-production-setup by introducing composable presets, explicit production validation, and cookbook-style runnable references.

### Non-goals
- No runtime auto-migration of existing app configs.
- No behavioral changes in existing v1 preset defaults unless overlays are explicitly used.

### Definition of Done
- [x] DFR updated and approved
- [x] Code implemented
- [x] Tests added/updated per matrix
- [x] Telemetry implemented and verified
- [x] "What's New" added/updated
- [x] Rollout plan documented

### MVP / V1 / Nice-to-have
- MVP: Preset v2 composition model (`base + overlays`) and validator.
- V1: Production profile generator and onboarding snippets.
- Nice-to-have: Additional opinionated overlays for vertical-specific traffic patterns.

## 3. User Value
### User problem
Teams spend significant setup time selecting resilient defaults and validating production readiness. Misconfiguration risks include missing offline store for queued writes, no retry/rate controls, and ad-hoc copy-paste onboarding.

DX 2.0 provides a guided path: generate profile -> validate anti-patterns -> bootstrap from snippet -> verify via cookbook tests.

### Success metrics
| Metric | Baseline | Target | Measurement method |
|---|---:|---:|---|
| Time to first production-ready preset setup | Manual setup flow | -35% | Internal onboarding sessions / setup checklist timing |
| Blocking config errors caught before rollout | Low | +80% detection | Validator reports in CI/onboarding |
| Cookbook scenario verification coverage | Partial | 100% DX scenarios mapped | Requirement-to-test matrix |

## 4. Rollout, Dependencies, Risks
### Rollout plan
- Feature flag: Not required (library API additive)
- Initial rollout percentage: 100% for package consumers
- Segments: All integrators on v1.19+
- Ramp plan: Release with docs + examples + test coverage
- Rollback trigger: Revert v1.19 DX APIs if blocking regressions are found

### Dependencies
- Internal: Existing `NetworkClientPreset`, `RequestExecutionOptions`, `RuntimePolicy`
- External: None

### Risks and mitigations
| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Overlay semantics misunderstood | Medium | Medium | Explicit docs + generator snippets + validator output |
| False confidence from partial validation | High | Low | Blocking/error severity for unsafe offline queue setup |
| Regression in preset behavior | High | Low | Contract tests for existing v1 presets and new v2 composition |

## 5. Requirements

### Functional requirements (FR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| FR-1 | Provide preset v2 composition model (`base + overlays`) | API composes a base preset with ordered overlays and returns final `NetworkClientPreset` | `NetworkClientPresetComposer`, `NetworkClientPreset.compose` |
| FR-2 | Provide production validator | Validator outputs issues with severity and blocking status for anti-patterns | `NetworkClientPresetValidator` |
| FR-3 | Provide onboarding production profile generator | Generator outputs base preset, overlays, composed preset, validation, bootstrap snippet | `NetworkClientProductionProfileGenerator` |
| FR-4 | Provide cookbook reference examples | `Examples/README.md` maps runnable scenarios to test contracts | `Examples/README.md`, new example target |

### UX requirements (UR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| UR-1 | Onboarding must be actionable | Generated profile includes copy-paste setup snippet | `NetworkClientProductionProfile.bootstrapSnippet` |
| UR-2 | Findings must be understandable | Validation issue includes stable code + message + recommendation | `NetworkClientPresetValidationIssue` |

### Data requirements (DR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| DR-1 | Validation output is machine-readable | `NetworkClientPresetValidationReport` exposes issues and blocking subset | `NetworkClientPresetValidationReport` |

### Analytics requirements (AR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| AR-1 | No false production-ready signal for unsafe offline setup | Missing store with enabled offline queue returns blocking issue | `AP-OFFLINE-001`, tests |

### Non-functional requirements (NFR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| NFR-1 | Backward compatibility | Existing v1 presets and APIs continue to behave unchanged without overlays | Preset contract tests |
| NFR-2 | Testability | DX scenarios are covered by deterministic unit tests | `NetworkingCoverageTests+Presets.swift`, `+ReferenceCookbook.swift` |

### Edge cases (EC)
| ID | Scenario | Expected behavior | Trace links |
|---|---|---|---|
| EC-1 | Offline-first selected but offline queue disabled | Validator returns blocking error | `AP-OFFLINE-002` |
| EC-2 | Low-latency and offline-durability overlays combined | Validator returns warning about mixed priorities | `AP-OVERLAY-001` |

## 6. State Machine and Flows
### States
- `draft_profile`
- `generated_profile`
- `validated_ready`
- `validated_blocked`

### Transitions
| From | Trigger | To | Notes |
|---|---|---|---|
| `draft_profile` | Generate profile | `generated_profile` | Base + overlays composed |
| `generated_profile` | Validate (no blocking issues) | `validated_ready` | Ready for production setup |
| `generated_profile` | Validate (blocking issues) | `validated_blocked` | Requires remediation |

### State to UI/Actions/Analytics mapping
| State | UI | Allowed actions | Analytics |
|---|---|---|---|
| `generated_profile` | Show composed config summary | Apply overlays, run validator | None |
| `validated_ready` | Show green-ready status | Bootstrap setup | None |
| `validated_blocked` | Show blocking findings | Fix config and re-validate | None |

## 7. Engineering Notes
- Overlay order is deterministic and applied sequentially.
- Runtime policy merge follows existing runtime store semantics (override non-nil fields).
- Validator intentionally starts with pragmatic anti-pattern coverage and stable issue codes.

## 8. Test Matrix
| Requirement ID | Test ID | Test type (`unit/integration/ui`) | Owner | Status |
|---|---|---|---|---|
| FR-1 | T-19.1 `presetV2CompositionAppliesOverlayOrder` | unit | Platform | passing |
| FR-2 | T-19.2 `presetV2ValidatorFlagsOfflineQueueWithoutStoreAsBlocking` | unit | Platform | passing |
| FR-3 | T-19.3 `productionProfileGeneratorBuildsValidatedRealtimeProfile` | unit | Platform | passing |
| FR-4 | T-19.4 `cookbookScenarioCoalescedRequestUsesSingleTransportCall` | unit | Platform | passing |
| AR-1 | T-19.5 `cookbookScenarioProductionProfileForOfflineFirstRequiresStore` | unit | Platform | passing |

### Negative tests
- T-19.2 validates blocking error when offline queue is enabled without durable store.
- T-19.5 validates offline-first generator output fails readiness without store.

### Regression risks
- Existing v1 preset contracts remain covered by `presetsExposeSafeDefaultsAndTradeoffs`.
- Runtime policy application telemetry remains covered by `applyRuntimePolicyFromPresetEmitsPolicyUpdateTelemetry`.

## 9. Release Notes Input ("What's New")
### Customer impact
- Faster production onboarding with fewer unsafe setup mistakes.

### User-facing changes
- New preset v2 composition APIs, validator, and production profile generator.
- New cookbook example for production profile generation.

### Behavior changes / migration notes
- Existing APIs unchanged. New features are additive and opt-in.

### Known limitations
- Validator rules are opinionated and focused on common anti-patterns; teams may add extra internal checks.

# Traceability Pack v3.7

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V3_7_DFR.md`
- Scope: eight independent, opt-in features; one section per feature below, in DFR order.

## A. Hedged requests

### Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-HEDGE-1 | `Sources/NovaNetworkClient/Networking/Client/NetworkClientConfiguration.swift` (`hedging`), `NetworkClient.swift` (`init(configuration:)`) |
| FR-HEDGE-2, FR-HEDGE-6, FR-HEDGE-7, EC-HEDGE-4 | `Sources/NovaNetworkClient/Networking/Policies/HedgingPolicy.swift` (`HedgingPolicy`, `HedgingDelay`, `HedgingState`) |
| FR-HEDGE-3…5, EC-HEDGE-1…3 | `Sources/NovaNetworkClient/Networking/Core/HedgingTransport.swift` |
| AR-HEDGE-1…3 | `Sources/NovaNetworkClient/Networking/Core/TelemetryHooks.swift` (`TelemetryHedgeContext`, `onRequestHedged`) |

### Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-18.1 | FR-HEDGE-3, FR-HEDGE-4, AR-HEDGE-1, AR-HEDGE-2 | unit | `HedgingRaceTests.aSlowRequestIsSentAgainAndTheFasterAnswerWins` |
| T-18.2 | FR-HEDGE-4, AR-HEDGE-2 | unit | `HedgingRaceTests.whenThePrimaryAnswersFirstTheHedgeIsCancelledAndDoesNotCountAsAWin` |
| T-18.3 | FR-HEDGE-5, AR-HEDGE-2 | unit | `HedgingRaceTests.aFailureWaitsForTheOtherRequestAndTwoFailuresReturnThePrimarysError` |
| T-18.4 | EC-HEDGE-1 | unit | `HedgingRaceTests.aRequestThatFailsBeforeTheDelayIsNotHedged` |
| T-18.5 | FR-HEDGE-2, EC-HEDGE-2 | unit | `HedgingEligibilityTests.onlyRequestsThatAreSafeToRepeatAreHedged` |
| T-18.6 | FR-HEDGE-7, AR-HEDGE-3 | unit | `HedgingRaceTests.aSpentBudgetSendsNothingAndSaysSo`, `HedgingStateTests.theBudgetEarnsAShareOfAHedgePerRequestAndSavesUpToTheBurst` |
| T-18.7 | FR-HEDGE-6 | unit | `HedgingStateTests.theDelayIsAPercentileOfRecentLatenciesToTheSameHost` |
| T-18.8 | EC-HEDGE-3 | unit | `HedgingRaceTests.cancellingTheCallerCancelsBothRequests` |
| T-18.9 | EC-HEDGE-4 | unit | `HedgingStateTests.nonsensicalValuesAreClamped` |
| T-18.10 | FR-HEDGE-1 (regression) | unit | `HedgingEligibilityTests.withoutAPolicyEveryRequestIsSentOnce` |

### Analytics verification

- Trigger timing: `fired` is emitted when the delay elapses and before the second request starts;
  `won` only when the second request's response is returned (T-18.1, T-18.2).
- Payload: every event carries the prepared request and the delay waited (T-18.1).
- No false success: a hedge that fails, or loses, emits no `won` (T-18.2, T-18.3); a refused budget
  emits `budget_exhausted` and sends nothing (T-18.6).

### E2E

Not applicable (DFR §A.9). The existing E2E suite is unaffected.

## B. Persisting the query cache across launches

### Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-QPERSIST-1…6, FR-QPERSIST-8, EC-QPERSIST-1…3, AR-QPERSIST-1…3 | `Sources/NovaNetworkQuery/QueryClient.swift` (`init(configuration:persistence:now:)`, `persistedValue`, `flushPersistence`, `restore`, `persist`, `enqueueWrite`) |
| FR-QPERSIST-7, EC-QPERSIST-4, AR-QPERSIST-2 | `Sources/NovaNetworkQuery/QueryPersistence.swift` |

### Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-19.1 | FR-QPERSIST-2, FR-QPERSIST-3, AR-QPERSIST-1 | unit | `QueryPersistenceRestoreTests.aValueFetchedInOneLaunchIsOnScreenAtTheStartOfTheNext` |
| T-19.2 | FR-QPERSIST-3 | unit | `QueryPersistenceRestoreTests.aStaleRestoredValueIsReturnedAtOnceAndRefreshedBehindIt` |
| T-19.3 | FR-QPERSIST-4, AR-QPERSIST-2 | unit | `QueryPersistenceRestoreTests.aRecordThatCannotBeTrustedIsDiscardedAndRemoved` |
| T-19.4 | FR-QPERSIST-5 | unit | `QueryPersistenceWriteTests.setValuesAreKeptButOptimisticGuessesAreNot` |
| T-19.5 | FR-QPERSIST-6 | unit | `QueryPersistenceWriteTests.removingAKeyOrEverythingRemovesItFromTheStore` |
| T-19.6 | FR-QPERSIST-7, EC-QPERSIST-4 | unit | `FileQueryPersistenceStoreTests.recordsRoundTripThroughFilesAndACollidingFileIsTreatedAsAbsent`, `aQueryClientRestoresFromFilesAcrossInstances` |
| T-19.7 | FR-QPERSIST-8 | unit | `QueryPersistenceWriteTests.writesReachTheStoreInTheOrderTheyWereMade` |
| T-19.8 | EC-QPERSIST-3, AR-QPERSIST-3 | unit | `QueryPersistenceWriteTests.aStoreThatRefusesWritesDoesNotBreakTheQuery` |
| T-19.9 | EC-QPERSIST-1, EC-QPERSIST-2 | unit | `QueryPersistenceBoundaryTests.nothingStoredMeansAnOrdinaryFetchAndMemoryAlwaysWinsOverDisk` |
| T-19.10 | FR-QPERSIST-1 (regression) | unit | `QueryPersistenceBoundaryTests.withoutPersistenceNothingIsReadOrWritten` |

### Analytics verification

- Trigger timing: `restored` is emitted once, when the record is put in memory (T-19.1).
- Payload: `restored` carries the record's age; `discarded` carries one of four reasons (T-19.1, T-19.3).
- No false success: a discarded record emits no `restored` (T-19.3); a refused write emits
  `writeFailed` and the query still succeeds (T-19.8).

### E2E

Not applicable (DFR §B.9).

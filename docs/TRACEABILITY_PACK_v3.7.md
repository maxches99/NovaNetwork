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

## C. Checking responses against an OpenAPI contract

### Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-CONTRACT-1…7, EC-CONTRACT-1…3, EC-CONTRACT-5 | `Sources/NovaNetworkOpenAPI/OpenAPIContract.swift` |
| FR-CONTRACT-8, FR-CONTRACT-9, EC-CONTRACT-4, AR-CONTRACT-1…3 | `Sources/NovaNetworkOpenAPI/OpenAPIContractMiddleware.swift` |

### Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-20.1 | FR-CONTRACT-1, EC-CONTRACT-5 | unit | `OpenAPIContractMatchingTests.aContractIsBuiltFromYAMLOrJSONAndNeedsPaths` |
| T-20.2 | FR-CONTRACT-2, FR-CONTRACT-3, FR-CONTRACT-7 | unit | `OpenAPIContractMatchingTests.theOperationAndResponseAreFoundByMethodPathAndStatus` |
| T-20.3 | FR-CONTRACT-4 | unit | `OpenAPIContractSchemaTests.typesRequiredNullAndEnumsAreChecked` |
| T-20.4 | FR-CONTRACT-5, EC-CONTRACT-3 | unit | `OpenAPIContractSchemaTests.referencesAndCompositionAreFollowedAsDeepAsTheDataGoes` |
| T-20.5 | FR-CONTRACT-6 | unit | `OpenAPIContractSchemaTests.undocumentedFieldsAreDriftUnlessTheSchemaAllowsOrForbidsThem` |
| T-20.6 | FR-CONTRACT-8, AR-CONTRACT-1, AR-CONTRACT-2 | unit | `OpenAPIContractMiddlewareTests.aDifferingResponseIsReportedWithWhereAndWhatAndAConformingOneIsNot` |
| T-20.7 | AR-CONTRACT-3 | unit | `OpenAPIContractMiddlewareTests.eachViolationIsReportedOnceUnlessAskedOtherwise` |
| T-20.8 | FR-CONTRACT-9 | unit | `OpenAPIContractMiddlewareTests.failOnBreakingTurnsABreakingViolationIntoAnError` |
| T-20.9 | EC-CONTRACT-1, EC-CONTRACT-2, EC-CONTRACT-4 | unit | `OpenAPIContractSchemaTests.bodiesThatAreNotJSONOrNotDescribedAreLeftAlone`, `OpenAPIContractMiddlewareTests.theSampleRateIsClampedAndDecidesWhatIsChecked` |
| T-20.10 | regression | unit | `OpenAPIContractMiddlewareTests.conformingPetstoreTrafficProducesNoReports` |

### Analytics verification

- Trigger timing: `onReport` is called once per checked response with something new to report, after
  the response is validated and before it is returned (T-20.6, T-20.7).
- Payload: method, path, matched template, status, and each violation's pointer, kind, and severity
  (T-20.6).
- No false reports: conforming traffic produces none (T-20.6, T-20.10); an unsampled response is not
  checked (T-20.9).

### E2E

Not applicable (DFR §C.9).

## D. Compressing request bodies

### Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-COMPRESS-1…5, EC-COMPRESS-1…4, AR-COMPRESS-1…2 | `Sources/NovaNetworkClient/Networking/Core/RequestCompression.swift` |

### Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-21.1 | FR-COMPRESS-3, FR-COMPRESS-4, AR-COMPRESS-1 | unit | `RequestCompressionTests.aLargeJSONBodyIsSentAsGzipThatDecodesToTheOriginal` |
| T-21.2 | FR-COMPRESS-4 | unit | `RequestCompressionTests.deflateMeansAZlibStreamAndTheChecksumsMatchTheirReferenceValues` |
| T-21.3 | FR-COMPRESS-2, AR-COMPRESS-2, EC-COMPRESS-3 | unit | `RequestCompressionTests.eachRuleThatSaysNoSendsTheBodyUnchangedAndSaysWhy` |
| T-21.4 | EC-COMPRESS-2 | unit | `RequestCompressionTests.dataThatDoesNotCompressIsSentAsItIs` |
| T-21.5 | FR-COMPRESS-5 | unit | `RequestCompressionTests.anEligibilityRuleReplacesTheContentTypeRule` |
| T-21.6 | EC-COMPRESS-1, EC-COMPRESS-4 | unit | `RequestCompressionTests.aRequestWithNoBodyPassesSilentlyAndANegativeMinimumIsZero` |
| T-21.7 | FR-COMPRESS-1 | unit | `RequestCompressionClientTests.aSigningMiddlewareAfterCompressionSignsTheBytesThatAreSent` |

### Analytics verification

- Trigger timing: one event per request with a body, when the middleware decides (T-21.1, T-21.3).
- Payload: `compressed` carries both sizes and the encoding; `skipped` carries the reason (T-21.1, T-21.3).
- No false success: an uncompressible body reports `not_smaller` and no `compressed` (T-21.4); a
  request with no body reports nothing (T-21.6).

### E2E

Not applicable (DFR §D.9).

## E. GraphQL

### Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-GQL-1 | `Sources/NovaNetworkGraphQL/GraphQLOperation.swift` |
| FR-GQL-3, FR-GQL-4, EC-GQL-1, AR-GQL-1…2 | `Sources/NovaNetworkGraphQL/GraphQLResponse.swift` |
| FR-GQL-2, FR-GQL-5…8, EC-GQL-2…4 | `Sources/NovaNetworkGraphQL/GraphQLClient.swift` |

### Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-22.1 | FR-GQL-1, FR-GQL-2, EC-GQL-2 | unit | `GraphQLRequestTests.anOperationIsPostedAsSortedJSONWithItsDocumentNameAndVariables` |
| T-22.2 | FR-GQL-3, FR-GQL-4, EC-GQL-1, AR-GQL-2 | unit | `GraphQLRequestTests.errorsComeBackBesideTheDataAndDataForThrowsThemWithWhatSurvived` |
| T-22.3 | FR-GQL-5, EC-GQL-3, AR-GQL-1 | unit | `GraphQLPersistedQueryTests.aHashIsSentFirstAndTheDocumentOnlyWhenTheServerAsks` |
| T-22.4 | FR-GQL-5, EC-GQL-3, AR-GQL-1 | unit | `GraphQLPersistedQueryTests.aServerWithoutSupportTurnsPersistedQueriesOffForGood` |
| T-22.5 | FR-GQL-6 | unit | `GraphQLTransportTests.identicalQueriesShareARequestButIdenticalMutationsNeverDo` |
| T-22.6 | FR-GQL-7 | unit | `GraphQLTransportTests.queriesCanGoAsGETWhileMutationsStayPOST` |
| T-22.7 | FR-GQL-8, EC-GQL-4 | unit | `GraphQLTransportTests.aGraphQLBodyInAnErrorStatusIsReadAndAnythingElseStaysAnHTTPError` |
| T-22.8 | FR-GQL-2, FR-GQL-3 | E2E | `GraphQLE2ECoverageTests.e2eATypedQueryDecodesFromARealGraphQLServer`, `e2eAValidationErrorFromARealServerIsAGraphQLError` |

### Analytics verification

- Trigger timing: `persistedQueryRegistered` only after a miss, before the resend; `persistedQueriesUnsupported`
  once, when APQ is turned off (T-22.3, T-22.4).
- Payload: `partialResponse` carries the operation name, the error count, and whether data came back (T-22.2).
- No false events: a clean response emits nothing (T-22.2).

### E2E

T-22.8 runs against `https://countries.trevorblades.com/graphql` with the real `Transport` and no
stubs, under `RUN_E2E_TESTS=1 swift test --filter E2ECoverageTests`.

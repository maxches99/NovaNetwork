import Foundation
import Testing
@testable import NovaNetworkClient

extension NetworkingCoverageTests {
    @Test
    func presetsExposeSafeDefaultsAndTradeoffs() {
        let rest = NetworkClientPreset.restHeavy
        #expect(rest.kind == .restHeavy)
        #expect(rest.retryPolicy.maxAttempts == 3)
        #expect(rest.defaultRequestOptions.rateLimitPolicy != nil)
        #expect(rest.tradeoffs.count >= 3)

        let realtime = NetworkClientPreset.realtimeHeavy
        #expect(realtime.kind == .realtimeHeavy)
        if case .networkOnly = realtime.defaultCachePolicy {
            #expect(Bool(true))
        } else {
            Issue.record("Expected networkOnly default cache policy for realtime preset")
        }
        #expect(realtime.defaultRequestOptions.priority == .high)
        #expect(realtime.defaultRequestOptions.offlineQueuePolicy == .disabled)

        let offline = NetworkClientPreset.offlineFirst
        #expect(offline.kind == .offlineFirst)
        #expect(offline.retryPolicy.maxAttempts >= 4)
        #expect(offline.defaultRequestOptions.offlineQueuePolicy.mode == .enqueueWhenOffline)
        #expect(offline.defaultRequestOptions.idempotencyPolicy != nil)
    }

    @Test
    func presetRequestOverridesMergeWithoutDroppingSafetyDefaults() {
        let preset = NetworkClientPreset.offlineFirst

        let merged = preset.requestOptions(
            overrides: .init(
                priority: .high,
                rateLimitPolicy: RateLimitPolicy(maxRequests: 4, intervalSeconds: 1)
            )
        )

        #expect(merged.priority == .high)
        #expect(merged.rateLimitPolicy?.maxRequests == 4)

        #expect(merged.capacityScheduling == preset.defaultRequestOptions.capacityScheduling)
        #expect(merged.coalescingMode == preset.defaultRequestOptions.coalescingMode)
        #expect(merged.offlineQueuePolicy == preset.defaultRequestOptions.offlineQueuePolicy)
        #expect(merged.idempotencyPolicy?.headerName == preset.defaultRequestOptions.idempotencyPolicy?.headerName)
    }

    @Test
    func applyRuntimePolicyFromPresetEmitsPolicyUpdateTelemetry() async {
        let recorder = TelemetryRecorder()
        let client = NetworkClient(
            transport: StubNetworkTransport(delayNanos: 0, response: .success(Data("ok".utf8))),
            telemetryHooks: .init(
                onPolicyUpdated: { context in
                    Task { await recorder.appendPolicyUpdated(context) }
                }
            )
        )

        await client.applyRuntimePolicy(from: .restHeavy)

        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if !(await recorder.policyUpdatedSnapshot().isEmpty) {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let events = await recorder.policyUpdatedSnapshot()
        guard let update = events.last else {
            Issue.record("Expected policy update telemetry")
            return
        }

        #expect(update.scope == "global")
        #expect(update.source == RuntimePolicySource.runtimeUpdate.rawValue)
        #expect(update.changedFields.contains("deadline_budget_seconds"))
        #expect(update.changedFields.contains("circuit_breaker_policy"))
        #expect(update.changedFields.contains("coalescing_policy"))
    }
}

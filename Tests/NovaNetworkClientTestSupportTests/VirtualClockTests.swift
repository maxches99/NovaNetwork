import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkClientTestSupport

// Requirements: FR-TEST-4 (deterministic virtual clock).
//
// A fixed real-time sleep is a guess that a task has reached `clock.sleep`, not a guarantee, and it
// is the reason this suite failed intermittently on CI. Every wait here is on observable state --
// `pendingSleepCount()` -- with a deadline.

@Suite
struct VirtualClockTests {
    @Test
    func sleepResumesOnlyOnceTheDeadlineHasFullyElapsed() async throws {
        let clock = VirtualClock()
        let task = Task { try await clock.sleep(nanoseconds: 5_000_000_000) }

        await waitUntil { await clock.pendingSleepCount() == 1 }

        await clock.advance(by: 3_000_000_000)
        #expect(await clock.pendingSleepCount() == 1) // still short of the 5s deadline

        await clock.advance(by: 2_000_000_000)
        try await task.value // now resumes
        #expect(await clock.pendingSleepCount() == 0)
    }

    @Test
    func advanceToNextDeadlineJumpsDirectlyToTheEarliestPendingSleep() async throws {
        let clock = VirtualClock()
        let task = Task { try await clock.sleep(nanoseconds: 10_000_000_000) }
        await waitUntil { await clock.pendingSleepCount() == 1 }

        let advanced = await clock.advanceToNextDeadline()
        #expect(advanced == 10_000_000_000)
        try await task.value
        #expect(await clock.currentTime() == 10_000_000_000)
    }

    @Test
    func multipleSleepsAtDifferentDeadlinesResumeInDeadlineOrder() async throws {
        let clock = VirtualClock()
        actor Order {
            var resumed: [String] = []
            func record(_ label: String) { resumed.append(label) }
        }
        let order = Order()

        let long = Task {
            try await clock.sleep(nanoseconds: 5_000_000_000)
            await order.record("long")
        }
        let short = Task {
            try await clock.sleep(nanoseconds: 1_000_000_000)
            await order.record("short")
        }
        // Both sleepers must be registered before the clock moves.
        await waitUntil { await clock.pendingSleepCount() == 2 }

        // Advancing to each deadline in turn asserts the property under test -- the shorter deadline
        // wakes first and the longer one does not wake early -- without depending on how the
        // scheduler happens to interleave two tasks that were resumed together.
        await clock.advance(by: 1_000_000_000)
        try await short.value
        #expect(await order.resumed == ["short"])

        await clock.advance(by: 4_000_000_000)
        try await long.value

        #expect(await order.resumed == ["short", "long"])
    }

    @Test
    func cancellingTheSleepingTaskThrowsCancellationErrorAndRemovesTheWaiter() async throws {
        let clock = VirtualClock()
        let task = Task { try await clock.sleep(nanoseconds: 5_000_000_000) }
        await waitUntil { await clock.pendingSleepCount() == 1 }

        task.cancel()
        do {
            try await task.value
            Issue.record("expected cancellation to throw")
        } catch is CancellationError {
            // expected
        }

        await waitUntil { await clock.pendingSleepCount() == 0 }
        #expect(await clock.pendingSleepCount() == 0)
    }

    @Test
    func zeroDurationSleepReturnsImmediatelyWithoutBecomingAWaiter() async throws {
        let clock = VirtualClock()
        try await clock.sleep(nanoseconds: 0)
        #expect(await clock.pendingSleepCount() == 0)
    }
}

import Foundation

public enum CancellationPolicy: Sendable {
    case keepRunning
    case cancelWhenNoWaiters
}

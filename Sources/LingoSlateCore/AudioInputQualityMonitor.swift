import Foundation

public struct AudioInputQualityMonitor: Sendable {
    private let observationDuration: TimeInterval
    private let strongLevelThreshold: Float
    private let minimumStrongSamples: Int
    private var windowStartedAt: TimeInterval?
    private var strongSampleCount = 0

    public private(set) var isInputLow = false

    public init(
        observationDuration: TimeInterval = 15,
        strongLevelThreshold: Float = 0.32,
        minimumStrongSamples: Int = 8
    ) {
        self.observationDuration = max(1, observationDuration)
        self.strongLevelThreshold = min(max(strongLevelThreshold, 0), 1)
        self.minimumStrongSamples = max(1, minimumStrongSamples)
    }

    @discardableResult
    public mutating func record(level: Float, at timestamp: TimeInterval) -> Bool {
        guard let windowStartedAt else {
            self.windowStartedAt = timestamp
            strongSampleCount = level >= strongLevelThreshold ? 1 : 0
            return isInputLow
        }
        guard timestamp >= windowStartedAt else {
            reset()
            self.windowStartedAt = timestamp
            return isInputLow
        }

        if level >= strongLevelThreshold {
            strongSampleCount += 1
        }
        guard timestamp - windowStartedAt >= observationDuration else {
            return isInputLow
        }

        isInputLow = strongSampleCount < minimumStrongSamples
        self.windowStartedAt = timestamp
        strongSampleCount = 0
        return isInputLow
    }

    public mutating func reset() {
        windowStartedAt = nil
        strongSampleCount = 0
        isInputLow = false
    }
}

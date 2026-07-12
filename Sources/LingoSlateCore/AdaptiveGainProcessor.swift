import Foundation

public struct AdaptiveGainConfiguration: Hashable, Sendable {
    public var targetDecibels: Float
    public var silenceFloorDecibels: Float
    public var minimumGainDecibels: Float
    public var maximumGainDecibels: Float
    public var gainIncreaseResponseSeconds: TimeInterval
    public var gainDecreaseResponseSeconds: TimeInterval
    public var limiterPeak: Float

    public init(
        targetDecibels: Float = -24,
        silenceFloorDecibels: Float = -55,
        minimumGainDecibels: Float = -6,
        maximumGainDecibels: Float = 15,
        gainIncreaseResponseSeconds: TimeInterval = 0.35,
        gainDecreaseResponseSeconds: TimeInterval = 0.05,
        limiterPeak: Float = 0.89
    ) {
        self.targetDecibels = targetDecibels
        self.silenceFloorDecibels = silenceFloorDecibels
        self.minimumGainDecibels = minimumGainDecibels
        self.maximumGainDecibels = maximumGainDecibels
        self.gainIncreaseResponseSeconds = max(0.01, gainIncreaseResponseSeconds)
        self.gainDecreaseResponseSeconds = max(0.01, gainDecreaseResponseSeconds)
        self.limiterPeak = min(max(limiterPeak, 0.1), 1)
    }

    public static let classroom = AdaptiveGainConfiguration()
}

public struct AdaptiveGainProcessor: Sendable {
    public let configuration: AdaptiveGainConfiguration
    public private(set) var currentGain: Float = 1

    public init(configuration: AdaptiveGainConfiguration = .classroom) {
        self.configuration = configuration
    }

    public var currentGainDecibels: Float {
        20 * log10(max(currentGain, 0.000_001))
    }

    public mutating func process(_ frame: AudioFrame) -> AudioFrame {
        guard !frame.samples.isEmpty else { return frame }

        let level = Self.measure(frame.samples)
        if level.decibels >= configuration.silenceFloorDecibels {
            let desiredGain = Self.gain(forDecibels: configuration.targetDecibels - level.decibels)
            let minimumGain = Self.gain(forDecibels: configuration.minimumGainDecibels)
            let maximumGain = Self.gain(forDecibels: configuration.maximumGainDecibels)
            let clampedGain = min(max(desiredGain, minimumGain), maximumGain)
            let responseSeconds = clampedGain < currentGain
                ? configuration.gainDecreaseResponseSeconds
                : configuration.gainIncreaseResponseSeconds
            let frameDuration = Double(frame.samples.count) / max(frame.sampleRate, 1)
            let blend = Float(1 - exp(-frameDuration / responseSeconds))
            currentGain += (clampedGain - currentGain) * blend
        }

        if level.peak > 0 {
            currentGain = min(currentGain, configuration.limiterPeak / level.peak)
        }

        let processedSamples = frame.samples.map { sample in
            min(max(sample * currentGain, -configuration.limiterPeak), configuration.limiterPeak)
        }
        return AudioFrame(
            samples: processedSamples,
            sampleRate: frame.sampleRate,
            capturedAt: frame.capturedAt
        )
    }

    private static func measure(_ samples: [Float]) -> (decibels: Float, peak: Float) {
        var sumOfSquares: Float = 0
        var peak: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(max(sumOfSquares / Float(samples.count), 0.000_000_000_1))
        return (20 * log10(rms), peak)
    }

    private static func gain(forDecibels decibels: Float) -> Float {
        pow(10, decibels / 20)
    }
}

import Foundation

/// Android's `PeakLimiter`: the catch for overs the spatial widener and the equaliser leave in
/// place for the stages after them (`DspChain` holds the loudness limiter on for exactly those).
///
/// Instant attack, a smooth release, linked across channels so a peak on one side never pulls the
/// stereo image over, and no lookahead: a catcher for the odd over, not a mastering limiter, and
/// most of the time it does nothing at all. Audio side only.
struct PeakLimiter {
    /// Just under full scale, as on Android.
    static let ceiling: Float = 0.985
    /// A little slow, so a release never moves within a bass cycle (heard as grit).
    static let releaseSeconds = 0.1

    private var releaseCoefficient: Float = 1
    private(set) var reduction: Float = 1

    mutating func configure(sampleRate: Double) {
        releaseCoefficient = sampleRate > 0 ? Float(1 - exp(-1 / (Self.releaseSeconds * sampleRate))) : 1
        reduction = 1
    }

    /// Lets go at once, for a seek or a bypass: there is nothing left to be continuous with.
    mutating func reset() {
        reduction = 1
    }

    /// What to multiply a frame by, given the magnitude of its loudest channel.
    mutating func gain(forPeak peak: Float) -> Float {
        let wanted = peak > Self.ceiling ? Self.ceiling / peak : 1
        reduction = wanted < reduction ? wanted : reduction + (wanted - reduction) * releaseCoefficient
        // Settled back: snapped to exactly unity so an idle limiter passes samples bit-exact.
        if reduction > 0.999_999 { reduction = 1 }
        return reduction
    }

    mutating func process(_ channels: DSPChannels) {
        let stride = channels.stride
        let channelCount = channels.channelCount
        var frame = 0
        while frame < channels.frameCount {
            let index = frame * stride
            var peak: Float = 0
            var channel = 0
            while channel < channelCount {
                peak = max(peak, abs(channels.base(of: channel)[index]))
                channel += 1
            }
            let gain = gain(forPeak: peak)
            if gain != 1 {
                channel = 0
                while channel < channelCount {
                    channels.base(of: channel)[index] *= gain
                    channel += 1
                }
            }
            frame += 1
        }
    }
}

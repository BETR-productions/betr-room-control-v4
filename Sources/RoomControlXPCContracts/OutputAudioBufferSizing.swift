// OutputAudioBufferSizing — correct frame-aligned audio buffer sizes.
// Two audio buffers per video frame at ~half-frame granularity.
// At 48kHz / 29.97fps: alternates 800/801 samples per buffer (sum ~1601/frame).
// Never 480 or 48000 sample blocks.

import Foundation

public enum OutputAudioBufferSizing {
    /// Sample count for a single audio buffer push.
    ///
    /// Two audio buffers per video frame at approximately half-frame granularity.
    /// `frameIndex` is the sequential audio buffer push index (0, 1, 2, ...).
    /// Uses integer arithmetic for exact long-term sample alignment.
    ///
    /// At 48kHz / 29.97fps (30000/1001):
    /// - Each buffer is ~800-801 samples (~16.7ms)
    /// - Two buffers per video frame sum to ~1601-1602 samples
    /// - Over 5 video frames (10 buffers): exactly 8008 samples
    public static func sampleCount(
        forFrameIndex frameIndex: UInt64,
        sampleRate: Int,
        frameRateNumerator: Int,
        frameRateDenominator: Int
    ) -> Int {
        // accumulated(n) = n * sampleRate * frameRateDenominator / (frameRateNumerator * 2)
        // Integer floor division distributes fractional samples correctly over time.
        let num = UInt64(sampleRate) * UInt64(frameRateDenominator)
        let den = UInt64(frameRateNumerator) * 2
        let accNext = (frameIndex + 1) * num / den
        let accCurr = frameIndex * num / den
        return Int(accNext - accCurr)
    }

    /// Total samples for one video frame (sum of two audio buffers).
    /// `videoFrameIndex` is the video frame index (0, 1, 2, ...).
    public static func samplesPerVideoFrame(
        videoFrameIndex: UInt64,
        sampleRate: Int,
        frameRateNumerator: Int,
        frameRateDenominator: Int
    ) -> Int {
        let num = UInt64(sampleRate) * UInt64(frameRateDenominator)
        let den = UInt64(frameRateNumerator)
        let accNext = (videoFrameIndex + 1) * num / den
        let accCurr = videoFrameIndex * num / den
        return Int(accNext - accCurr)
    }
}

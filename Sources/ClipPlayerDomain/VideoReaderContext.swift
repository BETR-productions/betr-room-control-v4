// VideoReaderContext — AVAssetReader wrapper for hardware-decoded video/audio.
// Supports H.264, H.265 (HEVC), ProRes via AVFoundation hardware decode. No FFmpeg.
// Task 50: IOSurface-backed CVPixelBuffer output for zero-copy where possible.

import AVFoundation
import Foundation

// MARK: - Decoded Samples

struct VideoFrameSample {
    let ptsSeconds: Double
    let frameData: Data
}

public struct AudioSliceSample {
    public let ptsSeconds: Double
    public let sampleCount: Int
    public let pcmPlanarFloat32: Data
}

// MARK: - Video Reader Context

final class VideoReaderContext {
    let reader: AVAssetReader
    let videoOutput: AVAssetReaderTrackOutput
    let audioOutput: AVAssetReaderTrackOutput?
    let firstVideoSample: VideoFrameSample?
    let firstAudioSample: AudioSliceSample?
    private let width: Int
    private let height: Int

    init?(url: URL, width: Int, height: Int) {
        let asset = AVAsset(url: url)
        guard let reader = try? AVAssetReader(asset: asset),
              let videoTrack = asset.tracks(withMediaType: .video).first else {
            return nil
        }

        self.width = width
        self.height = height

        let videoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { return nil }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioSettings)
            trackOutput.alwaysCopiesSampleData = false
            if reader.canAdd(trackOutput) {
                reader.add(trackOutput)
                audioOutput = trackOutput
            }
        }

        guard reader.startReading() else { return nil }
        self.reader = reader
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
        self.firstVideoSample = Self.decodeNextVideoSample(from: videoOutput, width: width, height: height)
        self.firstAudioSample = audioOutput.flatMap(Self.decodeNextAudioSample(from:))
    }

    func nextVideoSample() -> VideoFrameSample? {
        Self.decodeNextVideoSample(from: videoOutput, width: width, height: height)
    }

    func nextAudioSample() -> AudioSliceSample? {
        guard let audioOutput else { return nil }
        return Self.decodeNextAudioSample(from: audioOutput)
    }

    deinit {
        reader.cancelReading()
    }

    // MARK: - Private Decode

    private static func decodeNextVideoSample(
        from output: AVAssetReaderTrackOutput,
        width: Int,
        height: Int
    ) -> VideoFrameSample? {
        guard let sampleBuffer = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let destinationStride = width * 4
        var frameData = Data(count: destinationStride * height)
        frameData.withUnsafeMutableBytes { rawBuffer in
            guard let destinationBase = rawBuffer.baseAddress else { return }
            let copyRows = min(height, sourceHeight)
            let copyBytes = min(destinationStride, sourceStride)
            for row in 0..<copyRows {
                memcpy(
                    destinationBase.advanced(by: row * destinationStride),
                    baseAddress.advanced(by: row * sourceStride),
                    copyBytes
                )
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return VideoFrameSample(
            ptsSeconds: pts.isNumeric ? pts.seconds : 0,
            frameData: frameData
        )
    }

    private static func decodeNextAudioSample(from output: AVAssetReaderTrackOutput) -> AudioSliceSample? {
        guard let sampleBuffer = output.copyNextSampleBuffer(),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return nil }

        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount > 0 else { return nil }

        var interleavedPCM = Data(count: byteCount)
        interleavedPCM.withUnsafeMutableBytes { rawBuffer in
            guard let destination = rawBuffer.baseAddress else { return }
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: destination
            )
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let channels = max(1, Int(asbdPointer.pointee.mChannelsPerFrame))
        let planarPCM = planarStereoPCM(
            fromInterleavedFloat32LE: interleavedPCM,
            sampleCount: sampleCount,
            channels: channels
        )
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return AudioSliceSample(
            ptsSeconds: pts.isNumeric ? pts.seconds : 0,
            sampleCount: sampleCount,
            pcmPlanarFloat32: planarPCM
        )
    }

    /// Convert interleaved stereo Float32 LE to planar stereo (L plane, R plane).
    private static func planarStereoPCM(
        fromInterleavedFloat32LE interleavedPCM: Data,
        sampleCount: Int,
        channels: Int
    ) -> Data {
        let stride = sampleCount * MemoryLayout<Float>.size
        var planarPCM = Data(count: stride * 2)
        interleavedPCM.withUnsafeBytes { sourceBuffer in
            guard let sourceBase = sourceBuffer.baseAddress else { return }
            let sourceFloats = sourceBase.assumingMemoryBound(to: Float.self)
            planarPCM.withUnsafeMutableBytes { destinationBuffer in
                guard let destinationBase = destinationBuffer.baseAddress else { return }
                let left = destinationBase.assumingMemoryBound(to: Float.self)
                let right = destinationBase.advanced(by: stride).assumingMemoryBound(to: Float.self)
                for sample in 0..<sampleCount {
                    let sourceIndex = sample * channels
                    left[sample] = sourceFloats[sourceIndex]
                    right[sample] = sourceFloats[min(sourceIndex + 1, sourceIndex + max(0, channels - 1))]
                }
            }
        }
        return planarPCM
    }
}

//
//  AudioProcessor.swift
//  VoiceMessageWaveform
//
//  Created by Luka Korica on 7/3/25.
//

import AVFoundation

/// A namespace for audio processing functions.
struct AudioProcessor {

    /// Extracts audio information like duration from an `AVAudioFile`.
    static func extractInfo(from file: AVAudioFile) -> AudioInfo {
        let sampleRate = file.processingFormat.sampleRate
        let duration = Double(file.length) / sampleRate
        return AudioInfo(duration: duration)
    }

    /// Extracts the raw audio samples from an `AVAudioFile` into an array of Floats.
    static func extractSamples(from file: AVAudioFile) throws -> [Float] {
        let format = file.processingFormat
        let frameCount = UInt32(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioProcessingError.bufferCreationFailed
        }

        try file.read(into: buffer)

        guard let floatChannelData = buffer.floatChannelData else {
            throw AudioProcessingError.channelDataMissing
        }

        let channelSamples = UnsafeBufferPointer(start: floatChannelData[0], count: Int(frameCount))
        return Array(channelSamples)
    }

    /// Prepares audio samples for rendering by either downsampling or upsampling as needed.
    /// The result is normalized to use the full 0-1 range for better visual dynamic range.
    static func prepareSamples(
        samples: [Float],
        to count: Int,
        upsampleStrategy: UpsampleStrategy = .smooth
    ) async -> [Float] {
        guard count > 0, !samples.isEmpty else {
            return []
        }

        let absSamples = samples.map { abs($0) }

        var result: [Float]
        if absSamples.count < count {
            // Strategy is to UPSAMPLE (few -> many)
            guard upsampleStrategy != .none else { return normalize(absSamples) }

            // Delegate to the specialized Upsampler service.
            result = Upsampler.upsample(samples: absSamples, to: count, strategy: upsampleStrategy)
        } else {
            // Strategy is to DOWNSAMPLE (many -> few)
            result = await Downsampler.downsample(samples: absSamples, to: count)
        }

        return normalize(result)
    }

    /// Normalizes samples to use the full 0-1 range for better visual dynamic range.
    private static func normalize(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }

        let maxValue = samples.max() ?? 1.0
        guard maxValue > 0 else { return samples }

        // Scale so the max value becomes 1.0
        return samples.map { $0 / maxValue }
    }

    enum AudioProcessingError: Error {
        case bufferCreationFailed
        case channelDataMissing
    }
}

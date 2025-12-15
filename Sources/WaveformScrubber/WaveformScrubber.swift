//
//  WaveformScrubber.swift
//  VoiceMessageWaveform
//
//  Created by Luka Korica on 7/2/25.
//

import os
import SwiftUI
import AVFoundation

private let logger = Logger(subsystem: "WaveformScrubber", category: "WaveformScrubber")

/// A SwiftUI view that displays an audio waveform and allows seeking through playback.
///
/// This view is generic over a `Drawer` type, which must conform to the `WaveformDrawing`
/// protocol. This allows for customizable waveform rendering (e.g., bars, lines).
public struct WaveformScrubber<Drawer: WaveformDrawing,
                                ActiveStyle: ShapeStyle,
                               InactiveStyle: ShapeStyle>: View {

    /// The source of waveform data - either a URL to load from, or pre-supplied samples.
    enum DataSource: Equatable {
        case url(URL)
        case samples([Float])
    }

    @Environment(\.waveformScrubberStyle) private var style
    private let waveformCacheService = WaveformCache.shared

    let config: ScrubberConfig<ActiveStyle, InactiveStyle>
    let drawer: Drawer
    let dataSource: DataSource

    @Binding var progress: CGFloat

    let onInfoLoaded: (AudioInfo) -> Void
    let onGestureActive: (Bool) -> Void

    @State private var samples: [Float] = []
    @State private var localProgress: CGFloat
    @State private var viewSize: CGSize = .zero
    @GestureState private var isDragging: Bool = false

    /// Task ID for triggering sample loading/processing.
    /// For URL-based loading: includes size since we downsample based on view width.
    /// For samples-based loading: excludes size to avoid cycles during geometry changes.
    private var loadTaskID: AnyHashable {
        switch dataSource {
        case .url(let url):
            return AnyHashable(URLTaskID(url: url, size: viewSize))
        case .samples(let samples):
            // Only depend on samples identity (by count + first/last), not size
            // This prevents cycles when geometry changes during iOS navigation
            return AnyHashable(SamplesTaskID(count: samples.count,
                                             first: samples.first ?? 0,
                                             last: samples.last ?? 0))
        }
    }

    private struct URLTaskID: Hashable {
        let url: URL
        let size: CGSize
    }

    private struct SamplesTaskID: Hashable {
        let count: Int
        let first: Float
        let last: Float
    }

    /// Creates a new WaveformScrubber view that loads waveform data from a URL.
    /// - Parameters:
    ///   - config: Configuration for the scrubbers's appearance.
    ///   - drawer: Type of a drawer used for the scrubber's instance
    ///   - url: The URL of the audio file to display.
    ///   - progress: A binding to the playback progress, from 0.0 to 1.0.
    ///   - onInfoLoaded: A closure called when the audio file's metadata (like duration) is loaded.
    ///   - onGestureActive: A closure called when the user starts or stops a drag gesture.
    public init(
        config: ScrubberConfig<ActiveStyle, InactiveStyle>,
        drawer: Drawer,
        url: URL,
        progress: Binding<CGFloat>,
        onInfoLoaded: @escaping (AudioInfo) -> Void = { _ in },
        onGestureActive: @escaping (Bool) -> Void = { _ in }
    ) {
        self.config = config
        self.drawer = drawer
        self.dataSource = .url(url)
        self._progress = progress
        self._localProgress = State(initialValue: progress.wrappedValue)
        self.onInfoLoaded = onInfoLoaded
        self.onGestureActive = onGestureActive
    }

    /// Creates a new WaveformScrubber view with pre-supplied waveform samples.
    ///
    /// Use this initializer when you already have waveform data (e.g., from a streaming audio engine)
    /// and want to avoid re-parsing the audio file.
    ///
    /// - Parameters:
    ///   - config: Configuration for the scrubbers's appearance.
    ///   - drawer: Type of a drawer used for the scrubber's instance
    ///   - samples: Pre-computed waveform samples (normalized 0.0-1.0). These will be downsampled
    ///              to fit the view width automatically.
    ///   - progress: A binding to the playback progress, from 0.0 to 1.0.
    ///   - onGestureActive: A closure called when the user starts or stops a drag gesture.
    public init(
        config: ScrubberConfig<ActiveStyle, InactiveStyle>,
        drawer: Drawer,
        samples: [Float],
        progress: Binding<CGFloat>,
        onGestureActive: @escaping (Bool) -> Void = { _ in }
    ) {
        self.config = config
        self.drawer = drawer
        self.dataSource = .samples(samples)
        self._progress = progress
        self._localProgress = State(initialValue: progress.wrappedValue)
        self.onInfoLoaded = { _ in }
        self.onGestureActive = onGestureActive
    }

    public var body: some View {
        resolveStyleAndApplyModifiers()
            .task(id: loadTaskID) {
                logger.notice("[WAVEFORM] WaveformScrubber task triggered - viewSize: \(viewSize.width)x\(viewSize.height)")
                guard viewSize.width > 0 else {
                    logger.notice("[WAVEFORM] WaveformScrubber: viewSize.width is 0, waiting for layout")
                    return
                }

                switch dataSource {
                case .url(let url):
                    logger.notice("[WAVEFORM] WaveformScrubber: loading from URL: \(url.lastPathComponent)")
                    // Debounce URL-based loading
                    do {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    } catch {
                        return
                    }
                    await loadAudioDataFromURL()

                case .samples(let rawSamples):
                    logger.notice("[WAVEFORM] WaveformScrubber: using pre-supplied samples (\(rawSamples.count) samples)")
                    await prepareSamplesForDisplay(rawSamples)
                }
            }
    }

    @ViewBuilder
    private func resolveStyleAndApplyModifiers() -> some View {
        let shape = AnyShape(DrawingShape(samples: samples, drawer: drawer))
        let active = AnyView(
            shape.mask(alignment: .leading) {
                Rectangle().frame(width: viewSize.width * progress)
            }
            .foregroundStyle(config.activeTint)
        )
        let inactive = AnyView(
            shape.mask(alignment: .leading) {
                Rectangle().padding(.leading, viewSize.width * progress)
            }
            .foregroundStyle(config.inactiveTint)
        )
        let configuration = WaveformScrubberStyle.Configuration(
            waveform: shape,
            activeWaveform: active,
            inactiveWaveform: inactive
        )

        AnyView(style.makeBody(configuration: configuration))
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .background(geometryReader)
            .onChange(of: isDragging, perform: onGestureActive)
            .onChange(of: progress) { newProgress in
                // Update local state only when not dragging to sync with external changes.
                if !isDragging {
                    localProgress = newProgress
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, state, _ in
                state = true
            }
            .onChanged { value in
                guard viewSize.width > 0 else { return }
                let newProgress = (value.translation.width / viewSize.width) + localProgress
                progress = max(0, min(1, newProgress))
            }
            .onEnded { value in
                // Persist the progress after the drag ends.
                localProgress = progress
            }
    }

    private var geometryReader: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear {
                    // Only set viewSize once on appear to avoid cycles
                    // during layout changes (especially iOS navigation)
                    if viewSize == .zero {
                        viewSize = geometry.size
                    }
                }
        }
    }

    /// Prepares pre-supplied samples for display by downsampling to fit the view.
    private func prepareSamplesForDisplay(_ rawSamples: [Float]) async {
        guard !rawSamples.isEmpty else {
            logger.notice("[WAVEFORM] WaveformScrubber.prepareSamplesForDisplay: rawSamples is EMPTY")
            return
        }

        let targetSampleCount = drawer.sampleCount(for: viewSize)
        logger.notice("[WAVEFORM] WaveformScrubber: downsampling \(rawSamples.count) -> \(targetSampleCount) samples for viewSize \(viewSize.width)")

        if Task.isCancelled { return }

        let preparedSamples = await AudioProcessor.prepareSamples(
            samples: rawSamples,
            to: targetSampleCount,
            upsampleStrategy: drawer.upsampleStrategy
        )

        if Task.isCancelled { return }

        logger.notice("[WAVEFORM] WaveformScrubber: prepared \(preparedSamples.count) samples for display")
        await MainActor.run {
            self.samples = preparedSamples
        }
    }

    /// Loads waveform data from a URL.
    private func loadAudioDataFromURL() async {
        guard case .url(let url) = dataSource else { return }
        guard viewSize.width > 0 else { return }

        // Clear old samples to provide immediate visual feedback.
        await MainActor.run {
            self.samples = []
        }

        do {
            // 1. Get the full-resolution samples from the shared cache.
            // This will be instantaneous if another scrubber has already processed this URL.
            // If not, it will perform the processing and cache the result for next time.
            let rawSamples = try await waveformCacheService.samples(for: url)

            // 2. The downsampling step is still necessary for each instance, as it depends on `viewSize`.
            let targetSampleCount = drawer.sampleCount(for: viewSize)

            if Task.isCancelled { return }

            // This vDSP operation is very fast.
            let preparedSamples = await AudioProcessor.prepareSamples(
                samples: rawSamples,
                to: targetSampleCount,
                upsampleStrategy: drawer.upsampleStrategy
            )

            if Task.isCancelled { return }

            // 3. Update the UI.
            await MainActor.run {
                self.samples = preparedSamples
            }

            // We can also fetch the audio info here without re-reading the file.
            // This part is fast and can be done alongside.
            let audioFile = try AVAudioFile(forReading: url)
            onInfoLoaded(AudioProcessor.extractInfo(from: audioFile))

        } catch {
            if !(error is CancellationError) {
                print("WaveformScrubber failed to process audio: \(error.localizedDescription)")
            }
        }
    }

}

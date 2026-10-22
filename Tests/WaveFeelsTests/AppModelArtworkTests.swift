import AppKit
import Testing
import WaveCore
@testable import WaveFeels

/// Обложка и палитра в модели: из обложки трека, только пока Now Playing работает.
@MainActor
struct AppModelArtworkTests {
    @Test func artworkSourceNeedsNowPlaying() {
        let track = SnapshotRenderer.track
        #expect(AppModel.artworkSource(track: track, nowPlayingAvailable: true) == track.artworkData)
        #expect(AppModel.artworkSource(track: track, nowPlayingAvailable: false) == nil)
        #expect(AppModel.artworkSource(track: nil, nowPlayingAvailable: true) == nil)
    }

    @Test func coverPaletteOnlyWhileNowPlayingWorks() throws {
        _ = NSApplication.shared
        let suite = "com.wfeels.wavefeels.tests.artwork"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let cover = ArtworkAnalysis(data: SnapshotRenderer.testArtwork, displayPixels: ExpandedPanelView.artworkPixels).palette
        #expect(cover != PaletteExtractor.fallback)

        show(SnapshotRenderer.track, nowPlaying: true, in: model)
        #expect(model.artwork?.id != nil)
        #expect(model.palette == cover)

        // Запасной режим: трек с обложкой остался, но обложки и ее палитры нет.
        show(SnapshotRenderer.track, nowPlaying: false, in: model)
        #expect(model.artwork?.id == nil)
        #expect(model.palette == PaletteExtractor.fallback)

        show(SnapshotRenderer.track, nowPlaying: true, in: model)
        #expect(model.artwork?.id != nil)
        #expect(model.palette == cover)

        var noArtwork = SnapshotRenderer.track
        noArtwork.artworkData = nil
        show(noArtwork, nowPlaying: true, in: model)
        #expect(model.artwork?.id == nil)
        #expect(model.palette == PaletteExtractor.fallback)
    }

    private func show(_ track: NowPlayingInfo, nowPlaying: Bool, in model: AppModel) {
        model.showPreview(
            state: .expanded, track: track, palette: nil, frame: .silent, motion: WaveMotion(),
            pulse: BeatPulse(), time: 0, nowPlayingAvailable: nowPlaying
        )
    }
}

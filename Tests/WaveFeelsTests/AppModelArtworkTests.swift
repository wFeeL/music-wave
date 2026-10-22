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

    /// Кнопки панели управляют тем, кого показывает Now Playing, поэтому трек с кнопками
    /// показывается, только пока текущая запись Now Playing относится к источнику.
    @Test func panelTrackNeedsNowPlayingOfSelectedSource() {
        let yandex = AudioSource.application(
            bundleID: "ru.yandex.desktop.music", bundlePath: "/Applications/Яндекс Музыка.app", displayName: "Яндекс Музыка"
        )
        let track = NowPlayingInfo(bundleIdentifier: "ru.yandex.desktop.music", title: "Песня", isPlaying: false)
        let helper = NowPlayingInfo(bundleIdentifier: "ru.yandex.desktop.music.helper", title: "Песня")
        let other = NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: "Другая", isPlaying: true)

        #expect(AppModel.panelTrack(lastTrack: track, current: track, source: yandex, nowPlayingAvailable: true) == track)
        #expect(AppModel.panelTrack(lastTrack: track, current: helper, source: yandex, nowPlayingAvailable: true) == track)
        // Now Playing переключился на Музыку: у Яндекс Музыки остался трек, но кнопок нет.
        #expect(AppModel.panelTrack(lastTrack: track, current: other, source: yandex, nowPlayingAvailable: true) == nil)
        #expect(AppModel.panelTrack(lastTrack: track, current: nil, source: yandex, nowPlayingAvailable: true) == nil)
        #expect(AppModel.panelTrack(lastTrack: track, current: track, source: yandex, nowPlayingAvailable: false) == nil)
        // Весь звук системы: подходит любая запись.
        #expect(AppModel.panelTrack(lastTrack: other, current: other, source: .systemWide, nowPlayingAvailable: true) == other)
    }

    private func show(_ track: NowPlayingInfo, nowPlaying: Bool, in model: AppModel) {
        model.showPreview(
            state: .expanded, track: track, palette: nil, frame: .silent, motion: WaveMotion(),
            pulse: BeatPulse(), time: 0, nowPlayingAvailable: nowPlaying
        )
    }
}

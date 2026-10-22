import Testing
@testable import WaveCore

struct TrackBannerTests {
    private static let a = TrackKey(title: "Первый", artist: "Исполнитель", source: "com.apple.Music")
    private static let b = TrackKey(title: "Второй", artist: "Исполнитель", source: "com.apple.Music")
    private static let c = TrackKey(title: "Третий", artist: "Исполнитель", source: "com.apple.Music")
    private static let d = TrackKey(title: "Четвертый", artist: "Исполнитель", source: "com.apple.Music")
    private static let e = TrackKey(title: "Пятый", artist: "Исполнитель", source: "com.apple.Music")

    private func inputs(
        _ track: TrackKey?, playing: Bool = true, enabled: Bool = true,
        panelOpen: Bool = false, suppressed: Bool = false
    ) -> TrackBannerInputs {
        TrackBannerInputs(
            enabled: enabled, track: track, isPlaying: playing, panelOpen: panelOpen, suppressed: suppressed
        )
    }

    /// Баннер с базовым треком A, обновленный в момент 0.
    private func withBaseline() -> TrackBanner {
        var banner = TrackBanner()
        _ = banner.update(inputs(Self.a), now: 0)
        return banner
    }

    private func isShowing(_ phase: TrackBannerPhase) -> Bool {
        if case .showing = phase { return true }
        return false
    }

    @Test func firstTrackAfterResetIsBaseline() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 0.5)
        banner.reset()
        var now = 1.0
        while now <= 20 {
            #expect(banner.update(inputs(Self.a), now: now) == .hidden, "t \(now)")
            now += 0.25
        }
        #expect(banner.deadline == nil)
    }

    @Test func newTrackShowsAfterSettle() {
        var banner = withBaseline()
        #expect(banner.update(inputs(Self.b), now: 10) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 10.29) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 10.31) == .showing(Self.b, textVisible: true))
        #expect(banner.update(inputs(Self.b), now: 13.67) == .showing(Self.b, textVisible: true))
        #expect(banner.update(inputs(Self.b), now: 13.69) == .showing(Self.b, textVisible: false))
        #expect(banner.update(inputs(Self.b), now: 13.79) == .showing(Self.b, textVisible: false))
        #expect(banner.update(inputs(Self.b), now: 13.81) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 30) == .hidden)
    }

    @Test func rapidChangesUpdateOneBanner() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        _ = banner.update(inputs(Self.c), now: 10.1)
        var now = 10.1
        while now < 10.39 {
            let phase = banner.update(inputs(Self.c), now: now)
            #expect(phase == .hidden, "t \(now)")
            now += 0.02
        }
        #expect(banner.update(inputs(Self.c), now: 10.41) == .showing(Self.c, textVisible: true))
        // Смена во время показа обновляет содержимое после своей выдержки и продлевает показ.
        #expect(banner.update(inputs(Self.d), now: 11) == .showing(Self.c, textVisible: true))
        #expect(banner.update(inputs(Self.d), now: 11.29) == .showing(Self.c, textVisible: true))
        #expect(banner.update(inputs(Self.d), now: 11.31) == .showing(Self.d, textVisible: true))
        #expect(banner.update(inputs(Self.d), now: 14.79) == .showing(Self.d, textVisible: false))
        #expect(banner.update(inputs(Self.d), now: 14.81) == .hidden)
    }

    @Test func waitsOneSecondAfterHide() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        #expect(banner.update(inputs(Self.b), now: 13.81) == .hidden)
        #expect(banner.update(inputs(Self.e), now: 14.0) == .hidden)
        #expect(banner.update(inputs(Self.e), now: 14.3) == .hidden)
        #expect(banner.update(inputs(Self.e), now: 14.79) == .hidden)
        #expect(banner.update(inputs(Self.e), now: 14.81) == .showing(Self.e, textVisible: true))
    }

    @Test func gapCountsFromHideEvenWithoutUpdateAtHide() {
        // Показ кончился в 13.8, а следующий вызов только в 14.0 со сменой трека.
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        #expect(banner.update(inputs(Self.e), now: 14.0) == .hidden)
        #expect(banner.update(inputs(Self.e), now: 14.79) == .hidden)
        #expect(isShowing(banner.update(inputs(Self.e), now: 14.81)))
    }

    @Test func pausedChangeShowsWhenPlaybackStarts() {
        var banner = withBaseline()
        #expect(banner.update(inputs(Self.b, playing: false), now: 10) == .hidden)
        #expect(banner.update(inputs(Self.b, playing: false), now: 15) == .hidden)
        #expect(banner.deadline == nil)
        #expect(banner.update(inputs(Self.b), now: 20) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 20.29) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 20.31) == .showing(Self.b, textVisible: true))
    }

    @Test func pauseDuringSettleDropsPendingChange() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(banner.update(inputs(Self.b, playing: false), now: 10.1) == .hidden)
        #expect(banner.update(inputs(Self.b, playing: false), now: 10.5) == .hidden)
        // Воспроизведение снова: выдержка заново от 11.
        #expect(banner.update(inputs(Self.b), now: 11) == .hidden)
        #expect(banner.update(inputs(Self.b), now: 11.29) == .hidden)
        #expect(isShowing(banner.update(inputs(Self.b), now: 11.31)))
    }

    @Test func returnToBaselineDuringSettleShowsNothing() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(banner.update(inputs(Self.a), now: 10.1) == .hidden)
        #expect(banner.update(inputs(Self.a), now: 11) == .hidden)
        #expect(banner.deadline == nil)
    }

    @Test func emptyTitleNeverShows() {
        var banner = withBaseline()
        let empty = TrackKey(title: "", artist: "Исполнитель", source: "com.apple.Music")
        let blank = TrackKey(title: "  ", artist: "Другой", source: "com.apple.Music")
        for (index, key) in [empty, blank].enumerated() {
            let start = 10.0 + Double(index) * 10
            var now = start
            while now < start + 5 {
                #expect(banner.update(inputs(key), now: now) == .hidden, "t \(now)")
                now += 0.25
            }
        }
        #expect(banner.update(inputs(nil), now: 30) == .hidden)
        // Пустое название не стало базовым: возврат к A без баннера.
        #expect(banner.update(inputs(Self.a), now: 31) == .hidden)
        #expect(banner.update(inputs(Self.a), now: 32) == .hidden)
    }

    @Test func emptyTitleIsNotFirstBaseline() {
        var banner = TrackBanner()
        let empty = TrackKey(title: "", artist: "", source: "com.apple.Music")
        #expect(banner.update(inputs(empty), now: 0) == .hidden)
        #expect(banner.update(inputs(Self.a), now: 0.5) == .hidden)
        #expect(banner.update(inputs(Self.a), now: 5) == .hidden)
    }

    @Test func openPanelUpdatesInPlace() {
        var banner = withBaseline()
        #expect(banner.update(inputs(Self.b, panelOpen: true), now: 10) == .hidden)
        #expect(banner.update(inputs(Self.b, panelOpen: true), now: 11) == .hidden)
        var now = 12.0
        while now <= 18 {
            #expect(banner.update(inputs(Self.b), now: now) == .hidden, "t \(now)")
            now += 0.25
        }
    }

    @Test func suppressedChangeBecomesBaseline() {
        // Остров скрыт полноэкранным приложением при «Скрывать в полноэкранном режиме».
        var banner = withBaseline()
        #expect(banner.update(inputs(Self.b, suppressed: true), now: 10) == .hidden)
        #expect(banner.update(inputs(Self.b, suppressed: true), now: 12) == .hidden)
        var now = 13.0
        while now <= 18 {
            #expect(banner.update(inputs(Self.b), now: now) == .hidden, "t \(now)")
            now += 0.25
        }
    }

    @Test func disabledNeverShowsAndLeavesNoBacklog() {
        var banner = withBaseline()
        var now = 10.0
        for key in [Self.b, Self.c, Self.d] {
            for _ in 0..<20 {
                #expect(banner.update(inputs(key, enabled: false), now: now) == .hidden, "t \(now)")
                now += 0.25
            }
        }
        // Включили: текущий трек D уже базовый.
        while now <= 30 {
            #expect(banner.update(inputs(Self.d), now: now) == .hidden, "t \(now)")
            now += 0.25
        }
        // Следующая смена снова показывается.
        _ = banner.update(inputs(Self.e), now: 31)
        #expect(isShowing(banner.update(inputs(Self.e), now: 31.31)))
    }

    @Test func cancelHidesAndKeepsBaseline() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        banner.cancel()
        #expect(banner.deadline == nil)
        var now = 10.5
        while now <= 18 {
            #expect(banner.update(inputs(Self.b), now: now) == .hidden, "t \(now)")
            now += 0.25
        }
    }

    @Test func cancelCountsAsHideForGap() {
        var banner = withBaseline()
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
        _ = banner.update(inputs(Self.b), now: 11)
        banner.cancel()
        _ = banner.update(inputs(Self.c), now: 11.2)
        #expect(banner.update(inputs(Self.c), now: 11.6) == .hidden)
        #expect(banner.update(inputs(Self.c), now: 11.99) == .hidden)
        #expect(isShowing(banner.update(inputs(Self.c), now: 12.01)))
    }

    @Test func sourceChangeCountsAsNewTrack() {
        var banner = withBaseline()
        let other = TrackKey(title: Self.a.title, artist: Self.a.artist, source: "com.spotify.client")
        _ = banner.update(inputs(other), now: 10)
        #expect(banner.update(inputs(other), now: 10.31) == .showing(other, textVisible: true))
    }

    @Test func suppressionOrPauseHidesAtOnce() {
        let hiders: [TrackBannerInputs] = [
            inputs(Self.b, playing: false),
            inputs(Self.b, suppressed: true),
            inputs(Self.b, panelOpen: true),
            inputs(Self.b, enabled: false),
        ]
        for hider in hiders {
            var banner = withBaseline()
            _ = banner.update(inputs(Self.b), now: 10)
            #expect(isShowing(banner.update(inputs(Self.b), now: 10.31)))
            #expect(banner.update(hider, now: 11) == .hidden, "\(hider)")
            #expect(banner.deadline == nil)
            // Причина ушла: тот же трек уже показан, баннер не возвращается.
            #expect(banner.update(inputs(Self.b), now: 11.5) == .hidden, "\(hider)")
            #expect(banner.update(inputs(Self.b), now: 13) == .hidden, "\(hider)")
        }
    }

    @Test func deadlineNamesNextEvent() throws {
        var banner = withBaseline()
        #expect(banner.deadline == nil)
        _ = banner.update(inputs(Self.b), now: 10)
        #expect(try #require(banner.deadline) == 10 + TrackBanner.settleDelay)
        _ = banner.update(inputs(Self.b), now: 10.3)
        let shown = 10 + TrackBanner.settleDelay
        let end = shown + TrackBanner.openDuration + TrackBanner.visibleDuration
        #expect(try #require(banner.deadline) == end - TrackBanner.textLead)
        _ = banner.update(inputs(Self.b), now: end - TrackBanner.textLead)
        #expect(try #require(banner.deadline) == end)
        _ = banner.update(inputs(Self.b), now: end)
        #expect(banner.deadline == nil)
        // Новая смена сразу после скрытия ждет минимальный промежуток.
        _ = banner.update(inputs(Self.c), now: end + 0.1)
        #expect(try #require(banner.deadline) == end + TrackBanner.minimumGap)
    }

    @Test func constantsMatchSpec() {
        #expect(TrackBanner.settleDelay == 0.3)
        #expect(TrackBanner.minimumGap == 1.0)
        #expect(TrackBanner.openDuration == 0.5)
        #expect(TrackBanner.visibleDuration == 3.0)
        #expect(TrackBanner.textLead == 0.12)
    }
}
